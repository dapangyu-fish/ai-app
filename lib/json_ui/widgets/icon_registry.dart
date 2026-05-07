// Material Icons 注册表
// 将字符串名称映射到 Flutter IconData，供 button.icon / input.prefixIcon 等使用
import 'package:flutter/material.dart';

class IconRegistry {
  static final Map<String, IconData> _icons = {
    // 导航
    'home': Icons.home,
    'back': Icons.arrow_back,
    'forward': Icons.arrow_forward,
    'menu': Icons.menu,
    'close': Icons.close,
    'more': Icons.more_vert,
    'more_horiz': Icons.more_horiz,

    // 操作
    'add': Icons.add,
    'remove': Icons.remove,
    'delete': Icons.delete,
    'edit': Icons.edit,
    'save': Icons.save,
    'copy': Icons.copy,
    'paste': Icons.paste,
    'share': Icons.share,
    'send': Icons.send,
    'upload': Icons.upload,
    'download': Icons.download,
    'refresh': Icons.refresh,
    'sync': Icons.sync,
    'undo': Icons.undo,
    'redo': Icons.redo,

    // 文件
    'folder': Icons.folder,
    'file': Icons.insert_drive_file,
    'attachment': Icons.attach_file,
    'image': Icons.image,
    'photo': Icons.photo,
    'camera': Icons.camera_alt,
    'video': Icons.videocam,
    'audio': Icons.audiotrack,

    // 通信
    'email': Icons.email,
    'phone': Icons.phone,
    'chat': Icons.chat,
    'message': Icons.message,
    'notification': Icons.notifications,

    // 用户
    'person': Icons.person,
    'people': Icons.people,
    'account': Icons.account_circle,
    'login': Icons.login,
    'logout': Icons.logout,

    // 状态
    'check': Icons.check,
    'check_circle': Icons.check_circle,
    'error': Icons.error,
    'warning': Icons.warning,
    'info': Icons.info,
    'help': Icons.help,
    'block': Icons.block,

    // 内容
    'search': Icons.search,
    'filter': Icons.filter_list,
    'sort': Icons.sort,
    'star': Icons.star,
    'star_outline': Icons.star_outline,
    'favorite': Icons.favorite,
    'favorite_outline': Icons.favorite_border,
    'bookmark': Icons.bookmark,
    'bookmark_outline': Icons.bookmark_border,
    'tag': Icons.label,
    'link': Icons.link,
    'code': Icons.code,

    // UI
    'settings': Icons.settings,
    'tune': Icons.tune,
    'palette': Icons.palette,
    'dark_mode': Icons.dark_mode,
    'light_mode': Icons.light_mode,
    'visibility': Icons.visibility,
    'visibility_off': Icons.visibility_off,
    'lock': Icons.lock,
    'unlock': Icons.lock_open,
    'key': Icons.vpn_key,

    // 方向
    'up': Icons.arrow_upward,
    'down': Icons.arrow_downward,
    'left': Icons.arrow_back,
    'right': Icons.arrow_forward,
    'expand': Icons.expand_more,
    'collapse': Icons.expand_less,
    'fullscreen': Icons.fullscreen,

    // 游戏 / 历史
    'history': Icons.history,
    'replay': Icons.replay,
    'restart': Icons.restart_alt,
    'pause': Icons.pause,
    'play': Icons.play_arrow,
    'stop': Icons.stop,
    'trophy': Icons.emoji_events,
    'leaderboard': Icons.leaderboard,
    'timeline': Icons.timeline,

    // 其他
    'calendar': Icons.calendar_today,
    'clock': Icons.access_time,
    'location': Icons.location_on,
    'map': Icons.map,
    'globe': Icons.language,
    'wifi': Icons.wifi,
    'bluetooth': Icons.bluetooth,
    'print': Icons.print,
    'qr_code': Icons.qr_code,
    'fingerprint': Icons.fingerprint,
    'emoji': Icons.emoji_emotions,
    'list': Icons.list,
    'grid': Icons.grid_view,
    'dashboard': Icons.dashboard,
    'analytics': Icons.analytics,
    'receipt': Icons.receipt,
    'shopping_cart': Icons.shopping_cart,
    'payment': Icons.payment,
  };

  static IconData? get(String name) => _icons[name];

  /// 列出所有可用图标名（调试用）
  static List<String> get allNames => _icons.keys.toList()..sort();
}
