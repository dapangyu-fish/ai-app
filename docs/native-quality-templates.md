# Native Quality JSON Templates

这 5 个模板是普通工具 / 记录 / 管理类 APP 的正例样板，目标是把“像原生手机 APP”落实成可复用结构，而不是让非视觉模型临场判断审美。

## 模板

- `templates/native_quality_notes.json`：笔记 / 日记 / 内容记录。
- `templates/native_quality_crm.json`：CRM / 联系人 / 资料库。
- `templates/native_quality_budget.json`：预算 / 记账 / 交易流水。
- `templates/native_quality_habits.json`：习惯打卡 / 任务进度。
- `templates/native_quality_workout.json`：训练记录 / 健康日志。

共同结构：

- 原生 app bar + 右侧新增入口。
- 三个摘要指标卡。
- 搜索栏。
- 状态筛选 chip。
- native list item 风格列表。
- 详情页和表单页闭环。
- 移动端 402x874 首屏可读，必要时 360x780 下限回归；避免落地页式 hero、emoji 结构控件、空白中心态。

## 生成

```bash
python3 scripts/generate_native_quality_templates.py
```

生成器复用 `backend/json_app_builder.py` 的 native helper。以后新增同类模板应优先扩展 helper 或生成器，不要手写大块重复 JSON。

## 验证

```bash
python3 -m py_compile scripts/generate_native_quality_templates.py backend/json_app_builder.py
python3 backend/validate_json_app.py templates/native_quality_notes.json
python3 backend/validate_json_app.py templates/native_quality_crm.json
python3 backend/validate_json_app.py templates/native_quality_budget.json
python3 backend/validate_json_app.py templates/native_quality_habits.json
python3 backend/validate_json_app.py templates/native_quality_workout.json
```

移动端截图仍然是最终人工验收入口。使用 `docs/local-json-web-debug.md` 的 `?local_json=` 流程，在 402x874 视口检查首屏是否有信息密度、主次层级和列表可读性；高风险布局再用 360x780 做下限回归。
