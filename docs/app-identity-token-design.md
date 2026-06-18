# App Identity Token (AIT) — 凭证模型设计方案

> **状态**：设计草案，**待评审**。本文件**只描述设计，不改任何运行时代码**。
> **代码基线**：`feat/agent-control-plane` @ `f86646d`。所有 `file:line` 引用以该提交为准。
> **关联**：解决 [`interpreter-game-security-review.md`](./interpreter-game-security-review.md) 中的 **C1（`@get_auth_token` + `@http_*` → 会话 token 外泄 → 账号接管）**。
> **方法**：本方案先对真实代码做了接入点勘探（auth / 后端签发面 / registry / FaaS / 客户端），再用 6 路对抗红队（47 条攻击）对模型做了加固，下文的每条设计约束都对应一条已识别的攻击。

---

## 1. 背景与目标

### 产品约束（不可动摇）
1. **开放出口是特性**：JSON App 可以调用**任意**后端——一方（`*.dapangyu.work`）、平台 FaaS、或完全第三方。**不限制目的地。**
2. **生态身份联合是核心能力**：第三方 app（如"围绕平台做的抖音"）必须能拿到一个凭证，让它**自己的**（哪怕完全第三方的）后端回调平台**验证用户身份**。这是 "Sign in with MyApp" / OIDC，不是平台访问授权。
3. **不砍功能**：app 作者的开发体验尽量不变。

### 安全目标
> **要保护的是"凭证"，不是"目的地"。** 危险不是"app 能连 evil.com"，而是"app 能拿到**账号主凭证**并能连 evil.com"——经典 confused deputy。

因此核心动作不是"禁止 app 拿令牌"，而是**让 app 能拿到的令牌，泄漏了也干不成大事**。

---

## 2. 核心原则（红队验证后的硬约束）

| # | 原则 | 对应红队攻击 |
|---|------|------------|
| P1 | **主 session token（Supabase access/refresh）永不进入 JSON 可读状态**。仅存在于原生层，经 Dio 拦截器注入给一方后端。 | `master-isolation` 全部、`trusted-turns-evil#7` |
| P2 | **拆分两类令牌**：身份断言（AIT，可外发）vs 访问凭证（主 token，原生专用）。二者是**不同 token class**：不同 `typ`、专用签名密钥、`require_auth` 永不接受 AIT 的 kid。 | `aud-confusion#1`（AIT 被一方端点当鉴权用） |
| P3 | **信任 = provenance + scope + revoke + version**，不是单一"是否可信"。信任单元是 **(appid, version, content-hash)**，不是裸 appid。 | `trusted-turns-evil` 全部 |
| P4 | **同意（consent）与 scope 在签发端（issuer）强制**，客户端只能抑制重复弹窗，绝不能作为权威。 | `consent-scope#2,#3` |
| P5 | **`@get_auth_token` 移除主 token 暴露，是上线 AIT 的硬前提**（同批次发布，不可滞后）。只要还有一条路把主 token 交给 JSON，整套 consent/scope 就**不可执行**。 | `consent-scope#7`、`master-isolation#1`、多处重复 |

---

## 3. 令牌模型

### 3.1 三类令牌

| 令牌 | 持有者 | 能干什么 | 生命周期 | 是否进 JSON |
|------|--------|----------|----------|------------|
| **Master session token**（Supabase access+refresh） | 原生层 | 一方平台 API（IM、profile、registry、storage） | access ~短、refresh 轮换 | **永不** |
| **App Identity Token (AIT)** | JSON App（可外发给任意后端） | 向 AIT 的 `aud` 资源**断言"这是用户 U（对该 app 的化名）"**；`scope=identity` | **≤300s**（elevated ≤60s） | ✅（`@get_auth_token` 改为返回它） |
| **Scoped access token**（可选，后续阶段） | JSON App，经显式 consent | 在平台上替用户做**受限**操作（按 scope） | ≤60s + 强制在线 `/verify` | ✅，但高 tier app + consent |

### 3.2 AIT claim 结构

