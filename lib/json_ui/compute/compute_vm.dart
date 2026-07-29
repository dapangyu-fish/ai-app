/// A dependency-free, deterministic integer virtual machine for JSON apps.
///
/// Compute VM v2 compiles a structured JSON AST into fixed-width register
/// bytecode and basic blocks. It is intended for hot, data-authored algorithms;
/// it does not depend on Flutter, Flame, or any application-specific runtime.
///
/// ## Module format
///
/// ```json
/// {
///   "version": 2,
///   "buffers": {"bytes": 256},
///   "i32": {"words": 16},
///   "init": {"bytes": [1, 2], "words": [3, 4]},
///   "functions": {
///     "add": {
///       "params": ["a", "b"],
///       "body": [
///         ["ret", ["+", ["var", "a"], ["var", "b"]]]
///       ]
///     }
///   }
/// }
/// ```
///
/// Statements are `set`, `setu8`, `seti32`, `if`, `while`, `repeat`,
/// `switch`, `call`, `host`, `memset`, `memlut`, `ret`, `break`, `continue`,
/// `block`, and `nop`.
/// Expressions are integer/boolean literals, `var`, `lit`, `u8`, `i32`,
/// `call`, `host`, arithmetic (`+ - * / % min max`), bitwise
/// (`& | ^ ~ << >>`), comparisons, `and`, `or`, `not`, and `?:`.
///
/// Values use signed 32-bit two's-complement semantics after every bytecode
/// instruction. Division truncates toward zero; division and modulo by zero
/// return zero. `%` uses a non-negative Euclidean remainder. Shifts mask their
/// count with 31 and `>>` is a logical 32-bit shift.
///
/// Byte buffers whose non-zero length is a power of two wrap addresses with a
/// mask. Other buffers return zero for out-of-range reads and ignore
/// out-of-range writes. Word buffers always use checked, non-wrapping indices.
///
/// Every executed bytecode instruction consumes one budget unit, including
/// calls and host calls. A shared budget covers the complete recursive call
/// tree. Bulk byte-buffer instructions additionally charge work proportional
/// to the clamped range they will touch. They reserve that dynamic charge
/// before mutating a buffer, so budget failure cannot leave a partially
/// completed bulk operation.
library;

import 'dart:typed_data';

part 'src/compute_vm_bytecode.dart';
part 'src/compute_vm_compiler.dart';
part 'src/compute_vm_runtime.dart';

const int _maxSafeInteger = 9007199254740991;

/// A native callback exposed to a compute module.
///
/// Arguments are evaluated from left to right and converted to signed int32.
/// The returned value is converted to signed int32 before the program observes
/// it.
typedef ComputeVmHostFunction = int Function(List<int> arguments);

/// Limits applied while compiling or running an untrusted compute module.
final class ComputeVmLimits {
  const ComputeVmLimits({
    this.maxFunctions = 2048,
    this.maxBuffers = 256,
    this.maxInstructions = 500000,
    this.maxConstants = 64 * 1024,
    this.maxCallSites = 64 * 1024,
    this.maxHostSites = 8 * 1024,
    this.maxSwitchSites = 8 * 1024,
    this.maxBulkSites = 8 * 1024,
    this.maxRegistersPerFunction = 8192,
    this.maxU8Bytes = 16 * 1024 * 1024,
    this.maxI32Words = 4 * 1024 * 1024,
    this.maxBufferBytes = 16 * 1024 * 1024,
    this.maxInitializerElements = 256 * 1024,
    this.maxAstNodes = 500000,
    this.maxAstDepth = 128,
    this.maxNameLength = 128,
    this.maxSwitchTableEntries = 64 * 1024,
    this.maxCallDepth = 256,
    this.maxStackWords = 256 * 1024,
    this.maxBudget = 5 * 1000 * 1000,
  });

  final int maxFunctions;
  final int maxBuffers;
  final int maxInstructions;
  final int maxConstants;
  final int maxCallSites;
  final int maxHostSites;
  final int maxSwitchSites;
  final int maxBulkSites;
  final int maxRegistersPerFunction;
  final int maxU8Bytes;
  final int maxI32Words;
  final int maxBufferBytes;
  final int maxInitializerElements;
  final int maxAstNodes;
  final int maxAstDepth;
  final int maxNameLength;
  final int maxSwitchTableEntries;
  final int maxCallDepth;
  final int maxStackWords;
  final int maxBudget;
}

/// A malformed module or an error detected while compiling it.
final class ComputeVmCompileException implements Exception {
  const ComputeVmCompileException(this.message, {this.path});

  final String message;
  final String? path;

  @override
  String toString() {
    final location = path == null ? '' : ' at $path';
    return 'ComputeVmCompileException$location: $message';
  }
}

/// A runtime error other than budget exhaustion.
final class ComputeVmRuntimeException implements Exception {
  const ComputeVmRuntimeException(this.message);

  final String message;

  @override
  String toString() => 'ComputeVmRuntimeException: $message';
}

/// Thrown when a call consumes all of its instruction budget.
final class ComputeVmBudgetExceeded implements Exception {
  const ComputeVmBudgetExceeded({
    required this.budget,
    required this.executedInstructions,
    required this.function,
    required this.instruction,
  });

  final int budget;
  final int executedInstructions;
  final String function;
  final int instruction;

  @override
  String toString() {
    return 'ComputeVmBudgetExceeded('
        'budget: $budget, executed: $executedInstructions, '
        'at: $function#$instruction)';
  }
}

/// Read-only metadata for one compiled function.
final class ComputeVmFunctionInfo {
  const ComputeVmFunctionInfo({
    required this.name,
    required this.parameterCount,
    required this.localCount,
    required this.registerCount,
    required this.instructionCount,
    required this.basicBlockCount,
    this.jumpTableSwitchCount = 0,
    this.binarySearchSwitchCount = 0,
  });

