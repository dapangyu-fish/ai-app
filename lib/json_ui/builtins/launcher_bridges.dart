// Launcher 桥接函数 — 让 JSON-DSL 能调原生服务做"启动器组件库"
// ───────────────────────────────────────────────────────────
// 用户可以用纯 JSON 写自己的 launcher（启动器），通过这些桥接函数访问：
//   - @my_apps_list / _delete / _share —— 本地保存的 JSON-APP 管理
//   - @launch_app —— 从 launcher 内部跳进市场上 / 本地的另一个 JSON-APP
//   - @market_list（后续）—— 从 Registry 拉市场列表
//   - @settings_*（后续）—— 主题/语言/缓存/默认启动 App
//   - @auth_*（后续）—— 当前用户/登出
//
// 调度方式：interpreter.dart 的 _handleCall 默认分支 fall through 到这里；
// 命中返回 (handled: true, value: ...)，未命中返回 (handled: false)，
// interpreter 走原来的"未知内置函数"警告。

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../cache_manager.dart';
import '../interpreter.dart';
import '../semver.dart';
import '../../designer/app_storage.dart';
import '../../i18n/meta_helper.dart';
import '../../main.dart' show JsonDslApp, JsonScreenView;

class LauncherBridges {
  /// interpreter.dart 默认分支兜底用：handled=true 表示已处理，
  /// value 是返回值（可为 null）；handled=false 让 interpreter 输出"未知内置函数"。
  static Future<({bool handled, dynamic value})> tryDispatch(
    String callTarget,
    Map<String, dynamic> resolvedArgs,
    JsonInterpreter interpreter,
  ) async {
    switch (callTarget) {
      case '@my_apps_list':
        return (handled: true, value: await _myAppsList());
      case '@my_apps_delete':
        return (handled: true, value: await _myAppsDelete(resolvedArgs));
      case '@my_apps_share':
        return (handled: true, value: await _myAppsShare(resolvedArgs));
      case '@launch_app':
        return (handled: true, value: await _launchApp(resolvedArgs, interpreter));
      default:
        return (handled: false, value: null);
    }
  }

  // ========== my_apps ==========

  /// 列出本地保存的 JSON-APP，按时间倒序。
  /// 返回字段：fileName / name / displayName / description / savedAt /
  /// version / author / type （都从 meta 里掘出来，方便 JSON 直接渲染卡片）
  static Future<List<Map<String, dynamic>>> _myAppsList() async {
    final apps = await AppStorage.instance.list();
    return apps.map((app) {
      final meta = app.config['meta'] as Map<String, dynamic>? ?? {};
      return {
        'fileName': app.fileName,
        'name': app.name,
        'displayName': resolveDisplayName(meta, fallback: app.name),
        'description': app.description,
        'savedAt': app.savedAt,
        'version': meta['version']?.toString() ?? '',
        'author': meta['author']?.toString() ?? '',
        'type': meta['type']?.toString() ?? 'app',
      };
    }).toList();
  }

  /// @my_apps_delete({fileName})  → bool
  static Future<bool> _myAppsDelete(Map<String, dynamic> args) async {
    final fileName = args['fileName']?.toString();
    if (fileName == null || fileName.isEmpty) {
      debugPrint('[@my_apps_delete] 缺 fileName');
      return false;
    }
    try {
      await AppStorage.instance.delete(fileName);
      return true;
    } catch (e) {
      debugPrint('[@my_apps_delete] 失败: $e');
      return false;
    }
  }

