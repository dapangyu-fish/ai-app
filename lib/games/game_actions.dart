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
    }

    // 未识别的 @action — debug 提示
    // ignore: avoid_print
    return null;
  }
}