```jsonc
// JWT header
{ "alg": "RS256", "typ": "ait+jwt", "kid": "<platform-issuer-key-id>" }
// JWT payload
{
  "iss": "https://myapp-backend.dapangyu.work",     // 平台 issuer（专用，非 Supabase）
  "sub": "<pairwise>",      // 按 sector 化名：HMAC(server_secret, user_id, sector) — 见 §10
  "aud": "<resource-id>",   // 具体注册资源 id（FaaS=service_id；第三方=registry 颁发的不透明 id），不是裸 origin
  "azp": "<appid>",         // 实际运行的顶层 app（registry 校验过的）
  "app_trust": "official|verified|unverified|local",  // 签名进 claim，验证方不必再信裸 appid
  "app_ns": "<namespace>",
  "scope": "identity",      // 默认仅 identity；更高 scope 需 consent + tier 允许
  "token_use": "identity",  // 与访问令牌硬区分
  "iat": 0, "nbf": 0, "exp": 0,   // exp-iat ≤ 300s
  "jti": "<uuid>",          // 重放/吊销追踪
  "nonce": "<RP-issued>",   // 高价值流程：由依赖方下发、回显校验（唯一离线可行的防重放）
  "cnf": { "jkt": "<dpop-thumbprint>" }  // 可选：发送方约束（DPoP），见 §9.6
}
```

### 3.3 token class 硬隔离（防 `aud` 混淆 / 越权）
- AIT 用**专用 issuer 密钥对**签名（与 Supabase、agent-node、APNs 密钥**全部隔离**；后端今天**没有**平台 issuer key，需新增——见 §6.6）。
- `require_auth`（一方鉴权网关 `backend/auth.py:122`）**只接受 Supabase session token，显式拒绝任何带 AIT issuer/kid/`typ=ait+jwt` 的令牌**。
- **保留 audience 黑名单**：minter 拒绝签发 `aud` 命中任何一方主机（`*.dapangyu.work`、auth/registry/IM/storage/agent-node）的 AIT。
- **`aud` 不是裸 origin**，而是绑定到**具体服务/资源 id**：FaaS = `service_id`；第三方 = registry 在 `/publish` 时记录并**域名验证过**的资源标识。验证方必须**精确匹配** `aud`（不得前缀/子串匹配）。

---

## 4. 信任模型

### 4.1 信任分级（scope 天花板按 tier，服务端强制）

| Tier | 来源 | scope 天花板 |
|------|------|------------|
| **official** | admin 发布、无命名空间包（`registry_server.py:1058-1061` 现有判定，但需替换 `REGISTRY_ADMIN_TOKEN` 静态绕过） | 最高（仍需 per-scope consent） |
| **verified** | 命名空间所有者经**真实验证**（域名控制证明 / 发布者 2FA / 人工审核），非"建个账号就行" | 中（identity + 经 consent 的受限 scope） |
| **unverified** | 普通命名空间包 | 仅 `identity` |
| **local** | 本地 sideload 的 JSON | 独立 principal，**永不**继承任何 registry appid 的身份/授权 |

> 红队：今天 tier 只有 `official`/`user` 二值（`registry_server.py:1058`），且 `REGISTRY_ADMIN_TOKEN` 可铸造合成 admin（`registry_server.py:131-154`）。设计要求：**新增 `trust_tier` 列 + 真实验证流程**；**官方发布禁用静态 admin token**，改为短时、可审计、2FA 的 per-operator 凭证。

### 4.2 信任单元 = (appid, version, content-hash)
- 红队 `trusted-turns-evil`：被信任 app 会失守（发布者被盗、恶意更新、供应链）。**裸 appid 不能作为信任锚**。
- 要求：
  1. `/publish` 记录**每版本 content-hash**，经 `/resolve_appid` 暴露；
  2. consent grant 与 AIT 签发 key 在 **(appid, major-version 或 content-hash)** 上——版本变化/scope 扩大 **强制 re-consent**，不继承旧授权；
  3. 提供**版本钉选**（"运行 app X"可钉到已审版本，而非永远 latest）；
  4. appid 由**服务端 re-resolve**（`/resolve_appid` `registry_server.py:481-537`）确认 appid→package→author/namespace，**不信客户端自报 appid**（`registry_server.py:864` 今天是客户端自报 UUID）。

