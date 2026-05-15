import 'package:flutter/material.dart';
import 'session_meta.dart';

/// 对话消息
class ChatMessage {
  final String role; // 'user' | 'assistant' | 'system'
  final String content;
  final Map<String, dynamic>? jsonApp; // AI 生成的 JSON-APP
  final String? action; // 客户端动作，例如 'UPLOAD_CURRENT_APP'
  final String? failedJsonUrl; // 下载失败的 URL
  final String? jsonUrl; // 待用户点击下载并运行的 JSON URL
  ChatMessage({required this.role, required this.content, this.jsonApp, this.action, this.failedJsonUrl, this.jsonUrl});
}

/// 纯字幕式覆层 — 半透明浮在屏幕底部，带窗口框和标题栏。
class ChatOverlay extends StatefulWidget {
  final List<ChatMessage> messages;
  final String? liveTranscript;
  final bool isListening;
  final bool isThinking;
  final bool isGeneratingJson;
  final String generatingStatusMessage;
  final VoidCallback onClose;
  final VoidCallback? onClear;
  final ScrollController scrollController;
  final void Function(Map<String, dynamic> jsonConfig)? onRunJsonApp;
  final VoidCallback? onUploadCurrentApp;
  final void Function(String url)? onRetryDownload;
  final Future<void> Function(String url)? onDownloadAndRun;
  final VoidCallback? onRetryLastTurn;  // worker 死了时的重试按钮

  // 多会话回调（由 designer_ball 注入；service 完成实际状态变更）
  final String activeSessionId;
  final List<SessionMeta> Function() getSessions;
  final Future<void> Function()? onNewSession;
  final Future<void> Function(String sid)? onSwitchSession;
  final Future<void> Function(String sid)? onDeleteSession;
  final Future<void> Function(String sid, String newTitle)? onRenameSession;
  /// 打开 sheet 时调一次：对最近的 N 条 committed session 调 /status，
  /// 返回 SessionMeta 已被原地更新过的 sid 集合（不需要用，调完 setState 拿最新就行）
  final Future<Set<String>> Function()? onProbeAllSessionStatus;
  /// DesignerBall 挂在 MaterialApp.builder 上，ChatOverlay 自身的 context
  /// 找不到 Navigator 祖先（实测会抛 "Navigator operation requested with a
  /// context that does not include a Navigator"）。需要由 designer_ball 注入
  /// 一个能找到 root navigator 的 context（典型是 JsonDslApp.navigatorKey.currentContext）。
  final BuildContext? Function()? getNavigatorContext;

  const ChatOverlay({
    super.key,
    required this.messages,
    required this.isListening,
    required this.isThinking,
    this.isGeneratingJson = false,
    this.generatingStatusMessage = '正在生成代码...',
    required this.onClose,
    required this.scrollController,
    required this.activeSessionId,
    required this.getSessions,
    this.liveTranscript,
    this.onRunJsonApp,
    this.onClear,
    this.onUploadCurrentApp,
    this.onRetryDownload,
    this.onDownloadAndRun,
    this.onRetryLastTurn,
    this.onNewSession,
    this.onSwitchSession,
    this.onDeleteSession,
    this.onRenameSession,
    this.onProbeAllSessionStatus,
    this.getNavigatorContext,
  });

  @override
  State<ChatOverlay> createState() => _ChatOverlayState();
}

class _ChatOverlayState extends State<ChatOverlay> {
  double _offsetY = 0.0; // 窗口垂直偏移量

  String _currentSessionTitle() {
    final sid = widget.activeSessionId;
    if (sid.isEmpty) return '新会话';
    for (final s in widget.getSessions()) {
      if (s.id == sid) return s.displayTitle(maxVisualWidth: 8);
    }
    return '新会话';
  }

