import 'dart:convert';

import 'package:flutter/services.dart';

import 'asset_cache.dart';

class JsonAppAssetManager {
  JsonAppAssetManager({
    required this.appId,
    required this.appName,
    required this.appVersion,
  });

  factory JsonAppAssetManager.fromConfig(Map<String, dynamic> config) {
    final meta = config['meta'] as Map<String, dynamic>? ?? const {};
    final name = meta['name']?.toString() ?? 'json-app';
    final version = meta['version']?.toString() ?? '0.0.0';
    final appId = config['appid']?.toString() ?? name;
    return JsonAppAssetManager(
      appId: appId,
      appName: name,
      appVersion: version,
    );
  }

  final String appId;
  final String appName;
  final String appVersion;

  /// Stable per-app namespace.
  ///
  /// Do not include JSON app version here. Asset URLs should be versioned by the
  /// publisher, so keeping the namespace stable lets app updates reuse unchanged
  /// asset files instead of downloading them again for every JSON release.
  String get namespace => appId;

  String resolve(String path, {String? baseUrl, String? relativeTo}) {
    final uri = Uri.tryParse(path);
    if (uri != null && uri.hasScheme) return path;
    if (relativeTo != null && relativeTo.isNotEmpty) {
      return Uri.parse(relativeTo).resolve(path).toString();
    }
    if (baseUrl != null && baseUrl.isNotEmpty) {
      return Uri.parse(baseUrl).resolve(path).toString();
    }
    return path;
  }

  Future<Uint8List> loadBytes(String path) async {
    final uri = Uri.tryParse(path);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return (await AssetCache.instance.getBytes(
        path,
        namespace: namespace,
      )).bytes;
    }
    final data = await rootBundle.load(path);
    return data.buffer.asUint8List();
  }

  Future<String> loadText(String path) async {
    final bytes = await loadBytes(path);
    return utf8.decode(bytes);
  }

  Future<void> clearCache() => AssetCache.instance.clearNamespace(namespace);
}
