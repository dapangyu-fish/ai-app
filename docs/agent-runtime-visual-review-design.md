# Agent Runtime Visual Review Design

This document defines the first production design for adding visual review to
JSON-APP generation. The important boundary is that visual review is part of the
Agent's normal design loop, not a late server-side upload gate.

## Goal

Some AI models can understand screenshots. When the selected provider and Agent
support image input, JSON-APP generation should be able to render the draft app
inside the real Flutter Web interpreter, capture mobile screenshots, inspect the
UI visually, and improve the JSON before final upload.

The goal is to improve initial app quality:

- catch blank screens, red error pages, loading stalls, clipped controls, and
  non-scrollable long content;
- catch weak native UI quality such as sparse first screens, web-form layouts,
  duplicated headers, red question-mark icons, and obvious placeholder assets;
- let the Agent use screenshots during design, not only after validation fails;
- keep non-visual providers working exactly as they do today.

## Non-Goals

- Do not make visual review a replacement for `backend/validate_json_app.py`.
- Do not make the backend rewrite or hide Agent output based on screenshots.
- Do not require the client to participate in visual review.
- Do not depend on Flutter Web DOM selectors for interaction.
- Do not require every provider to support vision.
- Do not expose production or private provider keys to the Agent container.

## Current Reusable Pieces

- `docs/local-json-web-debug.md` describes the existing `?local_json=` path.
  This path loads JSON into the real Flutter Web `JsonInterpreter` and
  `JsonScreenView`.
- `scripts/ai_generation_quality_lab.py` already has a local Chrome DevTools
  Protocol screenshot prototype.
- `docs/deepseek-generation-optimization-playbook.md` already defines the
  mobile viewport targets:
  - primary: `402x874`
  - lower bound: `360x780`
- `backend/providers/` already centralizes provider and Agent adapter metadata.
- `agent-node` already issues temporary proxy tokens so the Agent runtime does
  not receive real provider secrets.

## High-Level Flow

For a provider/Agent pair without vision support, the flow stays unchanged.

For a provider/Agent pair with vision support:

1. Backend starts the Agent run and includes visual-review capability metadata.
2. Agent writes a first draft JSON to `$AI_APP_WORKSPACE/app.json`.
3. Agent runs static checks:

   ```bash
   python3 backend/repair_json_app.py "$AI_APP_WORKSPACE/app.json"
   python3 backend/validate_json_app.py "$AI_APP_WORKSPACE/app.json"
   ```

4. Agent runs:

   ```bash
   myapp-visual-review "$AI_APP_WORKSPACE/app.json"
   ```

5. `myapp-visual-review` renders the app through the bundled Flutter Web
   runtime, captures screenshots, optionally explores the UI with coordinate
   taps, calls the configured visual model, and writes a report under:

   ```text
   $AI_APP_WORKSPACE/visual_review/report.md
   $AI_APP_WORKSPACE/visual_review/report.json
   $AI_APP_WORKSPACE/visual_review/screenshots/
   ```

6. Agent reads the report and updates `app.json`.
7. Agent may repeat visual review up to the configured max attempts.
8. Agent performs the normal final upload path:

   ```bash
   bash backend/upload_with_signature.sh "$AI_APP_WORKSPACE/app.json"
   ```

The backend still performs its existing server-side repair/validate/upload
resolution for `server_upload_app_json`. Visual review does not replace that
hard gate.

## Runtime Tool Contract

The generated runtime command is:

```bash
myapp-visual-review [options] <app.json>
```

Initial options:

```text
--out-dir <dir>               default: $AI_APP_WORKSPACE/visual_review
--viewport 402x874            repeatable
--small-viewport 360x780      optional lower-bound capture
--max-clicks 4                max coordinate taps per review
--max-depth 2                 max click/explore depth
--timeout 90                  total render/explore timeout in seconds
--no-vision                   capture screenshots only, no model call
--json                        print compact machine-readable summary
```

Exit code contract:

- `0`: screenshots captured and report written.
- `2`: app render failed or screenshots could not be captured.
- `3`: vision call failed after retries.

Exit codes are advisory for the Agent. The Agent prompt should say that render
failure must be fixed before final upload, but the backend will not directly
convert these exit codes into client protocol events in v1.

## Report Contract

`report.json` should be strict JSON:

```json
{
  "schema": "myapp.visual_review.v1",
  "app_path": "/workspace/app.json",
  "viewports": [
    {"width": 402, "height": 874, "label": "primary"}
  ],
  "screenshots": [
    {
      "id": "primary-initial",
      "path": "screenshots/primary-initial.png",
      "action": null,
      "changed_from_previous": true
    }
  ],
  "summary": {
    "pass": false,
    "score": 68,
    "hard_fail": false,
    "native_feel": 3,
    "functional_confidence": 4,
    "layout_fit": 3
  },
  "issues": [
    {
      "severity": "major",
      "screen": "primary-initial",
      "category": "native_ui",
      "message": "First screen is sparse and looks like a web form.",
      "suggestion": "Move summary cards and recent items above the empty state."
    }
  ],
  "recommended_next_steps": [
    "Revise the first screen and rerun myapp-visual-review."
  ]
}
```

`report.md` should be optimized for the Agent to read:

- short verdict;
- screenshot list;
- concrete visible problems;
- concrete JSON-level repair suggestions;
- whether another review is recommended.

## Screenshot and Interaction Model

Flutter Web should be treated as a visual surface. The runtime must not rely on
stable DOM selectors because Flutter Web can render through glass-pane,
CanvasKit, semantics nodes, and hidden input layers.

The visual-review tool should use Chrome DevTools Protocol:

- `Emulation.setDeviceMetricsOverride`
- `Page.captureScreenshot`
- `Input.dispatchMouseEvent`
- optionally `Runtime.evaluate` for coarse readiness and console text

Interaction is full-screen coordinate based:

1. Capture initial screenshot.
2. Ask the visual model for safe tap coordinates.
3. Validate every coordinate is inside the viewport.
4. Skip actions marked dangerous.
5. Tap one coordinate.
6. Wait for Flutter to settle.
7. Capture another screenshot.
8. Stop exploring a path if the screenshot is unchanged.

Supported action schema in v1:

```json
{
  "actions": [
    {
      "type": "tap",
      "x": 201,
      "y": 812,
      "reason": "Open the second bottom tab",
      "dangerous": false
    }
  ]
}
```

Unsupported in v1:

- text input;
- long press;
- drag;
- pinch;
- file picker;
- camera/microphone permission flows.

These can be added later once the basic loop is stable.

## Flutter Web Renderer Strategy

Do not run `flutter build web` inside every Agent run.

There are three viable renderer modes.

### Mode A: Hosted Web Renderer With Loopback JSON URL

This should be the default production direction when the hosted Web client is
deployed together with the backend/runtime version.

The visual tool opens the already hosted Web client, for example:

```text
https://myapp-web.dapangyu.work
```

The Agent runtime starts a local HTTP server that exposes only the current JSON
draft:

```text
http://127.0.0.1:6666/app.json
```

Then Chrome opens the hosted Web app with a JSON URL parameter:

```text
https://myapp-web.dapangyu.work/?remote_file=http%3A%2F%2F127.0.0.1%3A6666%2Fapp.json
```

This still does not upload the JSON to the backend. The browser running inside
the Agent runtime fetches `http://127.0.0.1:6666/app.json` from its own loopback
interface. The hosted Web page only receives the JSON bytes in that browser
process and loads them into the same `JsonInterpreter`.

Benefits:

- no duplicated Flutter Web build inside `agent-runtime`;
- no second renderer artifact to keep in sync manually;
- tests the same hosted Web client real users open;
- smaller runtime image than bundling a full Web build;
- easier to automate than driving the browser file picker.

Requirements:

- the hosted Web app must add a dedicated `remote_file` or `remote_json`
  startup parameter;
