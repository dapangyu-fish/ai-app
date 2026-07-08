// 依赖加载器
// 负责：下载依赖 JSON、校验版本、检测循环依赖、注册到命名空间
import 'package:flutter/material.dart';
import 'semver.dart';
import 'cache_manager.dart';
import '../config/app_config.dart';

/// Registry 配置 —— 单 source，跟着 [AppConfig.registryUrl] 走（受环境切换控制）
class RegistryConfig {
  static String get registryUrl => AppConfig.registryUrl;
}

/// 已加载的模块信息
class LoadedModule {
  final String name;
  final SemVer version;
  final String type; // app | library | widget
  final List<String> exports;
  final Map<String, dynamic> config; // 完整 JSON 配置
  final Map<String, dynamic> functions;
  final Map<String, dynamic> variables;
  final List<dynamic> screens;
  final Map<String, dynamic> templates;

  LoadedModule({
    required this.name,
    required this.version,
    required this.type,
    required this.exports,
    required this.config,
    required this.functions,
    required this.variables,
    required this.screens,
    required this.templates,
  });
}

/// 依赖声明
class DependencySpec {
  final String name;
  final String? url; // 可选，如果为空则通过 registry 解析
  final VersionConstraint constraint;
  final String resourceType;
  final bool lazy;

  DependencySpec({
    required this.name,
    this.url,
    required this.constraint,
    this.resourceType = 'library',
    this.lazy = false,
  });

  factory DependencySpec.fromJson(String name, dynamic json) {
    // 新格式：简化版本约束字符串
    // "common-ui": "^1.0.0"
    if (json is String) {
      return DependencySpec(
        name: name,
        url: null,
        constraint: VersionConstraint.parse(json),
        resourceType: 'library',
        lazy: false,
      );
    }

    // 旧格式：对象格式
    // "common-ui": { "url": "...", "version": "^1.0.0" }
    if (json is Map<String, dynamic>) {
      return DependencySpec(
        name: name,
        url: json['url']?.toString(),
        constraint: VersionConstraint.parse(json['version']?.toString() ?? '*'),
        resourceType: _normalizeResourceType(json['type']?.toString()),
        lazy: json['lazy'] == true,
      );
    }

    // 默认
    return DependencySpec(
      name: name,
      url: null,
      constraint: VersionConstraint.parse('*'),
      resourceType: 'library',
      lazy: false,
    );
  }

  static String _normalizeResourceType(String? value) {
    final normalized = (value ?? '').trim().toLowerCase();
    if (normalized == 'app') return 'app';
    return 'library';
  }
}

class DependencyLoader {
  /// 已加载的模块缓存（按 name 缓存，避免重复加载）
  final Map<String, LoadedModule> _loadedModules = {};

  /// 当前加载路径（用于检测循环依赖）
  final Set<String> _loadingStack = {};

  /// 获取已加载的模块
  Map<String, LoadedModule> get modules => Map.unmodifiable(_loadedModules);

  /// 清除缓存
  void clear() {
    _loadedModules.clear();
    _loadingStack.clear();
  }

  /// 嵌套 APP 用：保存当前已加载模块（浅拷贝，LoadedModule 本身不可变就够用）。
  Map<String, LoadedModule> snapshot() =>
      Map<String, LoadedModule>.from(_loadedModules);

  /// 嵌套 APP 用：从 [snapshot] 还原已加载模块。
  void restoreFromSnapshot(Map<String, LoadedModule> snapshot) {
    _loadedModules
      ..clear()
      ..addAll(snapshot);
    _loadingStack.clear();
  }

  /// 解析并加载所有依赖
  /// Native framework capabilities declared via `dependencies` (so an app opts
  /// in and the validator accepts the `@cap.*` calls) but provided by the client
  /// itself — not fetched from the Registry. E.g. `compute` = the T7 kernel.
  static const _nativeCapabilities = {'compute'};

  Future<void> loadDependencies(Map<String, dynamic>? deps) async {
    if (deps == null || deps.isEmpty) return;

    final specs = <DependencySpec>[];
    for (final entry in deps.entries) {
      if (_nativeCapabilities.contains(entry.key)) continue; // provided natively
      specs.add(DependencySpec.fromJson(entry.key, entry.value));
    }

    // 并发加载所有依赖
    await Future.wait(
      specs.where((spec) => !spec.lazy).map((spec) => _loadDependency(spec)),
    );
  }

