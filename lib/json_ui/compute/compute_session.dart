import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kReleaseMode;

import 'compute_vm.dart';

/// App-scoped facade around [ComputeVmProgram].
///
/// The facade deliberately exposes only deterministic calls and typed-buffer
/// transfers. Platform services remain regular JSON App actions; trusted
/// embedders may construct [ComputeVmProgram] directly when host functions are
/// required.
final class ComputeSession {
  ComputeSession._({
    required Map<String, dynamic> programSpecification,
    required ComputeVmProgram program,
    required this.defaultBudget,
    required this.maxBudget,
  }) : _program = program,
       _initialU8 = _u8InitializerPrefixes(program, programSpecification),
       _initialI32 = _i32InitializerPrefixes(program, programSpecification);

  static const int _defaultInstructionBudget = 500 * 1000;
  static const int _productionMaximumInstructionBudget = 5 * 1000 * 1000;
  static const int _localMaximumInstructionBudget = 16 * 1000 * 1000;
  static const int _requestedLocalInstructionBudget = int.fromEnvironment(
    'JSON_APP_LOCAL_COMPUTE_MAX_BUDGET',
    defaultValue: _productionMaximumInstructionBudget,
  );
  static const int _maximumTransferElements = 1024 * 1024;
  static const int _maximumBase64Characters =
      ((_maximumTransferElements + 2) ~/ 3) * 4;

  static int get _maximumInstructionBudget {
    if (kReleaseMode) return _productionMaximumInstructionBudget;
    if (_requestedLocalInstructionBudget <
        _productionMaximumInstructionBudget) {
      return _productionMaximumInstructionBudget;
    }
    if (_requestedLocalInstructionBudget > _localMaximumInstructionBudget) {
      return _localMaximumInstructionBudget;
    }
    return _requestedLocalInstructionBudget;
  }

  final ComputeVmProgram _program;
  final Map<String, Uint8List> _initialU8;
  final Map<String, Int32List> _initialI32;

  /// Budget used by `@compute.call` when the action omits `budget`.
  final int defaultBudget;

  /// Hard ceiling for one synchronous `@compute.call`.
  final int maxBudget;

  /// Returns the length of a VM byte buffer for host-side adapters.
  int u8BufferLength(String name) {
    final buffer = _program.u8[name];
    if (buffer == null) {
      throw ComputeVmRuntimeException('unknown u8 buffer: $name');
    }
    return buffer.length;
  }

  /// Copies a VM byte range into host-owned typed memory.
  ///
  /// This avoids allocating a boxed `List<int>` per frame while ensuring host
  /// renderers cannot mutate persistent VM state through an aliased view.
  int copyU8BufferInto(
    String name,
    Uint8List destination, {
    int sourceOffset = 0,
    int destinationOffset = 0,
    required int length,
  }) {
    final buffer = _program.u8[name];
    if (buffer == null) {
      throw ComputeVmRuntimeException('unknown u8 buffer: $name');
    }
    _checkTransferSize(length);
    _checkRange(sourceOffset, length, buffer.length, operation: 'copy');
    _checkRange(
      destinationOffset,
      length,
      destination.length,
      operation: 'copy destination',
    );
    destination.setRange(
      destinationOffset,
      destinationOffset + length,
      buffer,
      sourceOffset,
    );
    return length;
  }

