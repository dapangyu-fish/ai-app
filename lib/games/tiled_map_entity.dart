import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

import '../json_ui/asset_manager.dart';
import 'game_entity.dart';
import 'game_world.dart';

const int _flipMask = 0xE0000000;

class TiledMapEntity extends GameEntity {
  String source;
  final String? baseUrl;
  final double scale;
  bool loaded = false;
  String? error;
  final Set<String>? includeLayers;
  final Set<String> excludeLayers;
  final Set<String> solidLayers;
  final Set<String> hazardLayers;
  final bool collidable;
  final JsonAppAssetManager assetManager;

  int mapWidth = 0;
  int mapHeight = 0;
  int tileWidth = 64;
  int tileHeight = 64;
  final List<TiledTileset> tilesets = [];
  final List<TiledLayer> layers = [];
  final Map<String, List<TiledObject>> objectsByLayer = {};

  TiledMapEntity({
    required super.id,
    required super.renderConfig,
    super.priority,
    required this.source,
    this.baseUrl,
    this.scale = 1,
    this.includeLayers,
    this.excludeLayers = const {},
    this.solidLayers = const {},
    this.hazardLayers = const {},
    this.collidable = true,
    required this.assetManager,
  });

  double get widthPx => mapWidth * tileWidth * scale;
  double get heightPx => mapHeight * tileHeight * scale;

  Future<void> load() async {
    try {
      final sourceUrl = _resolve(source);
      debugPrint('[tiled_map:$id] load start: $sourceUrl');
      final tmxText = await _loadText(sourceUrl);
      final doc = XmlDocument.parse(tmxText);
      final map = doc.rootElement;
      mapWidth = _intAttr(map, 'width', 0);
      mapHeight = _intAttr(map, 'height', 0);
      tileWidth = _intAttr(map, 'tilewidth', 64);
      tileHeight = _intAttr(map, 'tileheight', 64);

      tilesets.clear();
      for (final ts in map.findElements('tileset')) {
        final firstGid = _intAttr(ts, 'firstgid', 1);
        final tsxSource = ts.getAttribute('source');
        if (tsxSource == null) continue;
        try {
          tilesets.add(
            await _loadTileset(firstGid, tsxSource, relativeTo: sourceUrl),
          );
        } catch (e) {
          debugPrint('[tiled_map:$id] tileset failed: $tsxSource $e');
        }
      }
      tilesets.sort((a, b) => a.firstGid.compareTo(b.firstGid));

      layers.clear();
      objectsByLayer.clear();
      _readMapChildren(map);

      loaded = true;
      error = null;
      debugPrint(
        '[tiled_map:$id] load success: layers=${layers.length} '
        'objects=${objectsByLayer.length} tilesets=${tilesets.length}',
      );
    } catch (e) {
      loaded = false;
      error = e.toString();
      debugPrint('[tiled_map:$id] load error: $error');
    }
  }

  Future<void> loadSource(String nextSource) async {
    source = nextSource;
    loaded = false;
    error = null;
    tilesets.clear();
    layers.clear();
    objectsByLayer.clear();
    await load();
  }

  @override
  void render(Canvas canvas, GameWorld world) {
    if (!loaded) {
      drawShape(canvas, const Offset(24, 24), const Size(280, 40), {
        'shape': 'text',
        'value': error == null ? 'Loading TMX...' : 'TMX load failed',
        'color': '#FFFFFFFF',
        'fontSize': 14,
      });
      return;
    }
    for (final layer in layers) {
      if (!_usesLayer(layer)) continue;
      _renderLayer(canvas, layer);
    }
  }

  @override
  Map<String, dynamic> toMap() => {
    'loaded': loaded,
    'error': error,
    'width': widthPx,
    'height': heightPx,
    'tileWidth': tileWidth * scale,
    'tileHeight': tileHeight * scale,
    'objects': objectsByLayer.map(
      (key, value) => MapEntry(key, value.map((e) => e.toMap()).toList()),
    ),
  };

  List<Rect> solidRectsIn(Rect area) {
    return collisionRectsIn(area)
        .where((collision) => collision.solid)
        .map((collision) => collision.rect)
        .toList(growable: false);
  }

