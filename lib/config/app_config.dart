import 'environment_service.dart';

/// 应用配置 - 统一管理所有服务端地址和配置
///
/// 使用方式：
/// ```dart
/// import 'package:flutter_application_1/config/app_config.dart';
///
/// // 使用后端API地址
/// final url = '${AppConfig.backendUrl}/api/ai/chat/start';
/// ```
///
/// 这 7 个 URL 默认是生产环境（编译期 `String.fromEnvironment` 可覆盖），
/// 运行时通过 [EnvironmentService] 可切换到用户自建的测试环境。
/// 自定义环境某个字段为空 → 自动回退到生产默认。
class AppConfig {
  // ==================== 生产默认（编译期常量，可被 --dart-define 覆盖） ====================

  static const String _defaultBackendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://myapp-backend.dapangyu.work',
  );

  static const String _defaultSupabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://myapp-auth.dapangyu.work',
  );

  static const String _defaultMinioUrl = String.fromEnvironment(
    'MINIO_URL',
    defaultValue: 'https://myapp-oss-endpoint.dapangyu.work',
  );

  static const String _defaultRegistryUrl = String.fromEnvironment(
    'REGISTRY_URL',
    defaultValue: 'https://myapp-registry.dapangyu.work',
  );

  static const String _defaultImApiUrl = String.fromEnvironment(
    'IM_API_URL',
    defaultValue: 'https://myapp-im.dapangyu.work',
  );

  static const String _defaultImWsUrl = String.fromEnvironment(
    'IM_WS_URL',
    defaultValue: 'wss://myapp-im.dapangyu.work',
  );

  static const String _defaultConfigCenterUrl = String.fromEnvironment(
    'CONFIG_CENTER_URL',
    defaultValue: 'https://config.dapangyu.work',
  );

  // ==================== Demo 模式 ====================
  //
  // Demo 是免登录体验，但**不再有固定的 demo 专用后端**：demo 的全部流量
  // （/api/auth/demo、AI 回放、FaaS 调用、依赖解析）都走当前 active 环境——
  // 每个集群都应自带 demo 装配（demo 账号 + 公共 FaaS 组 + 预录回放，部署
  // runbook 已覆盖）。集群未装配 demo 时后端返回 DEMO_NOT_CONFIGURED，客户端
  // 给出可读提示。（历史设计曾把 demo 钉在固定集群 myapp-pre-de；该集群已
  // 退役，钉死 URL 反而让 demo 全网 404，故改为随环境走。）

  // ==================== 运行时 getter — 走 EnvironmentService active 环境 ====================
  //
  // 任一字段在 active 环境里为 null/空 → 回退生产默认。
  // EnvironmentService 未 load 完成时，active 是内建 production（所有字段 null），
  // 即返回生产默认 → 永远不会拿到 null/空 URL。

  static String _pick(String? custom, String fallback) =>
      (custom == null || custom.isEmpty) ? fallback : custom;

  /// 后端API服务器地址（demo 模式同样走 active 环境）。
  static String get backendUrl =>
      _pick(EnvironmentService.instance.active.backendUrl, _defaultBackendUrl);

  /// Supabase 认证服务器地址
  static String get supabaseUrl => _pick(
    EnvironmentService.instance.active.supabaseUrl,
    _defaultSupabaseUrl,
  );

  /// MinIO 对象存储服务器地址
  static String get minioUrl =>
      _pick(EnvironmentService.instance.active.minioUrl, _defaultMinioUrl);

  /// 组件注册中心地址（demo 模式同样走 active 环境，解析 demo app 的依赖）。
  static String get registryUrl => _pick(
    EnvironmentService.instance.active.registryUrl,
    _defaultRegistryUrl,
  );

  /// OpenIM HTTP API 地址（fallback；正常由后端 /api/im/token 下发覆盖）
  static String get imApiUrl =>
      _pick(EnvironmentService.instance.active.imApiUrl, _defaultImApiUrl);

  /// OpenIM WebSocket 地址（fallback；正常由后端 /api/im/token 下发覆盖）
  static String get imWsUrl =>
      _pick(EnvironmentService.instance.active.imWsUrl, _defaultImWsUrl);

  /// 配置中心地址（独立服务，物理隔离于主后端，主后端挂了它仍可下发紧急配置）
  static String get configCenterUrl => _pick(
    EnvironmentService.instance.active.configCenterUrl,
    _defaultConfigCenterUrl,
  );

  // ==================== API端点配置 ====================

  /// AI供应商列表API端点
  static String get providersApiUrl => '$backendUrl/api/ai/providers';

  /// 豆包ASR WebSocket端点
  static String get bytedanceAsrUrl => backendUrl;

  // ==================== 应用配置 ====================

  /// 应用名称
  static const String appName = 'AI App';

  /// 应用版本。单一真相源是 pubspec.yaml 的 `version:` 字段：走 scripts/flutter.sh
  /// 构建时会以 `--dart-define=APP_VERSION=<pubspec version>` 注入；此处常量仅作裸
  /// `flutter build` / IDE 构建的兜底默认（请与 pubspec 保持一致）。主页底部那个 v
  /// 标签读的就是它。（与平台 VERSION=1.2.x 是两条独立线，互不影响。）
  static const String appVersion =
      String.fromEnvironment('APP_VERSION', defaultValue: '1.2.2+3');

  /// 构建时注入的 Git commit。默认空字符串，避免把具体 commit 写死进代码。
  static const String gitCommit = String.fromEnvironment('APP_GIT_COMMIT');

  /// 是否为调试模式
  static const bool isDebug = bool.fromEnvironment(
    'DEBUG',
    defaultValue: false,
  );

  /// 是否启用日志
  static const bool enableLogging = bool.fromEnvironment(
    'ENABLE_LOGGING',
    defaultValue: true,
  );

  // ==================== 环境检测 ====================

  /// 当前环境（按 backendUrl 推断 dev / staging / prod）
  static EnvironmentKind get environmentKind {
    final url = backendUrl;
    if (url.contains('localhost') || url.contains('127.0.0.1')) {
      return EnvironmentKind.development;
    } else if (url.contains('test') || url.contains('staging')) {
      return EnvironmentKind.staging;
    } else {
      return EnvironmentKind.production;
    }
  }

  /// 是否为生产环境
  static bool get isProduction => environmentKind == EnvironmentKind.production;

  /// 是否为开发环境
  static bool get isDevelopment =>
      environmentKind == EnvironmentKind.development;

  // ==================== 辅助方法 ====================

  /// 打印当前配置（用于调试）
  static void printConfig() {
    print('========== App Configuration ==========');
    print('Environment: ${environmentKind.name}');
    print(
      'Active env: ${EnvironmentService.instance.active.name} (${EnvironmentService.instance.active.id})',
    );
    print('Backend URL: $backendUrl');
    print('Supabase URL: $supabaseUrl');
    print('MinIO URL: $minioUrl');
    print('Registry URL: $registryUrl');
    print('IM API URL: $imApiUrl');
    print('IM WS URL: $imWsUrl');
    print('Config Center URL: $configCenterUrl');
    print('Debug Mode: $isDebug');
    print('Logging Enabled: $enableLogging');
    print('=======================================');
  }
}

/// 环境类型枚举（按 backendUrl 推断）
enum EnvironmentKind { development, staging, production }