  /// Builds a session from the top-level JSON App configuration.
  ///
  /// A compute-enabled App must declare DSL 4.x. That makes clients that only
  /// understand DSL 3 reject the App instead of silently ignoring its compute
  /// actions.
  static ComputeSession? fromAppConfig(
    Map<String, dynamic> config, {
    ComputeVmLimits? limits,
  }) {
    final rawCompute = config['compute'];
    if (rawCompute == null) return null;

    final declaredDsl = config['dsl']?.toString().trim() ?? '';
    final dslMajor = int.tryParse(declaredDsl.split('.').first);
    if (dslMajor != 4) {
      throw const ComputeVmCompileException(
        'compute requires a DSL 4.x app contract',
        path: r'$.dsl',
      );
    }

    final compute = _stringMap(rawCompute, r'$.compute');
    final engine = _stringMap(compute['engine'], r'$.compute.engine');
    if (engine['abi'] != 2) {
      throw const ComputeVmCompileException(
        'compute engine abi must be 2',
        path: r'$.compute.engine.abi',
      );
    }
    if (engine['backend'] != 'vm') {
      throw const ComputeVmCompileException(
        'only the "vm" compute backend is supported',
        path: r'$.compute.engine.backend',
      );
    }
    if (engine['semantics'] != 'i32-v2') {
      throw const ComputeVmCompileException(
        'compute semantics must be "i32-v2"',
        path: r'$.compute.engine.semantics',
      );
    }

    final clientMaximumInstructionBudget = _maximumInstructionBudget;
    final effectiveLimits =
        limits ?? ComputeVmLimits(maxBudget: clientMaximumInstructionBudget);
    final defaultBudget = _positiveInteger(
      engine['defaultBudget'] ?? _defaultInstructionBudget,
      r'$.compute.engine.defaultBudget',
    );
    final maxBudget = _positiveInteger(
      engine['maxBudget'] ?? clientMaximumInstructionBudget,
      r'$.compute.engine.maxBudget',
    );
    if (maxBudget > clientMaximumInstructionBudget) {
      throw const ComputeVmCompileException(
        'maxBudget exceeds the client safety ceiling',
        path: r'$.compute.engine.maxBudget',
      );
    }
    if (maxBudget > effectiveLimits.maxBudget) {
      throw ComputeVmCompileException(
        'maxBudget exceeds the runtime limit ${effectiveLimits.maxBudget}',
        path: r'$.compute.engine.maxBudget',
      );
    }
    if (defaultBudget > maxBudget) {
      throw const ComputeVmCompileException(
        'defaultBudget must not exceed maxBudget',
        path: r'$.compute.engine.defaultBudget',
      );
    }

    final programSpecification = _stringMap(
      compute['program'],
      r'$.compute.program',
    );
    final program = ComputeVmProgram.compile(
      programSpecification,
      limits: effectiveLimits,
    );
    return ComputeSession._(
      programSpecification: programSpecification,
      program: program,
      defaultBudget: defaultBudget,
      maxBudget: maxBudget,
    );
  }

  /// Execute one generic `@compute.*` operation.
  dynamic execute(String operation, Map<String, dynamic> arguments) {
    switch (operation) {
      case 'call':
        return _call(arguments);
      case 'read':
        return _read(arguments);
      case 'write':
        return _write(arguments);
      case 'load':
        return _load(arguments);
      case 'reset':
        for (final entry in _program.u8.entries) {
          entry.value.fillRange(0, entry.value.length, 0);
          final initializer = _initialU8[entry.key];
          if (initializer != null) entry.value.setAll(0, initializer);
        }
        for (final entry in _program.i32.entries) {
          entry.value.fillRange(0, entry.value.length, 0);
          final initializer = _initialI32[entry.key];
          if (initializer != null) entry.value.setAll(0, initializer);
        }
        return true;
      default:
        throw ComputeVmRuntimeException(
          'unknown compute operation: $operation',
        );
    }
  }

  int _call(Map<String, dynamic> arguments) {
    final function = arguments['function'] ?? arguments['name'];
    if (function is! String || function.isEmpty) {
      throw const ComputeVmRuntimeException(
        'compute.call requires a function name',
      );
    }
    final rawArguments = arguments['args'] ?? const <dynamic>[];
    if (rawArguments is! List) {
      throw const ComputeVmRuntimeException('compute.call args must be a list');
    }
    final values = <int>[
      for (var index = 0; index < rawArguments.length; index++)
        _runtimeInteger(rawArguments[index], 'args[$index]'),
    ];
    final budget = arguments.containsKey('budget')
        ? _runtimePositiveInteger(arguments['budget'], 'budget')
        : defaultBudget;
    if (budget > maxBudget) {
      throw ComputeVmRuntimeException(
        'compute.call budget $budget exceeds maxBudget $maxBudget',
      );
    }
    return _program.call(function, args: values, budget: budget);
  }

