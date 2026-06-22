# Goal — FaaS 访问架构加固 + 端到端「自动生成带后端应用」真实测试

> 📦 **归档说明(2026-06):OpenFaaS/faasd 已被彻底移除**，唯一运行时为自研 Docker FaaS(详见 `docs/faas-docker-runtime.md`)。本文档仅作历史记录保留。

Date: 2026-06-16
Branch: `feat/agent-control-plane`
Status: 待实施（本文是 `/goal`，实施前的**目标 + 验收契约**）

关联：本目标建立在 `docs/faas-backend-generation-goal.md`（运行时 / 严格 git 源真相）、
`docs/faas-backend-generation.md`、`docs/faas-backend-generation-handoff.md` 之上，
**新增两块**作为 FaaS 下一阶段验收标准：
1. **访问架构**（faasd 端口收口 / 独立域名 / 双访问 / 多节点就绪）。
2. **端到端真实测试**（模拟 客户端 → 后端 API → 真实 AI 生成 → 部署 → 调用，全链路在 77 跑通）。

---

## 一、终极目标（Ultimate Goal）

用户在对话里要求「做一个需要后端的应用」，系统**自动**完成：

```
对话(MiniMax M3) → AI 生成 Python/Flask 后端 + 客户端 JSON-APP
  → 后端校验/存储/推 GitHub/部署到 faasd
    → 客户端可两种方式调用该后端并得到正确结果：
        (a) 后端代理：  /api/faas/invoke/<service_id>/<route>   ← 推荐，带校验，多节点路由
        (b) faas 节点独立域名： https://myapp-pre-de-openfaas.dapangyu.work/...  ← 直连该节点 faasd
```

**验收以一条真实端到端测试通过为准**：API 层（无 UI 自动化），在 **77** 上跑，
允许消耗真实 AI 额度（MiniMax M3）。

---

## 二、现状（Current State，已于 2026-06-16 核实）

| # | 事实 | 位置 | 影响 |
|---|------|------|------|
| S1 | faasd gateway 发布在 host `*:8080`，faasd-provider 在 host `*:8081`，**均公网可达，无防火墙** | 77 `/var/lib/faasd/docker-compose.yaml` gateway `ports: "8080:8080"`；`ss` 显示 `*:8080`/`*:8081` | 需收口 |
| S2 | nginx 生成器**已内置** `openfaas` 路由，但 upstream 指向 **`http://backend:5566`**（不是 faasd） | `scripts/myapp_ctl.py:163` | faas 域名当前只是 backend 的别名，**不是**直连 faasd |
| S3 | `FAAS_PUBLIC_BASE_URL` 被设为 `urls["openfaas"]`（= faas 域名） | `scripts/myapp_ctl.py:~4736/4747`、`backend/config.py:129` | 函数容器拉 bundle 走 faas 域名 → backend；若把 faas 域名改指 faasd，会断 |
| S4 | 实时 77 backend：`FAAS_DEPLOY_MODE=openfaas`，`FAAS_OPENFAAS_GATEWAY=http://77.237.233.229:8080`（裸 IP + 明文） | `/etc/myapp/secrets.d/*.env` | 需改为内网地址；封 8080 后此地址会断 |
| S5 | gateway 解析是**单一调用点**：`openfaas_gateway_for_service(service)` 先读 `meta_json.deploy.openfaas_gateway`，否则回退全局 `FAAS_OPENFAAS_GATEWAY` | `backend/faas_store.py:358-366`；`backend/faas.py:296-310` | 已部署服务**各自钉死**了旧 gateway → 重指需迁移；多节点扩展点也在这里 |
| S6 | `faas_services` 无独立 node 字段，gateway 存在 `meta_json.deploy.openfaas_gateway` | `backend/faas_store.py:202-217, 328-366` | 多节点用 `meta_json.deploy.node_id` + 节点注册表即可，无需建表 |
| S7 | invoke **当前无鉴权 / 无归属校验**（`FAAS_REQUIRE_AUTH` 对 invoke 不生效）；后端代理强制：路由/方法白名单、路径消毒、剥敏感头、冷启动重试 | `backend/faas.py:249-268(_route_allowed) / 203-213(_safe_route_suffix) / 316-329(头) / 336-361(重试)` | 直连 faasd 会**丢失全部上述保护**（见决策 D-B） |
| S8 | 运行时 bundle 由后端 HMAC 端点下发 | `/api/faas/runtime_bundle/<id>`，token = `HMAC-SHA256(FAAS_RUNTIME_TOKEN, service_id)` | bundle 必须由 **backend** 提供，不能由 faasd 提供 |
| S9 | AI 生成入口：`POST /api/ai/chat/start`（Bearer）→ 轮询 `GET /api/ai/chat/<sid>/result` 取 `client_actions`；`server_deploy_faas_service` → `deploy_bundle` → `faas_service_ready{service_id,invoke_url,routes}` | `backend/claude_chat.py:343`；`backend/ai_session.py:907-987`；`backend/faas_store.py:1330` | e2e 测试驱动点 |
| S10 | MiniMax 已注册：id `minimax`，模型 `MiniMax-M3`，Anthropic 兼容 `https://api.minimaxi.com/anthropic`；默认 provider 是 `deepseek` | `backend/providers/minimax/provider.py:9` | e2e 测试需**显式** `provider=minimax` |
| S11 | **无任何测试跑「真实 AI 生成 → 部署 → 调用」整链**；最接近的是 `scripts/faas_ai_action_smoke.py`（注入已写好的 artifact，不含真实生成） | `backend/test_faas_*.py`、`scripts/faas_*_smoke.py` | 这就是要补的 e2e 缺口 |