  /// 加载单个依赖
  Future<void> _loadDependency(DependencySpec spec) async {
    // 已加载，校验版本
    if (_loadedModules.containsKey(spec.name)) {
      final existing = _loadedModules[spec.name]!;
      if (!spec.constraint.satisfiedBy(existing.version)) {
        debugPrint(
          '[JSON DSL] 版本冲突: ${spec.name} '
          '已加载 ${existing.version}, 需要 ${spec.constraint}',
        );
      }
      return;
    }

    // 循环依赖检测
    if (_loadingStack.contains(spec.name)) {
      debugPrint(
        '[JSON DSL] 检测到循环依赖: ${_loadingStack.join(" → ")} → ${spec.name}',
      );
      return;
    }

    _loadingStack.add(spec.name);

    try {
      // 通过 CacheManager 获取资源（自带本地缓存 + 后台热更新）
      final config = await CacheManager.instance.getResource(
        spec.name,
        spec.constraint,
        type: spec.resourceType,
      );

      if (config == null) {
        debugPrint('[JSON DSL] 加载依赖失败或无法解析: ${spec.name}');
        return;
      }

      // 解析模块信息
      final meta = config['meta'] as Map<String, dynamic>? ?? {};
      final moduleVersion = SemVer.parse(
        meta['version']?.toString() ?? '0.0.0',
      );

      // 版本约束校验
      if (!spec.constraint.satisfiedBy(moduleVersion)) {
        debugPrint(
          '[JSON DSL] 版本不满足: ${spec.name} '
          'v$moduleVersion 不满足 ${spec.constraint}',
        );
        return;
      }

      final global = config['global'] as Map<String, dynamic>? ?? {};
      final exportsList =
          (meta['exports'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];

      final module = LoadedModule(
        name: spec.name,
        version: moduleVersion,
        type: meta['type']?.toString() ?? 'library',
        exports: exportsList,
        config: config,
        functions: global['functions'] as Map<String, dynamic>? ?? {},
        variables: global['variables'] as Map<String, dynamic>? ?? {},
        screens:
            (config['ui'] as Map<String, dynamic>?)?['screens']
                as List<dynamic>? ??
            [],
        templates:
            (config['ui'] as Map<String, dynamic>?)?['templates']
                as Map<String, dynamic>? ??
            {},
      );

      _loadedModules[spec.name] = module;
      debugPrint(
        '[JSON DSL] 依赖加载成功: ${spec.name} v$moduleVersion '
        '(${module.type}, exports: ${exportsList.join(", ")})',
      );

      // 递归加载子依赖
      final subDeps = config['dependencies'] as Map<String, dynamic>?;
      if (subDeps != null && subDeps.isNotEmpty) {
        await loadDependencies(subDeps);
      }
    } catch (e) {
      debugPrint('[JSON DSL] 加载依赖异常: ${spec.name} - $e');
    } finally {
      _loadingStack.remove(spec.name);
    }
  }

  /// 查找依赖中的函数
  Map<String, dynamic>? findFunction(String depName, String funcName) {
    final module = _loadedModules[depName];
    if (module == null) return null;

    // 检查 exports（如果声明了 exports，只暴露列出的函数）
    if (module.exports.isNotEmpty && !module.exports.contains(funcName)) {
      debugPrint('[JSON DSL] 函数 $funcName 未在 $depName 的 exports 中');
      return null;
    }

    return module.functions[funcName] as Map<String, dynamic>?;
  }

  /// 查找依赖中的 screen
  Map<String, dynamic>? findScreen(String depName, String screenId) {
    final module = _loadedModules[depName];
    if (module == null) return null;

    if (module.exports.isNotEmpty && !module.exports.contains(screenId)) {
      debugPrint('[JSON DSL] Screen $screenId 未在 $depName 的 exports 中');
      return null;
    }

    for (final screen in module.screens) {
      if (screen is Map<String, dynamic> && screen['id'] == screenId) {
        return screen;
      }
    }
    return null;
  }

  /// 查找依赖中的 widget template
  Map<String, dynamic>? findTemplate(String depName, String widgetName) {
    final module = _loadedModules[depName];
    if (module == null) return null;

    if (module.exports.isNotEmpty && !module.exports.contains(widgetName)) {
      debugPrint('[JSON DSL] Widget $widgetName 未在 $depName 的 exports 中');
      return null;
    }

    return module.templates[widgetName] as Map<String, dynamic>?;
  }

  /// 查找依赖中的变量（只读）
  dynamic findVariable(String depName, String varPath) {
    final module = _loadedModules[depName];
    if (module == null) return null;

    final keys = varPath.split('.');
    dynamic current = module.variables;
    for (final key in keys) {
      if (current is Map<String, dynamic> && current.containsKey(key)) {
        current = current[key];
      } else {
        return null;
      }
    }
    return current;
  }
}