- this hosted parameter must not reuse the existing `local_json` absolute-path
  behavior;
- the hosted parameter should only accept `http://127.0.0.1`, `http://localhost`,
  loopback IPv6, or explicitly allowed HTTPS URLs;
- the local JSON HTTP server must return CORS headers and handle browser private
  network preflight;
- the visual tool should record the hosted Web build commit/version if the page
  exposes one.

The existing `?local_json=` query path is not the same mechanism. That path is
intentionally localhost-host-only and should stay that way. Hosted mode should
use a new URL-fetching parameter, not a public `local_json=/absolute/path`
parameter.

The local JSON server should emit at least:

```text
Access-Control-Allow-Origin: https://myapp-web.dapangyu.work
Access-Control-Allow-Methods: GET, OPTIONS
Access-Control-Allow-Headers: Content-Type
Access-Control-Allow-Private-Network: true
Content-Type: application/json; charset=utf-8
Cache-Control: no-store
```

Chrome may preflight public-to-loopback requests under Private Network Access.
If that happens, the server must answer `OPTIONS` successfully with the same
CORS/PNA headers.

For manual testing, the shape is:

```bash
python3 scripts/local_json_server.py --port 6666 --file "$AI_APP_WORKSPACE/app.json"

open 'https://myapp-web.dapangyu.work/?remote_file=http%3A%2F%2F127.0.0.1%3A6666%2Fapp.json'
```

`scripts/local_json_server.py --file <path>` serves one file directly as
`/app.json` and includes the CORS/PNA headers above.

### Mode B: Hosted Web Renderer With Browser File Picker

This remains a fallback if browsers block loopback fetches in a target
environment. The tool can use Chrome DevTools Protocol to drive the existing
local file selection flow and select:

```text
/workspace/app.json
```

This also does not upload the JSON to the backend; it uses the browser File API.
It is slightly harder to automate than the loopback URL mode, so it should not
be the first choice.

### Mode C: Bundled Web Renderer

Bundled mode remains useful for self-hosted/offline deployments or strict
same-commit testing where the hosted Web client may not be available.

In that mode, the Agent runtime image contains a prebuilt Flutter Web JSON
interpreter:

```text
/opt/myapp/json-runtime-web/
```

This is not a separate renderer and must not be a hand-written web
implementation of the JSON DSL. It is the same Flutter application entry point
compiled for Web from this repository, using the same `JsonInterpreter`,
`JsonScreenView`, runtime widgets, asset manager, bridges, and crash routing as
the normal Web client.

The artifact should be a dedicated Docker build artifact, not a committed file
tree in Git. It should also not blindly copy the Cloudflare Pages deployment
output because `scripts/build_cloudflare_pages.sh` adds Cloudflare-specific
headers, redirects, and compressed WASM handling. The runtime image should build
or copy a plain Flutter Web release output that a simple localhost static server
can serve correctly.

Expected placement:

```text
agent-runtime image
  /opt/myapp/json-runtime-web/index.html
  /opt/myapp/json-runtime-web/main.dart.js
  /opt/myapp/json-runtime-web/assets/...
  /opt/myapp/json-runtime-web/*.wasm
```

The visual tool serves this directory on `127.0.0.1` and opens:

```text
http://127.0.0.1:<web-port>/?local_json=/workspace/app.json&local_json_server=http://127.0.0.1:<json-port>/json
```

The current Flutter entry point checks `_LocalJsonDebugLoader.maybeBuild()`
before `_AuthGate`, so this path bypasses login and loads the JSON app directly.
The local JSON loader is host-limited to `localhost`, `127.0.0.1`, and loopback
IPv6 hosts, which is suitable for an in-container headless Chrome review path.

Build-time approach:

1. Multi-stage Docker build installs Flutter only in a builder stage.
2. Builder runs a web build that includes the existing `?local_json=` debug
   path.
3. Final runtime image copies only the built web files plus Chrome and scripts.

Required runtime packages:

- Google Chrome or Chromium with headless support;
- CJK fonts;
- emoji/fallback fonts;
- Python dependencies used by the visual script.