---

## 三、锁定的架构决策（Locked Decisions，源自本次需求）

### D-A：faasd 端口收口（封 8080，换不常见内网端口）
- faasd gateway host 端口 **8080 → 8731**（不常见、可配；以下示例用 `8731`）。
- **公网防火墙 DROP** `tcp/8080`、`tcp/8081`（faasd-provider）、`tcp/8731`；仅放行 **docker 网段（172.16.0.0/12）+ loopback**。
- 结果：faasd 对公网**只**经 nginx `:443`（faas 域名）暴露；裸端口全部内网化。

### D-B：双访问（两条都支持）
- **(a) 后端代理（首选）**：`<backend域名>/api/faas/invoke/<id>/<route>` → backend → faasd。
  保留全部校验（S7），且是**多节点路由的唯一通道**。
- **(b) faas 节点独立域名（直连）**：`https://myapp-pre-de-openfaas.dapangyu.work/...` → nginx → 该节点 faasd `:8731`。
  **明确权衡（已接受）**：直连**绕过** S7 的路由/方法白名单、路径消毒、剥头、冷启动重试，且 invoke 本就无鉴权。
  ⇒ 直连域名仅 `location` 放行 `/function/`、`/healthz`，**拒绝 `/system/`**（faasd 管理 API）；敏感操作请走代理。

### D-C：多节点就绪（单机 faasd × N，非集群）
- 我们用的是单机版 faasd（集群版收费，未来也不用）。多个 faas node = 多台各跑单机 faasd 的服务器，各有独立域名。
- **后端按 service 路由到其所属 node**：在 `meta_json.deploy.node_id` 记节点，加一个 `node_id → gateway_url` 注册表，扩展唯一调用点 `openfaas_gateway_for_service`（S5/S6）。
- 本期**只落一个节点**（de-openfaas / 77），但数据模型与解析逻辑按多节点设计，加节点 = 注册 + 分配，不改 invoke 代码。

### D-D：端到端真实测试（本目标的验收核心）
- 一条可重复的 e2e：模拟客户端 → `/api/ai/chat/start`（真实 MiniMax M3 生成）→ 部署 → 两种方式调用 → 更新 → 清理。
- API 层断言为主（结构/状态/可调用/正确返回），不做 UI 自动化；接受真实 AI 的非确定性（见测试目标）。

---

## 四、目标（Goals）

- **G1** faasd 不再监听公网 8080/8081；gateway 内网端口为不常见值（示例 8731）；裸端口公网不可达。
- **G2** faas 独立域名 `myapp-pre-de-openfaas.dapangyu.work` 经 nginx（TLS，复用 `*.dapangyu.work`）**直连** faasd，仅放行 `/function/`、拒绝 `/system/`。
- **G3** 后端代理 `/api/faas/invoke/...` 正常工作，经内网到达 faasd，保留全部校验；为多节点路由预留 `node_id` + 注册表。
- **G4** 函数容器拉 bundle 改走 **backend 域名**（与 faas 域名解耦，D-A 后仍可用）。
- **G5** 已部署服务的 `meta_json.deploy.openfaas_gateway` 完成迁移，封 8080 后不掉线。
- **G6** 一条 `myapp-ctl faas e2e`（或 `scripts/faas_e2e_test.py`）跑通真实 AI 生成 → 部署 → 双访问调用 → 更新 → 清理，并在 77 上绿。
- **G7** 文档（本目标 + README 架构图/roadmap + handoff）同步更新为「端口收口 + 双访问 + 多节点就绪」。

---

