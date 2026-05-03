# 回归测试手册 — regression-test JSON-APP

配套 JSON 文件：`templates/regression-test.json`

本手册逐项列出 **85 个测试点**，给出操作步骤、**预期结果**、**不预期结果**（满足这些就算回归）。

---

## 如何运行

1. 启动 Flutter app（`flutter run` 或已编译版本）
2. 在欢迎页用 file picker 加载 `templates/regression-test.json`
3. 进入 home 看到 17 类共 85 个测试点的列表
4. 点击任一卡片进入对应测试 screen
5. 测完点屏幕顶部的 ← 返回测试列表（或 AppBar 默认返回箭头）

> **依赖说明**：本测试套件 `dependencies` 引用 `common-ui ^1.0.0`，启动时框架会从 registry 自动拉取（要联网）。
>
> **HTTP 测试**：使用 `httpbin.org` 公网端点（HTTPS）。
>
> **持久化测试**：使用 App 文档目录与 SharedPreferences；杀进程后重启数据应仍在。

---

## 通用预期 / 不预期

每个测试都隐含以下规则：
- ✅ **预期**：屏幕能正常渲染；返回按钮能回 home；不出现 RenderFlex / unbounded 异常对话框
- ❌ **不预期**：
  - 红屏 / overflow / RenderFlex 异常
  - `{{ }}` 字面量出现在文本里（说明模板没解析）
  - "未知控件类型" / "未知内置函数" 警告（除了 Q.3 边界测试故意触发的）
  - 闪退 / 卡死 / 无响应

下文每个测试点只列**该项独有的**预期 / 不预期。

---

## A. 基础 widget（main 既有）

### A.1 text 控件
**操作**：观察 6 行文字；连点"count +1"按钮 3 次  
**预期**：文字按 size/color/bold/center 不同样式呈现；count = 3  
**不预期**：所有文字都同一样式；count 不变

### A.2 button 控件
**操作**：分别点 5 个按钮  
**预期**：filled/outlined/text 三种 variant 视觉清晰区分；icon 按钮带图标；disabled 按钮灰色不响应；自定义颜色按钮粉底白字圆角更大  
**不预期**：disabled 按钮触发 toast；自定义颜色无效；icon 不显示

### A.3 input 控件
**操作**：在输入框打字  
**预期**：下方 text 实时反映输入；点"清空"后输入框清空  
**不预期**：bind 不同步；clear 后仍显示旧字

### A.4 list 控件
**操作**：(1) 默认 5 项；(2) 点"切到空数据"应显示 emptyText；(3) 重置后，下拉应触发 onRefresh 插入"刷新插入项"  
**预期**：列表正常滚动；空状态有图标+文字；下拉有 RefreshIndicator 圈圈，松手后多一项  
**不预期**：空状态白屏；下拉无反应；插入后未刷新

### A.5 container 控件
**操作**：观察三种 layout  
**预期**：row 三段分散（左/中/右）；column 三行垂直；stack 文字+右上角 ❤  
**不预期**：layout 不生效（全部上下排列）；stack 子项错位

### A.6 divider 控件
**操作**：观察  
**预期**：两段文字之间有一条灰色横线  
**不预期**：无横线 / 横线占满左右带 padding 错位

### A.7 image 控件
**操作**：观察两张图  
**预期**：第一张是 httpbin 的灰白 PNG；第二张（无效 URL）显示损坏图标占位  
**不预期**：第一张白框；第二张红屏崩溃

### A.8 image_picker 控件
**操作**：点虚框 → 选图  
**预期**：选完虚框变成所选图片；下方 text 显示路径  
**不预期**：点击无反应；权限弹框被吃；路径不写入 bind

### A.9 spacer 控件
**操作**：观察灰色行  
**预期**：左侧 / 右侧两段文字被推到行的两端  
**不预期**：两段文字仍贴在一起

### A.10 switch 控件
**操作**：拨开关  
**预期**：开关切换时下方 text 显示 true/false  
**不预期**：拨动无效；text 不更新

