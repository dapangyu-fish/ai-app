// nestest verification: load nestest.nes, run automated mode from $C000,
// check result codes at $0002/$0003 (0x00 == pass).
import 'dart:io';
import 'dart:convert';
import 'package:flutter_application_1/json_ui/compute/compute_kernel.dart';

void main(List<String> args) {
  final specJson = File('scripts/nesd/nesd_cpu.json').readAsStringSync();
  final spec = jsonDecode(specJson) as Map<String, dynamic>;
  final cpu = ComputeProgram.compile(spec);

  // load ROM: 16B header + 16KB PRG (NROM), mirror to fill 32KB prg buffer
  final rom = File(const String.fromEnvironment('NESTEST', defaultValue: 'roms/nestest.nes')).readAsBytesSync();
  final prgSize = rom[4] * 16384;
  final prg = cpu.buffer('prg');
  for (var i = 0; i < prgSize; i++) {
    prg[i] = rom[16 + i];
  }
  if (prgSize == 16384) {
    for (var i = 0; i < 16384; i++) {
      prg[16384 + i] = prg[i];
    }
  }

  cpu.call('reset', args: [0xC000]);
  final reg = cpu.words('reg');
  final ram = cpu.buffer('ram');

  // run in chunks, watch for the end-of-test loop or halt
  var total = 0;
  var lastPc = -1, stuck = 0;
  for (var chunk = 0; chunk < 400; chunk++) {
    cpu.call('run', args: [100]);
    total += 100;
    final pc = reg[5];
    if (reg[7] != 0) {
      print('HALT at instr $total, PC=${pc.toRadixString(16)}');
      break;
    }
    if (pc == lastPc) {
      stuck++;
      if (stuck > 3) break;
    } else {
      stuck = 0;
    }
    lastPc = pc;
  }

  final e02 = ram[0x02], e03 = ram[0x03];
  print('ran ~$total instr; final PC=${reg[5].toRadixString(16)} '
      'A=${reg[0].toRadixString(16)} X=${reg[1].toRadixString(16)} '
      'Y=${reg[2].toRadixString(16)} P=${reg[4].toRadixString(16)} '
      'SP=${reg[3].toRadixString(16)}');
  print('result: \$02=0x${e02.toRadixString(16)}  \$03=0x${e03.toRadixString(16)}');
  print(e02 == 0 && e03 == 0
      ? '*** NESTEST PASS (all opcodes correct) ***'
      : '*** FAIL: error codes present (see nestest error-code table) ***');
}
