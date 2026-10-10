# 实况窗demo（华为官方示例）

⚠️这是**华为官方示例项目**（Copyright (c) 2023 Huawei Device Co., Ltd.），
**不在主工程的 `modules` 列表里**（主工程只有 `entry`），
即当前**没有启用**它，保留仅作参考。

## 库里缺了什么

| 缺失 | 原因 |
|---|---|
| `实况窗各场景参数与模板映射关系指导.xlsx` | **41MB**，参数映射表格文档 |
| `screenshots/` | **11MB**，官方界面截图 |

两者与代码无关，且使仓库从 5.9MB 涨到 57MB —— 直接导致首次 `git push`
被 GitHub 连接重置（`Connection reset by peer` / `Broken pipe`）。

需要时从华为官方示例仓库获取：
<https://gitee.com/harmonyos_samples/live-view>

## 许可

本目录内容遵循它自带的 `LICENSE`（Huawei Device Co., Ltd.），
**与主工程的 GPL-3.0 不同** —— 引用本目录代码时请注意它的原始条款。
