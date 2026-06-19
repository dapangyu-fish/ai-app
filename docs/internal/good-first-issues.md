# Good-first-issues — staged drafts

`gh` was not available when these were drafted, so they are staged here. File them with
the GitHub CLI once authenticated (creates the `good first issue` label on first use):

```bash
# from repo root, authenticated gh
gh label create "good first issue" --color 7057ff --force 2>/dev/null
gh label create "help wanted" --color 008672 --force 2>/dev/null
# then create each issue, e.g.:
gh issue create --title "<title>" --label "good first issue" --body "<body>"
```

Each is scoped to ~half a day and grounded in the roadmap (`README.md`) / `docs/internal/TODO_WIDGETS.md` /
`docs/GAME_PORTING_TASKLIST.md`. Difficulty: 🟢 easy · 🟡 medium.

---

### Templates / example apps (best onboarding)

1. 🟢 **Add a `templates/todo.json` example app** — a polished to-do list (add/complete/delete, local persistence via `@storage_*`). Roadmap: "more example JSON-APPs (todo)". Acceptance: passes `validate_json_app.py`, renders on Web.
2. 🟢 **Add a `templates/notes.json` example app** — notes with list + detail screens + search. Roadmap item.
3. 🟡 **Add a `templates/fitness.json` example app** — workout/habit tracker with a chart widget. Roadmap item.
4. 🟢 **Add `templates/hello.json`** — the smallest possible "hello world" app, referenced from a 5-minute tutorial.
5. 🟢 **Add screenshots/GIFs to 5 flagship templates** — capture `demo_2048`, `demo_tetris`, `demo_im`, `calculator`, `match3-pixel` running and link them from a gallery doc.

### Docs

6. 🟢 **Write `docs/JSON-DSL-CHEATSHEET.md`** — a 1-page English cheat sheet (`{{ }}` vs jsonlogic vs raw rules, widget table, top 15 builtins, 5 snippets). `JSON-DSL.md` is large + Chinese-heavy.
7. 🟢 **Write `docs/TUTORIAL.md`** — "your first app in 5 minutes": open playground → add a screen → add an HTTP call → add a list → publish.
8. 🟢 **Generate a template gallery (`docs/GALLERY.md`)** — categorized index (apps/games/libraries) auto-listed from each template's `meta`.

### Client runtime / widgets

9. 🟡 **Add a `rating` (star) widget** — extend `JsonBaseWidget`, register in `widget_builder.dart`, document in `JSON-DSL.md`, add example. (See CONTRIBUTING "Adding a widget".)
10. 🟡 **Add a `stepper`/`number_input` widget** — common form control.
11. 🟢 **Add more Material icons to `icon_registry.dart`** — map ~30 commonly-requested icon names.
12. 🟡 **Audio: `@audio_play` / `@audio_record` builtins + a simple audio UI widget** — Roadmap: "Audio support for JSON-APPs". Start with playback only.

### Tests / quality

13. 🟡 **Add interpreter tests for control-flow builtins** (`@for_each`, `@while`, `@loop_by_num`) — Roadmap: "more tests around the interpreter".
14. 🟢 **Add a regression test for a flagship template** — load + render `demo_tetris.json` in a widget test.
15. 🟢 **Extend CI template validation** — make `.github/workflows/ci.yml` validate more known-good templates (curate from the 57 that pass `validate_json_app.py`).

### Games

16. 🟡 **Mario demo: Koopa spawn/movement/rendering parity** — finish parity vs the `flutter_game` reference. See `docs/GAME_PORTING_TASKLIST.md`.

### Code health

17. 🟢 **Burn down `flutter analyze` info lints** — CI currently runs `flutter analyze --no-fatal-infos`. Clear the ~30 pre-existing infos: `avoid_print` → `debugPrint` (`lib/config/app_config.dart`), `use_super_parameters`, `use_build_context_synchronously` (add proper `mounted` guards), and `deprecated_member_use` migrations (Radio → `RadioGroup`, `onReorder` → `onReorderItem`, form `value` → `initialValue`, `cacheExtent` → `scrollCacheExtent`). When clean, drop `--no-fatal-infos` to keep it clean. Tackle a few files per PR.
