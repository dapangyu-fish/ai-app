import 'dart:io';
import 'dart:convert';
import 'package:flutter_application_1/json_ui/compute/compute_kernel.dart';
void main() {
  final spec = jsonDecode(File('scripts/nesd/nesd_cpu.json').readAsStringSync()) as Map<String, dynamic>;
  final cpu = ComputeProgram.compile(spec);
  final rom = File(const String.fromEnvironment('NESTEST', defaultValue: 'roms/nestest.nes')).readAsBytesSync();
  final prg = cpu.buffer('prg');
  for (var i = 0; i < 16384; i++) { prg[i] = rom[16 + i]; prg[16384 + i] = rom[16 + i]; }
  cpu.call('reset', args: [0xC000]);
  final reg = cpu.words('reg');
  String hex(int v, [int w = 2]) => v.toRadixString(16).toUpperCase().padLeft(w, '0');
  for (var i = 0; i < 30; i++) {
    final pc = reg[5];
    print('${hex(pc, 4)}  A:${hex(reg[0])} X:${hex(reg[1])} Y:${hex(reg[2])} '
        'P:${hex(reg[4])} SP:${hex(reg[3])}');
    cpu.call('step');
  }
}
