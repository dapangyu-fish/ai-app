# RFC：JSON-APP 音频支持（录音 / 播放 / 上传 / 可复用音频 UI 与 action）

> 状态：**提案（待实现）** · 作者：平台团队 · 创建：2026-06-29
> 关联：`JSON-DSL.md`（游戏 `@audio.*` action、`@request_permission` 权限、`@pick_image` / `@file_to_base64` builtin）、`backend/im_media.py`（预签名上传网关）、IM 媒体上传链路（`lib/im/im_media_uploader.dart`）

---

## 1. 背景与问题

平台已经把一套**完整可用**的音频播放引擎落进了 flame 游戏层（`lib/games/game_audio.dart`），底层依赖（`audioplayers` / `record` / `permission_handler`）也都在 `pubspec.yaml` 里就位，麦克风权限在三端均已声明。但这些能力**100% 封闭在游戏作用域**，普通 JSON-APP（不含 `flame_game` 的 `widget_builder` + `interpreter` builtin 路径）**完全没有**播放、录音、音频 widget 或音频上传通道。

具体表现为三个结构性缺口：

1. **播放只在游戏里有**。`@audio.play / @audio.stop / @audio.pause / @audio.resume / @audio.set_volume` 这 5 个 action 由 `GameActionEvaluator` 分发（`lib/games/game_actions.dart:610-640`），转发到 `game.audio.*`，**不是** interpreter 的全局 builtin。模板里所有 `@audio.play` 调用都落在 `flame_game` 块内。`JSON-DSL.md:1990-1993` 也明确把这组 action 归到游戏引擎章节，`audio` 配置块（`JSON-DSL.md:1777-1798`）是 `flame_game` 的子字段。普通 JSON-APP 想播一段语音/提示音/背景音，**无任何 DSL 入口**。

2. **录音能力没暴露给 DSL**。`record` 包目前**唯一**的生产用法是 ASR：`lib/designer/bytedance_asr_service.dart` 用 `AudioRecorder.startStream(...)` 做 16k PCM 流式识别（`:120/133-139/224`），返回的是**识别文本**，既不落地音频文件、也不暴露给 JSON-APP。

3. **音频文件无上传通道**。后端预签名网关 `backend/im_media.py` 的 `purpose` 维度只有 `image/snapshot/video/file`（`SIZE_LIMITS :51-56`、`ALLOWED_MIME_PATTERNS :60-84`、`ALLOWED_EXT :87-96`），MIME 白名单无 `audio/*`，ext 白名单无 `m4a/mp3/wav/aac/ogg`，连 `file` purpose 也不含音频后缀。客户端 `ImMediaPurpose` enum（`lib/im/im_media_uploader.dart:31-43`）只是后端白名单的镜像，同样没有 `audio`。

### 目标场景（产品描述）

> 一个 JSON-APP（如语音笔记、语音消息、有声内容、口语练习）需要：
> - 点按钮**播放**一段网络音频 / 本地文件 / asset；带暂停、进度、时长；
> - 点按钮**录音**，停止后拿到本地文件路径与时长；
> - 把录音**上传**到对象存储拿一个公开 URL（用于发消息 / 存档 / 二次播放）；
> - 上层 JSON-APP 直接引用一套**可复用音频 UI 组件**（录音按钮、语音气泡、音频列表项），无需自己拼 widget。

## 2. 目标与非目标

**目标**
- 把**播放**能力从游戏层下沉为通用引擎，并在 interpreter 暴露全局 builtin（播放 / 暂停 / 停止 / seek / 状态查询），支持 URL / asset / **本地文件**三类 source。
- 新增**录音** builtin（开始 / 停止），落盘为可存档格式，停止后返回本地文件 path + 时长。
- 新增音频**上传**通道：后端加 `audio` purpose，客户端复用 `ImMediaUploader`，提供 DSL 便捷 action。
- 新增 `type:"audio"` **播放器 widget**（播放/暂停 + 进度条 + 时长），以及一份可复用音频 UI lib（`lib_audio.json`）。
- 复用已就绪的麦克风权限链路与现有上传基建，**不新增第三方包**。

