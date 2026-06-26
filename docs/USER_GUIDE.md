# MyApp User Guide

本文面向使用 MyApp 的用户、测试人员和自部署操作者，解释从打开客户端到生成
JSON App、切换私有后端、使用私有 Agent Node 的完整流程。

部署运维细节见 [deploy/production/README.md](../deploy/production/README.md)。
后端内部链路见 [backend/ARCHITECTURE.md](../backend/ARCHITECTURE.md)。

## 1. Entry Points

可用客户端入口：

| Entry | Use when | Notes |
|---|---|---|
| Web | 想快速体验或验证 JSON App | `https://myapp-web.dapangyu.work/` |
| iOS TestFlight | 想在真机体验语音、推送、IM、移动端 UI | Public Group 1: `https://testflight.apple.com/join/3Fk5Exnn` |
| Android APK | 想直接安装测试 Android | 固定 APK 链接由官网和配置中心维护 |
| Local Flutter build | 要调试客户端或接本地后端 | `flutter run -d <device>` |

未登录也可以浏览和运行公开 JSON App。需要登录的能力包括：

- AI 对话生成/修复 App
- 保存会话和继续多轮打磨
- IM、好友、个人资料等账号能力
- 发布 JSON App 或管理自己的 namespace
- 创建和管理私有 Agent Node

框架层会对需要登录的 bridge/API 做保护；JSON App 本身不需要单独实现鉴权兜底。

## 2. First Run On Hosted Stack

1. 打开 Web、TestFlight 或 APK。
2. 可先选择不登录体验公开 App。
3. 登录后进入首页。
4. 打开“探索”安装官方 JSON App，或点击悬浮 AI 入口描述需求。
5. AI 生成完成后，客户端会收到结构化 `json_app_ready` 动作并自动打开生成结果。

AI 生成是长任务，10 分钟以上属于正常范围。客户端断线或后台后，后端任务仍会继续；
回到前台时客户端会通过 session 状态和 SSE `last_id` 接续读取。

## 3. Explore / App Library

“探索”页面默认只展示官方 namespace `/` 下的 App。页面能力：

- App / Library / Favorites tab
- namespace 下拉和搜索
- App 详情页
- 安装、运行、收藏
- 官方 App 和用户 namespace 隔离展示

如果你在私有后端上看不到 App，先检查：

```bash
myapp-ctl status registry app-minio
curl -fsS http://127.0.0.1:5000/api/v1/public
```

## 4. Generate Apps With AI

生成入口在客户端悬浮球/AI 对话页。

推荐请求方式：

- 先描述目标用户、核心场景和必须有的页面。
- 如果是工具类，明确数据结构和常用操作。
- 如果是游戏，明确规则、胜负条件、分数/生命/暂停/重开。
- 如果是移动端体验，说明首屏和常用屏幕，不要只说“做一个漂亮的 app”。
- 生成后直接继续同一个 session 说“把列表改成卡片”“增加详情页”等，不要新开会话。

生成链路：

```text
client chat
  -> backend /api/ai/chat/start
  -> Redis session/queue
  -> agent-node pulls job
  -> isolated runtime runs Claude/Codex/OpenCode
  -> JSON validated and uploaded
  -> backend stores terminal action
  -> client receives json_app_ready
```

如果客户端显示“重试”，通常表示当前 session 的后端状态是 failed/aborted，或者 SSE
中断后无法恢复。优先查看：

```bash
myapp-ctl log backend -n 200
myapp-ctl log ai-worker -n 200
myapp-ctl agent-node ls
myapp-ctl log agent-node -n 200
```

## 5. Agent Routing

客户端设置里有 `Agent routing`：

- `public`: 使用平台公开 Agent Node。
- `private`: 只使用当前登录用户自己的私有 Agent Node。

没有 `auto` 模式。私有模式下，如果私有节点离线或没有对应 provider/agent，任务会失败，
不会自动回落公共节点。用户需要手动切回 `public`。

provider 和 agent 下拉框会跟随 routing 模式：

- public 模式只显示公开节点上报的 provider/agent。
- private 模式只显示当前用户私有节点上报的 provider/agent。

## 6. User-Private Agent Node

私有 Agent Node 适合普通用户把自己的机器和 provider key 接入 MyApp，同时保证：

- 私有 provider key 只保存在用户自己的 agent 机器。
- 私有节点只服务该用户自己的请求。
- 公开用户不会被调度到这个节点。
- 后端只保存节点元数据、公钥、心跳和容量，不保存用户的 provider key。

客户端流程：

