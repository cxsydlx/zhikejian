# 第三方授权声明 / THIRD-PARTY NOTICES

本文件逐源记录 dictionary.xsheep.cn 使用的第三方数据与软件。
**「是否修改」一栏是 CC BY-SA 4.0 第 3(a) 条明确要求的举证项，不可删除。**

---

## 1. 英文释义与音标 —— Open English WordNet

| 项 | 内容 |
|---|---|
| **名称** | Open English WordNet |
| **来源** | https://github.com/globalwordnet/english-wordnet |
| **许可** | Creative Commons Attribution 4.0 International (CC BY 4.0) |
| **上游** | 派生自 Princeton WordNet |
| **是否修改** | **否**。`build_lexicon.py` 只做格式转换（YAML → SQLite），不改写、不删减、不追加任何释义文字 |
| **署名要求** | **必须同时署名 Princeton WordNet 与 Open English Wordnet 团队** |

原文引用（`LICENSE.md`）：

> This resource is derived from Princeton WordNet under the WordNet License
> and further developed under the Creative Commons Attribution 4.0
> International License. You may share and adapt this resource providing
> attribution is given to both Princeton WordNet and the Open English
> Wordnet team.

**衍生义务**：因 OEWN 自身是 CC BY 4.0，本项目对其内容的再分发同样需保留上述署名。

---

## 2. Princeton WordNet（OEWN 的上游）

| 项 | 内容 |
|---|---|
| **名称** | Princeton WordNet |
| **来源** | https://wordnet.princeton.edu/license-and-commercial-use |
| **许可** | WordNet License（专有许可，非 OSI 认证开源） |
| **是否修改** | **否**（经由 OEWN 间接使用） |
| **限制** | 版权**始终**归普林斯顿大学所有；**不得**用 "Princeton" 名义为本项目做广告宣传 |

---

## 3. 发音 —— espeak-ng

| 项 | 内容 |
|---|---|
| **名称** | espeak-ng |
| **来源** | https://github.com/espeak-ng/espeak-ng |
| **许可** | GPL-3.0-or-later（**仅软件**） |
| **是否修改** | 否，未修改其代码 |
| **用法** | 以**独立进程命令行调用**（`espeak-ng -v en-gb/-v en-us -w out.wav word`），**未链接其代码** |

**为什么 GPL 不传染本项目**：GPL-3.0 第 4 条第 2 款仅规制「程序作品」。
espeak-ng 采用**共振峰合成**（formant synthesis），不使用任何人声录音样本，
其输出音频由算法参数生成，**不构成 GPL 意义上的衍生作品**。
本项目仅以独立进程调用，未将其代码链接进本项目，故不触发 copyleft。

维护者 Valdis Vitolins 在官方论坛的明确背书（espeak-ng 官方讨论区）：

> "It allows any usage like all really free/libre/open source software.
>  Obligations/limitations apply to attribution and changes of source
>  code/configuration files."

**⚠️ 硬性红线（务必遵守）**：**绝不使用 MBROLA 音色**。
espeak-ng 的音色列表里 `mb/*`、`us-mbrola-*` 等属于 MBROLA 的 voice data，
那些文件是**非商业授权**（仅限 non-commercial, non-military）。
本项目只传 `-v en-gb` / `-v en-us`，它们解析到 `gmw/en`（英）、`gmw/en-US`（美）
两个**原生**音色，天然规避。修改本项目时不得改为 `-v mb-en1` 之类。

---

## 4. 用户提交的释义改写

| 项 | 内容 |
|---|---|
| **许可** | CC BY-SA 4.0（由提交者在提交时显式同意） |
| **来源** | 本站用户通过 `PUT /api/v1/word` 提交 |
| **是否修改** | **是**（属改用素材） |
| **归属** | 修改部分著作权归提交者（《著作权法》第十三条：注释、整理已有作品产生的作品，著作权由整理人享有，但不得侵犯原作品著作权） |

