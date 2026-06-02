# AI Generation Quality Lab

This document is the working memory for JSON-APP generation quality experiments.
Each round should record the prompt strategy, generated artifact, mobile
screenshot, visible UI defects, and the next prompt change.

For the reusable optimization loop and production-equivalent test rules, see
`docs/deepseek-generation-optimization-playbook.md`.

## Goal

Generated non-game APPs should feel like practical native mobile apps, not
rough web demos serialized into JSON. The default target viewport is `402x874`
for standard iPhone 17. Use `360x780` as the iPhone 13 mini lower-bound
regression viewport.

## Scoring

Use a 1-5 score for each category:

- **Native structure**: app bar, tabs/navigation, primary action, list/detail/form
  flows feel like a mobile app.
- **Visual polish**: spacing, typography, contrast, color semantics, icons, and
  empty states are coherent.
- **Functional completeness**: expected CRUD, persistence, edit/delete/confirm,
  and state feedback are present.
- **DSL correctness**: `json.tool` and `backend/validate_json_app.py` pass; no
  obvious unsupported widget/action fields.
- **Mobile fit**: no clipping/overflow at `402x874`; when risk is high, also
  check `360x780`. Bottom navigation and
  primary actions remain reachable.

## Hypotheses

1. Direct JSON generation causes weak UI because the model optimizes for
   schema validity before visual hierarchy.
2. A required Native Design Brief before JSON may improve hierarchy without
   adding unsupported fields.
3. Flutter-first planning may improve native feel, but it can also leak
   unsupported Flutter concepts into JSON unless the translation step is strict.
4. Good examples and archetypes may matter more than generic warnings.

## Experiment Matrix

