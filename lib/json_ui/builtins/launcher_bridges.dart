// Launcher 桥接函数 — 让 JSON-DSL 能调原生服务做"启动器组件库"
// ───────────────────────────────────────────────────────────
// 用户可以用纯 JSON 写自己的 launcher（启动器），通过这些桥接函数访问：
//   - @my_apps_list / _delete / _share —— 本地保存的 JSON-APP 管理
//   - @launch_app —— 从 launcher 内部跳进市场上 / 本地 / 依赖中的 JSON-APP
//   - @market_list（后续）—— 从 Registry 拉市场列表
//   - @settings_*（后续）—— 主题/语言/缓存/默认启动 App
//   - @auth_*（后续）—— 当前用户/登出
//
// 调度方式：interpreter.dart 的 _handleCall 默认分支 fall through 到这里；
// 命中返回 (handled: true, value: ...)，未命中返回 (handled: false)，
// interpreter 走原来的"未知内置函数"警告。

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import '../../platform/native_fs.dart';
import '../cache_manager.dart';
import '../dependency_loader.dart';
import '../interpreter.dart';
import '../semver.dart';
import '../../auth/auth_service.dart';
import '../../config/app_config.dart';
import '../../designer/app_storage.dart';
import '../../designer/default_startup_prefs.dart';
import '../../i18n/locale_controller.dart';
import '../../i18n/meta_helper.dart';
import '../../im/im_service.dart';
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
        return (
          handled: true,
          value: await _myAppsList(resolvedArgs, interpreter),
        );
      case '@my_apps_delete':
        return (handled: true, value: await _myAppsDelete(resolvedArgs));
      case '@my_apps_share':
        return (handled: true, value: await _myAppsShare(resolvedArgs));
      case '@launch_app':
        return (
          handled: true,
          value: await _launchApp(resolvedArgs, interpreter),
        );
      case '@market_list':
        return (handled: true, value: await _marketList(resolvedArgs));
      case '@startup_default_get':
        return (handled: true, value: await _startupDefaultGet());
      case '@startup_default_set':
        return (handled: true, value: await _startupDefaultSet(resolvedArgs));
      case '@startup_default_clear':
        return (handled: true, value: await _startupDefaultClear());
      case '@cache_clear':
        return (handled: true, value: await _cacheClear());
      case '@get_framework_locale':
        return (handled: true, value: _getFrameworkLocale());
      case '@set_framework_locale':
        return (
          handled: true,
          value: await _setFrameworkLocale(resolvedArgs, interpreter),
        );
      case '@auth_logout':
        return (handled: true, value: await _authLogout());
      default:
        return (handled: false, value: null);
    }
  }

  // ========== my_apps ==========

  /// 列出本地保存的 JSON-APP，按时间倒序。
  /// 返回字段：fileName / name / displayName / description / savedAt /
  /// version / author / type （都从 meta 里掘出来，方便 JSON 直接渲染卡片）。
  /// 调用方用 action 上的 `assign: "global.xxx"` 把结果写进变量。
  static Future<List<Map<String, dynamic>>> _myAppsList(
    Map<String, dynamic> args,
    JsonInterpreter interpreter,
  ) async {
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
      final tmp = await NativeFs.tempDir();
      if (tmp == null) {
        debugPrint('[@my_apps_share] 当前平台不支持文件分享');
        return false;
      }
      final tempPath = '$tmp/$fileName';
      await NativeFs.writeStringAbs(tempPath, json.encode(config));
      final meta = config['meta'] as Map<String, dynamic>? ?? {};
      final displayName = resolveDisplayName(meta, fallback: fileName);
      final result = await Share.shareXFiles([
        XFile(tempPath, mimeType: 'application/json'),
      ], subject: displayName);
      return result.status == ShareResultStatus.success;
    } catch (e) {
      debugPrint('[@my_apps_share] 失败: $e');
      return false;
    }
  }

  // ========== market ==========

  /// @market_list({type: "app"|"library", search?, page?, perPage?})  → List<Map>
  /// 从 Registry 分页拉市场列表。search 由服务端模糊匹配。
  ///
  /// 返回字段：name / displayName / description / version / author / type
  /// （和 @my_apps_list 同 schema，方便组件库共享 item 模板）
  static Future<List<Map<String, dynamic>>> _marketList(
    Map<String, dynamic> args,
  ) async {
    final type = (args['type']?.toString() ?? 'app').trim();
    final search = args['search']?.toString().trim() ?? '';
    final page = (args['page'] as num?)?.toInt() ?? 1;
    final perPage = (args['perPage'] as num?)?.toInt() ?? 50;
    try {
      final uri = Uri.parse('${AppConfig.registryUrl}/packages').replace(
        queryParameters: {
          'type': type,
          'page': page.toString(),
          'per_page': perPage.toString(),
          if (search.isNotEmpty) 'q': search,
        },
      );
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        debugPrint('[@market_list] HTTP ${resp.statusCode}');
        return const [];
      }
      final body = json.decode(resp.body) as Map<String, dynamic>;
      final packages = (body['packages'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      // 规整字段：保证 displayName 已被 resolveDisplayName 解析、其它键也填齐
      final mapped = packages.map((pkg) {
        final name = pkg['name']?.toString() ?? '';
        return {
          'name': name,
          'displayName': resolveDisplayName(pkg, fallback: name),
          'description': pkg['description']?.toString() ?? '',
          'version': pkg['version']?.toString() ?? '',
          'author': pkg['author']?.toString() ?? '',
          'type': pkg['type']?.toString() ?? type,
        };
      }).toList();
      return mapped;
    } catch (e) {
      debugPrint('[@market_list] 失败: $e');
      return const [];
    }
  }

  // ========== launch_app ==========

  /// @launch_app({kind: "local"|"market"|"dependency", fileName?, name?, version?, isStartupRoot?})
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
          preferLatest: true,
        );
        if (config == null) {
          debugPrint('[@launch_app] 市场获取失败: $name@$version');
          return false;
        }
        final meta = config['meta'] as Map<String, dynamic>?;
        displayName = resolveDisplayName(
          meta ?? {'name': name},
          fallback: name,
        );
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
      } else if (kind == 'dependency') {
        final name = args['name']?.toString();
        if (name == null || name.isEmpty) {
          debugPrint('[@launch_app] kind=dependency 必须传 name');
          return false;
        }
        final module = interpreter.depLoader.modules[name];
        if (module != null) {
          config = module.config;
        } else {
          final deps = interpreter.rawConfig?['dependencies'];
          final rawSpec = deps is Map<String, dynamic> ? deps[name] : null;
          if (rawSpec == null) {
            debugPrint('[@launch_app] 依赖未声明: $name');
            return false;
          }
          final spec = DependencySpec.fromJson(name, rawSpec);
          config = await CacheManager.instance.getResource(
            name,
            spec.constraint,
            type: spec.resourceType,
            preferLatest: true,
          );
          if (config == null) {
            debugPrint('[@launch_app] 依赖获取失败: $name@${spec.constraint}');
            return false;
          }
        }
        final meta = config['meta'] as Map<String, dynamic>?;
        displayName = resolveDisplayName(
          meta ?? {'name': name},
          fallback: name,
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

  // ========== 默认启动 App ==========

  /// @startup_default_get → Map（kind / marketName / marketVersion / 显示名 / fileName 等）
  /// 没设过返回 { kind: "none" }。和 DefaultStartupConfig 字段一一对应。
  static Future<Map<String, dynamic>> _startupDefaultGet() async {
    final cfg = await DefaultStartupPrefs.read();
    return {
      'kind': cfg.kind.value,
      'hasTarget': cfg.hasTarget,
      'marketName': cfg.marketName ?? '',
      'marketVersion': cfg.marketVersion ?? '',
      'marketDisplayName': cfg.marketDisplayName ?? '',
      'localFileName': cfg.localFileName ?? '',
      'localDisplayName': cfg.localDisplayName ?? '',
      'displayName': cfg.displaySummary(noneLabel: ''),
    };
  }

  /// @startup_default_set({kind: "market"|"local", ...})
  /// market: 必填 name + version；可选 displayName
  /// local: 必填 fileName；可选 displayName
  /// 返回 bool（成功 / 参数缺）
  static Future<bool> _startupDefaultSet(Map<String, dynamic> args) async {
    final kind = args['kind']?.toString();
    try {
      if (kind == 'market') {
        final name = args['name']?.toString();
        final version = args['version']?.toString();
        if (name == null ||
            name.isEmpty ||
            version == null ||
            version.isEmpty) {
          debugPrint('[@startup_default_set] kind=market 必须传 name 和 version');
          return false;
        }
        await DefaultStartupPrefs.writeMarket(
          name: name,
          version: version,
          displayName: args['displayName']?.toString(),
        );
        return true;
      }
      if (kind == 'local') {
        final fileName = args['fileName']?.toString();
        if (fileName == null || fileName.isEmpty) {
          debugPrint('[@startup_default_set] kind=local 必须传 fileName');
          return false;
        }
        await DefaultStartupPrefs.writeLocal(
          fileName: fileName,
          displayName: args['displayName']?.toString(),
        );
        return true;
      }
      debugPrint('[@startup_default_set] 未知 kind: $kind');
      return false;
    } catch (e) {
      debugPrint('[@startup_default_set] 失败: $e');
      return false;
    }
  }

  /// @startup_default_clear → bool；清掉默认启动 App，下次冷启动回到 FilePickerPage
  static Future<bool> _startupDefaultClear() async {
    try {
      await DefaultStartupPrefs.writeNone();
      return true;
    } catch (e) {
      debugPrint('[@startup_default_clear] 失败: $e');
      return false;
    }
  }

  // ========== 缓存 ==========

  /// @cache_clear → bool；清掉 dsl_cache 目录（市场/库的本地包缓存）。
  /// 下次 @launch_app / 加载依赖会重新从 Registry 拉。
  static Future<bool> _cacheClear() async {
    try {
      await CacheManager.instance.reset();
      // CacheManager.reset 只清内存态，磁盘目录得自己删（web 无文件系统则 no-op）
      final docs = await NativeFs.appDocDir();
      if (docs != null) {
        await NativeFs.deleteDirAbs('$docs/dsl_cache');
      }
      return true;
    } catch (e) {
      debugPrint('[@cache_clear] 失败: $e');
      return false;
    }
  }

  // ========== 框架 locale ==========
  //
  // 现成的 @set_locale / @get_locale 只动 JSON-APP 自己的 global.locale，
  // 框架 UI 不会跟着切。launcher 替代了原生主页，用户在 launcher 设置里切
  // "Deutsch" 期望整个 app（包括框架 UI）一起切，所以另开一对桥接：

  /// @get_framework_locale → 'zh'/'en'/'de'/'es'/'fr'/'pt'/'ca'/'hi'/'ko'/'ja'/'it'
  /// 或 'system'（跟随系统时）
  static String _getFrameworkLocale() {
    final v = appLocale.value;
    if (v == null) return 'system';
    return v.languageCode;
  }

  /// @set_framework_locale({value: 'zh'|'en'|'de'|'es'|'fr'|'pt'|'ca'|'hi'|'ko'|'ja'|'it'|'system'}) → bool
  /// （value 接受任意框架支持的语言简码，见 framework_strings.dart 的 supportedLocales）
  /// 同步 LocaleController.setLocale + interpreter.global.locale，
  /// MaterialApp 跟着 appLocale 重建，JSON-APP 模板 {{ t('xxx') }} 也跟着切。
  static Future<bool> _setFrameworkLocale(
    Map<String, dynamic> args,
    JsonInterpreter interpreter,
  ) async {
    final v = args['value']?.toString();
    if (v == null || v.isEmpty) return false;
    try {
      if (v == 'system') {
        await LocaleController.setLocale(null);
        // 同步 JSON-APP locale 到当前系统简码
        final tag = LocaleController.currentLocaleTag();
        final dash = tag.indexOf(RegExp(r'[-_]'));
        interpreter.setVariable(
          'global.locale',
          dash < 0 ? tag : tag.substring(0, dash),
        );
      } else {
        await LocaleController.setLocale(Locale(v));
        interpreter.setVariable('global.locale', v);
      }
      return true;
    } catch (e) {
      debugPrint('[@set_framework_locale] 失败: $e');
      return false;
    }
  }

  // ========== Auth ==========

  /// @auth_logout → bool；登出 IM + 清 token，AuthGate 会自动跳回登录页
  //
  // 注：读取当前用户 / 头像 / 邮箱用现成的 @get_user_info（native）或
  // lib_user 的 getUserAvatar / getUserName / getUserEmail 即可，不再重复
  // 包一个 @auth_current_user。

  static Future<bool> _authLogout() async {
    try {
      await IMService.instance.logout();
      await AuthService.signOut();
      return true;
    } catch (e) {
      debugPrint('[@auth_logout] 失败: $e');
      return false;
    }
  }
}
