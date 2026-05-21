import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../platform/native_fs.dart';
import 'http_client.dart';
import 'semver.dart';
import 'dependency_loader.dart' show RegistryConfig;

class CacheManager {
  static final CacheManager instance = CacheManager._();
  CacheManager._();

  final DslHttpClient _httpClient = DslHttpClient();
  
  Map<String, dynamic>? _indexCache;
  bool _initialized = false;
  String? _cacheDir;

  Future<void> init() async {
    if (_initialized) return;
    try {
      final docPath = await NativeFs.appDocDir();
      if (docPath == null) {
        // web / 无文件系统：只用内存索引（永远 cache-miss，不落盘）
        _indexCache = {
          'version': '1.1',
          'updated_at': DateTime.now().toIso8601String(),
          'resources': <String, dynamic>{}
        };
        _initialized = true;
        return;
      }
      _cacheDir = '$docPath/dsl_cache';
      await NativeFs.ensureDir(_cacheDir!);

      final content = await NativeFs.readStringAbs('$_cacheDir/index.json');
      if (content != null) {
        _indexCache = json.decode(content) as Map<String, dynamic>;
      } else {
        _indexCache = {
          'version': '1.1',
          'updated_at': DateTime.now().toIso8601String(),
          'resources': <String, dynamic>{}
        };
      }
      _initialized = true;
    } catch (e) {
      debugPrint('[CacheManager] Init failed: $e');
    }
  }

  /// 切换账号时调用：丢弃内存里的索引，下次访问会重新 init / 拉取。
  /// 注意磁盘上的 dsl_cache 目录由调用方（local_data_wiper）负责删除。
  Future<void> reset() async {
    _initialized = false;
    _indexCache = null;
    _cacheDir = null;
  }

  Future<void> _saveIndex() async {
    if (_cacheDir == null || _indexCache == null) return;
    try {
      _indexCache!['updated_at'] = DateTime.now().toIso8601String();
      await NativeFs.writeStringAbs('$_cacheDir/index.json', json.encode(_indexCache));
    } catch (e) {
      debugPrint('[CacheManager] Failed to save index: $e');
    }
  }

  /// 获取资源（App 或依赖库）。
  /// [name]: 资源名，如 common-ui 或 calculator
  /// [constraint]: 版本约束，如 ^1.0.0
  /// [type]: 资源类型，'app' 或 'library'
  /// 
  /// 流程：
  /// 1. 检查本地是否满足版本约束
  /// 2. 如果满足，立刻返回本地内容，并在后台发起更新检查（Stale-While-Revalidate）
  /// 3. 如果不满足或无本地缓存，阻塞式去远端下载并返回。
  Future<Map<String, dynamic>?> getResource(String name, VersionConstraint constraint, {String type = 'library'}) async {
    await init();
    
    // 1. 检查本地缓存
    final localMatch = _findBestLocalMatch(name, constraint);
    if (localMatch != null) {
      final version = localMatch['version'] as String;
      final filePath = localMatch['file_path'] as String;
      
      try {
        final content = await NativeFs.readStringAbs('$_cacheDir/$filePath');
        if (content != null) {
          final config = json.decode(content) as Map<String, dynamic>;

          debugPrint('[CacheManager] 命中本地缓存: $name@$version (约束: $constraint)');

          // 后台静默更新
          _revalidateResourceAsync(name, constraint, type);

          return config;
        }
      } catch (e) {
        debugPrint('[CacheManager] 读取本地缓存失败: $e');
      }
    }
    
    // 2. 如果没有本地缓存，或者不满足约束，阻塞式下载
    debugPrint('[CacheManager] 未命中缓存或不满足约束，开始下载: $name@$constraint');
    return await _downloadAndCacheResource(name, constraint, type);
  }

  /// 后台异步检查并更新缓存
  Future<void> _revalidateResourceAsync(String name, VersionConstraint constraint, String type) async {
    try {
      // 这里的逻辑就是去查 registry，如果有满足约束的更新版本，就下载并缓存
      await _downloadAndCacheResource(name, constraint, type, background: true);
    } catch (e) {
      debugPrint('[CacheManager] 后台热更新失败: $name - $e');
    }
  }