### A.11 video 控件 *（占位）*
**预期**：进入后显示"开发中"黄底卡片，说明无内置视频源  
**不预期**：直接报错或白屏（没有友好提示）

### A.12 ref 控件 *（占位）*
**预期**：显示"开发中"，说明依赖功能在 O 类已覆盖  
**不预期**：报错

---

## B. 新 widget — 基础类

### B.1 icon 控件
**操作**：观察 5 个图标  
**预期**：home/search/favorite/settings 显示对应图标；最后一个不存在的回退为 ❓ help_outline 红色  
**不预期**：不存在的图标空白或闪退

### B.2 card 控件
**操作**：点第一张卡片  
**预期**：可点卡片有水波纹动画 + toast；扁平卡片无阴影；row 卡片图标在左、文字在右  
**不预期**：点击无水波纹（说明 InkWell 没生效）；阴影/圆角丢失

### B.3 checkbox 控件
**操作**：勾选第一项；尝试点第二项  
**预期**：第一项 label 也能点（不只复选框本体）；状态下方实时显示；第二项始终不可点  
**不预期**：disabled 仍可点；label 不响应点击；state 不更新

### B.4 expanded 控件
**操作**：观察搜索框行  
**预期**：图标 - 输入框 - 按钮，输入框自动撑满中间  
**不预期**：输入框很小；图标按钮被压扁

### B.5 loading 控件
**操作**：观察 4 个 indicator；点 "进度 +0.1" 几次  
**预期**：第一个圆形不停旋转；第二个圆形显示部分弧线；linear 线性同上；点按钮后第二个/第四个进度增加  
**不预期**：所有都不动；value=null 的反而不旋转

### B.6 dropdown 控件
**操作**：(1) 点第一个 dropdown 选"女"；(2) 点第二个选"选项 B"；(3) 点"外部清空 bind"  
**预期**：选择后 bind 同步；外部清空后 dropdown 也清空（验证响应式 — P0 修复点）  
**不预期**：清空 bind 后 dropdown 仍显示原选项（说明 P0 fix 失效）

### B.7 radio 控件
**操作**：在两组 radio 间切换选项  
**预期**：选中项高亮；下方 text 反映；两组 radio 共享同一 bind  
**不预期**：能多选；选中无视觉变化

### B.8 wrap 控件
**操作**：观察按钮排列  
**预期**：8 个按钮自动换行排列；间距均匀  
**不预期**：按钮溢出屏幕；不换行

### B.9 grid 控件
**操作**：点任一格子  
**预期**：3 列 9 格子；点击 toast 显示 "点了第 N 项"  
**不预期**：点击 toast 显示 "点了第 {{ loop.index }} 项"（字面量未解析 → P0-5 修复失效）；列数错；崩溃

### B.10 progress 控件
**操作**：点"重置 0"再点 "+0.1" 几次（在 B.5 页面或这里都可以）  
**预期**：上方进度条按 value 变化；下方 indeterminate 进度条不停滚动  
**不预期**：进度不更新；indeterminate 也是静止的

---

## C. 新 widget — 布局类

### C.1 padding 控件
**操作**：观察三个不同色背景的容器  
**预期**：第一个文字四面 24px 内陷；第二个左右 32 上下 8；第三个上 24 下 4 左 16  
**不预期**：所有 padding 一样大；padding 不生效

### C.2 center 控件
**操作**：观察紫底容器  
**预期**：文字水平垂直居中  
**不预期**：左对齐 / 顶部对齐

### C.3 align 控件
**操作**：观察橙底大容器  
**预期**：粉色 ❤ 在右下角  
**不预期**：在左上 / 居中

### C.4 flexible 控件
**操作**：对比上下两个 row  
**预期**：上方 fit=loose 行短文字保持自然宽度；下方 fit=tight 行红色文字撑满中间所有剩余空间  
**不预期**：两行视觉一样；tight 不撑满

### C.5 stack 控件
**操作**：观察灰色容器  
**预期**：底层 200×120 灰底 + 右上 ❤ + 左下 ℹ  
**不预期**：两个图标重叠在一起；位置不正确

---

