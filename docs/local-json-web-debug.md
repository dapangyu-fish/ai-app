# Local JSON Web Debug Flow

Use this flow to test an AI-generated JSON-APP end to end in the real Flutter
Web interpreter, without logging in and without copying the JSON into the app.

This is intentionally a development-only path. The Flutter entry point only
honors it in debug builds on localhost.

## Run

1. Start the local JSON helper:

   ```bash
   python3 scripts/local_json_server.py --port 8765
   ```

2. Start Flutter Web:

   ```bash
   flutter run -d chrome --web-port 5555
   ```

3. Open the generated app directly:

   ```text
   http://localhost:5555/?local_json=/tmp/ai-app-claude-repro/<session>/<job>/app.json
   ```

   If the path contains spaces, `?`, or `&`, URL-encode the path value.

4. Test primarily at phone size. Use `402x874` as the default viewport
   (standard iPhone 17 logical size). Use `360x780` as the small-device
   regression target for iPhone 13 mini. Desktop may hide cramped mobile layout
   bugs.

For headless screenshots, use Chrome DevTools Protocol mobile emulation rather
than only `--window-size`; headless Chrome may clamp the layout viewport wider
than the screenshot. Set device metrics to `width=402`, `height=874`,
`deviceScaleFactor=1`, `mobile=true` before primary capture, then repeat at
`360x780` for the small-screen lower bound when layout risk is high. At the
lower bound, content may be denser or scroll farther, but key cards, primary
actions, bottom navigation, QR codes, and active controls must not be clipped
horizontally.

## Parameters

- `local_json`, `json_path`, or `json_app`: absolute path to a local JSON file,
  or an `http(s)` URL to a JSON file.
- `local_json_server`: optional helper endpoint. Defaults to
  `http://127.0.0.1:8765/json`.

Example:

```text
http://localhost:5555/?local_json=/tmp/app.json&local_json_server=http://127.0.0.1:8765/json
```

## Why This Exists

Do not build a separate web renderer for JSON-DSL QA. It will drift from the
real client. This path loads the JSON into the same `JsonInterpreter` and
`JsonScreenView` used by the app, so generated app QA catches actual widget,
action, layout, asset, and runtime failures.

For AI generation quality work, the loop is:

1. Generate JSON into an isolated `/tmp` workspace.
2. Validate it with `python3 -m json.tool` and `backend/validate_json_app.py`.
3. Open it through `?local_json=...`.
4. Inspect mobile viewport UI and console errors.
5. Feed concrete crash/layout/visual findings back into the prompt or template.