**非目标（本期不做）**
- 不改 flame 游戏侧的 `@audio.*` 语义与 `tracks/sounds` catalog（只把底层播放器池下沉为共享层，游戏侧保持薄封装）。
- 不做音频编辑 / 剪辑 / 波形可视化 / 变速变调。
- 不做「边录边转写」的 ASR 集成（与本期纯落盘上传是两套配置，留待评估，见 §10）。
- 不强行覆盖 Web 端录音（`record` 在 Web 需 MediaRecorder + opus/webm，`audioplayers` Web 后端受限，见 §10）。

## 3. 术语

| 术语 | 含义 |
|------|------|
| **共享音频引擎** | 待新增的 `lib/json_ui/audio/audio_engine.dart`：通用播放器池 + source 解析（URL/asset/本地文件）+ loop/volume，供普通 JSON-APP 与游戏层共用。|
| **source** | 音频来源字符串：`http(s)://…`（网络）/ `assets/…`（打包资源）/ 本地文件绝对路径（录音回放）。|
| **handle / id** | 播放实例标识。播放时分配（或由 JSON 指定），供后续 `@audio_pause/stop/seek/status` 定位同一条播放，支持多实例并发。|
| **recording** | 一次录音会话；`@record_start` 开启，`@record_stop` 结束并产出本地文件 path + duration_ms。|
| **purpose** | 预签名上传网关的用途维度（`backend/im_media.py`），决定 MIME/ext/size 白名单与对象 key 前缀。本期新增 `audio`。|
| **音频 UI lib** | 待发布的 `templates/lib_audio.json`：把 builtin + widget 封装为命名函数/组件，供上层 JSON-APP 依赖引用（与 `lib_im` / `lib_user` 同模式）。|

## 4. 总体设计

分四层，自下而上；**复用已实现资产**与**待新增**用标注区分：

```
① 共享引擎层   lib/json_ui/audio/audio_engine.dart【待新增】
                  播放器池(loop/one-shot) + source 解析(URL/asset/本地文件) + volume/seek/position
                  ↑ 下沉自 game_audio.dart【已实现，复用其 looping/one-shot/_sourceFor 资产】
                  ↑ 必须新增本地文件分支 DeviceFileSource（现 _sourceFor 只认 URL/asset，:185-194）
      │
② DSL builtin 层  interpreter.dart 全局 builtin【待新增】
                  播放：@audio_play / @audio_pause / @audio_stop / @audio_seek / @audio_status
                  录音：@record_start / @record_stop（仿 @pick_image 契约，:3618 写 bind + 返 path）
                  上传：@upload_audio → 复用 ImMediaUploader【已实现】
                  权限：@request_permission({type:"microphone"})【已实现，:1535-1549 / :3840-3841】
      │
③ widget 层    JsonAudioWidget(type:"audio")【待新增】
                  播放/暂停按钮 + 进度条 + 时长，内部用①；仿 video_widget 的 StatefulWidget 封装
                  注册进 widget_builder._builders（参照 'video':JsonVideoWidget，widget_builder.dart:86）
      │
④ 后端 + lib   im_media.py 加 purpose=audio【待新增】 + ImMediaPurpose.audio 镜像【待新增】
                  templates/lib_audio.json 可复用音频 UI 组件【待新增】
```

两类音频流向都走同一套引擎与上传：
- **播放流**：JSON 指定 source（URL/asset/本地路径）→ 共享引擎播放，分配 handle 供控制。
- **录音流**：`@record_start` 落盘 → `@record_stop` 返回 path → `@upload_audio` 直传对象存储拿公开 URL → 该 URL 既可回放、也可入消息/存档。

## 5. 详细设计

### 5.1 共享音频引擎（下沉 `game_audio`，新增本地文件 source）

> 现状：`lib/games/game_audio.dart` 的 `GameAudioController` 是**唯一**已实现的播放引擎，且很成熟——循环音用持久化 `_loopingPlayers` map（每 id 一个 `AudioPlayer`，`ReleaseMode.loop`，`:38-42/147-167`），一次性音效用 `_oneShotPlayers` set，播完自动 `dispose`（`:44-52/169-183`），`setVolume` 已 `clamp(0,1)`（`:101-107`），`dispose()` 统一回收（`:109-120`）。但它绑了 `assetManager`（`:9-11`）和游戏生命周期，且 `_sourceFor`（`:185-194`）只解析 **URL（http/https）→ `UrlSource`** 与 **asset → `AssetSource`**。