  dynamic _read(Map<String, dynamic> arguments) {
    final view = _resolveView(arguments);
    final offset = _runtimeNonNegativeInteger(
      arguments['offset'] ?? arguments['index'] ?? 0,
      'offset',
    );
    if (!arguments.containsKey('length')) {
      _checkRange(offset, 1, view.length, operation: 'read');
      return view.read(offset);
    }
    final length = _runtimeNonNegativeInteger(arguments['length'], 'length');
    _checkTransferSize(length);
    _checkRange(offset, length, view.length, operation: 'read');
    return <int>[
      for (var index = 0; index < length; index++) view.read(offset + index),
    ];
  }

  int _write(Map<String, dynamic> arguments) {
    final view = _resolveView(arguments);
    final offset = _runtimeNonNegativeInteger(
      arguments['offset'] ?? arguments['index'] ?? 0,
      'offset',
    );
    final dynamic rawValues;
    if (arguments.containsKey('values')) {
      rawValues = arguments['values'];
      if (rawValues is! List) {
        throw const ComputeVmRuntimeException(
          'compute.write values must be a list',
        );
      }
    } else if (arguments.containsKey('value')) {
      rawValues = <dynamic>[arguments['value']];
    } else {
      throw const ComputeVmRuntimeException(
        'compute.write requires value or values',
      );
    }

    final values = rawValues as List;
    _checkTransferSize(values.length);
    _checkRange(offset, values.length, view.length, operation: 'write');

    // Validate the complete transfer before mutating persistent VM state.
    // A malformed value in the middle of a list must not leave a partial write.
    for (var index = 0; index < values.length; index++) {
      _runtimeInteger(values[index], 'values[$index]');
    }
    for (var index = 0; index < values.length; index++) {
      view.write(
        offset + index,
        _runtimeInteger(values[index], 'values[$index]'),
      );
    }
    return values.length;
  }

  int _load(Map<String, dynamic> arguments) {
    final kind = arguments['kind'] ?? 'u8';
    if (kind != 'u8') {
      throw const ComputeVmRuntimeException(
        'compute.load currently supports only u8 buffers',
      );
    }
    final view = _resolveView(<String, dynamic>{...arguments, 'kind': 'u8'});
    final offset = _runtimeNonNegativeInteger(
      arguments['offset'] ?? 0,
      'offset',
    );
    final encoded = arguments['base64'] ?? arguments['data'];
    if (encoded is! String || encoded.isEmpty) {
      throw const ComputeVmRuntimeException(
        'compute.load requires non-empty base64 data',
      );
    }
    if (encoded.length > _maximumBase64Characters) {
      throw const ComputeVmRuntimeException(
        'compute.load encoded data exceeds the transfer limit',
      );
    }

    final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException catch (error) {
      throw ComputeVmRuntimeException(
        'compute.load data is not valid base64: ${error.message}',
      );
    }
    _checkTransferSize(bytes.length);
    _checkRange(offset, bytes.length, view.length, operation: 'load');
    for (var index = 0; index < bytes.length; index++) {
      view.write(offset + index, bytes[index]);
    }
    return bytes.length;
  }

  _ComputeBufferView _resolveView(Map<String, dynamic> arguments) {
    final kind = arguments['kind'];
    final name = arguments['buffer'];
    if (name is! String || name.isEmpty) {
      throw const ComputeVmRuntimeException(
        'compute buffer operation requires a buffer name',
      );
    }
    switch (kind) {
      case 'u8':
        return _U8BufferView(_program.buffer(name));
      case 'i32':
        return _I32BufferView(_program.words(name));
      default:
        throw const ComputeVmRuntimeException(
          'compute buffer kind must be "u8" or "i32"',
        );
    }
  }

