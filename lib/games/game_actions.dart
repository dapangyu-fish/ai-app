// 游戏专属 @action 注册表。
//
// 这些 @action 跑在 GameLogicEngine 内部，*不*污染主 JsonInterpreter 的 130
// 个全局 action。区别仅适用于 flame_game 内的 logic / tick / input 块。
//
// 类别：
// - @cell_path.*  : snake 用（advance / grow / contains / head）
// - @grid.*       : 网格辅助（random_empty）
// - @scroll_list.*: tap_white_tile 用
// - @score.*      : 分数操作（顺便 emit scoreChanged 事件）
// - @game_over    : 触发结束（顺便 emit gameOver 事件）
// - @game_reset   : 重置（关卡内重玩）

import 'dart:math';

import 'flame_game_engine.dart';
import 'game_entity.dart';
import 'game_logic.dart';

class GameActions {
  GameActions._();

  static final Random _random = Random();

  static dynamic dispatch(
    JsonFlameGame game,
    String call,
    Map<String, dynamic> args,
    GameLogicEngine logic,
  ) {
    switch (call) {
      // ---------- 分数 / 状态 ----------
      case '@score.add':
        {
          final n = (args['n'] as num?)?.toInt() ?? 1;
          game.setScore(game.score + n);
          return null;
        }
      case '@score.set':
        {
          final v = (args['value'] as num?)?.toInt() ?? 0;
          game.setScore(v);
          return null;
        }
      case '@game_over':
        game.triggerGameOver();
        return null;
      case '@game_reset':
        game.resetGame();
        return null;

      // ---------- cell_path ----------
      case '@cell_path.advance':
        {
          final pathId = args['path']?.toString();
          final dir = args['direction']?.toString() ?? 'up';
          if (pathId == null) return null;
          final ent = game.entities[pathId];
          if (ent is! CellPathEntity) return null;
          return ent.advance(dir, game.gameWorld);
        }
      case '@cell_path.grow':
        {
          final pathId = args['path']?.toString();
          if (pathId == null) return null;
          final ent = game.entities[pathId];
          if (ent is! CellPathEntity) return null;
          ent.grow();
          return null;
        }
      case '@cell_path.contains':
        {
          final pathId = args['path']?.toString();
          final cell = args['cell'];
          final skipHead = args['skip_head'] == true;
          if (pathId == null) return false;
          final ent = game.entities[pathId];
          if (ent is! CellPathEntity) return false;
          if (cell is List && cell.length == 2 && cell[0] is num && cell[1] is num) {
            return ent.containsCell(
              (cell[0] as num).toInt(),
              (cell[1] as num).toInt(),
              skipHead: skipHead,
            );
          }
          return false;
        }
      case '@cell_path.head':
        {
          final pathId = args['path']?.toString();
          if (pathId == null) return null;
          final ent = game.entities[pathId];
          if (ent is! CellPathEntity) return null;
          return ent.head;
        }
      case '@cell_path.head_collides_self':
        {
          final pathId = args['path']?.toString();
          if (pathId == null) return false;
          final ent = game.entities[pathId];
          if (ent is! CellPathEntity) return false;
          final h = ent.head;
          return ent.containsCell(h[0], h[1], skipHead: true);
        }
      case '@cells_equal':
        {
          final a = args['a'];
          final b = args['b'];
          if (a is List && b is List && a.length >= 2 && b.length >= 2) {
            return a[0] == b[0] && a[1] == b[1];
          }
          return false;
        }
      case '@not':
        {
          // jsonlogic 的 ! 不会递归 inline action（{call: ...}），
          // 所以提供 @not 让 JSON 能写 {call: @not, args: {value: {call: @xxx}}}
          final v = args['value'];
          if (v == null) return true;
          if (v is bool) return !v;
          if (v is num) return v == 0;
          if (v is String) return v.isEmpty;
          if (v is List) return v.isEmpty;
          if (v is Map) return v.isEmpty;
          return false;
        }

      // ---------- value_grid（2048 类游戏） ----------
      case '@value_grid.slide_merge':
        {
          final id = args['grid']?.toString();
          final direction = args['direction']?.toString() ?? 'left';
          if (id == null) return {'moved': false, 'score': 0};
          final ent = game.entities[id];
          if (ent is! ValueGridEntity) return {'moved': false, 'score': 0};

          bool moved = false;
          int scoreGained = 0;

          if (direction == 'left' || direction == 'right') {
            for (int r = 0; r < ent.rows; r++) {
              final original = List<int>.from(ent.cells[r]);
              final processed = _slideAndMerge(original, direction == 'right');
              if (processed.moved) moved = true;
              scoreGained += processed.score;
              ent.cells[r] = processed.line;
            }
          } else {
            // up / down —— 按列处理
            for (int c = 0; c < ent.cols; c++) {
              final original = <int>[];
              for (int r = 0; r < ent.rows; r++) {
                original.add(ent.cells[r][c]);
              }
              final processed = _slideAndMerge(original, direction == 'down');
              if (processed.moved) moved = true;
              scoreGained += processed.score;
              for (int r = 0; r < ent.rows; r++) {
                ent.cells[r][c] = processed.line[r];
              }
            }
          }
          return {'moved': moved, 'score': scoreGained};
        }
      case '@value_grid.spawn':
        {
          final id = args['grid']?.toString();
          final fourChance =
              (args['four_chance'] as num?)?.toDouble() ?? 0.1;
          if (id == null) return false;
          final ent = game.entities[id];
          if (ent is! ValueGridEntity) return false;
          final empty = <List<int>>[];
          for (int r = 0; r < ent.rows; r++) {
            for (int c = 0; c < ent.cols; c++) {
              if (ent.cells[r][c] == 0) empty.add([r, c]);
            }
          }
          if (empty.isEmpty) return false;
          final picked = empty[_random.nextInt(empty.length)];
          final value = _random.nextDouble() < fourChance ? 4 : 2;
          ent.cells[picked[0]][picked[1]] = value;
          return true;
        }
      case '@value_grid.can_move':
        {
          final id = args['grid']?.toString();
          if (id == null) return false;
          final ent = game.entities[id];
          if (ent is! ValueGridEntity) return false;
          // 有空格 → 能动
          for (int r = 0; r < ent.rows; r++) {
            for (int c = 0; c < ent.cols; c++) {
              if (ent.cells[r][c] == 0) return true;
            }
          }
          // 任意相邻同值 → 能合并
          for (int r = 0; r < ent.rows; r++) {
            for (int c = 0; c < ent.cols; c++) {
              final v = ent.cells[r][c];
              if (c + 1 < ent.cols && ent.cells[r][c + 1] == v) return true;
              if (r + 1 < ent.rows && ent.cells[r + 1][c] == v) return true;
            }
          }
          return false;
        }

      // ---------- grid ----------
      case '@grid.random_empty':
        {
          final exclude = (args['exclude'] as List?) ?? const [];
          final excludeCells = <List<int>>{};
          for (final id in exclude) {
            final ent = game.entities[id?.toString()];
            if (ent is CellPathEntity) {
              excludeCells.addAll(ent.cells.map((c) => [c[0], c[1]]));
            } else if (ent is CellEntity) {
              excludeCells.add([ent.x, ent.y]);
            }
          }
          final free = <List<int>>[];
          for (int x = 0; x < game.gameWorld.cols; x++) {
            for (int y = 0; y < game.gameWorld.rows; y++) {
              if (excludeCells.any((c) => c[0] == x && c[1] == y)) continue;
              free.add([x, y]);
            }
          }
          if (free.isEmpty) return null;
          final picked = free[_random.nextInt(free.length)];
          // 可选 assign：写到 entities.<id>.cell
          final assignId = args['assign']?.toString();
          if (assignId != null) {
            final ent = game.entities[assignId];
            if (ent is CellEntity) {
              ent.x = picked[0];
              ent.y = picked[1];
            }
          }
          return picked;
        }
      case '@cell.set':
        {
          final id = args['id']?.toString();
          final cell = args['cell'];
          if (id == null || cell is! List || cell.length != 2) return null;
          final ent = game.entities[id];
          if (ent is! CellEntity) return null;
          ent.x = (cell[0] as num).toInt();
          ent.y = (cell[1] as num).toInt();
          return null;
        }

      // ---------- scroll_list ----------
      case '@scroll_list.set_speed':
        {
          final id = args['id']?.toString();
          final v = (args['value'] as num?)?.toDouble();
          if (id == null || v == null) return null;
          final ent = game.entities[id];
          if (ent is! ScrollListEntity) return null;
          ent.speed = v;
          return null;
        }
      case '@scroll_list.add_speed':
        {
          final id = args['id']?.toString();
          final v = (args['by'] as num?)?.toDouble() ?? 0;
          final maxV = (args['max'] as num?)?.toDouble();
          if (id == null) return null;
          final ent = game.entities[id];
          if (ent is! ScrollListEntity) return null;
          var next = ent.speed + v;
          if (maxV != null && next > maxV) next = maxV;
          ent.speed = next;
          return null;
        }
      case '@scroll_list.tap':
        {
          // 命中检测 + 处理。返回 'hit' / 'miss' / 'outside'
          // tapped 行的 active cell 命中 → 标记 tapped + 加速 + 加分
          // 命中非 active cell → return 'miss'，由 logic 判断游戏结束
          // 没命中任何行（gap 太小等）→ 'outside'
          final id = args['id']?.toString();
          final px = (args['x'] as num?)?.toDouble() ?? 0;
          final py = (args['y'] as num?)?.toDouble() ?? 0;
          if (id == null) return 'outside';
          final ent = game.entities[id];
          if (ent is! ScrollListEntity) return 'outside';
          final idx = ent.rowIndexAtY(py);
          if (idx < 0) return 'outside';
          final row = ent.rows[idx];
          if (row.tapped) return 'outside';
          if (row.activeIndex < 0) return 'miss';
          final cellsPerRow = row.cells;
          final col = (px / (game.gameWorld.width / cellsPerRow)).floor();
          if (col == row.activeIndex) {
            row.tapped = true;
            return 'hit';
          }
          return 'miss';
        }
      case '@scroll_list.first_unhit_below':
        {
          // 是否有未点击的 active 行已经穿过给定 y（死亡线）
          // tap_white_tile 用：每帧检查
          final id = args['id']?.toString();
          final lineY = (args['y'] as num?)?.toDouble();
          if (id == null || lineY == null) return false;
          final ent = game.entities[id];
          if (ent is! ScrollListEntity) return false;
          for (final r in ent.rows) {
            if (r.activeIndex < 0) continue;
            if (r.tapped) continue;
            if (r.missedChecked) continue;
            if (r.y >= lineY) {
              r.missedChecked = true;
              return true;
            }
          }
          return false;
        }

      // ---------- pixel entity 物理（通用，跟具体游戏无关） ----------
      case '@pixel.set_position':
        {
          final id = args['id']?.toString();
          final p = args['position'] ?? args['p'];
          if (id == null || p is! List || p.length < 2) return null;
          final ent = game.entities[id];
          if (ent is! PixelEntity) return null;
          ent.x = (p[0] as num).toDouble();
          ent.y = (p[1] as num).toDouble();
          return null;
        }
      case '@pixel.set_velocity':
        {
          final id = args['id']?.toString();
          final v = args['velocity'] ?? args['v'];
          if (id == null || v is! List || v.length < 2) return null;
          final ent = game.entities[id];
          if (ent is! PixelEntity) return null;
          ent.vx = (v[0] as num).toDouble();
          ent.vy = (v[1] as num).toDouble();
          return null;
        }
      case '@pixel.add_velocity':
        {
          final id = args['id']?.toString();
          final dv = args['dv'] ?? args['delta'];
          if (id == null || dv is! List || dv.length < 2) return null;
          final ent = game.entities[id];
          if (ent is! PixelEntity) return null;
          ent.vx += (dv[0] as num).toDouble();
          ent.vy += (dv[1] as num).toDouble();
          return null;
        }

      // ---------- 通用 entity 管理 ----------
      case '@spawn':
        {
          // {kind, id, position?, size?, velocity?, render?, ...} — 任意 entity 类型
          final id = args['id']?.toString();
          if (id == null) return false;
          final spec = Map<String, dynamic>.from(args)..remove('id');
          return game.spawnEntity(id, spec);
        }
      case '@despawn':
        {
          final id = args['id']?.toString();
          if (id == null) return false;
          return game.despawnEntity(id);
        }

      // ---------- 碰撞检测 ----------
      case '@collide.rect':
        {
          // 两个 entity 的 AABB 重叠检测。两边都得是 PixelEntity（或同样
          // 暴露 x/y/w/h 的 entity），否则返回 false。
          final a = game.entities[args['a']?.toString()];
          final b = game.entities[args['b']?.toString()];
          if (a is! PixelEntity || b is! PixelEntity) return false;
          return a.x < b.x + b.w &&
              a.x + a.w > b.x &&
              a.y < b.y + b.h &&
              a.y + a.h > b.y;
        }

      // ---------- 迭代 ----------
      case '@for_each_entity':
        {
          // 遍历所有 entity，可选用 where_prefix 过滤。每次迭代 push 一个
          // loop 上下文：{id, entity, index}。do 是 logic 数组，可以在
          // 子动作里用 {{ loop.id }} / {{ loop.entity.position }} 之类。
          final wherePrefix = args['where_prefix']?.toString() ?? '';
          final doSteps = args['do'];
          if (doSteps is! List) return null;
          final ids = game.entities.keys
              .where((k) => wherePrefix.isEmpty || k.startsWith(wherePrefix))
              .toList(); // 复制一份，子 logic 里 spawn/despawn 不影响本轮迭代
          int idx = 0;
          for (final id in ids) {
            final ent = game.entities[id];
            if (ent == null) continue; // 子 logic despawn 掉的跳过
            logic.runLogicWithLoop(doSteps, {
              'id': id,
              'entity': ent.toMap(),
              'index': idx,
            });
            idx++;
          }
          return null;
        }

      // ---------- RNG ----------
      case '@random_int':
        {
          final minV = (args['min'] as num?)?.toInt() ?? 0;
          final maxV = (args['max'] as num?)?.toInt() ?? 100;
          if (maxV <= minV) return minV;
          return minV + _random.nextInt(maxV - minV);
        }
      case '@random_double':
        {
          final minV = (args['min'] as num?)?.toDouble() ?? 0.0;
          final maxV = (args['max'] as num?)?.toDouble() ?? 1.0;
          return minV + _random.nextDouble() * (maxV - minV);
        }
    }

    // 未识别的 @action — debug 提示
    // ignore: avoid_print
    return null;
  }

