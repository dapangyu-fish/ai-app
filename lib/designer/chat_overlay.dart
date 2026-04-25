import 'package:flutter/material.dart';
import 'ai_chat_service.dart';

/// 对话消息
class ChatMessage {
  final String role; // 'user' | 'assistant' | 'system'
  final String content;
  final Map<String, dynamic>? jsonApp; // AI 生成的 JSON-APP
  final String? action; // 客户端动作，例如 'UPLOAD_CURRENT_APP'
  final String? failedJsonUrl; // 下载失败的 URL
  ChatMessage({required this.role, required this.content, this.jsonApp, this.action, this.failedJsonUrl});
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
  final void Function(String providerId)? onProviderChanged;
  final VoidCallback? onUploadCurrentApp;
  final void Function(String url)? onRetryDownload;

  const ChatOverlay({
    super.key,
    required this.messages,
    required this.isListening,
    required this.isThinking,
    this.isGeneratingJson = false,
    this.generatingStatusMessage = '正在生成代码...',
    required this.onClose,
    required this.scrollController,
    this.liveTranscript,
    this.onRunJsonApp,
    this.onClear,
    this.onProviderChanged,
    this.onUploadCurrentApp,
    this.onRetryDownload,
  });

  @override
  State<ChatOverlay> createState() => _ChatOverlayState();
}

class _ChatOverlayState extends State<ChatOverlay> {
  double _offsetY = 0.0; // 窗口垂直偏移量

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
                  Text(
                    '对话',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (AiChatService.providers.length > 1) ...[
                    const SizedBox(width: 8),
                    _ProviderChip(
                      providers: AiChatService.providers,
                      selectedId: AiChatService.selectedProvider,
                      onChanged: widget.onProviderChanged,
                    ),
                  ],
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
                    if (msg.failedJsonUrl != null) {
                      return _buildRetryLine(msg.content, msg.failedJsonUrl!);
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

/// 供应商选择小标签 — 点击弹出切换菜单
class _ProviderChip extends StatelessWidget {
  final List<AiProvider> providers;
  final String selectedId;
  final void Function(String providerId)? onChanged;

  const _ProviderChip({
    required this.providers,
    required this.selectedId,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final current = providers
        .where((p) => p.id == selectedId)
        .firstOrNull;
    final label = current?.name ?? selectedId;

    return GestureDetector(
      onTap: () => _showMenu(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
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
            Icon(Icons.smart_toy,
                color: Colors.white.withValues(alpha: 0.6), size: 11),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more,
                color: Colors.white.withValues(alpha: 0.4), size: 12),
          ],
        ),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    final RenderBox box = context.findRenderObject() as RenderBox;
    final offset = box.localToGlobal(Offset.zero);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        offset.dx,
        offset.dy + box.size.height + 4,
        offset.dx + box.size.width,
        0,
      ),
      items: providers.map((p) {
        return PopupMenuItem<String>(
          value: p.id,
          child: Row(
            children: [
              if (p.id == selectedId)
                const Icon(Icons.check, size: 16, color: Colors.green)
              else
                const SizedBox(width: 16),
              const SizedBox(width: 8),
              Text(p.name),
            ],
          ),
        );
      }).toList(),
    ).then((value) {
      if (value != null && value != selectedId) {
        onChanged?.call(value);
      }
    });
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