**做法（待新增）**：新建 `lib/json_ui/audio/audio_engine.dart`，把「播放器池 + source 解析 + volume/loop」下沉为通用层；`GameAudioController` 改为薄封装，保留游戏侧 `tracks/sounds` catalog 语义（`configure` / `_readGroup`，`:17-24/122-145`）与 `assetManager.resolve`（`:128-138`）。

**关键缺口补强（必须新增）**：
1. **本地文件 source 分支**。在下沉后的 source 解析里，URL/asset 之外加一支 `DeviceFileSource(path)`——录音回放与「下载到本地再播」都依赖它。现 `_sourceFor` 完全不认本地路径（`game_audio.dart:185-194`）。
2. **seek**。现引擎无任何 `player.seek` 调用；新增 `seek(handle, positionMs)`。
3. **position / duration / onComplete 上报**。现引擎只 `play/stop/pause/resume/setVolume`，不读 position/duration，也不把 `onPlayerComplete`（仅内部用于 one-shot 回收，`:46-49`）透传给上层。新增 position/duration 轮询或事件流 + onComplete 回调，桥接到 DSL（见 §5.6）。
4. **多 handle 并发**。游戏层已是多实例池（按 id 索引），通用层沿用：播放分配 handle，普通 JSON-APP 也能背景音 + 音效叠加（并发模型取舍见 §10）。

### 5.2 播放 builtin（interpreter 全局）

> 现状：`interpreter.dart` 全表无任何 audio/play/seek 的全局 builtin（仅 flame 内有 `@audio.*`）。`widget_builder.dart` 已注册 91 个 widget 类型，含 `'video':JsonVideoWidget()`（`:86`）、`'camera':JsonCameraWidget()`（`:124`），但**无 audio**。

**新增 builtin**（命名沿用 flame 的 `audio` 语义，置于 interpreter 全局；为与全局 builtin 的下划线风格一致用 `@audio_*`）：

| builtin | 入参 | 行为 |
|---|---|---|
| `@audio_play` | `{ src, loop?, volume?, handle?, bind_handle? }` | 经共享引擎播放 `src`（URL/本地路径/asset）。未传 `handle` 则分配一个，写入 `bind_handle` 变量供后续控制。`loop` 默认 false，`volume` 0..1。 |
| `@audio_pause` | `{ handle? }` | 暂停指定 handle；不传则暂停全部。 |
| `@audio_stop` | `{ handle? }` | 停止并释放指定 handle；不传则全停。 |
| `@audio_seek` | `{ handle, position_ms }` | 跳转到指定毫秒。 |
| `@audio_status` | `{ handle, bind }` | 把当前 `{state, position_ms, duration_ms}` 写入 `bind` 变量。 |

> 复用参照：`@audio_play` 的入参/handle 设计对齐游戏侧 `@audio.play`（`game_actions.dart:611-621` 的 `id/source/loop/volume/restart`），但底层走共享引擎而非 `game.audio`。

### 5.3 录音 builtin（仿 `@pick_image` 契约）

> 现状：`record` 包仅在 ASR 流式场景用（`bytedance_asr_service.dart`，16k PCM、socket.io 发后端），不落盘、不返回 JSON-APP。麦克风权限链路**已全就绪**：DSL 侧 `@request_permission({type:"microphone"})` / `@permission_status`（`interpreter.dart:1535-1549`），`_parsePermission` 已映射 `microphone → Permission.microphone`（`:3840-3841`），`speech` 也已支持（`JSON-DSL.md:511`）；平台声明齐备——Android `RECORD_AUDIO`（`AndroidManifest.xml:4`）、iOS `NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`（`Info.plist:59-62`）、macOS `audio-input` entitlement（`DebugProfile.entitlements`）。**录音权限零额外配置。**

**契约范本**：`@pick_image` → `_pickOrTakeImage`（`interpreter.dart:3618-3663`）把 `XFile.path` 写进 `bind` 变量并返回路径。录音 builtin 采用**完全相同**的「返回本地文件路径 + 写 bind」契约：

