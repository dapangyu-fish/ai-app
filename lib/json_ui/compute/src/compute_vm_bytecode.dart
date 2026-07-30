part of '../compute_vm.dart';

const int _instructionWidth = 4;
const int _packedDispatchOpcodeBits = 7;
const int _packedDispatchOpcodeMask = (1 << _packedDispatchOpcodeBits) - 1;
const int _packedBinaryOpcodeBits = 6;
const int _packedBinaryOpcodeMask = (1 << _packedBinaryOpcodeBits) - 1;
const int _packedBufferIdBits = 8;
const int _packedBufferIdMask = (1 << _packedBufferIdBits) - 1;
const int _packedRegisterBits = 13;
const int _packedRegisterMask = (1 << _packedRegisterBits) - 1;

// Retain fused bytecode only when it removes at least one in four static
// dispatches. Lower-density functions showed AOT code-layout regressions and
// are safer on the physically separate scalar runner.
const int _minimumFusionSavingsDivisor = 4;

abstract final class _Op {
  static const int constant = 0;
  static const int move = 1;
  static const int loadU8 = 2;
  static const int storeU8 = 3;
  static const int loadI32 = 4;
  static const int storeI32 = 5;

  static const int add = 6;
  static const int subtract = 7;
  static const int multiply = 8;
  static const int divide = 9;
  static const int modulo = 10;
  static const int negate = 11;
  static const int bitAnd = 12;
  static const int bitOr = 13;
  static const int bitXor = 14;
  static const int bitNot = 15;
  static const int shiftLeft = 16;
  static const int shiftRight = 17;
  static const int equal = 18;
  static const int notEqual = 19;
  static const int less = 20;
  static const int lessEqual = 21;
  static const int greater = 22;
  static const int greaterEqual = 23;
  static const int logicalNot = 24;
  static const int minimum = 25;
  static const int maximum = 26;

  static const int jump = 27;
  static const int jumpZero = 28;
  static const int jumpNonZero = 29;
  static const int jumpLessEqualZero = 30;
  static const int switchDispatch = 31;
  static const int decrement = 32;

  static const int call = 33;
  static const int host = 34;
  static const int returnValue = 35;
  static const int memset = 36;
  static const int memlut = 37;

  // Peephole superinstructions retain the scalar sequence's logical cost but
  // avoid dispatching compiler-generated temporary constants and moves.
  static const int constantMove = 38;
  static const int moveMove = 39;
  static const int loadU8Immediate = 40;
  static const int loadI32Immediate = 41;
  static const int loadU8ImmediateMove = 42;
  static const int loadI32ImmediateMove = 43;
  static const int binaryImmediateRight = 44;
  static const int binaryRegisterRight = 45;
  static const int returnImmediate = 46;
  static const int storeU8ImmediateBoth = 47;
  static const int storeI32ImmediateBoth = 48;
  static const int compareImmediateJumpZero = 49;
  static const int compareMovedRegisterJumpZero = 50;
  static const int compareRegisterJumpZero = 51;
  static const int binaryImmediateDistinct = 52;
  static const int constantFoldedBinary = 53;
  static const int planar8 = 54;
  static const int u8RmwImmediate = 55;
  static const int i32RmwImmediate = 56;
  static const int loadU8ImmediateBinaryImmediate = 57;
  static const int loadI32ImmediateBinaryImmediate = 58;
  static const int loadU8ImmediateCompareJumpZero = 59;
  static const int loadI32ImmediateCompareJumpZero = 60;
  static const int binaryImmediatePair = 61;
  static const int constantJumpZero = 62;
  static const int normalizeAndJump = 63;
  static const int binaryImmediateDistinctPair = 64;
  static const int moveCompareImmediateJumpZero = 65;
  static const int moveBinaryImmediateDistinctPair = 66;
}

final class _VmModule {
  const _VmModule({
    required this.functions,
    required this.functionByName,
    required this.constants,
    required this.callSites,
    required this.hostSites,
    required this.switchSites,
    required this.bulkSites,
    required this.hostNames,
    required this.usesFusedBytecode,
    required this.entryUsesFusedBytecode,
  });

  final List<_VmFunction> functions;
  final Map<String, int> functionByName;
  final List<int> constants;
  final List<_VmCallSite> callSites;
  final List<_VmHostSite> hostSites;
  final List<_VmSwitchSite> switchSites;
  final List<_VmBulkSite> bulkSites;
  final List<String> hostNames;
  final bool usesFusedBytecode;

  /// Whether calling each function can reach fused bytecode through the
  /// static call graph. This keeps scalar entry points on the compact runner
  /// even when an unrelated cold helper in the same module is optimized.
  final List<bool> entryUsesFusedBytecode;
}

