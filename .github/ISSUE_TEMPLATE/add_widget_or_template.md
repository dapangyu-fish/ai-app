---
name: Add a widget or example app
about: Good first contribution — a new widget or a new JSON App template
title: "[good first issue] add "
labels: ["good first issue"]
---

**What to add**
- [ ] A new widget (`lib/json_ui/widgets/<name>_widget.dart`), or
- [ ] A new example JSON App (`templates/<name>.json`)

**For a widget**
- Name / what it renders:
- Steps: extend `JsonBaseWidget` → register in `widget_builder.dart` → update `JSON-DSL.md` → add a tiny example template. (See `CONTRIBUTING.md`.)

**For a template**
- App idea (tool / game / UI showcase):
- Run `python3 backend/validate_json_app.py templates/<name>.json` and confirm it passes.

**Acceptance**
- `flutter analyze` clean, example renders on Web, `JSON-DSL.md` updated if behavior changed.