  List<TiledTileCollision> collisionRectsIn(Rect area) {
    if (!loaded || !collidable) return const [];
    final out = <TiledTileCollision>[];
    final tw = tileWidth * scale;
    final th = tileHeight * scale;
    for (final layer in layers) {
      if (!_usesLayer(layer)) continue;
      final minCol = ((area.left - layer.offsetX) / tw).floor().clamp(
        0,
        layer.width - 1,
      );
      final maxCol = ((area.right - layer.offsetX) / tw).ceil().clamp(
        0,
        layer.width - 1,
      );
      final minRow = ((area.top - layer.offsetY) / th).floor().clamp(
        0,
        layer.height - 1,
      );
      final maxRow = ((area.bottom - layer.offsetY) / th).ceil().clamp(
        0,
        layer.height - 1,
      );
      for (int row = minRow; row <= maxRow; row++) {
        for (int col = minCol; col <= maxCol; col++) {
          final idx = row * layer.width + col;
          if (idx < 0 || idx >= layer.gids.length) continue;
          final rawGid = layer.gids[idx];
          final gid = rawGid & ~_flipMask;
          if (gid == 0) continue;
          final tile = _tileForGid(gid);
          if (tile == null) continue;
          final tileX = layer.offsetX + col * tw;
          final tileY = layer.offsetY + row * th;
          final layerSolid = solidLayers.contains(layer.name);
          final layerHazard = hazardLayers.contains(layer.name);
          final type = layerHazard
              ? 'Hazard'
              : layerSolid && tile.type.isEmpty
              ? 'Platform'
              : tile.type;
          final localRects =
              tile.collisionRects.isEmpty &&
                  (tile.solid || layerSolid || layerHazard)
              ? [
                  Rect.fromLTWH(
                    0,
                    0,
                    tile.tileset.tileWidth.toDouble(),
                    tile.tileset.tileHeight.toDouble(),
                  ),
                ]
              : tile.collisionRects;
          for (final local in localRects) {
            final rect = Rect.fromLTWH(
              tileX + local.left * scale,
              tileY + local.top * scale,
              local.width * scale,
              local.height * scale,
            );
            if (rect.overlaps(area)) {
              out.add(
                TiledTileCollision(
                  rect: rect,
                  type: type,
                  properties: tile.properties,
                ),
              );
            }
          }
        }
      }
    }
    return out;
  }

  TiledObject? firstObject(String layer) {
    final objects = objectsByLayer[layer];
    if (objects == null || objects.isEmpty) return null;
    return objects.first;
  }

  bool _usesLayer(TiledLayer layer) {
    if (!layer.visible) return false;
    if (includeLayers != null && !includeLayers!.contains(layer.name)) {
      return false;
    }
    if (excludeLayers.contains(layer.name)) return false;
    return true;
  }

  TiledObjectSprite? spriteForGid(int rawGid) {
    final gid = rawGid & ~_flipMask;
    final ref = _tileForGid(gid);
    if (ref == null || ref.tileset.imageSource.isEmpty) return null;
    return TiledObjectSprite(
      asset: ref.tileset.imageSource,
      srcX: ref.src.left,
      srcY: ref.src.top,
      srcW: ref.src.width,
      srcH: ref.src.height,
    );
  }

  void _readMapChildren(
    XmlElement parent, {
    double offsetX = 0,
    double offsetY = 0,
    bool visible = true,
  }) {
    for (final child in parent.children.whereType<XmlElement>()) {
      final childVisible = visible && child.getAttribute('visible') != '0';
      final childOffsetX = offsetX + _doubleAttr(child, 'offsetx', 0) * scale;
      final childOffsetY = offsetY + _doubleAttr(child, 'offsety', 0) * scale;
      if (child.name.local == 'group') {
        _readMapChildren(
          child,
          offsetX: childOffsetX,
          offsetY: childOffsetY,
          visible: childVisible,
        );
      } else if (child.name.local == 'layer') {
        _readLayer(child, childOffsetX, childOffsetY, childVisible);
      } else if (child.name.local == 'objectgroup') {
        _readObjectGroup(child, childOffsetX, childOffsetY, childVisible);
      }
    }
  }

  void _readLayer(
    XmlElement layer,
    double offsetX,
    double offsetY,
    bool visible,
  ) {
    final data = layer.getElement('data');
    if (data == null) return;
    final encoding = data.getAttribute('encoding') ?? '';
    if (encoding != 'csv') return;
    final csv = data.innerText.trim();
    final gids = csv
        .split(',')
        .map((s) => int.tryParse(s.trim()) ?? 0)
        .toList(growable: false);
    layers.add(
      TiledLayer(
        name: layer.getAttribute('name') ?? '',
        width: _intAttr(layer, 'width', mapWidth),
        height: _intAttr(layer, 'height', mapHeight),
        offsetX: offsetX,
        offsetY: offsetY,
        visible: visible,
        parallaxX: _doubleAttr(layer, 'parallaxx', 1),
        gids: gids,
      ),
    );
  }

