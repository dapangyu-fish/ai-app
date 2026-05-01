// Chart 控件 — 简单图表
// 支持三种 kind：
//   - line: 折线图，data 是 [{x, y}] 数组
//   - bar: 柱状图，data 是 [{label, value}] 数组
//   - pie: 饼图，data 是 [{label, value, color?}] 数组
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonChartWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final kind = json['kind']?.toString() ?? 'line';
    final height = (json['height'] as num?)?.toDouble() ?? 240;
    final width = (json['width'] as num?)?.toDouble();
    final rawData = interpreter.resolveExpression(json['data']);
    final data = rawData is List ? rawData : const [];
    final rawColor = json['color']?.toString();
    final color = _parseColor(
            rawColor != null ? interpreter.resolveTemplate(rawColor) : null) ??
        Theme.of(context).colorScheme.primary;

    Widget chart;
    switch (kind) {
      case 'bar':
        chart = _buildBar(data, color);
        break;
      case 'pie':
        chart = _buildPie(data);
        break;
      case 'line':
      default:
        chart = _buildLine(data, color);
    }

    return SizedBox(
      width: width,
      height: height,
      child: Padding(padding: const EdgeInsets.all(8), child: chart),
    );
  }

  Widget _buildLine(List data, Color color) {
    final spots = <FlSpot>[];
    for (var i = 0; i < data.length; i++) {
      final item = data[i];
      double x = i.toDouble();
      double y = 0;
      if (item is Map) {
        final mx = item['x'];
        final my = item['y'];
        if (mx is num) x = mx.toDouble();
        if (my is num) y = my.toDouble();
      } else if (item is num) {
        y = item.toDouble();
      }
      spots.add(FlSpot(x, y));
    }
    if (spots.isEmpty) return const Center(child: Text('No data'));

    return LineChart(LineChartData(
      gridData: const FlGridData(show: true),
      borderData: FlBorderData(show: false),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          color: color,
          barWidth: 3,
          isCurved: true,
          dotData: const FlDotData(show: true),
        ),
      ],
    ));
  }

  Widget _buildBar(List data, Color color) {
    final groups = <BarChartGroupData>[];
    final labels = <String>[];
    for (var i = 0; i < data.length; i++) {
      final item = data[i];
      if (item is! Map) continue;
      final v = item['value'];
      if (v is! num) continue;
      labels.add(item['label']?.toString() ?? '$i');
      groups.add(BarChartGroupData(x: i, barRods: [
        BarChartRodData(toY: v.toDouble(), color: color, width: 20),
      ]));
    }
    if (groups.isEmpty) return const Center(child: Text('No data'));

    return BarChart(BarChartData(
      barGroups: groups,
      gridData: const FlGridData(show: true),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (val, _) {
              final i = val.toInt();
              if (i < 0 || i >= labels.length) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(labels[i],
                    style: const TextStyle(fontSize: 10)),
              );
            },
          ),
        ),
        leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 28)),
        rightTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles:
            const AxisTitles(sideTitles: SideTitles(showTitles: false)),
      ),
    ));
  }

  Widget _buildPie(List data) {
    final palette = <Color>[
      const Color(0xFF6C5CE7),
      const Color(0xFF00B894),
      const Color(0xFFE17055),
      const Color(0xFF0984E3),
      const Color(0xFFFD79A8),
      const Color(0xFFFDCB6E),
      const Color(0xFF636E72),
    ];

    final sections = <PieChartSectionData>[];
    var i = 0;
    for (final item in data) {
      if (item is! Map) continue;
      final v = item['value'];
      if (v is! num) continue;
      final colorStr = item['color']?.toString();
      final color = _parseColor(colorStr) ?? palette[i % palette.length];
      sections.add(PieChartSectionData(
        value: v.toDouble(),
        title: item['label']?.toString() ?? '',
        color: color,
        radius: 80,
        titleStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ));
      i++;
    }
    if (sections.isEmpty) return const Center(child: Text('No data'));

    return PieChart(PieChartData(sections: sections, sectionsSpace: 2));
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}
