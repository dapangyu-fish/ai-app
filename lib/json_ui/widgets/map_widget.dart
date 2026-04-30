// Map 控件 — 基于 OpenStreetMap (无需 API key)
// 支持: latitude, longitude (中心), zoom (默认 13),
//       markers ([{latitude, longitude, label?}]),
//       height (默认 300), width
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonMapWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final lat = (json['latitude'] as num?)?.toDouble() ?? 39.9042;
    final lng = (json['longitude'] as num?)?.toDouble() ?? 116.4074;
    final zoom = (json['zoom'] as num?)?.toDouble() ?? 13;
    final height = (json['height'] as num?)?.toDouble() ?? 300;
    final width = (json['width'] as num?)?.toDouble();

    final markers = <Marker>[];
    final rawMarkers = interpreter.resolveExpression(json['markers']);
    if (rawMarkers is List) {
      for (final m in rawMarkers) {
        if (m is! Map) continue;
        final mlat = m['latitude'];
        final mlng = m['longitude'];
        if (mlat is! num || mlng is! num) continue;
        markers.add(Marker(
          point: LatLng(mlat.toDouble(), mlng.toDouble()),
          width: 40,
          height: 40,
          child: const Icon(Icons.location_on, color: Colors.red, size: 36),
        ));
      }
    }

    return SizedBox(
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
            (json['borderRadius'] as num?)?.toDouble() ?? 0),
        child: FlutterMap(
          options: MapOptions(
            initialCenter: LatLng(lat, lng),
            initialZoom: zoom,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.dapangyu.fish.myapp',
            ),
            if (markers.isNotEmpty) MarkerLayer(markers: markers),
          ],
        ),
      ),
    );
  }
}
