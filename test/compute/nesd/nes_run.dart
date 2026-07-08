import 'dart:io';
import 'dart:convert';
import 'package:flutter_application_1/json_ui/compute/compute_kernel.dart';

const nesPalette = [ // 64-entry NES palette (RGB), standard
 0x626262,0x001FB2,0x2404C8,0x5200B2,0x730076,0x800024,0x730B00,0x522800,
 0x244400,0x005700,0x005C00,0x005324,0x003C76,0x000000,0x000000,0x000000,
 0xABABAB,0x0D57FF,0x4B30FF,0x8A13FF,0xBC08D6,0xD21269,0xC72E00,0x9D5400,
 0x607B00,0x209800,0x00A300,0x009942,0x007DB4,0x000000,0x000000,0x000000,
 0xFFFFFF,0x53AEFF,0x9085FF,0xD365FF,0xFF57FF,0xFF5DCF,0xFF7757,0xFA9E00,
 0xBDC700,0x7AE700,0x43F611,0x26EF7E,0x2CD5F6,0x4E4E4E,0x000000,0x000000,
 0xFFFFFF,0xB6E1FF,0xCED1FF,0xE9C3FF,0xFFBCFF,0xFFBDF4,0xFFC6C3,0xFFD59A,
 0xE9E681,0xCEF481,0xB6FB9A,0xA9FAC3,0xA9F0F6,0xB8B8B8,0x000000,0x000000,
];

void main() {
  final spec = jsonDecode(File('scripts/nesd/nesd_nes.json').readAsStringSync()) as Map<String, dynamic>;
  final nes = ComputeProgram.compile(spec, hosts: {'input': (a) => 0});
  final rom = File('scripts/nesd/nes_test.nes').readAsBytesSync();
  final prg = nes.buffer('prg'), chr = nes.buffer('chr');
  for (var i = 0; i < 16384; i++) { prg[i] = rom[16 + i]; prg[16384 + i] = rom[16 + i]; }
  for (var i = 0; i < 8192; i++) { chr[i] = rom[16 + 16384 + i]; }
  final mirror = rom[6] & 1; // 0=horizontal,1=vertical
  nes.call('power_on', args: [0, 1, mirror]);

  for (var f = 0; f < 4; f++) {
    nes.call('run_frame', args: [80000], budget: 400000000);
  }
  final fb = nes.buffer('fb');
  final pp = nes.words('p');
  print('after frames: scanline=${pp[8]} cycle=${pp[9]} frames=${pp[10]} '
      'STATUS=0x${pp[6].toRadixString(16)} MASK=0x${pp[5].toRadixString(16)} '
      'v=0x${pp[0].toRadixString(16)} PC=0x${nes.words('reg')[5].toRadixString(16)}');

  // assert diagonal hatch: fb[y*256+x] == 0x30 iff (x&7)==(y&7) else 0x0F
  var ok = 0, bad = 0;
  for (var y = 0; y < 240; y += 13) {
    for (var x = 0; x < 256; x += 7) {
      final want = ((x & 7) == (y & 7)) ? 0x30 : 0x0F;
      if (fb[y * 256 + x] == want) { ok++; } else { bad++; }
    }
  }
  print('pixel assertions: $ok correct, $bad wrong');
  // distinct palette indices present
  final seen = <int>{};
  for (final v in fb) { seen.add(v); }
  print('distinct fb palette indices: ${seen.map((v) => '0x${v.toRadixString(16)}').toList()}');

  // dump PNG
  final png = _encodePng(fb);
  File('nes_frame.png').writeAsBytesSync(png);
  print('wrote nes_frame.png');
}

List<int> _encodePng(List<int> fb) {
  // build RGB raw then minimal PNG (uncompressed via zlib stored blocks)
  final w = 256, h = 240;
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0); // filter none
    for (var x = 0; x < w; x++) {
      final c = nesPalette[fb[y * 256 + x] & 0x3f];
      raw.addByte((c >> 16) & 0xFF); raw.addByte((c >> 8) & 0xFF); raw.addByte(c & 0xFF);
    }
  }
  final rawBytes = raw.toBytes();
  final comp = ZLibEncoder().encode(rawBytes);
  final out = BytesBuilder();
  out.add([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A]);
  void chunk(String type, List<int> data) {
    final len = data.length;
    out.add([(len>>24)&0xFF,(len>>16)&0xFF,(len>>8)&0xFF,len&0xFF]);
    final td = <int>[...type.codeUnits, ...data];
    out.add(td);
    final crc = _crc32(td);
    out.add([(crc>>24)&0xFF,(crc>>16)&0xFF,(crc>>8)&0xFF,crc&0xFF]);
  }
  chunk('IHDR', [(w>>24)&0xFF,(w>>16)&0xFF,(w>>8)&0xFF,w&0xFF,
                 (h>>24)&0xFF,(h>>16)&0xFF,(h>>8)&0xFF,h&0xFF, 8,2,0,0,0]);
  chunk('IDAT', comp);
  chunk('IEND', []);
  return out.toBytes();
}

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1);
    }
  }
  return crc ^ 0xFFFFFFFF;
}
