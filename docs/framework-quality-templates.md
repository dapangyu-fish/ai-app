# Framework Quality JSON Templates

这批模板用于补足 `native_quality_*` 的同质化问题。它们不是 CRUD/list 正例，而是展示当前 JSON-DSL 框架层已经支持的不同应用形态。

## 模板

- `templates/framework_quality_smart_home.json`：智能家居控制台，使用 `switch`、`slider`、`grid`、`progress`、`chip`。
- `templates/framework_quality_ops_dashboard.json`：运营数据看板，使用 `chart`、`dropdown`、`tab_view`、`progress`。
- `templates/framework_quality_travel_pass.json`：旅行票证，使用 `qr_code`、`map`、进度和时间线。
- `templates/framework_quality_course_player.json`：视频课程播放器，使用 `video`、`tab_view`、`switch`、课程进度。
- `templates/framework_quality_camera_inspection.json`：现场拍照质检，使用 `image_picker(source=camera)`、`badge`、`checkbox`、`progress`。

## 生成

```bash
python3 scripts/generate_framework_quality_templates.py
```

这些模板的设计原则：

- 不复用“搜索 + 筛选 + 列表 + 详情 + 表单”的单一骨架。
- 优先展示框架已有控件的真实组合方式。
- 首屏按 402x874 手机尺寸检查，不允许出现明显挤压、竖排、白屏；高风险布局再用 360x780 做下限回归。
- 对视频、地图、相机这类依赖平台/网络的控件，首屏必须有可读的周边 UI，控件加载慢时也不能只剩空白。

## 验证

```bash
python3 -m py_compile scripts/generate_framework_quality_templates.py
python3 backend/validate_json_app.py templates/framework_quality_smart_home.json
python3 backend/validate_json_app.py templates/framework_quality_ops_dashboard.json
python3 backend/validate_json_app.py templates/framework_quality_travel_pass.json
python3 backend/validate_json_app.py templates/framework_quality_course_player.json
python3 backend/validate_json_app.py templates/framework_quality_camera_inspection.json
```

移动端截图仍用 `docs/local-json-web-debug.md` 的 `?local_json=` 流程。
