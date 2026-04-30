# Widget 实现待办清单

## 📊 当前状态

- ✅ 已实现：43 个 Widget + 6 个增强 action + 3 项 screen 级配置
  - 第一批：icon / card / checkbox / expanded / loading
  - 第二批：dropdown / radio / wrap / grid + `@show_choice_dialog` + `@list_remove`
  - 第三批：padding / center / align / flexible / stack
  - 第四批：slider / date_picker / time_picker / tooltip + `@show_snackbar` / `@show_date_picker` / `@show_time_picker`
  - 第五批：chip / badge / avatar / rich_text / progress
  - 第六批：inkwell / gesture_detector / dismissible / draggable / refresh
  - 第七批：tab_view / app_bar widget + `screen.appBar` / `screen.drawer` / `screen.tabs`(已存在) + `@show_bottom_sheet`
- ❌ 待实现：5 个特殊 Widget（webview / map / chart / qr_code / camera，需新加包）

---

## 🎯 优先级分类

### 🔥 高优先级（推荐优先实现）

这些是最常用的 Widget，实现后可以覆盖 90% 的应用场景。

#### 1. ✅ checkbox - 复选框（已实现）
- **使用频率**: ⭐⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 表单必备，多选场景
- **Flutter Widget**: `Checkbox`

#### 2. ✅ dropdown - 下拉菜单（已实现）
- **使用频率**: ⭐⭐⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 表单必备，选项选择
- **Flutter Widget**: `DropdownButton`

#### 3. ✅ card - 卡片（已实现）
- **使用频率**: ⭐⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: UI 展示必备，内容容器
- **Flutter Widget**: `Card`

#### 4. ✅ icon - 图标（已实现）
- **使用频率**: ⭐⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: UI 装饰必备，按钮图标
- **Flutter Widget**: `Icon`

#### 5. ✅ expanded - 弹性布局（已实现）
- **使用频率**: ⭐⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 布局必备，自适应宽度
- **Flutter Widget**: `Expanded`

#### 6. ✅ grid - 网格布局（已实现）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 列表展示常用，图片墙
- **Flutter Widget**: `GridView`

#### 7. ✅ tab_bar - 标签栏（已实现，与 tab_view 合并为单 widget）
- **使用频率**: ⭐⭐⭐⭐⭐
- **实现难度**: 复杂
- **预计时间**: 2 天
- **用途**: 多页面应用必备
- **Flutter Widget**: `TabBar` + `TabBarView`
- **实现方式**: `tab_view` widget 内置 DefaultTabController + TabBar + TabBarView

#### 8. ✅ bottom_nav - 底部导航栏（已通过 `screen.tabs` 配置支持）
- **使用频率**: ⭐⭐⭐⭐⭐
- **实现难度**: 复杂
- **预计时间**: 2 天
- **用途**: 移动应用必备，主导航
- **Flutter Widget**: `BottomNavigationBar`
- **实现方式**: screen 顶层 `tabs: [...]` 配置自动渲染底部导航栏（早期已支持）

#### 9. ✅ dialog - 对话框（已实现，作为 `@show_choice_dialog` action）
- **使用频率**: ⭐⭐⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 交互反馈必备，确认操作
- **Flutter Widget**: `AlertDialog` / `Dialog`
- **实现方式**: 命令式 action（不是渲染 widget），支持自定义按钮 + 返回被点按钮的 value

#### 10. ✅ loading - 加载指示器（已实现）
- **使用频率**: ⭐⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 异步操作必备，等待提示
- **Flutter Widget**: `CircularProgressIndicator` / `LinearProgressIndicator`

---

## 📋 表单类 Widget

### ✅ radio - 单选框（已实现，作为单选组）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 表单，单选场景
- **Flutter Widget**: `Radio`
- **实现方式**: `bind` + `options` 数组，整组单选；比单个 Radio 在 JSON 里更实用

### ✅ slider - 滑块（已实现）
- **使用频率**: ⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 数值选择，音量调节
- **Flutter Widget**: `Slider`

