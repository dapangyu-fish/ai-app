# Native 工具类 APP 生成指南

适用：日记、笔记、待办、预算、习惯、联系人、CRM、库存、课程表、资料库、表单、列表管理工具。

目标：像手机上的可用原生应用，不像网页 demo 或只堆输入框的 JSON 示例。

## 推荐资料

先读 1-2 个最接近的模板，不要全读：

- `templates/native_quality_notes.json`
- `templates/native_quality_crm.json`
- `templates/native_quality_budget.json`
- `templates/native_quality_habits.json`
- `templates/native_quality_workout.json`

非 CRUD 工具可读：

- `templates/framework_quality_smart_home.json`
- `templates/framework_quality_ops_dashboard.json`
- `templates/framework_quality_travel_pass.json`
- `templates/framework_quality_course_player.json`
- `templates/framework_quality_camera_inspection.json`

## 强制使用 helper

复杂 CRUD / 工具 APP 必须写 Python 生成器，并优先使用 `backend/json_app_builder.py`：

```python
import os
import sys

PROJECT_ROOT = os.environ.get("AI_APP_PROJECT_ROOT") or os.getcwd()
sys.path.insert(0, os.path.join(PROJECT_ROOT, "backend"))

from json_app_builder import (
    new_app, screen, text, icon, spacer, container, card, button,
    native_app_bar, native_search_bar, native_metric_card, native_metric_row,
    native_filter_chips, native_empty_state, native_crud_app_shell, save_json,
)
```

这些 helper 只输出 DSL 已支持字段，能减少 `body`、CSS margin、shadow、style 等错误。

## 首屏结构下限

按标准 iPhone 17 逻辑视口 402x874 作为主设计尺寸。AppBar 下至少有两个有用结构区：

- 摘要/统计/进度卡
- 搜索/筛选
- 列表标题/最近记录
- 快捷入口/主操作
- 紧凑空状态

空数据时也要保留 0 值摘要、进度、分类入口。空状态只是列表区域的一部分，不要占满大半屏。

移动端首屏硬要求：

- 摘要卡横排最多 2 张；3 张以上必须换成两行 `wrap`/网格或更紧凑的列表。不要用 3 个 `expanded` 横排挤在 402 宽度里。
- 控制面板/智能家居/运营仪表盘首屏必须在摘要区之后立刻露出真实控制区或列表区；只展示天气、能耗、设备数等摘要，下面大面积空白，视为失败。
- 任何一屏底部不能因为过高 header/摘要卡导致主要功能完全不可见。
- iPhone 13 mini 的 360x780 只作为兼容回归下限；不要为了小屏下限牺牲标准机型上的信息密度和原生质感，但也不能在 360 宽出现关键摘要卡、主按钮、底部导航或当前区域控制被横向裁切。
- 横向 chip/快捷场景超过 3 个时必须 `wrap`、换行或使用框架已支持的横向滚动结构；不要写一条超出屏幕右侧的固定 row。
- 两列摘要卡必须使用弹性布局，不要给卡片写固定宽度；如果文案较长，在 360 宽改成上下两行或更短标签。
- 行程票夹/钱包/证件类 hero 卡里如果放二维码或缩略图，二维码宽高控制在 56-72；左侧文本必须用 `expanded/flexible` 或单独纵向布局，不能把二维码裁出屏幕右侧。
- 动态状态文案不要把 JsonLogic 对象直接写进 `text.value`。例如安防状态、窗帘开关、票证状态，应该用 `{{ global.securityLabel }}` 这类字符串变量显示，并在切换动作里同步更新 label。

## 滚动布局契约

生成前先判断每个 screen/tab 的主滚动模型，避免“下方内容存在但用户滑不到”：

- 普通静态长页面、设置页、详情页、控制台、仪表盘：直接用 `children` 顺序堆卡片/控件，框架会自动给 screen/tab 外层加纵向滚动。横向摘要卡可以在 `row` 里用 `expanded`，不要因此改成固定高度页面。
- 普通 `list` 默认是 full-height 内部滚动区，会让 screen/tab 外层不再滚动。它适合作为列表页的主区域，必须作为 screen/tab 的直接 child 使用，前面只放紧凑搜索/筛选/摘要，后面不要再堆大段静态内容。
- 如果只是“最近 3 条记录 / 日程预览 / 小历史列表”嵌在仪表盘或详情页中，必须在 `list` 上写 `"shrinkWrap": true`，不要写 `scrollToEnd` 或 `onLoadMore`；外层页面负责滚动。
- `grid` 嵌在长页面时同样写 `"shrinkWrap": true`。只有真正需要占满剩余高度的瀑布/宫格页才使用默认非 shrinkWrap。
- 不要把非 shrinkWrap 的 `list` 放进 `card`、`container`、`padding`、`center` 等 wrapper 里；这类结构要么无法滚动到底，要么会触发 Flutter 高度约束问题。需要包视觉样式时，把样式放到 `item_template` 的卡片里。
- 如果一屏内容超过 iPhone 17 逻辑视口 402x874，必须保证底部主要按钮、设置项、详情分组能通过纵向滚动到达；不要依赖用户“再让 AI 修改”。

