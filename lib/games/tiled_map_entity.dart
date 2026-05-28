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
const int _flipHorizontal = 0x80000000;
const int _flipVertical = 0x40000000;
const int _flipDiagonal = 0x20000000;

class TiledMapEntity extends GameEntity {
  String source;
  Map<String, dynamic>? mapData;
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
    this.mapData,
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
      layers.clear();
      objectsByLayer.clear();
      tilesets.clear();

      if (mapData != null) {
        debugPrint('[tiled_map:$id] load inline map_data');
        await _loadFromJson(mapData!);
      } else {
        final sourceUrl = _resolve(source);
        debugPrint('[tiled_map:$id] load start: $sourceUrl');
        final text = await _loadText(sourceUrl);
        if (text.trimLeft().startsWith('{')) {
          final data = json.decode(text) as Map<String, dynamic>;
          await _loadFromJson(data, sourceUrl: sourceUrl);
        } else {
          await _loadFromTmx(text, sourceUrl);
        }
      }

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

  Future<void> _loadFromTmx(String tmxText, String sourceUrl) async {
    final doc = XmlDocument.parse(tmxText);
    final map = doc.rootElement;
    mapWidth = _intAttr(map, 'width', 0);
    mapHeight = _intAttr(map, 'height', 0);
    tileWidth = _intAttr(map, 'tilewidth', 64);
    tileHeight = _intAttr(map, 'tileheight', 64);

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

    _readMapChildren(map);
  }

  Future<void> _loadFromJson(
    Map<String, dynamic> data, {
    String? sourceUrl,
  }) async {
    final inlineSource = data['source']?.toString();
    final effectiveSourceUrl =
        sourceUrl ??
        (inlineSource == null || inlineSource.isEmpty
            ? null
            : _resolve(inlineSource));
    mapWidth = _intValue(data['width'], 0);
    mapHeight = _intValue(data['height'], 0);
    tileWidth = _intValue(data['tilewidth'] ?? data['tileWidth'], 64);
    tileHeight = _intValue(data['tileheight'] ?? data['tileHeight'], 64);

    final rawTilesets = data['tilesets'];
    if (rawTilesets is List) {
      for (final raw in rawTilesets) {
        final ts = _asStringMap(raw);
        if (ts == null) continue;
        final firstGid = _intValue(ts['firstgid'] ?? ts['firstGid'], 1);
        final tsSource = ts['source']?.toString();
        try {
          if (_hasInlineTilesetData(ts)) {
            tilesets.add(
              await _loadTilesetFromJson(
                firstGid,
                ts,
                relativeTo: effectiveSourceUrl,
              ),
            );
          } else if (tsSource != null && tsSource.isNotEmpty) {
            tilesets.add(
              await _loadTileset(
                firstGid,
                tsSource,
                relativeTo: effectiveSourceUrl,
              ),
            );
          }
        } catch (e) {
          debugPrint('[tiled_map:$id] json tileset failed: $tsSource $e');
        }
      }
    }
    tilesets.sort((a, b) => a.firstGid.compareTo(b.firstGid));

    final rawLayers = data['layers'];
    if (rawLayers is List) {
      _readJsonChildren(rawLayers);
    }
  }

  Future<void> loadSource(String nextSource) async {
    source = nextSource;
    mapData = null;
    await _reload();
  }

  Future<void> loadMapData(Map<String, dynamic> nextMapData) async {
    source = '';
    mapData = nextMapData;
    await _reload();
  }