1. 登录客户端。
2. 设置中选择 provider/agent 和 `Agent routing`。
3. 打开 `Private Agent Node` 页面。
4. 点击创建加入命令，只需要输入节点名称。
5. 复制 join command 到自己的 agent 主机执行。
6. join 过程中在 agent 主机本地填写 DeepSeek / MiniMax / 自定义 provider 配置。
7. 回到客户端，把 routing 切到 `private`。

命令形态：

```bash
export MYAPP_PRIVATE_AGENT_JOIN_TOKEN='<copied from app settings>'

myapp-ctl agent-node private join \
  --backend https://<backend-host> \
  --node-id my-private-agent \
  --name "My private agent" \
  --provider deepseek \
  --agent claude \
  --capacity 2 \
  --queue-max 10 \
  --pull
```

私有节点本机查看：

```bash
myapp-ctl agent-node private status
myapp-ctl agent ls
myapp-ctl log agent-node -n 120
```

私有节点暂停、恢复和容量调整必须在 agent 节点机器本机执行：

```bash
myapp-ctl agent-node pause --reason "maintenance"
myapp-ctl agent-node resume
myapp-ctl agent-node limits --capacity 2 --queue-max 10
```

客户端只同步和展示节点状态，不远程修改私有节点运行配置。

管理端查看公开节点：

```bash
myapp-ctl agent-node ls
```

管理端查看某个用户私有 namespace：

```bash
myapp-ctl agent-node ls --namespace <user-id>
```

## 7. Connect Client To A Self-Hosted Backend

全量部署后，`myapp-ctl deploy` 会打印客户端导入 JSON 和二维码。之后可随时重新打印：

```bash
myapp-ctl client-env --host <public-ip-or-domain> --terminal-qr
cat /mnt/myapp/state/client-environment.json
```

客户端导入方式：

1. 打开登录页。
2. 连续点击品牌/版本入口进入 Service Environment 页面。
3. 扫描二维码，或粘贴完整 `myapp.environment` JSON。
4. 保存后重新登录。

导入后影响这些地址：

- backend API
- registry
- config center
- OpenIM API/WS
- ByteDance ASR endpoint

如果切换后登录失败，先用浏览器或 curl 检查后端：

```bash
curl -fsS http://<host>:5566/health
curl -fsS http://<host>:5566/api/ai/providers
curl -fsS http://<host>:5000/api/v1/public
```

## 8. Web Debug Modes

Flutter Web 支持两类直达入口。

按 appid 直接打开 Registry 中的 App：

```text
https://myapp-web.dapangyu.work/?appid=<uuid>
https://myapp-web.dapangyu.work/?app_id=<uuid>
```

本地 JSON 调试：

```text
http://localhost:<flutter-port>/?local_json=/absolute/path/app.json
http://localhost:<flutter-port>/?json_path=/absolute/path/app.json
http://localhost:<flutter-port>/?json_app=/absolute/path/app.json
```

Web 不能直接读本机绝对路径；默认会请求本机 helper：

```text
http://127.0.0.1:8765/json?path=/absolute/path/app.json
```

可通过 `local_json_server` 覆盖：

```text
http://localhost:<flutter-port>/?local_json=/tmp/app.json&local_json_server=http://127.0.0.1:8765/json
```

## 9. Publish And Share JSON Apps

发布前先验证：

```bash
python3 backend/validate_json_app.py templates/<app>.json
```

推荐发布路径：

- 官方 App：发布到根 namespace `/`，需要 admin 权限。
- 用户 App：发布到用户 namespace。
- 组件/库：作为 `type=library` 发布，App 通过依赖加载。
- 资产：使用 asset manifest / OSS URL，不要在 JSON 中拼接宿主机本地路径。

生成型 App 的最终 JSON 一般先进入临时对象 URL；用户确认可用后再发布到 Registry。

## 10. Common Troubleshooting

| Symptom | Likely cause | First action |
|---|---|---|
| 登录失败 | 环境 JSON 指向错误后端、Supabase 未启动、测试用户未创建 | `myapp-ctl status supabase-auth backend` |
| 探索空白 | Registry 或 App MinIO 不通，namespace 为空 | `myapp-ctl status registry app-minio` |
| AI 一直排队 | 没有在线 agent-node，或队列满 | `myapp-ctl agent-node ls` |
| 私有模式不可用 | 私有节点离线、provider/agent 不匹配、节点被暂停 | `myapp-ctl agent-node private status` |
| 生成成功但客户端没打开 | 终态 action 丢失或客户端未恢复 result | 查 `/api/ai/chat/<session>/result` 和 backend log |
| Web IM 异常 | OpenIM WASM bridge 或 OpenIM 地址错误 | 重新构建 `web_openim_bridge`，检查环境 JSON |
| Push 不工作 | APNs/FCM/GeTui 未配置或 token 未注册 | `myapp-ctl secret ls` 和 backend push logs |
