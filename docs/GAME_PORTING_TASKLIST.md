# Game Porting Task List

This is the working checklist for JSON-only game ports. Do not add game-specific Dart bridges. If framework work is unavoidable, it must be a reusable atom/component and covered by a focused test.

## Current Batch

- [x] `bgug` from `https://github.com/bluefireteam/bgug` -> `demo-bgug-runner`
- [x] `darkness_dungeon` from `https://github.com/RafaelBarbosatec/darkness_dungeon` -> `demo-darkness-dungeon`
- [x] `new_super_jumper` from `https://github.com/Yayo-Arellano/flutter_games_compilation/tree/main/new_super_jumper` -> `demo-new-super-jumper`
- [x] `guidi-tu` from `https://github.com/maurovanetti/guidi-tu` -> `demo-guidi-tu-rps`, `demo-guidi-tu-boules`
- [x] duplicate `new_super_jumper` request: published one canonical JSON app

## Required Workflow

- [x] Clone the source repos locally and inspect code/assets before writing JSON.
- [x] Identify the original game loop, input model, physics, scoring, win/lose rules, and asset license.
- [x] Host required assets under `json-app-assets` or embed them when small enough.
- [x] Implement gameplay in JSON DSL using existing game atoms first.
- [x] Validate every JSON app with `backend/validate_json_app.py`.
- [x] Add regression tests for any reused or newly discovered framework behavior.
- [x] Publish each app to Registry and verify `/resolve` returns the new version.

## Existing Follow-Up

- [ ] `demo-mario-platformer`: Koopa behavior still needs final parity verification against the original `flutter_game` implementation.
