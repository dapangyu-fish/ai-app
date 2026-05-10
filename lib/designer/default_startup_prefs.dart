// 默认启动 App 配置
//
// 用户可以选一个 App 作为启动直加载目标——市场 App 或本地 App。
// 设了之后冷启动从 MyApp 首页 → 直接进那个 App。
// 没设 = 默认行为（MyApp 首页）。
//
// 数据落到 SharedPreferences；为了简单 + 易升级，每个字段单独 key
// 而不是 JSON blob。

import 'package:shared_preferences/shared_preferences.dart';

enum DefaultStartupKind {
  none,
  market,
  local;

  String get value => switch (this) {
        DefaultStartupKind.none => 'none',
        DefaultStartupKind.market => 'market',
        DefaultStartupKind.local => 'local',
      };

  static DefaultStartupKind parse(String? raw) {
    return switch (raw) {
      'market' => DefaultStartupKind.market,
      'local' => DefaultStartupKind.local,
      _ => DefaultStartupKind.none,
    };
  }
}

class DefaultStartupConfig {
  final DefaultStartupKind kind;

  /// market 时：包名（registry name）
  final String? marketName;

  /// market 时：版本号（用于 ^X.Y.Z 解析）
  final String? marketVersion;

  /// market 时：用户友好显示名（设置页 subtitle 用），可选
  final String? marketDisplayName;

  /// local 时：SavedApp.fileName（AppStorage 主键）
  final String? localFileName;

  /// local 时：用户友好显示名（设置页 subtitle 用），可选
  final String? localDisplayName;

  const DefaultStartupConfig({
    required this.kind,
    this.marketName,
    this.marketVersion,
    this.marketDisplayName,
    this.localFileName,
    this.localDisplayName,
  });

  const DefaultStartupConfig.none() : this(kind: DefaultStartupKind.none);

  bool get hasTarget => kind != DefaultStartupKind.none;

  /// 用于设置页 subtitle 显示当前选了啥
  String displaySummary({required String noneLabel}) {
    return switch (kind) {
      DefaultStartupKind.none => noneLabel,
      DefaultStartupKind.market => marketDisplayName ?? marketName ?? '?',
      DefaultStartupKind.local => localDisplayName ?? localFileName ?? '?',
    };
  }
}

class DefaultStartupPrefs {
  static const _kKind = 'default_startup_kind';
  static const _kMarketName = 'default_startup_market_name';
  static const _kMarketVersion = 'default_startup_market_version';
  static const _kMarketDisplayName = 'default_startup_market_display_name';
  static const _kLocalFileName = 'default_startup_local_file_name';
  static const _kLocalDisplayName = 'default_startup_local_display_name';

  static Future<DefaultStartupConfig> read() async {
    final p = await SharedPreferences.getInstance();
    final kind = DefaultStartupKind.parse(p.getString(_kKind));
    return DefaultStartupConfig(
      kind: kind,
      marketName: p.getString(_kMarketName),
      marketVersion: p.getString(_kMarketVersion),
      marketDisplayName: p.getString(_kMarketDisplayName),
      localFileName: p.getString(_kLocalFileName),
      localDisplayName: p.getString(_kLocalDisplayName),
    );
  }

  static Future<void> writeNone() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kKind);
    await p.remove(_kMarketName);
    await p.remove(_kMarketVersion);
    await p.remove(_kMarketDisplayName);
    await p.remove(_kLocalFileName);
    await p.remove(_kLocalDisplayName);
  }

  static Future<void> writeMarket({
    required String name,
    required String version,
    String? displayName,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kKind, DefaultStartupKind.market.value);
    await p.setString(_kMarketName, name);
    await p.setString(_kMarketVersion, version);
    if (displayName != null) {
      await p.setString(_kMarketDisplayName, displayName);
    } else {
      await p.remove(_kMarketDisplayName);
    }
    await p.remove(_kLocalFileName);
    await p.remove(_kLocalDisplayName);
  }

  static Future<void> writeLocal({
    required String fileName,
    String? displayName,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kKind, DefaultStartupKind.local.value);
    await p.setString(_kLocalFileName, fileName);
    if (displayName != null) {
      await p.setString(_kLocalDisplayName, displayName);
    } else {
      await p.remove(_kLocalDisplayName);
    }
    await p.remove(_kMarketName);
    await p.remove(_kMarketVersion);
    await p.remove(_kMarketDisplayName);
  }
}
