// JsonFlameGame —— 把 JSON spec 烧成一个可跑的 FlameGame。
//
// 跑起来后职责：
// 1. 维护 world / entities / vars / score / game_over 状态
// 2. update(dt): 推 entity 自动行为 → 跑 frame.logic → 跑 tick(s).logic
// 3. render():   背景 → 网格线 → entities → 顶部分数 → game_over 蒙层
// 4. 输入：tap / pan 按 JSON 注册的 input.tap / input.swipe action 跑
// 5. emit 事件给外层 widget（onScoreChanged / onGameOver）让 JSON-APP 接

import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import 'game_entity.dart';
import 'game_logic.dart';
import 'tiled_map_entity.dart';
import 'platformer_physics_backend.dart';
import 'game_world.dart';
import '../i18n/framework_strings.dart';
import '../json_ui/asset_manager.dart';

/// 事件回调签名（跟 A 模式一致，外层 widget 把事件桥到 JSON-DSL action）
typedef GameEventCallback =
    void Function(String eventName, Map<String, dynamic> data);

/// tick 循环
class _TickLoop {
  /// interval 可能是 "{{ vars.tick_interval }}"，每次重新求值
  final dynamic intervalSpec;
  final List<dynamic> logic;
  double accumulator = 0;

  _TickLoop({required this.intervalSpec, required this.logic});
}

/// JsonFlameGame 不直接 mixin Flame 的 TapDetector / PanDetector ——
/// 那俩在不同 Flame 版本 API 不稳定（1.37 重构）。改成由外层 widget
/// 包 GestureDetector，调下面的 [handleTap] / [handleSwipe]。
class JsonFlameGame extends FlameGame {
  /// 整份 game spec（type=flame_game 节点的全部内容）
  final Map<String, dynamic> spec;

  /// 外部回调（emit 给 JSON-APP）
  final GameEventCallback? onEvent;
  final JsonAppAssetManager assetManager;

  // ---- 运行时状态 ----
  /// 我们的世界定义（命名 gameWorld 避免跟 FlameGame.world 冲突 —— 后者
  /// 是 camera scene root 的 World 组件，不是我们要的坐标系抽象）
  late final GameWorld gameWorld;
  final Map<String, GameEntity> entities = {};
  final Map<String, dynamic> vars = {};

  int score = 0;
  int bestScore = 0;
  bool isGameOver = false;
  final Set<String> consumedTiledObjectKeys = {};

  late final GameLogicEngine logic;
  final Map<String, Future<ui.Image>> _imageCache = {};

  // 输入 / 循环
  List<dynamic>? _tapAction;
  List<dynamic>? _swipeAction;
  List<dynamic>? _panAction;
  List<dynamic>? _pressEndAction;
  List<dynamic>? _frameLogic;

  // swipe 的离散触发阈值（像素）—— JSON 可在 input.swipe_threshold 里覆盖
  double _swipeThreshold = 16;
  final List<_TickLoop> _ticks = [];

  // 内置 overlay 配置
  bool _showScore = true;
  bool _showGameOver = true; // overlay.game_over=false 时关掉 canvas
  bool _showAssetLoading = true;
  // 浮层 + tap/swipe 自动重置，让 JSON-APP 用
  // common-ui dialog 接管结算页
  // 默认值在构造函数里走 T.current（非 const，所以不能放 field 初始化）
  String _gameOverTitle = '';
  String _gameOverHint = '';
  String _assetLoadingText = 'Loading assets...';
  bool _initialAssetLoadingComplete = false;
  String? _cameraFollow;
  String? _cameraMap;
  double _cameraX = 0;
  double _cameraY = 0;
  double _cameraOffsetX = 0;
  double _cameraOffsetY = 0;
  double _cameraDeadzoneY = 0;
  double _cameraSmoothY = 1;
  double? _viewportWidth;
  double? _viewportHeight;
  String _viewportFit = 'contain';
  double _viewportScale = 1;
  double _viewportDx = 0;
  double _viewportDy = 0;
  PlatformerPhysicsConfig _platformerPhysics = const PlatformerPhysicsConfig(
    backend: PlatformerPhysicsBackend.aabb,
    fallback: PlatformerPhysicsBackend.aabb,
  );

