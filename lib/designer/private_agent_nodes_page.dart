import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_page.dart';
import '../auth/auth_service.dart';
import '../config/app_config.dart';
import 'ai_chat_service.dart';

class PrivateAgentNodesPage extends StatefulWidget {
  const PrivateAgentNodesPage({super.key});

  @override
  State<PrivateAgentNodesPage> createState() => _PrivateAgentNodesPageState();
}

class _PrivateAgentNodesPageState extends State<PrivateAgentNodesPage> {
  final List<_PrivateAgentNode> _nodes = [];
  Map<String, dynamic> _summary = const {};
  bool _loading = false;
  bool _creatingJoin = false;
  String? _busyNodeId;

  @override
  void initState() {
    super.initState();
    _loadNodes();
  }

  String _text({
    required String zh,
    required String en,
    required String de,
    required String es,
  }) {
    switch (Localizations.localeOf(context).languageCode) {
      case 'en':
        return en;
      case 'de':
        return de;
      case 'es':
        return es;
      default:
        return zh;
    }
  }

  Future<http.Response> _authedRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final token = AuthService.token;
    if (token == null) {
      throw Exception(
        _text(
          zh: '请先登录',
          en: 'Please sign in first',
          de: 'Bitte zuerst anmelden',
          es: 'Inicia sesion primero',
        ),
      );
    }
    Future<http.Response> send(String bearer) {
      final headers = <String, String>{
        'Authorization': 'Bearer $bearer',
        if (body != null) 'Content-Type': 'application/json',
      };
      final uri = Uri.parse('${AppConfig.backendUrl}$path');
      final encoded = body == null ? null : json.encode(body);
      switch (method) {
        case 'GET':
          return http
              .get(uri, headers: headers)
              .timeout(const Duration(seconds: 12));
        case 'POST':
          return http
              .post(uri, headers: headers, body: encoded)
              .timeout(const Duration(seconds: 12));
        case 'DELETE':
          return http
              .delete(uri, headers: headers, body: encoded)
              .timeout(const Duration(seconds: 12));
        default:
          throw ArgumentError('unsupported method: $method');
      }
    }