---

## 5. 同意与授权（Consent）

- **签发端强制**：`/api/auth/identity-token` 对任何超出基线 `identity` 的 scope，必须存在服务端 consent 记录 `(user_sub, appid, scope[], version/hash, granted_at)`，否则拒签或静默降权。
- **scope = 交集**：`min(requested, granted)`，绝不把 requested 原样写进 JWT。
- **每个 scope 独立 consent**：`identity` 同意**不蕴含**任何数据/操作 scope；高权限 scope 首次请求必弹窗，且展示 scope diff（"此应用现在还想要 X"）。
- **可信 UI 写入**：consent 由原生可信 UI 流程（主 token 原生调用 `/api/auth/consent`）写入，**JSON 或 SharedPreferences 不能伪造**；客户端缓存只用于抑制重复弹窗。
- **新增"管理应用权限 / 撤销"界面**（今天不存在）：用户可查看并撤销某 app 的授权或全部会话。

---

## 6. 后端：签发与验证

> 复用现成原语：`PyJWT[crypto]` 已是依赖；RS256 mint+verify 已在 agent-node 跑生产（`agent_node_service.py:1764` 签 / `ai_session.py:2175` 验）；per-principal 公钥库已存在（`agent_node_registry.py:37`）。**AIT 是增量，不是从零。**

### 6.1 `POST /api/auth/identity-token`（铸造 AIT）
- 注册位置：`backend/app.py:59-68` 现有 `/api/auth/*` 块旁，套用 `@require_auth`（`auth.py:122`）先用主 token 认证用户。
- 入参 `{appid, aud, scope?, nonce?, dpop?}`；流程：
  1. `require_auth` → `request.supabase_user`（拿 user_id、role）；
  2. **服务端 re-resolve appid**→package→(namespace, author_id, trust_tier, content-hash)；拒绝客户端自报且无法核实的 appid；
  3. 校验 `aud` ∈ 该 appid 在 registry **域名验证过**的资源 allowlist；命中保留主机黑名单则拒；
  4. scope = 交集(requested, consent 记录, tier 天花板)；
  5. `sub` = pairwise（§10）；
  6. `jwt.encode(...)` 复用 `agent_node_service.py:1764-1775` 的 claim 形态与调用方式，用**平台 issuer 私钥**签名。
- （可选）要求 DPoP proof 匹配主 token 的 `cnf`，使裸主 token 字符串无法铸造 AIT。

### 6.2 `GET /.well-known/jwks.json`（公钥）
- 多 key + `kid`（仿 `agent_nodes.py:134` kid=pubkey 的 sha256）；`Cache-Control: max-age ≤ 600s`（密钥撤销延迟 = 此 max-age，故要短）；轮换留重叠窗口。

### 6.3 `POST /api/auth/verify`（RFC7662 introspection）
- 返回 `{active, sub, scope, aud, azp, exp, jti, app_trust, revoked_reason?}`；查 per-app 撤销标志 + jti 黑名单 + 主 session 存活；正向结果缓存 ≤ `min(exp, 60s)`。
- elevated scope 的 AIT 带 `introspection_required` claim，明示验证方**必须**在线验。

### 6.4 Consent 存储 + endpoints
- 新表 `app_consents(user_id, appid, version_or_hash, scope[], granted_at, revoked_at)`；`POST /api/auth/consent` 写入（原生主 token 调用）；`/manage` 列出/撤销。

### 6.5 Registry 扩展（新增字段——今天全无）
- `declared_backend_origins`（每 app，**域名控制证明**后才能成为 `aud` allowlist 源）；
- `requested_scopes`；`trust_tier`（替代二值）；`content_hash`（每版本）。
- 落点：`_index.json` 包条目（`registry_server.py:1059-1074`）+ `registry_packages`（`schema.sql:75-99`）+ `namespaces`（`migrations/001_*.sql`）加 `verified/trust` 列。

