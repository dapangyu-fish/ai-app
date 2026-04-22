import 'dart:io' show Platform;
import 'package:flutter/services.dart';

/// 管理 Android 系统手势排除区域，防止悬浮球拖拽触发系统返回手势。
class GestureExclusionHelper {
  static const _channel = MethodChannel('com.dapangyu.fish/gesture_exclusion');

  /// 设置手势排除矩形区域（像素坐标）
  static Future<void> setExclusionRect({
    required double left,
    required double top,
    required double width,
    required double height,
    required double devicePixelRatio,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      // 添加额外的 padding 扩大排除区域，确保手指触碰球的边缘也不会触发系统手势
      const padding = 16.0;
      await _channel.invokeMethod('setGestureExclusionRects', {
        'rects': [
          {
            'left': ((left - padding) * devicePixelRatio).round(),
            'top': ((top - padding) * devicePixelRatio).round(),
            'right': ((left + width + padding) * devicePixelRatio).round(),
            'bottom': ((top + height + padding) * devicePixelRatio).round(),
          }
        ],
      });
    } catch (_) {}
  }

  /// 清除所有手势排除区域
  static Future<void> clearExclusionRects() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('clearGestureExclusionRects');
    } catch (_) {}
  }
}
