# 实况窗可视化工具

## 简介

本工具是一款面向开发者的实况窗参数配置可视化工具，旨在降低开发门槛，帮助开发者快速了解实况窗展示效果、协助完成接入方案和体验设计、提升实况窗接入开发效率。

## 界面展示

工具界面分为三个区域，具体功能如下：

- **左侧：实况窗参数配置区** </br>开发者可在该区域按需选择实况窗卡片和胶囊模板，并在各输入框填入实况窗业务参数，完成可视化配置。

- **中间：实况窗卡片预览区** </br>该区域实况窗卡片及胶囊将根据左侧参数配置区的输入值，实时同步展示实况窗。

- **右侧：实况窗参数源码区** </br>系统将自动解析配置区输入值，生成API接口参数源码。开发者可一键复制代码片段到项目代码中使用。

| 实况窗参数配置区 | 实况窗卡片预览区 | 实况窗参数源码区 |
|-----------------|----------------|-------------------|
| ![](./screenshots/params_area.png) | ![](./screenshots/preview_area.png) | ![](./screenshots/code_area.png) |

## 使用说明

开发者需要将[实况可视化工具.html文件](./LiveViewDevelopmentAssistant.1.0.100_Beta.html)下载至本地，使用浏览器打开运行。

### 实况窗参数配置区

1.开发者选择实况窗卡片模板和胶囊模板类型，参数配置区会分别加载该卡片模板和胶囊模板支持的API字段，卡片预览区会显示对应模板实况窗卡片及胶囊。

| 实况窗卡片模板 | 实况窗胶囊模板 | 实况窗预览效果 |
| ------------- | ------------- | ------------- |
|![](./screenshots/select_layoutType.png) | ![](./screenshots/select_capsule.png) | ![](./screenshots/preview.png) |

2.固定区内容等API字段，支持显示多个文本，并支持设置字体颜色。当多个文本设置字体颜色时，所有设置字体颜色的文本仅支持设置同一种颜色。
</br>![](./screenshots/content.png)

3.辅助区图片等API字段，支持点击后选择传入图片，体验实况窗显示效果。
</br>![](./screenshots/select_image.png)

4.进度百分比等API字段，支持滑动修改数值。
</br>![](./screenshots/progress.png)

### 实况窗卡片预览区

1.支持实况窗UI槽位与API字段的高亮关联展示。开发者将鼠标悬停于实况窗预览区的任意 UI 元素上，系统会自动高亮标注该元素及其对应的 API 字段。
</br>![](./screenshots/map.png)

2.双击预览区的实况窗UI槽位，可在参数配置区及源码区快速定位对应API字段。

### 实况窗参数源码区

1.开发者可点击复制按钮，复制实况窗参数源码示例，拷贝至工程项目中使用。
</br>![](./screenshots/copy.png)

2.实况窗云侧参数源码，需要根据云侧[创建实况窗约束](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/push-scenariozed-api-request-param#section441214411235)适配修改，包括：
 - event对创建实况窗模板类型的约束。
- 创建实况窗时，对于不同的布局类型，需要在支持携带占位符的字段中填入至少一次{{status}}占位符的约束。
3.开发者可参考[云侧创建代码示例](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/push-scenariozed-api-request-example)实现项目云侧创建实况窗。

## 约束与限制

1.本工具实况窗显示效果与真机存在部分能力差异，具体差异如下：

- 工具不支持天气动效背景

- 工具内实况窗预览所采用的实况胶囊为三孔样式设计，其显示效果与市面部分机型真机实况窗存在差异。

- 工具的实况窗字体使用运行设备的默认字体，可能与真机存在一定差异，建议配置使用[HarmonyOS Sans 字体](https://alliance-communityfile-drcn.dbankcdn.com/FileServer/getFile/cmtyManage/011/111/111/0000000000011111111.20251218140934.53495826757772194907330661120530:50001231000000:2800:4C6B270E72171539BE152974FA4BAB1C2C63CB46549E9DC13D66B6F2BBC574CA.zip?needInitFileName=true)

2.建议使用以下浏览器运行实况窗可视化工具：

- Google Chrome 144.0及以上

- Microsoft Edge 133.0及以上
