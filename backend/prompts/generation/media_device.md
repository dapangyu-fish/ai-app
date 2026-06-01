# 媒体 / 设备能力 APP 生成指南

适用：相机、图片上传/裁剪、二维码、地图、视频、音频、文件选择、扫描、设备能力组合。

## 先确认能力存在

不要凭 Flutter/网页经验自创字段。先查：

- `lib/json_ui/widget_builder.dart` 的 widget 注册表。
- `lib/json_ui/widgets/` 下对应 widget 源码。
- `lib/json_ui/interpreter.dart` 的 `case '@xxx':` action。
- 相近模板：`templates/framework_quality_camera_inspection.json`、`templates/framework_quality_travel_pass.json`、`templates/framework_quality_course_player.json` 等。

## 页面结构

媒体/设备类 APP 不要只放一个按钮。首屏通常需要：

- 顶部状态/摘要区：当前权限、最近记录、当前设备/模式。
- 主操作区：拍照、选择图片、扫码、播放、定位等。
- 结果区：预览、识别结果、历史记录、错误提示。
- 设置/模式区：开关、滑块、分段控制、筛选。

按标准 iPhone 17 逻辑视口 402x874 设计首屏：摘要卡最多 2 列，主操作区必须在首屏可见。设备控制类不要把首屏全部用状态卡占满。iPhone 13 mini 的 360x780 仅作兼容回归下限，但不能横向裁切关键按钮、二维码、控制卡或导航。

图标名只能使用 `lib/json_ui/widgets/icon_registry.dart` 里注册的名字；相机、地图、设备、传感器、路由、视频等图标不确定时先查源码，不要写未注册 Material icon 名。

## 图片 / 相机 / 上传

- 图片结果要有预览、重试、删除或保存路径。
- 上传头像/图片时，必须确认 action 返回的 URL 绑定到变量，再用于 image/avatar。
- 如果需要视觉素材但不是用户拍摄，读 `backend/prompts/generation/assets.md`。

## 二维码 / 地图 / 视频

- 二维码：需要明确输入内容、生成结果、复制/分享/保存入口。
- 地图：需要标记、说明、列表联动或当前位置状态；不要只放一块空地图。
- 视频/课程：需要播放区、章节/进度、笔记或状态反馈。
- 二维码放在卡片行内时宽高控制在 56-72，必须给文字侧留足宽度；如果空间不足，二维码独占一行。不要让二维码或条码被右侧裁切。

## 权限与失败态

设备能力容易失败。UI 必须提供：

- 空状态 / 未授权状态。
- 操作失败提示。
- 重试或重新选择入口。

不要让按钮点了没有反馈。

## 混合场景

- “相机 + 记录管理”：以 `media_device` 为主，补读 `native_app.md` 的列表/详情/表单。
- “地图 + 行程/票夹”：以 `native_app` 为主，补读本文件的地图/二维码段。
- “视频课程”：以 `native_app` 或 `media_device` 为主均可，取决于用户更强调内容管理还是播放体验。
