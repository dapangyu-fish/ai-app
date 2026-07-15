import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'environment.dart';

/// 服务环境管理。
///
/// - 内建一个 `production` 环境，所有 URL 字段为 null（表示走 AppConfig 的生产默认）
/// - 用户可创建任意多个自定义环境，**字段留空即回退生产默认**
/// - active 选择持久化到 SharedPreferences，app 重启保留
/// - 切换 active 通过 `notifyListeners` 触发 UI 更新；具体的 logout / 清缓存
///   流程由调用方负责
class EnvironmentService extends ChangeNotifier {
  EnvironmentService._();
  static final EnvironmentService instance = EnvironmentService._();

  static const String productionId = 'production';
  static const String demoDeId = 'demo-de';
  static const String _envsKey = 'environments_v1';
  static const String _activeKey = 'active_environment_id';

  static final Environment _productionEnv = Environment(
    id: productionId,
    name: '生产',
    isBuiltin: true,
    createdAtMillis: 0,
  );

  /// 预置的 demo-de 集群环境（普通可选环境，与 demo 模式无关；内建 → 不可编辑/删除、
  /// 不写入用户自定义列表）。默认 active 仍是生产，用户可在环境页手动切到这个。
  static final Environment _demoDeEnv = Environment(
    id: demoDeId,
    name: 'MyApp myapp-demo-de.dapangyu.work',
    backendUrl: 'https://myapp-demo-de-backend.dapangyu.work',
    supabaseUrl: 'https://myapp-demo-de-auth.dapangyu.work',
    minioUrl: 'https://myapp-demo-de-oss-endpoint.dapangyu.work',
    registryUrl: 'https://myapp-demo-de-registry.dapangyu.work',
    imApiUrl: 'https://myapp-demo-de-im.dapangyu.work',
    imWsUrl: 'wss://myapp-demo-de-im.dapangyu.work/ws',
    configCenterUrl: 'https://myapp-demo-de-config-center.dapangyu.work',
    isBuiltin: true,
    createdAtMillis: 0,
  );

  List<Environment> _envs = [_productionEnv, _demoDeEnv];
  String _activeId = productionId;
  bool _loaded = false;

  bool get isLoaded => _loaded;
  Environment get active =>
      _envs.firstWhere((e) => e.id == _activeId, orElse: () => _productionEnv);
  List<Environment> get all => List.unmodifiable(_envs);
  bool get isProductionActive => _activeId == productionId;

  /// app 启动时调一次。失败 fail-open 退到生产环境。
  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_envsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = json.decode(raw);
        if (decoded is List) {
          final loaded = <Environment>[];
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              try {
                final env = Environment.fromJson(item);
                if (!env.isBuiltin) loaded.add(env);
              } catch (e) {
                debugPrint('[EnvironmentService] 解析单条失败 (忽略): $e');
              }
            }
          }
          _envs = [_productionEnv, _demoDeEnv, ...loaded];
        }
      }
      final savedActive = prefs.getString(_activeKey);
      if (savedActive != null && _envs.any((e) => e.id == savedActive)) {
        _activeId = savedActive;
      }
    } catch (e) {
      debugPrint('[EnvironmentService] load 失败 (回退生产): $e');
      _envs = [_productionEnv, _demoDeEnv];
      _activeId = productionId;
    } finally {
      _loaded = true;
    }
  }

  /// 切换 active 环境。切换前调用方应弹确认框 + 执行 logout/清缓存。
  ///
  /// 这里**总是** _persistAll() 而不是只写 active key —— wipe 流程把 prefs 都清了
  /// 之后调这个方法，要把环境列表一并写回来。
  Future<void> activate(String id) async {
    if (!_envs.any((e) => e.id == id)) {
      debugPrint('[EnvironmentService] activate: id $id 不存在，忽略');
      return;
    }
    _activeId = id;
    await _persistAll();
    notifyListeners();
  }

  /// 新增 / 更新（按 id 判断）。`isBuiltin` 永远会被改回 false（保护生产）。
  Future<void> save(Environment env) async {
    if (env.id == productionId) {
      debugPrint('[EnvironmentService] save: 拒绝覆盖生产环境');
      return;
    }
    final clean = env.copyWith();  // 不带 isBuiltin 改写参数 → 用户传进来的肯定是 false
    final idx = _envs.indexWhere((e) => e.id == clean.id);
    if (idx >= 0) {
      _envs[idx] = clean;
    } else {
      _envs.add(clean);
    }
    await _persistAll();
    notifyListeners();
  }

  /// 删除自定义环境。若删的是当前 active，自动切回生产。内建环境（生产 / demo-de）不可删。
  Future<bool> delete(String id) async {
    if (id == productionId || id == demoDeId) return false;
    final removed = _envs.where((e) => e.id != id).toList();
    if (removed.length == _envs.length) return false;
    _envs = removed;
    if (_activeId == id) {
      _activeId = productionId;
    }
    await _persistAll();
    notifyListeners();
    return true;
  }

  Future<void> _persistAll() async {
    final prefs = await SharedPreferences.getInstance();
    final customs = _envs.where((e) => !e.isBuiltin).map((e) => e.toJson()).toList();
    await prefs.setString(_envsKey, json.encode(customs));
    await prefs.setString(_activeKey, _activeId);
  }

  /// 给 wipeAllLocalAccountData 用：prefs.clear() 之后把内存里的环境写回，
  /// 否则换号确认那一路会把环境一起冲掉
  Future<void> persistCurrent() async {
    if (!_loaded) return;
    await _persistAll();
  }
}
