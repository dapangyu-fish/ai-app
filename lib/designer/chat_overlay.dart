import 'package:flutter/material.dart';
import 'ai_chat_service.dart';
import 'session_meta.dart';
import '../i18n/framework_strings.dart';

/// 对话消息
class ChatMessage {
  final String role; // 'user' | 'assistant' | 'system'
  final String content;
  final Map<String, dynamic>? jsonApp; // AI 生成的 JSON-APP
  final String? action; // 客户端动作，例如 'UPLOAD_CURRENT_APP'
  final String? failedJsonUrl; // 下载失败的 URL
  final String? jsonUrl; // 待用户点击下载并运行的 JSON URL
  ChatMessage({
    required this.role,
    required this.content,
    this.jsonApp,
    this.action,
    this.failedJsonUrl,
    this.jsonUrl,
  });

  Map<String, dynamic> toJson({bool includeJsonApp = true}) => {
    'role': role,
    'content': content,
    if (includeJsonApp && jsonApp != null) 'jsonApp': jsonApp,
    if (action != null) 'action': action,
    if (failedJsonUrl != null) 'failedJsonUrl': failedJsonUrl,
    if (jsonUrl != null) 'jsonUrl': jsonUrl,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final rawJsonApp = json['jsonApp'];
    return ChatMessage(
      role: json['role']?.toString() ?? 'assistant',
      content: json['content']?.toString() ?? '',
      jsonApp: rawJsonApp is Map
          ? rawJsonApp.map((key, value) => MapEntry(key.toString(), value))
          : null,
      action: json['action']?.toString(),
      failedJsonUrl: json['failedJsonUrl']?.toString(),
      jsonUrl: json['jsonUrl']?.toString(),
    );
  }
}

/// 纯字幕式覆层 — 半透明浮在屏幕底部，带窗口框和标题栏。
class ChatOverlay extends StatefulWidget {
  final List<ChatMessage> messages;
  final String? liveTranscript;
  final bool isListening;
  final bool isThinking;
  final bool isGeneratingJson;
  final String? generatingStatusMessage;
  final VoidCallback onClose;
  final VoidCallback? onClear;
  final ScrollController scrollController;
  final void Function(Map<String, dynamic> jsonConfig)? onRunJsonApp;
  final VoidCallback? onUploadCurrentApp;
  final void Function(String url)? onRetryDownload;
  final Future<void> Function(String url)? onDownloadAndRun;
  final VoidCallback? onRetryLastTurn; // worker 死了时的重试按钮

  // 多会话回调（由 designer_ball 注入；service 完成实际状态变更）
  final String activeSessionId;
  final List<SessionMeta> Function() getSessions;
  final List<AiProvider> providers;
  final List<AiAgent> agents;
  final String selectedProviderId;
  final String selectedAgentId;
  final bool agentLocked;
  final Future<void> Function()? onNewSession;
  final Future<void> Function(String sid)? onSwitchSession;
  final Future<void> Function(String providerId)? onSelectProvider;
  final Future<void> Function(String agentId)? onSelectAgent;
  final Future<void> Function(String providerId, String agentId)?
  onSelectProviderAgent;
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
    this.generatingStatusMessage, // null → i18n 默认值（chatStatusGenerating）
    required this.onClose,
    required this.scrollController,
    required this.activeSessionId,
    required this.getSessions,
    this.providers = const [],
    this.agents = const [],
    this.selectedProviderId = '',
    this.selectedAgentId = '',
    this.agentLocked = false,
    this.liveTranscript,
    this.onRunJsonApp,
    this.onClear,
    this.onUploadCurrentApp,
    this.onRetryDownload,
    this.onDownloadAndRun,
    this.onRetryLastTurn,
    this.onNewSession,
    this.onSwitchSession,
    this.onSelectProvider,
    this.onSelectAgent,
    this.onSelectProviderAgent,
    this.onDeleteSession,
    this.onRenameSession,
    this.onProbeAllSessionStatus,
    this.getNavigatorContext,
  });

  @override
  State<ChatOverlay> createState() => _ChatOverlayState();
}

enum _TopMenuKind { sessions, providers }

class _ChatOverlayState extends State<ChatOverlay> {
  double _offsetY = 0.0; // 窗口垂直偏移量

