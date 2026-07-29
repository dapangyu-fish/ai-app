import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'expression_plan.dart';
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

/// One sentinel for a subtree owned by another runtime or copied before use.
///
/// Descendants deliberately receive no identity plans. If this source object
/// is ever evaluated through the generic interpreter, the runtime executes the
/// legacy recursive semantics from this root.
final class OpaqueValuePlan extends ValuePlan {
  const OpaqueValuePlan({
    required this.source,
    required this.owner,
    required super.sourcePath,
  }) : super(globalDependencies: const <String>{});

  final dynamic source;
  final String owner;
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
    required this.expressionPlan,
    required super.sourcePath,
  }) : super(
         globalDependencies: Set<String>.unmodifiable(<String>{
           ...values.values.expand((value) => value.globalDependencies),
           ...?expressionPlan?.globalDependencies,
         }),
       );

  final Map<String, dynamic> source;
  final Map<String, ValuePlan> values;
  final bool isJsonLogic;
  final JsonLogicExpressionPlan? expressionPlan;
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
    required this.dependenciesAreComplete,
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

  /// Whether [globalDependencies] covers every state read that can affect this
  /// widget's rendered output.
  ///
  /// `false` never means "no dependencies": callers must use screen-wide
  /// invalidation instead of treating the dependency set as exhaustive.
  final bool dependenciesAreComplete;
}

final class ScreenPlan {
  ScreenPlan({
    required this.source,
    required this.sourcePath,
    required this.id,
    required this.fallbackGlobalDependencies,
    required this.fallbackOnAnyGlobalWrite,
    required Map<Map<String, dynamic>, WidgetPlan> pathScopedWidgets,
  }) : pathScopedWidgets = UnmodifiableMapView(pathScopedWidgets);

  final Map<String, dynamic> source;
  final String sourcePath;
  final String id;

  /// Dependencies owned by the screen shell rather than an individual widget.
  final Set<String> fallbackGlobalDependencies;

  /// If true, dependency discovery was incomplete and every global write must
  /// invalidate the whole screen.
  final bool fallbackOnAnyGlobalWrite;

  /// Identity-keyed widgets that are safe to invalidate independently.
  ///
  /// This is populated only when dependency discovery is complete for the
  /// entire screen. Otherwise it is empty and the screen uses broad fallback.
  final Map<Map<String, dynamic>, WidgetPlan> pathScopedWidgets;
}

final class AppExecutionPlanStats {
  const AppExecutionPlanStats({
    required this.templateCount,
    required this.valuePlanCount,
    required this.actionCount,
    required this.widgetCount,
    required this.screenCount,
    required this.stateSlotCount,
    required this.expressionCount,
    required this.opaqueValueCount,
  });

  final int templateCount;
  final int valuePlanCount;
  final int actionCount;
  final int widgetCount;
  final int screenCount;
  final int stateSlotCount;
  final int expressionCount;
  final int opaqueValueCount;
}

enum AppSourceHashMode {
  /// Canonicalize the decoded Map again and hash it.
  canonicalJson,

