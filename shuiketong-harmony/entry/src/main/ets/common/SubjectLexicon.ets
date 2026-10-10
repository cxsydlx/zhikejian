/**
 * 科目专业词汇库 —— 提升课堂语音识别准确率。
 *
 * 两条生效路径：
 *   ① 术语表（hotwords）→ 云端 ASR 握手时下发；服务端支持热词则直接提升识别率
 *   ② 误识别纠正（fixes）→ 转写文本落库前替换；纯端侧，不依赖服务端，两端效果一致
 *
 * 纠正只做**多字词组**替换（不做单字），避免把日常用语改坏。
 * 映射之间刻意不嵌套（不存在"某误识别词是另一误识别词的子串"），因此执行顺序无关。
 */

export class SubjectFix {
  wrong: string;
  right: string;

  constructor(wrong: string, right: string) {
    this.wrong = wrong;
    this.right = right;
  }
}

export class Subject {
  key: string;
  label: string;
  /** 该科目术语（下发给云端 ASR 做热词增强） */
  hotwords: string[];
  /** 常见误识别 → 正确写法 */
  fixes: SubjectFix[];

  constructor(key: string, label: string, hotwords: string[], fixes: SubjectFix[]) {
    this.key = key;
    this.label = label;
    this.hotwords = hotwords;
    this.fixes = fixes;
  }
}

function F(wrong: string, right: string): SubjectFix {
  return new SubjectFix(wrong, right);
}

/** 所有科目通用：课堂里高频、且与科目无关的误识别 */
const COMMON_FIXES: SubjectFix[] = [
  F('高数', '高等数学'),
  F('线代', '线性代数'),
  F('概统', '概率统计'),
  F('知识电', '知识点'),
  F('这道提', '这道题'),
  F('做业', '作业'),
  F('复席', '复习'),
  F('比记', '笔记'),
  F('考电', '考点'),
  F('众点', '重点'),
  F('达疑', '答疑'),
  F('期末考式', '期末考试'),
  F('期中考式', '期中考试'),
  F('论闻', '论文'),
  F('学份', '学分'),
  F('基点', '绩点'),
];

/**
 * 科目自动匹配规则：课程名关键词 → 科目 key。
 *
 * 【2026-09-28 修正】原实现按「规则顺序 → 关键词顺序」首个命中即返回，
 * 导致泛词抢答。实测反例（修复前）：
 *   · 「计算机英语」→ english  ← `'英语'` 规则排在 cs 之前，`'计算机'` 被吃掉
 *   · 「数字信号处理」→ general ← 只有整词 `'数字电路'`，没有 `'数字信号'`
 *
 * 现改为**全局长度优先**：把所有关键词拉平成一个表，按关键词长度**降序**匹配，
 * 命中即返回。长词天然比短词具体（`'计算机网络'` 8 字 > `'计算机'` 3 字），
 * 因此「计算机网络」不会再被 cs 抢走，「计算机英语」也会正确落到 cs（`'计算机'` 3 字
 * 比 `'英语'` 2 字长）。同长度时按此数组声明顺序决定优先级。
 *
 * ⚠️ 新增关键词时**不需要**再手工调整规则顺序 —— 长度优先已经兜住了。
 */
class GuessRule {
  kws: string[];
  key: string;

  constructor(kws: string[], key: string) {
    this.kws = kws;
    this.key = key;
  }
}

