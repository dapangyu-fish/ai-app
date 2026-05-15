/// 多会话支持的元数据。一条 session 在 prefs 里就是一条 SessionMeta。
///
/// 状态约定：
/// - committed=false：本地刚 createNewSession 出来的占位，还没成功发过消息。
///   未持久化到 prefs；杀 app 就丢。
/// - committed=true：首次 POST /start 200 之后才置位 + 写 prefs。
///
/// title 显示优先级：customTitle > 首条 user message 截断 > "新会话"。
class SessionMeta {
  final String id;
  String? customTitle;
  String firstMessage;       // 首条 user message，title 来源；committed 后不再变
  String lastUserMessage;    // 最近一条已被 backend 接受的 user message，用于 retry/resume
  int updatedAt;
  bool committed;
  String? lastKnownStatus;   // 上次 /status 探到的 status: running/done/failed/aborted
  bool processAlive;          // 上次 /status 探到的 process_alive
  String lastEntryId;         // SSE 续读游标，仅 active session 有意义

  SessionMeta({
    required this.id,
    this.customTitle,
    this.firstMessage = '',
    this.lastUserMessage = '',
    int? updatedAt,
    this.committed = false,
    this.lastKnownStatus,
    this.processAlive = false,
    this.lastEntryId = '0',
  }) : updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
        'id': id,
        if (customTitle != null) 'customTitle': customTitle,
        'firstMessage': firstMessage,
        'lastUserMessage': lastUserMessage,
        'updatedAt': updatedAt,
        'committed': committed,
        if (lastKnownStatus != null) 'lastKnownStatus': lastKnownStatus,
        'processAlive': processAlive,
        'lastEntryId': lastEntryId,
      };

  factory SessionMeta.fromJson(Map<String, dynamic> j) => SessionMeta(
        id: j['id'] as String,
        customTitle: j['customTitle'] as String?,
        firstMessage: j['firstMessage'] as String? ?? '',
        lastUserMessage: j['lastUserMessage'] as String? ?? '',
        updatedAt: j['updatedAt'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        committed: j['committed'] as bool? ?? true,  // 老数据视为已提交
        lastKnownStatus: j['lastKnownStatus'] as String?,
        processAlive: j['processAlive'] as bool? ?? false,
        lastEntryId: j['lastEntryId'] as String? ?? '0',
      );

  /// 显示用标题。maxVisualWidth 是"视觉宽度"——中文按 1.0、ASCII 按 0.5 计。
  /// 顶栏 chip 建议 8，sheet 列表行建议 22。
  String displayTitle({double maxVisualWidth = 8}) {
    final raw = (customTitle?.isNotEmpty ?? false)
        ? customTitle!
        : (firstMessage.isNotEmpty ? firstMessage : '新会话');
    return _truncateByVisualWidth(raw, maxVisualWidth);
  }

  static String _truncateByVisualWidth(String s, double maxWidth) {
    double w = 0;
    final buf = StringBuffer();
    for (final r in s.runes) {
      final w1 = _runeVisualWidth(r);
      if (w + w1 > maxWidth) {
        return '${buf.toString()}...';
      }
      buf.writeCharCode(r);
      w += w1;
    }
    return buf.toString();
  }

  // ASCII 半宽 0.5，其他都按 1.0（粗略足够 UI 用）
  static double _runeVisualWidth(int rune) => (rune <= 0x7F) ? 0.5 : 1.0;
}
