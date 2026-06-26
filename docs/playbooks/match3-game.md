# 三消 / 宝石消消乐（match-3）生成 playbook

适用：宝石消消乐、糖果消除、方块三消、对对碰等「交换相邻 → 三连消除 → 下落补位 → 连锁计分」类游戏。

## 0. 关键结论：三消不是静态网格

最常见的失败是**只画了一个彩色网格但点了没反应**——那不是三消游戏。一个能玩的三消必须有完整闭环：

```
交换相邻两颗 → 检测三连(横/竖≥3) → 命中则消除 → 上方下落补位 → 顶部随机补新宝石
  → 继续检测连锁(cascade) → 计分/步数/目标 → 没有命中则把交换换回去(非法交换回弹)
```

只要缺了「检测/消除/下落/补位/连锁」中的任意一环，用户就会说「根本玩不了」。

## 1. 用 flame_game，不要用纯 list/grid 控件

平台已验证的三消参考实现是 **`templates/match3-pixel.json`**（`flame_game` + 宝石实体，3000 行，真实可玩）。生成时**优先学它的字段与 action 形状**（不要复制它的具体坐标/数值/素材）。

- 宝石用实体（`@spawn` 一个 entity，render 用 pixel/sprite/animated_sprite），位置用 `x/y`，下落用改 `y` 或 `@entity.set`。
- 网格是逻辑上的二维数组（存在 `frame.vars` 里，如 `grid[r][c]=颜色id`），实体只是它的可视投影。
- 必须用 `flame_game` 才能做丝滑的交换/下落动画；静态 grid 控件做不出「下落补位」的连锁观感。

可用 action（来自参考实现，按需取用）：`@spawn` / `@despawn` / `@for_each_entity` / `@entity.set` / `@entity.add` / `@pixel.set_position` / `@score.add` / `@random_int` / `@set` / `@if`(用 `{cond, then}`) / `@loop_by_num` / `@for_each`。

## 2. 数据模型（放在 flame_game.vars 或 global）

```
cols=8, rows=8, types=6           // 6 种颜色
grid: 二维数组 rows×cols，每格存颜色 id（0..types-1）或 -1（空）
selected: 当前选中的格子 {r,c} 或 null
score, moves, target              // 计分、步数、目标分
busy: 动画/连锁进行中时为 true，期间禁止输入
```

初始化：随机填满 `grid`，但要**保证开局没有现成三连**（填充时若新格与左/上两格同色就重roll）。

## 3. 玩法闭环（在 frame.logic / action 里实现）

1. **选中/交换**：第一次点选 `selected`；第二次若点的是相邻格 → 交换 `grid` 两格的颜色。
2. **检测三连**：扫描每行每列，找出长度 ≥3 的同色连续段，收集所有要消除的格子坐标集合 `matched`。
3. **非法交换回弹**：若交换后 `matched` 为空 → 把两格换回去（交换无效），`selected=null`，return。
4. **消除**：`matched` 里的格子置 -1，`@score.add` 按消除数量计分（连消越多分越高），对应实体 `@despawn` + 消除动画。
5. **下落补位**：每一列从底往上，把非空格往下压实；列顶留出的空格用 `@random_int` 生成新颜色，`@spawn` 新宝石从顶部落下。
6. **连锁(cascade)**：下落后再次检测三连，有就继续消除+下落，循环直到没有新的三连；连锁有额外加分。
7. **结束/目标**：`moves` 递减，到 0 或达到 `target` → 结算弹窗 + 「再来一局」重置。

输入期间 `busy=true`，连锁结束后再 `busy=false`，避免动画中误触导致状态错乱（也是「每秒崩溃/卡死」的常见根因）。

## 4. 视觉与文案（沿用 game.md 规则）

- 宝石要像宝石：用一致的 pixel art 图元组合或 manifest 里的 sprite，**不要用 emoji 或纯文字冒充**（除非用户明确要 emoji 风格）。颜色之间要清晰可区分。
- HUD（分数/步数/目标）固定在屏幕上：相机无关元素写 `"fixed_to_screen": true`。
- 所有用户可见文字用中文：分数 / 步数 / 目标 / 暂停 / 「再来一局」等，不要出现英文 Score/Moves/Game Over。
- 图标只用 `icon_registry.dart` 里注册过的名字，否则渲染成红色问号。

## 5. 上传前自检（除通用 validator 外）

- 点击交换相邻宝石**真的会发生交换**，且只允许相邻。
- 形成三连**真的会消除并下落补位**，不是消失后留空洞。
- 非法交换会**回弹**。
- 连锁能继续触发并加分。
- 有明确的步数/目标与结算 + 重开。
- 没有「点了没反应」的静态网格。

> 参考实现：`templates/match3-pixel.json`（纯 DSL flame_game 三消）、`templates/match3-game.json`（依赖 common-ui 的版本）。生成新三消时学它们的 action/字段形状，但自己设计关卡数值与配色。