const GUESS_RULES: GuessRule[] = [
  new GuessRule([
    '英语', '外语', '口语', '听说', '读写', '视听说', '翻译', '雅思', '托福',
    '英语听力', '英语口语', '专业英语', '商务英语', '学术英语', '英文',
  ], 'english'),
  new GuessRule([
    '计算机网络', '网络', '通信原理', 'tcp', 'ip', '移动通信', '光纤通信', '数据通信',
    '网络工程', '网络协议', '组网', '局域网', '互联网',
  ], 'network'),
  new GuessRule([
    '概率', '统计', '概统', '随机过程', '数理统计', '概率论', '应用统计',
    '统计学', '贝叶斯',
  ], 'prob'),
  new GuessRule([
    '线性代数', '线代', '矩阵论', '高等代数', '矩阵分析', '代数',
  ], 'linalg'),
  // 补漏：数字信号处理 / 模拟电子 / 电工电子 等课程常用简称
  new GuessRule([
    '电路', '模电', '数电', '电工', '电子', '信号与系统', '模拟电路', '数字电路',
    '数字信号', '信号处理', '电工电子', '模拟电子', '数字电子', '电子技术',
    '电路分析', '电子线路', '电力电子', '电机', '自动控制', '控制理论',
    '检测技术', '传感器', 'plc', 'dsp', '单片机原理',
  ], 'circuit'),
  new GuessRule([
    '大学物理', '物理学', '理论力学', '材料力学', '结构力学', '工程力学',
    '力学', '电磁', '光学', '热学', '量子', '声学', '物理实验', '物理',
    '热力学', '统计物理', '流体力学', '弹性力学', '固体物理',
  ], 'physics'),
  new GuessRule([
    '高等数学', '高数', '微积分', '数学分析', '复变函数', '离散数学', '数学建模',
    '线性代数', '概率', '数学物理', '数学', '常微分', '偏微分', '泛函分析',
    '数值分析', '数值计算', '运筹学',
  ], 'math'),
  new GuessRule([
    '程序设计', '数据结构', '算法', '编程', 'C语言', 'Java', 'Python', '操作系统',
    '编译原理', '软件', '数据库', '计算机', '人工智能', '机器学习', '单片机', '嵌入式',
    '信息安全', '网络空间安全', '面向对象', 'web', '前端', '后端', '深度学习',
    '神经网络', '数据挖掘', '大数据', '云计算', '计算机组成', '微机原理',
    '软件工程', '系统结构', '图形学', '人机交互',
  ], 'cs'),
];

/** 拉平后的关键词表（长度降序），`guess()` 用它做全局优先匹配。 */
class FlatKw {
  kw: string;
  key: string;

  constructor(kw: string, key: string) {
    this.kw = kw;
    this.key = key;
  }
}

const FLAT_KWS: FlatKw[] = ((): FlatKw[] => {
  const out: FlatKw[] = [];
  for (const r of GUESS_RULES) {
    for (const k of r.kws) {
      out.push(new FlatKw(k.toLowerCase(), r.key));
    }
  }
  // 长度降序；长度相同保持声明顺序（sort 在某些引擎上不稳定，故用索引兜底）
  out.sort((a: FlatKw, b: FlatKw): number => {
    if (b.kw.length !== a.kw.length) {
      return b.kw.length - a.kw.length;
    }
    return 0;
  });
  return out;
})();

/** `guess()` 的详细结果：科目 key + 命中的关键词（空串表示没命中任何关键词）。 */
export class GuessResult {
  key: string;
  /** 命中的关键词；'' 表示没匹配到专业科目 */
  hit: string;

  constructor(key: string, hit: string) {
    this.key = key;
    this.hit = hit;
  }
}

export class SubjectLexicon {
  /** 自动模式：按课表当前 / 下一节的课程名推断科目 */
  static readonly AUTO: string = 'auto';

