# 游戏生成指南

适用：平台跳跃、横版动作/射击、跑酷、弹幕、塔防、解谜、2048、白块、Flappy、拖拽棋盘、连续动画、60fps、物理、关卡。

## 选 widget 还是 flame_game

- 连续动画、60fps、物理、角色移动、关卡、碰撞、拖拽过渡：用 `flame_game`。
- 静态表单、列表、普通仪表盘：不要用 `flame_game`。
- 棋盘/下落方块可用 `value_grid` + matrix/polyomino action；需要丝滑动画时再考虑 `flame_game`。

## 参考模板

只选最相关的 1 个学习 API 形状：

- `templates/demo_2048.json`
- `templates/demo_tap_white_tile.json`
- `templates/demo_jump.json`
- `templates/demo_flappy_bird.json`

模板只用于学习字段和 action 调用，不要复制 demo 的关卡、坐标、素材路径或数值。

## 必须用生成器

游戏通常必须写 `$AI_APP_WORKSPACE/generate_app.py`。优先使用：

```python
import os
import sys

PROJECT_ROOT = os.environ.get("AI_APP_PROJECT_ROOT") or os.getcwd()
sys.path.insert(0, os.path.join(PROJECT_ROOT, "backend"))

from json_app_builder import (
    AssetPack, new_app, screen, asset_bundle, save_json,
    pixel_entity, sprite_entity, animated_sprite_entity, parallax_entity,
    tiled_map_entity, tile_layer, fill_rect, tiled_object,
    tiled_objects_from_run_and_gun_plan, tileset, tiled_map,
    run_and_gun_profile_summary, run_and_gun_stage_plan,
)
```

## 横版 / run-and-gun 关卡

平台跳跃、横版动作、横版射击、run-and-gun 优先使用中立布局 profile：

```python
plan = run_and_gun_stage_plan(viewport_width=420, viewport_height=500, tile=16)
print(run_and_gun_profile_summary())
objects_layer = tiled_objects_from_run_and_gun_plan(plan)
```

最终要能回答：

- 每个 segment 的玩法目的是什么？
- 前两屏玩家能否看到敌人和可互动内容？
- 敌人对象点是否绑定真实 sprite / animated_sprite？
- 子弹是否在命中和离屏两条路径都回收？
- 玩家掉坑、离开地图或被击中后是否 death / respawn / game_over？
- 摇杆上方向是否用于 `aim_y` / upward fire，而不是让角色飞起来？

## flame_game 结构硬规则

- `flame_game` 必须作为 `ui.screens` 下真实可渲染 widget 节点出现，不能藏在 `props`。
- 输入控件和 `flame_game` 是 sibling/overlay；`game-controls.psJoystickGamepad` 不是 game 容器。
- 手柄只负责发输入；必须在 `flame_game.frame.logic` 中把输入变量转成移动、攻击、动画或 `@platformer.step`。
- 标题页、HUD、倒计时、固定按钮等相机无关元素必须写 `"fixed_to_screen": true`。

## entity action

- `flame_game` 内部逻辑里的 `@if` 参数必须写 `{"cond": ..., "then": [...]}`。不要写普通 DSL action 里的 `condition`。
- `@entity.set` 用 `{"id": "...", "field": "x|y|w|h|vx|vy|auto_update|state.xxx|render.xxx", "value": ...}`。
- `@entity.add` 用 `{"id": "...", "field": "x|y|vx|vy|state.xxx", "by": ...}`。
- 不要用旧写法 `path/value`。
- 不要把 `size`、`position`、`velocity` 写成数组；拆成 `w/h`、`x/y`、`vx/vy`。

## 素材

有角色、敌人、地块、背景、爆炸、子弹等视觉资源时，读 `backend/prompts/generation/assets.md`。不要手拼 OSS URL，不要猜 sprite sheet 帧尺寸。

视觉质量要求：

- 玩家、敌人、主要收集物不要用 emoji 或普通文字实体冒充素材，除非用户明确要求 emoji 风格。优先用 manifest 中的 sprite/animated_sprite；找不到合适素材时，用一致的 pixel art 图元组合。
- HUD 可以用短文字，但主要角色和道具必须像游戏资产，而不是聊天文本。
- 背景层次要服务玩法：前景/中景/远景的速度、尺寸、颜色应有区分，且不要只是一堆无意义色块。

## 上传前额外自检

除通用 validator 外，游戏还要检查：

- 游戏 widget 在首屏真实挂载。
- 玩家可移动，输入能改变实体状态。
- 有胜负/失败/重开或明确目标。
- 资源 URL 来自本轮选择的 manifest。
- sprite sheet 帧尺寸来自 manifest/atlas/可复核脚本，不凭文件名猜。