## D. 新 widget — 表单/picker

### D.1 slider 控件
**操作**：拖滑块  
**预期**：拖动时下方值实时更新；松手时值停在该位置；分 10 段（divisions）  
**不预期**：拖不动；松手回弹；text 不更新

### D.2 date_picker 控件
**操作**：点输入框 → 选 2026-06-15  
**预期**：弹日期选择器；选完关闭后输入框显示 "2026-06-15"  
**不预期**：弹不出 picker；选完不写入

### D.3 time_picker 控件
**操作**：点输入框 → 选 14:30  
**预期**：弹时间选择器；选完关闭后显示 "14:30"  
**不预期**：弹不出 / 不写入

### D.4 tooltip 控件
**操作**：长按蓝色 ℹ 图标  
**预期**：约 1 秒后显示"这是一个 tooltip 示例"气泡  
**不预期**：长按无反应

---

## E. 新 widget — 装饰类

### E.1 chip 控件 ⚠️ P0-1 修复点
**操作**：(1) 点第一个 chip 删除按钮 → toast；(2) **反复点击 choice 收藏 chip**；(3) 点 filter 各项加减  
**预期**：(1) toast；(2) 第一次点选中（粉色）写入 "star"；**第二次点取消选中**写入 null；可反复切换（**P0-1 修复重点**）；(3) filter 列表多选可独立加减  
**不预期**：(2) 取消选中失败（永远高亮）→ P0-1 失效；filter 选中后没法取消

### E.2 badge 控件
**操作**：点 "count +1" 几次；点 "count = 0"  
**预期**：>0 显示数字；=0 自动隐藏；>99 显示 "99+"；NEW 角标始终显示  
**不预期**：count=0 仍显示 "0"；超过 99 显示原数

### E.3 avatar 控件 ⚠️ P0-4 修复点
**操作**：观察 4 个头像  
**预期**：(1) dicebear 网络头像；(2)(3) 显示首字母 "张" "B"；(4) **无效 URL 显示首字母 "失"（P0-4 修复重点）**  
**不预期**：(4) 显示空圆圈而无 fallback → P0-4 失效

### E.4 rich_text 控件
**操作**：观察两段文字  
**预期**：第一段数字 "42" 加粗粉红、"8" 加粗蓝；第二段斜体 / 下划线 / 删除线分别正确  
**不预期**：所有 span 同一样式

### E.5 inkwell 控件
**操作**：分别点 / 长按 / 双击紫色方块  
**预期**：水波纹动画；分别 toast "tap" / "long press" / "double tap"  
**不预期**：水波纹缺失；同一 toast 触发多次

---

## F. 新 widget — 手势类

### F.1 gesture_detector 控件
**操作**：在粉色方块上分别向 4 个方向快速滑动  
**预期**：下方 log 显示 "← 左滑" 等  
**不预期**：log 不变 / 错方向

### F.2 dismissible 控件
**操作**：每一项向左滑  
**预期**：滑动有红色背景露出；松手后该项被删除  
**不预期**：滑不动 / 删除后界面闪屏 / 抛 "duplicate key" 异常

### F.3 draggable 控件
**操作**：按住橙色方块拖动  
**预期**：原位置变半透明；指尖跟着 feedback widget；松手归位  
**不预期**：按住无反应；feedback 错位；松手报错（**P0 修复点**：旧 Draggable&lt;dynamic&gt; 现已为 &lt;Object&gt;）

### F.4 refresh 控件
**操作**：在内列表上下拉  
**预期**：出现 RefreshIndicator；松手触发 onRefresh，"刷新次数" +1  
**不预期**：下拉无反应

---

## G. 新 widget — 结构类

### G.1 tab_view 控件
**操作**：在 3 个 tab 间切换  
**预期**：上方 tab bar，下方内容区切换（首页/消息内容/我的）；切换计数 +1  
**不预期**：tab bar 不响应；onTabChange 不触发或多触发（监听器泄漏）

### G.2 app_bar 独立 widget
**操作**：点蓝条上的 search/menu 图标  
**预期**：分别 toast 对应消息  
**不预期**：图标点不动 / actions 不显示