### 6.6 专用 issuer 密钥
- `backend/config.py:43` 今天只有 Supabase keys。新增**独立** RSA/EC issuer keypair（`.env.example` + config）；**绝不复用** agent-node / APNs 密钥；定义轮换与紧急撤销（JWKS 删 kid + `/verify` 维护 revoked-kid 列表）。

---

## 7. 验证配方与"离线 vs 在线"分层

**第三方必须检查**（发布规范化 recipe，并提供平台 `/verify` 让第三方不必自己实现）：
`iss` + **精确 `aud`** + `azp`==预期 appid + `exp`/`nbf`(leeway≤60s) + `typ=ait+jwt` + `nonce` 回显 + 签名（按 `kid` 取 JWKS）。**裸"签名+iss"不充分。**

| scope | 验证方式 | 理由 |
|-------|----------|------|
| `identity`（仅断言"是谁"） | 离线 JWKS 可接受，保护**仅靠 ≤300s 短 exp** | 第三方后端可能离线；身份断言低敏感 |
| 任何**作用于用户平台数据**的 scope | **必须在线** `/verify`（经过 Flask choke point：吊销 + jti + 异常检测） | logout/吊销需秒级传播；纯离线 JWKS 无法吊销 |

> 红队 `revocation-freshness`：logout 不会传播到离线验证方——**AIT 的 exp 就是离线验证方的吊销 SLA**，故 identity ≤300s、elevated ≤60s + 强制在线。平台只能管控"经过平台的回路"，管不了纯外部第三方自己的后端——文档需明示此边界。

---

## 8. FaaS 集成（让 app 自由调 FaaS 且函数能识别用户）

- 现状：`invoke_service`（`faas.py:291-395`）**剥掉** Authorization/cookie/身份头（`faas.py:336-349`），函数拿不到调用者身份；invoke URL 是相对 `/api/faas/invoke/<service_id>`（`ai_session.py:203`）→ **同一方 origin**。
- 设计：**FaaS 按第三方对待**（AIT 消费者，**非**主 token 消费者）：
  1. JSON App 取 `aud=service_id, azp=appid, scope=identity` 的 AIT；
  2. invoke proxy **转发前校验** AIT：`iss/typ/exp/nonce` + **`aud == 被调 service_id`**，不符 403；
  3. 通过后用**专用不剥离头** `X-MyApp-Identity-Token` 注入给函数；
  4. 主 token 拦截器**显式排除** `/api/faas/invoke/*`（虽同 origin）。
- 红队 `aud-confusion#7`：否则 AIT 在平台内被跨租户/跨服务复用。

---

## 9. 客户端改造

### 9.1 移除主 token 暴露（**P0，与 AIT 同批**）
- 重写 `@get_auth_token`（`interpreter.dart:2441`）：**不再返回 `AuthService.token`**，改为按 `_appId`（`interpreter.dart:42, 566-570`）+ consent 铸造/返回 **AIT**。
- `AuthService.token` getter（`auth_service.dart:78`）对解释器层**不可达**（移到 DSL 调不到的原生一方签名器后）。
- **CI lint 断言**：任何 DSL builtin 不得引用 `AuthService.token`/`_accessToken`。任何残留主 token 返回路径 = 发布阻断项。

### 9.2 Dio 拦截器（主 token 自动注入，仅一方）
- 落点：`DslHttpClient._internal()`（`http_client.dart:16-24`，今天无 interceptor）。
- 规则（红队 `master-isolation`）：
  - **硬编码、原生专用、精确 route-prefix allowlist**（如 `/api/auth`、`/api/im`、registry publish），**不是**宽泛 origin 匹配；
  - **硬拒 `/api/faas/invoke/*`**；
  - 仅对**原生发起**的请求注入（per-request 原生标志，DSL 不能设）→ JSON 拼出的指向一方主机的请求**拿不到**主 token；
  - 携带主 token 的请求 `followRedirects:false` 或在重定向跨 origin 时剥 `Authorization`；`maxRedirects` 上限。

