// QrCode 控件 — 二维码生成
// 支持: data (必填，要编码的字符串), size (默认 200),
//       backgroundColor, color (前景色 默认黑), errorCorrectionLevel (L/M/Q/H)
//
// 扫码功能见 mobile_scanner 包，本控件仅生成
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonQrCodeWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawData = json['data']?.toString() ?? '';
    final data = interpreter.resolveTemplate(rawData);
    final size = (json['size'] as num?)?.toDouble() ?? 200;
    final rawBg = json['backgroundColor']?.toString();
    final bg = _parseColor(
        rawBg != null ? interpreter.resolveTemplate(rawBg) : null);
    final rawColor = json['color']?.toString();
    final fg = _parseColor(
        rawColor != null ? interpreter.resolveTemplate(rawColor) : null);
    final ecLevel = _parseECLevel(json['errorCorrectionLevel']?.toString());

    if (data.isEmpty) {
      return SizedBox(
        width: size,
        height: size,
        child: const Center(child: Text('qr: data 为空')),
      );
    }

    return Container(
      width: size,
      height: size,
      color: bg ?? Colors.white,
      padding: const EdgeInsets.all(8),
      child: QrImageView(
        data: data,
        size: size - 16,
        backgroundColor: bg ?? Colors.white,
        eyeStyle: QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: fg ?? Colors.black,
        ),
        dataModuleStyle: QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: fg ?? Colors.black,
        ),
        errorCorrectionLevel: ecLevel,
      ),
    );
  }

  int _parseECLevel(String? s) {
    switch (s) {
      case 'L':
        return QrErrorCorrectLevel.L;
      case 'Q':
        return QrErrorCorrectLevel.Q;
      case 'H':
        return QrErrorCorrectLevel.H;
      case 'M':
      default:
        return QrErrorCorrectLevel.M;
    }
  }

  Color? _parseColor(String? colorStr) {
    if (colorStr == null || !colorStr.startsWith('#')) return null;
    final hex = colorStr.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    if (hex.length == 8) return Color(int.parse(hex, radix: 16));
    return null;
  }
}
