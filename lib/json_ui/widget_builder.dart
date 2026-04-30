// Widget 构建器（总入口）
// 根据 JSON 节点的 type 字段分发到对应的控件构建器
import 'package:flutter/material.dart';
import 'interpreter.dart';
import 'widgets/text_widget.dart';
import 'widgets/button_widget.dart';
import 'widgets/input_widget.dart';
import 'widgets/list_widget.dart';
import 'widgets/container_widget.dart';
import 'widgets/divider_widget.dart';
import 'widgets/image_widget.dart';
import 'widgets/image_picker_widget.dart';
import 'widgets/spacer_widget.dart';
import 'widgets/switch_widget.dart';
import 'widgets/video_widget.dart';
import 'widgets/ref_widget.dart';
import 'widgets/icon_widget.dart';
import 'widgets/card_widget.dart';
import 'widgets/checkbox_widget.dart';
import 'widgets/expanded_widget.dart';
import 'widgets/loading_widget.dart';
import 'widgets/dropdown_widget.dart';
import 'widgets/radio_widget.dart';
import 'widgets/wrap_widget.dart';
import 'widgets/grid_widget.dart';
import 'widgets/padding_widget.dart';
import 'widgets/center_widget.dart';
import 'widgets/align_widget.dart';
import 'widgets/flexible_widget.dart';
import 'widgets/stack_widget.dart';
import 'widgets/slider_widget.dart';
import 'widgets/date_picker_widget.dart';
import 'widgets/time_picker_widget.dart';
import 'widgets/tooltip_widget.dart';

class JsonWidgetBuilder {
  // 控件注册表：type → 构建器实例
  static final Map<String, dynamic> _builders = {
    'text': JsonTextWidget(),
    'button': JsonButtonWidget(),
    'input': JsonInputWidget(),
    'list': JsonListWidget(),
    'container': JsonContainerWidget(),
    'divider': JsonDividerWidget(),
    'image': JsonImageWidget(),
    'image_picker': JsonImagePickerWidget(),
    'spacer': JsonSpacerWidget(),
    'switch': JsonSwitchWidget(),
    'video': JsonVideoWidget(),
    'ref': JsonRefWidget(),
    'icon': JsonIconWidget(),
    'card': JsonCardWidget(),
    'checkbox': JsonCheckboxWidget(),
    'expanded': JsonExpandedWidget(),
    'loading': JsonLoadingWidget(),
    'dropdown': JsonDropdownWidget(),
    'radio': JsonRadioWidget(),
    'wrap': JsonWrapWidget(),
    'grid': JsonGridWidget(),
    'padding': JsonPaddingWidget(),
    'center': JsonCenterWidget(),
    'align': JsonAlignWidget(),
    'flexible': JsonFlexibleWidget(),
    'stack': JsonStackWidget(),
    'slider': JsonSliderWidget(),
    'date_picker': JsonDatePickerWidget(),
    'time_picker': JsonTimePickerWidget(),
    'tooltip': JsonTooltipWidget(),
  };

  /// 根据 JSON 配置构建对应的 Flutter Widget
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final type = json['type'] as String?;

    if (type == null) {
      return const SizedBox.shrink();
    }

    final builder = _builders[type];
    if (builder != null) {
      return builder.build(context, json, interpreter);
    }

    // 未知类型，显示占位提示
    return Container(
      padding: const EdgeInsets.all(8),
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '未知控件类型: $type',
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontSize: 12,
        ),
      ),
    );
  }
}
