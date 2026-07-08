import 'dart:io';
import 'dart:convert';
import 'package:flutter_application_1/json_ui/compute/compute_kernel.dart';
void main() {
  final spec = jsonDecode(File('scripts/nesd/nesd_nes.json').readAsStringSync()) as Map<String, dynamic>;
  final nes = ComputeProgram.compile(spec, hosts: {'input': (a) => 0});
  final rom = File('scripts/nesd/apu_test.nes').readAsBytesSync();
  final prg = nes.buffer('prg');
  for (var i = 0; i < 16384; i++) { prg[i] = rom[16 + i]; prg[16384 + i] = rom[16 + i]; }
  nes.call('power_on', args: [0]);
  for (var f = 0; f < 3; f++) { nes.call('run_frame', args: [80000], budget: 400000000); }
  final samples = nes.buffer('samples');
  final ap = nes.words('a');
  final sidx = ap[71], apucyc = ap[69], sacc = ap[70];
  print('SIDX=$sidx APUCYC=$apucyc SACC=$sacc  TP1=${ap[4]} L1V=${ap[13]} EN1=${ap[0]}');
  final vals = <int>[];
  for (var i = 0; i < sidx && i < 4000; i++) {
    var v = samples[i * 2] | (samples[i * 2 + 1] << 8);
    if (v >= 32768) v -= 65536;
    vals.add(v);
  }
  if (vals.isEmpty) { print('no samples'); return; }
  final distinct = vals.toSet();
  final maxv = vals.reduce((a, b) => a > b ? a : b);
  final minv = vals.reduce((a, b) => a < b ? a : b);
  print('count=${vals.length} distinct=${distinct.length} min=$minv max=$maxv');
  var edges = 0; bool lastHigh = false;
  for (final v in vals) {
    final high = v > maxv ~/ 2;
    if (high != lastHigh) { edges++; lastHigh = high; }
  }
  final seconds = vals.length / 48000.0;
  final freq = seconds > 0 ? (edges / 2) / seconds : 0;
  print('edges=$edges  est freq=${freq.toStringAsFixed(1)} Hz (expect ~440)');
}
