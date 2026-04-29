// TabView 控件 — 单 widget 包含 TabBar + TabBarView
// 支持: tabs ([{label, icon?, content}]),
//       initialIndex (默认 0), color (选中颜色), backgroundColor (TabBar 背景色),
//       isScrollable (默认 false), onTabChange action, height (TabBarView 必须明确高度)
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'icon_registry.dart';
import 'action_helper.dart';
import '../interpreter.dart';

class JsonTabViewWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawTabs = json['tabs'];
    if (rawTabs is! List || rawTabs.isEmpty) {
      return const SizedBox.shrink();
    }

    final initialIndex = (json['initialIndex'] as num?)?.toInt() ?? 0;
    final isScrollable = json['isScrollable'] == true;
    final rawColor = json['color']?.toString();
    final color = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);
    final rawBg = json['backgroundColor']?.toString();
    final bg = _parseColor(
        rawBg != null ? interpreter.resolveTemplate(rawBg) : null);
    // 在循环上下文里预解析（构建后 loop 上下文会被 pop）
    final onTabChangeDef =
        resolveActionAtBuildTime(json['onTabChange'], interpreter);
    final height = (json['height'] as num?)?.toDouble() ?? 400;

    final tabs = <Tab>[];
    final contents = <Widget>[];
    for (final t in rawTabs) {
      if (t is Map<String, dynamic>) {
        final label = interpreter.resolveTemplate(t['label']?.toString() ?? '');
        final iconName = t['icon']?.toString();
        final iconData = iconName != null ? IconRegistry.get(iconName) : null;
        tabs.add(Tab(
          text: label,
          icon: iconData != null ? Icon(iconData) : null,
        ));
        final content = t['content'];
        if (content is Map<String, dynamic>) {
          contents.add(interpreter.buildWidget(context, content));
        } else {
          contents.add(const SizedBox.shrink());
        }
      }
    }

    return _TabViewBody(
      tabs: tabs,
      contents: contents,
      initialIndex: initialIndex.clamp(0, tabs.length - 1),
      isScrollable: isScrollable,
      labelColor: color,
      indicatorColor: color,
      backgroundColor: bg,
      height: height,
      onTabChangeDef: onTabChangeDef is Map<String, dynamic>
          ? onTabChangeDef
          : null,
      interpreter: interpreter,
    );
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}

/// StatefulWidget 用 TabController + 在 dispose 时移除 listener，避免泄漏
class _TabViewBody extends StatefulWidget {
  final List<Tab> tabs;
  final List<Widget> contents;
  final int initialIndex;
  final bool isScrollable;
  final Color? labelColor;
  final Color? indicatorColor;
  final Color? backgroundColor;
  final double height;
  final Map<String, dynamic>? onTabChangeDef;
  final JsonInterpreter interpreter;

  const _TabViewBody({
    required this.tabs,
    required this.contents,
    required this.initialIndex,
    required this.isScrollable,
    required this.labelColor,
    required this.indicatorColor,
    required this.backgroundColor,
    required this.height,
    required this.onTabChangeDef,
    required this.interpreter,
  });

  @override
  State<_TabViewBody> createState() => _TabViewBodyState();
}

class _TabViewBodyState extends State<_TabViewBody>
    with SingleTickerProviderStateMixin {
  late TabController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TabController(
      length: widget.tabs.length,
      initialIndex: widget.initialIndex,
      vsync: this,
    );
    if (widget.onTabChangeDef != null) {
      _controller.addListener(_onTabChange);
    }
  }

  void _onTabChange() {
    if (_controller.indexIsChanging) return;
    final def = widget.onTabChangeDef;
    if (def != null && context.mounted) {
      widget.interpreter.executeAction(def, context);
    }
  }

  @override
  void dispose() {
    if (widget.onTabChangeDef != null) {
      _controller.removeListener(_onTabChange);
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          color: widget.backgroundColor,
          child: TabBar(
            controller: _controller,
            tabs: widget.tabs,
            isScrollable: widget.isScrollable,
            labelColor: widget.labelColor,
            indicatorColor: widget.indicatorColor,
          ),
        ),
        SizedBox(
          height: widget.height,
          child: TabBarView(
            controller: _controller,
            children: widget.contents,
          ),
        ),
      ],
    );
  }
}
