# Agent Runtime Visual Review Design

This document defines the production direction for visual review in JSON-APP
generation. The key boundary is simple: visual review belongs inside the Agent's
normal design loop. The backend must not run a separate vision model after the
Agent finishes, and the screenshot tool must not call any provider API by
itself.

## Goal

When the selected Agent/model supports image understanding, the Agent should be
able to render its draft JSON app in the real Flutter Web interpreter, inspect
mobile screenshots, revise the JSON, and repeat that loop before final upload.

This should catch issues that static validation cannot see:

- blank screens, error pages, loading stalls, clipped controls, and missing
  scroll behavior;
- weak native UI quality such as sparse first screens, duplicated headers,
  web-form layouts, red question-mark icons, and placeholder assets;
- game screens with emoji or tiny placeholder sprites instead of usable assets;
- interaction regressions after tapping bottom tabs, primary content, or top
  actions.

## Non-Goals

- Do not replace `backend/validate_json_app.py`; schema/runtime validation
  remains the hard gate.
- Do not make the backend rewrite, filter, or hide Agent output based on visual
  findings.
- Do not require client participation.
- Do not rely on Flutter Web DOM selectors; the app is treated as pixels.
- Do not expose production or private provider keys to the Agent container.
- Do not add a service-side vision proxy for this feature. Claude, Codex, or
  OpenCode should use their own image-reading ability when the selected model
  supports it.

## Current Reusable Pieces

- The hosted Flutter Web client now supports:

  ```text
  https://myapp-web.dapangyu.work/?remote_file=http://127.0.0.1:<port>/app.json
  ```

  The remote URL is still restricted to loopback hosts, so the JSON file is
  served locally inside the Agent runtime and is not uploaded just for review.

- `scripts/myapp_visual_review.py` is the runtime screenshot tool.
- `docs/deepseek-generation-optimization-playbook.md` defines the viewport
  targets:
  - primary: `402x874`
  - lower bound: `360x780`
- `agent-node` already isolates Agent execution and temporary provider keys.

## Runtime Flow

For runs where visual review is disabled, the generation flow stays unchanged.

For runs where visual review is enabled:

1. Backend starts the Agent run and includes a concise prompt note telling the
   Agent that `myapp-visual-review` is available.
2. Agent writes or modifies `$AI_APP_WORKSPACE/app.json`.
3. Agent runs the normal static checks:

   ```bash
   python3 backend/repair_json_app.py "$AI_APP_WORKSPACE/app.json"
   python3 backend/validate_json_app.py "$AI_APP_WORKSPACE/app.json"
   ```

4. Agent runs:

   ```bash
   myapp-visual-review "$AI_APP_WORKSPACE/app.json" --capture-small
   ```

5. The tool serves the JSON app on `127.0.0.1`, opens the hosted Flutter Web
   interpreter with `remote_file=...`, drives headless Chrome through CDP,
   captures screenshots, performs a small deterministic tap pass, and writes:

   ```text
   $AI_APP_WORKSPACE/visual_review/report.md
   $AI_APP_WORKSPACE/visual_review/report.json
   $AI_APP_WORKSPACE/visual_review/screenshots/
   ```

6. If the Agent/model can read images, the Agent opens the PNG files referenced
   by `report.md`, makes JSON changes, reruns repair/validation, and may rerun
   the visual review tool.
7. Final upload remains the existing path:

   ```bash
   bash backend/upload_with_signature.sh "$AI_APP_WORKSPACE/app.json"
   ```

## Tool Contract

Command:

```bash
myapp-visual-review [options] <app.json>
```

Options:

```text
--out-dir <dir>               default: $AI_APP_WORKSPACE/visual_review
--web-base <url>              default: https://myapp-web.dapangyu.work
--remote-param <name>         default: remote_file
--viewport 402x874            primary capture size
--small-viewport 360x780      optional lower-bound capture size
--capture-small               enable the lower-bound capture with default size
--max-clicks 4                deterministic coordinate taps on primary viewport
--timeout 120                 render wait timeout in seconds
--stabilize-seconds 5         wait before screenshots
--json                        print compact report JSON to stdout
```

Exit codes:

- `0`: report was written and no render/capture hard failure was detected.
- `2`: render failed or screenshot capture failed.

Exit codes are advisory for the Agent. The backend should not convert visual
review failure into client protocol events by itself.

## Report Contract

`report.json` is strict JSON:

```json
{
  "schema": "myapp.visual_review.v1",
  "app_path": "/workspace/app.json",
  "renderer": "hosted-loopback-url",
  "web_url": "https://myapp-web.dapangyu.work/?remote_file=...",
  "agent_visual_review": {
    "tool_calls_vision_api": false,
    "agent_should_inspect_images_if_supported": true
  },
  "screenshots": [
    {
      "id": "primary-initial",
      "path": "screenshots/primary-initial.png",
      "viewport": {"width": 402, "height": 874, "label": "primary"},
      "action": null,
      "changed_from_previous": true
    }
  ],
  "summary": {
    "pass": true,
    "score": 70,
    "hard_fail": false
  },
  "issues": [],
  "recommended_next_steps": [
    "If the current Agent/model supports image input, inspect the screenshot PNG files listed in report.md and revise app.json before upload."
  ]
}
```

`report.md` is optimized for Agent reading and includes Markdown image links:

- command result and renderer details;
- screenshots with relative file paths;
- deterministic tap metadata and whether each tap changed pixels;
- render/capture issues;
- a clear reminder that image inspection is the Agent's responsibility.

## Screenshot and Interaction Model

Flutter Web should be treated as a visual surface. The screenshot tool uses
Chrome DevTools Protocol:

- `Emulation.setDeviceMetricsOverride`
- `Page.navigate`
- `Page.captureScreenshot`
- `Input.dispatchMouseEvent`

Initial interaction is deterministic and conservative:

- bottom navigation center;
- bottom navigation left;
- bottom navigation right;
- top-right action;
- primary visible content region.

The tool records before/after hashes. It does not decide whether the resulting
UI is beautiful; it only provides visual artifacts and hard render findings for
the Agent to inspect.

## Runtime Packaging

`deploy/production/Dockerfile.agent-runtime` should include:

- Google Chrome or Chromium with headless support;
- CJK and emoji fallback fonts;
- `scripts/myapp_visual_review.py` installed as `myapp-visual-review`;
- the same backend scripts already used by the Agent for repair, validation,
  and upload.

The preferred renderer is the hosted Cloudflare Web build with a loopback JSON
server:

```text
AI_APP_VISUAL_REVIEW_WEB_BASE=https://myapp-web.dapangyu.work
AI_APP_VISUAL_REVIEW_REMOTE_PARAM=remote_file
AI_APP_VISUAL_REVIEW_PRIMARY_VIEWPORT=402x874
AI_APP_VISUAL_REVIEW_SMALL_VIEWPORT=360x780
AI_APP_VISUAL_REVIEW_MAX_CLICKS=4
```

This avoids maintaining a second compiled Flutter Web artifact inside the
Agent image. If the hosted Web runtime changes, the Agent review naturally uses
the same runtime users see.

## Capability and Prompt Injection

Visual review is enabled by configuration, not by a backend vision call.

Recommended environment flag:

```text
AI_APP_VISUAL_REVIEW_ENABLED=1
```

When enabled, backend prompt injection should add a concise note:

```text
本轮运行时提供视觉复检工具：
myapp-visual-review "$AI_APP_WORKSPACE/app.json" --capture-small

如果当前 Agent/模型支持读取图片，复杂 APP 或视觉质量敏感 APP 在最终上传前至少运行一次，
并打开 visual_review/report.md 中引用的 PNG 截图，根据真实画面修复 JSON。
如果当前模型不能读取图片，只把该报告当作渲染/截图证据，不要声称完成视觉评估。
视觉复检不是上传动作；最终仍必须执行 upload_with_signature.sh。
```

This keeps non-visual models safe: they may skip the tool or use it only as
render evidence, while visual-capable models can complete a genuine screenshot
review without any extra backend API.

## Failure Handling

- If visual review is unavailable, generation continues unchanged.
- If Chrome is missing or fails to start, the tool exits with a clear error.
- If rendering fails, `report.md` and `report.json` still record the error when
  possible.
- The backend hard gate remains repair, validation, and upload resolution.
- The client protocol does not change.

## Concurrency and Performance

Visual review is heavier than static validation. The first implementation uses
one local Chrome instance per Agent run. If node pressure becomes high, add an
agent-node-local semaphore so only a small number of visual reviews can run on
one physical host.

Recommended defaults:

```text
AI_APP_VISUAL_REVIEW_ENABLED=1
AI_APP_VISUAL_REVIEW_MAX_CLICKS=4
AI_APP_VISUAL_REVIEW_PRIMARY_VIEWPORT=402x874
AI_APP_VISUAL_REVIEW_SMALL_VIEWPORT=360x780
```

## Acceptance Criteria

- Non-visual provider runs remain compatible.
- Agent runtime exposes `myapp-visual-review`.
- The tool renders through the real hosted Flutter Web JSON interpreter.
- Screenshots are captured at `402x874`, and optional lower-bound screenshots
  at `360x780`.
- Report files include relative screenshot paths and Markdown image links.
- Visual-capable Agents can inspect the images and revise `app.json`.
- Final JSON still passes `backend/validate_json_app.py`.
- Real provider secrets do not appear in Agent workspace, payload files, logs,
  or final messages.
- No service-side vision API, vision token proxy, or backend output mutation is
  introduced for this feature.