### 9.3 响应头泄漏通道
- `_buildResult`（`http_client.dart:376-383`）返回给 JSON 的 headers **必须 strip** `Authorization`/`Set-Cookie`/`x-*-token` 等；定义**响应头白名单**。

### 9.4 `@get_user_info` 化名化
- `interpreter.dart:2429-2439`：返回**按 appid 化名的 subject + 已 consent 的字段**，绝不返回原始 Supabase id/email/`app_metadata.role`。

### 9.5 Consent UI
- 复用 `_showAlertDialog/_showChoiceDialog`（`interpreter.dart:3286-3381`）+ `globalContext`（`interpreter.dart:138`、`main.dart:2861`）做"App X 想用你的身份"弹窗；grant 写服务端（§5）。

### 9.6 设备绑定 / DPoP（纵深防御，分平台）
- 移动/桌面：主 token 经 `cnf/jkt` 发送方约束，私钥放 hardware-backed keystore（StrongBox/SecureEnclave/TPM）+ 平台证明（Play Integrity / App Attest）；服务端按 `cnf` **拒绝无匹配 DPoP proof 的呈现**（无 per-request 回退）。
- **Web**：无安全 keystore——主 token **本就永不进 JSON 层**是关键；用非可导出 WebCrypto key 做 DPoP（只挡离线重放，不挡同源滥用）；web 列为"不可硬件绑定" tier，主 token 更短 TTL、不签发高 scope；XSS/扩展为已接受残余，要求 CSP + 同源隔离。
- AIT 铸造本身要求 DPoP proof 匹配主 token `cnf`，使裸主 token 字符串不能铸造 AIT。

---

## 10. 隐私：pairwise 化名 sub

- 默认 **pairwise pseudonymous sub**：`sub = HMAC/HKDF(server_secret, user_id, sector)`，`sector` = app 的**已验证命名空间所有者**（或经 registry 校验的 `sector_identifier`）。
  - 不同 sector → 同一用户呈现**不同、不可关联**的 sub（杜绝跨 app 追踪）；
  - 同一发布者的 app 家族**显式 opt-in** 共享 sector → 合法 SSO；
  - `server_secret` 是**服务端密钥**（非公开 salt），第三方无法预算 `user_id↔sub`。
- 真实身份（email/姓名）**只经显式 consent 的 `verified-email`/`profile` scope** 暴露，绝不经 `sub` 泄漏。
- 验证方持久化的用户键必须是 **(iss, azp, sub) 三元组**，绝不单用 `sub`。

---

## 11. 威胁 → 缓解 速查（红队 47 条浓缩）

| 攻击类 | 关键缓解（章节） |
|--------|------------------|
| AIT 被一方端点当鉴权 / `aud` 混淆 | token class 硬隔离 + reserved-aud 黑名单 + `aud`=资源id 非裸origin + 精确匹配（§3.3, §7） |
| 两 app 共享 origin 致 AIT 互通 | `aud` 绑 service_id/不透明资源id，验证方查 `azp`（§3.3, §8） |
| 客户端伪造 consent / scope 越权 | issuer 端强制 + scope=交集 + 服务端 grant（§5） |
| 自报 appid 冒充 / appid 重指 | 服务端 re-resolve appid→provenance，签 `app_trust/app_ns`（§4.2, §6.1） |
| 被信任 app 失守 / 恶意更新 | 信任单元=(appid,version,hash) + 版本变更 re-consent + 版本钉选 + revoke-by-version（§4.2） |
| logout 不传播 / 重放 | exp≤300s（elevated≤60s）+ 强制在线 /verify + jti 黑名单 + RP 下发 nonce 回显（§7） |
| 密钥泄漏无法撤销 | 专用 issuer key + kid + 多key JWKS + 短 Cache-Control + revoked-kid（§6.2, §6.6） |
| 主 token 残留路径 | 移除 @get_auth_token（P0）+ 拦截器精确 allowlist + 排除 faas + 剥响应头 + 重定向不带凭证（§9.1-9.3） |
| 跨 app 用户关联（隐私） | pairwise 化名 sub keyed by sector（§10） |
| Web 无法设备绑定 | 主 token 不进 JSON 是底线；web 降级 tier + 更短 TTL + 不签高 scope（§9.6） |

