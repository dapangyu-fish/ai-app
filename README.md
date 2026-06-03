# MyApp

> **AI describe → server-driven mobile app → instantly running on user's phone.**
>
> A Flutter runtime that interprets JSON-DSL into native UI + business logic. Users tell AI what they want, AI emits JSON, and the app renders it inside a precompiled capability set.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android%20%7C%20Web%20%7C%20macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)]()

---

## What is this?

Three things in one repo:

1. **A Flutter Server-Driven UI engine** (`lib/`) — renders any JSON-DSL config into a real cross-platform app at runtime
2. **A Python backend stack** (`backend/`, `user_center/`, `config_center/`) — auth (Supabase), IM (OpenIM), push (APNs + FCM), AI chat proxy, package registry, user admin
3. **A package ecosystem** (`templates/`) — example JSON-APPs (IM, games, user profile, calculator…) you can install on top of the runtime

The name **MyApp** is intentional: each user can create, install, and operate "my app" on top of the shared runtime.

The flagship use case: **a user opens the app → chats with AI → AI returns a JSON-DSL → the app loads and runs it instantly inside the capabilities already compiled into the client**.

---

## Why is this interesting?

- **Server-driven** — ship UI and behavior data through a fixed, precompiled runtime boundary. See [App Store compliance notes](docs/APP_STORE_COMPLIANCE.md).
- **AI-native** — the DSL is designed to be LLM-friendly. The included AI chat (Claude / DeepSeek / MiniMax) generates apps that actually render.
- **Batteries included** — IM with push, AI proxy, package registry, namespaces, mirroring, user center, environment switching — all wired together. Not "yet another low-code framework that punts on auth".
- **Self-hostable** — `myapp-ctl deploy` manages the backend stack, agent runtime, registry, config center, and service secrets from one host-level CLI.
- **Cross-platform** — same JSON-DSL renders on iOS, Android, Web, macOS, Linux, Windows.

---

## Quickstart

### Just run the client against the hosted stack (60 seconds)

If you only want to *use* the app and play with AI-generated mini-apps:

1. Install MyApp from [App Store](#) / [Google Play](#) *(coming soon)*
2. Sign up with email
3. Tap the floating ball → speak / type what you want
4. Wait for AI to generate, then it auto-runs

### Build the client from source (5 minutes)

```bash
git clone https://github.com/<your-org>/myapp.git
cd myapp
flutter pub get
flutter run -d <ios|android|chrome>
```

The default config points at the public hosted backend, so you can sign up and use it immediately.

For Flutter Web IM support, the checked-in `web/openIM.wasm`, `web/sql-wasm.wasm`,
workers, and bridge bundle are runtime assets copied from the pinned
`@openim/wasm-client-sdk` dependency in `web_openim_bridge/package-lock.json`.
On a fresh machine or in CI, regenerate them before `flutter build web` if they
are missing or after changing the SDK version:

```bash
./scripts/build_web_openim.sh
flutter build web
```

For Web builds/runs, you can also use the wrapper script so the OpenIM Web
assets are checked first and regenerated when needed:

```bash
./scripts/flutter_web.sh run -d chrome
./scripts/flutter_web.sh build web
```

### Self-host the full backend stack (20 minutes)

```bash
cd deploy/production
./install_ctl.sh
myapp-ctl setup --host <public-ip-or-domain>
myapp-ctl deploy --pull
```

For a development/test host that builds images from this checkout:

```bash
myapp-ctl setup --host <public-ip-or-domain>
myapp-ctl deploy --build
```

This boots the MyApp backend stack locally / on a VPS:
- JSON app Postgres + AI session Redis + App MinIO
- Agent node + isolated Ubuntu agent runtime
- App backend + AI worker + Registry + Config center + User center

After deploy, the client's built-in **Environment Switcher** (tap brand 7 times on login page) lets you point to your own stack.

See [`deploy/production/README.md`](deploy/production/) for detailed `myapp-ctl` commands.

---

## Architecture

The project is now closer to a small app platform than a single Flutter demo.
The Flutter client is a compiled runtime; JSON-APPs, components, assets, IM,
and AI generation are all served by the backend stack.

```text
                         +-----------------------------+
                         |  Cloudflare Pages (optional) |
                         |  hosted Flutter Web build    |
                         +--------------+--------------+
                                        |
+---------------------------------------v--------------------------------------+
|                         Flutter client runtime (lib/)                       |
| iOS / Android / Web / Desktop                                                |
|                                                                              |
|  JSON-DSL interpreter  | asset/cache manager | environment switcher          |
|  Native widgets        | Flame game atoms    | media picker / preview        |
|  AI designer ball      | IM UI               | OpenIM native + Web WASM SDK  |
+------------------------+---------------------+-------------------------------+
                         | HTTPS / SSE / WSS
                         v
+------------------------------------------------------------------------------+
|                              Backend API (Flask)                              |
| Auth/session checks | AI chat start/status/stream/result | media upload | push |
| Provider config     | Remote config proxy                 | app generation flow |
+------------+--------------------+----------------------+----------------------+
             |                    |                      |
             v                    v                      v
   +------------------+   +-------------------+   +--------------------------+
   | AI session Redis |   | AI worker pool    |   | Supabase                 |
   | queue + SSE log  |   | Claude CLI today  |   | auth + DB + storage      |
   | resumable tasks  |   | Codex/etc future  |   +--------------------------+
   +------------------+   +---------+---------+
                                    |
                                    v
                          +-------------------+
                          | LLM providers     |
                          | DeepSeek / GLM /  |
                          | Claude-compatible |
                          +-------------------+

+--------------------------+     +-------------------------+     +-------------+
| Registry service         | --> | MinIO / OSS             | --> | JSON assets |
| packages, search, mirror |     | json-app/json-component |     | asset packs |
| catalog enrichment       |     | json-app-assets         |     | media files |
+--------------------------+     +-------------------------+     +-------------+

+-------------------+   +------------------+   +------------------------------+
| OpenIM server     |   | Config Center    |   | User Center                  |
| IM + WebSocket    |   | env flags        |   | admin for users/roles        |
+-------------------+   +------------------+   +------------------------------+

Planned:
+------------------------------------------------------------------------------+
| FaaS runtime                                                                   |
| AI-created backend functions for complex JSON-APPs, with isolation, quotas,    |
| resource limits, deploy logs, and self-hosting controls.                       |
+------------------------------------------------------------------------------+
```

| Component | Where | What |
|---|---|---|
| Flutter Runtime | `lib/` | Cross-platform compiled client: JSON-DSL interpreter, widgets, Flame game atoms, asset cache, environment switching, AI entry, IM/media UI |
| Web Runtime Assets | `web/`, `web_openim_bridge/` | OpenIM Web WASM bridge and build assets used by Flutter Web |
| Backend API | `backend/app.py`, `backend/claude_chat.py` | Flask API for auth-gated AI chat, SSE streaming, media upload, push, provider config, and client-facing backend endpoints |
| AI Queue / Sessions | `backend/ai_session.py` + Redis | Durable-ish AI task metadata, bounded worker queue, resumable SSE event stream, abort/retry status |
| AI Worker Pool | `backend/ai_worker_daemon.py`, `backend/agent_node_service.py` | Runs Claude/Codex-style coding agents inside isolated Docker runtime containers through agent-node |
| Registry | `backend/registry_server.py` | Package registry for JSON-APPs/components: semver, namespaces, search, pagination, publish API, mirror, catalog enrichment |
| Object Storage | MinIO / OSS | Public JSON packages, component files, asset packs, app media, and temporary AI-generated JSON URLs |
| OpenIM | `backend/openim/` | IM backend bridge. Native clients use OpenIM Flutter/native SDK; Web uses the WASM SDK bridge |
| Supabase | external service / production config | Auth, database, and storage-compatible services configured through host-local secrets |
| Config Center | `config_center/` | Remote config flags and environment-specific client configuration |
| User Center | `user_center/` | Admin UI for user roles, bans, reset flows, and account operations |
| Templates / Libraries | `templates/` | Published example apps and reusable JSON libraries: IM, launcher, OpenAI chat, games, controls, profile, utilities |
| Website | `website/` | TS/Vite marketing and demo site, including the embedded web client preview |
| Control Plane | `deploy/production/`, `scripts/myapp_ctl.py` | `myapp-ctl` status/log/secret/domain/image/deploy management for test and production hosts |
| Future FaaS | planned | AI-created backend functions for JSON-APPs that need server-side compute, secrets, scheduled jobs, or integrations beyond client-only DSL |

Core flows:

1. **AI app generation**: client sends a chat task -> Backend writes queue/meta to Redis -> worker submits to agent-node -> isolated runtime runs the configured AI coding agent -> backend uploads generated JSON to OSS -> client receives a structured `json_app_ready` event through resumable SSE.
2. **Package install**: client queries Registry with pagination/search -> Registry returns package metadata and download URLs -> client downloads JSON from OSS -> dependency loader resolves libraries and caches them locally.
3. **IM**: mobile uses the native OpenIM SDK path; Web uses `openim/wasm-client-sdk` through `web_openim_bridge`, with framework-level compatibility so JSON IM apps call one API shape.
4. **Self-host backend**: `myapp-ctl secret` manages host-local credentials; `myapp-ctl deploy --pull` or `myapp-ctl deploy --build` starts the backend stack and agent runtime.

---

## The JSON-DSL

A 100-line MyApp config can become a full app with screens, navigation, network calls, animations, native widgets. The DSL is documented in [JSON-DSL.md](JSON-DSL.md).

Minimal example:

```json
{
  "dsl": "3.3",
  "meta": { "name": "hello", "version": "1.0.0", "type": "app" },
  "global": { "count": 0 },
  "ui": {
    "screens": [{
      "name": "home",
      "body": {
        "type": "container",
        "layout": "column",
        "children": [
          { "type": "text", "value": "Counter: {{ global.count }}" },
          { "type": "button", "label": "+1", "action": {
            "call": "@set",
            "args": { "var": "global.count", "value": { "+": [{ "var": "global.count" }, 1] } }
          }}
        ]
      }
    }]
  }
}
```

Drop this through the AI generation flow, or `flutter run` and pick the JSON file from disk.

---

## Features

### Engine
- 30+ widgets (text / button / input / list / image / video / chart / map / webview / camera / qr / chat bubble / …)
- JsonLogic expression engine with 15 custom operators
- 30+ built-in functions (HTTP, JSON, string, array, control flow, UI feedback)
- `@parallel` for concurrent steps
- Templates `{{ path }}` resolve to original type (not stringified)
- Hot-swap config from network / disk / registry

### Backend
- Supabase auth integration
- AI chat with provider-scoped queues and isolated agent execution (Claude-compatible providers / DeepSeek / MiniMax)
- Channel-agnostic push (APNs + FCM, easy to add more)
- Package registry with namespaces + semver + dependency resolution
- **Cross-instance mirror** — self-hosted instance can mirror packages from upstream (lazy file proxy + 10-minute index sync)
- User admin UI (role / ban / reset password)
- Audit log

### Deploy
- `myapp-ctl deploy` for full-stack or component-level backend deployment
- `myapp-ctl secret` for host-local provider, push, OSS, and backend secrets
- Isolated agent-node + Docker runtime for AI workers
- Built-in MinIO for media uploads
- Healthchecks, logs, restart, status, and agent inspection commands

---

## Status

| Area | State |
|---|---|
| Engine (Dart) | Production. 34k LOC. Powering a real app. |
| Backend (Python) | Production. 7k LOC. Running real users. |
| Tests | Widget smoke test plus JSON regression suite (`templates/regression-test.json`). PRs adding coverage very welcome. |
| Docs | Mid (CLAUDE.md, JSON-DSL.md, REGISTRY_README.md, BACKEND_DEPLOY.md). Improving. |
| API stability | DSL v3.3 — minor breaking changes possible until v4. Backend HTTP API stable. |
| Public hosted? | Yes (subject to fair use, see Terms) |

---

## Contributing

Issues, PRs, discussions all welcome.

- Documentation in [`CLAUDE.md`](CLAUDE.md) (also doubles as Claude Code instructions if you're using AI to contribute)
- JSON-DSL specification in [`JSON-DSL.md`](JSON-DSL.md)
- Code conventions:
  - Comments answer *why*, not *what* (the code shows what)
  - Avoid speculative abstractions; three similar lines beat a premature interface
  - For UI changes, test the golden path *and* edge cases in a browser/simulator before claiming done

---

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

You may:
- Use this in commercial products
- Fork and modify freely
- Self-host the whole stack

You may not:
- Use the **"MyApp" name or logo** without permission (apply for a [trademark license](#))
- Misrepresent the origin of the code

Marketplace packages, uploaded assets, and user-created JSON apps are owned and
licensed by their authors unless they explicitly say otherwise.

---

## Acknowledgements

- [Flutter](https://flutter.dev) — UI framework
- [Supabase](https://supabase.com) — auth + DB + storage backend
- [OpenIM](https://github.com/openimsdk) — IM SDK + server
- [Anthropic Claude Code CLI](https://docs.claude.com/en/docs/claude-code) — AI generation runtime
- [JsonLogic](https://jsonlogic.com) — expression engine

---

## Roadmap (in priority order)

- [ ] Drop a 60-second viral demo video (AI → app in 30 seconds)
- [ ] Public hosted free tier
- [ ] App share-link with QR (open AI-generated app via deep link)
- [ ] Add CI (GitHub Actions: pub get, analyze, build APK)
- [ ] More example JSON-APPs (todo, notes, fitness tracker)
- [ ] Prompt system v2: split the long app-generation prompt into core rules + task cards, and move JSON validation into tooling
- [ ] Agent runtime support: allow different AI coding agents/runtimes such as Codex to generate, repair, and publish JSON-APPs
- [ ] Audio support for JSON-APPs (recording, playback, upload, and reusable audio UI/actions)
- [ ] FaaS support: let AI conversations create small backend functions for complex apps, with resource limits, deployment isolation, and self-hosting controls
- [ ] Mario JSON demo parity: finish Koopa spawn/movement/rendering parity against the original `flutter_game` reference before treating that demo as fully complete
- [ ] DSL v4 (stabilize breaking-change window)
- [ ] More tests around the interpreter
- [ ] Performance: defer interpret of off-screen subtrees

---

*Built with care. Open to feedback.*