| Round | Case | Strategy | Artifact | Screenshot | Scores | Result | Next Change |
|---|---|---|---|---|---|---|---|
| 00 | pomodoro | current prompt baseline | `/tmp/ai-app-claude-repro/5b532aec-fa13-4716-8bd6-6aa5f62bfe8c/job2-generate/app.json` | `/tmp/ai-app-pomodoro-cdp-mobile.png` | native 3 / polish 2 / function 4 / DSL 5 / fit 4 | Valid and usable, but visually sparse; large blank space; generic red palette; tab screen is acceptable but not premium native. | Add stronger app archetypes, disable debug chrome in screenshots, compare direct/native_brief/flutter_first. |
| 01 | diary | direct | `/tmp/ai-app-quality-lab/01/workspace/app.json` | `/tmp/ai-app-quality-lab/01/mobile.png` blank; `/tmp/ai-app-quality-lab/01/mobile-body-compat-v3.png` after renderer fallback | native 2 / polish 2 / function 3 / DSL 1 / fit 3 | Old validator passed, but runtime opened blank because screens used `body` instead of `children`. After fallback it renders only a sparse empty state with app bar; direct strategy took ~19.6 min total, 60 Claude turns, 17 Read + 24 Grep + 7 Edit, and self-used `TaskCreate`/`TaskUpdate`. | Make `screen.body` a validator error, add prompt rule that screen/tab content must use `children`, fix screenshot capture to navigate after mobile emulation, then rerun diary with native_brief. |
| 02 | diary | native_brief | `/tmp/ai-app-quality-lab/02/workspace/app.json` | `/tmp/ai-app-quality-lab/02/mobile.png` | native 3 / polish 3 / function 4 / DSL 5 / fit 4 | Valid and rendered. The Native Design Brief avoided `screen.body`, reduced tool churn versus round 01, and produced a usable diary CRUD app with search and persistence. Visual quality is still mid-tier: empty state dominates the first screen, primary CTA uses emoji text, and the layout feels like a clean web form rather than a real Notes/Journal app. | Test flutter_first for the same diary case, then add a concrete app archetype playbook with first-screen density, no-emoji primary actions, and sample native compositions. |
| 03 | diary | flutter_first | `/tmp/ai-app-quality-lab/03/workspace/app.json` | `/tmp/ai-app-quality-lab/03/mobile.png` | native 3 / polish 3 / function 4 / DSL 5 / fit 4 | Valid and rendered. Flutter-first produced a slightly denser mobile structure than round 02: app bar action, search, mood filters, count, list area, detail/write flows. It did not create a dramatic visual upgrade; the first screen is still mostly empty, the title and empty state rely on emoji, and the search box looks web-like. | Flutter-first can stay as an optional strategy, but prompt work should focus on concrete native archetype examples and stronger visual constraints. |
| 04 | budget | direct | `/tmp/ai-app-quality-lab/04/workspace/app.json` | `/tmp/ai-app-quality-lab/04/mobile.png` | native 2 / polish 2 / function 4 / DSL 3 / fit 4 | Rendered, but the first tab is a poor budget-app first screen: it hides summary cards behind the empty-data state and shows mostly a centered empty prompt plus bottom tabs. During generation it also produced invalid `list.source` jsonlogic and unsupported spacing fields, then self-fixed most issues. After validator hardening it still fails on `style.marginTop`. | Add hard validator errors for `marginTop/Left/Right`, and strengthen prompt: budget/task/habit apps must show 0-value summary/progress scaffolds even when there is no data. |
| 05 | budget | native_brief | `/tmp/ai-app-quality-lab/05/workspace/app.json` | none | native n/a / polish n/a / function 4 / DSL 1 / fit n/a | Failed validation after ~19 min. The planned UI was better on paper, but the JSON kept many unsupported `marginTop/Bottom/Left/Right` fields. The final text incorrectly claimed checks passed while validator still reported ERRORs. | Prompt must say validator ERROR blocks completion, and repeated forbidden-key errors should be fixed with a small recursive cleanup script rather than manual piecemeal edits. |
| 06 | habit | native_brief | `/tmp/ai-app-quality-lab/06/workspace/app.json` | none | native n/a / polish n/a / function 4 / DSL 1 / fit n/a | Failed validation. Product plan was appropriate, but native-looking cards leaked unsupported margin/shadow fields; final text falsely claimed checks passed. | Deterministic repair script is now part of upload and local runner; use it in later rounds and consider a builder/helper for native card/list layouts. |
| 07 | notes | flutter_first | `/tmp/ai-app-quality-lab/07/workspace/app.json` | `/tmp/ai-app-quality-lab/07/mobile.png` | native 3 / polish 2 / function 4 / DSL 5 / fit 4 | Valid after the new repair/validation flow. Functional notes app with search, tags, pin/delete, edit/detail screens. Visual quality remains weak: brown one-note palette, centered empty state, structural emoji in copy/buttons, and visible framework refresh hint. | Add stronger visual examples / helper templates; consider validator warnings for emoji in app bars/buttons/empty states and avoid refresh hints on empty lists. |
| 08 | workout | native_brief | `/tmp/ai-app-quality-lab/08/workspace/app.json`; repaired copy `/tmp/ai-app-quality-lab/08/app-repaired.json` | `/tmp/ai-app-quality-lab/08/mobile.png` crashed; `/tmp/ai-app-quality-lab/08/mobile-repaired.png` after repair | native 3 / polish 3 / function 4 / DSL 2 original, 5 repaired / fit 4 | Big improvement in generation process: used Python generator and native helper functions, no `body`/per-side margin/shadow. But validator missed `margin`/`padding` dicts, causing a runtime crash. After hardening validator/repair, the app renders with stats and primary actions, though still sparse. | Validator now rejects numeric scalar fields with dict/string values; repair converts edge dicts to scalar spacing and removes unsupported `style.margin/padding`. |
| 09 | recipe | native_brief | `/tmp/ai-app-quality-lab/09/workspace/app.json` | `/tmp/ai-app-quality-lab/09/mobile.png` had early font artifact; `/tmp/ai-app-quality-lab/09/mobile-retry.png` is usable | native 3 / polish 3 / function 4 / DSL 5 / fit 4 | Valid after repair. Functional recipe app with search, category chips, favorite switch, list/detail/form/persistence. Visual is usable but still not native-polished: duplicated default app bar + custom header, strong one-note orange, structural emoji, large empty area. | Screenshot capture now waits longer after Flutter readiness to avoid early CJK font artifact. Helper usage should be made stronger, not optional. |
| 10 | contacts | flutter_first | `/tmp/ai-app-quality-lab/10/workspace/app.json` | `/tmp/ai-app-quality-lab/10/mobile.png` | native 3 / polish 3 / function 4 / DSL 5 / fit 4 | Valid after one mechanical repair. Uses Python generator and basic helpers; has search, status filter, CRM list/detail/forms/follow-up persistence. First screen is serviceable but still sparse: promised stats are not visible, empty state dominates, and the layout lacks dense native CRM information. | Make high-level native helpers mandatory for CRUD apps, and add visual acceptance checks for first-screen information density. |

## Current Prompt Changes Under Test

- Removed external `TASKS.md` management; use Claude Code's own
  `TodoWrite`/`TaskUpdate`.