  /** 全部科目；第一项是"通用"（不做学科纠正，只下发通用热词） */
  static readonly SUBJECTS: Subject[] = [
    new Subject('general', '通用', [], []),

    new Subject('math', '高等数学', [
      '极限', '连续', '可导', '导数', '微分', '偏导数', '全微分', '不定积分', '定积分',
      '二重积分', '三重积分', '曲线积分', '曲面积分', '级数', '幂级数', '收敛', '发散',
      '拉格朗日中值定理', '罗尔定理', '柯西中值定理', '洛必达法则', '泰勒公式', '麦克劳林',
      '傅里叶级数', '格林公式', '高斯公式', '斯托克斯公式', '无穷小', '等价无穷小',
      '驻点', '极值', '拐点', '渐近线', '方向导数', '梯度', '散度', '旋度',
    ], [
      F('拉格朗尔', '拉格朗日'),
      F('罗比塔', '洛必达'),
      F('洛比达', '洛必达'),
      F('科西', '柯西'),
      F('太勒公式', '泰勒公式'),
      F('泰乐公式', '泰勒公式'),
      F('付里叶', '傅里叶'),
      F('傅立叶', '傅里叶'),
      F('斯托克思', '斯托克斯'),
      F('渐进线', '渐近线'),
      F('偏倒数', '偏导数'),
      F('可倒', '可导'),
      F('闪度', '散度'),
      F('旋渡', '旋度'),
      F('提度', '梯度'),
      F('住点', '驻点'),
      F('怪点', '拐点'),
      F('等加无穷小', '等价无穷小'),
    ]),

    new Subject('linalg', '线性代数', [
      '矩阵', '行列式', '特征值', '特征向量', '相似对角化', '二次型', '秩', '伴随矩阵',
      '逆矩阵', '转置', '初等变换', '线性相关', '线性无关', '极大线性无关组', '正交',
      '施密特正交化', '齐次线性方程组', '非齐次线性方程组', '克拉默法则', '分块矩阵',
    ], [
      F('行列氏', '行列式'),
      F('特征直', '特征值'),
      F('特征向亮', '特征向量'),
      F('你矩阵', '逆矩阵'),
      F('转至', '转置'),
      F('史密特', '施密特'),
      F('其次线性', '齐次线性'),
      F('非其次', '非齐次'),
      F('线性无官', '线性无关'),
      F('出等变换', '初等变换'),
      F('相似对角话', '相似对角化'),
    ]),

    new Subject('prob', '概率论与数理统计', [
      '随机变量', '分布函数', '概率密度', '正态分布', '均匀分布', '泊松分布', '二项分布',
      '期望', '方差', '标准差', '协方差', '相关系数', '贝叶斯公式', '全概率公式',
      '条件概率', '独立同分布', '大数定律', '中心极限定理', '矩估计', '最大似然估计', '假设检验',
    ], [
      F('伯松', '泊松'),
      F('波松', '泊松'),
      F('协方查', '协方差'),
      F('贝叶思', '贝叶斯'),
      F('全盖率', '全概率'),
      F('大数定率', '大数定律'),
      F('大树定律', '大数定律'),
      F('中心极限定里', '中心极限定理'),
      F('最大自然估计', '最大似然估计'),
      F('举估计', '矩估计'),
      F('正太分布', '正态分布'),
    ]),

    new Subject('physics', '大学物理', [
      '质点', '位移', '加速度', '动量', '角动量', '转动惯量', '简谐振动', '单摆',
      '杨氏模量', '泊松比', '电场强度', '电势', '电容', '磁感应强度', '磁通量',
      '安培环路定理', '高斯定理', '法拉第电磁感应定律', '楞次定律', '霍尔效应',
      '光电效应', '康普顿效应', '德布罗意波', '薛定谔方程', '热力学第一定律', '熵', '麦克斯韦方程组',
    ], [
      F('杨氏模亮', '杨氏模量'),
      F('伯松比', '泊松比'),
      F('愣次', '楞次'),
      F('愣磁', '楞次'),
      F('安陪', '安培'),
      F('霍尔效映', '霍尔效应'),
      F('霍尔校应', '霍尔效应'),
      F('光电效映', '光电效应'),
      F('康普登', '康普顿'),
      F('德布罗依', '德布罗意'),
      F('薛定鹅', '薛定谔'),
      F('薛定恶', '薛定谔'),
      F('麦克斯伟', '麦克斯韦'),
      F('马克思韦', '麦克斯韦'),
      F('磁通亮', '磁通量'),
      F('转动贯量', '转动惯量'),
      F('简些振动', '简谐振动'),
    ]),

    new Subject('circuit', '电路与模电', [
      '电阻', '电容', '电感', '欧姆定律', '基尔霍夫定律', '节点电压法', '网孔电流法',
      '叠加定理', '戴维南定理', '诺顿定理', '谐振', '阻抗', '容抗', '感抗', '三极管',
      '场效应管', '运算放大器', '虚短', '虚断', '负反馈', '放大倍数', '截止频率',
      '傅里叶变换', '拉普拉斯变换',
    ], [
      F('基尔霍父', '基尔霍夫'),
      F('基尔霍弗', '基尔霍夫'),
      F('代维南', '戴维南'),
      F('诺登', '诺顿'),
      F('迭加定理', '叠加定理'),
      F('写振', '谐振'),
      F('谢振', '谐振'),
      F('祖抗', '阻抗'),
      F('容扛', '容抗'),
      F('感扛', '感抗'),
      F('三机管', '三极管'),
      F('场效映管', '场效应管'),
      F('运算发大器', '运算放大器'),
      F('拉普拉丝', '拉普拉斯'),
      F('负反愧', '负反馈'),
    ]),

    new Subject('cs', '程序设计 / 数据结构', [
      '指针', '数组', '结构体', '联合体', '枚举', '递归', '迭代', '时间复杂度', '空间复杂度',
      '链表', '栈', '队列', '二叉树', '平衡二叉树', '红黑树', '哈希表', '图',
      '深度优先搜索', '广度优先搜索', '动态规划', '贪心算法', '回溯', '分治',
      '快速排序', '归并排序', '堆排序', '编译', '链接', '野指针', '内存泄漏',
    ], [
      F('地归', '递归'),
      F('递规', '递归'),
      F('跌代', '迭代'),
      F('哈西表', '哈希表'),
      F('哈西', '哈希'),
      F('二叉数', '二叉树'),
      F('练表', '链表'),
      F('对列', '队列'),
      F('结构题', '结构体'),
      F('联合题', '联合体'),
      F('深度悠先', '深度优先'),
      F('广度悠先', '广度优先'),
      F('谈新算法', '贪心算法'),
      F('回素', '回溯'),
      F('野真针', '野指针'),
      F('时间复渣度', '时间复杂度'),
    ]),

    new Subject('network', '计算机网络', [
      '三次握手', '四次挥手', '子网掩码', '路由器', '交换机', '拥塞控制', '流量控制',
      '滑动窗口', '超时重传', '确认号', '序号', '报文段', '数据报', '以太网',
      '介质访问控制', 'IP地址', '子网划分', '域名解析', '负载均衡',
    ], [
      F('三次我手', '三次握手'),
      F('四次回手', '四次挥手'),
      F('子网眼码', '子网掩码'),
      F('华东窗口', '滑动窗口'),
      F('滑动创口', '滑动窗口'),
      F('报文档', '报文段'),
      F('域明解析', '域名解析'),
      F('介质访问空制', '介质访问控制'),
      F('负载均横', '负载均衡'),
    ]),

    new Subject('english', '大学英语', [
      '一般现在时', '一般过去时', '现在完成时', '过去完成时', '虚拟语气', '非谓语动词',
      '定语从句', '状语从句', '名词性从句', '主谓一致', '倒装句', '强调句',
    ], [
      F('过去完城时', '过去完成时'),
      F('现在完城时', '现在完成时'),
      F('虚拟雨气', '虚拟语气'),
      F('非渭语动词', '非谓语动词'),
      F('定雨从句', '定语从句'),
      F('主谓一至', '主谓一致'),
      F('状雨从句', '状语从句'),
      F('倒装据', '倒装句'),
    ]),
  ];