  Future<Map<String, dynamic>?> _downloadAndCacheResource(String name, VersionConstraint constraint, String type, {bool background = false}) async {
    try {
      final url = '${RegistryConfig.registryUrl}/resolve?name=$name&version=${Uri.encodeComponent(constraint.toString())}';
      final response = await _httpClient.get(url);
      
      if (response['error'] != null || response['data'] == null) {
        if (!background) debugPrint('[CacheManager] Registry 解析失败: ${response['error']}');
        return null;
      }

      Map<String, dynamic> data;
      if (response['data'] is String) {
        data = json.decode(response['data'] as String);
      } else if (response['data'] is Map) {
        data = Map<String, dynamic>.from(response['data'] as Map);
      } else {
        return null;
      }

      final downloadUrl = data['download_url']?.toString();
      final resolvedVersionStr = data['version']?.toString();
      
      if (downloadUrl == null || resolvedVersionStr == null) return null;
      
      // 如果本地已经有这个版本的缓存了，没必要再下
      final localMatch = _findBestLocalMatch(name, VersionConstraint.parse(resolvedVersionStr));
      if (localMatch != null && localMatch['version'] == resolvedVersionStr) {
        if (background) debugPrint('[CacheManager] 后台检查完毕，当前已是最新满足约束的版本: $name@$resolvedVersionStr');
        return null; // 不需要返回 config 给后台更新使用
      }

      if (!background) debugPrint('[CacheManager] 开始下载资源: $name@$resolvedVersionStr');
      final resourceResp = await _httpClient.get(downloadUrl);
      
      if (resourceResp['error'] != null || resourceResp['data'] == null) {
        return null;
      }
      
      Map<String, dynamic> config;
      if (resourceResp['data'] is String) {
        config = json.decode(resourceResp['data'] as String);
      } else {
        config = Map<String, dynamic>.from(resourceResp['data'] as Map);
      }
      
      // 保存到本地
      final relPath = '${type == "app" ? "apps" : "packages"}/$name/$resolvedVersionStr.json';
      await NativeFs.writeStringAbs('$_cacheDir/$relPath', json.encode(config));
      
      // 更新索引
      final resources = _indexCache!['resources'] as Map<String, dynamic>;
      if (!resources.containsKey(name)) {
        resources[name] = {
          'type': type,
          'latest_version': resolvedVersionStr,
          'versions': <String, dynamic>{}
        };
      }
      
      final resNode = resources[name] as Map<String, dynamic>;
      // 简单地把最新的当作 latest
      // （严谨的做法应该比较 semver，这里作为演示简化处理）
      resNode['latest_version'] = resolvedVersionStr;
      
      final versionsNode = resNode['versions'] as Map<String, dynamic>;
      versionsNode[resolvedVersionStr] = {
        'file_path': relPath,
        'download_url': downloadUrl,
        'downloaded_at': DateTime.now().toIso8601String()
      };
      
      await _saveIndex();
      
      if (background) {
        debugPrint('[CacheManager] 后台热更新成功，已缓存: $name@$resolvedVersionStr');
      } else {
        debugPrint('[CacheManager] 资源下载并缓存成功: $name@$resolvedVersionStr');
      }
      
      return config;
    } catch (e) {
      if (!background) debugPrint('[CacheManager] 下载或缓存异常: $e');
      return null;
    }
  }

  /// 查找本地索引中满足约束的最高版本
  Map<String, dynamic>? _findBestLocalMatch(String name, VersionConstraint constraint) {
    if (_indexCache == null) return null;
    final resources = _indexCache!['resources'] as Map<String, dynamic>?;
    if (resources == null) return null;
    
    final resNode = resources[name] as Map<String, dynamic>?;
    if (resNode == null) return null;
    
    final versionsNode = resNode['versions'] as Map<String, dynamic>?;
    if (versionsNode == null || versionsNode.isEmpty) return null;
    
    final matchedVersions = <String>[];
    for (final v in versionsNode.keys) {
      try {
        final semver = SemVer.parse(v);
        if (constraint.satisfiedBy(semver)) {
          matchedVersions.add(v);
        }
      } catch (_) {}
    }
    
    if (matchedVersions.isEmpty) return null;
    
    // 按版本号降序排序
    matchedVersions.sort((a, b) => SemVer.parse(b).compareTo(SemVer.parse(a)));
    
    final bestVersion = matchedVersions.first;
    final versionInfo = Map<String, dynamic>.from(versionsNode[bestVersion] as Map);
    versionInfo['version'] = bestVersion;
    
    return versionInfo;
  }
}