  Future<void> _openSessionSheet(BuildContext fallbackContext) async {
    // ChatOverlay 自身 context 找不到 Navigator（DesignerBall 在 MaterialApp.builder
    // 之上），必须用 designer_ball 注入的 navigatorKey context；fallback 只为防御。
    final navCtx = widget.getNavigatorContext?.call() ?? fallbackContext;
    debugPrint('[ChatOverlay] 点击 SessionChip，准备弹 sheet '
        '(active=${widget.activeSessionId}, sessions=${widget.getSessions().length}, '
        'navCtxFromInjected=${widget.getNavigatorContext?.call() != null})');
    final probe = widget.onProbeAllSessionStatus?.call();
    try {
      await showModalBottomSheet<void>(
        context: navCtx,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => _SessionListSheet(
          activeSessionId: widget.activeSessionId,
          getSessions: widget.getSessions,
          onNewSession: widget.onNewSession,
          onSwitchSession: widget.onSwitchSession,
          onDeleteSession: widget.onDeleteSession,
          onRenameSession: widget.onRenameSession,
          statusProbeFuture: probe,
        ),
      );
      debugPrint('[ChatOverlay] sheet 关闭');
    } catch (e, st) {
      debugPrint('[ChatOverlay] sheet 打开失败: $e\n$st');
    }
    if (mounted) setState(() {});  // sheet 关闭后刷新 chip 标题
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    final visibleMessages =
        widget.messages.where((m) => m.content.isNotEmpty).toList();
    final hasLive = widget.liveTranscript != null && widget.liveTranscript!.isNotEmpty;

    if (visibleMessages.isEmpty && !hasLive && !widget.isThinking && !widget.isGeneratingJson) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: 12,
      right: 12,
      bottom: bottomPadding + 80 + _offsetY,
      child: Container(
        constraints: BoxConstraints(maxHeight: screen.height * 0.4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.chat_bubble_outline,
                      color: Colors.white.withValues(alpha: 0.5), size: 14),
                  const SizedBox(width: 6),
                  if (widget.onNewSession != null) ...[
                    _TitleBarButton(
                      icon: Icons.add_circle_outline,
                      onTap: () { widget.onNewSession!(); },
                    ),
                    const SizedBox(width: 4),
                  ],
                  _SessionChip(
                    title: _currentSessionTitle(),
                    onTap: () => _openSessionSheet(context),
                  ),
                  // 可拖动区域
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onPanUpdate: (details) {
                        setState(() {
                          // 向上拖动时 dy 为负，增加 offsetY（窗口上移）
                          // 向下拖动时 dy 为正，减少 offsetY（窗口下移）
                          _offsetY -= details.delta.dy;

                          // 限制拖动范围：不能超出屏幕
                          final maxOffset = screen.height - bottomPadding - 200; // 至少保留200px在屏幕内
                          final minOffset = -80.0; // 不能低于初始位置
                          _offsetY = _offsetY.clamp(minOffset, maxOffset);
                        });
                      },
                      child: Container(
                        alignment: Alignment.center,
                        child: Container(
                          width: 30,
                          height: 3,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (widget.onClear != null && visibleMessages.isNotEmpty)
                    _TitleBarButton(
                      icon: Icons.delete_outline,
                      onTap: widget.onClear!,
                    ),
                  const SizedBox(width: 4),
                  _TitleBarButton(
                    icon: Icons.close,
                    onTap: widget.onClose,
                  ),
                ],
              ),
            ),
            // 消息列表
            Flexible(
              child: ScrollConfiguration(
                behavior: _NoGlowBehavior(),
                child: ListView.builder(
                  controller: widget.scrollController,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  shrinkWrap: true,
                  itemCount: visibleMessages.length +
                      (hasLive ? 1 : 0) +
                      (widget.isThinking ? 1 : 0) +
                      (widget.isGeneratingJson ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (hasLive && index == visibleMessages.length) {
                      return _buildLine('you', widget.liveTranscript!, live: true);
                    }
                    if (widget.isThinking && index == visibleMessages.length + (hasLive ? 1 : 0)) {
                      return _buildThinkingLine();
                    }
                    if (widget.isGeneratingJson && index == visibleMessages.length + (hasLive ? 1 : 0) + (widget.isThinking ? 1 : 0)) {
                      return _buildGeneratingLine();
                    }
                    final msg = visibleMessages[index];
                    if (msg.action == 'UPLOAD_CURRENT_APP') {
                      return _buildActionLine(msg.content, '上传当前应用配置', widget.onUploadCurrentApp);
                    }
                    if (msg.action == 'RETRY_LAST_TURN') {
                      return _buildActionLine(msg.content, '重试', widget.onRetryLastTurn);
                    }
                    if (msg.failedJsonUrl != null) {
                      return _buildRetryLine(msg.content, msg.failedJsonUrl!);
                    }
                    if (msg.jsonUrl != null) {
                      return _buildDownloadLine(msg.content, msg.jsonUrl!);
                    }
                    if (msg.role == 'system' && msg.jsonApp != null) {
                      return _buildRunButton(msg.content, msg.jsonApp!);
                    }
                    return _buildLine(
                      msg.role == 'user' ? 'you' : 'AI',
                      msg.content,
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLine(String label, String content, {bool live = false}) {
    final isUser = label == 'you';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isUser
              ? Colors.purple.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$label: ',
                style: TextStyle(
                  color: isUser
                      ? Colors.purple.shade100
                      : Colors.purpleAccent.shade100,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextSpan(
                text: content + (live ? ' ●' : ''),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: live ? 0.6 : 0.9),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRunButton(String label, Map<String, dynamic> jsonApp) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: () => widget.onRunJsonApp?.call(jsonApp),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.play_arrow, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRetryLine(String content, String url) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (content.isNotEmpty) _buildLine('assistant', content),
          GestureDetector(
            onTap: () => widget.onRetryDownload?.call(url),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.refresh, color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  const Text(
                    '重试下载 JSON',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionLine(String content, String buttonText, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (content.isNotEmpty) _buildLine('system', content),
          GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_upload, color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    buttonText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadLine(String content, String url) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (content.isNotEmpty) _buildLine('AI', content),
          _DownloadRunButton(
            url: url,
            onDownloadAndRun: widget.onDownloadAndRun,
          ),
        ],
      ),
    );
  }

  Widget _buildThinkingLine() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const _ThinkingDots(),
      ),
    );
  }

  Widget _buildGeneratingLine() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.purpleAccent.shade100),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                widget.generatingStatusMessage,
                style: TextStyle(
                  color: Colors.purpleAccent.shade100,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标题栏按钮
class _TitleBarButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _TitleBarButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color: Colors.white.withValues(alpha: 0.0),
        ),
        child: Icon(icon, color: Colors.white60, size: 15),
      ),
    );
  }
}

