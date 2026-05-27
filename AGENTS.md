# Repository Guidelines

## Project Structure & Module Organization

This repository contains a Flutter client, Python backend services, JSON-DSL app templates, and a Vite website.

- `lib/`: Flutter app code, JSON-DSL runtime, IM integration, and Flame game widgets.
- `backend/`: Flask/Gunicorn services, AI session worker, Registry, validators, prompts, and JSON app builder helpers.
- `templates/`: JSON-DSL demo apps and reusable examples. `templates/bacsase/anti_patterns_and_pitfalls.md` documents generation pitfalls.
- `assets/`, `web/`, `web_openim_bridge/`: bundled app assets and Flutter Web/OpenIM WASM bridge files.
- `website/`: React + TypeScript marketing/demo site.
- `deploy/test-env/`: one-click local/test deployment scripts and Docker Compose files.
- `test/`: Flutter tests.

## Build, Test, and Development Commands

- `flutter pub get`: install Flutter dependencies.
- `flutter analyze`: run Dart static analysis with `flutter_lints`.
- `flutter test`: run Flutter tests.
- `flutter run -d chrome`: run the Flutter Web client locally.
- `./scripts/build_cloudflare_pages.sh`: build the production Flutter Web output.
- `cd web_openim_bridge && npm install && npm run build`: rebuild OpenIM WASM bridge assets under `web/`.
- `cd website && npm install && npm run dev`: run the website locally.
- `cd website && npm run build`: type-check and build the website.
- `python3 backend/validate_json_app.py templates/<app>.json`: validate a JSON-DSL app before publishing.
- `cd deploy/test-env && ./bootstrap.sh`: start a full test environment.

## Coding Style & Naming Conventions

Dart code follows `flutter_lints` from `analysis_options.yaml`; prefer clear widget names, small helpers, and existing Riverpod patterns. Python backend code should use typed helpers where practical, explicit error handling, and no app-specific hardcoding in validators or generators. JSON-DSL package names use kebab-case, for example `demo-platformer-adventure`.

## Testing Guidelines

Run `flutter analyze` and `flutter test` for client changes. For backend generation or Registry changes, run `python3 -m py_compile` on touched Python files and validate representative templates with `backend/validate_json_app.py`. For website changes, run `npm run build` in `website/`.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects such as `fix: ...`, `chore: ...`, or descriptive titles like `Harden game JSON generation validation`. Keep commits focused. PRs should include a summary, test commands run, deployment impact, and screenshots or recordings for UI/gameplay changes.

## Security & Configuration Tips

Do not commit production secrets, `.env` files, signed URLs, or server-local credentials. Backend production config lives outside Git; test-env scripts generate local secrets. JSON app generation must use asset manifest URLs rather than hand-built paths.