  static of(key: string): Subject | null {
    for (const s of SubjectLexicon.SUBJECTS) {
      if (s.key === key) {
        return s;
      }
    }
    return null;
  }

  static labelOf(key: string): string {
    const s = SubjectLexicon.of(key);
    return s == null ? '通用' : s.label;
  }

  /**
   * 由课程名推断科目；认不出来返回 general（只做通用纠正）。
   *
   * 【2026-09-28 修正】改为**全局长度优先**匹配（见 `FLAT_KWS` 注释）：
   *   长关键词比短关键词具体，先匹配长的可避免泛词抢答。
   *   实测对照：
   *     「计算机英语」  旧=english（错） → 新=cs（`计算机`3字 > `英语`2字）
   *     「计算机网络」  旧=network       → 新=network（`计算机网络`6字 最长）
   *     「数字信号处理」旧=general（漏） → 新=circuit（补了 `数字信号`）
   */
  static guess(courseName: string): string {
    return SubjectLexicon.guessDetail(courseName).key;
  }

  /**
   * 同 `guess()`，但额外返回**命中的关键词**（设置页用来显示匹配依据）。
   *
   * 【2026-09-30 新增】用户反馈「为什么没有匹配到专业科目？」——
   * 原来只知道"没匹上"，看不出是课名为空、还是关键词表里没这个词。
   * 把命中词一并带出来，设置页就能显示「自动→大学物理（命中：理论力学）」。
   */
  static guessDetail(courseName: string): GuessResult {
    const n = courseName.trim();
    if (n.length === 0) {
      return new GuessResult('general', '');
    }
    const low = n.toLowerCase();
    for (const f of FLAT_KWS) {
      if (low.indexOf(f.kw) >= 0) {
        return new GuessResult(f.key, f.kw);
      }
    }
    return new GuessResult('general', '');
  }