- Added native app quality baseline to `generate_app_prompt.md`.
- Added local JSON web rendering path and mobile screenshot workflow.
- Added explicit `children`-only screen schema rule; `screen.body` now fails
  validation because older clients render it blank.
- Fixed screenshot capture: launch `about:blank`, set mobile metrics, then
  `Page.navigate` instead of reloading after the page has already started.
- Added a native app archetype playbook to the generation prompt: record/list,
  budget/task/habit, and contacts/health/data-library first-screen recipes;
  compact empty states; no emoji as structural UI; bounded source lookup for
  ordinary CRUD/tool apps.
- Hardened validator and prompt against CSS-like per-side margins:
  `marginTop`, `marginBottom`, `marginLeft`, `marginRight`.
- Strengthened validation discipline: any validator `ERROR` blocks a completion
  claim, and repeated forbidden-key failures should be fixed with a recursive
  cleanup script before revalidation.
- Added `backend/repair_json_app.py` and wired it into
  `backend/upload_with_signature.sh`; local quality runner now mirrors this by
  running repair before final validation. The repair pass migrates screen/tab
  `body` to `children`, removes unsupported CSS-like fields, flattens container
  `style`, and removes redundant `action.type: "call"`.
- Added native UI helper functions in `backend/json_app_builder.py`
  (`native_app_bar`, `native_search_bar`, `native_metric_card`,
  `native_empty_state`, plus safe `card`/`button`/`icon`/`spacer`) and prompted
  complex CRUD generators to use them.
- Hardened validator against another runtime-crash class: scalar numeric fields
  such as `margin`, `padding`, `height`, `fontSize`, etc. must be numbers, not
  dicts or strings. Repair now converts edge `margin`/`padding` dicts to scalar
  spacing and removes unsupported `style.margin` / `style.padding`.
- Increased screenshot stabilization wait after Flutter Web readiness because
  round 09 initially captured CJK glyphs before fallback fonts settled.
- Made native helper usage mandatory for complex CRUD apps and added first
  viewport visual acceptance rules: at least two useful structural regions below
  the app bar, no duplicated headers, compact empty states, and no emoji as
  primary UI chrome.
- Added two concrete high-quality JSON templates generated from native-style
  Material app compositions:
  `templates/native_quality_notes.json` and
  `templates/native_quality_crm.json`. These are examples for generation, not
  static UI scoring rules.

## Findings After Round 10

1. Claude Code's own task tools are real and sufficient. Multiple rounds used
   `TaskCreate` / `TaskUpdate`; the external `TASKS.md` file is not needed.
2. Prompt-only schema discipline is not reliable. The model repeatedly claimed
   success while validator ERRORs remained. Deterministic repair + validator
   hardening is required for production robustness.
3. The largest reliability wins came from code, not prose:
   - local JSON rendering path for fast visual inspection;
   - `screen.body` validator block plus runtime fallback;
   - `repair_json_app.py` before upload;
   - numeric scalar validation for runtime-crash fields.
4. Native UI quality improved from "blank/sparse shell" to "usable utility",
   but still rarely reaches polished native app quality. Common failures:
   duplicated headers, one-note palettes, emoji used as UI chrome, too much
   empty vertical space, and hidden summary cards in empty-data states.
5. Helper-based generation is promising. Round 08 used a Python generator and
   helpers, avoided many forbidden fields, and produced a more coherent first
   screen. However, helpers are currently optional; many rounds still ignore
   the higher-level native helpers.
6. Flutter-first planning is not a silver bullet. It can improve hierarchy, but
   it also encourages Flutter/CSS leakage unless repair/validator catches it.
   Concrete JSON-native examples/helpers matter more than asking the model to
   imagine Flutter.

## Next Optimization Backlog

- Make high-level native helpers mandatory for CRUD apps above ~30 widgets, or
  provide a single `native_crud_app_shell` helper that emits app bar, summary
  row, search/filter row, list, compact empty state, and form/detail scaffolds.
- Add a visual acceptance checklist to the prompt: first 844px viewport must
  show at least two useful non-empty structural regions besides app bar, even
  when data is empty.
- Add validator warnings for structural emoji in app bar titles, primary button
  labels, and empty-state copy.
- Add optional screenshot OCR/pixel heuristics later: reject runtime error
  screens, mostly blank first screens, and duplicated app bars automatically.

## Round Notes

### 01 Diary Direct

- Direct generation did use Claude Code's own task tools:
  `TaskCreate` and `TaskUpdate`. The external task-list file was redundant.
