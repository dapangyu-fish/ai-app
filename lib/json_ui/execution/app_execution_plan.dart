import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'state_schema.dart';
import 'template_plan.dart';

sealed class ValuePlan {
  const ValuePlan({required this.sourcePath, required this.globalDependencies});

  final String sourcePath;
  final Set<String> globalDependencies;
}

final class ConstantValuePlan extends ValuePlan {
  const ConstantValuePlan({required this.value, required super.sourcePath})
    : super(globalDependencies: const <String>{});

  final dynamic value;
}

final class TemplateValuePlan extends ValuePlan {
  TemplateValuePlan({required this.template, required super.sourcePath})
    : super(globalDependencies: template.globalDependencies);

  final TemplatePlan template;
}

final class ListValuePlan extends ValuePlan {
  ListValuePlan({
    required this.source,
    required this.items,
    required super.sourcePath,
  }) : super(
         globalDependencies: Set<String>.unmodifiable(
           items.expand((item) => item.globalDependencies),
         ),
       );

  final List<dynamic> source;
  final List<ValuePlan> items;
}

final class MapValuePlan extends ValuePlan {
  MapValuePlan({
    required this.source,
    required this.values,
    required this.isJsonLogic,
    required super.sourcePath,
  }) : super(
         globalDependencies: Set<String>.unmodifiable(
           values.values.expand((value) => value.globalDependencies),
         ),
       );

  final Map<String, dynamic> source;
  final Map<String, ValuePlan> values;
  final bool isJsonLogic;
}

enum ActionPlanKind { call, navigate, back, fallback }

final class ActionPlan {
  const ActionPlan({
    required this.source,
    required this.sourcePath,
    required this.kind,
    required this.callTarget,
    required this.arguments,
    required this.assignPath,
    required this.screenId,
  });

  final Map<String, dynamic> source;
  final String sourcePath;
  final ActionPlanKind kind;
  final String? callTarget;
  final MapValuePlan? arguments;
  final String? assignPath;
  final String? screenId;
}

final class WidgetPlan {
  const WidgetPlan({
    required this.source,
    required this.sourcePath,
    required this.type,
    required this.visible,
    required this.position,
    required this.globalDependencies,
  });

  final Map<String, dynamic> source;
  final String sourcePath;
  final String type;
  final ValuePlan? visible;
  final ValuePlan? position;

  /// Conservative first version: all executable values below the widget.
  ///
  /// Later widget-specific compilers can narrow this to render-time bindings
  /// and exclude event-only action arguments.
  final Set<String> globalDependencies;
}

final class ScreenPlan {
  const ScreenPlan({
    required this.source,
    required this.sourcePath,
    required this.id,
  });

  final Map<String, dynamic> source;
  final String sourcePath;
  final String id;
}

final class AppExecutionPlanStats {
  const AppExecutionPlanStats({
    required this.templateCount,
    required this.valuePlanCount,
    required this.actionCount,
    required this.widgetCount,
    required this.screenCount,
    required this.stateSlotCount,
  });

  final int templateCount;
  final int valuePlanCount;
  final int actionCount;
  final int widgetCount;
  final int screenCount;
  final int stateSlotCount;
}

/// Immutable load-time plan for one dynamic JSON App.
///
/// JSON remains the source and fallback. The plan binds repeated syntax to
/// typed Dart objects and integer state slots without producing executable
/// machine code, so a new JSON can be compiled after download on every Flutter
/// target, including iOS.
final class AppExecutionPlan {
  AppExecutionPlan._({
    required this.abi,
    required this.sourceHash,
    required this.hasStableSourceHash,
    required this.stateSchema,
    required this.templates,
    required Map<Object, ValuePlan> valuePlans,
    required Map<Map<String, dynamic>, ActionPlan> actionPlans,
    required Map<Map<String, dynamic>, WidgetPlan> widgetPlans,
    required this.screens,
    required this.stats,
  }) : _valuePlans = valuePlans,
       _actionPlans = actionPlans,
       _widgetPlans = widgetPlans;

  static const int currentAbi = 1;

  factory AppExecutionPlan.compile(
    Map<String, dynamic> config, {
    required Set<String> knownJsonLogicOperators,
    required Set<String> knownWidgetTypes,
  }) {
    return _AppExecutionPlanCompiler(
      config: config,
      knownJsonLogicOperators: knownJsonLogicOperators,
      knownWidgetTypes: knownWidgetTypes,
    ).compile();
  }

  final int abi;
  final String sourceHash;
  final bool hasStableSourceHash;
  final StateSchema stateSchema;
  final Map<String, TemplatePlan> templates;
  final Map<Object, ValuePlan> _valuePlans;
  final Map<Map<String, dynamic>, ActionPlan> _actionPlans;
  final Map<Map<String, dynamic>, WidgetPlan> _widgetPlans;
  final Map<String, ScreenPlan> screens;
  final AppExecutionPlanStats stats;