  static void _checkTransferSize(int length) {
    if (length < 0 || length > _maximumTransferElements) {
      throw ComputeVmRuntimeException(
        'compute transfer length must be between 0 and '
        '$_maximumTransferElements elements',
      );
    }
  }

  static void _checkRange(
    int offset,
    int length,
    int bufferLength, {
    required String operation,
  }) {
    if (offset < 0 ||
        length < 0 ||
        offset > bufferLength ||
        length > bufferLength - offset) {
      throw ComputeVmRuntimeException(
        'compute.$operation range [$offset, ${offset + length}) exceeds '
        'buffer length $bufferLength',
      );
    }
  }

  static Map<String, dynamic> _stringMap(dynamic value, String path) {
    if (value is! Map) {
      throw ComputeVmCompileException('expected an object', path: path);
    }
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String || (entry.key as String).isEmpty) {
        throw ComputeVmCompileException(
          'object keys must be non-empty strings',
          path: path,
        );
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static Map<String, Uint8List> _u8InitializerPrefixes(
    ComputeVmProgram program,
    Map<String, dynamic> specification,
  ) {
    final initializers = specification['init'];
    if (initializers is! Map) return const <String, Uint8List>{};
    final result = <String, Uint8List>{};
    for (final entry in program.u8.entries) {
      final source = initializers[entry.key];
      if (source is! List || source.isEmpty) continue;
      final prefix = Uint8List(source.length)
        ..setRange(0, source.length, entry.value);
      result[entry.key] = prefix;
    }
    return Map<String, Uint8List>.unmodifiable(result);
  }

  static Map<String, Int32List> _i32InitializerPrefixes(
    ComputeVmProgram program,
    Map<String, dynamic> specification,
  ) {
    final initializers = specification['init'];
    if (initializers is! Map) return const <String, Int32List>{};
    final result = <String, Int32List>{};
    for (final entry in program.i32.entries) {
      final source = initializers[entry.key];
      if (source is! List || source.isEmpty) continue;
      final prefix = Int32List(source.length)
        ..setRange(0, source.length, entry.value);
      result[entry.key] = prefix;
    }
    return Map<String, Int32List>.unmodifiable(result);
  }

  static int _positiveInteger(dynamic value, String path) {
    if (value is! num ||
        !value.isFinite ||
        value.toInt() != value ||
        value <= 0) {
      throw ComputeVmCompileException(
        'expected a positive integer',
        path: path,
      );
    }
    return value.toInt();
  }

  static int _runtimeInteger(dynamic value, String name) {
    if (value is! num ||
        !value.isFinite ||
        value.toInt() != value ||
        value < -9007199254740991 ||
        value > 9007199254740991) {
      throw ComputeVmRuntimeException(
        '$name must be a cross-platform safe integer',
      );
    }
    return value.toInt();
  }

  static int _runtimePositiveInteger(dynamic value, String name) {
    final integer = _runtimeInteger(value, name);
    if (integer <= 0) {
      throw ComputeVmRuntimeException('$name must be positive');
    }
    return integer;
  }

  static int _runtimeNonNegativeInteger(dynamic value, String name) {
    final integer = _runtimeInteger(value, name);
    if (integer < 0) {
      throw ComputeVmRuntimeException('$name must not be negative');
    }
    return integer;
  }
}

sealed class _ComputeBufferView {
  int get length;

  int read(int index);

  void write(int index, int value);
}

final class _U8BufferView implements _ComputeBufferView {
  const _U8BufferView(this.value);

  final Uint8List value;

  @override
  int get length => value.length;

  @override
  int read(int index) => value[index];

  @override
  void write(int index, int element) {
    value[index] = element.toUnsigned(8);
  }
}

final class _I32BufferView implements _ComputeBufferView {
  const _I32BufferView(this.value);

  final Int32List value;

  @override
  int get length => value.length;

  @override
  int read(int index) => value[index];

  @override
  void write(int index, int element) {
    value[index] = element.toSigned(32);
  }
}