**系统已留存的举证材料**（`user_edit` 表字段）：

| 字段 | 作用 |
|---|---|
| `created_at` | 时间戳 —— 证明何时修改 |
| `submitter` | 提交者标识 —— 证明谁修改 |
| `license` | 固定为 `CC-BY-SA-4.0` —— 证明以何种授权发布 |

**ShareAlike 义务的准确边界**（避免误解，此处为条款文义）：

| 场景 | 是否触发 ShareAlike |
|---|---|
| 网页上逐词展示释义 | **否**。这属于「提供检索服务」，未「分享改用素材」，也未构建「纳入相当部分内容」的数据库（CC BY-SA 4.0 第 4 条） |
| 用户提交的改写内容对外可见 | 这些**用户贡献的改用素材**须以 CC BY-SA 授权 |
| **本网站的源代码** | **否**。CC BY-SA deed 第 2(a)(2) 条注明："Merely changing the format never creates a derivative." 网站源码保持私有是合规的 |
| 批量下载全部词库 | **是**。分发含改用素材的数据库会触发第 4 条 |

∴ **本项目刻意不提供全库 CSV/JSON 下载**，仅提供逐词检索与（限内网的）离线词表接口。

---

## 5. ⚠️ 刻意未采用的数据源：ECDICT 的释义

| 项 | 内容 |
|---|---|
| **名称** | ECDICT |
| **来源** | https://github.com/skywind3000/ECDICT |
| **其许可** | MIT License, Copyright (c) 2025 Linwei |
| **本项目使用情况** | **仅参考其词频/词性/屈折变化等语言学标注字段，不使用其释义** |

**为什么不用它的释义**（这是本项目最重要的合规判断）：

ECDICT 的 LICENSE 是 MIT，但 MIT 协议原文规制的是「this **software** and associated
documentation files」—— **`ecdict.csv` 是数据文件，不是软件，也不是文档**。
而作者本人在项目 wiki（`wiki/双解释义`）中**明确列出释义的实际来源**：

| 来源 | 性质 |
|---|---|
| TheFreeDictionary.com | 商业聚合站 |
| linguee.com | 商业（DeepL 旗下） |
| Babylon | 商业词典 |
| Google / Google Cloud Translation | 商业翻译 |
| Urban Dictionary | 商用需授权 |
| foldoc.org | 商业 |
| 屌丝词典 diaosi | 该仓库**无 LICENSE 文件** |
| cdict-1.0-1.rpm | 开源，但上游来源不明 |

这些站点本身聚合了韦氏、朗文、牛津等**商业出版社**的内容。
**MIT 许可只能约束作者自己拥有的权利，无法覆盖其实际上不拥有的上游内容** ——
这在著作权法上称为**授权链断裂**（license laundering）。

同时实测确认：`ecdict.csv` 的 `audio` 列**完全为空**（抽查 12281 行，0 条非空），
仓库内无任何音频文件。

**结论**：若要商用或公开部署，使用 ECDICT 的 `translation`（中文释义）、
`collins`（柯林斯星级）、`oxford`（牛津 3000）字段存在真实的法律风险。
本项目改用 OEWN（CC BY 4.0，来源链清晰）承担英文释义。

---

## 6. 本项目自身的许可

见仓库根目录 `LICENSE`（GPL-3.0）。

---

## 7. 免责声明

本站释义由自动化流程从上述开源词库转换而来，**可能存在错译、遗漏或过时**。
内容仅供学习参考，不作为翻译或学术依据使用。
商用或大规模分发前，请自行确认上述授权条款是否满足你的使用场景。

**法律状态说明**：本文档是工程实践记录，**不是法律意见**。
以下两点建议在商用前咨询执业律师：

1. ECDICT 释义的真实权利状况（本文档只指出了瑕疵，未判定其可用性）
2. 中国法下「在线词典逐词展示」是否构成信息网络传播 —— 目前无明确判例，
   本文档采用的是条款文义 + 行业惯例的解读