  void _readObjectGroup(
    XmlElement group,
    double offsetX,
    double offsetY,
    bool visible,
  ) {
    if (!visible) return;
    final name = group.getAttribute('name') ?? '';
    objectsByLayer[name] = group
        .findElements('object')
        .map((object) {
          return TiledObject(
            id: _intAttr(object, 'id', 0),
            name: object.getAttribute('name') ?? '',
            type: object.getAttribute('type') ?? '',
            x: offsetX + _doubleAttr(object, 'x', 0) * scale,
            y: offsetY + _doubleAttr(object, 'y', 0) * scale,
            width: _doubleAttr(object, 'width', 0) * scale,
            height: _doubleAttr(object, 'height', 0) * scale,
            gid: _intAttr(object, 'gid', 0),
            properties: _readProperties(object),
          );
        })
        .toList(growable: false);
  }

  void _renderLayer(Canvas canvas, TiledLayer layer) {
    final tw = tileWidth * scale;
    final th = tileHeight * scale;
    final clip = canvas.getLocalClipBounds().inflate(math.max(tw, th) * 2);
    final minCol = ((clip.left - layer.offsetX) / tw).floor().clamp(
      0,
      layer.width - 1,
    );
    final maxCol = ((clip.right - layer.offsetX) / tw).ceil().clamp(
      0,
      layer.width - 1,
    );
    final minRow = ((clip.top - layer.offsetY) / th).floor().clamp(
      0,
      layer.height - 1,
    );
    final maxRow = ((clip.bottom - layer.offsetY) / th).ceil().clamp(
      0,
      layer.height - 1,
    );
    final paint = Paint()
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false;

    for (int row = minRow; row <= maxRow; row++) {
      for (int col = minCol; col <= maxCol; col++) {
        final idx = row * layer.width + col;
        if (idx < 0 || idx >= layer.gids.length) continue;
        final rawGid = layer.gids[idx];
        final gid = rawGid & ~_flipMask;
        if (gid == 0) continue;
        final tile = _tileForGid(gid);
        if (tile == null || tile.tileset.image == null) continue;
        final dst = Rect.fromLTWH(
          layer.offsetX + col * tw,
          layer.offsetY + row * th,
          tw,
          th,
        );
        canvas.drawImageRect(tile.tileset.image!, tile.src, dst, paint);
      }
    }
  }

  TiledTileRef? _tileForGid(int gid) {
    TiledTileset? tileset;
    for (final ts in tilesets) {
      if (gid >= ts.firstGid) tileset = ts;
    }
    if (tileset == null) return null;
    final local = gid - tileset.firstGid;
    if (local < 0 || local >= tileset.tileCount) return null;
    final col = local % tileset.columns;
    final row = local ~/ tileset.columns;
    return TiledTileRef(
      tileset: tileset,
      src: Rect.fromLTWH(
        (tileset.margin + col * (tileset.tileWidth + tileset.spacing))
            .toDouble(),
        (tileset.margin + row * (tileset.tileHeight + tileset.spacing))
            .toDouble(),
        tileset.tileWidth.toDouble(),
        tileset.tileHeight.toDouble(),
      ),
      collisionRects: tileset.tileCollision[local] ?? const [],
      type: tileset.tileTypes[local] ?? '',
      properties: tileset.tileProperties[local] ?? const {},
    );
  }

  Future<TiledTileset> _loadTileset(
    int firstGid,
    String tsxSource, {
    String? relativeTo,
  }) async {
    final tsxUrl = _resolve(tsxSource, relativeTo: relativeTo);
    final doc = XmlDocument.parse(await _loadText(tsxUrl));
    final root = doc.rootElement;
    final image = root.getElement('image');
    final imageSource = image?.getAttribute('source') ?? '';
    final imageUrl = _resolve(imageSource, relativeTo: tsxUrl);
    final bytes = await _loadBytes(imageUrl);
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final tileCollision = <int, List<Rect>>{};
    final tileTypes = <int, String>{};
    final tileProperties = <int, Map<String, dynamic>>{};
    for (final tile in root.findElements('tile')) {
      final id = _intAttr(tile, 'id', -1);
      if (id < 0) continue;
      final type =
          tile.getAttribute('type') ?? tile.getAttribute('class') ?? '';
      if (type.isNotEmpty) tileTypes[id] = type;
      final props = _readProperties(tile);
      if (props.isNotEmpty) tileProperties[id] = props;
      final group = tile.getElement('objectgroup');
      if (group == null) continue;
      final rects = <Rect>[];
      for (final object in group.findElements('object')) {
        rects.add(
          Rect.fromLTWH(
            _doubleAttr(object, 'x', 0),
            _doubleAttr(object, 'y', 0),
            _doubleAttr(object, 'width', 0),
            _doubleAttr(object, 'height', 0),
          ),
        );
      }
      if (rects.isNotEmpty) tileCollision[id] = rects;
    }
    return TiledTileset(
      firstGid: firstGid,
      source: tsxUrl,
      imageSource: imageUrl,
      tileWidth: _intAttr(root, 'tilewidth', tileWidth),
      tileHeight: _intAttr(root, 'tileheight', tileHeight),
      tileCount: _intAttr(root, 'tilecount', 0),
      columns: _intAttr(root, 'columns', 1).clamp(1, 1 << 30),
      spacing: _intAttr(root, 'spacing', 0),
      margin: _intAttr(root, 'margin', 0),
      image: frame.image,
      tileCollision: tileCollision,
      tileTypes: tileTypes,
      tileProperties: tileProperties,
    );
  }

