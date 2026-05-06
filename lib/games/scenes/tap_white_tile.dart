// "别踩白块儿" 节奏游戏（接入自 game.dart）
//
// 跟 game.dart 比，**只**做了三类改动：
// 1. 构造函数收 params（columns / initialSpeed / speedAccel / maxSpeed / initialBest）
// 2. 加 `onEvent` 回调，分数变化和游戏结束时通知外层（JSON-DSL 用）
// 3. 删掉 main()/MyApp 那种 standalone 启动壳，只保留 FlameGame 子类
//
// 渲染、循环、tap 处理逻辑跟原版完全一致。

import 'dart:math';

import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import '../game_registry.dart' show TappableScene;

/// 事件回调签名：(eventName, payload)
/// - eventName: 'scoreChanged' / 'gameOver'
/// - payload: 跟 JSON `{{ event.xxx }}` 一一对应的字段
typedef GameEventCallback = void Function(
    String eventName, Map<String, dynamic> data);

class TapWhiteTileScene extends FlameGame implements TappableScene {
  /// 列数（默认 4）
  final int columnCount;

  /// 初始下落速度（px/s）
  final double initialSpeed;

  /// 速度加速度（px/s²，每秒增加多少）
  final double speedAccel;

  /// 最高速度（px/s）
  final double maxSpeed;

  /// 历史最佳分数（外部传入，比如从 SharedPreferences）
  final int initialBest;

  /// 事件回调（可空；不传就当作"没人在听"）
  final GameEventCallback? onEvent;

  TapWhiteTileScene({
    this.columnCount = 4,
    this.initialSpeed = 180.0,
    this.speedAccel = 3.5,
    this.maxSpeed = 600.0,
    this.initialBest = 0,
    this.onEvent,
  });

  final List<_TileRow> _rows = [];
  final _random = Random();

  double _scrollSpeed = 0;
  int _score = 0;
  late int _highScore;
  bool _isGameOver = false;

  late double _tileWidth;
  late double _tileHeight;
  late double _deathLineY;

  @override
  void onLoad() {
    _highScore = initialBest;
    _calcLayout();
    _resetGame();
  }

  @override
  void onGameResize(Vector2 size) {
    super.onGameResize(size);
    _calcLayout();
  }

  void _calcLayout() {
    _tileWidth = size.x / columnCount;
    _tileHeight = _tileWidth;
    _deathLineY = size.y - _tileHeight;
  }

  void _resetGame() {
    _rows.clear();
    _scrollSpeed = initialSpeed;
    _score = 0;
    _isGameOver = false;
    _emitScore();

    // 底部 2 行是 safe zone 全白
    final safeZoneTop = _deathLineY - _tileHeight * 2;

    double y = -_tileHeight * 5;
    while (y < size.y + _tileHeight) {
      final inSafeZone = y >= safeZoneTop;
      final row = _TileRow(
        inSafeZone ? -1 : _random.nextInt(columnCount),
        y,
      );
      if (y >= _deathLineY) {
        row.missedChecked = true;
      }
      _rows.add(row);
      y += _tileHeight;
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (_isGameOver) return;

    final safeDt = dt.clamp(0, 0.05);
    final moveAmount = _scrollSpeed * safeDt;

    for (final row in _rows) {
      row.y += moveAmount;
    }

    for (final row in _rows) {
      if (row.hasBlackTile &&
          !row.tapped &&
          !row.missedChecked &&
          row.y >= _deathLineY) {
        row.missedChecked = true;
        _triggerGameOver();
        return;
      }
    }

    _rows.removeWhere((r) => r.y > size.y + _tileHeight * 2);

    while (_rows.isEmpty || _rows.first.y > -_tileHeight * 4) {
      final newY = _rows.isEmpty ? -_tileHeight : _rows.first.y - _tileHeight;
      _rows.insert(0, _TileRow(_random.nextInt(columnCount), newY));
    }

    if (_scrollSpeed < maxSpeed) {
      _scrollSpeed += speedAccel * safeDt;
    }
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.x, size.y),
      Paint()..color = const Color(0xFF2B2B2B),
    );

