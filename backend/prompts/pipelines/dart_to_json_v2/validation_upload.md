# Step 3: Repair, Validate, Visual Review, Upload

生成 `$AI_APP_WORKSPACE/app.json` 后必须按顺序执行：

1. `python3 backend/repair_json_app.py "$AI_APP_WORKSPACE/app.json"`
2. `python3 backend/validate_json_app.py "$AI_APP_WORKSPACE/app.json"`
3. 如视觉复检工具可用，复杂 APP、游戏、多页面 APP 或视觉质量敏感 APP 至少运行一次 `myapp-visual-review "$AI_APP_WORKSPACE/app.json"`，并根据截图报告修复。
4. 再次运行 validate，最终必须无 ERROR。
5. `bash backend/upload_with_signature.sh "$AI_APP_WORKSPACE/app.json"`

任何一步失败：

- 必须先修复。
- 不得上传。
- 不得回复“已生成好了”。

最终回复：

- 只用简短自然语言说明已生成或需要用户上传当前应用。
- 回复语言跟随用户本轮请求的语言（用户用中文就回中文，用英文就回英文）；无法判断时默认中文。
- 禁止在最终自然语言中输出 `[json_app_url]`、`[request_action]` 等协议标签。
- 客户端动作必须写入 `$AI_APP_WORKSPACE/client_actions.json` 或由上传脚本生成。

