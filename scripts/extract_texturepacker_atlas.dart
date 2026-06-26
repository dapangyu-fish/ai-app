// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:image/image.dart' as img;

class _Region {
  final String name;
  bool rotate = false;
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;

  _Region(this.name);
}

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln(
      'usage: dart run scripts/extract_texturepacker_atlas.dart <atlas.atlas> <atlas.png> <out-dir>',
    );
    exit(2);
  }

  final atlasFile = File(args[0]);
  final imageFile = File(args[1]);
  final outDir = Directory(args[2])..createSync(recursive: true);
  final source = img.decodeImage(imageFile.readAsBytesSync());
  if (source == null) {
    stderr.writeln('cannot decode image: ${imageFile.path}');
    exit(1);
  }

  final regions = _parseAtlas(atlasFile.readAsLinesSync());
  for (final region in regions) {
    final cropWidth = region.rotate ? region.height : region.width;
    final cropHeight = region.rotate ? region.width : region.height;
    var frame = img.copyCrop(
      source,
      x: region.x,
      y: region.y,
      width: cropWidth,
      height: cropHeight,
    );
    if (region.rotate) {
      frame = img.copyRotate(frame, angle: 90);
    }
    final safeName = region.name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
    File('${outDir.path}/$safeName.png').writeAsBytesSync(img.encodePng(frame));
  }
  stdout.writeln('extracted ${regions.length} atlas regions to ${outDir.path}');
}

List<_Region> _parseAtlas(List<String> lines) {
  final regions = <_Region>[];
  _Region? current;

  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    if (!raw.startsWith(' ') && !line.contains(':')) {
      if (line.endsWith('.png')) continue;
      if (line == 'format' || line == 'filter' || line == 'repeat') continue;
      current = _Region(line);
      regions.add(current);
      continue;
    }
    if (current == null) continue;
    final trimmed = line.trim();
    final split = trimmed.indexOf(':');
    if (split < 0) continue;
    final key = trimmed.substring(0, split).trim();
    final value = trimmed.substring(split + 1).trim();
    switch (key) {
      case 'rotate':
        current.rotate = value == 'true';
      case 'xy':
        final parts = _ints(value);
        if (parts.length >= 2) {
          current.x = parts[0];
          current.y = parts[1];
        }
      case 'size':
        final parts = _ints(value);
        if (parts.length >= 2) {
          current.width = parts[0];
          current.height = parts[1];
        }
    }
  }

  return regions
      .where((r) => r.width > 0 && r.height > 0)
      .toList(growable: false);
}

List<int> _ints(String value) {
  return value
      .split(',')
      .map((p) => int.tryParse(p.trim()))
      .whereType<int>()
      .toList(growable: false);
}