  TemplatePlan? templateFor(String source) => templates[source];

  ValuePlan? valuePlanFor(Object source) => _valuePlans[source];

  ActionPlan? actionPlanFor(Map<String, dynamic> source) =>
      _actionPlans[source];

  WidgetPlan? widgetPlanFor(Map<String, dynamic> source) =>
      _widgetPlans[source];
}

final class _AppExecutionPlanCompiler {
  _AppExecutionPlanCompiler({
    required this.config,
    required this.knownJsonLogicOperators,
    required this.knownWidgetTypes,
  }) : _stateSchema = StateSchemaBuilder(
         (config['global'] as Map<String, dynamic>?)?['variables']
                 as Map<String, dynamic>? ??
             const <String, dynamic>{},
       );

  final Map<String, dynamic> config;
  final Set<String> knownJsonLogicOperators;
  final Set<String> knownWidgetTypes;
  final StateSchemaBuilder _stateSchema;
  final LinkedHashMap<String, TemplatePlan> _templates =
      LinkedHashMap<String, TemplatePlan>();
  final HashMap<Object, ValuePlan> _valuePlans =
      HashMap<Object, ValuePlan>.identity();
  final HashMap<Map<String, dynamic>, ActionPlan> _actionPlans =
      HashMap<Map<String, dynamic>, ActionPlan>.identity();
  final HashMap<Map<String, dynamic>, WidgetPlan> _widgetPlans =
      HashMap<Map<String, dynamic>, WidgetPlan>.identity();
  final LinkedHashMap<String, ScreenPlan> _screens =
      LinkedHashMap<String, ScreenPlan>();
  final Set<Object> _visiting = HashSet<Object>.identity();

  AppExecutionPlan compile() {
    _registerDeclaredState(
      (config['global'] as Map<String, dynamic>?)?['variables']
              as Map<String, dynamic>? ??
          const <String, dynamic>{},
      '',
    );
    _compileValue(config, r'$');
    _registerScreens();
    final schema = _stateSchema.build();
    final (sourceHash, stableHash) = _hashConfig(config);
    return AppExecutionPlan._(
      abi: AppExecutionPlan.currentAbi,
      sourceHash: sourceHash,
      hasStableSourceHash: stableHash,
      stateSchema: schema,
      templates: Map<String, TemplatePlan>.unmodifiable(_templates),
      valuePlans: Map<Object, ValuePlan>.unmodifiable(_valuePlans),
      actionPlans: Map<Map<String, dynamic>, ActionPlan>.unmodifiable(
        _actionPlans,
      ),
      widgetPlans: Map<Map<String, dynamic>, WidgetPlan>.unmodifiable(
        _widgetPlans,
      ),
      screens: Map<String, ScreenPlan>.unmodifiable(_screens),
      stats: AppExecutionPlanStats(
        templateCount: _templates.length,
        valuePlanCount: _valuePlans.length,
        actionCount: _actionPlans.length,
        widgetCount: _widgetPlans.length,
        screenCount: _screens.length,
        stateSlotCount: schema.slots.length,
      ),
    );
  }

  ValuePlan _compileValue(dynamic value, String sourcePath) {
    if (value is String) {
      if (!value.contains('{{') || !value.contains('}}')) {
        _registerPossibleStaticPath(value);
        return ConstantValuePlan(value: value, sourcePath: sourcePath);
      }
      final template = _templates.putIfAbsent(
        value,
        () => TemplatePlan.compile(value),
      );
      _registerTemplateReads(template);
      return TemplateValuePlan(template: template, sourcePath: sourcePath);
    }
    if (value is List<dynamic>) {
      final cached = _valuePlans[value];
      if (cached != null) return cached;
      if (!_visiting.add(value)) {
        return ConstantValuePlan(value: value, sourcePath: sourcePath);
      }
      final items = <ValuePlan>[
        for (var index = 0; index < value.length; index++)
          _compileValue(value[index], '$sourcePath[$index]'),
      ];
      _visiting.remove(value);
      final plan = ListValuePlan(
        source: value,
        items: List<ValuePlan>.unmodifiable(items),
        sourcePath: sourcePath,
      );
      _valuePlans[value] = plan;
      return plan;
    }
    if (value is Map<String, dynamic>) {
      final cached = _valuePlans[value];
      if (cached != null) return cached;
      if (!_visiting.add(value)) {
        return ConstantValuePlan(value: value, sourcePath: sourcePath);
      }
      final values = <String, ValuePlan>{};
      for (final entry in value.entries) {
        values[entry.key] = _compileValue(
          entry.value,
          '$sourcePath.${entry.key}',
        );
      }
      _visiting.remove(value);
      final plan = MapValuePlan(
        source: value,
        values: Map<String, ValuePlan>.unmodifiable(values),
        isJsonLogic:
            value.length == 1 &&
            knownJsonLogicOperators.contains(value.keys.first),
        sourcePath: sourcePath,
      );
      _valuePlans[value] = plan;
      _registerJsonLogicRead(value);
      _registerAction(value, sourcePath);
      _registerWidget(value, plan, sourcePath);
      return plan;
    }
    return ConstantValuePlan(value: value, sourcePath: sourcePath);
  }