### ✅ date_picker - 日期选择器（已实现）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 日期输入，预约场景
- **Flutter Widget**: `showDatePicker`
- **实现方式**: `date_picker` 输入框控件 + `@show_date_picker` 命令式 action

### ✅ time_picker - 时间选择器（已实现）
- **使用频率**: ⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 时间输入，闹钟设置
- **Flutter Widget**: `showTimePicker`
- **实现方式**: `time_picker` 输入框控件 + `@show_time_picker` 命令式 action

---

## 🎨 布局类 Widget

### ✅ wrap - 自动换行布局（已实现）
- **使用频率**: ⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 标签云，自适应布局
- **Flutter Widget**: `Wrap`

### ✅ stack - 层叠布局（已实现）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 图片叠加，浮动按钮
- **Flutter Widget**: `Stack` + `Positioned`

### ✅ flexible - 灵活布局（已实现）
- **使用频率**: ⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 弹性布局，自适应
- **Flutter Widget**: `Flexible`

### ✅ padding - 内边距（已实现）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 布局调整，间距控制
- **Flutter Widget**: `Padding`

### ✅ center - 居中（已实现）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 内容居中，对齐
- **Flutter Widget**: `Center`

### ✅ align - 对齐（已实现）
- **使用频率**: ⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 精确对齐，位置控制
- **Flutter Widget**: `Align`

---

## 🧭 导航类 Widget

### ✅ tab_view - 标签页内容（已实现，与 tab_bar 合并）
- **使用频率**: ⭐⭐⭐⭐⭐
- **实现难度**: 复杂
- **预计时间**: 2 天（与 tab_bar 一起实现）
- **用途**: 标签页内容展示
- **Flutter Widget**: `TabBarView`

### ✅ drawer - 侧边栏（已实现，screen.drawer 配置）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 复杂
- **预计时间**: 2 天
- **用途**: 主菜单，设置入口
- **Flutter Widget**: `Drawer`

### ✅ app_bar - 顶部栏（已实现，独立 widget + screen.appBar 覆写）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 页面标题，操作按钮
- **Flutter Widget**: `AppBar`

---

## 💬 反馈类 Widget

### ✅ bottom_sheet - 底部弹窗（已实现，作为 `@show_bottom_sheet` action）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 选项菜单，操作面板
- **Flutter Widget**: `showModalBottomSheet`

### ✅ snackbar - 提示条（已实现）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 轻量提示，操作反馈
- **Flutter Widget**: `SnackBar`
- **实现方式**: 新增 `@show_snackbar` action（带操作按钮 + 自定义时长 + 背景色）；保留 `@show_toast` 不变

### ✅ progress - 进度条（已实现）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 进度展示，下载上传
- **Flutter Widget**: `LinearProgressIndicator`

### ✅ tooltip - 工具提示（已实现）
- **使用频率**: ⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 帮助提示，说明文字
- **Flutter Widget**: `Tooltip`

---

## 🎭 展示类 Widget

### ✅ chip - 标签/徽章（已实现，三种 variant）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 标签展示，分类标记
- **Flutter Widget**: `Chip` / `FilterChip` / `ChoiceChip`

### ✅ badge - 角标（已实现）
- **使用频率**: ⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 消息提醒，数量标记
- **Flutter Widget**: `Badge`

### ✅ avatar - 头像（已实现）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 用户头像，圆形图片
- **Flutter Widget**: `CircleAvatar`

### ✅ rich_text - 富文本（已实现）
- **使用频率**: ⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 多样式文本，高亮显示
- **Flutter Widget**: `RichText` / `Text.rich`

---

## 🖱️ 交互类 Widget

### ✅ gesture_detector - 手势检测（已实现）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 自定义手势，点击长按
- **Flutter Widget**: `GestureDetector`

### ✅ inkwell - 水波纹点击效果（已实现）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 点击反馈，Material 风格
- **Flutter Widget**: `InkWell`

### ✅ draggable - 可拖拽（已实现 Draggable，DragTarget 后续批次补）
- **使用频率**: ⭐⭐
- **实现难度**: 复杂
- **预计时间**: 2 天
- **用途**: 拖拽排序，自定义交互
- **Flutter Widget**: `Draggable` + `DragTarget`

