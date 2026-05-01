/// 应用配置 - 统一管理所有服务端地址和配置
///
/// 使用方式：
/// ```dart
/// import 'package:flutter_application_1/config/app_config.dart';
///
/// // 使用后端API地址
/// final url = '${AppConfig.backendUrl}/api/chat';
/// ```
class AppConfig {
  // ==================== 服务端地址配置 ====================

  /// 后端API服务器地址
  ///
  /// 开发环境：http://localhost:5566 或 http://127.0.0.1:5566
  /// 生产环境：https://app-backend.dapangyu.work
  static const String backendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'https://app-backend.dapangyu.work',
  );

  /// Supabase认证服务器地址
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://app-auth.dapangyu.work',
  );

  /// MinIO对象存储服务器地址
  static const String minioUrl = String.fromEnvironment(
    'MINIO_URL',
    defaultValue: 'https://app-oss-endpoint.dapangyu.work',
  );

  /// 组件注册中心地址
  static const String registryUrl = String.fromEnvironment(
    'REGISTRY_URL',
    defaultValue: 'https://registry.dapangyu.work',
  );

  // ==================== API端点配置 ====================

  /// AI对话API端点
  static String get chatApiUrl => '$backendUrl/chat';

  /// AI供应商列表API端点
  static String get providersApiUrl => '$backendUrl/api/providers';

  /// 豆包ASR WebSocket端点
  static String get bytedanceAsrUrl => backendUrl;

  /// OSS模型下载基础URL
  static String get ossModelsBaseUrl => '$minioUrl/models';

  // ==================== 应用配置 ====================

  /// 应用名称
  static const String appName = 'AI App';

  /// 应用版本
  static const String appVersion = '1.1.0';

  /// 是否为调试模式
  static const bool isDebug = bool.fromEnvironment('DEBUG', defaultValue: false);

  /// 是否启用日志
  static const bool enableLogging = bool.fromEnvironment('ENABLE_LOGGING', defaultValue: true);

  // ==================== 环境检测 ====================

  /// 当前环境
  static Environment get environment {
    if (backendUrl.contains('localhost') || backendUrl.contains('127.0.0.1')) {
      return Environment.development;
    } else if (backendUrl.contains('test') || backendUrl.contains('staging')) {
      return Environment.staging;
    } else {
      return Environment.production;
    }
  }

  /// 是否为生产环境
  static bool get isProduction => environment == Environment.production;

  /// 是否为开发环境
  static bool get isDevelopment => environment == Environment.development;

  // ==================== 辅助方法 ====================

  /// 打印当前配置（用于调试）
  static void printConfig() {
    print('========== App Configuration ==========');
    print('Environment: ${environment.name}');
    print('Backend URL: $backendUrl');
    print('Supabase URL: $supabaseUrl');
    print('MinIO URL: $minioUrl');
    print('Registry URL: $registryUrl');
    print('Debug Mode: $isDebug');
    print('Logging Enabled: $enableLogging');
    print('=======================================');
  }
}

/// 环境枚举
enum Environment {
  development,
  staging,
  production,
}