  String _resolve(String path, {String? relativeTo}) {
    return assetManager.resolve(path, baseUrl: baseUrl, relativeTo: relativeTo);
  }

  Future<String> _loadText(String path) async {
    final bytes = await _loadBytes(path);
    return utf8.decode(bytes);
  }

  Future<Uint8List> _loadBytes(String path) async {
    return assetManager.loadBytes(path);
  }

  static Map<String, dynamic> _readProperties(XmlElement object) {
    final props = <String, dynamic>{};
    final properties = object.getElement('properties');
    if (properties == null) return props;
    for (final p in properties.findElements('property')) {
      final name = p.getAttribute('name');
      if (name == null) continue;
      final type = p.getAttribute('type') ?? 'string';
      final raw = p.getAttribute('value') ?? p.innerText;
      props[name] = switch (type) {
        'bool' => raw == 'true',
        'int' => int.tryParse(raw),
        'float' => double.tryParse(raw),
        _ => raw,
      };
    }
    return props;
  }

  static int _intAttr(XmlElement e, String name, int fallback) {
    return int.tryParse(e.getAttribute(name) ?? '') ?? fallback;
  }

  static double _doubleAttr(XmlElement e, String name, double fallback) {
    return double.tryParse(e.getAttribute(name) ?? '') ?? fallback;
  }
}

class TiledLayer {
  final String name;
  final int width;
  final int height;
  final double offsetX;
  final double offsetY;
  final bool visible;
  final double parallaxX;
  final List<int> gids;

  const TiledLayer({
    required this.name,
    required this.width,
    required this.height,
    required this.offsetX,
    required this.offsetY,
    required this.visible,
    required this.parallaxX,
    required this.gids,
  });
}

class TiledTileset {
  final int firstGid;
  final String source;
  final String imageSource;
  final int tileWidth;
  final int tileHeight;
  final int tileCount;
  final int columns;
  final int spacing;
  final int margin;
  final ui.Image? image;
  final Map<int, List<Rect>> tileCollision;
  final Map<int, String> tileTypes;
  final Map<int, Map<String, dynamic>> tileProperties;

  const TiledTileset({
    required this.firstGid,
    required this.source,
    required this.imageSource,
    required this.tileWidth,
    required this.tileHeight,
    required this.tileCount,
    required this.columns,
    this.spacing = 0,
    this.margin = 0,
    required this.image,
    required this.tileCollision,
    this.tileTypes = const {},
    this.tileProperties = const {},
  });
}

class TiledObjectSprite {
  final String asset;
  final double srcX;
  final double srcY;
  final double srcW;
  final double srcH;

  const TiledObjectSprite({
    required this.asset,
    required this.srcX,
    required this.srcY,
    required this.srcW,
    required this.srcH,
  });

  Map<String, dynamic> toMap() => {
    'asset': asset,
    'src': [srcX, srcY, srcW, srcH],
  };
}

class TiledTileRef {
  final TiledTileset tileset;
  final Rect src;
  final List<Rect> collisionRects;
  final String type;
  final Map<String, dynamic> properties;

  const TiledTileRef({
    required this.tileset,
    required this.src,
    required this.collisionRects,
    this.type = '',
    this.properties = const {},
  });

  bool get solid {
    final normalized = type.toLowerCase();
    return normalized == 'platform' ||
        normalized == 'slope' ||
        normalized == 'hazard' ||
        collisionRects.isNotEmpty;
  }
}

class TiledTileCollision {
  final Rect rect;
  final String type;
  final Map<String, dynamic> properties;

  const TiledTileCollision({
    required this.rect,
    required this.type,
    this.properties = const {},
  });

  bool get hazard => type.toLowerCase() == 'hazard';

  bool get solid => type.toLowerCase() != 'none';

  Map<String, dynamic> toMap() => {
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
    'type': type,
    'properties': properties,
    ...properties,
  };
}

class TiledObject {
  final int id;
  final String name;
  final String type;
  final double x;
  final double y;
  final double width;
  final double height;
  final int gid;
  final Map<String, dynamic> properties;

  const TiledObject({
    required this.id,
    required this.name,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.gid,
    required this.properties,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'type': type,
    'x': x,
    'y': y,
    'w': width,
    'h': height,
    'gid': gid,
    'properties': properties,
    ...properties,
  };
}
