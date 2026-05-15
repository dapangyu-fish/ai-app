// Grid 控件
// 支持: source (数据源), item_template (列表项模板),
//       crossAxisCount (列数, 默认 2),
//       crossAxisSpacing, mainAxisSpacing, spacing (同时设置两个),
//       childAspectRatio (子项宽高比, 默认 1),
//       padding, shrinkWrap, emptyText
import 'package:flutter/material.dart';
import 'base_widget.dart';
import '../interpreter.dart';
import '../../i18n/framework_strings.dart';

class JsonGridWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final sourceRaw = json['source'];
    List<dynamic> items = [];
    if (sourceRaw is String) {
      final resolved = interpreter.resolveExpression(sourceRaw);
      if (resolved is List) items = resolved;
    } else if (sourceRaw is List) {
      items = sourceRaw;
    }

    final itemTemplate = json['item_template'] as Map<String, dynamic>?;
    final crossAxisCount = (json['crossAxisCount'] as num?)?.toInt() ?? 2;
    final spacing = (json['spacing'] as num?)?.toDouble();
    final crossAxisSpacing =
        (json['crossAxisSpacing'] as num?)?.toDouble() ?? spacing ?? 8;
    final mainAxisSpacing =
        (json['mainAxisSpacing'] as num?)?.toDouble() ?? spacing ?? 8;
    final childAspectRatio =
        (json['childAspectRatio'] as num?)?.toDouble() ?? 1.0;
    final padding = (json['padding'] as num?)?.toDouble() ?? 0;
    final shrinkWrap = json['shrinkWrap'] == true;
    final emptyText = interpreter.resolveTemplate(
        json['emptyText']?.toString() ?? T.of(context).empty);
    // 跨屏导航时保留滚动位置（同 list 的 key 字段）
    final keyStr = json['key']?.toString();
    final pageKey = keyStr != null && keyStr.isNotEmpty
        ? PageStorageKey<String>(keyStr)
        : null;

    if (itemTemplate == null || items.isEmpty) {
      final empty = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.grid_off,
                  size: 40,
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.5)),
              const SizedBox(height: 8),
              Text(
                items.isEmpty ? emptyText : T.of(context).widgetMissingItemTemplate,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
      return shrinkWrap ? empty : Expanded(child: empty);
    }

    final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: crossAxisCount,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
      childAspectRatio: childAspectRatio,
    );

    final grid = GridView.builder(
      key: pageKey,
      padding: EdgeInsets.all(padding),
      shrinkWrap: shrinkWrap,
      physics:
          shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      gridDelegate: gridDelegate,
      itemCount: items.length,
      itemBuilder: (ctx, index) => interpreter.buildWidgetInLoopContext(
        context: ctx,
        json: itemTemplate,
        loopItem: items[index],
        loopIndex: index,
      ),
    );

    return shrinkWrap ? grid : Expanded(child: grid);
  }
}
