# Contributing to MyApp

Thanks for your interest! MyApp is a Flutter **server-driven UI** runtime that renders
AI-generated JSON-DSL apps (and their backends) across iOS, Android, Web and desktop.
This guide is for **human contributors** — the AI-assistant conventions live in
[`CLAUDE.md`](CLAUDE.md) / [`AGENTS.md`](AGENTS.md).

## Ways to contribute

- **Add a widget** to the client runtime (great first PR — steps below).
- **Add an example JSON App** to [`templates/`](templates/) (a game, a tool, a UI showcase).
- **Improve docs** — especially an English quickstart / DSL cheat sheet.
- **Fix a bug** or pick up a [`good first issue`](https://github.com/dapangyu-fish/ai-app/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22).

## Dev setup

```bash
git clone https://github.com/dapangyu-fish/ai-app.git
cd ai-app
flutter pub get
flutter run -d <chrome|ios|android>   # default config points at the hosted backend
```

You do **not** need the backend to hack on the client — the default build talks to the
hosted backend, and you can load local JSON for debugging (see
[`docs/local-json-web-debug.md`](docs/local-json-web-debug.md)).

## The contract: `JSON-DSL.md`

`JSON-DSL.md` is the **single source of truth** for the DSL. Two rules:

1. Any framework change that alters DSL behavior **must** update `JSON-DSL.md` in the same PR.
2. Any JSON App must follow `JSON-DSL.md`. The framework should tolerate any *legal* JSON —
   if legal JSON crashes the runtime, that's a framework bug, not a config problem.

## Adding a widget (recommended first PR)

1. Create `lib/json_ui/widgets/<name>_widget.dart` extending `JsonBaseWidget`.
2. Register it in `JsonWidgetBuilder._builders` in `lib/json_ui/widget_builder.dart`.
3. Update the widget type table in `JSON-DSL.md`.
4. Add a tiny example to a template under `templates/`.

## Adding / changing a template

JSON Apps live in `templates/`. Validate before opening a PR:

```bash
python3 backend/validate_json_app.py templates/<your-app>.json
```

Each template needs a `meta` block (`name`, `version`, `type`). Package names: lowercase,
digits, `-`, `_` (no spaces/CJK).

## Before you open a PR

```bash
flutter analyze
flutter test
python3 -m compileall -q backend       # backend syntax
python3 backend/validate_json_app.py templates/<changed>.json   # if you touched templates
```

CI (see `.github/workflows/ci.yml`) runs backend byte-compile + flagship template
validation + `flutter analyze`/`flutter test`. Keep it green.

## PR guidelines

- One focused change per PR; describe **what** and **why**.
- Match the surrounding code style (the repo uses `flutter_lints`).
- Update docs (`JSON-DSL.md` / `README.md`) when behavior changes.
- Be kind — see [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## License

By contributing, you agree your contributions are licensed under the project's
[Apache-2.0 License](LICENSE). Don't use the **MyApp** name/logo in a misleading way
(see [`NOTICE`](NOTICE)).