  // 下拉菜单 state：菜单作为 chat overlay 自己 Stack 内的一层渲染，
  // 这样能跟着拖动同步移动、保证 z-order 在字幕上面、再次点 chip 能切回关闭。
  // 不再用 showMenu (它走 root navigator overlay，物理位置在 chat overlay 下方)。
  _TopMenuKind? _openMenu;
  String? _expandedProviderAgentId;
  Future<Set<String>>? _statusProbeFuture;
  SessionMeta? _actionsSession;
  SessionMeta? _deleteConfirmSession;
  SessionMeta? _renameSession;
  TextEditingController? _renameController;
  bool _liveTranscriptScrollScheduled = false;

  @override
  void initState() {
    super.initState();
    _scheduleLiveTranscriptScrollIfNeeded();
  }

  @override
  void didUpdateWidget(covariant ChatOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.liveTranscript != oldWidget.liveTranscript ||
        widget.isListening != oldWidget.isListening) {
      _scheduleLiveTranscriptScrollIfNeeded();
    }
  }

  bool get _shouldFollowLiveTranscript =>
      widget.isListening && (widget.liveTranscript?.isNotEmpty ?? false);

  void _scheduleLiveTranscriptScrollIfNeeded() {
    if (!_shouldFollowLiveTranscript || _liveTranscriptScrollScheduled) return;
    _liveTranscriptScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _liveTranscriptScrollScheduled = false;
      if (!mounted || !_shouldFollowLiveTranscript) return;
      final controller = widget.scrollController;
      if (!controller.hasClients || !controller.position.hasContentDimensions) {
        _scheduleLiveTranscriptScrollIfNeeded();
        return;
      }
      final target = controller.position.maxScrollExtent;
      if (target.isFinite) controller.jumpTo(target);
    });
  }

  String _currentSessionTitle() {
    final defaultTitle = T.of(context).chatSessionDefaultTitle;
    final sid = widget.activeSessionId;
    if (sid.isEmpty) return defaultTitle;
    for (final s in widget.getSessions()) {
      if (s.id == sid) return s.displayTitle(maxVisualWidth: 8);
    }
    return defaultTitle;
  }

  void _toggleMenu(_TopMenuKind kind) {
    if (_openMenu == kind) {
      setState(() {
        _openMenu = null;
        _expandedProviderAgentId = null;
      });
    } else {
      // 每次打开重发起探活
      if (kind == _TopMenuKind.sessions) {
        _statusProbeFuture = widget.onProbeAllSessionStatus?.call();
      }
      setState(() {
        _openMenu = kind;
        _expandedProviderAgentId = null;
      });
    }
  }

  void _closeMenu() {
    if (_openMenu != null) {
      setState(() {
        _openMenu = null;
        _expandedProviderAgentId = null;
      });
    }
  }

  String _providerLabel() {
    for (final provider in widget.providers) {
      if (provider.id == widget.selectedProviderId) return provider.name;
    }
    return widget.selectedProviderId.isNotEmpty
        ? widget.selectedProviderId
        : 'Provider';
  }

  List<AiAgent> _agentsForProvider(AiProvider provider) {
    final ids = provider.supportedAgentIds.isEmpty
        ? const ['claude']
        : provider.supportedAgentIds;
    return ids
        .map((id) {
          for (final agent in widget.agents) {
            if (agent.id == id) return agent;
          }
          return AiAgent(id: id, name: id, description: '', configured: true);
        })
        .toList(growable: false);
  }

  bool _providerSupportsAgent(AiProvider provider, String agentId) {
    if (agentId.isEmpty) return true;
    final ids = provider.supportedAgentIds.isEmpty
        ? const ['claude']
        : provider.supportedAgentIds;
    return ids.contains(agentId);
  }

  String _agentLabelForProvider(AiProvider provider) {
    // 对话的 agent 是会话级单一运行时：凡是支持它的 provider 都显示这个 agent，
    // 而不是各 provider 各自记忆的默认（否则选了 deepseek+codex 后 minimax 仍显示 claude）。
    final selectedAgentId = widget.selectedAgentId;
    final agentId =
        (selectedAgentId.isNotEmpty &&
            _providerSupportsAgent(provider, selectedAgentId))
        ? selectedAgentId
        : AiChatService.selectedAgentForProvider(provider.id);
    for (final agent in widget.agents) {
      if (agent.id == agentId) return agent.name;
    }
    return agentId.isNotEmpty ? agentId : 'Agent';
  }

  void _openSessionActions(String sid) {
    final s = widget.getSessions().firstWhere(
      (x) => x.id == sid,
      orElse: () => SessionMeta(id: ''),
    );
    if (s.id.isEmpty) return;
    setState(() => _actionsSession = s);
  }

  void _closeSessionActions() {
    if (_actionsSession != null) {
      setState(() => _actionsSession = null);
    }
  }

  void _openRenameFromActions() {
    final session = _actionsSession;
    if (session == null) return;
    _renameController?.dispose();
    _renameController = TextEditingController(
      text: session.customTitle ?? session.firstMessage,
    );
    setState(() {
      _actionsSession = null;
      _renameSession = session;
    });
  }

  void _openDeleteFromActions() {
    final session = _actionsSession;
    if (session == null) return;
    setState(() {
      _actionsSession = null;
      _deleteConfirmSession = session;
    });
  }

  void _closeRename() {
    if (_renameSession != null) {
      setState(() => _renameSession = null);
    }
    _renameController?.dispose();
    _renameController = null;
  }

  Future<void> _confirmRename() async {
    final session = _renameSession;
    final newTitle = _renameController?.text;
    if (session == null || newTitle == null) return;
    _closeRename();
    await widget.onRenameSession?.call(session.id, newTitle);
  }

  @override
  void dispose() {
    _renameController?.dispose();
    super.dispose();
  }

  void _closeDeleteConfirmation() {
    if (_deleteConfirmSession != null) {
      setState(() => _deleteConfirmSession = null);
    }
  }

  Future<void> _confirmDeleteSession() async {
    final session = _deleteConfirmSession;
    if (session == null) return;
    setState(() => _deleteConfirmSession = null);
    await widget.onDeleteSession?.call(session.id);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final bottomPadding = MediaQuery.of(context).viewPadding.bottom;

    final visibleMessages = widget.messages
        .where((m) => m.content.isNotEmpty)
        .toList();
    final hasLive =
        widget.liveTranscript != null && widget.liveTranscript!.isNotEmpty;

    // 多会话场景下不再因"没消息"就整个 SizedBox.shrink —— 否则空 session 看不到 chip，
    // 没法切换回有内容的 session。chat overlay 永远渲染至少一条标题栏。

    // 顶部锚定：用 top 而非 bottom，content 变短只缩底部不让顶部跳来跳去
    final maxHeight = screen.height * 0.4;
    final containerTop =
        (screen.height - bottomPadding - 80 - maxHeight - _offsetY).clamp(
          0.0,
          screen.height - 60,
        );

    // 用 Positioned.fill 强制内部 Stack 占满 DesignerBall 外层 Stack，否则
    // 仅 Positioned 子节点的 Stack 会塌成 0×0，inner Positioned 的 top
    // 算出来贴到外层 Stack 顶（被灵动岛挡）
    return Positioned.fill(
      child: Stack(
        children: [
          // 1. 字幕容器（被 hardEdge 裁剪，内容不会跑出来）
          Positioned(
            left: 12,
            right: 12,
            top: containerTop,
            child: Container(
              constraints: BoxConstraints(maxHeight: maxHeight),
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
                        Icon(
                          Icons.chat_bubble_outline,
                          color: Colors.white.withValues(alpha: 0.5),
                          size: 14,
                        ),
                        const SizedBox(width: 6),
                        if (widget.onNewSession != null) ...[
                          _TitleBarButton(
                            icon: Icons.add_circle_outline,
                            onTap: () {
                              widget.onNewSession!();
                            },
                          ),
                          const SizedBox(width: 4),
                        ],
                        _SessionChip(
                          title: _currentSessionTitle(),
                          icon: Icons.forum_outlined,
                          width: 108,
                          maxTextWidth: 58,
                          onTap: () => _toggleMenu(_TopMenuKind.sessions),
                        ),
                        const SizedBox(width: 3),
                        _SessionChip(
                          title: _providerLabel(),
                          icon: Icons.cloud_outlined,
                          width: 108,
                          maxTextWidth: 58,
                          onTap:
                              widget.onSelectProvider != null &&
                                  widget.providers.isNotEmpty
                              ? () => _toggleMenu(_TopMenuKind.providers)
                              : null,
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
                                final maxOffset =
                                    screen.height -
                                    bottomPadding -
                                    200; // 至少保留200px在屏幕内
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
                        if (widget.onClear != null &&
                            visibleMessages.isNotEmpty)
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        shrinkWrap: true,
                        itemCount:
                            visibleMessages.length +
                            (hasLive ? 1 : 0) +
                            (widget.isThinking ? 1 : 0) +
                            (widget.isGeneratingJson ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (hasLive && index == visibleMessages.length) {
                            return _buildLine(
                              'you',
                              widget.liveTranscript!,
                              live: true,
                            );
                          }
                          if (widget.isThinking &&
                              index ==
                                  visibleMessages.length + (hasLive ? 1 : 0)) {
                            return _buildThinkingLine();
                          }
                          if (widget.isGeneratingJson &&
                              index ==
                                  visibleMessages.length +
                                      (hasLive ? 1 : 0) +
                                      (widget.isThinking ? 1 : 0)) {
                            return _buildGeneratingLine();
                          }
                          final msg = visibleMessages[index];
                          if (msg.action == 'UPLOAD_CURRENT_APP') {
                            return _buildActionLine(
                              msg.content,
                              T.of(context).chatActionUploadCurrentApp,
                              widget.onUploadCurrentApp,
                            );
                          }
                          if (msg.action == 'RETRY_LAST_TURN') {
                            return _buildActionLine(
                              msg.content,
                              T.of(context).retry,
                              widget.onRetryLastTurn,
                            );
                          }
                          if (msg.failedJsonUrl != null) {
                            return _buildRetryLine(
                              msg.content,
                              msg.failedJsonUrl!,
                            );
                          }
                          if (msg.jsonUrl != null) {
                            return _buildDownloadLine(
                              msg.content,
                              msg.jsonUrl!,
                            );
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
          ),
          // 2. 下拉菜单：作为 outer Stack 的兄弟节点而不是嵌在字幕容器里；
          //    这样既不会被 Clip.hardEdge 截掉、也不受字幕容器宽高变化影响
          if (_openMenu != null) ...[
            // backdrop 覆盖标题栏下方所有屏幕区域，点空白处关菜单
            Positioned(
              left: 0,
              right: 0,
              top: containerTop + 36,
              bottom: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeMenu,
                child: Container(color: Colors.black.withValues(alpha: 0.3)),
              ),
            ),
            // 菜单面板本体，锚定在标题栏正下方
            Positioned(
              top: containerTop + 40,
              left: 12 + 38, // chat overlay 左缘 12 + chip 在标题栏内的偏移 ~38
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: screen.width - 24 - 38 - 12,
                ),
                child: switch (_openMenu!) {
                  _TopMenuKind.sessions => _SessionDropdownPanel(
                    sessions: widget.getSessions(),
                    activeSessionId: widget.activeSessionId,
                    statusProbeFuture: _statusProbeFuture,
                    // 最多顶到屏幕底部留点边界
                    maxHeight:
                        screen.height - containerTop - 40 - bottomPadding - 20,
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
                      _openSessionActions(sid);
                    },
                  ),
                  _TopMenuKind.providers => _AiProviderDropdownPanel(
                    providers: widget.providers,
                    selectedProviderId: widget.selectedProviderId,
                    selectedAgentId: widget.selectedAgentId,
                    agentLocked: widget.agentLocked,
                    expandedProviderId: _expandedProviderAgentId,
                    agentLabelForProvider: _agentLabelForProvider,
                    agentsForProvider: _agentsForProvider,
                    providerSupportsSelectedAgent: (provider) =>
                        _providerSupportsAgent(
                          provider,
                          widget.selectedAgentId,
                        ),
                    maxHeight:
                        screen.height - containerTop - 40 - bottomPadding - 20,
                    onSelectProvider: (providerId) async {
                      _closeMenu();
                      await widget.onSelectProvider?.call(providerId);
                    },
                    onToggleProviderAgents: (providerId) {
                      setState(() {
                        _expandedProviderAgentId =
                            _expandedProviderAgentId == providerId
                            ? null
                            : providerId;
                      });
                    },
                    onSelectProviderAgent: (providerId, agentId) async {
                      _closeMenu();
                      if (widget.onSelectProviderAgent != null) {
                        await widget.onSelectProviderAgent!(
                          providerId,
                          agentId,
                        );
                      } else {
                        await widget.onSelectProvider?.call(providerId);
                        await widget.onSelectAgent?.call(agentId);
                      }
                    },
                  ),
                },
              ),
            ),
          ],
          if (_actionsSession != null)
            _SessionActionsLayer(
              session: _actionsSession!,
              onCancel: _closeSessionActions,
              onRename: _openRenameFromActions,
              onDelete: _openDeleteFromActions,
            ),
          if (_renameSession != null && _renameController != null)
            _RenameSessionLayer(
              session: _renameSession!,
              controller: _renameController!,
              onCancel: _closeRename,
              onConfirm: _confirmRename,
            ),
          if (_deleteConfirmSession != null)
            _DeleteSessionConfirmLayer(
              session: _deleteConfirmSession!,
              onCancel: _closeDeleteConfirmation,
              onConfirm: _confirmDeleteSession,
            ),
        ],
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
                  Text(
                    T.of(context).chatActionRetryDownloadJson,
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

  Widget _buildActionLine(
    String content,
    String buttonText,
    VoidCallback? onTap,
  ) {
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
                valueColor: AlwaysStoppedAnimation<Color>(
                  Colors.purpleAccent.shade100,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                widget.generatingStatusMessage ??
                    T.of(context).chatStatusGenerating,
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
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

/// 会话切换小标签 —— 点击触发 onTap，由调用方控制下拉菜单显隐
class _SessionChip extends StatelessWidget {
  final String title;
  final IconData icon;
  final double? width;
  final double maxTextWidth;
  final VoidCallback? onTap;

  const _SessionChip({
    required this.title,
    required this.icon,
    this.width,
    required this.maxTextWidth,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: width,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Colors.white.withValues(alpha: enabled ? 0.2 : 0.12),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: Colors.white.withValues(alpha: enabled ? 0.7 : 0.45),
                size: 12,
              ),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxTextWidth),
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.white.withValues(
                      alpha: enabled ? 0.85 : 0.55,
                    ),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.expand_more,
                color: Colors.white.withValues(alpha: enabled ? 0.5 : 0.25),
                size: 14,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionActionsLayer extends StatelessWidget {
  final SessionMeta session;
  final VoidCallback onCancel;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _SessionActionsLayer({
    required this.session,
    required this.onCancel,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return Positioned.fill(
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onCancel,
                child: Container(color: Colors.black.withValues(alpha: 0.42)),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12 + MediaQuery.of(context).viewPadding.bottom,
              child: SafeArea(
                top: false,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.16),
                      width: 0.8,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 24,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Text(
                          session.displayTitle(maxVisualWidth: 22),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      _SessionActionTile(
                        icon: Icons.edit_outlined,
                        label: t.chatSessionActionRename,
                        color: Colors.white,
                        onTap: onRename,
                      ),
                      _SessionActionTile(
                        icon: Icons.delete_outline,
                        label: t.chatSessionDeleteTitle,
                        color: Colors.redAccent,
                        onTap: onDelete,
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _SessionActionTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color, size: 21),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RenameSessionLayer extends StatelessWidget {
  final SessionMeta session;
  final TextEditingController controller;
  final VoidCallback onCancel;
  final Future<void> Function() onConfirm;

  const _RenameSessionLayer({
    required this.session,
    required this.controller,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return Positioned.fill(
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onCancel,
                child: Container(color: Colors.black.withValues(alpha: 0.48)),
              ),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.16),
                      width: 0.8,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 24,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.chatSessionRenameTitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: controller,
                          autofocus: true,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: t.chatSessionRenameHint,
                            hintStyle: const TextStyle(color: Colors.white38),
                            filled: true,
                            fillColor: Colors.white.withValues(alpha: 0.08),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(
                                color: Colors.white.withValues(alpha: 0.16),
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(
                                color: Colors.white.withValues(alpha: 0.16),
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                color: Colors.purpleAccent,
                              ),
                            ),
                          ),
                          onSubmitted: (_) => onConfirm(),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: onCancel,
                              child: Text(
                                t.cancel,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: onConfirm,
                              child: Text(t.save),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeleteSessionConfirmLayer extends StatelessWidget {
  final SessionMeta session;
  final VoidCallback onCancel;
  final Future<void> Function() onConfirm;

  const _DeleteSessionConfirmLayer({
    required this.session,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final t = T.of(context);
    return Positioned.fill(
      child: Material(
        color: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onCancel,
                child: Container(color: Colors.black.withValues(alpha: 0.48)),
              ),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2C2C2E),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.16),
                      width: 0.8,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 24,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.delete_outline,
                              color: Colors.redAccent,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                t.chatSessionDeleteTitle,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          T.fmt(t.chatSessionDeleteContent, {
                            'title': session.displayTitle(maxVisualWidth: 16),
                          }),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.76),
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: onCancel,
                              child: Text(
                                t.cancel,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: onConfirm,
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.redAccent,
                              ),
                              child: Text(t.delete),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.add_circle_outline,
                        color: Colors.purpleAccent,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        T.of(context).chatSessionMenuNew,
                        style: const TextStyle(
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
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          T.of(context).chatSessionMenuEmpty,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
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

class _AiProviderDropdownPanel extends StatelessWidget {
  final List<AiProvider> providers;
  final String selectedProviderId;
  final String selectedAgentId;
  final bool agentLocked;
  final String? expandedProviderId;
  final String Function(AiProvider provider) agentLabelForProvider;
  final List<AiAgent> Function(AiProvider provider) agentsForProvider;
  final bool Function(AiProvider provider) providerSupportsSelectedAgent;
  final double maxHeight;
  final void Function(String providerId) onSelectProvider;
  final void Function(String providerId) onToggleProviderAgents;
  final void Function(String providerId, String agentId) onSelectProviderAgent;

  const _AiProviderDropdownPanel({
    required this.providers,
    required this.selectedProviderId,
    required this.selectedAgentId,
    required this.agentLocked,
    required this.expandedProviderId,
    required this.agentLabelForProvider,
    required this.agentsForProvider,
    required this.providerSupportsSelectedAgent,
    required this.maxHeight,
    required this.onSelectProvider,
    required this.onToggleProviderAgents,
    required this.onSelectProviderAgent,
  });

  @override
  Widget build(BuildContext context) {
    return _AiRouteDropdownFrame(
      width: 276,
      maxHeight: maxHeight,
      emptyText: 'No providers',
      isEmpty: providers.isEmpty,
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: providers.length,
        itemBuilder: (ctx, i) {
          final provider = providers[i];
          final selected = provider.id == selectedProviderId;
          final expanded = expandedProviderId == provider.id;
          final providerAgents = agentsForProvider(provider);
          // 展开某个 provider 的 agent 列表时，凡支持本次对话 agent 的都高亮该 agent，
          // 与行内 chip 标签保持一致（会话级单一 agent）。
          final providerAgentId = selected
              ? selectedAgentId
              : (selectedAgentId.isNotEmpty &&
                        providerSupportsSelectedAgent(provider)
                    ? selectedAgentId
                    : AiChatService.selectedAgentForProvider(provider.id));
          final enabled =
              selected ||
              !agentLocked ||
              providerSupportsSelectedAgent(provider);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AiProviderMenuRow(
                provider: provider,
                selected: selected,
                enabled: enabled,
                agentLabel: agentLabelForProvider(provider),
                agentLocked: agentLocked,
                expanded: expanded,
                onSelectProvider: () {
                  if (enabled) onSelectProvider(provider.id);
                },
                onToggleAgents: () {
                  if (enabled) onToggleProviderAgents(provider.id);
                },
              ),
              if (expanded)
                _AiAgentInlineList(
                  agents: providerAgents,
                  selectedAgentId: providerAgentId,
                  onSelectAgent: (agentId) =>
                      onSelectProviderAgent(provider.id, agentId),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _AiProviderMenuRow extends StatelessWidget {
  final AiProvider provider;
  final bool selected;
  final bool enabled;
  final String agentLabel;
  final bool agentLocked;
  final bool expanded;
  final VoidCallback onSelectProvider;
  final VoidCallback onToggleAgents;

  const _AiProviderMenuRow({
    required this.provider,
    required this.selected,
    required this.enabled,
    required this.agentLabel,
    required this.agentLocked,
    required this.expanded,
    required this.onSelectProvider,
    required this.onToggleAgents,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = provider.defaultModel.isNotEmpty
        ? provider.defaultModel
        : provider.id;
    final primaryColor = enabled ? Colors.white : Colors.white38;
    final secondaryColor = enabled ? Colors.white54 : Colors.white30;
    final iconColor = selected
        ? Colors.purpleAccent
        : (enabled ? Colors.white54 : Colors.white30);
    return Container(
      color: selected ? Colors.white.withValues(alpha: 0.06) : null,
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: enabled ? onSelectProvider : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.cloud_outlined, color: iconColor, size: 17),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            provider.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: primaryColor,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: secondaryColor,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _AgentSelectorChip(
            label: agentLabel,
            locked: agentLocked || !enabled,
            expanded: expanded,
            onTap: agentLocked || !enabled ? null : onToggleAgents,
          ),
          if (selected) ...[
            const SizedBox(width: 6),
            const Icon(Icons.check, color: Colors.purpleAccent, size: 15),
          ],
        ],
      ),
    );
  }
}

class _AgentSelectorChip extends StatelessWidget {
  final String label;
  final bool locked;
  final bool expanded;
  final VoidCallback? onTap;

  const _AgentSelectorChip({
    required this.label,
    required this.locked,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 88),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: enabled ? 0.12 : 0.07),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(
              color: Colors.white.withValues(alpha: enabled ? 0.18 : 0.1),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                locked ? Icons.lock_outline : Icons.smart_toy_outlined,
                color: Colors.white.withValues(alpha: enabled ? 0.7 : 0.45),
                size: 11,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: enabled ? 0.82 : 0.5),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!locked) ...[
                const SizedBox(width: 2),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white.withValues(alpha: 0.55),
                  size: 13,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AiAgentInlineList extends StatelessWidget {
  final List<AiAgent> agents;
  final String selectedAgentId;
  final void Function(String agentId) onSelectAgent;

  const _AiAgentInlineList({
    required this.agents,
    required this.selectedAgentId,
    required this.onSelectAgent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: 0.18),
      padding: const EdgeInsets.only(left: 32, right: 8, bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: agents
            .map((agent) {
              final selected = agent.id == selectedAgentId;
              return _AiRouteMenuRow(
                icon: Icons.smart_toy_outlined,
                title: agent.name,
                subtitle: agent.description.isNotEmpty
                    ? agent.description
                    : agent.id,
                selected: selected,
                onTap: () => onSelectAgent(agent.id),
                dense: true,
              );
            })
            .toList(growable: false),
      ),
    );
  }
}

class _AiRouteDropdownFrame extends StatelessWidget {
  final double width;
  final double maxHeight;
  final bool isEmpty;
  final String emptyText;
  final Widget child;

  const _AiRouteDropdownFrame({
    required this.width,
    required this.maxHeight,
    required this.isEmpty,
    required this.emptyText,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      elevation: 8,
      borderRadius: BorderRadius.circular(10),
      shadowColor: Colors.black.withValues(alpha: 0.5),
      child: Container(
        width: width,
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
          child: isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Text(
                    emptyText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                )
              : child,
        ),
      ),
    );
  }
}

class _AiRouteMenuRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;

  const _AiRouteMenuRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? Colors.white.withValues(alpha: 0.06) : null,
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 8 : 12,
          vertical: dense ? 7 : 10,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: selected ? Colors.purpleAccent : Colors.white54,
              size: 17,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check, color: Colors.purpleAccent, size: 16),
          ],
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
                        fontWeight: isActive
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _relativeTime(context, session.updatedAt),
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
                  child: Icon(Icons.more_vert, size: 18, color: Colors.white54),
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
    } else if (session.lastKnownStatus == 'queued') {
      c = const Color(0xFFFFC107);
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

  String _relativeTime(BuildContext context, int ms) {
    final t = T.of(context);
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    if (diff < 60 * 1000) return t.chatTimeJustNow;
    if (diff < 60 * 60 * 1000) {
      return T.fmt(t.chatTimeMinutesAgo, {'n': diff ~/ (60 * 1000)});
    }
    if (diff < 24 * 60 * 60 * 1000) {
      return T.fmt(t.chatTimeHoursAgo, {'n': diff ~/ (60 * 60 * 1000)});
    }
    return T.fmt(t.chatTimeDaysAgo, {'n': diff ~/ (24 * 60 * 60 * 1000)});
  }
}

class _DownloadRunButton extends StatefulWidget {
  final String url;
  final Future<void> Function(String url)? onDownloadAndRun;

  const _DownloadRunButton({required this.url, this.onDownloadAndRun});

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
    final t = T.of(context);
    final buttonLabel = _isLoading
        ? t.chatDownloadStateDownloading
        : (_error == null ? t.chatDownloadStateRun : t.chatDownloadStateRetry);

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