  JsonFlameGame({
    required this.spec,
    required this.assetManager,
    this.onEvent,
  }) {
    // ⚠️ 必须在构造函数里同步完成所有 spec 解析。
    //
    // 原因：Flame 的 onGameResize 可能在 onLoad（async）之前被调，
    // 那时 late field 没初始化 → LateInitializationError。
    // 反正 spec 解析全是同步的，挪到构造函数里更稳。
    _gameOverTitle = T.current.gameOver;
    _gameOverHint = T.current.gameRestartHint;
    gameWorld = GameWorld.fromJson(spec['world'] as Map<String, dynamic>?);
    logic = GameLogicEngine(this);
    _setupFromSpec();
  }

  bool _ready = false;

  // ---------- 生命周期 ----------
  // 所有 spec 解析在构造函数里做完了，onLoad 留空。Entities 在第一次
  // onGameResize 拿到有效 size 时才铺（scroll_list 等依赖画布尺寸）。

  @override
  Future<void> onLoad() async {}

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    _updateViewportTransform(size.x, size.y);
    gameWorld.resize(_worldWidthForSize(size.x), _worldHeightForSize(size.y));
    // 第一次拿到有效画布尺寸时才铺 entities（scroll_list 等依赖 size）
    if (!_ready && size.x > 0 && size.y > 0) {
      _ready = true;
      _resetGameState();
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!_ready) return;
    if (isGameOver) return;

    // 1. entity 自动行为
    for (final e in entities.values) {
      e.update(dt, gameWorld);
    }
    entities.removeWhere((_, entity) => entity.expired);

    // 2. frame logic
    if (_frameLogic != null) {
      // 传 dt 进 event 作用域，逻辑里需要 FPS-independent 物理时可以用
      // {{ event.dt }} 乘速度 / 加速度
      logic.runLogic(_frameLogic!, {'dt': dt});
      if (isGameOver) return;
    }