/// 去掉 overscroll 发光/黄条效果
class _NoGlowBehavior extends ScrollBehavior {
  @override
  Widget buildOverscrollIndicator(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child;
  }
}

/// 会话切换小标签 —— 点击弹 _SessionListSheet
class _SessionChip extends StatelessWidget {
  final String title;
  final VoidCallback onTap;

  const _SessionChip({required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // 用 Material+InkWell 给点击反馈，避免之前 ProviderChip "点不动" 的歧义
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.2),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.forum_outlined,
                  color: Colors.white.withValues(alpha: 0.7), size: 12),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 110),
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more,
                  color: Colors.white.withValues(alpha: 0.5), size: 14),
            ],
          ),
        ),
      ),
    );
  }
}

/// 会话列表 sheet（半屏 bottom sheet）
/// - 顶部 [+ 新建会话]
/// - 每行：标题 + 副标题（时间 + 状态）；左侧状态圆点
/// - 滑动删除；长按重命名；点击切换 active
class _SessionListSheet extends StatefulWidget {
  final String activeSessionId;
  final List<SessionMeta> Function() getSessions;
  final Future<void> Function()? onNewSession;
  final Future<void> Function(String sid)? onSwitchSession;
  final Future<void> Function(String sid)? onDeleteSession;
  final Future<void> Function(String sid, String newTitle)? onRenameSession;
  final Future<Set<String>>? statusProbeFuture;

  const _SessionListSheet({
    required this.activeSessionId,
    required this.getSessions,
    required this.onNewSession,
    required this.onSwitchSession,
    required this.onDeleteSession,
    required this.onRenameSession,
    required this.statusProbeFuture,
  });

  @override
  State<_SessionListSheet> createState() => _SessionListSheetState();
}