  /** 设置值 → 实际生效的科目 key；auto 时按课程名推断 */
  static resolve(raw: string, courseName: string): string {
    return raw === SubjectLexicon.AUTO ? SubjectLexicon.guess(courseName) : raw;
  }

  /** 设置页下拉项：自动 + 全部科目 */
  static choiceKeys(): string[] {
    const out: string[] = [SubjectLexicon.AUTO];
    for (const s of SubjectLexicon.SUBJECTS) {
      out.push(s.key);
    }
    return out;
  }

  static labelOfChoice(key: string): string {
    return key === SubjectLexicon.AUTO ? '自动（按当前课表）' : SubjectLexicon.labelOf(key);
  }

  /** 全部科目名（供设置页下拉） */
  static labels(): string[] {
    const out: string[] = [];
    for (const s of SubjectLexicon.SUBJECTS) {
      out.push(s.label);
    }
    return out;
  }

  static keys(): string[] {
    const out: string[] = [];
    for (const s of SubjectLexicon.SUBJECTS) {
      out.push(s.key);
    }
    return out;
  }

  /** 该科目的热词表（含通用词），用于云端 ASR 握手下发 */
  static hotwords(key: string): string[] {
    const sub = SubjectLexicon.of(key);
    if (sub == null) {
      return [];
    }
    return sub.hotwords.slice();
  }

  private static apply(text: string, fixes: SubjectFix[]): string {
    let out = text;
    for (const f of fixes) {
      if (f.wrong !== f.right && out.indexOf(f.wrong) >= 0) {
        out = out.split(f.wrong).join(f.right);
      }
    }
    return out;
  }

  /**
   * 纠正一段转写文本。
   * @param text 原始识别文本
   * @param subjectKey 当前科目 key；'general' 或空串时只做通用纠正
   */
  static correct(text: string, subjectKey: string): string {
    if (text.length === 0) {
      return text;
    }
    let out = SubjectLexicon.apply(text, COMMON_FIXES);
    if (subjectKey.length === 0 || subjectKey === 'general') {
      return out;
    }
    const sub = SubjectLexicon.of(subjectKey);
    if (sub == null) {
      return out;
    }
    return SubjectLexicon.apply(out, sub.fixes);
  }

  /**
   * 该科目词库里一共多少条纠正规则（设置页展示用）。
   *
   * 【2026-09-30 修正 · 修「0 条」显示错误】
   * 原实现只数科目自带 `fixes` —— 通用科目是空数组，于是显示「仅用通用纠错（0 条）」，
   * 可实际上每次纠正都先跑 `COMMON_FIXES` 那 17 条，一条不少。
   * 用户看到「0 条」会以为纠错完全没生效。**改成如实统计**：
   * 通用纠错 + 该科目自带纠错。
   *
   * 参数 `includeCommon` 默认 true（设置页就是这么用的）。
   */
  static fixCount(key: string, includeCommon: boolean = true): number {
    const sub = SubjectLexicon.of(key);
    const own = (sub == null || key === 'general') ? 0 : sub.fixes.length;
    return includeCommon ? COMMON_FIXES.length + own : own;
  }

  /** 通用纠错条数（设置页单独展示时用） */
  static commonFixCount(): number {
    return COMMON_FIXES.length;
  }
}