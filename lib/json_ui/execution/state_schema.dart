import 'dart:collection';

import 'template_plan.dart';

enum StateValueKind {
  nullValue,
  boolean,
  integer,
  doubleValue,
  string,
  list,
  map,
  dynamicValue,
}

/// One stable integer slot assigned to a global-state path at App load.
///
/// The current compatibility runtime still keeps the Map as the source of
/// truth. The slot removes repeated name binding and provides a stable key for
/// dependency tracking; later typed stores can use the same schema ABI.
final class StateSlotPlan {
  const StateSlotPlan({
    required this.id,
    required this.canonicalPath,
    required this.readPlan,
    required this.initialKind,
  });

  final int id;
  final String canonicalPath;
  final VariableReadPlan readPlan;
  final StateValueKind initialKind;
}

final class StateSchema {
  StateSchema._(this.slots, this._slotIdsByPath);

  final List<StateSlotPlan> slots;
  final Map<String, int> _slotIdsByPath;

  int? slotIdForPath(String path) {
    final read = VariableReadPlan.compile(path);
    final canonical = _canonicalGlobalPath(read);
    return canonical == null ? null : _slotIdsByPath[canonical];
  }

  StateSlotPlan? slotForPath(String path) {
    final id = slotIdForPath(path);
    return id == null ? null : slots[id];
  }

  static String? _canonicalGlobalPath(VariableReadPlan read) {
    switch (read.namespace) {
      case VariableNamespace.global:
      case VariableNamespace.unqualified:
        return 'global.${read.path}';
      case VariableNamespace.loop:
      case VariableNamespace.params:
      case VariableNamespace.event:
      case VariableNamespace.app:
        return null;
    }
  }
}

final class StateSchemaBuilder {
  StateSchemaBuilder(this.initialState);

  final Map<String, dynamic> initialState;
  final LinkedHashMap<String, VariableReadPlan> _readsByCanonicalPath =
      LinkedHashMap<String, VariableReadPlan>();

  void registerRead(VariableReadPlan read) {
    final canonical = StateSchema._canonicalGlobalPath(read);
    if (canonical == null || read.path.isEmpty) return;
    _readsByCanonicalPath.putIfAbsent(canonical, () {
      if (read.namespace == VariableNamespace.global) return read;
      return VariableReadPlan.compile(canonical);
    });
  }

  void registerPath(String path) {
    registerRead(VariableReadPlan.compile(path));
  }

  StateSchema build() {
    final slots = <StateSlotPlan>[];
    final ids = <String, int>{};
    for (final entry in _readsByCanonicalPath.entries) {
      final read = entry.value;
      final lookup = read.pathPlan.lookup(initialState);
      final id = slots.length;
      ids[entry.key] = id;
      slots.add(
        StateSlotPlan(
          id: id,
          canonicalPath: entry.key,
          readPlan: read,
          initialKind: lookup.found
              ? _kindOf(lookup.value)
              : StateValueKind.dynamicValue,
        ),
      );
    }
    return StateSchema._(
      List<StateSlotPlan>.unmodifiable(slots),
      Map<String, int>.unmodifiable(ids),
    );
  }

  static StateValueKind _kindOf(dynamic value) {
    if (value == null) return StateValueKind.nullValue;
    if (value is bool) return StateValueKind.boolean;
    if (value is int) return StateValueKind.integer;
    if (value is double) return StateValueKind.doubleValue;
    if (value is String) return StateValueKind.string;
    if (value is List) return StateValueKind.list;
    if (value is Map) return StateValueKind.map;
    return StateValueKind.dynamicValue;
  }
}