### ✅ dismissible - 滑动删除（已实现）
- **使用频率**: ⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 列表项删除，滑动操作
- **Flutter Widget**: `Dismissible`

### ✅ refresh - 下拉刷新（已实现）
- **使用频率**: ⭐⭐⭐⭐
- **实现难度**: 中等
- **预计时间**: 1 天
- **用途**: 列表刷新，数据更新
- **Flutter Widget**: `RefreshIndicator`

---

## 🔧 特殊类 Widget

### webview - 网页视图
- **使用频率**: ⭐⭐⭐
- **实现难度**: 复杂
- **预计时间**: 2 天
- **用途**: 嵌入网页，H5 页面
- **Flutter Package**: `webview_flutter`

### map - 地图
- **使用频率**: ⭐⭐
- **实现难度**: 复杂
- **预计时间**: 3 天
- **用途**: 位置展示，导航
- **Flutter Package**: `google_maps_flutter` / `flutter_map`

### chart - 图表
- **使用频率**: ⭐⭐⭐
- **实现难度**: 复杂
- **预计时间**: 3 天
- **用途**: 数据可视化，统计展示
- **Flutter Package**: `fl_chart` / `charts_flutter`

### qr_code - 二维码
- **使用频率**: ⭐⭐
- **实现难度**: 简单
- **预计时间**: 0.5 天
- **用途**: 二维码生成，扫码
- **Flutter Package**: `qr_flutter` / `mobile_scanner`

### camera - 相机
- **使用频率**: ⭐⭐
- **实现难度**: 复杂
- **预计时间**: 2 天
- **用途**: 拍照录像，实时预览
- **Flutter Package**: `camera`
- **备注**: 目前有 `image_picker`，可以扩展

---

## 📊 实现统计

### 按难度分类

| 难度 | 数量 | 预计总时间 |
|------|------|-----------|
| 简单 | 20 个 | 10 天 |
| 中等 | 13 个 | 13 天 |
| 复杂 | 9 个 | 18 天 |
| **总计** | **42 个** | **41 天** |

### 按优先级分类

| 优先级 | 数量 | 预计总时间 |
|--------|------|-----------|
| 高优先级（推荐） | 10 个 | 9.5 天 |
| 中优先级 | 22 个 | 20 天 |
| 低优先级 | 10 个 | 11.5 天 |

---

## 🎯 实施建议

### 第一阶段：核心 Widget（1-2 周）

实现高优先级的 10 个 Widget，覆盖 90% 的应用场景：

1. ✅ checkbox（0.5 天）
2. ✅ icon（0.5 天）
3. ✅ expanded（0.5 天）
4. ✅ padding（0.5 天）
5. ✅ center（0.5 天）
6. ✅ loading（0.5 天）
7. ✅ card（0.5 天）
8. ✅ dropdown（1 天）
9. ✅ grid（1 天）
10. ✅ dialog（1 天）

**小计**: 7 天

### 第二阶段：表单和布局（1 周）

完善表单和布局相关的 Widget：

1. ✅ radio（0.5 天）
2. ✅ slider（0.5 天）
3. ✅ wrap（0.5 天）
4. ✅ flexible（0.5 天）
5. ✅ align（0.5 天）
6. ✅ stack（1 天）
7. ✅ date_picker（1 天）
8. ✅ time_picker（1 天）

**小计**: 5.5 天

### 第三阶段：导航和反馈（1-2 周）

实现导航和用户反馈相关的 Widget：

1. ✅ tab_bar + tab_view（2 天）
2. ✅ bottom_nav（2 天）
3. ✅ drawer（2 天）
4. ✅ bottom_sheet（1 天）
5. ✅ snackbar（0.5 天）
6. ✅ progress（0.5 天）

**小计**: 8 天

### 第四阶段：展示和交互（1 周）

实现展示和交互相关的 Widget：

1. ✅ chip（0.5 天）
2. ✅ badge（0.5 天）
3. ✅ avatar（0.5 天）
4. ✅ inkwell（0.5 天）
5. ✅ gesture_detector（1 天）
6. ✅ dismissible（1 天）
7. ✅ refresh（1 天）