## 五、完成标准（Definition of Done）

- **DoD-1** 77 上 `ss -ltnp` 无公网可达的 8080/8081/8731；从**外网**连这三个端口超时/拒绝，从 backend 容器连 `172.18.0.1:8731/healthz` 返回 200。
- **DoD-2** `curl https://myapp-pre-de-openfaas.dapangyu.work/healthz` 经 nginx 命中 faasd 返回 200；`.../system/functions` 被 nginx 拒（403/404），不暴露管理 API。
- **DoD-3** 同一个已部署 service：
  - (a) `POST <backend>/api/faas/invoke/<id>/<route>` 返回预期结果；未声明路由 → 404、未声明方法 → 405（白名单生效）。
  - (b) `POST https://myapp-pre-de-openfaas.dapangyu.work/function/<function_name>/<route>` 可达并返回同样结果（记录：直连不做白名单）。
- **DoD-4** 函数容器以 `FAAS_PUBLIC_BASE_URL=<backend域名>` 成功拉取 bundle 并就绪（冷启动后 invoke 成功）。
- **DoD-5** 旧服务迁移后 invoke 仍成功（迁移脚本/命令有幂等、可重跑、dry-run）。
- **DoD-6**（多节点就绪，非真上量）`openfaas_gateway_for_service` 单测覆盖：有 `node_id` → 解析注册表 URL；无 → 回退全局；注册表缺失 → 明确报错。
- **DoD-7（端到端，核心）** `myapp-ctl faas e2e` 在 77 通过：真实 MiniMax M3 生成一个带后端的应用，自动部署为 faas service，(a)(b) 两种方式均调用成功，更新生效，最后清理释放配额。退出码 0，输出每步证据（service_id、commit、两种调用的状态码/响应摘要）。
- **DoD-8** 9 个既有 faas 单测 + 新增多节点解析单测全绿；`python3 -m py_compile` 通过；`flutter analyze`（如涉及客户端）无新增告警。
- **DoD-9** 77 任何破坏性操作前 `/etc/myapp` 已备份并可还原；本目标不泄露任何密钥到 git / Agent 容器。

---

## 六、修改方法（Modification Methods）

> 原则：**配置驱动优先**（改 myapp-ctl 生成器/setup，使改动随 deploy 可重现），尽量不手改 77 上的生成文件。

### M1 — faasd 端口迁移（D-A，77）
- 改 `/var/lib/faasd/docker-compose.yaml` gateway `ports: "8080:8080"` → `"8731:8080"`（容器内仍 8080，仅换 host 侧）。
- `systemctl restart faasd`；`ss -ltnp | grep 8731` 确认；确认 8080 不再被 faasd 监听。
- faasd-provider `:8081` 保持内网，仅靠防火墙收口（不需要对外）。
- 封装：新增 `myapp-ctl faas faasd-port --host-port 8731 [--apply]`（改 compose + restart + 校验），避免手改漂移。

### M2 — 防火墙收口（D-A，77）
- iptables（或主机现用防火墙）：对**公网网卡**入站 `tcp/8080,8081,8731` DROP；放行 `-s 172.16.0.0/12` 与 `-i lo`。
- 持久化（iptables-save / 主机机制）。封装入 `myapp-ctl faas faasd-harden`（端口 + 防火墙 + nginx 校验一把梭，幂等）。
- 验证：外网 `nc -vz 77 8080/8081/8731` 失败；backend 容器内 `curl 172.18.0.1:8731/healthz` 成功。

### M3 — nginx：faas 域名直连 faasd（D-B，改生成器）
- `scripts/myapp_ctl.py:163` 把 `openfaas` 路由 upstream 由 `http://backend:5566` 改为 `http://host.docker.internal:8731`（faasd 在宿主机，不在 compose 网络）。
- 给该路由用**受限 body**：仅 `location /function/ {…}`、`location = /healthz {…}` 反代，`location /system/ { return 403; }`（拒绝管理 API）。可能需扩展 `_edge_route_body`/`_edge_server_block` 支持「带 deny 的 openfaas 专用 body」。
- `deploy/production/docker-compose.edge.yml` 给 `edge-nginx` 加 `extra_hosts: ["host.docker.internal:host-gateway"]`，重建容器。
- host 配置加 `hosts["openfaas"] = myapp-pre-de-openfaas.dapangyu.work`（`myapp-ctl setup`/host 配置），证书复用通配 `*.dapangyu.work`，无需另签。