| builtin | 入参 | 行为 |
|---|---|---|
| `@record_start` | `{ encoder?, sample_rate?, bind_recording? }` | 调 `record` 包的 `start(path:)`（**落盘模式，非 `startStream`**）开始录音，handle 写入 `bind_recording`。默认编码 `aac` / 容器 `m4a`（跨端通吃、体积小）；ASR 用的 `pcm16bits` 不适合存档，不作默认。先经 `@request_permission` 确保麦克风已授权。 |
| `@record_stop` | `{ bind }` | 停止录音并把 `{ path, duration_ms, size }` 写入 `bind` 变量、返回 path。`path` 是本地文件绝对路径，可直接喂给 `@audio_play`（§5.2 本地文件分支）或 `@upload_audio`（§5.4）。 |

> 复用参照：`record` 包的权限检查（`bytedance_asr_service.dart:120` 的 `hasPermission()`）与 `RecordConfig` 编码选型经验可借鉴，但本期走 `start(path:)` 落盘而非流式。

### 5.4 录音上传（后端加 `audio` purpose + 复用 `ImMediaUploader`）

> 现状（后端）：`backend/im_media.py` 流程成熟——POST 拿预签名 PUT（15min，`:99/211`）→ 客户端直传 `im-media` 桶 → 返 public GET URL（桶 public-read，`:130-148`）。但 `purpose` 校验只认 `SIZE_LIMITS` 里的 4 个（`upload_url` 在 `:186` 处 `if purpose not in SIZE_LIMITS` 直接 400），且 `_validate_mime`（`:151-161`）/ `_validate_ext`（`:164-165`）的白名单**无任何音频条目**。
> 现状（客户端）：`ImMediaUploader.uploadFile(File, purpose:, onProgress:)`（`im_media_uploader.dart:60`）是完整的 presign→PUT→public-URL helper，3 次重试（`:52`），MIME 由 `mime_pkg` 推断（`:93-96`）。`ImMediaPurpose` enum（`:31-43`）是后端白名单的镜像，注释明写「新增 purpose 时两边一起改」（`:30`）。

**后端改动（待新增）**——在 `im_media.py` 三处白名单各加一行：
- `SIZE_LIMITS["audio"] = 30 * 1024 * 1024`（语音/短录音 30MB 兜底）。
- `ALLOWED_MIME_PATTERNS["audio"] = [r"audio/"]`（一刀切 `audio/*`，与 image/video 同口径；滥用风险见 §7）。
- `ALLOWED_EXT["audio"] = {"m4a", "mp3", "wav", "aac", "ogg", "opus", "webm"}`。

**客户端改动（待新增）**——`ImMediaPurpose` 加 `audio` 成员（enum + `name` switch，`:31-43`），与后端同步。

**DSL 便捷 action（待新增）**：`@upload_audio({ path, bind })` —— 内部 `ImMediaUploader.uploadFile(File(path), purpose: ImMediaPurpose.audio)`，把返回的 public URL 写入 `bind`。比 base64 直传省后端内存、与 IM 媒体链路一致。

> 不宜复用的旁路：`@upload_avatar`（`interpreter.dart:2509`）→ `AuthService.uploadAvatar(base64)`（`auth_service.dart:529-554`）是 base64-in-body、强绑头像语义，不适合录音。`@file_to_base64`（`interpreter.dart:2432-2447`）可作为「若改走 base64 上传」的备选读文件手段，但本期默认走直传。

### 5.5 音频播放器 widget（`type:"audio"`）

> 现状：`widget_builder.dart` 91 个注册类型无 audio widget。视频走 `JsonVideoWidget`（`widget_builder.dart:86`），是 chewie 封装的 StatefulWidget——可作为封装范本。

**新增 `JsonAudioWidget`（待新增）**：`type:"audio"`，StatefulWidget，内部持有共享引擎的一个 handle，渲染「播放/暂停按钮 + 进度条 + 已播/总时长」。args：`{ src, autoplay?, loop?, show_controls? }`。注册进 `JsonWidgetBuilder._builders`（`widget_builder.dart`）。这是「可复用音频 UI」的视觉核心。

### 5.6 进度 / 事件 → DSL 的桥接

> 现状：共享引擎需要新增 position/duration/onComplete 上报（§5.1 缺口 3）。游戏侧 `on_game_over` 这类「事件触发 logic」的范式（`JSON-DSL.md` 游戏章节）可作为事件桥接的参照。

