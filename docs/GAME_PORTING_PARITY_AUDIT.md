# Game Porting Parity Audit

This file tracks the corrective pass after the first JSON ports were rejected
as non-parity demos. The previous `demo-bgug-runner`,
`demo-darkness-dungeon`, `demo-new-super-jumper`, `demo-guidi-tu-rps`, and
`demo-guidi-tu-boules` packages were deleted from the production Registry.

## Ground Rules

- No game-specific Dart bridge.
- Prefer JSON DSL with existing `flame_game`, Tiled, audio, gamepad, and entity
  atoms.
- Framework changes are allowed only for reusable atoms, with focused tests.
- Do not republish until each app is playable against its source-game checklist.

## Corrective Pass Notes

- `1.1.0` templates are generated from `scripts/generate_ported_game_templates.py`.
- Asset packs use `asset-packs/<slug>/1.1/` and keep source assets outside the
  Flutter client bundle.
- Do not use nested template paths such as `sprites/{{ vars.items.{{ i }} }}`.
  The generator must emit explicit JSON branches or use generic entity getters.
- If parity needs new runtime behavior, first try JSON branches and existing
  entity/collision atoms. Add framework atoms only when they are reusable.

## BGUG

Source: `bluefireteam/bgug`, MIT.

Parity checklist:

- Source state machine: tutorial/running/dead/end-card/pause behavior.
- Hold-to-jump using `maxHoldJumpMillis`, `jumpImpulse`, and
  `jumpTimeMultiplier`; right-side tap dive only while falling.
- Infinite sector generation using `SECTOR_LENGTH = 1000`, sector zero gem,
  obstacle/gem/coin probabilities, and camera follow.
- Top/bottom obstacle collision kills the player and rotates death sprite.
- Guns mode: block button, temporary blocks, shooters, bullets, gems as ammo.
- HUD: score, held-jump gauge, gems/coins, restart/end-card flow.

## Darkness Dungeon

Source: `RafaelBarbosatec/darkness_dungeon`, MIT.

Parity checklist:

- Render the full Tiled map including tile layers and all 44 object-layer
  objects.
- Build all map object types: door, torch, empty torch, potion, wizard, kid,
  spikes, key, boss, goblin, imp, mini_boss.
- Knight: joystick movement, melee attack, ranged fireball, stamina recovery,
  HP, key state, crypt on death.
- Enemies: vision radius, chase, close-range attack intervals, HP/life bars,
  damage numbers, smoke/explosion death effect.
- Boss: first-sighting camera/dialogue, child enemy summons at HP thresholds,
  boss background music switch.
- Lighting/darkness effect and interface bars.

## New Super Jumper

Source: `flutter_games_compilation/new_super_jumper`.

Parity checklist:

- Use extracted TexturePacker atlas sprites, not a small hand-picked subset.
- Fixed 428x926 world semantics, gravity 9.8, camera follow, score by height.
- Hero states: jump/fall/dead, horizontal acceleration, screen wrap, jetpack,
  bubble shield, bullets.
- One-way platforms with 18 platform variants, broken platform pieces,
  generated sections, out-of-screen cleanup.
- Enemies: hearth/cloud/lightning behavior and contact rules.
- Powerups, coins, bullets, UI counters, pause/game-over menu.

## Guidi Tu: Rock Paper Scissors

Source: `maurovanetti/guidi-tu`, CC BY-NC-SA 4.0.

Parity checklist:

- Use Git LFS assets for hands and interstitial art.
- Build sequence board with `players.length + 2` gesture slots.
- Active choices: rock, paper, scissors, backspace.
- Passive sequence slots and ready-state only after enough gestures.
- Outcome scoring: compare each gesture against every rival sequence.

## Guidi Tu: Boules

Source: `maurovanetti/guidi-tu`, CC BY-NC-SA 4.0.

Parity checklist:

- Use Git LFS assets for bowl/target/interstitial art.
- Drag target above start position, projection arrow and arrowhead.
- Throw bowl using source impulse factor, wall bounces, damping, jack movement.
- Persist previous bowls and updated jack position across turns.
- Outcome score by distance to the final jack position.