## 图标规则

图标名必须来自 `lib/json_ui/widgets/icon_registry.dart`。常用安全图标包括：

`home, add, edit, delete, search, filter, settings, refresh, calendar, clock, star, favorite, person, people, chat, notification, dashboard, analytics, receipt, payment, warning, warning_amber, info, check_circle, medication, local_pharmacy, inventory_2, schedule, notes, today, wb_sunny, bolt, electric_bolt, air, payments, devices, lightbulb, thermostat, ac_unit, weekend, king_bed, single_bed, kitchen, cooking, bathroom, security, sensors, wifi, tv, router`

不要凭 Material Icons 记忆随便写名字；不确定就查源码。未知图标会在 UI 上显示红色问号，并会被上传前 validator 拦截。

## 常见配方

记录 / 笔记 / 日记：

- AppBar：短标题 + 右侧新增按钮。
- 首屏：搜索栏、筛选 chip、统计/排序行、主列表、紧凑空状态。
- 列表项：左侧 icon/badge/状态色块，中间标题 + 摘要 + 日期，右侧编辑/更多。
- 写入页：独立 screen，表单有 label/hint，保存/取消清晰。

预算 / 清单 / 任务 / 习惯：

- 首屏先放今日/本月摘要卡或进度条，再放筛选和列表。
- 即使没有数据，也展示 0 值摘要和快捷分类入口。
- 金额/完成率/剩余天数主数字 24-28px 即可，不要巨型 hero。
- 删除/危险操作放详情页或确认弹窗。

联系人 / 健康 / 药品 / 资料库：

- 搜索 + 分组/标签 + 列表。
- 列表项至少包含头像/图标、主标题、副标题、状态。
- 详情页用信息分组，不要无边框堆字段。

## 视觉规则

- 不要同时使用默认 screen title AppBar 和自定义大 header；二选一。
- 避免一整页同一种浅灰/米色/棕色/单色渐变。
- 主色只用于主要动作和选中态；危险红色；成功绿色；辅助灰色。
- 不要用 emoji 当标题图标、主按钮图标、列表状态图标或空状态主视觉。优先用 `icon` 或 button `icon`。
- 页面边距通常 16-20，卡片内边距 14-18，列表项高度 56-88。
- 标题不要超过 28px，除非用户明确要封面/海报页。

## 控制面板 / 仪表盘 / 智能家居 额外规则

- 快捷场景、快捷开关等"动作入口"用紧凑横向 chip 行或两列网格（`wrap` 或 `shrinkWrap` grid）。不要把每个场景做成占满整行、带大居中图标的纵向列表项——那会把温湿度卡、设备控制等真正内容挤出首屏。一行 3-4 个紧凑 chip 优于 5 个全宽大行。
- 任何"标签 + 当前值"（如 `当前场景：`、`安防状态：`、`模式：`）必须有合理默认值，绝不能渲染成标签后面空白。用 `{{ global.currentSceneLabel }}` 这类变量并初始化一个默认中文值（如"回家模式"）。
- 不要把设备/控件的原始类型枚举（`light`/`switch`/`sensor`/`ac`）当作用户可见副标题。要么省略副标题（标题已是"客厅主灯"），要么显示真实状态（如"已开 · 亮度 80%"）。
- 多分区 APP 的主导航优先用底部导航（screen 级 `tabs` / 底部 nav），比顶部文字 tab 更贴近 iOS/Android 原生。设备控制项优先用真实开关控件（`switch`）体现可操作状态，而不是纯文字行。
- 摘要/统计卡必须显示具体数值（没有数据就写 0 或 —），禁止只有图标+标签、数字区留空的空卡片。列表为空时空状态不要占满首屏；首屏仍要有带数值的摘要卡和主操作（拍照/扫码/新增等）同时可见。

## 功能完整性

普通管理类 APP 至少要闭环：

- 新增
- 编辑
- 删除或归档
- 空状态
- 数据持久化或明确状态更新
- 表单回填
- 保存反馈或返回列表

不要只做一个静态展示页，除非用户明确要求。