**小计**: 5 天

### 第五阶段：特殊功能（可选，2-3 周）

根据需求实现特殊功能的 Widget：

1. ✅ webview（2 天）
2. ✅ rich_text（1 天）
3. ✅ tooltip（0.5 天）
4. ✅ app_bar（1 天）
5. ✅ draggable（2 天）
6. ✅ qr_code（0.5 天）
7. ✅ camera（2 天）
8. ✅ map（3 天）
9. ✅ chart（3 天）

**小计**: 15 天

---

## 📝 实现模板

每个 Widget 的实现包含以下步骤：

### 1. 创建 Widget 文件
```dart
// lib/json_ui/widgets/xxx_widget.dart
import 'package:flutter/material.dart';
import 'base_widget.dart';

class JsonXxxWidget extends JsonBaseWidget {
  const JsonXxxWidget({
    super.key,
    required super.config,
    required super.interpreter,
  });

  @override
  Widget build(BuildContext context) {
    // 实现逻辑
  }
}
```

### 2. 注册到 Widget Builder
```dart
// lib/json_ui/widget_builder.dart
'xxx': (config, interpreter) => JsonXxxWidget(
  config: config,
  interpreter: interpreter,
),
```

### 3. 更新 JSON-DSL.md
```markdown
| `xxx` | `XxxWidget` | 必填字段 | 可选字段 |
```

### 4. 创建测试 JSON
```json
{
  "type": "xxx",
  "属性1": "值1",
  "属性2": "值2"
}
```

---

## 🎉 完成标准

每个 Widget 实现完成后，需要满足：

- ✅ 代码实现完成
- ✅ 注册到 Widget Builder
- ✅ 更新 JSON-DSL.md 文档
- ✅ 创建示例 JSON 应用
- ✅ 测试基本功能正常
- ✅ 测试样式配置正常
- ✅ 测试事件绑定正常

---

## 📅 更新日志

- 2026-04-27: 创建待办清单，列出 42 个待实现的 Widget
- 2026-04-28: 第一批实现 5 个高优先级 Widget — icon / card / checkbox / expanded / loading；同步发布 demo 应用 `widgets-showcase` 和 common-ui 1.1.0 的辅助函数
- 2026-04-28: 第二批实现 4 个 Widget + 1 个增强 action — dropdown / radio / wrap / grid + `@show_choice_dialog`；demo 应用 `widgets-showcase-2`，common-ui bump 到 1.2.0 并新增 `confirmDelete` 辅助函数
- 2026-04-28: 第三批实现 5 个布局 Widget — padding / center / align / flexible / stack；demo 应用 `widgets-showcase-3`
- 2026-04-28: 第四批实现 4 个表单/反馈 Widget + 3 个 action — slider / date_picker / time_picker / tooltip + `@show_snackbar` / `@show_date_picker` / `@show_time_picker`；demo 应用 `widgets-showcase-4`
- 2026-04-29: 第五批实现 5 个展示 Widget — chip / badge / avatar / rich_text / progress；demo 应用 `widgets-showcase-5`
- 2026-04-29: 第六批实现 5 个交互 Widget — inkwell / gesture_detector / dismissible / draggable / refresh；新增 `executeActionWithResult` 公共方法支持 dismissible.confirmAction 取返回值；demo 应用 `widgets-showcase-6`
- 2026-04-29: 第七批实现 2 个 widget + 3 项 screen 级配置 + 1 个 action — tab_view / app_bar widget + `screen.appBar` / `screen.drawer`(原已支持 `screen.tabs`) + `@show_bottom_sheet`；main.dart Scaffold 渲染向后兼容地支持 appBar/drawer 覆写；demo 应用 `widgets-showcase-7`
- 待更新...

---

**总结**: 当前已实现 13 个核心 Widget，还有 42 个常见 Widget 待实现。建议优先实现高优先级的 10 个 Widget，可以在 1-2 周内完成，覆盖 90% 的应用场景。