  final String name;
  final int parameterCount;
  final int localCount;
  final int registerCount;
  final int instructionCount;
  final int basicBlockCount;
  final int jumpTableSwitchCount;
  final int binarySearchSwitchCount;
}

/// A compiled Compute VM v2 module.
///
/// Buffer state belongs to the program and survives calls. Call stacks,
/// registers, return values, and budgets are fresh for each [call].
final class ComputeVmProgram {
  ComputeVmProgram._({
    required Map<String, Uint8List> u8,
    required Map<String, Int32List> i32,
    required _VmModule module,
    required Map<String, ComputeVmHostFunction> hosts,
    required ComputeVmLimits limits,
  }) : u8 = Map<String, Uint8List>.unmodifiable(u8),
       i32 = Map<String, Int32List>.unmodifiable(i32),
       _u8Buffers = List<Uint8List>.unmodifiable(u8.values),
       _u8Masks = List<int>.unmodifiable(
         u8.values.map((buffer) {
           final mask = buffer.length - 1;
           return buffer.isNotEmpty && (buffer.length & mask) == 0 ? mask : -1;
         }),
       ),
       _i32Buffers = List<Int32List>.unmodifiable(i32.values),
       _module = module,
       _hosts = Map<String, ComputeVmHostFunction>.unmodifiable(hosts),
       _limits = limits;

  /// Byte buffers declared by the module.
  final Map<String, Uint8List> u8;

  /// Signed 32-bit word buffers declared by the module.
  final Map<String, Int32List> i32;

  final _VmModule _module;
  final List<Uint8List> _u8Buffers;
  final List<int> _u8Masks;
  final List<Int32List> _i32Buffers;
  final Map<String, ComputeVmHostFunction> _hosts;
  final ComputeVmLimits _limits;

  /// Compile and validate a JSON module.
  static ComputeVmProgram compile(
    Map<String, dynamic> specification, {
    Map<String, ComputeVmHostFunction> hosts = const {},
    ComputeVmLimits limits = const ComputeVmLimits(),
  }) {
    return _ComputeVmCompiler(
      specification,
      hosts: hosts,
      limits: limits,
    ).compile();
  }

  /// Whether [name] identifies a callable function.
  bool hasFunction(String name) => _module.functionByName.containsKey(name);

  /// Return metadata for a compiled function, or `null` when it is absent.
  ComputeVmFunctionInfo? functionInfo(String name) {
    final id = _module.functionByName[name];
    if (id == null) return null;
    final function = _module.functions[id];
    var jumpTableSwitchCount = 0;
    var binarySearchSwitchCount = 0;
    for (var pc = 0; pc < function.instructionCount; pc++) {
      final base = pc * _instructionWidth;
      if (function.code[base] != _Op.switchDispatch) continue;
      final site = _module.switchSites[function.code[base + 2]];
      if (site.encoding == _VmSwitchEncoding.jumpTable) {
        jumpTableSwitchCount++;
      } else if (site.encoding == _VmSwitchEncoding.binarySearch) {
        binarySearchSwitchCount++;
      }
    }
    return ComputeVmFunctionInfo(
      name: function.name,
      parameterCount: function.parameterCount,
      localCount: function.localCount,
      registerCount: function.registerCount,
      instructionCount: function.instructionCount,
      basicBlockCount: function.basicBlockStarts.length,
      jumpTableSwitchCount: jumpTableSwitchCount,
      binarySearchSwitchCount: binarySearchSwitchCount,
    );
  }

  /// Resolve a byte buffer or throw a descriptive runtime exception.
  Uint8List buffer(String name) {
    final value = u8[name];
    if (value == null) {
      throw ComputeVmRuntimeException('unknown u8 buffer: $name');
    }
    return value;
  }

  /// Resolve a signed word buffer or throw a descriptive runtime exception.
  Int32List words(String name) {
    final value = i32[name];
    if (value == null) {
      throw ComputeVmRuntimeException('unknown i32 buffer: $name');
    }
    return value;
  }

  /// Invoke [name] and return its signed int32 result.
  ///
  /// [budget] is shared by all nested calls. It must be positive.
  int call(String name, {List<int> args = const <int>[], int? budget}) {
    final id = _module.functionByName[name];
    if (id == null) {
      throw ComputeVmRuntimeException('unknown function: $name');
    }
    final effectiveBudget =
        budget ??
        (_limits.maxBudget < 500 * 1000 ? _limits.maxBudget : 500 * 1000);
    if (effectiveBudget <= 0) {
      throw ArgumentError.value(effectiveBudget, 'budget', 'must be positive');
    }
    if (effectiveBudget > _limits.maxBudget) {
      throw ArgumentError.value(
        effectiveBudget,
        'budget',
        'exceeds the configured maximum ${_limits.maxBudget}',
      );
    }
    final function = _module.functions[id];
    if (args.length != function.parameterCount) {
      throw ComputeVmRuntimeException(
        'function $name expects ${function.parameterCount} arguments, '
        'got ${args.length}',
      );
    }
    for (var index = 0; index < args.length; index++) {
      if (!_isSafeInteger(args[index])) {
        throw ComputeVmRuntimeException(
          'argument $index is outside the cross-platform safe integer range',
        );
      }
    }
    return _ComputeVmRunner(
      module: _module,
      u8: _u8Buffers,
      u8Masks: _u8Masks,
      i32: _i32Buffers,
      hosts: _hosts,
      limits: _limits,
      budget: effectiveBudget,
    ).call(id, args);
  }
}

bool _isSafeInteger(int value) {
  return value >= -_maxSafeInteger && value <= _maxSafeInteger;
}