- The model over-indexed on implementation correctness: it repeatedly read
  widget/runtime files, then patched low-level data logic. This improved some
  function calls (`@json_decode.value`, `@str_contains.value/search`) but did
  not protect visual/runtime structure.
- Critical schema miss: it generated `ui.screens[].body`. The runtime's
  canonical screen structure is `ui.screens[].children`, so the first screenshot
  was blank. A compatibility fallback can render some of it, but the validator
  should still block `body` to force clean output.
- Visible UI after compatibility render is only a centered empty state and a
  simple AppBar. It is usable as a skeleton but not a native-feeling diary app:
  the first screen has no search field, no sample/placeholder list affordance,
  generic empty icon, English `Pull to refresh`, and a text hint pointing to a
  pencil while the actual action icon is plus.
- Prompt implication: native quality rules must include concrete per-archetype
  first-screen composition, not just "use native components".

### 02 Diary Native Brief

- This run again used Claude Code's own planning tools:
  `TaskCreate` once and `TaskUpdate` twice. External `TASKS.md` remains
  unnecessary for current Claude Code.
- The Native Design Brief helped with structure: the app used canonical
  `ui.screens[].children`, included search, create/edit/detail/delete, confirm
  deletion, and `lib_database` persistence.
- The model still over-read runtime files, but less than round 01:
  13 `Read` + 9 `Grep` versus 17 `Read` + 24 `Grep`. It initially generated
  unsupported `paddingH`/`marginBottom` fields and self-fixed them after
  validation.
- The rendered first screen is usable but not strong native UI. It has a proper
  app bar, search row, count row, CTA, and empty state, but the empty state
  consumes most of the screen, the CTA uses emoji text, and the composition
  reads as a generic form/list demo.
- Prompt implication: the generator needs explicit archetype recipes for
  record/list apps: dense first screen, native search bar, toolbar/action
  conventions, no emoji primary buttons, and a realistic non-empty visual model
  even when persisted data is empty.

### 03 Diary Flutter First

- Flutter-first also used Claude Code's own task tools and passed validation on
  the first completed artifact. Tool use was lower than the direct/native_brief
  runs: 4 `Grep`, 1 `Glob`, 6 `Bash`, 1 `Write`, and no repeated source-file
  `Read` calls.
- The Flutter mental model helped the page hierarchy: the first screen has an
  app bar action, search row, horizontal mood filters, count label, list area,
  and empty state. Compared with round 02 it is a little closer to a mobile
  notes/journal app.
- The quality ceiling is still low. The visible UI relies on emoji in the title,
  filter chips, and empty copy; the search input has a web-form feel; and an
  empty database still leaves most of the mobile viewport unused.
- Prompt implication: "think in Flutter first" is not enough by itself. The
  generator needs examples of final JSON compositions that already look native,
  plus constraints that forbid emoji as structural UI and require a useful
  first screen even before the user creates data.

### 04 Budget Direct

- This run shows why "valid JSON" is not enough. The app has broad functional
  coverage on paper: home/detail/stat tabs, record form, filters, persistence,
  edit/delete, and clear-all.
- The rendered first screen is still weak. For an empty budget database it hides
  the monthly/today summary cards and category affordances, leaving only a
  centered empty prompt and bottom navigation. A native budget app should show
  0-value income/expense/balance summaries even before the first transaction.
- The prompt changes reduced emoji in structural UI, but the model still used
  unsupported layout habits during drafting: `list.source` as jsonlogic,
  `paddingH`, and `marginTop`. It fixed the `list.source` errors after
  validation, but `marginTop` was not yet blocked by the validator.
- Follow-up applied after this round: validator now rejects `marginTop`,
  `marginLeft`, and `marginRight` together with `marginBottom`; prompt now says
  budget/task/habit apps must show empty 0-state summary scaffolds, not hide the
  whole dashboard behind an empty state.

### 05 Budget Native Brief

- The design plan was stronger than round 04: month selector, income/expense/
  balance summary, today chip, category filters, transaction cards, FAB, edit
  flow, stats page.
- Implementation quality collapsed under UI complexity. The generated JSON
  initially had a syntax error, then fixed syntax, but retained many forbidden
  per-side margins in cards/screens/list item templates.
- The final response claimed all quality checks passed even though
  `backend/validate_json_app.py` still emitted ERRORs. This is a prompt
  compliance problem, not just a schema problem.
- Prompt implication: when validator reports repeated mechanical errors, the
  agent should run a tiny cleanup script against `$TMPFILE` and revalidate,
  instead of trying to patch individual paths or declaring success.

