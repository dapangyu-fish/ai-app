// ImagePicker 控件
// 跨平台图片选择器（iOS / Android / Web / macOS）
// 支持：source (gallery/camera)、bind (绑定选中图片路径到变量)、
//       placeholder、width、height、borderRadius
// 选中图片后自动预览，再次点击可重新选择
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonImagePickerWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final bindPath = json['bind'] as String?;
    final placeholder = json['placeholder']?.toString() ?? '点击选择图片';
    final width = (json['width'] as num?)?.toDouble() ?? double.infinity;
    final height = (json['height'] as num?)?.toDouble() ?? 200;
    final borderRadius = (json['borderRadius'] as num?)?.toDouble() ?? 12;
    final sourceStr = json['source']?.toString() ?? 'gallery';

    // 当前已选中的图片路径
    final currentPath = bindPath != null
        ? interpreter.getVariable(bindPath)?.toString()
        : null;
    final hasImage = currentPath != null && currentPath.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: GestureDetector(
        onTap: () => _pickImage(context, interpreter, bindPath, sourceStr),
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
              width: 1.5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: hasImage
              ? Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildImagePreview(currentPath, context),
                    // 重新选择遮罩
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        color: Colors.black45,
                        child: const Text(
                          '点击重新选择',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      sourceStr == 'camera' ? Icons.camera_alt : Icons.photo_library,
                      size: 40,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      placeholder,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildImagePreview(String path, BuildContext context) {
    if (kIsWeb || path.startsWith('http://') || path.startsWith('https://')) {
      return Image.network(
        path,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _errorWidget(context),
      );
    }
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _errorWidget(context),
    );
  }

  Widget _errorWidget(BuildContext context) {
    return Center(
      child: Icon(Icons.broken_image,
          size: 40, color: Theme.of(context).colorScheme.error),
    );
  }

  Future<void> _pickImage(
    BuildContext context,
    JsonInterpreter interpreter,
    String? bindPath,
    String sourceStr,
  ) async {
    final picker = ImagePicker();
    final source = sourceStr == 'camera'
        ? ImageSource.camera
        : ImageSource.gallery;

    try {
      final XFile? picked = await picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (picked != null && bindPath != null) {
        interpreter.setVariable(bindPath, picked.path);
      }
    } catch (e) {
      debugPrint('[JSON DSL] 图片选择失败: $e');
      // camera 不可用时 fallback 到 gallery
      if (source == ImageSource.camera) {
        try {
          final XFile? picked = await picker.pickImage(
            source: ImageSource.gallery,
            maxWidth: 1920,
            maxHeight: 1920,
            imageQuality: 85,
          );
          if (picked != null && bindPath != null) {
            interpreter.setVariable(bindPath, picked.path);
          }
        } catch (e2) {
          debugPrint('[JSON DSL] 图片选择 fallback 也失败: $e2');
        }
      }
    }
  }
}