    var resp = await send(token);
    if (resp.statusCode == 401) {
      await AuthService.refreshSession();
      final refreshed = AuthService.token;
      if (refreshed != null) resp = await send(refreshed);
    }
    return resp;
  }

  Map<String, dynamic> _decodeObject(http.Response resp) {
    if (resp.body.isEmpty) return {};
    final data = json.decode(resp.body);
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  Future<void> _loadNodes() async {
    if (!AuthService.isLoggedIn) return;
    setState(() => _loading = true);
    try {
      final resp = await _authedRequest(
        'GET',
        '/api/ai/private_agent/nodes?probe=1',
      );
      final data = _decodeObject(resp);
      if (resp.statusCode >= 400) {
        throw Exception(data['error'] ?? 'HTTP ${resp.statusCode}');
      }
      final rawNodes = data['nodes'] as List<dynamic>? ?? const [];
      if (!mounted) return;
      setState(() {
        _summary = data['summary'] is Map<String, dynamic>
            ? data['summary'] as Map<String, dynamic>
            : const {};
        _nodes
          ..clear()
          ..addAll(
            rawNodes.whereType<Map>().map(
              (item) => _PrivateAgentNode.fromJson(item),
            ),
          );
      });
    } catch (e) {
      if (!mounted) return;
      _snack(
        _text(
          zh: '加载私有 Agent Nodes 失败：$e',
          en: 'Failed to load private Agent Nodes: $e',
          de: 'Private Agent Nodes konnten nicht geladen werden: $e',
          es: 'No se pudieron cargar los Agent Nodes privados: $e',
        ),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createJoinCommand() async {
    if (!AuthService.isLoggedIn) {
      _snack(
        _text(
          zh: '请先登录后再生成私有 Agent Node 加入命令',
          en: 'Sign in before creating a private Agent Node join command',
          de: 'Bitte zuerst anmelden, um einen Private-Agent-Node-Befehl zu erstellen',
          es: 'Inicia sesion antes de crear el comando de union del Agent Node privado',
        ),
      );
      return;
    }
    setState(() => _creatingJoin = true);
    try {
      final provider = AiChatService.selectedProvider;
      final agent = AiChatService.selectedAgentForProvider(provider);
      final resp = await _authedRequest(
        'POST',
        '/api/ai/private_agent/join_token',
        body: {
          'provider_ids': [provider],
          'agent_ids': [agent],
          'ttl_seconds': 900,
          'backend_url': AppConfig.backendUrl,
        },
      );
      final data = _decodeObject(resp);
      if (resp.statusCode >= 400) {
        throw Exception(data['error'] ?? 'HTTP ${resp.statusCode}');
      }
      final command = (data['join_command'] as String?) ?? '';
      if (command.isEmpty) {
        throw Exception('join_command is empty');
      }
      if (!mounted) return;
      _showJoinCommand(command);
    } catch (e) {
      if (!mounted) return;
      _snack(
        _text(
          zh: '生成加入命令失败：$e',
          en: 'Failed to create join command: $e',
          de: 'Join-Befehl konnte nicht erstellt werden: $e',
          es: 'No se pudo crear el comando de union: $e',
        ),
      );
    } finally {
      if (mounted) setState(() => _creatingJoin = false);
    }
  }

  void _openAuthPage() {
    final currentRoute = ModalRoute.of(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AuthPage(
          onAuthSuccess: () {
            if (!mounted) return;
            final navigator = Navigator.of(context);
            if (currentRoute != null) {
              navigator.popUntil((route) => route == currentRoute);
            } else if (navigator.canPop()) {
              navigator.pop();
            }
            setState(() {});
            _loadNodes();
          },
        ),
      ),
    );
  }

  Future<void> _pauseOrResume(_PrivateAgentNode node) async {
    setState(() => _busyNodeId = node.nodeId);
    try {
      final action = node.status == 'paused' ? 'resume' : 'pause';
      final resp = await _authedRequest(
        'POST',
        '/api/ai/private_agent/nodes/${Uri.encodeComponent(node.nodeId)}/$action',
        body: action == 'pause' ? {'reason': 'paused from app settings'} : {},
      );
      final data = _decodeObject(resp);
      if (resp.statusCode >= 400) {
        throw Exception(data['error'] ?? 'HTTP ${resp.statusCode}');
      }
      await _loadNodes();
    } catch (e) {
      if (!mounted) return;
      _snack(
        _text(
          zh: '更新节点状态失败：$e',
          en: 'Failed to update node status: $e',
          de: 'Node-Status konnte nicht aktualisiert werden: $e',
          es: 'No se pudo actualizar el estado del nodo: $e',
        ),
      );
    } finally {
      if (mounted) setState(() => _busyNodeId = null);
    }
  }

  Future<void> _deleteNode(_PrivateAgentNode node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          _text(
            zh: '删除私有 Agent Node',
            en: 'Delete private Agent Node',
            de: 'Private Agent Node loeschen',
            es: 'Eliminar Agent Node privado',
          ),
        ),
        content: Text(
          _text(
            zh: '删除后该节点不能再接收你的私有任务。节点机器上的本地文件和密钥不会被远程删除。',
            en: 'After deletion, this node cannot receive your private jobs. Local files and keys on the host are not removed remotely.',
            de: 'Nach dem Loeschen kann dieser Node keine privaten Jobs mehr empfangen. Lokale Dateien und Schluessel auf dem Host werden nicht entfernt.',
            es: 'Despues de eliminarlo, este nodo no podra recibir tus tareas privadas. Los archivos y claves locales del host no se eliminan remotamente.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              _text(zh: '取消', en: 'Cancel', de: 'Abbrechen', es: 'Cancelar'),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              _text(zh: '删除', en: 'Delete', de: 'Loeschen', es: 'Eliminar'),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busyNodeId = node.nodeId);
    try {
      final resp = await _authedRequest(
        'DELETE',
        '/api/ai/private_agent/nodes/${Uri.encodeComponent(node.nodeId)}',
      );
      final data = _decodeObject(resp);
      if (resp.statusCode >= 400) {
        throw Exception(data['error'] ?? 'HTTP ${resp.statusCode}');
      }
      await _loadNodes();
    } catch (e) {
      if (!mounted) return;
      _snack(
        _text(
          zh: '删除节点失败：$e',
          en: 'Failed to delete node: $e',
          de: 'Node konnte nicht geloescht werden: $e',
          es: 'No se pudo eliminar el nodo: $e',
        ),
      );
    } finally {
      if (mounted) setState(() => _busyNodeId = null);
    }
  }

  Future<void> _editLimits(_PrivateAgentNode node) async {
    final capacityController = TextEditingController(
      text: node.capacity.toString(),
    );
    final queueController = TextEditingController(
      text: node.queueMax.toString(),
    );
    final result = await showModalBottomSheet<Map<String, int>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              16 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _text(
                    zh: '调整节点容量',
                    en: 'Adjust node capacity',
                    de: 'Node-Kapazitaet anpassen',
                    es: 'Ajustar capacidad del nodo',
                  ),
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: capacityController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _text(
                      zh: '最大并发',
                      en: 'Max concurrency',
                      de: 'Max. Parallelitaet',
                      es: 'Concurrencia maxima',
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: queueController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _text(
                      zh: '最大队列',
                      en: 'Max queue',
                      de: 'Max. Warteschlange',
                      es: 'Cola maxima',
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop({
                      'capacity':
                          int.tryParse(capacityController.text.trim()) ??
                          node.capacity,
                      'queue_max':
                          int.tryParse(queueController.text.trim()) ??
                          node.queueMax,
                    });
                  },
                  child: Text(
                    _text(zh: '保存', en: 'Save', de: 'Speichern', es: 'Guardar'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    capacityController.dispose();
    queueController.dispose();
    if (result == null) return;
    setState(() => _busyNodeId = node.nodeId);
    try {
      final resp = await _authedRequest(
        'POST',
        '/api/ai/private_agent/nodes/${Uri.encodeComponent(node.nodeId)}/limits',
        body: result,
      );
      final data = _decodeObject(resp);
      if (resp.statusCode >= 400) {
        throw Exception(data['error'] ?? 'HTTP ${resp.statusCode}');
      }
      await _loadNodes();
    } catch (e) {
      if (!mounted) return;
      _snack(
        _text(
          zh: '调整容量失败：$e',
          en: 'Failed to adjust capacity: $e',
          de: 'Kapazitaet konnte nicht angepasst werden: $e',
          es: 'No se pudo ajustar la capacidad: $e',
        ),
      );
    } finally {
      if (mounted) setState(() => _busyNodeId = null);
    }
  }

  void _showJoinCommand(String command) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              16 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _text(
                    zh: '私有 Agent Node 加入命令',
                    en: 'Private Agent Node join command',
                    de: 'Private-Agent-Node Join-Befehl',
                    es: 'Comando de union del Agent Node privado',
                  ),
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _text(
                    zh: '令牌为一次性短期令牌。复制后在你的 Agent 节点机器上执行，AI 服务商密钥只会保存在那台机器本地。',
                    en: 'This is a one-time short-lived token. Run it on your agent host; provider keys stay local on that host.',
                    de: 'Dies ist ein kurzlebiges Einmal-Token. Fuehre den Befehl auf deinem Agent-Host aus; Provider-Schluessel bleiben dort lokal.',
                    es: 'Es un token corto de un solo uso. Ejecutalo en tu host agent; las claves del proveedor quedan locales en ese host.',
                  ),
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      command,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.copy),
                  label: Text(
                    _text(
                      zh: '复制命令',
                      en: 'Copy command',
                      de: 'Befehl kopieren',
                      es: 'Copiar comando',
                    ),
                  ),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final copied = _text(
                      zh: '已复制私有 Agent Node 加入命令',
                      en: 'Private Agent Node join command copied',
                      de: 'Private-Agent-Node-Befehl kopiert',
                      es: 'Comando del Agent Node privado copiado',
                    );
                    await Clipboard.setData(ClipboardData(text: command));
                    if (!ctx.mounted) return;
                    Navigator.of(ctx).pop();
                    messenger.showSnackBar(SnackBar(content: Text(copied)));
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _text(
            zh: '私有 Agent Nodes',
            en: 'Private Agent Nodes',
            de: 'Private Agent Nodes',
            es: 'Agent Nodes privados',
          ),
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: _text(
              zh: '刷新',
              en: 'Refresh',
              de: 'Aktualisieren',
              es: 'Actualizar',
            ),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _loadNodes,
          ),
        ],
      ),
      body: SafeArea(
        child: !AuthService.isLoggedIn
            ? _buildLoginRequired(cs)
            : RefreshIndicator(
                onRefresh: _loadNodes,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildHeader(cs),
                    const SizedBox(height: 12),
                    if (_loading && _nodes.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_nodes.isEmpty)
                      _buildEmptyState(cs)
                    else
                      ..._nodes.map((node) => _buildNodeCard(node, cs)),
                  ],
                ),
              ),
      ),
      floatingActionButton: AuthService.isLoggedIn
          ? FloatingActionButton.extended(
              onPressed: _creatingJoin ? null : _createJoinCommand,
              icon: _creatingJoin
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_link),
              label: Text(
                _text(
                  zh: '加入节点',
                  en: 'Join node',
                  de: 'Node anbinden',
                  es: 'Unir nodo',
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildLoginRequired(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, color: cs.outline, size: 36),
            const SizedBox(height: 12),
            Text(
              _text(
                zh: '登录后可以注册和管理只属于你的私有 Agent Node。',
                en: 'Sign in to register and manage private Agent Nodes that only belong to you.',
                de: 'Melde dich an, um private Agent Nodes zu registrieren und zu verwalten.',
                es: 'Inicia sesion para registrar y gestionar Agent Nodes privados solo tuyos.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openAuthPage,
              icon: const Icon(Icons.login),
              label: Text(
                _text(
                  zh: '去登录',
                  en: 'Sign in',
                  de: 'Anmelden',
                  es: 'Iniciar sesion',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs) {
    final total = _summaryInt('total');
    final online = _summaryInt('online');
    final running = _summaryInt('active_runs');
    final capacity = _summaryInt('capacity');
    final queued = _summaryInt('queued');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.private_connectivity_outlined, color: cs.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _text(
                      zh: '我的私有节点',
                      en: 'My private nodes',
                      de: 'Meine privaten Nodes',
                      es: 'Mis nodos privados',
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _metricChip(
                  cs,
                  _text(zh: '总数', en: 'Total', de: 'Gesamt', es: 'Total'),
                  '$total',
                ),
                _metricChip(
                  cs,
                  _text(zh: '在线', en: 'Online', de: 'Online', es: 'En linea'),
                  '$online',
                ),
                _metricChip(
                  cs,
                  _text(zh: '运行', en: 'Running', de: 'Aktiv', es: 'Activos'),
                  '$running/$capacity',
                ),
                _metricChip(
                  cs,
                  _text(zh: '队列', en: 'Queue', de: 'Warteschlange', es: 'Cola'),
                  '$queued',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.hub_outlined, color: cs.outline, size: 36),
            const SizedBox(height: 12),
            Text(
              _text(
                zh: '还没有私有 Agent Node',
                en: 'No private Agent Nodes yet',
                de: 'Noch keine privaten Agent Nodes',
                es: 'Aun no hay Agent Nodes privados',
              ),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              _text(
                zh: '点击右下角生成加入命令，在你的机器上执行后会出现在这里。',
                en: 'Tap the button below to create a join command. Run it on your host and it will appear here.',
                de: 'Tippe unten auf den Button, erstelle einen Join-Befehl und fuehre ihn auf deinem Host aus.',
                es: 'Toca el boton para crear un comando de union. Ejecutalo en tu host y aparecera aqui.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNodeCard(_PrivateAgentNode node, ColorScheme cs) {
    final busy = _busyNodeId == node.nodeId;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  _statusIcon(node.status),
                  color: _statusColor(node.status, cs),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        node.displayName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (node.displayName != node.nodeId) ...[
                        const SizedBox(height: 2),
                        Text(
                          node.nodeId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        '${node.activeRuns}/${node.capacity} ${_text(zh: '运行', en: 'running', de: 'aktiv', es: 'activos')} · ${node.queueDepth}/${node.queueMax} ${_text(zh: '队列', en: 'queued', de: 'Warteschlange', es: 'cola')}',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _statusChip(node.status, cs),
                for (final provider in node.providerIds)
                  _metricChip(cs, 'provider', provider),
                for (final agent in node.agentIds)
                  _metricChip(cs, 'agent', agent),
                if (node.version.isNotEmpty)
                  _metricChip(cs, 'version', node.version),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _pauseOrResume(node),
                  icon: Icon(
                    node.status == 'paused' ? Icons.play_arrow : Icons.pause,
                  ),
                  label: Text(
                    node.status == 'paused'
                        ? _text(
                            zh: '恢复',
                            en: 'Resume',
                            de: 'Fortsetzen',
                            es: 'Reanudar',
                          )
                        : _text(
                            zh: '暂停',
                            en: 'Pause',
                            de: 'Pausieren',
                            es: 'Pausar',
                          ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _editLimits(node),
                  icon: const Icon(Icons.tune),
                  label: Text(
                    _text(zh: '容量', en: 'Limits', de: 'Limits', es: 'Limites'),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _deleteNode(node),
                  icon: const Icon(Icons.delete_outline),
                  label: Text(
                    _text(
                      zh: '删除',
                      en: 'Delete',
                      de: 'Loeschen',
                      es: 'Eliminar',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  int _summaryInt(String key) {
    final value = _summary[key];
    if (value is int) return value;
    return int.tryParse('$value') ?? 0;
  }

  Widget _metricChip(ColorScheme cs, String label, String value) {
    return Chip(
      visualDensity: VisualDensity.compact,
      label: Text('$label $value'),
      backgroundColor: cs.surfaceContainerHighest,
      side: BorderSide(color: cs.outlineVariant),
    );
  }

  Widget _statusChip(String status, ColorScheme cs) {
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        _statusIcon(status),
        size: 16,
        color: _statusColor(status, cs),
      ),
      label: Text(status.isEmpty ? '-' : status),
      backgroundColor: _statusColor(status, cs).withValues(alpha: 0.10),
      side: BorderSide(color: _statusColor(status, cs).withValues(alpha: 0.25)),
    );
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'online':
        return Icons.check_circle_outline;
      case 'paused':
        return Icons.pause_circle_outline;
      case 'down':
      case 'stale':
        return Icons.error_outline;
      default:
        return Icons.radio_button_unchecked;
    }
  }

  Color _statusColor(String status, ColorScheme cs) {
    switch (status) {
      case 'online':
        return Colors.green;
      case 'paused':
        return Colors.orange;
      case 'down':
      case 'stale':
        return cs.error;
      default:
        return cs.outline;
    }
  }
}

class _PrivateAgentNode {
  final String nodeId;
  final String name;
  final String status;
  final List<String> providerIds;
  final List<String> agentIds;
  final int activeRuns;
  final int capacity;
  final int queueDepth;
  final int queueMax;
  final String version;

  const _PrivateAgentNode({
    required this.nodeId,
    required this.name,
    required this.status,
    required this.providerIds,
    required this.agentIds,
    required this.activeRuns,
    required this.capacity,
    required this.queueDepth,
    required this.queueMax,
    required this.version,
  });

  factory _PrivateAgentNode.fromJson(Map<dynamic, dynamic> json) {
    return _PrivateAgentNode(
      nodeId: _str(json['node_id']),
      name: _str(json['name'] ?? json['display_name']),
      status: _str(json['status']),
      providerIds: _list(json['provider_ids']),
      agentIds: _list(json['agent_ids']),
      activeRuns: _int(json['active_runs']),
      capacity: _int(json['capacity']),
      queueDepth: _int(json['queue_depth']),
      queueMax: _int(json['queue_max']),
      version: _str(json['version']),
    );
  }

  String get displayName => name.isNotEmpty ? name : nodeId;

  static String _str(dynamic value) => value == null ? '' : '$value';

  static int _int(dynamic value) {
    if (value is int) return value;
    return int.tryParse('$value') ?? 0;
  }

  static List<String> _list(dynamic value) {
    if (value is List) {
      return value
          .map((item) => '$item')
          .where((item) => item.isNotEmpty)
          .toList();
    }
    if (value is String && value.isNotEmpty) {
      return value
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();
    }
    return const [];
  }
}
