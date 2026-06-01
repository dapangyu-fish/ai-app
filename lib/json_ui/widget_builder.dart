// Widget 构建器（总入口）
// 根据 JSON 节点的 type 字段分发到对应的控件构建器
import 'package:flutter/material.dart';
import 'interpreter.dart';
import '../i18n/framework_strings.dart';
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
import 'widgets/chip_widget.dart';
import 'widgets/badge_widget.dart';
import 'widgets/avatar_widget.dart';
import 'widgets/rich_text_widget.dart';
import 'widgets/progress_widget.dart';
import 'widgets/inkwell_widget.dart';
import 'widgets/gesture_detector_widget.dart';
import 'widgets/dismissible_widget.dart';
import 'widgets/draggable_widget.dart';
import 'widgets/refresh_widget.dart';
import 'widgets/tab_view_widget.dart';
import 'widgets/app_bar_widget.dart';
import 'widgets/webview_widget.dart';
import 'widgets/qr_code_widget.dart';
import 'widgets/chart_widget.dart';
import 'widgets/map_widget.dart';
import 'widgets/camera_widget.dart';
import 'widgets/skeleton_widget.dart';
import 'widgets/reorderable_list_widget.dart';
import 'widgets/flame_game_widget.dart';
import 'widgets/analog_stick_widget.dart';
import 'widgets/floating_layer_widget.dart';
import 'widgets/transform_widget.dart';
import 'widgets/material_button_widget.dart';
import 'widgets/positioned_widget.dart';
import 'widgets/cupertino_refresh_list_widget.dart';

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
    'chip': JsonChipWidget(),
    'badge': JsonBadgeWidget(),
    'avatar': JsonAvatarWidget(),
    'rich_text': JsonRichTextWidget(),
    'progress': JsonProgressWidget(),
    'inkwell': JsonInkWellWidget(),
    'gesture_detector': JsonGestureDetectorWidget(),
    'dismissible': JsonDismissibleWidget(),
    'draggable': JsonDraggableWidget(),
    'refresh': JsonRefreshWidget(),
    'tab_view': JsonTabViewWidget(),
    'app_bar': JsonAppBarWidget(),
    'webview': JsonWebViewWidget(),
    'qr_code': JsonQrCodeWidget(),
    'chart': JsonChartWidget(),
    'map': JsonMapWidget(),
    'camera': JsonCameraWidget(),
    'skeleton': JsonSkeletonWidget(),
    'reorderable_list': JsonReorderableListWidget(),
    'flame_game': JsonFlameGameWidget(),
    'analog_stick': JsonAnalogStickWidget(),
    'floating_layer': JsonFloatingLayerWidget(),
    'transform': JsonTransformWidget(),
    'material_button': JsonMaterialButtonWidget(),
    'positioned': JsonPositionedWidget(),
    'cupertino_refresh_list': JsonCupertinoRefreshListWidget(),
  };

  /// 根据 JSON 配置构建对应的 Flutter Widget
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    if (!_isVisible(json['visible'], interpreter)) {
      return const SizedBox.shrink();
    }

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
        color: Theme.of(
          context,
        ).colorScheme.errorContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        T.fmt(T.of(context).widgetUnknownTypeWith, {'type': type}),
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontSize: 12,
        ),
      ),
    );
  }

  bool _isVisible(dynamic raw, JsonInterpreter interpreter) {
    if (raw == null) return true;
    dynamic value = raw;
    if (raw is Map<String, dynamic> && interpreter.looksLikeJsonLogic(raw)) {
      value = interpreter.evaluateJsonLogicWithLocals(raw, const {});
    } else {
      value = interpreter.resolveExpression(raw);
    }
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized.isNotEmpty &&
          normalized != 'false' &&
          normalized != '0' &&
          normalized != 'null';
    }
    return value != null;
  }
}