两种消费方式并存：
- **变量驱动 UI**：`@audio_status({handle, bind})` 主动拉取写入 `global.*`，触发 rebuild（适合进度条）。
- **回调驱动 action**：`@audio_play` 接可选 `on_complete`（一段 logic，播放结束时执行），对齐 `flame_game` 的事件回调风格。具体事件→变量/action 的桥接契约在实现期定稿（见 §10）。

## 6. 数据模型 / 接口汇总

| 对象 | 位置 | 状态 |
|------|------|------|
| 共享音频引擎（播放器池 + source 解析 + seek/position） | `lib/json_ui/audio/audio_engine.dart` | **待新增**（下沉自 `game_audio.dart`） |
| `@audio_play / _pause / _stop / _seek / _status` | `lib/json_ui/interpreter.dart` | **待新增** |
| `@record_start / @record_stop` | `lib/json_ui/interpreter.dart` | **待新增**（仿 `@pick_image` :3618） |
| `@upload_audio` | `lib/json_ui/interpreter.dart` | **待新增**（复用 `ImMediaUploader`） |
| `JsonAudioWidget`（`type:"audio"`） | `lib/json_ui/widgets/audio_widget.dart` + `widget_builder.dart` 注册 | **待新增** |
| `purpose=audio`（SIZE_LIMITS / MIME / EXT） | `backend/im_media.py:51-96` | **待新增**（三处加一行） |
| `ImMediaPurpose.audio` | `lib/im/im_media_uploader.dart:31-43` | **待新增**（镜像后端） |
| `lib_audio.json`（录音按钮 / 语音气泡 / 音频列表项） | `templates/lib_audio.json` | **待新增** |
| `@request_permission({type:"microphone"})` | `interpreter.dart:1535-1549` / `:3840-3841` | **已实现，复用** |
| 麦克风平台声明（Android/iOS/macOS） | `AndroidManifest.xml:4` / `Info.plist:59-62` / `DebugProfile.entitlements` | **已实现，复用** |
| 依赖包（record / audioplayers / permission_handler / flame） | `pubspec.yaml:71/112/98/105` | **已实现，复用**（无 just_audio，无需新增包） |
| `ImMediaUploader.uploadFile`（presign→PUT→URL） | `lib/im/im_media_uploader.dart:60` | **已实现，复用** |
| 预签名上传网关（`/api/im/media/upload-url`） | `backend/im_media.py` | **已实现，扩展** |

## 7. 安全与防滥用

1. **`audio/*` 一刀切的 MIME 风险**：本期沿用 image/video 的 `audio/*` prefix 白名单（`im_media.py` `_validate_mime`），`im-media` 桶 public-read（`:130-148`）等同对任意音频开了「音床」口子——与现有图床/视频床同质风险。需确认 size 上限（建议 30MB）+ 后续按 prefix 做 lifecycle/配额（key 已按 `<purpose>/<yyyy>/<mm>/…` 分目录，`_build_key :168-174`，便于按 purpose 清理）。
2. **录音前置授权**：`@record_start` 必须先经 `@request_permission({type:"microphone"})`，未授权直接返回失败，不静默录音。
3. **handle 生命周期 / 后台残留**：JSON-APP 页面切换或 interpreter dispose 时，必须统一 stop + dispose 所有播放 handle 与进行中的录音，**防止后台残留播放**。游戏层已有 `GameAudioController.dispose()`（`game_audio.dart:109-120`）可参照，但通用层需绑 interpreter 生命周期（实现时确认 dispose 钩子）。
4. **上传鉴权沿用现状**：`upload_url` 是 `@require_auth`（`im_media.py:177`），录音上传复用同一鉴权与 15min 预签名，不额外开放匿名口子。
5. **录音长期保存**：`im-media` 桶有 lifecycle 清理预期（IM 媒体语义为短期），若音频需长期存档需评估独立桶 / 延长 lifecycle（见 §10）。

## 8. 兼容性与迁移