---

## H. 新 widget — 重型/外部依赖

### H.1 webview 控件
**操作**：进入后等加载  
**预期**：加载 example.com 的 "This domain is for use in illustrative examples..." 页面  
**不预期**：白屏超 10 秒 / 报错弹窗（多半是网络问题，可忽略）

### H.2 qr_code 控件
**操作**：用其他设备扫码  
**预期**：扫出 GitHub 仓库 URL  
**不预期**：二维码花掉/扫不出

### H.3 chart 控件
**操作**：观察三种图  
**预期**：line/bar/pie 都正确渲染；line 有曲线和点；bar 有 5 根柱+底部 Mon/Tue/...；pie 三色分块  
**不预期**：图变白板 / 数据不对

### H.4 map 控件 *（占位）*
**预期**：进入显示"开发中"黄底卡片  
**不预期**：直接渲染地图（如果你想自己测，按提示加 widget）

### H.5 camera 控件 *（占位）*
**预期**：进入显示"开发中"  
**不预期**：直接尝试启动相机（无权限会崩）

---

## I. 屏幕级配置

### I.1 screen.layout=stack
**操作**：观察整屏  
**预期**：左上角"返回"按钮；右下角蓝圆 + 号浮动按钮；中间蓝底说明文字  
**不预期**：浮动按钮在中间或丢失

### I.2 screen.tabs（底部导航）
**操作**：在底部 3 个 tab 间切换  
**预期**：底部 BottomNavigationBar 切换；body 整个换；返回按钮回 home  
**不预期**：底部栏不显示；切换无效

> ⚠️ **已知限制**：tab 页面内的 screen.appBar / screen.drawer 配置**不生效**（_TabScreenView 写死了 AppBar）—— 这是 batch-7 留下的限制，已在 review 中列为 P1 issue

### I.3 screen.appBar
**操作**：观察顶部紫色 AppBar；点右侧 search/menu  
**预期**：紫底白字 AppBar，标题"自定义 AppBar"居中；点 actions toast  
**不预期**：仍是默认 AppBar；actions 不显示

### I.4 screen.drawer
**操作**：(1) 点左上角 ☰ 图标；或 (2) 从屏幕左边缘向右滑动  
**预期**：弹出侧边抽屉，包含紫色 header + 3 个 ListTile；点"退出"回 home  
**不预期**：抽屉弹不出；自动 ☰ 没出现（说明 buildAppBar 没把 leading 留空）

---

## J. 模板与表达式

### J.1 {{ }} 模板
**操作**：观察 4 行文字  
**预期**：所有 `{{ ... }}` 都被替换成实际值（"Alice"、"Beijing"、"30"、"Alice 来自 Beijing"）  
**不预期**：仍出现 `{{ ... }}` 字面量

### J.2 jsonlogic 标准 op
**操作**：依次点 3 个按钮  
**预期**：result 显示 10 / "大" / true  
**不预期**：result 不更新；显示对象字面量

### J.3 jsonlogic 自定义 op
**操作**：依次点 6 个按钮  
**预期**：依次 `HELLO WORLD` / 11 / 8 / 4 / [1,1,2,3,4,5,6,9] / 7  
**不预期**：result 始终空；某个 op 报"未知 op"

---

## K. 控制流 actions

### K.1 @if
**操作**：(1) 点 "n +3" 两次；(2) 点 "运行 @if"  
**预期**：n=6 后 log = "n > 5 走 then"；n<=5 时 log = "n <= 5 走 else"  
**不预期**：log 不变 / 走错分支

### K.2 @while
**操作**：点"重置"，再点 while  
**预期**：n 从 0 跳到 10；过程瞬间完成  
**不预期**：n 不变 / 应用卡死（说明 max_iterations 防御失效）

### K.3 @for_each
**操作**：先点"运行"清空，再点"再加 for_each"  
**预期**：log = "#0:10 #1:20 #2:30"  
**不预期**：log 字面量含 `{{ var }}`（说明嵌套 jsonlogic 表达式没递归求值）