class _SessionListSheetState extends State<_SessionListSheet> {
  @override
  void initState() {
    super.initState();
    // 探活完成后刷新一次列表（拿到最新状态点）
    widget.statusProbeFuture?.then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessions = widget.getSessions();
    final mq = MediaQuery.of(context);

    return Container(
      width: double.infinity,  // 否则只贴着内容宽度，sheet 会变成一条窄缝看不见
      constraints: BoxConstraints(
        maxHeight: mq.size.height * 0.6,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // grab handle
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // + 新建会话
            InkWell(
              onTap: () async {
                Navigator.of(context).pop();
                await widget.onNewSession?.call();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Colors.purple.withValues(alpha: 0.25),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.add, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      '新建会话',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              height: 1,
              color: Colors.white.withValues(alpha: 0.08),
            ),
            Flexible(
              child: sessions.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 40),
                      child: Center(
                        child: Text(
                          '还没有会话',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: sessions.length,
                      separatorBuilder: (_, __) => Container(
                        height: 1,
                        color: Colors.white.withValues(alpha: 0.06),
                        margin: const EdgeInsets.only(left: 60),
                      ),
                      itemBuilder: (ctx, i) {
                        final s = sessions[i];
                        return _buildRow(s);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(SessionMeta s) {
    final isActive = s.id == widget.activeSessionId;
    return Dismissible(
      key: ValueKey('session_${s.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: Colors.red.withValues(alpha: 0.6),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) async {
        return await _confirmDelete(s);
      },
      onDismissed: (_) async {
        await widget.onDeleteSession?.call(s.id);
        if (mounted) setState(() {});
      },
      child: InkWell(
        onTap: () async {
          Navigator.of(context).pop();
          if (!isActive) {
            await widget.onSwitchSession?.call(s.id);
          }
        },
        onLongPress: () => _promptRename(s),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: isActive ? Colors.white.withValues(alpha: 0.06) : null,
          child: Row(
            children: [
              _statusDot(s),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.displayTitle(maxVisualWidth: 22),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontSize: 14,
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              if (isActive)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.check, color: Colors.purpleAccent, size: 18),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusDot(SessionMeta s) {
    Color c;
    if (s.id == widget.activeSessionId) {
      c = Colors.purpleAccent;
    } else if (s.lastKnownStatus == 'running' && s.processAlive) {
      c = const Color(0xFFFFC107); // yellow: 仍在跑但非 active
    } else if (s.lastKnownStatus == 'running' && !s.processAlive) {
      c = const Color(0xFFE53935); // red: worker 死了
    } else if (s.lastKnownStatus == 'done') {
      c = Colors.white.withValues(alpha: 0.4);
    } else if (s.lastKnownStatus == 'failed' || s.lastKnownStatus == 'aborted') {
      c = const Color(0xFFE53935);
    } else {
      c = Colors.white.withValues(alpha: 0.25);
    }
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
  }

  String _subtitle(SessionMeta s) {
    final parts = <String>[_relativeTime(s.updatedAt)];
    final st = s.lastKnownStatus;
    if (st != null && st.isNotEmpty) parts.add(st);
    return parts.join(' · ');
  }

  String _relativeTime(int ms) {
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 60 * 60 * 1000) return '${diff ~/ (60 * 1000)} 分钟前';
    if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ (60 * 60 * 1000)} 小时前';
    return '${diff ~/ (24 * 60 * 60 * 1000)} 天前';
  }

  Future<bool> _confirmDelete(SessionMeta s) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('删除「${s.displayTitle(maxVisualWidth: 16)}」？后台正在跑的回答也会被中止。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return res ?? false;
  }

  Future<void> _promptRename(SessionMeta s) async {
    final controller = TextEditingController(text: s.customTitle ?? s.firstMessage);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '新标题'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (newTitle == null) return;
    await widget.onRenameSession?.call(s.id, newTitle);
    if (mounted) setState(() {});
  }
}

class _DownloadRunButton extends StatefulWidget {
  final String url;
  final Future<void> Function(String url)? onDownloadAndRun;

  const _DownloadRunButton({
    required this.url,
    this.onDownloadAndRun,
  });

  @override
  State<_DownloadRunButton> createState() => _DownloadRunButtonState();
}

class _DownloadRunButtonState extends State<_DownloadRunButton> {
  bool _isLoading = false;
  String? _error;

  Future<void> _handleTap() async {
    if (_isLoading || widget.onDownloadAndRun == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    String? err;
    try {
      await widget.onDownloadAndRun!(widget.url);
    } catch (e) {
      err = e.toString();
    }

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    final buttonLabel = _isLoading
        ? '下载中...'
        : (_error == null ? '下载并运行' : '重试下载并运行');

    return GestureDetector(
      onTap: _handleTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _error == null
              ? Colors.green.withValues(alpha: 0.5)
              : Colors.orange.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLoading)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            else
              Icon(
                _error == null ? Icons.download : Icons.refresh,
                color: Colors.white,
                size: 18,
              ),
            const SizedBox(width: 6),
            Text(
              buttonLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 三点跳动动画
class _ThinkingDots extends StatefulWidget {
  const _ThinkingDots();

  @override
  State<_ThinkingDots> createState() => _ThinkingDotsState();
}

class _ThinkingDotsState extends State<_ThinkingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'AI: ',
              style: TextStyle(
                color: Colors.purpleAccent.shade100,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            ...List.generate(3, (i) {
              final delay = i * 0.2;
              final t = (_ctrl.value - delay).clamp(0.0, 1.0);
              final opacity = (1.0 - (t * 2 - 1).abs()).clamp(0.3, 1.0);
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: Colors.white70,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}