---

## 12. 迁移路线（分阶段）

| 阶段 | 内容 | 价值 |
|------|------|------|
| **P0（同批次，硬前提）** | ① 后端 issuer key + `POST /api/auth/identity-token`（仅 `identity` scope）+ JWKS；② 客户端 `@get_auth_token` 改返回 AIT、主 token 移出 JSON、加 Dio 一方拦截器、`_buildResult` strip 头；③ registry 加 `declared_backend_origins`(域名验证) + `content_hash`。 | **直接消除 C1 账号接管**，功能不丢（一方调用走拦截器、第三方身份走 AIT） |
| **P1** | `@get_user_info` 化名化 + per-app consent UI + grant 存储 + 管理/撤销界面 + `/api/auth/verify` introspection。 | 高权限可控、可撤销 |
| **P2** | 真实 trust_tier + 验证流程、版本钉选/按版本撤销、FaaS invoke 校验 `aud` 转发 `X-MyApp-Identity-Token`、替换 `REGISTRY_ADMIN_TOKEN` 官方发布路径。 | 供应链/越权收敛 |
| **P3** | DPoP/设备绑定 + 平台证明 + 异常检测、pairwise sub 的 sector 分组、scoped access token（替用户操作平台数据）。 | 泄漏即废、隐私、可控的平台代操作 |

---

## 13. 残余风险（明示边界）
- **rooted/越狱设备**抽取绑定私钥克隆 DPoP：靠短 exp + 撤销 + 平台证明分级收敛，不能根除。
- **Web 同源内滥用**（XSS/扩展）：靠"主 token 永不进 JS 可达层" + CSP + 同源隔离，属已接受残余。
- **第三方收到 AIT 后长期留存**：靠 `aud` 锁定 + ≤300s exp + RP nonce + （高 scope）在线 /verify + 撤销收敛；平台管不了纯外部第三方自身后端的留存。

## 14. 开放问题（待你拍板）
1. **是否要 P3 的 scoped access token**（让 app 替用户操作平台数据）？还是平台数据操作只走一方原生路径、第三方一律只给 identity？
2. **sector 默认粒度**：按 appid（最严，同发布者多 app 也不互通）还是按 verified-namespace 所有者（同发布者 app 家族可 SSO）？建议后者 + 显式分组。
3. **域名验证强度**：第三方 `aud` origin 用 well-known 文件证明还是 DNS TXT？
4. **DPoP 上线时机**：P3 够不够，还是主 token 一开始就要 cnf 绑定？

---

## 附：可复用的现有原语（file:line）
- `backend/agent_node_service.py:1764-1775` — RS256 短时 JWT 铸造（iss/sub/aud/iat/exp/jti），AIT 直接照搬形态。
- `backend/ai_session.py:2175-2196` — RS256 验证（先 unverified decode 读 sub → 查公钥 → 验签+aud），`/verify` 与第三方验证镜像此模式。
- `backend/agent_node_registry.py:37` — per-principal `auth_public_key` 库，类比平台 JWKS / per-app key。
- `backend/push/apns_provider.py:59` — ES256 `jwt.encode` + kid，第二处 PyJWT 非对称签名实证。
- `backend/auth.py:122,140` — `require_auth` / `verify_access_token`，铸造 AIT 前认证用户的网关。
- `backend/registry_server.py:481-537,864-922,1058-1074` — appid 解析 / 发布 / 包条目，client registry 骨架。
- `backend/faas.py:57-83,291-395,336-349` — FaaS 控制面/数据面 auth 与剥头逻辑，AIT 注入点。
- `lib/auth/auth_service.dart:78` — 主 token getter（待封进原生签名器）。
- `lib/json_ui/interpreter.dart:42,566-570,2429-2447,138` — `_appId`、`@get_auth_token`/`@get_user_info`、`globalContext`。
- `lib/json_ui/http_client.dart:16-35,376-383` — Dio 实例（拦截器落点）、`_resolveUrl`（origin 分类器）、`_buildResult`（响应头泄漏）。