### K.4 @loop_by_num
**操作**：点 "loop 5 次"  
**预期**：n 每次 +5  
**不预期**：n 不变

### K.5 @try_catch
**操作**：点"运行"  
**预期**：log = "catch: ..."；err 字段含异常  
**不预期**：抛到 UI；log 不更新

### K.6 @parallel
**操作**：点"运行"  
**预期**：约 800ms（最长那个）后出 toast  
**不预期**：约 1900ms+（说明串行）；toast 不出

### K.7 @delay
**操作**：点按钮  
**预期**：约 1.5 秒后出 toast  
**不预期**：立即出 toast / 不出

---

## L. 数据 actions

### L.1 @set
**操作**：依次点 3 个按钮  
**预期**：str = "hello" → num = 42 → num = 8（jsonlogic 求值正确）  
**不预期**：num 显示 "[Object Object]"（jsonlogic 没求值）

### L.2 @http_get / @http_post
**操作**：分别点 GET / POST 按钮  
**预期**：约 1-3 秒后 resp 显示 JSON 字符串前 200 字（含 "url"、"args" 等字段）  
**不预期**：resp 始终空；超过 30 秒无响应（**联网问题**）

### L.3 @json_decode / @json_encode
**操作**：先 encode，再 round-trip  
**预期**：encoded = `{"a":1,"b":[2,3]}`；round-trip 后还是同一字符串  
**不预期**：编码出错；round-trip 后字段错位

### L.4 @str_* 系列
**操作**：依次点 8 个按钮  
**预期**：result 依次为 `HELLO WORLD` / `hello world` / `hi` / `hello Flutter` / `abababab` / `0005` / `138****8000` / `Hi`  
**不预期**：某个 result 为空（说明该 action 未实现）

### L.5 @list_* 系列
**操作**：观察初始；依次点击 add/remove_at/remove/insert/sort/shuffle/...  
**预期**：列表按操作语义变化；新增的 `@list_remove` 删掉所有 1（结果含 [3,4,5,9,2,6]）  
**不预期**：@list_remove 报"未知函数"（说明 batch-2 的新 action 没注册）

### L.6 @random / @uuid
**操作**：依次点  
**预期**：随机数 1-100；8 字母数字；6 数字；标准 UUID 格式 xxxx-xxxx-...；从列表随机选一个  
**不预期**：每次结果一样（说明 random 退化）

### L.7 @timestamp / @date_format
**操作**：先点 timestamp，再点 format  
**预期**：先显示 13 位时间戳（如 1745020800000）；再显示当前日期格式化  
**不预期**：format 显示原始时间戳

---

## M. UI actions（含 5 个新增 ⭐）

### M.1 @show_toast
**操作**：点单次；点"5 次堆叠"  
**预期**：单次出现 1 个 toast 2 秒后消失；连点 5 次出现 5 条堆叠（最多 20 条限制）  
**不预期**：5 次只出最后 1 条

### M.2 @show_dialog
**操作**：点取消 / 确定 各试一次  
**预期**：result 显示 false / true  
**不预期**：result 始终空

### M.3 @show_input_dialog
**操作**：弹框输入 "Bob" 确定  
**预期**：「Bob」显示在 text 里；点取消 result 为 null/空  
**不预期**：输入丢失

### M.4 @show_choice_dialog ⭐
**操作**：分别点 3 个按钮  
**预期**：result 依次显示 "save" / "discard" / "cancel"；按钮样式 primary（实色蓝）/ danger（红）/ text（普通）  
**不预期**：所有按钮同一样式；result 不更新

### M.5 @show_snackbar ⭐
**操作**：点按钮，然后点 SnackBar 上的"撤销"  
**预期**：底部黑色 SnackBar 4 秒；点撤销出 "已撤销" toast  
**不预期**：SnackBar 不弹；撤销按钮无效

### M.6 @show_date_picker（命令式）⭐
**操作**：点按钮选日期  
**预期**：弹日期选择器；选完写入 result  
**不预期**：与 D.2（声明式）行为不一致

