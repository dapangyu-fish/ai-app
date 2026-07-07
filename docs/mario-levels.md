# Mario 关卡制作规范（demo_mario_full 多关卡）

`demo_mario_full.json` 是数据驱动的多关卡马里奥：**关卡选择器 + 关卡注册表 + 动态
`@tiled.load`**。旧的单关 `demo_mario_platformer.json` 保持不动。加一个新关卡 = 备齐
**三样东西** + 在注册表登记一行，无需改框架、无需改游戏逻辑。

## 一个关卡 = 三样东西

| # | 产物 | 说明 | 来源 |
|---|---|---|---|
| 1 | **背景长图** `images/mario/level_<n>.png` | 整关一张横条 PNG（1-1 是 3392×224）。TMX 的 `<imagelayer name="background">` 引用它 | VGMaps / Ian Albert 的 SMB 全关地图条；或从 tile_set 拼 |
| 2 | **TMX 地图** `tiles/mario-<world>.tmx` | 对象数据（碰撞/砖块/问号块/敌人/旗杆），schema 见下 | 用 Tiled 编辑器按 schema 摆；对象坐标可从 mx0c/super-mario-python 关卡数据换算（`scripts/smp_to_tmx.py`） |
| 3 | **BGM**（可选） | 地下/城堡/水下主题曲 | The Mushroom Kingdom 等，转 ogg/wav |

图片/音频可复用 1-1 已有的图集（tile_set/mario_bros/enemies 等），通常**只有背景长图和
TMX 是每关新增**。

## TMX schema（必须严格沿用 1-1 的图层名与 object type）

游戏逻辑按**图层名**绑定，改名即失效。1-1 的图层：

| objectgroup / imagelayer | 作用 | object `type` 取值 |
|---|---|---|
| `background`(imagelayer) | 整关背景条 | — （`<image source="../images/mario/level_<n>.png">`） |
| `grounds` | 地面碰撞 | — |
| `collider` | 额外实体碰撞块（管道等） | — |
| `brick blocks` | 可顶碎砖块 | — |
| `question blocks` | 问号块 | `coin` / `red mushroom` / `mushroom flower` / `green mushroom` / `star` |
| `enemies` | 敌人生成 | `goomba` / `koopa` |
| `flagpole` | 旗杆 | `pole` / `finial` / `flag` |
| `castle` | 终点城堡 | `flag` |

- `map` 头：`tilewidth=8 tileheight=8`，宽度 = 背景条宽/8（1-1 = 424）。
- solid 图层在 app 的 `map` 实体 `solid_layers` 里声明（已含
  grounds/collider/brick blocks/question blocks）。
- 新增 object type 若游戏逻辑不认，会被忽略（不崩）——要新机制需另加逻辑（见"进阶机制"）。

## 注册表（在 demo_mario_full 里登记）

`global.variables.mario_levels` 每关一行：

```json
{"id": "1-2", "name": "WORLD 1-2", "source": "tiles/mario-1-2.tmx", "unlocked": true}
```

- `source` 相对 `map` 实体的 `base_url`（当前 = `.../demo-mario-platformer/1.0.0/`）。
- `unlocked:false` 在选择器里显示为 🔒（点击提示 coming soon），备齐资源后改 `true`。
- 选择器点击 → `@set global.mario_level_source = <source>` → `@navigate {screen: "game"}`
  → 游戏 `map` 实体 `source: "{{ global.mario_level_source }}"` 动态加载。

## 加一个关卡的步骤

1. 备齐背景长图 + TMX（用 `scripts/smp_to_tmx.py` 生成 TMX 对象数据草稿，再在 Tiled 里
   校准坐标）+ 可选 BGM。
2. 上传到 OSS（`json-app-assets/demo-mario-platformer/1.0.0/{images,tiles,audio}/…`）。
3. `demo_mario_full.json` 注册表加一行，`unlocked:true`。
4. `python3 scripts/check_app_assets.py templates/demo_mario_full.json`（含 TMX 及其内部
   图片引用）必须全绿——这能当场抓出"漏传文件"。
5. 发布模板到 registry。

## 进阶机制（后续关卡的硬需求，各自需补游戏逻辑）

现有 1-1 已具备：跑跳物理、踩敌/龟壳、顶砖、问号块、金币、蘑菇/花/火球、旗杆结算、
计时分数。后续关卡新机制需在 `frame.logic` 加对应逻辑（不改框架，用已注册的游戏动作）：

- **管道传送 / 子区域**（1-2）：现有 1-1 无 warp。需设计 warp 对象 + 切子图或整关横排。
- 移动/升降平台、弹簧（1-2/1-3）
- 火棍、Bowser + 斧头断桥（1-4）
- 水下游泳物理（水关）

先做 **1-2** 最省力（只新增管道/平台/Piranha 三机制 + 一份地下背景条与 BGM）。

## 数据来源与授权

关卡布局数据参考 **[mx0c/super-mario-python](https://github.com/mx0c/super-mario-python)**
（开源）；Flame 移植参考 **[DaQinShgy/flutter_game](https://github.com/DaQinShgy/flutter_game)**。
Super Mario Bros. 为任天堂 IP，仅作 demo/教育用途，请勿用于对外商业素材。