The existing `?local_json=` path only works for localhost, which is desirable:
the visual tool runs a local static server inside the Agent runtime and does not
expose arbitrary local JSON loading publicly.

### Recommended v1 Default

Use hosted mode first:

```text
AI_APP_VISUAL_REVIEW_RENDERER=hosted-loopback-url
AI_APP_VISUAL_REVIEW_WEB_BASE=https://myapp-web.dapangyu.work
AI_APP_VISUAL_REVIEW_REMOTE_PARAM=remote_file
```

Keep file-picker and bundled modes as fallbacks:

```text
AI_APP_VISUAL_REVIEW_RENDERER=hosted-file-picker
AI_APP_VISUAL_REVIEW_RENDERER=bundled-local-json
```

If hosted mode is used, version drift must be visible. The report should include:

```json
{
  "renderer": "hosted-loopback-url",
  "web_base": "https://myapp-web.dapangyu.work",
  "web_commit": "unknown-or-detected",
  "agent_runtime_commit": "..."
}
```

If the hosted Web commit is known and differs from the Agent/runtime commit, the
tool should warn in `report.md`. It should not silently pretend the two runtimes
are identical.

## Provider Capability Model

Add a new optional adapter family:

```text
backend/providers/<provider>/vision/adapter.py
```

Example non-secret adapter shape:

```python
ADAPTER = {
    "model": "example-vision-model",
    "wire_api": "anthropic",
    "base_url": "https://example.com/anthropic",
    "env_key": "EXAMPLE_VISION_AUTH_TOKEN",
    "max_images": 8,
    "max_attempts": 2,
}
```

Environment overrides should follow the existing provider-prefix style:

```text
<PREFIX>_VISION_ENABLED=1
<PREFIX>_VISION_BASE_URL=
<PREFIX>_VISION_MODEL=
<PREFIX>_VISION_ENV_KEY=<PREFIX>_VISION_AUTH_TOKEN
<PREFIX>_VISION_AUTH_TOKEN=
<PREFIX>_VISION_WIRE_API=anthropic
<PREFIX>_VISION_MAX_IMAGES=8
<PREFIX>_VISION_MAX_ATTEMPTS=2
```

`provider_capabilities_from_env()` should be extended to report vision
availability for the selected provider. For scheduling, vision is not a
separate Agent type; it is a capability attached to a provider/Agent run.

## Secret and Proxy Boundary

Real provider tokens must remain outside the Agent container.

Expected path:

```text
myapp-visual-review
  -> temporary vision token in Agent env
  -> agent-node provider proxy
  -> real vision provider
```

The temporary token should be scoped to:

- run id;
- provider id;
- agent id;
- vision adapter;
- short TTL.

The proxy should redact tokens in logs and revoke them when the run ends, using
the same principle as the current Claude/Codex/OpenCode provider proxy.

## Backend Prompt Injection

When visual review is available, backend should append a concise capability
block to the normal per-turn prompt wrapper:

```text
本轮运行时支持视觉复检。你可以在生成或修改 JSON-APP 后运行：
myapp-visual-review "$AI_APP_WORKSPACE/app.json"

要求：
- 复杂或视觉质量敏感的 APP，最终上传前至少运行一次视觉复检。
- 如果报告发现空白、崩溃、裁切、不可滚动、红问号图标、明显 Web 表单感、游戏资产占位等问题，
  先修复 JSON，再重新校验，必要时再次运行视觉复检。
- 视觉复检报告是设计输入，不是最终上传动作；最终仍必须执行 upload_with_signature.sh。
```

The system prompt should also mention the tool in the indexed generation docs,
but only as an optional capability. Non-visual models must not be asked to run a
missing command.

## Failure Handling

The v1 behavior should be conservative:

- If visual review is unavailable, generation continues unchanged.
- If Chrome fails to start, Agent sees the tool error and should continue with
  static validation rather than blocking forever.
- If the vision API fails, tool writes a screenshot-only report and exits with
  code `3`.
