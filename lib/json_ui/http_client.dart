// HTTP 客户端封装
// 基于 dio 实现 GET / POST，供解释器 @http_get / @http_post 调用
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

class DslHttpClient {
  static final DslHttpClient _instance = DslHttpClient._internal();
  factory DslHttpClient() => _instance;

  late final Dio _dio;

  DslHttpClient._internal() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
    ));
  }

  /// HTTP GET
  /// 返回 { "status": int, "data": dynamic, "headers": Map, "error": String? }
  Future<Map<String, dynamic>> get(
    String url, {
    Map<String, dynamic>? queryParams,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.get(
        url,
        queryParameters: queryParams,
        options: Options(headers: headers),
      );
      return _buildResult(response);
    } on DioException catch (e) {
      return _buildError(e);
    } catch (e) {
      return {'status': -1, 'data': null, 'headers': {}, 'error': e.toString()};
    }
  }

  /// HTTP POST
  /// 返回 { "status": int, "data": dynamic, "headers": Map, "error": String? }
  Future<Map<String, dynamic>> post(
    String url, {
    dynamic body,
    Map<String, String>? headers,
    String contentType = 'application/json',
  }) async {
    try {
      final response = await _dio.post(
        url,
        data: contentType == 'application/json'
            ? (body is String ? json.decode(body) : body)
            : body,
        options: Options(
          headers: headers,
          contentType: contentType,
        ),
      );
      return _buildResult(response);
    } on DioException catch (e) {
      return _buildError(e);
    } catch (e) {
      return {'status': -1, 'data': null, 'headers': {}, 'error': e.toString()};
    }
  }

  /// HTTP PUT
  Future<Map<String, dynamic>> put(
    String url, {
    dynamic body,
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.put(
        url,
        data: body,
        options: Options(headers: headers, contentType: 'application/json'),
      );
      return _buildResult(response);
    } on DioException catch (e) {
      return _buildError(e);
    } catch (e) {
      return {'status': -1, 'data': null, 'headers': {}, 'error': e.toString()};
    }
  }

  /// HTTP DELETE
  Future<Map<String, dynamic>> delete(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      final response = await _dio.delete(
        url,
        options: Options(headers: headers),
      );
      return _buildResult(response);
    } on DioException catch (e) {
      return _buildError(e);
    } catch (e) {
      return {'status': -1, 'data': null, 'headers': {}, 'error': e.toString()};
    }
  }

  Map<String, dynamic> _buildResult(Response response) {
    return {
      'status': response.statusCode ?? 0,
      'data': response.data,
      'headers': response.headers.map.map((k, v) => MapEntry(k, v.join(', '))),
      'error': null,
    };
  }

  Map<String, dynamic> _buildError(DioException e) {
    debugPrint('[JSON DSL HTTP] 请求失败: ${e.message}');
    return {
      'status': e.response?.statusCode ?? -1,
      'data': e.response?.data,
      'headers': {},
      'error': e.message ?? '网络请求失败',
    };
  }
}