  void _registerTemplateReads(TemplatePlan template) {
    for (final part in template.parts) {
      if (part is TemplateBindingPart && part.variable != null) {
        _stateSchema.registerRead(part.variable!);
      }
    }
    final exact = template.exactBinding?.variable;
    if (exact != null) _stateSchema.registerRead(exact);
  }

  void _registerJsonLogicRead(Map<String, dynamic> value) {
    if (value.length != 1 || value.keys.first != 'var') return;
    final raw = value.values.first;
    final dynamic path = raw is List && raw.isNotEmpty ? raw.first : raw;
    if (path is String &&
        !path.contains('{{') &&
        !path.contains('}}') &&
        path.isNotEmpty) {
      _stateSchema.registerPath(path);
    }
  }

  void _registerAction(Map<String, dynamic> value, String sourcePath) {
    final rawType = value['type']?.toString() ?? 'call';
    final hasCallShape = value['call'] is String;
    final ActionPlanKind kind;
    switch (rawType) {
      case 'call':
        if (!hasCallShape) return;
        kind = ActionPlanKind.call;
        break;
      case 'navigate':
        kind = ActionPlanKind.navigate;
        break;
      case 'back':
        kind = ActionPlanKind.back;
        break;
      default:
        if (!hasCallShape) return;
        kind = ActionPlanKind.fallback;
        break;
    }

    final argsSource = value['args'];
    final argsPlan = argsSource is Map<String, dynamic>
        ? _valuePlans[argsSource] as MapValuePlan?
        : null;
    final assign = value['assign'] as String?;
    if (assign != null) _stateSchema.registerPath(assign);
    if (value['call'] == '@set' && argsSource is Map<String, dynamic>) {
      final writePath = argsSource['var'];
      if (writePath is String &&
          !writePath.contains('{{') &&
          !writePath.contains('}}')) {
        _stateSchema.registerPath(writePath);
      }
    }

    _actionPlans[value] = ActionPlan(
      source: value,
      sourcePath: sourcePath,
      kind: kind,
      callTarget: value['call'] as String?,
      arguments: argsPlan,
      assignPath: assign,
      screenId: value['screen'] as String?,
    );
  }

  void _registerWidget(
    Map<String, dynamic> value,
    MapValuePlan valuePlan,
    String sourcePath,
  ) {
    final type = value['type'];
    if (type is! String || !knownWidgetTypes.contains(type)) return;
    _widgetPlans[value] = WidgetPlan(
      source: value,
      sourcePath: sourcePath,
      type: type,
      visible: value.containsKey('visible')
          ? valuePlan.values['visible']
          : null,
      position: value.containsKey('position')
          ? valuePlan.values['position']
          : null,
      globalDependencies: valuePlan.globalDependencies,
    );
  }

  void _registerScreens() {
    final screens =
        (config['ui'] as Map<String, dynamic>?)?['screens'] as List<dynamic>? ??
        const <dynamic>[];
    for (var index = 0; index < screens.length; index++) {
      final screen = screens[index];
      if (screen is! Map<String, dynamic>) continue;
      final id = screen['id']?.toString();
      if (id == null || id.isEmpty) continue;
      _screens[id] = ScreenPlan(
        source: screen,
        sourcePath: '${r'$.ui.screens'}[$index]',
        id: id,
      );
    }
  }

  void _registerDeclaredState(Map<String, dynamic> values, String prefix) {
    for (final entry in values.entries) {
      final path = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      _stateSchema.registerPath('global.$path');
      if (entry.value is Map<String, dynamic>) {
        _registerDeclaredState(entry.value as Map<String, dynamic>, path);
      }
    }
  }

  void _registerPossibleStaticPath(String value) {
    if (value.startsWith('global.') || value.startsWith(r'$.global.')) {
      _stateSchema.registerPath(value);
    }
  }

  static (String, bool) _hashConfig(Map<String, dynamic> config) {
    try {
      return (sha256.convert(utf8.encode(jsonEncode(config))).toString(), true);
    } catch (_) {
      return ('runtime-${identityHashCode(config)}', false);
    }
  }
}