- **游戏侧零回归**：`@audio.*` 与 `tracks/sounds` catalog 语义不变（`JSON-DSL.md:1777-1798/1990-1993`），仅把底层播放器池下沉为共享层、`GameAudioController` 变薄封装；行为对齐回归测试覆盖。
- **后端叠加式**：`purpose=audio` 是在 `SIZE_LIMITS/ALLOWED_MIME_PATTERNS/ALLOWED_EXT` 各加一条，不动既有 image/snapshot/video/file 校验；旧客户端不传 `audio` purpose 时行为不变。
- **客户端镜像同步**：`ImMediaPurpose.audio` 与后端必须同版本发布（enum 注释已强调「两边一起改」，`im_media_uploader.dart:30`），否则客户端用 audio purpose 会被后端 400。
- **新 widget/builtin 向后兼容**：`type:"audio"` 与 `@audio_*/@record_*/@upload_audio` 都是新增；不识别它们的旧客户端按未知 type / 未知 builtin 既有降级路径处理。

## 9. 分期实施计划

**P1 · 播放打通（最小可用）**
1. 下沉共享引擎 `lib/json_ui/audio/audio_engine.dart`，**新增本地文件 source 分支** + seek + position/duration 上报；`GameAudioController` 改薄封装。
2. interpreter 全局 builtin：`@audio_play / @audio_pause / @audio_stop / @audio_seek / @audio_status`（含 handle 分配 + bind）。
3. `JsonAudioWidget`（`type:"audio"`）+ 注册进 `widget_builder._builders`；绑 interpreter dispose 统一回收 handle。

**P2 · 录音 + 上传**
4. 录音 builtin `@record_start / @record_stop`（落盘 m4a/aac，仿 `@pick_image` 返 path + 写 bind），前置麦克风授权。
5. 后端 `im_media.py` 加 `purpose=audio`（三处白名单）；客户端 `ImMediaPurpose.audio` 镜像。
6. DSL action `@upload_audio`（复用 `ImMediaUploader`）→ 公开 URL。

**P3 · 可复用 UI + 事件 + 加固**
7. 发布 `templates/lib_audio.json`（录音按钮组件、语音消息气泡、音频列表项），封装 builtin + widget 为命名函数（对齐 `lib_im`/`lib_user` 模式）。
8. 事件桥接定稿：`on_complete` 回调 + 进度变量驱动；并发/handle 生命周期、桶 lifecycle/配额加固。
9. （视评估结果）Web 端录音/播放支持与编码适配（见 §10）。

## 10. 开放问题

1. **Web 平台**：`record` 在 Web 需 MediaRecorder + opus/webm，`audioplayers` Web 后端能力受限；macOS entitlement 已含 audio-input，但 Web 无验证证据。是否纳入 MVP，还是先 iOS/Android/macOS、Web 留 P3？
2. **录音编码与 ASR 复用**：存档录音（m4a/aac）与 ASR 流式录音（pcm16，`bytedance_asr_service.dart:133-139`）是两套配置。`@record_*` 是否要顺带支持「边录边转写」接现有 socket.io ASR，还是纯落盘上传？
3. **播放并发模型**：单全局播放器（同时只播一条，简单）还是多 handle（背景音 + 音效叠加，复杂）？游戏层已是多实例池，普通 JSON-APP 层是否需要同等复杂度？
4. **进度/事件桥接**：DSL 怎么消费 position/duration/onComplete——写 `global.audio_position` 触发 rebuild，还是触发 `on_complete` action（类似 `on_game_over`）？需定义事件→变量/action 的桥接契约。
5. **`audio` purpose 安全口径**：MIME 是否一刀切 `audio/*`？public-read 桶放任意音频的滥用边界（与图床/视频床同口子）需确认。
6. **handle 生命周期归属**：页面切换/dispose 时谁统一 stop+dispose？game 层有 `dispose()`（`game_audio.dart:109-120`）可参照，全局层需明确绑 interpreter 生命周期钩子。
7. **音频长期存档**：`im-media` 桶为 IM 短期媒体语义并有 lifecycle 清理；长期保存的录音是否需独立桶/延长 lifecycle/配额？

---

**实现完成后**：把 `@audio_play / @audio_pause / @audio_stop / @audio_seek / @audio_status`、`@record_start / @record_stop`、`@upload_audio`、`type:"audio"` widget 回流到 `JSON-DSL.md`（当前 audio 仅在游戏章节有文档）；把 `purpose=audio` 的白名单与 size 上限回流到 `backend/im_media.py` 的注释契约与 `ImMediaPurpose` enum 的「两边一起改」约定；并在 `templates/lib_audio.json` 落地可复用音频 UI 组件。
