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

  // 下拉菜单 state：菜单作为 chat overlay 自己 Stack 内的一层渲染，
  // 这样能跟着拖动同步移动、保证 z-order 在字幕上面、再次点 chip 能切回关闭。
  // 不再用 showMenu (它走 root navigator overlay，物理位置在 chat overlay 下方)。
  bool _menuOpen = false;
  Future<Set<String>>? _statusProbeFuture;

  String _currentSessionTitle() {
    final sid = widget.activeSessionId;
    if (sid.isEmpty) return '新会话';
    for (final s in widget.getSessions()) {
      if (s.id == sid) return s.displayTitle(maxVisualWidth: 8);
    }
    return '新会话';
  }

  void _toggleMenu() {
    if (_menuOpen) {
      setState(() => _menuOpen = false);
    } else {
      // 每次打开重发起探活
      _statusProbeFuture = widget.onProbeAllSessionStatus?.call();
      setState(() => _menuOpen = true);
    }
  }

  void _closeMenu() {
    if (_menuOpen) setState(() => _menuOpen = false);
  }

  /// 二级 action 菜单：重命名 / 删除（从 ⋮ 进入）
  Future<void> _openSessionActions(BuildContext navCtx, String sid) async {
    final s = widget.getSessions().firstWhere(
          (x) => x.id == sid,
          orElse: () => SessionMeta(id: ''),
        );
    if (s.id.isEmpty) return;

    final action = await showModalBottomSheet<String>(
      context: navCtx,
      backgroundColor: const Color(0xFF2C2C2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                s.displayTitle(maxVisualWidth: 22),
                style: const TextStyle(
                    color: Colors.white70, fontSize: 13),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: Colors.white),
              title: const Text('重命名',
                  style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('删除会话',
                  style: TextStyle(color: Colors.redAccent)),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (action == 'rename') {
      // ignore: use_build_context_synchronously — navCtx 来自 JsonDslApp.navigatorKey，永远有效
      await _promptRename(navCtx, s);
    } else if (action == 'delete') {
      // ignore: use_build_context_synchronously — 同上
      final ok = await _confirmDelete(navCtx, s);
      if (ok == true) await widget.onDeleteSession?.call(sid);
    }
  }

  Future<void> _promptRename(BuildContext navCtx, SessionMeta s) async {
    final controller =
        TextEditingController(text: s.customTitle ?? s.firstMessage);
    final newTitle = await showDialog<String>(
      context: navCtx,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '新标题'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('保存')),
        ],
      ),
    );
    if (newTitle != null) {
      await widget.onRenameSession?.call(s.id, newTitle);
    }
  }

  Future<bool?> _confirmDelete(BuildContext navCtx, SessionMeta s) async {
    return await showDialog<bool>(
      context: navCtx,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text(
            '删除「${s.displayTitle(maxVisualWidth: 16)}」？后台正在跑的回答也会被中止。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
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
        child: Stack(
          children: [
            // 主体内容（标题栏 + 消息列表）
            Column(
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
                    onTap: _toggleMenu,
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
            // 下拉菜单：作为 Stack 第二层，z-order 在字幕之上；
            // 跟 chat overlay 容器一起被 Positioned 移动，所以拖动时同步跟随。
            if (_menuOpen) ...[
              // 1. 半透明 backdrop：拦截字幕区域的 tap，点空白处关菜单
              Positioned(
                left: 0,
                right: 0,
                top: 36, // 标题栏高度，菜单不遮挡标题栏（用户可以再点 chip 关菜单）
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closeMenu,
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.3),
                  ),
                ),
              ),
              // 2. 菜单面板本体
              Positioned(
                top: 40,
                left: 38, // 大致对齐 chip 左缘
                child: _SessionDropdownPanel(
                  sessions: widget.getSessions(),
                  activeSessionId: widget.activeSessionId,
                  statusProbeFuture: _statusProbeFuture,
                  maxHeight: screen.height * 0.4 - 48,
                  onNewSession: () async {
                    _closeMenu();
                    await widget.onNewSession?.call();
                  },
                  onSwitchSession: (sid) async {
                    _closeMenu();
                    if (sid != widget.activeSessionId) {
                      await widget.onSwitchSession?.call(sid);
                    }
                  },
                  onMoreTap: (sid) async {
                    _closeMenu();
                    final navCtx = widget.getNavigatorContext?.call();
                    if (navCtx != null) {
                      await _openSessionActions(navCtx, sid);
                    }
                  },
                ),
              ),
            ],
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

/// 会话切换小标签 —— 点击触发 onTap，由调用方控制下拉菜单显隐
class _SessionChip extends StatelessWidget {
  final String title;
  final VoidCallback onTap;

  const _SessionChip({required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
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

/// 下拉菜单面板：自渲染，作为 ChatOverlay Stack 的一层
class _SessionDropdownPanel extends StatelessWidget {
  final List<SessionMeta> sessions;
  final String activeSessionId;
  final Future<Set<String>>? statusProbeFuture;
  final double maxHeight;
  final VoidCallback onNewSession;
  final void Function(String sid) onSwitchSession;
  final void Function(String sid) onMoreTap;

  const _SessionDropdownPanel({
    required this.sessions,
    required this.activeSessionId,
    required this.statusProbeFuture,
    required this.maxHeight,
    required this.onNewSession,
    required this.onSwitchSession,
    required this.onMoreTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      shadowColor: Colors.black.withValues(alpha: 0.5),
      child: Container(
        width: 240,
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.15),
            width: 0.5,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // + 新建会话
              InkWell(
                onTap: onNewSession,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.add_circle_outline,
                          color: Colors.purpleAccent, size: 18),
                      const SizedBox(width: 10),
                      const Text(
                        '新建会话',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                height: 0.5,
                color: Colors.white.withValues(alpha: 0.1),
              ),
              // 会话列表
              Flexible(
                child: sessions.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text('暂无会话',
                            style: TextStyle(
                                color: Colors.white54, fontSize: 12)),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: sessions.length,
                        itemBuilder: (ctx, i) {
                          final s = sessions[i];
                          final isActive = s.id == activeSessionId;
                          return InkWell(
                            onTap: () => onSwitchSession(s.id),
                            child: Container(
                              color: isActive
                                  ? Colors.white.withValues(alpha: 0.06)
                                  : null,
                              child: _SessionMenuRow(
                                session: s,
                                isActive: isActive,
                                probeFuture: statusProbeFuture,
                                onMoreTap: () => onMoreTap(s.id),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 下拉菜单里一行：状态点 + 标题 + 副标题 + ⋮
class _SessionMenuRow extends StatelessWidget {
  final SessionMeta session;
  final bool isActive;
  final Future<Set<String>>? probeFuture;
  final VoidCallback onMoreTap;

  const _SessionMenuRow({
    required this.session,
    required this.isActive,
    required this.probeFuture,
    required this.onMoreTap,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Set<String>>(
      future: probeFuture,
      builder: (ctx, snap) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
          child: Row(
            children: [
              _statusDot(),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      session.displayTitle(maxVisualWidth: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.92),
                        fontSize: 13,
                        fontWeight:
                            isActive ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _relativeTime(session.updatedAt),
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ),
              // ⋮ 按钮：用 GestureDetector + opaque 行为吞掉 tap，
              // 不让外层 InkWell（切换会话）也跟着响应
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onMoreTap,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.more_vert,
                      size: 18, color: Colors.white54),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _statusDot() {
    Color c;
    if (isActive) {
      c = Colors.purpleAccent;
    } else if (session.lastKnownStatus == 'running' && session.processAlive) {
      c = const Color(0xFFFFC107);
    } else if (session.lastKnownStatus == 'running' && !session.processAlive) {
      c = const Color(0xFFE53935);
    } else if (session.lastKnownStatus == 'failed' ||
        session.lastKnownStatus == 'aborted') {
      c = const Color(0xFFE53935);
    } else if (session.lastKnownStatus == 'done') {
      c = Colors.grey.shade400;
    } else {
      c = Colors.grey.shade300;
    }
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
  }

  String _relativeTime(int ms) {
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60 * 1000) return '刚刚';
    if (diff < 60 * 60 * 1000) return '${diff ~/ (60 * 1000)} 分钟前';
    if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ (60 * 60 * 1000)} 小时前';
    return '${diff ~/ (24 * 60 * 60 * 1000)} 天前';
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
