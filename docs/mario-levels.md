# Mario 关卡制作规范（demo_mario_full 多关卡）

`demo_mario_full.json` 是数据驱动的多关卡马里奥：**关卡选择器 + 关卡注册表 + 动态
`@tiled.load`**。旧的单关 `demo_mario_platformer.json` 保持不动。加一个新关卡 = 写一份
**紧凑关卡 JSON**（`assets/mario/levels/`）→ 跑 `scripts/mario_level_build.py` 一键产出
背景长图 + TMX → 上传 OSS → 注册表登记一行。无需改框架、无需改游戏逻辑、无需外部素材。

**1-2（地下）/ 1-3（跳台）/ 1-4（灰色堡垒）已用这条产线建成并解锁**（demo-mario-full
v1.1.0），关卡源数据在 `assets/mario/levels/mario-1-{2,3,4}.json`。

## 自动化产线（mario_level_build.py）

```bash
# 素材来源（不入仓库）：两张参考图
#   level_1.png  ← DaQinShgy/flutter_game 克隆（assets/images/mario/），地面真值调色板
#   tiles.png    ← mx0c/super-mario-python 克隆（img/），提供地下蓝/堡垒灰变体
python3 scripts/mario_level_build.py --ref-strip level_1.png --sheet tiles.png \
    build assets/mario/levels/mario-1-2.json \
    --out-png out/level_2.png --out-tmx out/mario-1-2.tmx   # 需 Pillow（构建机跑）
```

渲染器的正确性证明：用 `assets/mario/levels/ref-1-1.json` 重建 1-1 整条长图
（3392×224），与原版 **逐像素 0 差异**。坐标模型：格 (c,r) 在长图像素 (16c, 8+16r)
——注意 8px 纵向偏移；地面顶 = 第 12 行 (y=200)。

### 关卡 JSON 格式（紧凑格网坐标，行 0-13）

| 字段 | 形式 | 说明 |
|---|---|---|
| `length` | int | 关卡宽（格）；长图宽 = 16×length |
| `sky` | `[r,g,b]` | 背景色，缺省天蓝（地下/堡垒用 `[0,0,0]`） |
| `palette` | `overworld` / `underground` / `castle` | 地面/台阶/顶棚砖的调色板 |
| `ground` | `[[a,b],…]` | 地面段（含 a 不含 b），空档=坑 |
| `ceiling` | `[[a,b],…]` | 顶棚（烘焙砖 + collider，占顶部 40px） |
| `stairs` | `[[x,h,"up"/"down"],…]` | 台阶金字塔（≤4 高可跳越） |
| `platforms` | `[[x,row,w],…]` | 悬浮台阶砖排（row 8 可从地面跳上） |
| `pipes` | `[[x,top_row],…]` | 管道（2 格宽，body 铺到地面） |
| `blocks.question` | `[[x,row,type],…]` | type ∈ coin / red mushroom / mushroom flower / green mushroom / star |
| `blocks.brick` | `[[x,row],…]` | 可顶碎砖（row 8 低层 / row 4 高层） |
| `enemies.goomba` | `[[x,row],…]` | 站立行（地面=11，台上=台 row-1） |
| `enemies.koopa` | `[[x],…]` | 引擎 marker 约定（x+8, y=201, 1×1） |
| `flag` / `castle` | int | 旗杆列（自动配 9 段 pole+finial+flag+基座）/ 城堡左列（5×5 烘焙） |
| `decor` | `[["hill_big",x] / ["hill_small",x] / ["bush",x,mids] / ["cloud",x,mids,row],…]` | 按列表顺序绘制（先画的在下层） |

设计护栏（保证可通关）：跳跃上限 4 行 → 障碍 ≤4 高、悬浮台在 row 8、row 4 需从
row 8 顶上二段跳；坑宽 ≤3；出生区（0-8 列）留平地无敌人。

## 一个关卡 = 三样东西（产线自动产出前两样）

| # | 产物 | 说明 | 来源 |
|---|---|---|---|
| 1 | **背景长图** `images/mario/level_<n>.png` | 整关一张横条 PNG（1-1 是 3392×224）。TMX 的 `<imagelayer name="background">` 引用它 | `mario_level_build.py` 从关卡 JSON 渲染 |
| 2 | **TMX 地图** `tiles/mario-<world>.tmx` | 对象数据（碰撞/砖块/问号块/敌人/旗杆），schema 见下 | 同上，一次生成；上游 smp 关卡数据也可用 `scripts/smp_to_tmx.py` 换算草稿 |
| 3 | **BGM**（可选） | 地下/城堡/水下主题曲 | 目前各关共用 app 级 BGM，无需新增 |

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

1. 写 `assets/mario/levels/mario-<world>.json`（格式见上），跑 `mario_level_build.py`
   产出长图 + TMX；建议再叠一张 QA 图（TMX 各对象矩形描边到长图上）目检对齐。
2. 上传到 OSS（`json-app-assets/demo-mario-platformer/1.0.0/{images,tiles}/…`）。
3. `demo_mario_full.json` 注册表加一行，`unlocked:true`。
4. `python3 scripts/check_app_assets.py templates/demo_mario_full.json` 必须全绿；关卡
   source 是运行时模板会被跳过，需再对每个 TMX URL 逐个 HEAD 并解析其内部
   `<image source>` 同样 HEAD（当场抓出"漏传文件"）。
5. 发布模板到 registry（bump `meta.version`）。

## 进阶机制（可选增强，各自需补游戏逻辑）

现有 1-1 已具备：跑跳物理、踩敌/龟壳、顶砖、问号块、金币、蘑菇/花/火球、旗杆结算、
计时分数。已建成的 1-2/1-3/1-4 全部只用这套现有机制（管道只作碰撞、结尾统一旗杆）。
想更贴近原作可在 `frame.logic` 加对应逻辑（不改框架，用已注册的游戏动作）：

- **管道传送 / 子区域**：需设计 warp 对象 + 切子图或整关横排。
- 移动/升降平台、弹簧（1-2/1-3 原作元素）
- 火棍、Bowser + 斧头断桥（1-4 原作结尾）
- 水下游泳物理（水关）

## 数据来源与授权

关卡布局数据参考 **[mx0c/super-mario-python](https://github.com/mx0c/super-mario-python)**
（开源）；Flame 移植参考 **[DaQinShgy/flutter_game](https://github.com/DaQinShgy/flutter_game)**。
Super Mario Bros. 为任天堂 IP，仅作 demo/教育用途，请勿用于对外商业素材。