    for (final row in _rows) {
      if (row.y + _tileHeight < -_tileHeight ||
          row.y > size.y + _tileHeight) {
        continue;
      }

      for (int col = 0; col < columnCount; col++) {
        final isBlack = col == row.blackIndex;
        final rect = Rect.fromLTWH(
          col * _tileWidth + 2,
          row.y + 2,
          _tileWidth - 4,
          _tileHeight - 4,
        );

        Color color;
        if (row.tapped && isBlack) {
          color = const Color(0xFF4A4A4A);
        } else if (isBlack) {
          color = const Color(0xFF1A1A1A);
        } else {
          color = const Color(0xFFF0F0F0);
        }

        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(6)),
          Paint()..color = color,
        );
      }
    }

    final deathPaint = Paint()
      ..color = const Color(0xFFFF3333)
      ..strokeWidth = 3.0;
    canvas.drawLine(
      Offset(0, _deathLineY),
      Offset(size.x, _deathLineY),
      deathPaint,
    );

    final glowPaint = Paint()
      ..color = const Color(0x44FF0000)
      ..strokeWidth = 8.0;
    canvas.drawLine(
      Offset(0, _deathLineY),
      Offset(size.x, _deathLineY),
      glowPaint,
    );

    final topGradient = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xAA000000), Color(0x00000000)],
      ).createShader(Rect.fromLTWH(0, 0, size.x, 80));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, 80), topGradient);

    _drawText(
      canvas,
      '$_score',
      40,
      Colors.white,
      Offset(size.x / 2, 40),
      centered: true,
    );

    if (_highScore > 0) {
      _drawText(
        canvas,
        '最佳 $_highScore',
        16,
        const Color(0x88FFFFFF),
        Offset(size.x / 2, 65),
        centered: true,
      );
    }

    if (_isGameOver) {
      _drawGameOver(canvas);
    }
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
    final offset =
        centered ? pos - Offset(tp.width / 2, tp.height / 2) : pos;
    tp.paint(canvas, offset);
  }

  void _drawGameOver(Canvas canvas) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.x, size.y),
      Paint()..color = const Color(0x88000000),
    );

    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        size.x / 2 - 130,
        size.y / 2 - 100,
        260,
        200,
      ),
      const Radius.circular(16),
    );
    canvas.drawRRect(r, Paint()..color = const Color(0xDD333333));
    canvas.drawRRect(
      r,
      Paint()
        ..color = const Color(0x44FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    _drawText(
      canvas,
      '游戏结束',
      44,
      const Color(0xFFFF5555),
      Offset(size.x / 2, size.y / 2 - 60),
      centered: true,
    );
    _drawText(
      canvas,
      '得分  $_score',
      28,
      Colors.white70,
      Offset(size.x / 2, size.y / 2 - 10),
      centered: true,
    );
    _drawText(
      canvas,
      '最佳  $_highScore',
      18,
      const Color(0x88FFFFFF),
      Offset(size.x / 2, size.y / 2 + 25),
      centered: true,
    );
    _drawText(
      canvas,
      '点击任意位置重新开始',
      17,
      const Color(0x66FFFFFF),
      Offset(size.x / 2, size.y / 2 + 65),
      centered: true,
    );
  }

  /// 外部 GestureDetector 转过来的点击坐标
  @override
  void handleTap(Offset position) {
    if (_isGameOver) {
      _resetGame();
      return;
    }

    final col = (position.dx / _tileWidth).floor();
    if (col < 0 || col >= columnCount) return;

    for (final row in _rows) {
      if (position.dy >= row.y && position.dy <= row.y + _tileHeight) {
        if (!row.tapped) {
          if (col == row.blackIndex) {
            row.tapped = true;
            _score++;
            _emitScore();
          } else {
            _triggerGameOver();
          }
        }
        break;
      }
    }
  }

  void _triggerGameOver() {
    _isGameOver = true;
    if (_score > _highScore) _highScore = _score;
    onEvent?.call('gameOver', {
      'score': _score,
      'best': _highScore,
    });
  }

  void _emitScore() {
    onEvent?.call('scoreChanged', {'score': _score});
  }
}

/// 一行数据
class _TileRow {
  final int blackIndex; // -1 = safe zone
  double y;
  bool tapped = false;
  bool missedChecked = false;

  bool get hasBlackTile => blackIndex >= 0;

  _TileRow(this.blackIndex, this.y);
}
