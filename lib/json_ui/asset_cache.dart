import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../platform/native_fs.dart';

class CachedAsset {
  const CachedAsset({
    required this.url,
    required this.bytes,
    required this.fromCache,
    this.path,
  });

  final String url;
  final Uint8List bytes;
  final bool fromCache;
  final String? path;
}

/// URL -> bytes cache for JSON app assets.
///
/// Native platforms persist under application support directory. Web falls
/// back to a process memory cache because the NativeFs facade intentionally has
/// no browser storage implementation yet.
class AssetCache {
  static final AssetCache instance = AssetCache._();
  AssetCache._();

  final http.Client _http = http.Client();
  final Map<String, Uint8List> _memory = <String, Uint8List>{};
  final Map<String, Future<CachedAsset>> _inFlight = {};
  String? _rootDir;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    final supportDir = await NativeFs.appSupportDir();
    if (supportDir != null && supportDir.isNotEmpty) {
      _rootDir = '$supportDir/json_app_assets';
      await NativeFs.ensureDir(_rootDir!);
    }
    _initialized = true;
  }

  Future<CachedAsset> getBytes(
    String url, {
    required String namespace,
    Map<String, String>? headers,
  }) async {
    await init();
    final key = '$namespace\n$url';
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final future = _getBytes(url, namespace: namespace, headers: headers);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<CachedAsset> _getBytes(
    String url, {
    required String namespace,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.tryParse(url);
    final isRemote =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    if (!isRemote) {
      throw ArgumentError('AssetCache only handles remote URLs: $url');
    }

    final memKey = '$namespace\n$url';
    final memoryHit = _memory[memKey];
    if (memoryHit != null) {
      // 内存命中也带上磁盘路径（若文件确实在）：音频等需要「本地文件」而非
      // 字节的消费方靠 path 零延迟播放；此前这里恒为 null，同会话内第二次
      // configure（如游戏重开）就永远拿不到本地路径了。
      final memPath = _filePath(namespace, url);
      final onDisk = memPath != null && await NativeFs.existsAbs(memPath);
      return CachedAsset(
        url: url,
        bytes: memoryHit,
        fromCache: true,
        path: onDisk ? memPath : null,
      );
    }

    final absPath = _filePath(namespace, url);
    if (absPath != null) {
      final cached = await NativeFs.readBytesAbs(absPath);
      if (cached != null) {
        _remember(memKey, cached);
        debugPrint('[AssetCache] hit $namespace $url');
        return CachedAsset(
          url: url,
          bytes: cached,
          fromCache: true,
          path: absPath,
        );
      }
    }

    debugPrint('[AssetCache] download $namespace $url');
    final resp = await _http.get(uri, headers: headers);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('Failed to load $url (${resp.statusCode})');
    }
    final bytes = Uint8List.fromList(resp.bodyBytes);
    _remember(memKey, bytes);
    var wrote = false;
    if (absPath != null) {
      wrote = await NativeFs.writeBytesAbs(absPath, bytes);
    }
    // path 只在文件真正落盘后返回 —— 消费方（音频本地播放）拿到 path 即可信。
    return CachedAsset(
      url: url,
      bytes: bytes,
      fromCache: false,
      path: wrote ? absPath : null,
    );
  }

  Future<void> clearNamespace(String namespace) async {
    await init();
    _memory.removeWhere((key, _) => key.startsWith('$namespace\n'));
    final root = _rootDir;
    if (root == null) return;
    await NativeFs.deleteDirAbs('$root/${_safeSegment(namespace)}');
  }

  String? _filePath(String namespace, String url) {
    final root = _rootDir;
    if (root == null) return null;
    final digest = sha256.convert(utf8.encode(url)).toString();
    final ext = _extension(url);
    return '$root/${_safeSegment(namespace)}/files/$digest$ext';
  }

  String _extension(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final idx = path.lastIndexOf('.');
    if (idx < 0 || idx == path.length - 1) return '.bin';
    final raw = path.substring(idx);
    if (raw.length > 12 || raw.contains('/')) return '.bin';
    return raw.toLowerCase();
  }

  String _safeSegment(String value) {
    final digest = sha256
        .convert(utf8.encode(value))
        .toString()
        .substring(0, 16);
    final clean = value
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .trim();
    final prefix = clean.isEmpty ? 'app' : clean;
    return '${prefix.substring(0, prefix.length > 48 ? 48 : prefix.length)}_$digest';
  }

  void _remember(String key, Uint8List bytes) {
    _memory[key] = bytes;
    if (_memory.length <= 256) return;
    _memory.remove(_memory.keys.first);
  }
}