  /// Avoid a second whole-App serialization when no stable upstream hash is
  /// available. The plan is still unique to this load and is not cacheable.
  runtimeIdentity,
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
    Set<String> pathScopedWidgetTypes = const <String>{},
    String? precomputedSourceHash,
    AppSourceHashMode sourceHashMode = AppSourceHashMode.canonicalJson,
  }) {
    return _AppExecutionPlanCompiler(
      config: config,
      knownJsonLogicOperators: knownJsonLogicOperators,
      knownWidgetTypes: knownWidgetTypes,
      pathScopedWidgetTypes: pathScopedWidgetTypes,
      precomputedSourceHash: precomputedSourceHash,
      sourceHashMode: sourceHashMode,
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
    required this.pathScopedWidgetTypes,
    required this.precomputedSourceHash,
    required this.sourceHashMode,
  }) : _stateSchema = StateSchemaBuilder(
         (config['global'] as Map<String, dynamic>?)?['variables']
                 as Map<String, dynamic>? ??
             const <String, dynamic>{},
       );

  final Map<String, dynamic> config;
  final Set<String> knownJsonLogicOperators;
  final Set<String> knownWidgetTypes;
  final Set<String> pathScopedWidgetTypes;
  final String? precomputedSourceHash;
  final AppSourceHashMode sourceHashMode;
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
  var _expressionCount = 0;
  var _opaqueValueCount = 0;

  late final Set<String> _computedGlobalPaths = _collectComputedGlobalPaths();

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
    final (sourceHash, stableHash) = _sourceHash();
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
        expressionCount: _expressionCount,
        opaqueValueCount: _opaqueValueCount,
      ),
    );
  }

  ValuePlan _compileValue(dynamic value, String sourcePath) {
    if (_isOpaqueRootPath(sourcePath)) {
      return _compileOpaqueValue(value, sourcePath, owner: sourcePath);
    }
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
      if (value['type'] == 'flame_game' &&
          knownWidgetTypes.contains('flame_game')) {
        return _compileFlameGameWidget(value, sourcePath);
      }
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
      final isJsonLogic =
          value.length == 1 &&
          knownJsonLogicOperators.contains(value.keys.first);
      final expressionPlan = isJsonLogic
          ? _compileJsonLogic(value, sourcePath)
          : null;
      final plan = MapValuePlan(
        source: value,
        values: Map<String, ValuePlan>.unmodifiable(values),
        isJsonLogic: isJsonLogic,
        expressionPlan: expressionPlan,
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

  ValuePlan _compileOpaqueValue(
    dynamic value,
    String sourcePath, {
    required String owner,
  }) {
    if (value is! Map<String, dynamic> && value is! List<dynamic>) {
      return ConstantValuePlan(value: value, sourcePath: sourcePath);
    }
    final cached = _valuePlans[value];
    if (cached != null) return cached;
    final plan = OpaqueValuePlan(
      source: value,
      owner: owner,
      sourcePath: sourcePath,
    );
    _valuePlans[value] = plan;
    _opaqueValueCount++;
    return plan;
  }

  ValuePlan _compileFlameGameWidget(
    Map<String, dynamic> value,
    String sourcePath,
  ) {
    if (!_visiting.add(value)) {
      return ConstantValuePlan(value: value, sourcePath: sourcePath);
    }
    final values = <String, ValuePlan>{};
    for (final entry in value.entries) {
      final entryPath = '$sourcePath.${entry.key}';
      values[entry.key] =
          entry.key == 'type' ||
              entry.key == 'visible' ||
              entry.key == 'position'
          ? _compileValue(entry.value, entryPath)
          : _compileOpaqueValue(entry.value, entryPath, owner: 'flame_game');
    }
    _visiting.remove(value);
    final plan = MapValuePlan(
      source: value,
      values: Map<String, ValuePlan>.unmodifiable(values),
      isJsonLogic: false,
      expressionPlan: null,
      sourcePath: sourcePath,
    );
    _valuePlans[value] = plan;
    _registerWidget(value, plan, sourcePath);
    return plan;
  }

  static bool _isOpaqueRootPath(String sourcePath) {
    return sourcePath == r'$.compute' || sourcePath == r'$.global.variables';
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

  JsonLogicExpressionPlan _compileJsonLogic(
    Map<String, dynamic> rule,
    String sourcePath,
  ) {
    _expressionCount++;
    return JsonLogicPlanCompiler(
      knownOperators: knownJsonLogicOperators,
      templateFor: (source) {
        final template = _templates.putIfAbsent(
          source,
          () => TemplatePlan.compile(source),
        );
        _registerTemplateReads(template);
        return template;
      },
    ).compile(rule, sourcePath);
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
      dependenciesAreComplete:
          pathScopedWidgetTypes.contains(type) &&
          _valueDependenciesAreComplete(valuePlan) &&
          !_hasUnsafeWidgetStructure(value),
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
      // JsonScreenView resolves duplicate IDs by taking the first matching
      // screen. Keep plan lookup aligned with that permissive runtime behavior
      // so invalidation metadata always belongs to the screen being rendered.
      if (_screens.containsKey(id)) continue;
      final screenPlan = _valuePlans[screen];
      final metadata = screenPlan is MapValuePlan
          ? _compileScreenDependencyMetadata(screen, screenPlan)
          : const _ScreenDependencyMetadata.incomplete();
      _screens[id] = ScreenPlan(
        source: screen,
        sourcePath: '${r'$.ui.screens'}[$index]',
        id: id,
        fallbackGlobalDependencies: metadata.fallbackGlobalDependencies,
        fallbackOnAnyGlobalWrite: metadata.fallbackOnAnyGlobalWrite,
        pathScopedWidgets: metadata.pathScopedWidgets,
      );
    }
  }

  _ScreenDependencyMetadata _compileScreenDependencyMetadata(
    Map<String, dynamic> screen,
    MapValuePlan screenValuePlan,
  ) {
    const safeScreenFields = <String>{
      'id',
      'title',
      'layout',
      'padding',
      'backgroundColor',
      'children',
    };
    if (screen.keys.any((key) => !safeScreenFields.contains(key))) {
      return _broadScreenMetadata(screenValuePlan);
    }

    final children = screen['children'];
    if (children != null && children is! List<dynamic>) {
      return _broadScreenMetadata(screenValuePlan);
    }

    final shellDependencies = <String>{};
    var shellIsComplete = true;
    for (final entry in screenValuePlan.values.entries) {
      if (entry.key == 'children') continue;
      shellDependencies.addAll(entry.value.globalDependencies);
      shellIsComplete =
          shellIsComplete && _valueDependenciesAreComplete(entry.value);
    }
    if (!shellIsComplete) return _broadScreenMetadata(screenValuePlan);

    final scopedWidgets = HashMap<Map<String, dynamic>, WidgetPlan>.identity();
    for (final child in children as List<dynamic>? ?? const <dynamic>[]) {
      if (child is! Map<String, dynamic>) continue;
      final widgetPlan = _widgetPlans[child];
      if (widgetPlan == null ||
          !pathScopedWidgetTypes.contains(widgetPlan.type) ||
          !widgetPlan.dependenciesAreComplete) {
        return _broadScreenMetadata(screenValuePlan);
      }
      scopedWidgets[child] = widgetPlan;
    }

    return _ScreenDependencyMetadata(
      fallbackGlobalDependencies: Set<String>.unmodifiable(shellDependencies),
      fallbackOnAnyGlobalWrite: false,
      pathScopedWidgets: scopedWidgets,
    );
  }

  _ScreenDependencyMetadata _broadScreenMetadata(MapValuePlan screenValuePlan) {
    return _ScreenDependencyMetadata(
      fallbackGlobalDependencies: screenValuePlan.globalDependencies,
      fallbackOnAnyGlobalWrite: true,
      pathScopedWidgets: HashMap<Map<String, dynamic>, WidgetPlan>.identity(),
    );
  }

  bool _valueDependenciesAreComplete(ValuePlan plan) {
    if (plan is ConstantValuePlan) return true;
    if (plan is OpaqueValuePlan) return false;
    if (plan is TemplateValuePlan) {
      return _templateDependenciesAreComplete(plan.template);
    }
    if (plan is ListValuePlan) {
      return plan.items.every(_valueDependenciesAreComplete);
    }
    if (plan is MapValuePlan) {
      final expressionPlan = plan.expressionPlan;
      if (expressionPlan != null &&
          !_jsonLogicDependenciesAreComplete(expressionPlan)) {
        return false;
      }
      return plan.values.values.every(_valueDependenciesAreComplete);
    }
    return false;
  }

  bool _templateDependenciesAreComplete(TemplatePlan template) {
    for (final part in template.parts) {
      if (part is! TemplateBindingPart) continue;
      if (part.isI18n) return false;
      final variable = part.variable;
      if (variable == null || variable.path.isEmpty) return false;
      switch (variable.namespace) {
        case VariableNamespace.global:
          if (_isComputedGlobalDependency('global.${variable.path}')) {
            return false;
          }
          break;
        case VariableNamespace.app:
          break;
        case VariableNamespace.loop:
        case VariableNamespace.params:
        case VariableNamespace.event:
        case VariableNamespace.unqualified:
          return false;
      }
    }
    return true;
  }

  bool _jsonLogicDependenciesAreComplete(JsonLogicExpressionPlan plan) {
    if (plan is JsonLogicConstantPlan) return true;
    if (plan is JsonLogicTemplatePlan) {
      return _templateDependenciesAreComplete(plan.template);
    }
    if (plan is JsonLogicLiteralListPlan) {
      return plan.items.every(_jsonLogicDependenciesAreComplete);
    }
    if (plan is JsonLogicLiteralMapPlan) {
      return plan.values.values.every(_jsonLogicDependenciesAreComplete);
    }
    if (plan is JsonLogicVariablePlan) {
      final key = plan.key;
      if (key is! String || key.isEmpty) return false;
      if (key == 'global' || _isComputedGlobalDependency(key)) return false;
      final defaultValue = plan.defaultValue;
      return defaultValue == null ||
          _jsonLogicDependenciesAreComplete(defaultValue);
    }
    if (plan is JsonLogicMultiAndPlan) {
      return plan.entries.every(_jsonLogicDependenciesAreComplete);
    }
    if (plan is JsonLogicFallbackPlan) return false;
    if (plan is JsonLogicOperatorPlan) {
      // These operators either contain dynamic paths, hide path strings in
      // literal arrays, perform reflection, or have observable side effects.
      // Treating their empty dependency set as exhaustive would leave a
      // locally mounted widget stale.
      if (const <String>{
        'var',
        'missing',
        'missing_some',
        'method',
        'log',
      }.contains(plan.operatorName)) {
        return false;
      }
      return plan.parameters.every(_jsonLogicDependenciesAreComplete);
    }
    return false;
  }

  bool _hasUnsafeWidgetStructure(Map<String, dynamic> widget) {
    // Keys and ParentData wrappers need stable ancestry. Runtime scopes and
    // event/action trees are not safe to bind to a leaf-only listener.
    const unsafeKeys = <String>{
      'key',
      'position',
      'loop',
      'params',
      'event',
      'events',
      'onLoad',
      'onTap',
      'onPressed',
      'action',
      'actions',
    };
    return widget.keys.any(unsafeKeys.contains);
  }

  bool _isComputedGlobalDependency(String dependency) {
    final normalized = dependency.startsWith(r'$.')
        ? dependency.substring(2)
        : dependency;
    if (!normalized.startsWith('global.')) return false;
    for (final computedPath in _computedGlobalPaths) {
      if (normalized == computedPath ||
          normalized.startsWith('$computedPath.') ||
          computedPath.startsWith('$normalized.')) {
        return true;
      }
    }
    return false;
  }

  Set<String> _collectComputedGlobalPaths() {
    final computed = (config['global'] as Map<String, dynamic>?)?['computed'];
    if (computed is! Map) return const <String>{};
    return Set<String>.unmodifiable(<String>{
      for (final key in computed.keys) 'global.${key.toString()}',
    });
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

  (String, bool) _sourceHash() {
    final supplied = precomputedSourceHash?.trim();
    if (supplied != null && supplied.isNotEmpty) return (supplied, true);
    if (sourceHashMode == AppSourceHashMode.runtimeIdentity) {
      return (
        'runtime-${identityHashCode(config)}-abi${AppExecutionPlan.currentAbi}',
        false,
      );
    }
    try {
      return (sha256.convert(utf8.encode(jsonEncode(config))).toString(), true);
    } catch (_) {
      return ('runtime-${identityHashCode(config)}', false);
    }
  }
}

final class _ScreenDependencyMetadata {
  const _ScreenDependencyMetadata({
    required this.fallbackGlobalDependencies,
    required this.fallbackOnAnyGlobalWrite,
    required this.pathScopedWidgets,
  });

  const _ScreenDependencyMetadata.incomplete()
    : fallbackGlobalDependencies = const <String>{},
      fallbackOnAnyGlobalWrite = true,
      pathScopedWidgets = const <Map<String, dynamic>, WidgetPlan>{};

  final Set<String> fallbackGlobalDependencies;
  final bool fallbackOnAnyGlobalWrite;
  final Map<Map<String, dynamic>, WidgetPlan> pathScopedWidgets;
}