  /// @my_apps_share({fileName})  → bool
  /// 弹系统分享，把 JSON 文件本体作为附件分享出去。
  static Future<bool> _myAppsShare(Map<String, dynamic> args) async {
    final fileName = args['fileName']?.toString();
    if (fileName == null || fileName.isEmpty) {
      debugPrint('[@my_apps_share] 缺 fileName');
      return false;
    }
    try {
      final config = await AppStorage.instance.load(fileName);
      if (config == null) {
        debugPrint('[@my_apps_share] 文件不存在: $fileName');
        return false;
      }
      // 写到临时目录再分享（share_plus 需要文件路径）
      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/$fileName');
      await tempFile.writeAsString(json.encode(config));
      final meta = config['meta'] as Map<String, dynamic>? ?? {};
      final displayName = resolveDisplayName(meta, fallback: fileName);
      final result = await Share.shareXFiles(
        [XFile(tempFile.path, mimeType: 'application/json')],
        subject: displayName,
      );
      return result.status == ShareResultStatus.success;
    } catch (e) {
      debugPrint('[@my_apps_share] 失败: $e');
      return false;
    }
  }

  // ========== launch_app ==========

  /// @launch_app({kind: "local"|"market", fileName?, name?, version?, isStartupRoot?})
  /// 从当前 JSON-APP 启动另一个 JSON-APP（典型：launcher → 用户选的 app）。
  ///
  /// 单 interpreter 架构下嵌套启动靠 [JsonInterpreter.pushState] /
  /// [JsonInterpreter.popState] 状态栈：push 父 → loadConfig 子 → push 路由 →
  /// 路由 pop 时 popState 恢复父。失败时立刻 popState 回滚。
  ///
  /// 返回 bool：true 表示路由已 push（子 app 在转场动画里），false 表示未启动。
  static Future<bool> _launchApp(
    Map<String, dynamic> args,
    JsonInterpreter interpreter,
  ) async {
    final kind = args['kind']?.toString() ?? 'local';
    final isStartupRoot = args['isStartupRoot'] == true;

    Map<String, dynamic>? config;
    String displayName;

    try {
      if (kind == 'market') {
        final name = args['name']?.toString();
        final version = args['version']?.toString();
        if (name == null || name.isEmpty) {
          debugPrint('[@launch_app] kind=market 必须传 name');
          return false;
        }
        // 没传 version → 任意版本（>=0.0.0）；传了 → ^x.y.z 同主版本兼容
        final constraint = version == null || version.isEmpty
            ? VersionConstraint.parse('>=0.0.0')
            : VersionConstraint.parse('^$version');
        config = await CacheManager.instance.getResource(
          name,
          constraint,
          type: 'app',
        );
        if (config == null) {
          debugPrint('[@launch_app] 市场获取失败: $name@$version');
          return false;
        }
        final meta = config['meta'] as Map<String, dynamic>?;
        displayName = resolveDisplayName(meta ?? {'name': name}, fallback: name);
      } else if (kind == 'local') {
        final fileName = args['fileName']?.toString();
        if (fileName == null || fileName.isEmpty) {
          debugPrint('[@launch_app] kind=local 必须传 fileName');
          return false;
        }
        config = await AppStorage.instance.load(fileName);
        if (config == null) {
          debugPrint('[@launch_app] 本地 app 不存在: $fileName');
          return false;
        }
        final meta = config['meta'] as Map<String, dynamic>?;
        displayName = resolveDisplayName(
          meta,
          fallback: meta?['name']?.toString() ?? fileName,
        );
      } else {
        debugPrint('[@launch_app] 未知 kind: $kind');
        return false;
      }
    } catch (e) {
      debugPrint('[@launch_app] 配置获取失败: $e');
      return false;
    }

    // 保父态，开始装子
    interpreter.pushState();
    try {
      interpreter.loadConfig(config);
      await interpreter.executeSteps();
    } catch (e) {
      debugPrint('[@launch_app] 子 app 加载失败: $e');
      interpreter.popState();
      return false;
    }

    final navigator = JsonDslApp.navigatorKey.currentState;
    if (navigator == null) {
      debugPrint('[@launch_app] navigatorKey 不可用，回滚');
      interpreter.popState();
      return false;
    }

    navigator
        .push(
          MaterialPageRoute(
            builder: (_) => JsonScreenView(
              fileName: displayName,
              isStartupRoot: isStartupRoot,
            ),
          ),
        )
        .whenComplete(() {
          // 子 app 路由被 pop（用户返回 / 程序 pop）→ 恢复父态
          interpreter.popState();
        });

    return true;
  }
}