### M.7 @show_time_picker（命令式）⭐
**操作**：点按钮选时间  
**预期**：弹时间选择器；选完写入 result  
**不预期**：同上

### M.8 @show_bottom_sheet ⭐
**操作**：点按钮，下拉关闭  
**预期**：底部弹出 sheet，圆角顶部，可下拉关闭，可点空白关闭  
**不预期**：点空白不关；sheet 无圆角

---

## N. 持久化 actions

### N.1 @storage_*
**操作**：set → get → 杀进程重启 → get  
**预期**：第二次 get 仍能拿到（SharedPreferences 持久化）  
**不预期**：杀进程后 get 为空

### N.2 @file_*
**操作**：依次 write_json → exists → read_json → append → list → delete  
**预期**：exists = true；read 返回写入对象；list 含 data.json 和 log.json；delete 后 exists = false  
**不预期**：write 无声失败；read 返回 null

### N.3 @db_* (drift)
**操作**：依次 create_table → insert × 2 → query → count → update → delete → kv_set → kv_get  
**预期**：query 返回 [{Alice, 30}, {Bob, 25}]；count = 2；update 后 Alice age=31；delete 后只剩 Alice；kv_get 返回 "bar"  
**不预期**：query 返回空；count 报错；update where 子句不支持

---

## O. 自定义函数 + 依赖

### O.1 @global.func
**操作**：点两次（不同参数）  
**预期**：依次显示 "Hi Alice, double = 14" / "Hi Bob, double = 8"  
**不预期**：result 字面量含 `{{ params.* }}`（params 没注入）

### O.2 @common-ui.func
**操作**：依次点 showSuccess / confirm / formatSize  
**预期**：第一个出绿色 ✅ toast；第二个弹确认框，回填 true/false；第三个 result = "1.18 MB"  
**不预期**：报"未找到依赖函数 @common-ui.xxx"（说明依赖加载器没工作）

---

## P. 循环上下文 action（关键 — P0-5 验证点）

### P.1 loop.* 在 action 的 List 字段里
**操作**：点列表中"苹果"项 → 弹出 choice dialog → 点"查看详情"  
**预期**：result 显示 `view-a`（id 是真实 a/b/c，不是字面量 `{{ loop.item.id }}`）  
**不预期**：result 是 `view-{{ loop.item.id }}` → **P0-5 List 递归修复失效**

> 这是验证 P0-5 修复的关键测试 —— 修复前 6 个 widget 的本地 helper 不递归 List，导致 List 内的 `{{ loop.* }}` 模板没在 build 阶段烘焙；修复后用共享 action_helper 应正确解析。

---

## Q. 边界与错误

### Q.1 空 list emptyText
**预期**：显示空状态图标 + "🎉 暂无数据"  
**不预期**：白屏 / 异常

### Q.2 HTTP 失败被 try_catch 捕获
**操作**：点按钮  
**预期**：toast "✅ catch: ..."；err 字段有异常字符串  
**不预期**：toast "❌ 不应到达这里"（说明 try 块异常没抛）；崩溃

### Q.3 未知 widget / 未知 action
**预期**：屏幕显示红底"未知控件类型: this_widget_does_not_exist" 占位；点未知 action 按钮无明显效果（仅 console 打印 "未知内置函数"）  
**不预期**：直接崩溃；红屏

---

## 占位测试点说明

以下 4 个测试点为"开发中"占位，不实际运行：
- **A.11 video** — 需稳定视频源，建议用 `demo_video_browser.json` 单独测
- **A.12 ref** — 依赖功能由 O 类的 `@common-ui.*` 实际验证
- **H.4 map** — flutter_map 依赖 OSM tile，平台/网络差异大
- **H.5 camera** — 需相机权限和硬件

---

## 重点回归项（这次 batch 1-8 + P0 修复后必看）