final class _VmFunction {
  _VmFunction({
    required this.name,
    required this.parameterCount,
    required this.localCount,
    required this.registerCount,
    required this.code,
    required this.logicalInstructionCount,
    required this.logicalSourceStarts,
    required this.logicalCosts,
    required this.basicBlockStarts,
    required this.staticDispatchSavings,
  });

  final String name;
  final int parameterCount;
  final int localCount;
  final int registerCount;
  final Int32List code;

  /// Predecoded bytecode for the fused runner.
  ///
  /// Each instruction header's low bits contain the opcode and the remaining
  /// bits contain the scalar budget cost. Keeping operands in the same list
  /// preserves spatial locality while [code] remains unchanged for compiler
  /// scans, diagnostics, tracing, and the compact scalar runner.
  ///
  /// This stays `null` for modules that use only the scalar runner, avoiding
  /// an unused full bytecode copy for ordinary JSON apps.
  Int32List? dispatchCode;
  final int logicalInstructionCount;

  /// Original scalar instruction that begins each physical instruction span.
  ///
  /// Optimized instructions can cover several contiguous scalar slots. This
  /// map keeps budget failures and diagnostics on the scalar ABI coordinates.
  final Int32List logicalSourceStarts;

  /// Number of original scalar budget slots represented by each physical
  /// instruction. Skipped payload slots of a superinstruction have cost zero.
  final Int32List logicalCosts;

  final Int32List basicBlockStarts;
  final int staticDispatchSavings;

  /// Instruction count in the stable scalar ABI address space.
  int get instructionCount => logicalInstructionCount;

  /// Number of physical bytecode slots after copy elimination.
  ///
  /// Superinstruction payload slots are retained, so the number of actual
  /// dispatches is [instructionCount] - [staticDispatchSavings].
  int get physicalInstructionCount => code.length ~/ _instructionWidth;

  bool get usesFusedBytecode => staticDispatchSavings > 0;
}

final class _VmCallSite {
  const _VmCallSite({
    required this.functionId,
    required this.argumentRegisters,
  });

  final int functionId;
  final Int32List argumentRegisters;
}

final class _VmHostSite {
  const _VmHostSite({required this.hostId, required this.argumentRegisters});

  final int hostId;
  final Int32List argumentRegisters;
}

/// Side-table data for a generic byte-buffer bulk instruction.
///
/// Keeping the buffer IDs and the variable-length register operands here lets
/// every bytecode instruction retain the fixed four-word representation.
final class _VmBulkSite {
  const _VmBulkSite({
    required this.destinationBufferId,
    required this.sourceBufferId,
    required this.lookupBufferId,
    required this.argumentRegisters,
  });

  final int destinationBufferId;

  /// `-1` when the operation has no source buffer.
  final int sourceBufferId;

  /// `-1` when the operation has no lookup buffer.
  final int lookupBufferId;

  final Int32List argumentRegisters;
}

abstract final class _VmSwitchEncoding {
  static const int pending = -1;
  static const int jumpTable = 0;
  static const int binarySearch = 1;
}

/// Side-table data for one `_Op.switchDispatch` instruction.
///
/// A site is reserved before any case body is compiled. That makes nested
/// switches receive distinct IDs even though their outer site is finalized
/// only after all case targets are known.
final class _VmSwitchSite {
  const _VmSwitchSite._({
    required this.encoding,
    required this.defaultTarget,
    required this.minimumKey,
    required this.keys,
    required this.targets,
  });

  _VmSwitchSite.pending()
    : this._(
        encoding: _VmSwitchEncoding.pending,
        defaultTarget: -1,
        minimumKey: 0,
        keys: _emptyInt32List,
        targets: _emptyInt32List,
      );

  _VmSwitchSite.jumpTable({
    required int defaultTarget,
    required int minimumKey,
    required Int32List targets,
  }) : this._(
         encoding: _VmSwitchEncoding.jumpTable,
         defaultTarget: defaultTarget,
         minimumKey: minimumKey,
         keys: _emptyInt32List,
         targets: targets,
       );

  _VmSwitchSite.binarySearch({
    required int defaultTarget,
    required Int32List keys,
    required Int32List targets,
  }) : this._(
         encoding: _VmSwitchEncoding.binarySearch,
         defaultTarget: defaultTarget,
         minimumKey: 0,
         keys: keys,
         targets: targets,
       );

  final int encoding;
  final int defaultTarget;
  final int minimumKey;

  /// Empty for jump tables; sorted ascending for binary-search sites.
  final Int32List keys;

  /// Jump-table slots or targets corresponding one-to-one with [keys].
  final Int32List targets;
}

final Int32List _emptyInt32List = Int32List(0);

final class _FunctionSignature {
  const _FunctionSignature({
    required this.id,
    required this.name,
    required this.parameters,
    required this.body,
  });

  final int id;
  final String name;
  final List<String> parameters;
  final List<dynamic> body;
}

int _int32(int value) => value.toSigned(32);
