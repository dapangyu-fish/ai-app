/// 服务环境 —— 7 个域名 + 元信息。
///
/// 任意 URL 字段为 null 或空字符串，表示走 [AppConfig] 的生产默认值。
/// `isBuiltin: true` 表示"生产"内建环境，不可编辑/不可删除。
class Environment {
  final String id;
  final String name;
  final String? backendUrl;
  final String? supabaseUrl;
  final String? minioUrl;
  final String? registryUrl;
  final String? imApiUrl;
  final String? imWsUrl;
  final String? configCenterUrl;
  final bool isBuiltin;
  final int createdAtMillis;

  const Environment({
    required this.id,
    required this.name,
    this.backendUrl,
    this.supabaseUrl,
    this.minioUrl,
    this.registryUrl,
    this.imApiUrl,
    this.imWsUrl,
    this.configCenterUrl,
    this.isBuiltin = false,
    required this.createdAtMillis,
  });

  Environment copyWith({
    String? name,
    String? backendUrl,
    String? supabaseUrl,
    String? minioUrl,
    String? registryUrl,
    String? imApiUrl,
    String? imWsUrl,
    String? configCenterUrl,
  }) {
    return Environment(
      id: id,
      name: name ?? this.name,
      backendUrl: backendUrl ?? this.backendUrl,
      supabaseUrl: supabaseUrl ?? this.supabaseUrl,
      minioUrl: minioUrl ?? this.minioUrl,
      registryUrl: registryUrl ?? this.registryUrl,
      imApiUrl: imApiUrl ?? this.imApiUrl,
      imWsUrl: imWsUrl ?? this.imWsUrl,
      configCenterUrl: configCenterUrl ?? this.configCenterUrl,
      isBuiltin: isBuiltin,
      createdAtMillis: createdAtMillis,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'backendUrl': backendUrl,
        'supabaseUrl': supabaseUrl,
        'minioUrl': minioUrl,
        'registryUrl': registryUrl,
        'imApiUrl': imApiUrl,
        'imWsUrl': imWsUrl,
        'configCenterUrl': configCenterUrl,
        'isBuiltin': isBuiltin,
        'createdAtMillis': createdAtMillis,
      };

  factory Environment.fromJson(Map<String, dynamic> json) {
    String? s(String key) {
      final v = json[key];
      return (v is String && v.isNotEmpty) ? v : null;
    }

    return Environment(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Unnamed',
      backendUrl: s('backendUrl'),
      supabaseUrl: s('supabaseUrl'),
      minioUrl: s('minioUrl'),
      registryUrl: s('registryUrl'),
      imApiUrl: s('imApiUrl'),
      imWsUrl: s('imWsUrl'),
      configCenterUrl: s('configCenterUrl'),
      isBuiltin: json['isBuiltin'] as bool? ?? false,
      createdAtMillis: json['createdAtMillis'] as int? ?? 0,
    );
  }
}
