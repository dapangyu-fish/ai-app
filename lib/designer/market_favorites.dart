// 市场收藏 —— 纯本地（SharedPreferences），不上服务端
// 存 [{name, display_name}] 列表，收藏 tab 直接渲染，点进去再拉详情。

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class MarketFavorites {
  MarketFavorites._();
  static const _key = 'market_favorites_v1';

  /// 返回收藏列表（[{name, display_name}]，新收藏在前）
  static Future<List<Map<String, String>>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = json.decode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => {
                  'name': e['name']?.toString() ?? '',
                  'display_name': e['display_name']?.toString() ?? '',
                })
            .where((e) => e['name']!.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  static Future<bool> isFavorite(String name) async {
    final items = await list();
    return items.any((e) => e['name'] == name);
  }

  /// 切换收藏，返回切换后的状态（true=已收藏）
  static Future<bool> toggle(String name, String displayName) async {
    final prefs = await SharedPreferences.getInstance();
    final items = await list();
    final idx = items.indexWhere((e) => e['name'] == name);
    bool nowFav;
    if (idx >= 0) {
      items.removeAt(idx);
      nowFav = false;
    } else {
      items.insert(0, {'name': name, 'display_name': displayName});
      nowFav = true;
    }
    await prefs.setString(_key, json.encode(items));
    return nowFav;
  }
}