### M4 — bundle URL 与 faas 域名解耦（G4，改 setup）
- `scripts/myapp_ctl.py:~4736/4747` 把 `FAAS_PUBLIC_BASE_URL` 由 `urls["openfaas"]` 改为 `urls["backend"]`（runtime bundle 永远由 backend 提供，S8）。
- 重新 `myapp-ctl deploy` 写入 backend env；函数容器以 backend 域名拉 bundle。

### M5 — 后端 gateway 重指 + 多节点钩子（D-C，G3/G5）
- 单节点即时：`FAAS_OPENFAAS_GATEWAY` 由 `http://77:8080` 改为内网 `http://172.18.0.1:8731`（backend 容器→宿主 faasd；或给 backend 也加 host-gateway 用 `host.docker.internal:8731`）。
- 多节点数据模型：`deploy_bundle`（`faas_store.py:1330`）写入 `meta_json.deploy.node_id`；新增配置 `FAAS_OPENFAAS_NODES`（`node_id → gateway_url` 映射，JSON/CSV）。
- 解析扩展：`openfaas_gateway_for_service`（`faas_store.py:358-366`）优先 `node_id` → 查注册表 → URL；查不到再回退 `FAAS_OPENFAAS_GATEWAY`；注册表里 `node_id` 缺失则明确报错（不要静默打到错节点）。invoke 侧（`faas.py:296`）单一调用点不改。

### M6 — 旧服务迁移（G5）
- 写迁移：把所有 `faas_services.meta_json.deploy.openfaas_gateway = http://77.x:8080` 更新为新内网 gateway（或置空让全局生效）并补 `node_id=de-openfaas`。
- 幂等 + `--dry-run` + 迁移后逐个 `health`/`invoke` 抽检。

### M7 — 端到端测试脚本（D-D，G6）
- 新增 `scripts/faas_e2e_test.py` + `myapp-ctl faas e2e`（参照既有 `faas ai-action-smoke`/`faas git-backend-smoke` 的 CLI 形态）。流程见「七、验证步骤」。

---

## 七、验证步骤（Verification Steps）—— e2e 脚本编排

在 77 执行（脚本可本地对 77 base-url 跑，或在 77 上跑）：

1. **备份**：`tar … /etc/myapp`；`myapp-ctl config export`。
2. **取 token**：用测试用户登录拿 Bearer（或沿用 smoke 的测试 token 机制）。
3. **发起生成**：`POST /api/ai/chat/start`，`provider=minimax`、`agent=claude`、`agent_scope=public`，`messages` 内容固定为「做一个带 Python 后端的应用：后端提供 `POST /sum`，入参 `{a,b}`，返回 `{result:a+b}`；并给一个调用它的 JSON-APP」。**契约化 prompt**：明确要求确定的路由/入参/出参，降低非确定性。
4. **等完成**：轮询 `GET /api/ai/chat/<sid>/status` 到 done（超时给足，真实 AI 约数分钟），`GET /result` 取 `client_actions`。
5. **取结果**：从 `faas_service_ready` 取 `service_id`、`invoke_url`、`routes`；断言 `status=ready`。
6. **源真相核对**：`myapp-faas-services` 仓库该用户子树出现新 commit；`faas ls` 能看到该服务。
7. **(a) 代理调用**：`POST <backend>/api/faas/invoke/<id>/sum {a:2,b:3}` → 期望 `{result:5}`；**负向**：`POST .../sum2`→404，`GET .../sum`（未声明 GET）→405。
8. **(b) 直连域名**：`POST https://myapp-pre-de-openfaas.dapangyu.work/function/<function_name>/sum {a:2,b:3}` → 期望 `{result:5}`；记录直连不过白名单。
9. **端口收口校验**（DoD-1/2）：外网连 8080/8081/8731 失败；`https://…openfaas…/system/functions` 被拒。
10. **更新路径**：对同会话再发「把 `/sum` 改成返回 `{result:a+b, by:'v2'}`」→ 重新部署 → 新 commit → 再调用见到 `by:v2`；其他服务不受影响。
11. **清理**：`faas disable <id>` 释放配额并下线；（可选）清 git 子树。
12. **还原**：恢复 `/etc/myapp`（如有破坏性改动）。

---

## 八、测试目标（Test Goals）—— e2e 必须断言什么

