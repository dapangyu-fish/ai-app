part of '../compute_vm.dart';

const int _instructionWidth = 4;

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
  });

  final List<_VmFunction> functions;
  final Map<String, int> functionByName;
  final List<int> constants;
  final List<_VmCallSite> callSites;
  final List<_VmHostSite> hostSites;
  final List<_VmSwitchSite> switchSites;
  final List<_VmBulkSite> bulkSites;
  final List<String> hostNames;
}

final class _VmFunction {
  const _VmFunction({
    required this.name,
    required this.parameterCount,
    required this.localCount,
    required this.registerCount,
    required this.code,
    required this.basicBlockStarts,
  });

  final String name;
  final int parameterCount;
  final int localCount;
  final int registerCount;
  final Int32List code;
  final Int32List basicBlockStarts;

  int get instructionCount => code.length ~/ _instructionWidth;
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
