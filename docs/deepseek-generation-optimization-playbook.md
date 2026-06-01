# DeepSeek JSON-APP Generation Optimization Playbook

This document is the reusable working process for improving JSON-APP generation
quality when the production model is non-visual DeepSeek and the evaluator is a
stronger multimodal LLM.

The goal is not to make one good demo. The goal is to keep improving the
production generation path with evidence from generated apps, validator output,
and real Flutter Web screenshots.

## Roles

- **DeepSeek / Claude CLI** generates the JSON-APP in the same way production
  backend does.
- **The multimodal evaluator** changes prompts, examples, repair scripts,
  validators, and framework helpers based on actual rendered output.
- **The validator** blocks mechanical failures before upload. It is not a
  substitute for visual review.

## Non-Negotiable Principle: Production Equivalence

Quality tests must match backend production injection by default.

- Use the real system prompt selected by `backend/config.py`.
- Use the same normal prompt wrapper as `backend/ai_session.py` /
  `backend/claude_chat.py`: `<user_request>`, `AI_APP_WORKSPACE`, and the
  reminder to follow the system prompt every round.
- Do not add lab-only instructions such as "do not upload", "local experiment",
  or "return local path" when validating production quality.
- Extra research strategies such as "Flutter-first" or "Native Design Brief"
  are allowed only as explicit opt-in experiments. Do not mix them into the
  default production-equivalent smoke test.

The helper script `scripts/ai_generation_quality_lab.py` defaults to production
equivalence. Use `--inject-strategy` only when intentionally A/B testing a
strategy, not when deciding whether the backend is ready.

## Device Targets

Design and QA use logical viewport sizes, not physical pixels.

- **Primary target:** standard iPhone 17, `402x874` logical viewport. Apple
  lists iPhone 17 as `2622-by-1206` physical pixels at 460 ppi; the practical
  Flutter/Web logical viewport is approximately `402x874`.
- **Lower bound:** iPhone 13 mini, `360x780` logical viewport. Apple lists
  iPhone 13 mini as `2340-by-1080` physical pixels at 476 ppi; at 3x this is
  `360x780`.

At the lower bound the UI may scroll farther or reduce visible density, but
important cards, primary actions, bottom navigation, QR codes, and active
controls must not be clipped horizontally.

## Standard Loop

1. **Choose one concrete app request.**
   Use diverse cases: native utility, device/media/control dashboard, IM/social,
   and game. Avoid repeatedly testing only note/CRUD apps.

2. **Run production-equivalent generation.**

   ```bash
   python3 scripts/ai_generation_quality_lab.py \
     --round prod-eq-YYYYMMDD-case-name \
     --case '具体用户需求' \
     --env-file /tmp/ai-app-backend.env \
     --timeout 3600 \
     --capture-small
   ```

   The default screenshot is `402x874`. `--capture-small` also captures
   `360x780`.

3. **Check validator results.**
   The script runs:

   ```bash
   python3 backend/repair_json_app.py "$AI_APP_WORKSPACE/app.json"
   python3 backend/validate_json_app.py "$AI_APP_WORKSPACE/app.json"
   ```

   Any `ERROR` means the generation flow is not good enough. Fix the prompt,
   repair script, framework helper, or validator, then rerun.

4. **Inspect screenshots visually.**
   Look at both the primary and lower-bound viewport when present. Evaluate:

   - Does it look like a native mobile app rather than a web demo?
   - Is the first viewport useful and dense enough?
   - Are core controls visible after summary/header content?
   - If content extends below the viewport, can it actually scroll to the
     bottom on the phone viewport?
   - Are icons real, not red question marks?
   - Are QR codes, cards, chips, buttons, and tabs clipped?
   - Are dynamic labels rendered as user text, not JSON/JsonLogic objects?
   - For games, are player, enemies, and collectibles real game assets or
     coherent pixel art, not emoji/text placeholders?

5. **Classify the failure.**

   - **Prompt failure:** DeepSeek did not read the right doc, chose a weak
     layout, used emoji, copied an old pattern, or misunderstood a rule.
   - **Example failure:** no close high-quality template exists for this app
     family.
   - **Validator gap:** JSON passes but renders wrong, crashes, or leaks data
     structures into text.
   - **Framework gap:** generated JSON is reasonable but runtime lacks common
     icons/helpers/aliases or has a brittle layout behavior.
   - **Repair gap:** common mechanical errors can be safely converted before
     validation.