  Future<void> _reload() async {
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
      _renderLayer(canvas, world, layer);
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
          final visualH = tile.tileset.tileHeight * scale;
          final tileX = layer.offsetX + col * tw;
          final tileY = layer.offsetY + row * th + th - visualH;
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
                  tileset: tile.tileset.name,
                  properties: tile.properties,
                ),
              );
            }
          }
        }
      }
    }
    for (final entry in objectsByLayer.entries) {
      final layerName = entry.key;
      final layerSolid = solidLayers.contains(layerName);
      final layerHazard = hazardLayers.contains(layerName);
      if (!layerSolid && !layerHazard) continue;
      for (final object in entry.value) {
        if (object.width <= 0 || object.height <= 0) continue;
        final rect = Rect.fromLTWH(
          object.x,
          object.y,
          object.width,
          object.height,
        );
        if (!rect.overlaps(area)) continue;
        out.add(
          TiledTileCollision(
            rect: rect,
            type: object.type.isNotEmpty
                ? object.type
                : layerHazard
                ? 'Hazard'
                : 'Platform',
            tileset: layerName,
            properties: object.properties,
          ),
        );
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

  void _readJsonChildren(
    List<dynamic> children, {
    double offsetX = 0,
    double offsetY = 0,
    bool visible = true,
  }) {
    for (final raw in children) {
      final child = _asStringMap(raw);
      if (child == null) continue;
      final type = child['type']?.toString() ?? child['kind']?.toString() ?? '';
      final childVisible = visible && _boolValue(child['visible'], true);
      final childOffsetX = offsetX + _doubleValue(child['offsetx'], 0) * scale;
      final childOffsetY = offsetY + _doubleValue(child['offsety'], 0) * scale;
      if (type == 'group') {
        final nested = child['layers'] ?? child['children'];
        if (nested is List) {
          _readJsonChildren(
            nested,
            offsetX: childOffsetX,
            offsetY: childOffsetY,
            visible: childVisible,
          );
        }
      } else if (type == 'tilelayer' || child.containsKey('data')) {
        _readJsonLayer(child, childOffsetX, childOffsetY, childVisible);
      } else if (type == 'objectgroup' || child.containsKey('objects')) {
        _readJsonObjectGroup(child, childOffsetX, childOffsetY, childVisible);
      }
    }
  }

  void _readJsonLayer(
    Map<String, dynamic> layer,
    double offsetX,
    double offsetY,
    bool visible,
  ) {
    final data = layer['data'];
    final gids = switch (data) {
      List() =>
        data.map((value) => _intValue(value, 0)).toList(growable: false),
      String() =>
        data
            .split(',')
            .map((value) => int.tryParse(value.trim()) ?? 0)
            .toList(growable: false),
      _ => const <int>[],
    };
    layers.add(
      TiledLayer(
        name: layer['name']?.toString() ?? '',
        width: _intValue(layer['width'], mapWidth),
        height: _intValue(layer['height'], mapHeight),
        offsetX: offsetX,
        offsetY: offsetY,
        visible: visible,
        parallaxX: _doubleValue(layer['parallaxx'] ?? layer['parallaxX'], 1),
        parallaxY: _doubleValue(layer['parallaxy'] ?? layer['parallaxY'], 1),
        gids: gids,
      ),
    );
  }

  void _readJsonObjectGroup(
    Map<String, dynamic> group,
    double offsetX,
    double offsetY,
    bool visible,
  ) {
    if (!visible) return;
    final name = group['name']?.toString() ?? '';
    final objects = group['objects'];
    objectsByLayer[name] = objects is List
        ? objects
              .map(_asStringMap)
              .whereType<Map<String, dynamic>>()
              .map(
                (object) => TiledObject(
                  id: _intValue(object['id'], 0),
                  name: object['name']?.toString() ?? '',
                  type:
                      object['type']?.toString() ??
                      object['class']?.toString() ??
                      '',
                  x: offsetX + _doubleValue(object['x'], 0) * scale,
                  y: offsetY + _doubleValue(object['y'], 0) * scale,
                  width:
                      _doubleValue(object['width'] ?? object['w'], 0) * scale,
                  height:
                      _doubleValue(object['height'] ?? object['h'], 0) * scale,
                  gid: _intValue(object['gid'], 0),
                  properties: _readJsonProperties(object['properties']),
                ),
              )
              .toList(growable: false)
        : const <TiledObject>[];
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
        parallaxY: _doubleAttr(layer, 'parallaxy', 1),
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
          final gid = _intAttr(object, 'gid', 0);
          final width = _doubleAttr(object, 'width', 0) * scale;
          final height = _doubleAttr(object, 'height', 0) * scale;
          return TiledObject(
            id: _intAttr(object, 'id', 0),
            name: object.getAttribute('name') ?? '',
            type: object.getAttribute('type') ?? '',
            x: offsetX + _doubleAttr(object, 'x', 0) * scale,
            y: offsetY + _doubleAttr(object, 'y', 0) * scale,
            width: width,
            height: height,
            gid: gid,
            properties: _readProperties(object),
          );
        })
        .toList(growable: false);
  }

  void _renderLayer(Canvas canvas, GameWorld world, TiledLayer layer) {
    final tw = tileWidth * scale;
    final th = tileHeight * scale;
    final maxTileExtent = tilesets.fold<double>(math.max(tw, th), (
      current,
      tileset,
    ) {
      return math.max(
        current,
        math.max(tileset.tileWidth * scale, tileset.tileHeight * scale),
      );
    });
    final clip = canvas.getLocalClipBounds().inflate(maxTileExtent * 2);
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
        final drawW = tile.tileset.tileWidth * scale;
        final drawH = tile.tileset.tileHeight * scale;
        final dst = Rect.fromLTWH(
          layer.offsetX + col * tw + world.cameraX * (1 - layer.parallaxX),
          layer.offsetY +
              row * th +
              th -
              drawH +
              world.cameraY * (1 - layer.parallaxY),
          drawW,
          drawH,
        );
        _drawTile(canvas, tile.tileset.image!, tile.src, dst, rawGid, paint);
      }
    }
  }

  void _drawTile(
    Canvas canvas,
    ui.Image image,
    Rect src,
    Rect dst,
    int rawGid,
    Paint paint,
  ) {
    final flipH = (rawGid & _flipHorizontal) != 0;
    final flipV = (rawGid & _flipVertical) != 0;
    final flipD = (rawGid & _flipDiagonal) != 0;
    if (!flipH && !flipV && !flipD) {
      canvas.drawImageRect(image, src, dst, paint);
      return;
    }

    canvas.save();
    canvas.translate(dst.center.dx, dst.center.dy);
    if (flipD) {
      canvas.rotate(math.pi / 2);
      canvas.scale(flipV ? -1.0 : 1.0, flipH ? -1.0 : 1.0);
    } else {
      canvas.scale(flipH ? -1.0 : 1.0, flipV ? -1.0 : 1.0);
    }
    final localDst = Rect.fromCenter(
      center: Offset.zero,
      width: dst.width,
      height: dst.height,
    );
    canvas.drawImageRect(image, src, localDst, paint);
    canvas.restore();
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
      name: root.getAttribute('name') ?? '',
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

  Future<TiledTileset> _loadTilesetFromJson(
    int firstGid,
    Map<String, dynamic> data, {
    String? relativeTo,
  }) async {
    final source = data['source']?.toString() ?? '';
    final sourceUrl = source.isEmpty
        ? relativeTo
        : _resolve(source, relativeTo: relativeTo);
    final rawImage =
        data['image']?.toString() ??
        data['imageSource']?.toString() ??
        data['image_source']?.toString() ??
        '';
    final imageUrl = rawImage.isEmpty
        ? ''
        : _resolve(rawImage, relativeTo: sourceUrl);
    ui.Image? image;
    if (imageUrl.isNotEmpty) {
      final bytes = await _loadBytes(imageUrl);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      image = frame.image;
    }

    final tileCollision = <int, List<Rect>>{};
    final tileTypes = <int, String>{};
    final tileProperties = <int, Map<String, dynamic>>{};
    final rawTiles = data['tiles'];
    if (rawTiles is List) {
      for (final rawTile in rawTiles) {
        final tile = _asStringMap(rawTile);
        if (tile == null) continue;
        final id = _intValue(tile['id'], -1);
        if (id < 0) continue;
        final type =
            tile['type']?.toString() ?? tile['class']?.toString() ?? '';
        if (type.isNotEmpty) tileTypes[id] = type;
        final props = _readJsonProperties(tile['properties']);
        if (props.isNotEmpty) tileProperties[id] = props;

        final rects = <Rect>[];
        final collision = tile['collision'];
        if (collision is List) {
          for (final rawRect in collision) {
            final rect = _asStringMap(rawRect);
            if (rect == null) continue;
            rects.add(
              Rect.fromLTWH(
                _doubleValue(rect['x'], 0),
                _doubleValue(rect['y'], 0),
                _doubleValue(rect['width'] ?? rect['w'], 0),
                _doubleValue(rect['height'] ?? rect['h'], 0),
              ),
            );
          }
        }
        final objectGroup = _asStringMap(tile['objectgroup']);
        final objects = objectGroup?['objects'];
        if (objects is List) {
          for (final rawObject in objects) {
            final object = _asStringMap(rawObject);
            if (object == null) continue;
            rects.add(
              Rect.fromLTWH(
                _doubleValue(object['x'], 0),
                _doubleValue(object['y'], 0),
                _doubleValue(object['width'] ?? object['w'], 0),
                _doubleValue(object['height'] ?? object['h'], 0),
              ),
            );
          }
        }
        if (rects.isNotEmpty) tileCollision[id] = rects;
      }
    }

    return TiledTileset(
      firstGid: firstGid,
      name: data['name']?.toString() ?? '',
      source: sourceUrl ?? '',
      imageSource: imageUrl,
      tileWidth: _intValue(data['tilewidth'] ?? data['tileWidth'], tileWidth),
      tileHeight: _intValue(
        data['tileheight'] ?? data['tileHeight'],
        tileHeight,
      ),
      tileCount: _intValue(data['tilecount'] ?? data['tileCount'], 0),
      columns: _intValue(data['columns'], 1).clamp(1, 1 << 30),
      spacing: _intValue(data['spacing'], 0),
      margin: _intValue(data['margin'], 0),
      image: image,
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

  static Map<String, dynamic> _readJsonProperties(dynamic rawProperties) {
    if (rawProperties is Map) {
      return rawProperties.map((key, value) => MapEntry(key.toString(), value));
    }
    if (rawProperties is List) {
      final out = <String, dynamic>{};
      for (final raw in rawProperties) {
        final prop = _asStringMap(raw);
        if (prop == null) continue;
        final name = prop['name']?.toString();
        if (name == null) continue;
        out[name] = prop.containsKey('value')
            ? prop['value']
            : prop['text']?.toString();
      }
      return out;
    }
    return const {};
  }

  static bool _hasInlineTilesetData(Map<String, dynamic> data) {
    return data.containsKey('image') ||
        data.containsKey('imageSource') ||
        data.containsKey('image_source') ||
        data.containsKey('tiles') ||
        data.containsKey('tilewidth') ||
        data.containsKey('tileWidth');
  }

  static Map<String, dynamic>? _asStringMap(dynamic value) {
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  static int _intAttr(XmlElement e, String name, int fallback) {
    return int.tryParse(e.getAttribute(name) ?? '') ?? fallback;
  }

  static double _doubleAttr(XmlElement e, String name, double fallback) {
    return double.tryParse(e.getAttribute(name) ?? '') ?? fallback;
  }

  static int _intValue(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static double _doubleValue(dynamic value, double fallback) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static bool _boolValue(dynamic value, bool fallback) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return fallback;
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
  final double parallaxY;
  final List<int> gids;

  const TiledLayer({
    required this.name,
    required this.width,
    required this.height,
    required this.offsetX,
    required this.offsetY,
    required this.visible,
    required this.parallaxX,
    required this.parallaxY,
    required this.gids,
  });
}

class TiledTileset {
  final int firstGid;
  final String name;
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
    required this.name,
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
  final String tileset;
  final Map<String, dynamic> properties;

  const TiledTileCollision({
    required this.rect,
    required this.type,
    this.tileset = '',
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
    'tileset': tileset,
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
