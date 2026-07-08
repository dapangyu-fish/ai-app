import 'dart:io';
import 'dart:convert';
import 'package:flutter_application_1/json_ui/compute/compute_kernel.dart';
const nesPalette = [
 0x626262,0x001FB2,0x2404C8,0x5200B2,0x730076,0x800024,0x730B00,0x522800,
 0x244400,0x005700,0x005C00,0x005324,0x003C76,0x000000,0x000000,0x000000,
 0xABABAB,0x0D57FF,0x4B30FF,0x8A13FF,0xBC08D6,0xD21269,0xC72E00,0x9D5400,
 0x607B00,0x209800,0x00A300,0x009942,0x007DB4,0x000000,0x000000,0x000000,
 0xFFFFFF,0x53AEFF,0x9085FF,0xD365FF,0xFF57FF,0xFF5DCF,0xFF7757,0xFA9E00,
 0xBDC700,0x7AE700,0x43F611,0x26EF7E,0x2CD5F6,0x4E4E4E,0x000000,0x000000,
 0xFFFFFF,0xB6E1FF,0xCED1FF,0xE9C3FF,0xFFBCFF,0xFFBDF4,0xFFC6C3,0xFFD59A,
 0xE9E681,0xCEF481,0xB6FB9A,0xA9FAC3,0xA9F0F6,0xB8B8B8,0x000000,0x000000,
];
void main(List<String> args) {
  final romPath = args[0];
  final frames = args.length > 1 ? int.parse(args[1]) : 40;
  final out = args.length > 2 ? args[2] : 'out.png';
  final spec = jsonDecode(File('scripts/nesd/nesd_nes.json').readAsStringSync()) as Map<String, dynamic>;
  final nes = ComputeProgram.compile(spec, hosts: {'input': (a) => 0});
  final rom = File(romPath).readAsBytesSync();
  final prgBanks = rom[4], chrBanks = rom[5];
  final prgSize = prgBanks * 16384;
  final prg = nes.buffer('prg');
  for (var i = 0; i < prgSize && i < prg.length; i++) prg[i] = rom[16 + i];
  if (prgSize == 16384) for (var i = 0; i < 16384; i++) prg[16384 + i] = prg[i];
  if (chrBanks > 0) {
    final chr = nes.buffer('chr');
    for (var i = 0; i < 8192 && 16 + prgSize + i < rom.length; i++) chr[i] = rom[16 + prgSize + i];
  }
  nes.call('power_on', args: [rom[6] & 1]);
  for (var f = 0; f < frames; f++) nes.call('run_frame', args: [200000], budget: 800000000);
  final fb = nes.buffer('fb');
  final seen = <int>{}; for (final v in fb) seen.add(v);
  print('frames=$frames distinct fb indices=${seen.length}  PC=0x${nes.words('reg')[5].toRadixString(16)}');
  final raw = BytesBuilder();
  for (var y = 0; y < 240; y++) { raw.addByte(0);
    for (var x = 0; x < 256; x++) { final c = nesPalette[fb[y*256+x]&0x3f];
      raw.addByte((c>>16)&0xFF); raw.addByte((c>>8)&0xFF); raw.addByte(c&0xFF); } }
  final comp = zlib.encode(raw.toBytes());
  final o = BytesBuilder(); o.add([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]);
  void chunk(String t, List<int> d) { final l=d.length;
    o.add([(l>>24)&0xFF,(l>>16)&0xFF,(l>>8)&0xFF,l&0xFF]); final td=[...t.codeUnits,...d]; o.add(td);
    var crc=0xFFFFFFFF; for(final b in td){crc^=b; for(var i=0;i<8;i++)crc=(crc&1)!=0?(0xEDB88320^(crc>>1)):(crc>>1);} crc^=0xFFFFFFFF;
    o.add([(crc>>24)&0xFF,(crc>>16)&0xFF,(crc>>8)&0xFF,crc&0xFF]); }
  chunk('IHDR',[0,0,1,0,0,0,0,240,8,2,0,0,0]);
  chunk('IDAT',comp); chunk('IEND',[]);
  File(out).writeAsBytesSync(o.toBytes());
  print('wrote $out');
}
