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
import 'dart:convert';
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
  static const int _putMaxAttempts = 3;

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
    final contentType =
        overrideContentType ??
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
      final resp = await http
          .post(
            Uri.parse('$_backendUrl/api/im/media/upload-url'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: json.encode({
              'purpose': purpose.name,
              'ext': ext,
              'content_type': contentType,
              'size': size,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode != 200) {
        debugPrint('[IM Uploader] 申请预签名失败 ${resp.statusCode}: ${resp.body}');
        return null;
      }
      final data = json.decode(resp.body) as Map<String, dynamic>;
      final put = data['put_url']?.toString();
      final pub = data['public_url']?.toString();
      final key = data['key']?.toString();
      if (put == null || pub == null || key == null) {
        debugPrint('[IM Uploader] 后端响应缺字段: ${resp.body}');
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
    // 用 dart:io HttpClient 而不是 http 包，因为 http 不支持上传进度。
    // 直传链路会经过移动网络 + edge-nginx + MinIO，偶发 5xx/连接断开时
    // 对同一个预签名 PUT URL 短重试是安全的：object key 相同，成功后结果一致。
    final total = await file.length();
    final uri = Uri.parse(putUrl);
    for (var attempt = 1; attempt <= _putMaxAttempts; attempt++) {
      try {
        final ok = await _putAttempt(
          uri: uri,
          file: file,
          contentType: contentType,
          total: total,
          attempt: attempt,
          onProgress: onProgress,
        );
        if (ok) return true;
        return false;
      } on _RetryablePutFailure {
        if (attempt == _putMaxAttempts) {
          return false;
        }
        await Future.delayed(_putRetryDelay(attempt));
      } catch (e) {
        debugPrint(
          '[IM Uploader] PUT 异常 (attempt $attempt/$_putMaxAttempts): $e',
        );
        if (attempt == _putMaxAttempts) {
          return false;
        }
        await Future.delayed(_putRetryDelay(attempt));
      }
    }
    return false;
  }

  static bool _isRetryablePutStatus(int statusCode) {
    return statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode == 500 ||
        statusCode == 502 ||
        statusCode == 503 ||
        statusCode == 504;
  }

  static Duration _putRetryDelay(int attempt) {
    return switch (attempt) {
      1 => const Duration(milliseconds: 500),
      2 => const Duration(milliseconds: 1200),
      _ => const Duration(milliseconds: 2000),
    };
  }

  /// 单次 PUT 上传。拆出来是为了让状态码重试和网络异常重试共用外层循环，
  /// 不重复写流式上传逻辑。
  static Future<bool> _putAttempt({
    required Uri uri,
    required File file,
    required String contentType,
    required int total,
    required int attempt,
    void Function(int sent, int total)? onProgress,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.putUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      req.contentLength = total;

      int sent = 0;
      await for (final chunk in file.openRead()) {
        req.add(chunk);
        sent += chunk.length;
        if (onProgress != null) onProgress(sent, total);
      }
      final resp = await req.close();
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        await resp.drain<void>();
        return true;
      }
      final errBody = await resp.transform(utf8.decoder).join();
      debugPrint(
        '[IM Uploader] PUT 失败 ${resp.statusCode} '
        '(attempt $attempt/$_putMaxAttempts): $errBody',
      );
      if (!_isRetryablePutStatus(resp.statusCode)) return false;
      throw _RetryablePutFailure();
    } finally {
      client.close(force: false);
    }
  }
}

class _RetryablePutFailure implements Exception {}

class _PresignedUpload {
  final String putUrl;
  final String publicUrl;
  final String key;
  _PresignedUpload({
    required this.putUrl,
    required this.publicUrl,
    required this.key,
  });
}
