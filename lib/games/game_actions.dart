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
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'flame_game_engine.dart';
import 'game_entity.dart';
import 'game_logic.dart';
import 'platformer_physics_backend.dart';
import 'tiled_map_entity.dart';

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
        game.resetGame(
          varOverrides: (args['vars'] as Map?)?.cast<String, dynamic>(),
          keepScore: args['keep_score'] == true,
        );
        return null;
      case '@emit':
        {
          final eventName =
              args['event']?.toString() ?? args['name']?.toString();
          if (eventName == null || eventName.isEmpty) return false;
          final data = (args['data'] as Map?)?.cast<String, dynamic>() ?? {};
          game.emitEvent(eventName, data);
          return true;
        }

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
          if (cell is List &&
              cell.length == 2 &&
              cell[0] is num &&
              cell[1] is num) {
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
          final fourChance = (args['four_chance'] as num?)?.toDouble() ?? 0.1;
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
          final x = _asDouble(p[0]);
          final y = _asDouble(p[1]);
          if (x == null || y == null) return null;
          ent.x = x;
          ent.y = y;
          return null;
        }
      case '@pixel.set_velocity':
        {
          final id = args['id']?.toString();
          final v = args['velocity'] ?? args['v'];
          if (id == null || v is! List || v.length < 2) return null;
          final ent = game.entities[id];
          if (ent is! PixelEntity) return null;
          final vx = _asDouble(v[0]);
          final vy = _asDouble(v[1]);
          if (vx == null || vy == null) return null;
          ent.vx = vx;
          ent.vy = vy;
          return null;
        }
      case '@pixel.add_velocity':
        {
          final id = args['id']?.toString();
          final dv = args['dv'] ?? args['delta'];
          if (id == null || dv is! List || dv.length < 2) return null;
          final ent = game.entities[id];
          if (ent is! PixelEntity) return null;
          final dvx = _asDouble(dv[0]);
          final dvy = _asDouble(dv[1]);
          if (dvx == null || dvy == null) return null;
          ent.vx += dvx;
          ent.vy += dvy;
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
      case '@animated_sprite.set_animation':
        {
          final id = args['id']?.toString();
          final name =
              args['animation']?.toString() ?? args['name']?.toString();
          if (id == null || name == null) return false;
          return game.setSpriteAnimation(id, name);
        }
      case '@animated_sprite.effect':
        {
          return _spawnAnimationEffect(game, args);
        }
      case '@entity.exists':
        {
          final id = args['id']?.toString();
          return id != null && game.entities.containsKey(id);
        }
      case '@entity.get':
        {
          final id = args['id']?.toString();
          final field = args['field']?.toString() ?? args['path']?.toString();
          if (id == null || field == null) return null;
          return _readEntityField(game.entities[id], field);
        }
      case '@entity.set':
        {
          final id = args['id']?.toString();
          final field = args['field']?.toString() ?? args['path']?.toString();
          if (id == null || field == null) return false;
          return _writeEntityField(game.entities[id], field, args['value']);
        }
      case '@entity.add':
        {
          final id = args['id']?.toString();
          final field = args['field']?.toString() ?? args['path']?.toString();
          final rawBy = args.containsKey('by') ? args['by'] : args['value'];
          final by = _asDouble(rawBy) ?? 0;
          if (id == null || field == null) return false;
          final current = _readEntityField(game.entities[id], field);
          if (current is! num) return false;
          var next = current.toDouble() + by;
          final minV = _asDouble(args['min']);
          final maxV = _asDouble(args['max']);
          if (minV != null && next < minV) next = minV;
          if (maxV != null && next > maxV) next = maxV;
          return _writeEntityField(game.entities[id], field, next);
        }
      case '@entity.flip_by_velocity':
        {
          final id = args['id']?.toString();
          final axis = args['axis']?.toString() ?? 'x';
          final invert = args['invert'] == true;
          final entity = game.entities[id];
          if (entity is! SpriteEntity) return false;
          final velocity = axis == 'y' ? entity.vy : entity.vx;
          if (velocity == 0) return false;
          entity.flipX = invert ? velocity > 0 : velocity < 0;
          return true;
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
      case '@collision.first':
        {
          final a = game.entities[args['a']?.toString()];
          final wherePrefix = args['where_prefix']?.toString() ?? '';
          if (a is! PixelEntity || wherePrefix.isEmpty) return null;
          for (final entry in game.entities.entries) {
            if (!entry.key.startsWith(wherePrefix)) continue;
            final b = entry.value;
            if (b is! PixelEntity) continue;
            if (_rectsOverlap(a, b)) return entry.key;
          }
          return null;
        }

      // ---------- tiled map / platformer ----------
      case '@tiled.loaded':
        {
          final id = args['id']?.toString() ?? args['map']?.toString();
          final ent = game.entities[id];
          return ent is TiledMapEntity && ent.loaded;
        }
      case '@tiled.first_object':
        {
          final mapId = args['map']?.toString();
          final layer = args['layer']?.toString();
          if (mapId == null || layer == null) return null;
          final ent = game.entities[mapId];
          if (ent is! TiledMapEntity) return null;
          return ent.firstObject(layer)?.toMap();
        }
      case '@tiled.load':
        {
          final mapId = args['map']?.toString() ?? args['id']?.toString();
          final source = args['source']?.toString();
          final mapData = (args['map_data'] as Map?)?.cast<String, dynamic>();
          if (mapId == null) return false;
          final ent = game.entities[mapId];
          if (ent is! TiledMapEntity) return false;
          if (mapData != null) {
            ent.loadMapData(mapData);
            return true;
          }
          if (source == null || source.isEmpty) return false;
          ent.loadSource(source);
          return true;
        }
      case '@tiled.clear_spawned':
        {
          final prefix = args['prefix']?.toString() ?? '';
          if (prefix.isEmpty) return false;
          final ids = game.entities.keys
              .where((id) => id.startsWith(prefix))
              .toList(growable: false);
          for (final id in ids) {
            game.despawnEntity(id, consumeTiledObject: false);
          }
          return ids.length;
        }
      case '@tiled.spawn_objects':
        {
          return _spawnTiledObjects(game, args);
        }
      case '@tiled.spawn_objects_near':
        {
          return _spawnTiledObjects(game, args, proximityOnly: true);
        }
      case '@tiled.collisions':
        {
          final mapId = args['map']?.toString();
          final entityId = args['entity']?.toString() ?? args['id']?.toString();
          final map = game.entities[mapId];
          final entity = game.entities[entityId];
          if (map is! TiledMapEntity) return const [];
          final rect = _rectFromArgs(args, entity);
          if (rect == null) return const [];
          return map.collisionRectsIn(rect).map((e) => e.toMap()).toList();
        }
      case '@tiled.has_collision_type':
        {
          final mapId = args['map']?.toString();
          final entityId = args['entity']?.toString() ?? args['id']?.toString();
          final type = args['type']?.toString().toLowerCase();
          final map = game.entities[mapId];
          final entity = game.entities[entityId];
          if (map is! TiledMapEntity || type == null) {
            return false;
          }
          final rect = _rectFromArgs(args, entity);
          if (rect == null) return false;
          if (type == 'hazard' && rect.top > map.heightPx) return true;
          return map
              .collisionRectsIn(rect)
              .any((collision) => collision.type.toLowerCase() == type);
        }
      case '@tiled.nearest_object':
        {
          final mapId = args['map']?.toString();
          final layer = args['layer']?.toString();
          final beforeX = (args['before_x'] as num?)?.toDouble();
          if (mapId == null || layer == null || beforeX == null) return null;
          final ent = game.entities[mapId];
          if (ent is! TiledMapEntity) return null;
          TiledObject? best;
          for (final object in ent.objectsByLayer[layer] ?? const []) {
            if (object.x >= beforeX) continue;
            if (best == null || object.x > best.x) best = object;
          }
          return best?.toMap();
        }
      case '@platformer.step':
        {
          return _platformerStep(game, args);
        }
      case '@platformer.backend':
        {
          return game.platformerPhysics.toMap();
        }
      case '@platformer.respawn':
        {
          return _platformerRespawn(game, args);
        }
      case '@platformer.stuck_check':
        {
          return _platformerStuckCheck(game, args);
        }
      case '@platformer.section_exit':
        {
          final playerId = args['id']?.toString() ?? args['player']?.toString();
          final mapId = args['map']?.toString();
          final margin = (args['margin'] as num?)?.toDouble() ?? 0;
          final player = game.entities[playerId];
          final map = game.entities[mapId];
          if (player is! PixelEntity || map is! TiledMapEntity || !map.loaded) {
            return false;
          }
          return player.x >= map.widthPx - margin;
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

  static bool _rectsOverlap(PixelEntity a, PixelEntity b) {
    return a.x < b.x + b.w &&
        a.x + a.w > b.x &&
        a.y < b.y + b.h &&
        a.y + a.h > b.y;
  }

  static dynamic _readEntityField(GameEntity? entity, String field) {
    if (entity is PixelEntity) {
      if (field.startsWith('state.')) {
        return entity.state[field.substring('state.'.length)];
      }
      switch (field) {
        case 'position':
          return [entity.x, entity.y];
        case 'size':
          return [entity.w, entity.h];
        case 'velocity':
          return [entity.vx, entity.vy];
        case 'x':
          return entity.x;
        case 'y':
          return entity.y;
        case 'w':
        case 'width':
          return entity.w;
        case 'h':
        case 'height':
          return entity.h;
        case 'vx':
          return entity.vx;
        case 'vy':
          return entity.vy;
        case 'autoMove':
        case 'auto_update':
          return entity.autoMove;
      }
    }
    if (entity is ParallaxEntity) {
      switch (field) {
        case 'speedX':
        case 'speed_x':
          return entity.speedX;
        case 'y':
          return entity.y;
      }
    }
    return entity?.toMap()[field];
  }

  static bool _writeEntityField(
    GameEntity? entity,
    String field,
    dynamic value,
  ) {
    if (entity is PixelEntity) {
      if (field.startsWith('state.')) {
        entity.state[field.substring('state.'.length)] = value;
        return true;
      }
      switch (field) {
        case 'position':
          return _writePixelPair(
            value,
            (a, b) {
              entity.x = a;
              entity.y = b;
            },
            firstKeys: const ['x'],
            secondKeys: const ['y'],
          );
        case 'size':
          return _writePixelPair(
            value,
            (a, b) {
              entity.w = a;
              entity.h = b;
            },
            firstKeys: const ['w', 'width'],
            secondKeys: const ['h', 'height'],
          );
        case 'velocity':
          return _writePixelPair(
            value,
            (a, b) {
              entity.vx = a;
              entity.vy = b;
            },
            firstKeys: const ['vx', 'x'],
            secondKeys: const ['vy', 'y'],
          );
      }
      switch (field) {
        case 'autoMove':
        case 'auto_update':
          entity.autoMove = value == true;
          return true;
      }
      final n = _asDouble(value);
      if (n == null) return false;
      switch (field) {
        case 'x':
          entity.x = n;
          return true;
        case 'y':
          entity.y = n;
          return true;
        case 'w':
        case 'width':
          entity.w = n;
          return true;
        case 'h':
        case 'height':
          entity.h = n;
          return true;
        case 'vx':
          entity.vx = n;
          return true;
        case 'vy':
          entity.vy = n;
          return true;
      }
    }
    if (entity is ParallaxEntity) {
      final n = _asDouble(value);
      if (n == null) return false;
      switch (field) {
        case 'speedX':
        case 'speed_x':
          entity.speedX = n;
          return true;
        case 'y':
          entity.y = n;
          return true;
      }
    }
    return false;
  }

  static Rect? _rectFromArgs(Map<String, dynamic> args, GameEntity? entity) {
    final raw = args['rect'];
    if (raw is List && raw.length >= 4) {
      final x = _asDouble(raw[0]);
      final y = _asDouble(raw[1]);
      final w = _asDouble(raw[2]);
      final h = _asDouble(raw[3]);
      if (x != null && y != null && w != null && h != null) {
        return Rect.fromLTWH(x, y, w, h);
      }
    }
    if (raw is Map) {
      final x = _asDouble(raw['x']);
      final y = _asDouble(raw['y']);
      final w = _asDouble(raw['w']) ?? _asDouble(raw['width']);
      final h = _asDouble(raw['h']) ?? _asDouble(raw['height']);
      if (x != null && y != null && w != null && h != null) {
        return Rect.fromLTWH(x, y, w, h);
      }
    }
    if (entity is PixelEntity) {
      return Rect.fromLTWH(entity.x, entity.y, entity.w, entity.h);
    }
    return null;
  }

  static double? _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  static bool _writePixelPair(
    dynamic value,
    void Function(double first, double second) apply, {
    required List<String> firstKeys,
    required List<String> secondKeys,
  }) {
    double? first;
    double? second;
    if (value is List && value.length >= 2) {
      first = _asDouble(value[0]);
      second = _asDouble(value[1]);
    } else if (value is Map) {
      for (final key in firstKeys) {
        first ??= _asDouble(value[key]);
      }
      for (final key in secondKeys) {
        second ??= _asDouble(value[key]);
      }
    }
    if (first == null || second == null) return false;
    apply(first, second);
    return true;
  }

  static bool _platformerStep(JsonFlameGame game, Map<String, dynamic> args) {
    final physics = args.containsKey('engine') || args.containsKey('backend')
        ? PlatformerPhysicsConfig.fromSpec(args)
        : game.platformerPhysics;
    if (!physics.usesAabbRuntime) return false;

    final playerId = args['id']?.toString() ?? args['player']?.toString();
    final mapId = args['map']?.toString();
    if (playerId == null || mapId == null) return false;
    final player = game.entities[playerId];
    final map = game.entities[mapId];
    if (player is! PixelEntity || map is! TiledMapEntity || !map.loaded) {
      return false;
    }
    player.state['physicsEngine'] = physics.engineName;
    player.state['physicsRuntime'] = physics.runtimeName;
    player.state['leapAvailable'] = LeapPlatformerBridge.available;

    final dt = (args['dt'] as num?)?.toDouble() ?? 0;
    if (dt <= 0) return false;
    final gravity = (args['gravity'] as num?)?.toDouble() ?? 1800;
    final maxFall = (args['max_fall'] as num?)?.toDouble() ?? 1600;
    final jumpVelocity = (args['jump_velocity'] as num?)?.toDouble() ?? -720;
    final jumpPressed = args['jump'] == true || args['jump_pressed'] == true;
    final allowDoubleJump = args['allow_double_jump'] == true;
    final autoRun = (args['auto_run'] as num?)?.toDouble();
    final move = (args['move'] as num?)?.toDouble();
    final speed = (args['speed'] as num?)?.toDouble() ?? 320;
    final oneWayTypes = _readStringSet(args['one_way_types']);
    final oneWayTilesets = _readStringSet(args['one_way_tilesets']);

    final onGround = player.state['onGround'] == true;
    if (autoRun != null) {
      player.vx = autoRun;
    } else if (move != null) {
      player.vx = move.clamp(-1, 1) * speed;
    }

    final doubleJumpUsed = player.state['doubleJumpUsed'] == true;
    if (jumpPressed) {
      if (onGround) {
        player.vy = jumpVelocity;
        player.state['onGround'] = false;
        player.state['doubleJumpUsed'] = false;
      } else if (allowDoubleJump && !doubleJumpUsed) {
        player.vy = jumpVelocity;
        player.state['doubleJumpUsed'] = true;
      }
    }

    player.vy = (player.vy + gravity * dt).clamp(-maxFall, maxFall);
    _moveAndCollideSwept(
      player,
      map,
      player.vx * dt,
      player.vy * dt,
      oneWayTypes: oneWayTypes,
      oneWayTilesets: oneWayTilesets,
    );
    if (player.state['onGround'] == true) {
      player.state['lastGroundXVelocity'] = player.vx.abs();
    }
    final rect = Rect.fromLTWH(player.x, player.y, player.w, player.h);
    final hazards = map.collisionRectsIn(rect).where((c) => c.hazard).toList();
    final fellOut = _isBelowMap(player, map);
    player.state['outOfBounds'] = fellOut;
    player.state['hazard'] = hazards.isNotEmpty || fellOut;
    player.state['hazardCollision'] = hazards.isNotEmpty
        ? hazards.first.toMap()
        : fellOut
        ? {
            'x': player.x,
            'y': player.y,
            'w': player.w,
            'h': player.h,
            'type': 'Pit',
          }
        : null;
    return true;
  }

  static bool _platformerRespawn(
    JsonFlameGame game,
    Map<String, dynamic> args,
  ) {
    final playerId = args['id']?.toString() ?? args['player']?.toString();
    final mapId = args['map']?.toString();
    final layer = args['layer']?.toString() ?? 'respawn';
    if (playerId == null || mapId == null) return false;
    final player = game.entities[playerId];
    final map = game.entities[mapId];
    if (player is! PixelEntity || map is! TiledMapEntity) return false;
    TiledObject? best;
    for (final object in map.objectsByLayer[layer] ?? const <TiledObject>[]) {
      if (object.x >= player.x) continue;
      if (best == null || object.x > best.x) best = object;
    }
    best ??= map.firstObject('spawn');
    if (best == null) return false;
    player.x = best.x;
    player.y = best.y - player.h;
    player.vx = 0;
    player.vy = 0;
    player.state['onGround'] = false;
    player.state['doubleJumpUsed'] = false;
    player.state['lastGroundXVelocity'] = 0;
    player.state['hazard'] = false;
    final invincibleSeconds = (args['invincible_seconds'] as num?)?.toDouble();
    if (invincibleSeconds != null && invincibleSeconds > 0) {
      player.state['invincibleUntil'] =
          ((player.state['time'] as num?)?.toDouble() ?? 0) + invincibleSeconds;
    }
    return true;
  }

  static bool _platformerStuckCheck(
    JsonFlameGame game,
    Map<String, dynamic> args,
  ) {
    final playerId = args['id']?.toString() ?? args['player']?.toString();
    final player = game.entities[playerId];
    if (player is! PixelEntity) return false;
    final dt = (args['dt'] as num?)?.toDouble() ?? 0;
    final enabled = args['enabled'] != false;
    final threshold = (args['threshold'] as num?)?.toDouble() ?? 1;
    final timeout = (args['timeout'] as num?)?.toDouble() ?? 1;
    final lastX = (player.state['stuckLastX'] as num?)?.toDouble() ?? player.x;
    var timer = (player.state['stuckTimer'] as num?)?.toDouble() ?? timeout;
    if (!enabled || dt <= 0) {
      player.state['stuckLastX'] = player.x;
      player.state['stuckTimer'] = timeout;
      player.state['stuck'] = false;
      return false;
    }
    if ((player.x - lastX).abs() <= threshold) {
      timer -= dt;
    } else {
      timer = timeout;
    }
    player.state['stuckLastX'] = player.x;
    player.state['stuckTimer'] = timer;
    final stuck = timer <= 0;
    player.state['stuck'] = stuck;
    return stuck;
  }

  static int _spawnTiledObjects(
    JsonFlameGame game,
    Map<String, dynamic> args, {
    bool proximityOnly = false,
  }) {
    final mapId = args['map']?.toString();
    final layer = args['layer']?.toString();
    final prefix = args['prefix']?.toString() ?? '${layer ?? 'object'}_';
    if (mapId == null || layer == null) return 0;
    final map = game.entities[mapId];
    if (map is! TiledMapEntity || !map.loaded) return 0;

    final referenceId = args['reference']?.toString();
    final reference = game.entities[referenceId];
    final proximity = (args['proximity'] as num?)?.toDouble() ?? 0;
    final despawnDistance = (args['despawn_distance'] as num?)?.toDouble();
    final debugSpawn = args['debug'] == true || args['debug_spawn'] == true;
    var count = 0;
    var seen = 0;
    var near = 0;
    var skippedExisting = 0;
    var skippedConsumed = 0;
    var skippedNoSpec = 0;
    var failed = 0;
    final spawnedSamples = <String>[];
    for (final object in map.objectsByLayer[layer] ?? const <TiledObject>[]) {
      seen++;
      if (proximityOnly) {
        if (reference is! PixelEntity || proximity <= 0) continue;
        if ((object.x - reference.x).abs() > proximity) continue;
      }
      near++;
      final type = _objectType(object);
      final templates = (args['templates'] as Map?)?.cast<String, dynamic>();
      final rawTemplate = _objectTemplate(type, templates);
      final idPrefix = _objectTemplateIdPrefix(rawTemplate, prefix);
      final id = '$idPrefix${object.id}';
      if (game.entities.containsKey(id)) {
        skippedExisting++;
        continue;
      }
      final spawnKey = '$mapId/$layer/${object.id}';
      if (game.consumedTiledObjectKeys.contains(spawnKey)) {
        skippedConsumed++;
        continue;
      }
      var spec = _objectSpecFromTemplate(map, object, type, rawTemplate);
      if (spec == null) {
        skippedNoSpec++;
        continue;
      }
      spec.remove('id_prefix');
      _attachTiledObjectState(
        spec,
        spawnKey: spawnKey,
        layer: layer,
        objectId: object.id,
        despawnDistance: despawnDistance,
        despawnReference: referenceId,
      );
      var spawned = game.spawnEntity(id, spec);
      if (!spawned) {
        spec = _objectSpriteSpec(map, object, type);
        if (spec != null) {
          _attachTiledObjectState(
            spec,
            spawnKey: spawnKey,
            layer: layer,
            objectId: object.id,
            despawnDistance: despawnDistance,
            despawnReference: referenceId,
          );
          spawned = game.spawnEntity(id, spec);
        }
      }
      if (spawned) {
        count++;
        if (debugSpawn && spawnedSamples.length < 6) {
          final entity = game.entities[id];
          if (entity is PixelEntity) {
            final asset = entity is SpriteEntity ? entity.asset : '';
            spawnedSamples.add(
              '$id@${entity.x.toStringAsFixed(1)},'
              '${entity.y.toStringAsFixed(1)} '
              '${entity.w.toStringAsFixed(1)}x${entity.h.toStringAsFixed(1)}'
              '${asset.isEmpty ? '' : ' asset=$asset'}',
            );
          } else {
            spawnedSamples.add('$id kind=${spec?['kind']}');
          }
        }
      } else {
        failed++;
      }
    }
    if (despawnDistance != null && reference is PixelEntity) {
      final ids = game.entities.entries
          .where((entry) {
            final entity = entry.value;
            return entity is PixelEntity &&
                entity.state['tiledLayer'] == layer &&
                (entity.x - reference.x).abs() > despawnDistance;
          })
          .map((entry) => entry.key)
          .toList(growable: false);
      for (final id in ids) {
        game.despawnEntity(id, consumeTiledObject: false);
      }
    }
    if (debugSpawn) {
      final refInfo = reference is PixelEntity
          ? '${reference.x.toStringAsFixed(1)},${reference.y.toStringAsFixed(1)}'
          : 'none';
      debugPrint(
        '[tiled.spawn_objects] map=$mapId layer=$layer seen=$seen near=$near '
        'spawned=$count existing=$skippedExisting consumed=$skippedConsumed '
        'noSpec=$skippedNoSpec failed=$failed reference=$referenceId '
        'ref=$refInfo proximity=$proximity despawn=$despawnDistance'
        '${spawnedSamples.isEmpty ? '' : ' samples=${spawnedSamples.join(' | ')}'}',
      );
    }
    return count;
  }

  static void _attachTiledObjectState(
    Map<String, dynamic> spec, {
    required String spawnKey,
    required String layer,
    required int objectId,
    double? despawnDistance,
    String? despawnReference,
  }) {
    final state = (spec['state'] as Map?)?.cast<String, dynamic>() ?? {};
    state['tiledSpawnKey'] = spawnKey;
    state['tiledLayer'] = layer;
    state['tiledObjectId'] = objectId;
    if (despawnDistance != null) {
      state['despawnDistance'] = despawnDistance;
      state['despawnReference'] = despawnReference;
    }
    spec['state'] = state;
  }

  static bool _spawnAnimationEffect(
    JsonFlameGame game,
    Map<String, dynamic> args,
  ) {
    final id =
        args['id']?.toString() ??
        'effect_${DateTime.now().microsecondsSinceEpoch}';
    final asset = args['asset']?.toString();
    if (asset == null || asset.isEmpty) return false;
    final atEntity = game.entities[args['at']?.toString()];
    final pos = args['position'];
    double x = 0, y = 0;
    if (atEntity is PixelEntity) {
      x = atEntity.x + atEntity.w / 2;
      y = atEntity.y + atEntity.h / 2;
    } else if (pos is List && pos.length >= 2) {
      x = (pos[0] as num).toDouble();
      y = (pos[1] as num).toDouble();
    }
    final size = (args['size'] as num?)?.toDouble() ?? 64;
    return game.spawnEntity(id, {
      'kind': 'animated_sprite',
      'priority': (args['priority'] as num?)?.toInt() ?? 45,
      'asset': asset,
      'position': [x - size / 2, y - size / 2],
      'size': [size, size],
      'frame_size': [
        (args['frame_w'] as num?)?.toDouble() ?? size,
        (args['frame_h'] as num?)?.toDouble() ?? size,
      ],
      'frames': (args['frames'] as num?)?.toInt() ?? 1,
      'frames_per_row': (args['frames_per_row'] as num?)?.toInt() ?? 0,
      'step_time': (args['step_time'] as num?)?.toDouble() ?? 0.042,
      'loop': false,
      'state': {'removeOnFinish': true},
      'render': args['render'] ?? const {'shape': 'rect', 'color': '#FFFFFF00'},
    });
  }

  static Map<String, dynamic>? _objectSpecFromTemplate(
    TiledMapEntity map,
    TiledObject object,
    String type,
    dynamic rawTemplate,
  ) {
    if (rawTemplate is Map) {
      final context = _objectTemplateContext(map, object, type);
      final resolved = _resolveObjectTemplate(rawTemplate, context);
      if (resolved is Map) {
        final spec = resolved.cast<String, dynamic>();
        _applyObjectSpecDefaults(map, object, spec);
        return spec;
      }
      return null;
    }
    return _objectSpriteSpec(map, object, type);
  }

  static void _applyObjectSpecDefaults(
    TiledMapEntity map,
    TiledObject object,
    Map<String, dynamic> spec,
  ) {
    final tile = map.tileWidth * map.scale;
    final width = object.width > 0 ? object.width : tile;
    final height = object.height > 0 ? object.height : width;
    final pos = spec['position'];
    if (pos is! List ||
        pos.length < 2 ||
        !_isNumericLike(pos[0]) ||
        !_isNumericLike(pos[1])) {
      spec['position'] = [object.x, object.y];
    }
    final size = spec['size'];
    if (size is! List ||
        size.length < 2 ||
        !_isNumericLike(size[0]) ||
        !_isNumericLike(size[1])) {
      spec['size'] = [width, height];
    }

    final kind = spec['kind']?.toString();
    if (kind == 'sprite') {
      final sprite = map.spriteForGid(object.gid);
      if (sprite != null) {
        final asset = spec['asset']?.toString() ?? '';
        if (asset.isEmpty || asset.contains('{{')) {
          spec['asset'] = sprite.asset;
        }
        final src = spec['src'];
        if (src is! List ||
            src.length < 4 ||
            src.any((value) => !_isNumericLike(value))) {
          spec['src'] = [sprite.srcX, sprite.srcY, sprite.srcW, sprite.srcH];
        }
      }
    }
  }

  static bool _isNumericLike(dynamic value) {
    if (value is num) return true;
    if (value is String) return double.tryParse(value.trim()) != null;
    return false;
  }

  static dynamic _objectTemplate(String type, Map<String, dynamic>? templates) {
    return templates?[type] ?? templates?['default'] ?? templates?['*'];
  }

  static String _objectTemplateIdPrefix(dynamic rawTemplate, String fallback) {
    if (rawTemplate is Map) {
      final raw = rawTemplate['id_prefix'];
      if (raw is String && raw.isNotEmpty && !raw.contains('{{')) return raw;
    }
    return fallback;
  }

  static String _objectType(TiledObject object) {
    return object.properties['Type']?.toString() ??
        object.type.ifEmpty('default');
  }

  static Map<String, dynamic> _objectTemplateContext(
    TiledMapEntity map,
    TiledObject object,
    String type,
  ) {
    final tile = map.tileWidth * map.scale;
    final size = object.width > 0 ? object.width : tile;
    final hitbox = tile * 0.5;
    final fly =
        object.properties['Fly'] == true ||
        object.properties['Fly']?.toString() == 'true';
    final sprite = map.spriteForGid(object.gid);
    return {
      'tile': tile,
      'hitbox': hitbox,
      'object': {
        'id': object.id,
        'name': object.name,
        'type': type,
        'x': object.x,
        'y': object.y,
        'yPlusHitbox': object.y + hitbox,
        'w': object.width,
        'h': object.height,
        'width': object.width,
        'height': object.height,
        'size': size,
        'gid': object.gid,
        'fly': fly,
        'properties': object.properties,
        'sprite': sprite == null
            ? null
            : {
                'asset': sprite.asset,
                'src': [sprite.srcX, sprite.srcY, sprite.srcW, sprite.srcH],
                'srcX': sprite.srcX,
                'srcY': sprite.srcY,
                'srcW': sprite.srcW,
                'srcH': sprite.srcH,
              },
      },
    };
  }

  static dynamic _resolveObjectTemplate(
    dynamic node,
    Map<String, dynamic> context,
  ) {
    if (node is String) return _resolveObjectTemplateString(node, context);
    if (node is List) {
      return node
          .map((value) => _resolveObjectTemplate(value, context))
          .toList();
    }
    if (node is Map) {
      return node.map(
        (key, value) =>
            MapEntry(key.toString(), _resolveObjectTemplate(value, context)),
      );
    }
    return node;
  }

  static dynamic _resolveObjectTemplateString(
    String text,
    Map<String, dynamic> context,
  ) {
    final fullMatch = RegExp(r'^\s*\{\{\s*(.+?)\s*\}\}\s*$').firstMatch(text);
    if (fullMatch != null) {
      return _readTemplatePath(context, fullMatch.group(1)!.trim());
    }
    if (!text.contains('{{')) return text;
    return text.replaceAllMapped(RegExp(r'\{\{\s*(.+?)\s*\}\}'), (match) {
      final value = _readTemplatePath(context, match.group(1)!.trim());
      return value?.toString() ?? '';
    });
  }

  static dynamic _readTemplatePath(Map<String, dynamic> context, String path) {
    dynamic current = context;
    for (final part in path.split('.')) {
      if (current is Map) {
        current = current[part];
      } else {
        return null;
      }
    }
    return current;
  }

  static Map<String, dynamic>? _objectSpriteSpec(
    TiledMapEntity map,
    TiledObject object,
    String type,
  ) {
    final sprite = map.spriteForGid(object.gid);
    if (sprite == null) return null;
    return {
      'kind': 'sprite',
      'priority': 20,
      'asset': sprite.asset,
      'src': [sprite.srcX, sprite.srcY, sprite.srcW, sprite.srcH],
      'position': [object.x, object.y],
      'size': [object.width, object.height],
      'state': {'objectId': object.id, 'objectType': type},
    };
  }

  static void _moveAndCollideSwept(
    PixelEntity player,
    TiledMapEntity map,
    double dx,
    double dy, {
    Set<String>? oneWayTypes,
    Set<String>? oneWayTilesets,
  }) {
    final tile = max(8.0, min(map.tileWidth, map.tileHeight) * map.scale);
    final maxStep = tile * 0.45;
    final steps = max(1, (max(dx.abs(), dy.abs()) / maxStep).ceil());
    final stepX = dx / steps;
    final stepY = dy / steps;
    for (var i = 0; i < steps; i++) {
      _moveAndCollideX(
        player,
        map,
        stepX,
        oneWayTypes: oneWayTypes,
        oneWayTilesets: oneWayTilesets,
      );
      _moveAndCollideY(
        player,
        map,
        stepY,
        oneWayTypes: oneWayTypes,
        oneWayTilesets: oneWayTilesets,
      );
      if (_isBelowMap(player, map)) break;
    }
  }

  static bool _isBelowMap(PixelEntity player, TiledMapEntity map) {
    final margin = max(player.h, map.tileHeight * map.scale);
    return player.y > map.heightPx + margin;
  }

  static void _moveAndCollideX(
    PixelEntity player,
    TiledMapEntity map,
    double dx, {
    Set<String>? oneWayTypes,
    Set<String>? oneWayTilesets,
  }) {
    if (dx == 0) return;
    player.x += dx;
    final rect = Rect.fromLTWH(player.x, player.y, player.w, player.h);
    for (final collision in map.collisionRectsIn(rect).where((c) => c.solid)) {
      if (_isOneWayPlatform(
        collision,
        oneWayTypes: oneWayTypes,
        oneWayTilesets: oneWayTilesets,
      )) {
        continue;
      }
      if (_isSlope(collision) && player.vy >= 0) continue;
      final solid = collision.rect;
      if (!solid.overlaps(
        Rect.fromLTWH(player.x, player.y, player.w, player.h),
      )) {
        continue;
      }
      if (dx > 0) {
        player.x = solid.left - player.w;
      } else {
        player.x = solid.right;
      }
      player.vx = 0;
    }
  }

  static void _moveAndCollideY(
    PixelEntity player,
    TiledMapEntity map,
    double dy, {
    Set<String>? oneWayTypes,
    Set<String>? oneWayTilesets,
  }) {
    player.state['onGround'] = false;
    if (dy == 0) return;
    player.y += dy;
    var rect = Rect.fromLTWH(player.x, player.y, player.w, player.h);
    for (final collision in map.collisionRectsIn(rect).where((c) => c.solid)) {
      if (dy < 0 &&
          _isOneWayPlatform(
            collision,
            oneWayTypes: oneWayTypes,
            oneWayTilesets: oneWayTilesets,
          )) {
        continue;
      }
      final solid = collision.rect;
      rect = Rect.fromLTWH(player.x, player.y, player.w, player.h);
      if (!solid.overlaps(rect)) continue;
      if (dy > 0) {
        final slopeTop = _slopeTopAt(collision, rect, map.scale);
        player.y = slopeTop - player.h;
        player.state['onGround'] = true;
        player.state['doubleJumpUsed'] = false;
      } else {
        player.y = solid.bottom;
      }
      player.vy = 0;
    }
  }

  static double _slopeTopAt(
    TiledTileCollision collision,
    Rect actor,
    double scale,
  ) {
    if (!_isSlope(collision)) return collision.rect.top;
    final leftTop = (collision.properties['LeftTop'] as num?)?.toDouble();
    final rightTop = (collision.properties['RightTop'] as num?)?.toDouble();
    if (leftTop == null || rightTop == null) return collision.rect.top;

    final left = leftTop * scale;
    final right = rightTop * scale;
    if (left < right) {
      final delta = right - left;
      final fromLeft = (actor.right - collision.rect.left)
          .clamp(0, collision.rect.width)
          .toDouble();
      final ratio = fromLeft / collision.rect.width;
      return (collision.rect.bottom - left) - (delta * ratio);
    }
    if (left > right) {
      final delta = left - right;
      final fromRight = (actor.left - collision.rect.left)
          .clamp(0, collision.rect.width)
          .toDouble();
      final ratio = 1 - (fromRight / collision.rect.width);
      return (collision.rect.bottom - right) - (delta * ratio);
    }
    return collision.rect.top;
  }

  static bool _isSlope(TiledTileCollision collision) =>
      collision.type.toLowerCase() == 'slope';

  static bool _isOneWayPlatform(
    TiledTileCollision collision, {
    Set<String>? oneWayTypes,
    Set<String>? oneWayTilesets,
  }) {
    final type = collision.type.toLowerCase();
    final tileset = collision.tileset.toLowerCase();
    if (oneWayTypes != null || oneWayTilesets != null) {
      return (oneWayTypes?.contains(type) ?? false) ||
          (oneWayTilesets?.contains(tileset) ?? false);
    }
    return type == 'platform';
  }

  static Set<String>? _readStringSet(dynamic raw) {
    if (raw == null) return null;
    if (raw is String) return {raw.toLowerCase()};
    if (raw is List) {
      return raw.map((e) => e.toString().toLowerCase()).toSet();
    }
    return null;
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class _SlideResult {
  final List<int> line;
  final int score;
  final bool moved;
  _SlideResult(this.line, this.score, this.moved);
}