| 编号 | 测试点 | 看什么 |
|---|---|---|
| **E.1** | chip choice 反复切换 | P0-1：取消选中应能写回 null |
| **E.3** | avatar 失败 URL | P0-4：应显示首字母而非空圆 |
| **B.9** | grid 顶层 + 不带 shrinkWrap | P0-3：不应抛 RenderFlex 异常（本测试用 shrinkWrap=true，安全 shape）|
| **F.3** | draggable 拖拽 | P0 follow-up：Draggable&lt;Object&gt; 不报 type_argument_not_matching_bounds |
| **G.1** | tab_view 反复切换 | batch-8 review：监听器无泄漏，不会越切 onTabChange 触发越多 |
| **P.1** | loop 内 choice_dialog buttons | P0-5：buttons 数组里的 `{{ loop.* }}` 应被烘焙成真实 id |
| **B.6** | dropdown 外部清空 | batch-8 review：bind 外部改写应反映到 UI（InputDecorator+DropdownButton）|
| **L.5** | @list_remove | batch-1 新增的 action |
| **M.4-M.8** | 5 个新 ⭐ action | 全部应正常工作 |
| **I.3, I.4** | screen.appBar / drawer | batch-7 屏幕级配置 |

---

## 单独的端到端 demo（不在 regression-test.json 里）

主回归套件之外，还有几个"完整应用"形态的 demo 用来验证集成场景。**每个 release 都要单独打开点一遍**，确认能正常加载、关键路径能跑通。

| 文件 | 验证内容 | 关键路径 |
|------|----------|----------|
| `demo_video_browser.json` | video widget + 视频源切换 | 列表点击 → 视频播放 → 返回不卡 |
| `demo_user_profile.json` | lib_user 头像 / 昵称编辑 | 进 home 看到自己的资料 → 改头像 → 改昵称 → 重启 app 仍生效 |
| `demo_im.json` ⭐**新**| lib_im 私信 | ① home 标题显示未读总数 `(N)` + 自己 ID + 好友 / 会话列表（首次空都正常）<br>② "搜好友" → 输关键词（≥2 字）→ 看到结果 → 点"加好友" → toast 成功<br>③ 对端登录后看到"新申请"红点 → 进申请页 → 通过 → 双方好友列表都出现对方<br>④ 点好友进 chat → 消息条带"display_sender · display_time"（自己显示"我"，他人显示昵称；时间是 HH:mm/昨天/N天前）→ 输文字 → 发送 → 自己看到消息 → 对端 push + chat 历史拉到 → 来回几条都正常<br>⑤ 会话列表显示未读徽章（红色数字）+ 时间戳；进 chat 后徽章应清零，home 标题未读数同步减少<br>⑥ 杀进程重开 → home 仍能拉到会话和好友（说明 IM session 被恢复） |

**不预期**（任意一个出现就算挂）：
- 红屏 / "未知内置函数" 警告（说明 lib_im 没正确解析）
- 搜不到、加不上、消息发不出但**没任何提示**（说明降级失败）
- 杀进程重启后好友 / 会话**完全空**（说明 OpenIM session 没恢复）
- macOS / Web 跑 demo_im 时崩（应该安全降级返回空数组，UI 仍渲染）
- 消息条 / 会话条出现"`{{ loop.item.display_xxx }}`"字样（说明 v1.1 display_* 字段没出来 — 检查 lib_im 解析的版本是不是 ≥1.1.0）

---

## 已知限制 / 不算回归

- I.2 tab 页内 appBar/drawer 不生效 — `_TabScreenView` 写死，已记录为 P1
- E.1 chip choice 取消后如果 bind 是 bool 变量配 value:true，label 可能瞬间显示 "null" — showcase 写法问题，**框架行为正确**
- H 类 webview/map/camera 行为依赖平台与网络
- demo_im 仅支持 iOS / Android（OpenIM SDK 限制）；其它平台所有 IM 操作降级返回空，UI 不崩

---

## 一键全过测试建议顺序

1. 从 home 顶部按 A → Q 顺序逐项测
2. 重点项（上表）单独跑两遍
3. 持久化项（N）测完后**杀进程重启再测一次 get**，验证持久化
4. 测完后看 home 是否仍正常加载（验证测试间无残留 state 损坏）

测试不通过的项请截图 + 描述，附在 PR comment。