  // ---------- 私有 helper ----------

  /// 2048 的 slide+merge：把一条线（行或列）按方向滑动并合并
  /// reverse=true 表示朝右/下（先反转、合并、再反转回来）
  static _SlideResult _slideAndMerge(List<int> line, bool reverse) {
    final original = List<int>.from(line);
    final processed = reverse ? line.reversed.toList() : List<int>.from(line);

    // 过滤 0
    final compact = processed.where((v) => v != 0).toList();

    // 相邻同值合并（左到右扫描，每对只合并一次）
    final merged = <int>[];
    int score = 0;
    int i = 0;
    while (i < compact.length) {
      if (i + 1 < compact.length && compact[i] == compact[i + 1]) {
        final newVal = compact[i] * 2;
        merged.add(newVal);
        score += newVal;
        i += 2;
      } else {
        merged.add(compact[i]);
        i += 1;
      }
    }

    // 后面补 0
    while (merged.length < line.length) {
      merged.add(0);
    }

    // 朝右/下 → 反转回去
    final result = reverse ? merged.reversed.toList() : merged;

    // 检查 vs 原始有没变
    bool moved = false;
    for (int j = 0; j < line.length; j++) {
      if (result[j] != original[j]) {
        moved = true;
        break;
      }
    }
    return _SlideResult(result, score, moved);
  }
}

class _SlideResult {
  final List<int> line;
  final int score;
  final bool moved;
  _SlideResult(this.line, this.score, this.moved);
}
