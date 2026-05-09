// IM 富媒体上传器
//
// 流程：
//   1. POST /api/im/media/upload-url 拿预签名 PUT URL + 公网 GET URL
//   2. PUT 文件 body 直传到 MinIO（不经过 Flask，省后端内存）
//   3. 返回公网 URL，调用方拿去喂给 OpenIM SDK 的 createXxxMessageByURL
//
// 用法：
//   final url = await ImMediaUploader.uploadFile(
//     File('/path/to/x.jpg'),
//     purpose: ImMediaPurpose.image,
//     onProgress: (sent, total) => debugPrint('$sent/$total'),
//   );
//   if (url != null) await IMService.instance.sendImageByUrl(...);
//
// 失败约定：返回 null + debugPrint。调用方负责 toast / 重试。

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mime/mime.dart' as mime_pkg;
import 'package:path/path.dart' as p;

import '../auth/auth_service.dart';
import '../config/app_config.dart';

/// 后端 SIZE_LIMITS / ALLOWED_EXT 的 enum 镜像。新增 purpose 时两边一起改。
enum ImMediaPurpose {
  image,
  snapshot, // 视频首帧缩略图
  video,
  file;

  String get name => switch (this) {
        ImMediaPurpose.image => 'image',
        ImMediaPurpose.snapshot => 'snapshot',
        ImMediaPurpose.video => 'video',
        ImMediaPurpose.file => 'file',
      };
}

class ImMediaUploadResult {
  final String publicUrl;
  final String key;
  ImMediaUploadResult({required this.publicUrl, required this.key});
}

class ImMediaUploader {
  static String get _backendUrl => AppConfig.backendUrl;

  /// 上传 [file]，成功返回 public URL。失败返回 null。
  ///
  /// [onProgress] 是 PUT 直传阶段的回调（sent / total），
  /// 申请预签名那一步在毫秒级，没必要单独回调。
  static Future<String?> uploadFile(
    File file, {
    required ImMediaPurpose purpose,
    String? overrideContentType,
    void Function(int sent, int total)? onProgress,
  }) async {
    final r = await uploadFileFull(
      file,
      purpose: purpose,
      overrideContentType: overrideContentType,
      onProgress: onProgress,
    );
    return r?.publicUrl;
  }

  /// 完整版：拿到的 key / URL 都返。OpenIM 撤回时若想顺手删 MinIO 文件，
  /// 这里的 key 是 minio object key，将来加 /api/im/media/delete 用得上。
  static Future<ImMediaUploadResult?> uploadFileFull(
    File file, {
    required ImMediaPurpose purpose,
    String? overrideContentType,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (!await file.exists()) {
      debugPrint('[IM Uploader] 文件不存在: ${file.path}');
      return null;
    }
    final size = await file.length();
    final ext = p.extension(file.path).toLowerCase().replaceFirst('.', '');
    if (ext.isEmpty) {
      debugPrint('[IM Uploader] 文件没后缀，无法上传: ${file.path}');
      return null;
    }
    final contentType = overrideContentType ??
        mime_pkg.lookupMimeType(file.path) ??
        'application/octet-stream';

    // 1. 拿预签名
    final sign = await _requestUploadUrl(
      purpose: purpose,
      ext: ext,
      contentType: contentType,
      size: size,
    );
    if (sign == null) return null;

    // 2. PUT 直传
    final ok = await _putToMinio(
      putUrl: sign.putUrl,
      file: file,
      contentType: contentType,
      onProgress: onProgress,
    );
    if (!ok) return null;

    return ImMediaUploadResult(publicUrl: sign.publicUrl, key: sign.key);
  }

  // ---------- internals ----------

  static Future<_PresignedUpload?> _requestUploadUrl({
    required ImMediaPurpose purpose,
    required String ext,
    required String contentType,
    required int size,
  }) async {
    final token = AuthService.token;
    if (token == null) {
      debugPrint('[IM Uploader] 没登录，拒绝');
      return null;
    }
    try {
      final resp = await http.post(
        Uri.parse('$_backendUrl/api/im/media/upload-url'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: '{"purpose":"${purpose.name}","ext":"$ext","content_type":"$contentType","size":$size}',
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        debugPrint('[IM Uploader] 申请预签名失败 ${resp.statusCode}: ${resp.body}');
        return null;
      }
      final body = resp.body;
      // 简单 JSON 提取，避免引入 json.decode 全套（也可以用 dart:convert，无所谓）
      final put = _extract(body, 'put_url');
      final pub = _extract(body, 'public_url');
      final key = _extract(body, 'key');
      if (put == null || pub == null || key == null) {
        debugPrint('[IM Uploader] 后端响应缺字段: $body');
        return null;
      }
      return _PresignedUpload(putUrl: put, publicUrl: pub, key: key);
    } catch (e) {
      debugPrint('[IM Uploader] 申请预签名异常: $e');
      return null;
    }
  }

  static Future<bool> _putToMinio({
    required String putUrl,
    required File file,
    required String contentType,
    void Function(int sent, int total)? onProgress,
  }) async {
    try {
      // 用 dart:io HttpClient 而不是 http 包，因为 http 不支持上传进度
      final total = await file.length();
      final uri = Uri.parse(putUrl);
      final client = HttpClient();
      try {
        final req = await client.putUrl(uri);
        req.headers.set(HttpHeaders.contentTypeHeader, contentType);
        req.contentLength = total;

        // 流式 read + 写，每个 chunk 触发 onProgress
        int sent = 0;
        await for (final chunk in file.openRead()) {
          req.add(chunk);
          sent += chunk.length;
          if (onProgress != null) onProgress(sent, total);
        }
        final resp = await req.close();
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          // 把 body 抽干，避免连接 dangling
          await resp.drain<void>();
          return true;
        }
        final errBody = await resp.transform(const SystemEncoding().decoder).join();
        debugPrint('[IM Uploader] PUT 失败 ${resp.statusCode}: $errBody');
        return false;
      } finally {
        client.close(force: false);
      }
    } catch (e) {
      debugPrint('[IM Uploader] PUT 异常: $e');
      return false;
    }
  }

  /// 从 JSON 字符串里抠 "key": "value" 形式的字段。仅用于已知后端响应格式。
  /// 后端字段值不含 quote / 反斜杠，所以这个简单提取够用，且省 dart:convert 依赖。
  static String? _extract(String json, String key) {
    final pattern = RegExp('"${RegExp.escape(key)}"\\s*:\\s*"([^"]*)"');
    final m = pattern.firstMatch(json);
    return m?.group(1);
  }
}

class _PresignedUpload {
  final String putUrl;
  final String publicUrl;
  final String key;
  _PresignedUpload({required this.putUrl, required this.publicUrl, required this.key});
}
