// AppBar 控件 — 独立的应用栏，可作为普通 widget 嵌入 column
// 支持: title, backgroundColor, color (前景色), elevation, centerTitle,
//       leading ({icon, action}), actions ([{icon, action}])
//
// 提示：作为 Scaffold 的 appBar 槽位时建议用 screen.appBar 配置
import 'package:flutter/material.dart';
import 'base_widget.dart';
import 'icon_registry.dart';
import '../interpreter.dart';

class JsonAppBarWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    return buildAppBar(context, json, interpreter);
  }
}

/// 共享构建器，screen.appBar 配置也走这个函数
PreferredSizeWidget buildAppBar(
  BuildContext context,
  Map<String, dynamic> json,
  JsonInterpreter interpreter,
) {
  final title = interpreter.resolveTemplate(json['title']?.toString() ?? '');
  final centerTitle = json['centerTitle'] != false;
  final elevation = (json['elevation'] as num?)?.toDouble();
  final rawBg = json['backgroundColor']?.toString();
  final bg = _parseColor(
    rawBg != null ? interpreter.resolveTemplate(rawBg) : null,
  );
  final rawFg = json['color']?.toString();
  final fg = _parseColor(
    rawFg != null ? interpreter.resolveTemplate(rawFg) : null,
  );
  final rawImage = json['backgroundImage']?.toString();
  final backgroundImage = rawImage != null
      ? interpreter.resolveTemplate(rawImage)
      : null;
  final height = (json['height'] as num?)?.toDouble();

  Widget? leading;
  final leadingDef = json['leading'];
  if (leadingDef is Map<String, dynamic>) {
    final iconName = leadingDef['icon']?.toString();
    final iconData = iconName != null ? IconRegistry.get(iconName) : null;
    final action = leadingDef['action'] as Map<String, dynamic>?;
    leading = IconButton(
      icon: Icon(iconData ?? Icons.arrow_back),
      onPressed: action != null
          ? () => interpreter.executeAction(action, context)
          : null,
    );
  }

  final actionWidgets = <Widget>[];
  final rawActions = json['actions'];
  if (rawActions is List) {
    for (final a in rawActions) {
      if (a is Map<String, dynamic>) {
        final iconName = a['icon']?.toString();
        final iconData = iconName != null ? IconRegistry.get(iconName) : null;
        final action = a['action'] as Map<String, dynamic>?;
        actionWidgets.add(
          IconButton(
            icon: Icon(iconData ?? Icons.more_vert),
            onPressed: action != null
                ? () => interpreter.executeAction(action, context)
                : null,
          ),
        );
      }
    }
  }

  if (backgroundImage != null && backgroundImage.isNotEmpty) {
    final appBarHeight = height ?? kToolbarHeight * 3;
    return PreferredSize(
      preferredSize: Size.fromHeight(appBarHeight),
      child: Stack(
        children: [
          Positioned.fill(child: _buildImage(backgroundImage, appBarHeight)),
          if (leadingDef != false)
            SafeArea(
              child:
                  leading ??
                  IconButton(
                    color: fg ?? Colors.white,
                    icon: const Icon(Icons.arrow_back_ios),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
            ),
        ],
      ),
    );
  }

  return AppBar(
    title: title.isNotEmpty ? Text(title) : null,
    centerTitle: centerTitle,
    elevation: elevation,
    backgroundColor: bg,
    foregroundColor: fg,
    leading: leading,
    actions: actionWidgets.isEmpty ? null : actionWidgets,
  );
}

Widget _buildImage(String source, double height) {
  if (source.startsWith('http://') || source.startsWith('https://')) {
    return Image.network(
      source,
      fit: BoxFit.cover,
      width: double.infinity,
      height: height,
    );
  }
  return Image.asset(
    source,
    fit: BoxFit.cover,
    width: double.infinity,
    height: height,
  );
}

Color? _parseColor(String? colorStr) {
  if (colorStr == null || !colorStr.startsWith('#')) return null;
  final hex = colorStr.replaceFirst('#', '');
  if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
  if (hex.length == 8) return Color(int.parse(hex, radix: 16));
  return null;
}