    // 3. tick loops
    for (final t in _ticks) {
      t.accumulator += dt;
      // 每次取 interval（让 "{{ vars.tick_interval }}" 可动态变化）
      final iv =
          (logic.resolveExpression(t.intervalSpec) as num?)?.toDouble() ?? 0.16;
      while (t.accumulator >= iv && !isGameOver) {
        t.accumulator -= iv;
        logic.runLogic(t.logic);
      }
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    if (!_ready) return;

    // 背景
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.x, size.y),
      Paint()..color = gameWorld.bg,
    );

    canvas.save();
    if (_hasVirtualViewport) {
      canvas.translate(_viewportDx, _viewportDy);
      canvas.scale(_viewportScale, _viewportScale);
      canvas.clipRect(Rect.fromLTWH(0, 0, gameWorld.width, gameWorld.height));
    }

    // 网格线（grid 模式 + 配了 grid_lines 才画）
    if (gameWorld.kind == 'grid' && gameWorld.gridLines != null) {
      _drawGridLines(canvas);
    }

    final assetsLoading = _assetsLoading;
    if (!assetsLoading) _initialAssetLoadingComplete = true;
    if (_showAssetLoading && assetsLoading) {
      canvas.restore();
      _drawAssetLoadingOverlay(canvas);
      return;
    }

    // entities
    _updateCamera();
    gameWorld.cameraX = _cameraX;
    gameWorld.cameraY = _cameraY;
    canvas.save();
    canvas.translate(-_cameraX, -_cameraY);
    final renderList = entities.values.toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    for (final e in renderList) {
      e.render(canvas, gameWorld);
    }
    canvas.restore();

    canvas.restore();

    // 内置 overlay
    if (_showScore) _drawScoreOverlay(canvas);
    if (isGameOver && _showGameOver) _drawGameOverOverlay(canvas);
  }

  // ---------- 输入（由外层 widget 的 GestureDetector 调进来） ----------

  /// 外层 GestureDetector.onTapDown 转过来
  void handleTap(double x, double y) {
    if (!_ready) return;
    if (_showAssetLoading && _assetsLoading) return;
    final point = _toWorldPoint(x, y);
    if (isGameOver) {
      // 关掉内置浮层 = JSON-APP 自己接管结算页，tap 不再自动重置
      if (!_showGameOver) return;
      resetGame();
      return;
    }
    if (_tapAction != null) {
      logic.runLogic(_tapAction!, {'x': point.dx, 'y': point.dy});
    }
  }

  /// 离散 swipe：一次手势结束时被外层调一次（accumulated dx/dy）
  void handleSwipe(double dx, double dy) {
    if (!_ready) return;
    if (isGameOver) {
      if (!_showGameOver) return;
      // 滑动也能重开
      resetGame();
      return;
    }
    if (_swipeAction != null) {
      final delta = _toWorldDelta(dx, dy);
      final dir = _swipeDirection(dx, dy);
      if (dir == null) return;
      logic.runLogic(_swipeAction!, {
        'direction': dir,
        'dx': delta.dx,
        'dy': delta.dy,
      });
    }
  }

  /// 连续 pan：每一帧 onPanUpdate 都被调（per-frame delta）
  void handlePan(double dx, double dy) {
    if (!_ready) return;
    if (isGameOver) return;
    if (_panAction != null) {
      final delta = _toWorldDelta(dx, dy);
      logic.runLogic(_panAction!, {'dx': delta.dx, 'dy': delta.dy});
    }
  }

  bool get hasSwipe => _swipeAction != null;
  bool get hasPan => _panAction != null;
  bool get hasPressEnd => _pressEndAction != null;

  /// 按住 - 释放语义。外层 widget 在 onTapDown 记录时刻，onTapUp
  /// 时算出 held_ms 调进来。蓄力游戏（跳一跳 / 弹弓 / 充能技能）用。
  void handlePressEnd(double x, double y, int heldMs) {
    if (!_ready) return;
    if (isGameOver) return;
    if (_pressEndAction != null) {
      final point = _toWorldPoint(x, y);
      logic.runLogic(_pressEndAction!, {
        'x': point.dx,
        'y': point.dy,
        'held_ms': heldMs,
      });
    }
  }

  double get swipeThreshold => _swipeThreshold;

  String? _swipeDirection(double dx, double dy) {
    final adx = dx.abs();
    final ady = dy.abs();
    if (adx < 0.5 && ady < 0.5) return null;
    if (adx > ady) {
      return dx > 0 ? 'right' : 'left';
    } else {
      return dy > 0 ? 'down' : 'up';
    }
  }

  // ---------- 公开 API（GameActions 调） ----------

  void setScore(int v) {
    if (v == score) return;
    score = v;
    if (score > bestScore) bestScore = score;
    onEvent?.call('score_changed', {'score': score, 'best': bestScore});
  }

  void triggerGameOver() {
    if (isGameOver) return;
    isGameOver = true;
    if (score > bestScore) bestScore = score;
    onEvent?.call('game_over', {'score': score, 'best': bestScore});
  }

  void emitEvent(String eventName, Map<String, dynamic> data) {
    if (eventName.isEmpty) return;
    onEvent?.call(eventName, data);
  }

  void resetGame() => _resetGameState();

  /// 动态加 entity（@spawn 用）。spec 跟初始 entities map 里那个 spec 一样：
  /// {kind, position/init/..., size, velocity, render}
  bool spawnEntity(String id, Map<String, dynamic> spec) {
    if (entities.containsKey(id)) return false;
    final state = (spec['state'] as Map?)?.cast<String, dynamic>() ?? {};
    state.putIfAbsent('assetLoadingOverlay', () => false);
    spec['state'] = state;
    final ent = _buildEntity(id, spec);
    if (ent == null) return false;
    entities[id] = ent;
    _prepareEntity(ent);
    return true;
  }

  /// 动态删 entity（@despawn 用）
  bool despawnEntity(String id, {bool consumeTiledObject = true}) {
    final entity = entities[id];
    if (consumeTiledObject && entity is PixelEntity) {
      final key = entity.state['tiledSpawnKey']?.toString();
      if (key != null && key.isNotEmpty) {
        consumedTiledObjectKeys.add(key);
      }
    }
    return entities.remove(id) != null;
  }

  bool setSpriteAnimation(String id, String name) {
    final ent = entities[id];
    if (ent is! AnimatedSpriteEntity) return false;
    final spec = ent.setAnimation(name);
    if (spec == null) return false;
    _prepareEntity(ent);
    return true;
  }

  PlatformerPhysicsConfig get platformerPhysics => _platformerPhysics;

  // ---------- 解析 spec ----------

  void _setupFromSpec() {
    // gameWorld 已在构造函数里 init 了，这里只解析剩下的部分

    // input
    final input = spec['input'] as Map<String, dynamic>?;
    _tapAction = _toLogicList(input?['tap']);
    _swipeAction = _toLogicList(input?['swipe']);
    _panAction = _toLogicList(input?['pan']);
    _pressEndAction = _toLogicList(input?['press_end']);
    final th = (input?['swipe_threshold'] as num?)?.toDouble();
    if (th != null && th > 0) _swipeThreshold = th;

    // frame
    final frame = spec['frame'] as Map<String, dynamic>?;
    _frameLogic = _toLogicList(frame?['logic']);

    // ticks
    _ticks.clear();
    final ticksRaw = spec['tick'];
    if (ticksRaw is Map<String, dynamic>) {
      _ticks.add(
        _TickLoop(
          intervalSpec: ticksRaw['interval'],
          logic: _toLogicList(ticksRaw['logic']) ?? const [],
        ),
      );
    } else if (ticksRaw is List) {
      for (final t in ticksRaw) {
        if (t is Map<String, dynamic>) {
          _ticks.add(
            _TickLoop(
              intervalSpec: t['interval'],
              logic: _toLogicList(t['logic']) ?? const [],
            ),
          );
        }
      }
    }

    // overlay 配置
    final ov = spec['overlay'] as Map<String, dynamic>?;
    if (ov != null) {
      _showScore = ov['score'] != false;
      _showGameOver = ov['game_over'] != false;
      _showAssetLoading = ov['asset_loading'] != false;
      _assetLoadingText =
          ov['asset_loading_text']?.toString() ?? _assetLoadingText;
      _gameOverTitle = ov['game_over_title']?.toString() ?? _gameOverTitle;
      _gameOverHint = ov['game_over_hint']?.toString() ?? _gameOverHint;
    }

    final camera = spec['camera'] as Map<String, dynamic>?;
    _cameraFollow = camera?['follow']?.toString();
    _cameraMap = camera?['map']?.toString();
    _cameraOffsetX = (camera?['offset_x'] as num?)?.toDouble() ?? 0;
    _cameraOffsetY = (camera?['offset_y'] as num?)?.toDouble() ?? 0;
    _cameraDeadzoneY = (camera?['deadzone_y'] as num?)?.toDouble() ?? 0;
    _cameraSmoothY = (camera?['smooth_y'] as num?)?.toDouble() ?? 1;

    _platformerPhysics = PlatformerPhysicsConfig.fromSpec(spec['physics']);

    final viewport = spec['viewport'] as Map<String, dynamic>?;
    _viewportWidth = (viewport?['width'] as num?)?.toDouble();
    _viewportHeight = (viewport?['height'] as num?)?.toDouble();
    _viewportFit = viewport?['fit']?.toString() ?? 'contain';
  }

  List<dynamic>? _toLogicList(dynamic raw) {
    if (raw == null) return null;
    if (raw is List) return raw;
    if (raw is Map) return [raw]; // 单个 action 也接受
    return null;
  }

  void _resetGameState() {
    score = 0;
    isGameOver = false;
    _initialAssetLoadingComplete = false;
    consumedTiledObjectKeys.clear();
    vars.clear();

    // vars 初始值（spec.vars 里 "{{ ... }}" 用外层 game spec 的 best 等求值
    // —— 但此时还没玩家分数，先简单 resolve 成原始值即可）
    final rawVars = (spec['vars'] as Map?)?.cast<String, dynamic>() ?? {};
    rawVars.forEach((k, v) {
      vars[k] = logic.resolveExpression(v);
    });

    // entities
    entities.clear();
    final ents = (spec['entities'] as Map?)?.cast<String, dynamic>() ?? {};
    ents.forEach((id, raw) {
      final ent = _buildEntity(id, raw as Map<String, dynamic>);
      if (ent != null) {
        entities[id] = ent;
        _prepareEntity(ent);
      }
    });

    // 重置 tick 累积器
    for (final t in _ticks) {
      t.accumulator = 0;
    }

    // init.logic：entities 建好后跑一次的初始化（典型用途：开局 spawn 几个 tile）
    final initSpec = spec['init'] as Map<String, dynamic>?;
    final initLogic = initSpec?['logic'];
    if (initLogic is List) {
      logic.runLogic(initLogic);
    }

    onEvent?.call('reset', {'score': 0, 'best': bestScore});
  }

  GameEntity? _buildEntity(String id, Map<String, dynamic> spec) {
    final kind = spec['kind']?.toString() ?? 'cell';
    final renderRaw =
        (spec['render'] as Map?)?.cast<String, dynamic>() ?? const {};
    final render = renderRaw.map((k, v) => MapEntry(k, v));
    final priority = (spec['priority'] as num?)?.toInt() ?? 0;

    switch (kind) {
      case 'cell':
        {
          final initRaw = spec['init'];
          int x = 0, y = 0;
          if (initRaw is List && initRaw.length == 2) {
            x = (initRaw[0] as num).toInt();
            y = (initRaw[1] as num).toInt();
          }
          return CellEntity(
            id: id,
            renderConfig: render,
            priority: priority,
            x: x,
            y: y,
          );
        }
      case 'cell_path':
        {
          final initRaw = spec['init'];
          final cells = <List<int>>[];
          if (initRaw is List) {
            for (final c in initRaw) {
              if (c is List && c.length == 2) {
                cells.add([(c[0] as num).toInt(), (c[1] as num).toInt()]);
              }
            }
          }
          return CellPathEntity(
            id: id,
            renderConfig: render,
            priority: priority,
            cells: cells,
          );
        }
      case 'value_grid':
        {
          final cols = (spec['cols'] as num?)?.toInt() ?? 4;
          final rows = (spec['rows'] as num?)?.toInt() ?? 4;
          final fill = (spec['fill'] as num?)?.toInt() ?? 0; // 默认空 (0)
          final cells = <List<int>>[];
          final initRaw = spec['init'];
          for (int r = 0; r < rows; r++) {
            final row = <int>[];
            for (int c = 0; c < cols; c++) {
              int v = fill;
              if (initRaw is List &&
                  r < initRaw.length &&
                  initRaw[r] is List &&
                  c < (initRaw[r] as List).length) {
                v = ((initRaw[r] as List)[c] as num?)?.toInt() ?? fill;
              }
              row.add(v);
            }
            cells.add(row);
          }
          return ValueGridEntity(
            id: id,
            renderConfig: render,
            priority: priority,
            cols: cols,
            rows: rows,
            cells: cells,
          );
        }
      case 'pixel':
        {
          final pos = spec['position'];
          final size = spec['size'];
          final vel = spec['velocity'];
          double x = 0, y = 0;
          if (pos is List && pos.length >= 2) {
            x = (pos[0] as num).toDouble();
            y = (pos[1] as num).toDouble();
          }
          double w = 20, h = 20;
          if (size is List && size.length >= 2) {
            w = (size[0] as num).toDouble();
            h = (size[1] as num).toDouble();
          }
          double vx = 0, vy = 0;
          if (vel is List && vel.length >= 2) {
            vx = (vel[0] as num).toDouble();
            vy = (vel[1] as num).toDouble();
          }
          return PixelEntity(
            id: id,
            renderConfig: render,
            priority: priority,
            x: x,
            y: y,
            w: w,
            h: h,
            vx: vx,
            vy: vy,
            autoMove: spec['auto_update'] != false,
            state: (spec['state'] as Map?)?.cast<String, dynamic>(),
          );
        }
      case 'sprite':
        {
          final pixel = _readPixelSpec(spec);
          final src = spec['src'];
          double srcX = 0, srcY = 0;
          double? srcW, srcH;
          if (src is List && src.length >= 4) {
            srcX = (src[0] as num).toDouble();
            srcY = (src[1] as num).toDouble();
            srcW = (src[2] as num).toDouble();
            srcH = (src[3] as num).toDouble();
          }
          return SpriteEntity(
            id: id,
            renderConfig: render,
            priority: priority,
            x: pixel.x,
            y: pixel.y,
            w: pixel.w,
            h: pixel.h,
            vx: pixel.vx,
            vy: pixel.vy,
            autoMove: pixel.autoMove,
            state: pixel.state,
            asset:
                spec['asset']?.toString() ?? render['asset']?.toString() ?? '',
            srcX: srcX,
            srcY: srcY,
            srcW: srcW,
            srcH: srcH,
            flipX: spec['flip_x'] == true || render['flip_x'] == true,
          );
        }
      case 'animated_sprite':
        {
          final pixel = _readPixelSpec(spec);
          final frameSize = spec['frame_size'];
          double frameW = (spec['frame_w'] as num?)?.toDouble() ?? 16;
          double frameH = (spec['frame_h'] as num?)?.toDouble() ?? 16;
          if (frameSize is List && frameSize.length >= 2) {
            frameW = (frameSize[0] as num).toDouble();
            frameH = (frameSize[1] as num).toDouble();
          }
          final animations = _readAnimations(spec['animations']);
          final animationName = spec['animation']?.toString();
          final animationSpec = animationName == null
              ? null
              : animations[animationName];
          if (animationSpec != null) {
            frameW = animationSpec.frameW;
            frameH = animationSpec.frameH;
          }
          return AnimatedSpriteEntity(
            id: id,
            renderConfig: render,
            priority: priority,
            x: pixel.x,
            y: pixel.y,
            w: pixel.w,
            h: pixel.h,
            vx: pixel.vx,
            vy: pixel.vy,
            autoMove: pixel.autoMove,
            state: pixel.state,
            asset:
                animationSpec?.asset ??
                spec['asset']?.toString() ??
                render['asset']?.toString() ??
                '',
            frameW: frameW,
            frameH: frameH,
            frames:
                animationSpec?.frames ?? (spec['frames'] as num?)?.toInt() ?? 1,
            framesPerRow:
                animationSpec?.framesPerRow ??
                (spec['frames_per_row'] as num?)?.toInt() ??
                0,
            stepTime:
                animationSpec?.stepTime ??
                (spec['step_time'] as num?)?.toDouble() ??
                0.12,
            loop: animationSpec?.loop ?? spec['loop'] != false,
            animations: animations,
            currentAnimation: animationName,
            flipX: spec['flip_x'] == true || render['flip_x'] == true,
          );
        }
      case 'parallax':
        {
          return ParallaxEntity(
            id: id,
            renderConfig: render,
            priority: priority,
            asset:
                spec['asset']?.toString() ?? render['asset']?.toString() ?? '',
            speedX: (spec['speed_x'] as num?)?.toDouble() ?? 0,
            y: (spec['y'] as num?)?.toDouble() ?? 0,
            height: (spec['height'] as num?)?.toDouble(),
          );
        }
      case 'tiled_map':
        {
          return TiledMapEntity(
            id: id,
            renderConfig: render,
            priority: priority,
            source: spec['source']?.toString() ?? spec['map']?.toString() ?? '',
            baseUrl: spec['base_url']?.toString(),
            scale: (spec['scale'] as num?)?.toDouble() ?? 1,
            includeLayers: _readStringSet(spec['include_layers']),
            excludeLayers: _readStringSet(spec['exclude_layers']) ?? const {},
            solidLayers: _readStringSet(spec['solid_layers']) ?? const {},
            hazardLayers: _readStringSet(spec['hazard_layers']) ?? const {},
            collidable: spec['collidable'] != false,
            assetManager: assetManager,
          );
        }
      case 'scroll_list':
        {
          final scrollDir = spec['direction']?.toString() ?? 'down';
          final speed = (spec['speed'] as num?)?.toDouble() ?? 180;
          final rowSpec =
              (spec['row_spec'] as Map?)?.cast<String, dynamic>() ?? const {};
          final cellsPerRow = (rowSpec['cells'] as num?)?.toInt() ?? 4;
          // 默认行高 = 画布宽度 / 列数（方块），用户也可显式 row_height 覆盖
          final rowHeight =
              (spec['row_height'] as num?)?.toDouble() ??
              (gameWorld.width > 0 ? gameWorld.width / cellsPerRow : 95);
          final safeBottom = (spec['safe_zone_bottom'] as num?)?.toInt() ?? 2;
          // 初始铺一些行
          final rows = <ScrollRow>[];
          final rand = Random();
          if (gameWorld.width > 0 && gameWorld.height > 0) {
            double y = -rowHeight * 5;
            while (y < gameWorld.height + rowHeight) {
              final inSafe = (gameWorld.height - rowHeight * safeBottom) <= y;
              rows.add(
                ScrollRow(
                  y: y,
                  activeIndex: inSafe ? -1 : rand.nextInt(cellsPerRow),
                  cells: cellsPerRow,
                  missedChecked: y >= gameWorld.height - rowHeight,
                ),
              );
              y += rowHeight;
            }
          }
          return ScrollListEntity(
            id: id,
            renderConfig: render,
            priority: priority,
            scrollDirection: scrollDir,
            speed: speed,
            rowHeight: rowHeight,
            rowSpec: rowSpec,
            rows: rows,
            safeZoneBottom: safeBottom,
          );
        }
    }
    return null;
  }

  ({
    double x,
    double y,
    double w,
    double h,
    double vx,
    double vy,
    bool autoMove,
    Map<String, dynamic>? state,
  })
  _readPixelSpec(Map<String, dynamic> spec) {
    final pos = spec['position'];
    final size = spec['size'];
    final vel = spec['velocity'];
    double x = 0, y = 0;
    if (pos is List && pos.length >= 2) {
      x = (pos[0] as num).toDouble();
      y = (pos[1] as num).toDouble();
    }
    double w = 20, h = 20;
    if (size is List && size.length >= 2) {
      w = (size[0] as num).toDouble();
      h = (size[1] as num).toDouble();
    }
    double vx = 0, vy = 0;
    if (vel is List && vel.length >= 2) {
      vx = (vel[0] as num).toDouble();
      vy = (vel[1] as num).toDouble();
    }
    return (
      x: x,
      y: y,
      w: w,
      h: h,
      vx: vx,
      vy: vy,
      autoMove: spec['auto_update'] != false,
      state: (spec['state'] as Map?)?.cast<String, dynamic>(),
    );
  }

  Map<String, SpriteAnimationSpec> _readAnimations(dynamic raw) {
    if (raw is! Map) return const {};
    final out = <String, SpriteAnimationSpec>{};
    raw.forEach((key, value) {
      if (value is! Map) return;
      final spec = value.cast<String, dynamic>();
      final frameSize = spec['frame_size'];
      double frameW = (spec['frame_w'] as num?)?.toDouble() ?? 64;
      double frameH = (spec['frame_h'] as num?)?.toDouble() ?? 64;
      if (frameSize is List && frameSize.length >= 2) {
        frameW = (frameSize[0] as num).toDouble();
        frameH = (frameSize[1] as num).toDouble();
      }
      out[key.toString()] = SpriteAnimationSpec(
        asset: spec['asset']?.toString() ?? '',
        frameW: frameW,
        frameH: frameH,
        frames: (spec['frames'] as num?)?.toInt() ?? 1,
        framesPerRow: (spec['frames_per_row'] as num?)?.toInt() ?? 0,
        stepTime: (spec['step_time'] as num?)?.toDouble() ?? 0.12,
        loop: spec['loop'] != false,
      );
    });
    return out;
  }

  Set<String>? _readStringSet(dynamic raw) {
    if (raw is String && raw.isNotEmpty) return {raw};
    if (raw is! List) return null;
    final out = raw
        .map((value) => value?.toString())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet();
    return out.isEmpty ? null : out;
  }

  void _prepareEntity(GameEntity entity) {
    if (entity is TiledMapEntity) {
      entity.load();
      return;
    }
    if (entity is! ImageBackedEntity) return;
    final imageEntity = entity as ImageBackedEntity;
    final asset = imageEntity.asset;
    if (asset.isEmpty) return;
    _loadImage(asset)
        .then((image) {
          if (!entities.containsKey(entity.id)) return;
          imageEntity.image = image;
        })
        .catchError((_) {
          // Asset 加载失败时保留 fallback 渲染，不让游戏循环崩。
        });
  }

  void _updateCamera() {
    final follow = _cameraFollow;
    if (follow == null || follow.isEmpty) {
      _cameraX = 0;
      _cameraY = 0;
      return;
    }
    final target = entities[follow];
    if (target is! PixelEntity) return;
    var x = target.x + target.w / 2 - gameWorld.width / 2 + _cameraOffsetX;
    var y = target.y + target.h / 2 - gameWorld.height / 2 + _cameraOffsetY;
    if (_cameraDeadzoneY > 0 && (y - _cameraY).abs() < _cameraDeadzoneY) {
      y = _cameraY;
    } else if (_cameraSmoothY > 0 && _cameraSmoothY < 1) {
      y = _cameraY + (y - _cameraY) * _cameraSmoothY;
    }
    final mapId = _cameraMap;
    if (mapId != null) {
      final map = entities[mapId];
      if (map is TiledMapEntity && map.loaded) {
        x = x.clamp(0, max(0, map.widthPx - gameWorld.width));
        y = y.clamp(0, max(0, map.heightPx - gameWorld.height));
      }
    }
    _cameraX = x;
    _cameraY = y;
  }

  bool get _hasVirtualViewport =>
      (_viewportWidth ?? 0) > 0 && (_viewportHeight ?? 0) > 0;

  double _worldWidthForSize(double width) =>
      _hasVirtualViewport ? _viewportWidth! : width;

  double _worldHeightForSize(double height) =>
      _hasVirtualViewport ? _viewportHeight! : height;

  void _updateViewportTransform(double width, double height) {
    if (!_hasVirtualViewport || width <= 0 || height <= 0) {
      _viewportScale = 1;
      _viewportDx = 0;
      _viewportDy = 0;
      return;
    }
    final scaleX = width / _viewportWidth!;
    final scaleY = height / _viewportHeight!;
    _viewportScale = _viewportFit == 'cover'
        ? max(scaleX, scaleY)
        : min(scaleX, scaleY);
    _viewportDx = (width - _viewportWidth! * _viewportScale) / 2;
    _viewportDy = (height - _viewportHeight! * _viewportScale) / 2;
  }

  Offset _toWorldPoint(double x, double y) {
    if (!_hasVirtualViewport || _viewportScale <= 0) return Offset(x, y);
    return Offset(
      (x - _viewportDx) / _viewportScale,
      (y - _viewportDy) / _viewportScale,
    );
  }

  Offset _toWorldDelta(double dx, double dy) {
    if (!_hasVirtualViewport || _viewportScale <= 0) return Offset(dx, dy);
    return Offset(dx / _viewportScale, dy / _viewportScale);
  }

  Future<ui.Image> _loadImage(String asset) {
    return _imageCache.putIfAbsent(asset, () async {
      final bytes = await _loadImageBytes(asset);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      return frame.image;
    });
  }

  Future<Uint8List> _loadImageBytes(String asset) async {
    return assetManager.loadBytes(asset);
  }

  bool get _assetsLoading {
    var imageLoading = false;
    for (final entity in entities.values) {
      if (entity is TiledMapEntity && !entity.loaded && entity.error == null) {
        return true;
      }
      if (entity is SpriteEntity &&
          entity.asset.isNotEmpty &&
          entity.image == null) {
        if (_blocksAssetLoadingOverlay(entity)) imageLoading = true;
      }
      if (entity is ParallaxEntity &&
          entity.asset.isNotEmpty &&
          entity.image == null) {
        if (!_initialAssetLoadingComplete) imageLoading = true;
      }
    }
    return imageLoading && !_initialAssetLoadingComplete;
  }

  bool _blocksAssetLoadingOverlay(GameEntity entity) {
    if (_initialAssetLoadingComplete) return false;
    if (entity is PixelEntity && entity.state['assetLoadingOverlay'] == false) {
      return false;
    }
    return true;
  }

  // ---------- 内置 overlay ----------

  void _drawGridLines(Canvas canvas) {
    final p = Paint()
      ..color = gameWorld.gridLines!
      ..strokeWidth = 0.5;
    for (int i = 1; i < gameWorld.cols; i++) {
      canvas.drawLine(
        Offset(i * gameWorld.cellW, 0),
        Offset(i * gameWorld.cellW, size.y),
        p,
      );
    }
    for (int j = 1; j < gameWorld.rows; j++) {
      canvas.drawLine(
        Offset(0, j * gameWorld.cellH),
        Offset(size.x, j * gameWorld.cellH),
        p,
      );
    }
  }

  void _drawAssetLoadingOverlay(Canvas canvas) {
    final rect = Rect.fromLTWH(0, 0, size.x, size.y);
    canvas.drawRect(rect, Paint()..color = gameWorld.bg);
    final textPainter = TextPainter(
      text: TextSpan(
        text: _assetLoadingText,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: size.x * 0.8);
    textPainter.paint(
      canvas,
      Offset(
        (size.x - textPainter.width) / 2,
        (size.y - textPainter.height) / 2,
      ),
    );
  }

  void _drawScoreOverlay(Canvas canvas) {
    _drawText(
      canvas,
      '$score',
      36,
      const Color(0xCCFFFFFF),
      Offset(size.x / 2, 18),
      centered: true,
    );
    if (bestScore > 0) {
      _drawText(
        canvas,
        T.fmt(T.current.gameBestScoreWith, {'score': bestScore}),
        14,
        const Color(0x66FFFFFF),
        Offset(size.x / 2, 52),
        centered: true,
      );
    }
  }

  void _drawGameOverOverlay(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.x, size.y),
      Paint()..color = const Color(0x88000000),
    );
    final boxRect = Rect.fromLTWH(size.x / 2 - 130, size.y / 2 - 100, 260, 200);
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, const Radius.circular(16)),
      Paint()..color = const Color(0xDD333333),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(boxRect, const Radius.circular(16)),
      Paint()
        ..color = const Color(0x44FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    _drawText(
      canvas,
      _gameOverTitle,
      40,
      const Color(0xFFFF5555),
      Offset(size.x / 2, size.y / 2 - 60),
      centered: true,
    );
    _drawText(
      canvas,
      T.fmt(T.current.gameScoreWith, {'score': score}),
      26,
      Colors.white70,
      Offset(size.x / 2, size.y / 2 - 10),
      centered: true,
    );
    if (bestScore > 0) {
      _drawText(
        canvas,
        T.fmt(T.current.gameBestScoreWith, {'score': bestScore}),
        16,
        const Color(0x88FFFFFF),
        Offset(size.x / 2, size.y / 2 + 25),
        centered: true,
      );
    }
    _drawText(
      canvas,
      _gameOverHint,
      16,
      const Color(0x66FFFFFF),
      Offset(size.x / 2, size.y / 2 + 60),
      centered: true,
    );
  }

  void _drawText(
    Canvas canvas,
    String text,
    double fontSize,
    Color color,
    Offset pos, {
    bool centered = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final offset = centered ? pos - Offset(tp.width / 2, tp.height / 2) : pos;
    tp.paint(canvas, offset);
  }
}