- **T1 生成真实**：确实调用了 MiniMax M3（非 mock），产出含可部署的 `faas_bundle.json`（通过严格 AST 校验）。
- **T2 部署真实**：service 状态 `ready`；GitHub 出现该用户子树 commit（严格 git 源真相，D2 of 旧 goal）。
- **T3 代理调用正确 + 白名单生效**：声明路由可调用且结果正确；未声明路由/方法被 404/405 拒。
- **T4 直连可达**：faas 独立域名能直连 faasd 并返回正确结果（接受无白名单）。
- **T5 端口收口**：公网 8080/8081/8731 不可达；`/system/` 不可达。
- **T6 bundle 解耦**：函数容器经 backend 域名成功拉 bundle 就绪。
- **T7 更新生效**：二次生成/重部署后行为改变，且不影响他人/其他服务。
- **T8 配额与清理**：创建计入配额、`disable` 释放配额并下线。
- **非确定性处理**：断言**结构与契约**（status、commit 存在、HTTP 码、JSON 形状/关键字段），不断言 AI 自然语言原文；prompt 用确定的接口契约把可变性收敛到实现细节。

---

## 九、约束（Constraints）

- **C1** Agent 容器永不持有 git/docker/faasd/registry/`/etc/myapp` 密钥；只产出 `faas_bundle.json` + `client_actions.json`。
- **C2** Python + Flask only，沿用严格 AST 校验，放宽只能加窄权限 + 负向测试。
- **C3** 一仓多用户子树隔离；任一用户失败不污染他人/仓库可推性。
- **C4** 不破坏 77 现网 Docker 栈；破坏性操作前备份 `/etc/myapp` 并可还原。
- **C5** 固定运行时镜像，不按服务构建镜像；用户代码经 bundle 下发。
- **C6** faasd 公网仅经 nginx TLS 暴露 `/function/`；裸端口内网化；`/system/` 不公网暴露。
- **C7** 本期只上一个 faas node；多节点只落数据模型与解析钩子，不做真正多机路由上量、不做 invoke 鉴权（`FAAS_REQUIRE_AUTH` 维持现状，单独议题）。
- **C8** 端口号、节点注册表、域名均为配置项，不硬编码进框架逻辑。

---

## 十、风险与待确认（Risks / Open）

- **R1 直连绕过（已接受，需你知情确认）**：D-B(b) 直连域名会绕过路由/方法白名单与剥头，且 invoke 无鉴权。若不希望对外直连，可把 faas 域名也指回 backend（退回 S2 现状，只保留代理）。**默认按你「两种都要」实现，但把 `/system/` 关死。**
- **R2 hairpin**：单机下 (b) 直连是 公网→nginx→faasd 的发卡弯，单机内开销可忽略；多节点时 (b) 直达对应节点更自然。
- **R3 真实 AI 不稳定/超时**：e2e 给足超时 + 重试一次 + 契约化 prompt；失败要打印 `result`/`stream` 摘要便于定位，且不计入"框架缺陷"除非是部署/调用链路问题。
- **R4 迁移遗漏**：M6 必须覆盖所有旧服务的 `openfaas_gateway`，否则封 8080 后旧服务掉线；上线顺序：先迁移/改 gateway → 再封端口。
- **R5 端口占用**：8731 仅为示例，apply 前检查 77 未占用，可改任意空闲高位端口。
- **R6 103 收尾**：旧域名 `myapp-pre-hk2-openfaas-node` 仍指 103（已下线）；DNS 重指/摘除在你侧，本目标不依赖它。

---

## 十一、实施阶段（Phases）

- **P0** 备份 `/etc/myapp`；确认 8731 空闲；e2e 脚本骨架 + 取 token。
- **P1** M5/M6：后端 gateway 改内网 + 旧服务迁移（**先于封端口**，避免掉线）。
- **P2** M1/M2：faasd 换端口 8731 + 防火墙封 8080/8081/8731（`faas faasd-harden`）。
- **P3** M3/M4：nginx openfaas 路由改指 faasd（限 `/function/`、拒 `/system/`）+ `extra_hosts` + `FAAS_PUBLIC_BASE_URL` 改 backend 域名；重建 edge-nginx + deploy。
- **P4** 多节点钩子：`node_id` + `FAAS_OPENFAAS_NODES` + 解析扩展 + 单测（DoD-6）。
- **P5** M7：e2e 脚本（真实生成 → 部署 → 双访问 → 更新 → 清理）+ `myapp-ctl faas e2e`，在 77 跑通（DoD-7）。
- **P6** 回归（9 套 faas 单测 + 新单测）、文档同步（本目标 + README 架构/roadmap + handoff）、还原校验。

---

## 77 测试纪律（沿用）

```bash
tar -C / -czf /root/myapp-etc-backup-$(date +%Y%m%d-%H%M%S).tar.gz etc/myapp
myapp-ctl config export --out /root/myapp-config-backup-$(date +%Y%m%d-%H%M%S).json
```
破坏性步骤后还原；绝不把 `/etc/myapp` 密钥留在需人工重填的状态。