- The backend should not mark the whole session failed solely because visual
  review failed in v1.
- The backend hard gate remains `repair_json_app.py` plus
  `validate_json_app.py` plus upload resolution.

This keeps the first rollout safe while still giving visual-capable models a
better design loop.

## Concurrency and Performance

Visual review is heavier than normal validation.

Recommended defaults:

```text
AI_APP_VISUAL_REVIEW_ENABLED=1
AI_APP_VISUAL_REVIEW_MAX_ATTEMPTS=2
AI_APP_VISUAL_REVIEW_MAX_CLICKS=4
AI_APP_VISUAL_REVIEW_PRIMARY_VIEWPORT=402x874
AI_APP_VISUAL_REVIEW_SMALL_VIEWPORT=360x780
AGENT_NODE_VISUAL_MAX_CONCURRENCY=1
```

The first implementation can use a per-agent-run local Chrome instance. If CPU
or memory pressure becomes high, add an agent-node-local semaphore so only one
visual review runs at a time per physical node.

## Implementation Plan

### Phase 1: Runtime screenshot tool without vision

- Extract the CDP screenshot logic from `scripts/ai_generation_quality_lab.py`
  into a reusable script, `scripts/myapp_visual_review.py`.
- Package it into the Agent runtime as `myapp-visual-review`.
- Add Chrome and fonts to `Dockerfile.agent-runtime`.
- Add prebuilt Flutter Web runtime under `/opt/myapp/json-runtime-web`.
- Capture `402x874` screenshot and write `report.json` / `report.md`.
- Test with a known JSON template and a generated JSON app.

### Phase 2: Provider vision metadata and proxy

- Add `vision` adapter support under `backend/providers/`.
- Extend provider discovery/config to expose vision capability.
- Extend agent-node payload creation to include vision proxy config only when
  configured.
- Extend agent-node temporary proxy issuing for vision tokens.
- Keep real keys out of Agent runtime env.

### Phase 3: Vision model report

- Add image-to-report call inside `myapp-visual-review`.
- Support at least one wire protocol first, likely the easiest currently
  configured provider API.
- Require strict JSON output and save raw provider response for debugging with
  token redaction.
- Fall back to screenshot-only report if the vision call fails.

### Phase 4: Coordinate interaction

- Add full-screen coordinate tap support through CDP.
- Ask the visual model for safe next tap actions.
- Limit to a small number of taps and skip dangerous actions.
- Store per-action screenshots and changed/unchanged metadata.

### Phase 5: Prompt integration

- Add a visual-review capability block to backend prompt injection only when
  the selected run supports it.
- Add a short indexed prompt doc describing when and how to run the tool.
- Tell Agent that visual review is part of design iteration, not final upload.

### Phase 6: End-to-end validation

Run at least these cases:

1. Native utility app with long scroll content.
2. Dashboard/control app with sliders and switches.
3. Game with non-emoji player and collectible assets.

For each case:

- run non-visual provider path to confirm no regression;
- run visual-capable path and confirm the tool is used;
- inspect screenshots and report files;
- confirm final upload still uses existing structured client action path.

## Acceptance Criteria

- Non-visual providers produce the same backend behavior as before.
- Visual-capable runs expose `myapp-visual-review` inside the Agent runtime.
- The tool renders the real Flutter Web JSON interpreter, not a separate
  renderer.
- Screenshots are captured at `402x874`.
- The Agent can read `visual_review/report.md` and revise `app.json`.
- The final JSON still passes `backend/validate_json_app.py`.
- Real provider secrets do not appear in Agent workspace, payload files, logs,
  or final messages.
- The client protocol does not need to change.

## Open Decisions

- Which provider/model should be the first production vision adapter?
- Should visual review be strongly required for visual-capable models, or only
  recommended by prompt in v1?
- Should lower-bound `360x780` screenshots be default or only enabled for apps
  with long content / many controls?
- Should visual review reports be uploaded as internal artifacts for debugging,
  or kept only in the run workspace/logs?
