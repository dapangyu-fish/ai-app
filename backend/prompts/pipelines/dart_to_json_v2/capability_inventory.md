# Capability Inventory

生成 Dart 设计稿前，必须把 MyApp 能力当作硬边界。

可用 UI 能力：

- 页面和导航：多 screen、screen 切换、返回、弹窗、bottom sheet、tabs。
- 布局：column、row、stack、container、padding、safe area、scroll、list/grid、spacer、divider。
- 文本和图标：text、rich text、icon、badge、chip、button、icon button。
- 表单：input、textarea、switch、checkbox、slider、segmented control、dropdown、date/time 风格选择。
- 媒体：image、avatar、远程 asset、asset manifest 中声明的图片、音频、视频占位能力。
- 状态：全局/页面变量、列表数据、筛选、排序、搜索、计数、收藏、开关、简单计算。
- 动作：set state、append/remove/update item、navigate、open url、copy、toast、request permission、upload current app 请求。
- 账号/IM/设备：只能使用框架已暴露的 auth、profile、IM、media upload、permission 桥；必须做好未登录保护。
- 游戏：只能使用 JSON game/flame runtime 已支持的 entity、sprite、animation、collision、timer、input、camera、tile map、particle 等能力。

禁止能力：

- 任意 Flutter SDK 插件。
- 自定义 Dart class 作为运行时逻辑。
- CustomPainter、RenderObject、PlatformChannel、FFI。
- 真实网络 SDK、数据库 SDK、文件系统任意读写。
- JSON-DSL validator 不认识的 widget 字段和 action 字段。
- 依赖运行时编译 Dart 或动态下发二进制。

如果某个设计无法表达，必须降级为 JSON-DSL 可表达的交互，而不是在 Dart plan 中保留不可转换能力。