6. **Patch the smallest durable layer.**

   - Prompt docs for design intent, classification, or exploration routing.
   - Templates/examples for reusable visual patterns.
   - `backend/json_app_builder.py` helpers for layout patterns AI should not
     hand-roll.
   - `backend/validate_json_app.py` for hard failures that should never upload.
   - `backend/repair_json_app.py` only for safe mechanical conversions.
   - Runtime registries such as `IconRegistry` when a generated name is common
     and maps cleanly to Flutter.

7. **Record the round.**
   Add a concise note in `docs/ai-generation-quality-lab.md` or the relevant
   template doc:

   - request
   - prompt mode / strategy
   - artifact path
   - screenshot path
   - validator result
   - visible defects
   - concrete fix applied
   - next case to test

## Current Prompt Architecture

The default backend mode is indexed prompt loading:

- Core prompt: `backend/prompts/generate_app_prompt_indexed.md`
- Index: `backend/prompts/generation/index.md`
- Type docs:
  - `native_app.md`
  - `game.md`
  - `im_social.md`
  - `media_device.md`
  - `assets.md`
  - `debug_existing.md`
  - `validation.md`

The backend still injects the core rules twice by design:

- as `--append-system-prompt`
- inside each normal `-p` request as a reminder to re-read the indexed prompt
  and not forget workspace, repair/validate/upload, and final URL rules

Keep this dual injection. It is a production safety mechanism against long
multi-turn drift.

## Known Failure Patterns and Fixes

- **Huge prompt bloat:** solved by indexed prompt docs. DeepSeek reads the
  index, classifies the request, then reads only relevant docs/templates.
- **External task list not used:** do not rely on a separate generated task
  list. Claude/DeepSeek already uses internal task tools; quality comes from
  prompt structure, validators, helpers, and examples.
- **Unknown icons become red question marks:** expand `IconRegistry` for common
  names and make validator reject unknown static icon names.
- **Three metric cards squeezed into one row:** helper and prompt enforce max
  two columns on mobile.
- **Control dashboards show only summaries:** prompt requires real controls to
  appear immediately after the summary area.
- **`{op,args}` displayed in text:** repair converts mechanical `{op,args}` to
  standard JsonLogic; validator rejects structured values in presentation text.
- **QR or chips clipped at small widths:** primary design is `402x874`, but
  `360x780` lower-bound must not horizontally clip key content. Use wrap,
  flexible layout, shorter labels, or a vertical fallback.
- **Long page cannot scroll to lower content:** usually caused by a default
  full-height `list`/non-shrink grid/refresh changing the screen to a fixed
  Column, or by over-conservative runtime detection of horizontal `expanded`
  cards. Use `shrinkWrap:true` for embedded short lists/grids, keep full-height
  lists as direct screen/tab main regions, and verify scroll on `402x874`.
- **Template anchoring / skinning:** DeepSeek may over-copy the nearest demo.
  Treat templates as DSL/API references only. For IM/social apps, `demo_im`
  is only for `lib_im` / `lib_user` wiring; tabs, page ids, function names,
  contact rows, visual hierarchy, and copy must be redesigned for the current
  product. If replacing the brand words still leaves the app looking like the
  template, update the prompt and regenerate.
- **Game uses emoji as player/collectible:** game prompt requires sprite,
  animated sprite, or coherent pixel art for primary entities.

## Release Checklist

Before pushing prompt/generation changes:

```bash
python3 -m py_compile \
  backend/config.py \
  backend/ai_session.py \
  backend/claude_chat.py \
  backend/repair_json_app.py \
  backend/json_app_builder.py \
  backend/validate_json_app.py \
  scripts/ai_generation_quality_lab.py

python3 backend/validate_json_app.py templates/framework_quality_smart_home.json
python3 backend/validate_json_app.py templates/framework_quality_travel_pass.json
python3 backend/validate_json_app.py templates/native_quality_notes.json

git diff --check
```

For production readiness, run at least one production-equivalent DeepSeek case
after major prompt changes. Use `--capture-small` when changing layout rules.

## When Future Evaluation Finds a Bad App

Do not only hand-edit that JSON. Use the bad app as evidence and improve the
system:

1. Save the generated JSON and screenshots.
2. Identify whether the failure belongs in prompt, examples, validator, repair,
   helper, or runtime.
3. Patch the durable layer.
4. Rerun the same case production-equivalently.
5. Record the before/after result.

This is the reusable optimization loop for keeping DeepSeek generation quality
moving upward even though DeepSeek cannot visually inspect the app itself.