### 06 Habit Native Brief

- Failed validation for the same reason as round 05: the model used `marginTop`,
  `marginBottom`, `marginLeft`, `marginRight`, and `shadow` while trying to
  create a native card layout.
- The planned app had the right product shape: today progress, habit list,
  check-in state, streak count, add/edit screen, and detail stats. The failure
  was mostly mechanical DSL leakage rather than missing product intent.
- The final response again claimed checks passed even though validator ERRORs
  remained. This confirms prompt-only compliance is not stable enough.
- Follow-up applied after this round: add deterministic `repair_json_app.py` and
  run it before upload/validation. On copies of the round 05 and round 06
  artifacts, the repair pass removed all current validator errors.

### 07 Notes Flutter First

- The new repair flow worked: the final artifact validates and renders, after
  earlier drafts had unsupported `marginLeft`/`marginRight`/`shadow` and raw
  jsonlogic in presentation fields.
- Functional coverage is good: search, tags, create/edit/detail, pin, delete,
  clear all, and local persistence.
- Visual quality is still not where it needs to be. The first screen has the
  right app skeleton but feels generic: a one-note brown palette, large empty
  center, emoji in empty copy/buttons, and a framework refresh hint in the
  empty list. This confirms deterministic repair solves schema reliability but
  not native polish.
- Prompt implication: the next improvement should be concrete reusable JSON
  compositions or builder helpers for native list/card/form screens, not just
  more prose rules.

### 08 Workout Native Brief

- This is the first run where the helper strategy clearly changed generation
  behavior. Claude wrote a temporary Python generator, imported
  `json_app_builder`, and used `native_empty_state` / `native_app_bar`.
- Static validator initially passed and no mechanical repairs were reported,
  but the app crashed at runtime because `margin` / `padding` were sometimes
  dicts like `{top,bottom,left,right}` while Flutter widgets expect a scalar
  number.
- After adding numeric-scalar validation and extending repair, a repaired copy
  renders. The UI is better than earlier empty screens: it shows weekly stats,
  recent training section, and bottom primary actions. It is still sparse and
  includes an emoji in the primary action, but it no longer feels like a pure
  blank-state demo.
- Prompt/process implication: helper-based generation is promising, but the
  validator must cover runtime type assumptions, not just schema shape.

### 09 Recipe Native Brief

- The app validates after repair and covers the expected product flow: search,
  category chips, favorite-only switch, list cards, detail page, form page, and
  SQLite persistence.
- It did not use the new native helper functions. Repair removed repeated
  `action.type` noise plus a few `marginLeft`/`marginRight`/`shadow` fields.
- The first screenshot captured Chinese text as fallback-glyph stripes; a retry
  after waiting longer rendered correctly. The capture script now waits longer
  after Flutter readiness.
- UI quality is acceptable but not premium native: a default app bar duplicates
  the custom orange header, the palette is dominated by a single orange, and
  emoji are still used as structural markers.

### 10 Contacts Flutter First

- Valid after one mechanical repair (`action.type`). The app used a Python
  generator and basic builder helpers, but not the higher-level native helper
  compositions.
- Functional coverage is good for a CRM utility: customer list, search, status
  filter, detail page, add/edit customer, follow-up records, next-step reminder,
  and SQLite persistence.
- The visible first screen is better than the earliest diary/budget rounds but
  still too sparse for a CRM. The generated final text says there are three
  stats cards, but the screenshot shows only search, status dropdown, and a
  large empty state. This is a visual/product mismatch that static validation
  cannot catch.
- Prompt implication: add an explicit visual acceptance checklist: if the first
  viewport is mostly blank in empty-data state, the app is not done. For CRM,
  budget, habit, workout, and notes apps, 0-state summary/progress cards should
  remain visible.

### Next Regression Set

Use the three fresh requests defined in
`docs/deepseek-generation-optimization-playbook.md` after the current runtime
and template changes are committed. These are intentionally not template apps:

- camping gear packing utility
- home plant care control dashboard
- vertical diving collection game

For each run, record the artifact path, validation result, `402x874` and
`360x780` screenshots, visible defects, and whether the fix belongs in prompt
docs, examples, validator, repair, builder helpers, or runtime primitives.

## Runner

```bash
flutter build web
python3 scripts/ai_generation_quality_lab.py \
  --round 01 \
  --case diary \
  --strategy direct
```

Artifacts are written under `/tmp/ai-app-quality-lab/<round>/`.
