/// Drift 数据库管理器 — 按 appid 隔离数据库实例
///
/// 每个 JSON-APP 通过 appid 获得独立的 SQLite 数据库文件，
/// 表结构动态创建（无需 codegen），使用 drift 的 raw SQL 接口。
import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';

// ═══════════════════════════════════════════════════════════
//  动态 Drift 数据库（无 codegen，pure raw SQL）
// ═══════════════════════════════════════════════════════════

class AppDatabase extends GeneratedDatabase {
  AppDatabase(QueryExecutor e) : super(e);

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          // 创建默认的 kv_store 表（通用键值存储）
          await customStatement('''
            CREATE TABLE IF NOT EXISTS kv_store (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL,
              updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
            )
          ''');
        },
      );

  // ── 动态建表 ──
  Future<void> ensureTable(String tableName, List<Map<String, String>> columns) async {
    final colDefs = columns.map((col) {
      final name = col['name']!;
      final type = col['type']?.toUpperCase() ?? 'TEXT';
      final pk = col['primary'] == 'true' ? ' PRIMARY KEY' : '';
      return '$name $type$pk';
    }).join(', ');

    await customStatement('CREATE TABLE IF NOT EXISTS "$tableName" ($colDefs)');
  }

  // ── 插入 ──
  Future<int> insertRow(String tableName, Map<String, dynamic> data) async {
    final keys = data.keys.toList();
    final placeholders = keys.map((_) => '?').join(', ');
    final values = keys.map((k) => _encodeValue(data[k])).toList();

    final result = await customInsert(
      'INSERT INTO "$tableName" (${keys.map((k) => '"$k"').join(', ')}) VALUES ($placeholders)',
      variables: values.map((v) => Variable(v)).toList(),
    );
    return result;
  }

  // ── 查询 ──
  Future<List<Map<String, dynamic>>> queryRows(
    String tableName, {
    String? where,
    List<dynamic>? whereArgs,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    var sql = 'SELECT * FROM "$tableName"';
    final vars = <Variable>[];

    if (where != null && where.isNotEmpty) {
      sql += ' WHERE $where';
      if (whereArgs != null) {
        for (final a in whereArgs) {
          vars.add(Variable(_encodeValue(a)));
        }
      }
    }
    if (orderBy != null && orderBy.isNotEmpty) {
      sql += ' ORDER BY $orderBy';
    }
    if (limit != null) {
      sql += ' LIMIT $limit';
    }
    if (offset != null) {
      sql += ' OFFSET $offset';
    }

    final rows = await customSelect(sql, variables: vars).get();
    return rows.map((row) => _decodeRow(row.data)).toList();
  }

  // ── 更新 ──
  Future<int> updateRows(
    String tableName,
    Map<String, dynamic> data, {
    required String where,
    List<dynamic>? whereArgs,
  }) async {
    final setClauses = data.keys.map((k) => '"$k" = ?').join(', ');
    final values = data.values.map((v) => Variable(_encodeValue(v))).toList();

    if (whereArgs != null) {
      for (final a in whereArgs) {
        values.add(Variable(_encodeValue(a)));
      }
    }

    return await customUpdate(
      'UPDATE "$tableName" SET $setClauses WHERE $where',
      variables: values,
    );
  }

  // ── 删除 ──
  Future<int> deleteRows(
    String tableName, {
    required String where,
    List<dynamic>? whereArgs,
  }) async {
    final vars = <Variable>[];
    if (whereArgs != null) {
      for (final a in whereArgs) {
        vars.add(Variable(_encodeValue(a)));
      }
    }

    return await customUpdate(
      'DELETE FROM "$tableName" WHERE $where',
      variables: vars,
    );
  }

  // ── 计数 ──
  Future<int> countRows(String tableName, {String? where, List<dynamic>? whereArgs}) async {
    var sql = 'SELECT COUNT(*) as cnt FROM "$tableName"';
    final vars = <Variable>[];
    if (where != null && where.isNotEmpty) {
      sql += ' WHERE $where';
      if (whereArgs != null) {
        for (final a in whereArgs) {
          vars.add(Variable(_encodeValue(a)));
        }
      }
    }
    final rows = await customSelect(sql, variables: vars).get();
    return rows.first.data['cnt'] as int? ?? 0;
  }

  // ── KV 存储 ──
  Future<void> kvSet(String key, dynamic value) async {
    final encoded = json.encode(value);
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await customStatement(
      'INSERT OR REPLACE INTO kv_store (key, value, updated_at) VALUES (?, ?, ?)',
      [key, encoded, ts],
    );
  }

  Future<dynamic> kvGet(String key) async {
    final rows = await customSelect(
      'SELECT value FROM kv_store WHERE key = ?',
      variables: [Variable(key)],
    ).get();
    if (rows.isEmpty) return null;
    return json.decode(rows.first.data['value'] as String);
  }

  Future<void> kvDelete(String key) async {
    await customStatement('DELETE FROM kv_store WHERE key = ?', [key]);
  }

  // ── 辅助 ──
  dynamic _encodeValue(dynamic v) {
    if (v == null) return null;
    if (v is int || v is double || v is String || v is bool) return v;
    // Map / List → JSON 字符串
    return json.encode(v);
  }

  Map<String, dynamic> _decodeRow(Map<String, dynamic> row) {
    return row.map((key, value) {
      if (value is String && value.startsWith('{') || value is String && value.startsWith('[')) {
        try {
          return MapEntry(key, json.decode(value));
        } catch (_) {}
      }
      return MapEntry(key, value);
    });
  }
}

// ═══════════════════════════════════════════════════════════
//  数据库管理器 — 单例，管理所有 appid 对应的数据库实例
// ═══════════════════════════════════════════════════════════

class DriftDatabaseManager {
  DriftDatabaseManager._();
  static final DriftDatabaseManager instance = DriftDatabaseManager._();

  final Map<String, AppDatabase> _databases = {};

  /// 获取指定 appid 的数据库实例（懒加载 + 缓存）
  AppDatabase getDatabase(String appId) {
    if (_databases.containsKey(appId)) {
      return _databases[appId]!;
    }

    // 使用 drift_flutter 创建平台适配的数据库
    // 文件名格式: app_<appid>.db → 物理隔离
    final dbName = 'app_${_sanitize(appId)}';
    debugPrint('[DriftDB] Creating database for appId=$appId → $dbName.sqlite');

    final db = AppDatabase(
      driftDatabase(name: dbName),
    );
    _databases[appId] = db;
    return db;
  }

  /// 关闭指定 appid 的数据库
  Future<void> closeDatabase(String appId) async {
    final db = _databases.remove(appId);
    if (db != null) {
      await db.close();
      debugPrint('[DriftDB] Closed database for appId=$appId');
    }
  }

  /// 关闭所有数据库
  Future<void> closeAll() async {
    for (final entry in _databases.entries) {
      await entry.value.close();
      debugPrint('[DriftDB] Closed database for appId=${entry.key}');
    }
    _databases.clear();
  }

  /// 安全化 appid 作为文件名
  String _sanitize(String appId) {
    return appId.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
  }
}
