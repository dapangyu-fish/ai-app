import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_storage.dart';
import 'sherpa_asr_service.dart';
import 'ai_chat_service.dart';

// 语音识别方式枚举
enum AsrMode {
  online,    // 在线识别（speech_to_text）
  offline,   // 离线识别（sherpa_onnx）
  bytedance, // 豆包ASR
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SherpaAsrService _sherpaAsr = SherpaAsrService.instance;

  AsrMode _asrMode = AsrMode.online;
  String _selectedProvider = AiChatService.selectedProvider;
  List<AiProvider> _providers = AiChatService.providers;
  bool _loadingProviders = false;
  String _selectedModelId = 'sensevoice';

  // 模型状态和下载进度
  Map<String, Map<String, dynamic>> _modelStatuses = {};
  String? _downloadingModelId;
  String _downloadProgress = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _fetchProviders();
    _loadModelStatuses();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    // 读取语音识别方式
    final asrModeStr = prefs.getString('asr_mode') ?? 'online';
    AsrMode mode = AsrMode.online;
    switch (asrModeStr) {
      case 'offline':
        mode = AsrMode.offline;
        break;
      case 'bytedance':
        mode = AsrMode.bytedance;
        break;
      default:
        mode = AsrMode.online;
    }

    setState(() {
      _asrMode = mode;
      _selectedProvider = AiChatService.selectedProvider;
      _selectedModelId = prefs.getString('asr_model_id') ?? 'sensevoice';
    });
  }

  Future<void> _fetchProviders() async {
    setState(() => _loadingProviders = true);
    final providers = await AiChatService.fetchProviders();
    if (mounted) {
      setState(() {
        _providers = providers;
        _loadingProviders = false;
      });
    }
  }

  Future<void> _loadModelStatuses() async {
    final statuses = <String, Map<String, dynamic>>{};
    for (final model in SherpaAsrService.availableModels) {
      statuses[model.id] = await _sherpaAsr.getModelStatus(model.id);
    }
    if (mounted) {
      setState(() => _modelStatuses = statuses);
    }
  }

  Future<void> _selectAsrMode(AsrMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    String modeStr = 'online';
    switch (mode) {
      case AsrMode.offline:
        modeStr = 'offline';
        await _sherpaAsr.setForceOffline(true);
        break;
      case AsrMode.bytedance:
        modeStr = 'bytedance';
        await _sherpaAsr.setForceOffline(false);
        break;
      default:
        modeStr = 'online';
        await _sherpaAsr.setForceOffline(false);
    }
    await prefs.setString('asr_mode', modeStr);
    setState(() {
      _asrMode = mode;
    });
  }

  Future<void> _selectProvider(String providerId) async {
    await AiChatService.setProvider(providerId);
    setState(() {
      _selectedProvider = providerId;
    });
  }

  Future<void> _selectModel(String modelId) async {
    await _sherpaAsr.setModel(modelId);
    setState(() {
      _selectedModelId = modelId;
    });
  }

  Future<void> _redownloadModel(String modelId) async {
    setState(() {
      _downloadingModelId = modelId;
      _downloadProgress = '正在清理...';
    });

    final ok = await _sherpaAsr.cleanAndRedownload(
      modelId,
      onProgress: (status) {
        if (mounted) {
          setState(() => _downloadProgress = status);
        }
      },
    );

    // 刷新状态
    await _loadModelStatuses();

    if (mounted) {
      setState(() {
        _downloadingModelId = null;
        _downloadProgress = '';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok ? '模型下载完成' : '模型下载失败，请检查网络'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    CurrentPageState.instance.setFrameworkPage('settings');
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text('设置', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            _buildSectionTitle('AI 供应商', cs),
            const SizedBox(height: 8.0),
            _buildProviderSelector(cs),
            const SizedBox(height: 24.0),
            _buildSectionTitle('语音识别', cs),
            const SizedBox(height: 8.0),
            _buildAsrModeSelector(cs),
            const SizedBox(height: 16.0),
            if (_asrMode == AsrMode.offline) ...[
              _buildSectionTitle('语音模型', cs),
              const SizedBox(height: 8.0),
              _buildModelList(cs),
              const SizedBox(height: 16.0),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title, ColorScheme cs) {
    return Text(
      title,
      style: GoogleFonts.inter(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: cs.onSurface,
      ),
    );
  }

  Widget _buildAsrModeSelector(ColorScheme cs) {
    return Card(
      child: Column(
        children: [
          RadioListTile<AsrMode>(
            value: AsrMode.online,
            groupValue: _asrMode,
            onChanged: (value) {
              if (value != null) _selectAsrMode(value);
            },
            title: const Text('在线识别'),
            subtitle: const Text('使用 speech_to_text，需要网络连接'),
            secondary: Icon(
              Icons.cloud,
              color: _asrMode == AsrMode.online ? cs.primary : cs.outline,
            ),
          ),
          Divider(height: 1, indent: 16, endIndent: 16, color: cs.outline.withValues(alpha: 0.2)),
          RadioListTile<AsrMode>(
            value: AsrMode.offline,
            groupValue: _asrMode,
            onChanged: (value) {
              if (value != null) _selectAsrMode(value);
            },
            title: const Text('离线识别'),
            subtitle: const Text('使用 sherpa_onnx 本地模型，无需网络'),
            secondary: Icon(
              Icons.offline_bolt,
              color: _asrMode == AsrMode.offline ? cs.primary : cs.outline,
            ),
          ),
          Divider(height: 1, indent: 16, endIndent: 16, color: cs.outline.withValues(alpha: 0.2)),
          RadioListTile<AsrMode>(
            value: AsrMode.bytedance,
            groupValue: _asrMode,
            onChanged: (value) {
              if (value != null) _selectAsrMode(value);
            },
            title: const Text('豆包 ASR'),
            subtitle: const Text('字节跳动语音识别，需要网络和配额'),
            secondary: Icon(
              Icons.mic_external_on,
              color: _asrMode == AsrMode.bytedance ? cs.primary : cs.outline,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProviderSelector(ColorScheme cs) {
    if (_loadingProviders && _providers.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (_providers.isEmpty) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.cloud_off),
          title: const Text('无法获取供应商列表'),
          subtitle: const Text('使用默认供应商 DeepSeek'),
          trailing: IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchProviders,
          ),
        ),
      );
    }

    return Card(
      child: Column(
        children: _providers.map((provider) {
          final selected = provider.id == _selectedProvider;
          return RadioListTile<String>(
            value: provider.id,
            groupValue: _selectedProvider,
            onChanged: (value) {
              if (value != null) _selectProvider(value);
            },
            title: Text(
              provider.name,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            subtitle: Text(
              provider.description.isNotEmpty
                  ? '${provider.description} (${provider.defaultModel})'
                  : '模型: ${provider.defaultModel}',
              style: TextStyle(
                color: cs.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            secondary: Icon(
              Icons.smart_toy,
              color: selected ? cs.primary : cs.outline,
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildModelList(ColorScheme cs) {
    return Card(
      child: Column(
        children: SherpaAsrService.availableModels.map((model) {
          final selected = model.id == _selectedModelId;
          final status = _modelStatuses[model.id];
          final isDownloading = _downloadingModelId == model.id;
          final downloaded = status?['downloaded'] ?? 0;
          final total = status?['total'] ?? 0;
          final size = status?['size'] ?? 0;
          final isReady = status?['ready'] ?? false;

          return Column(
            children: [
              RadioListTile<String>(
                value: model.id,
                groupValue: _selectedModelId,
                onChanged: isDownloading ? null : (v) {
                  if (v != null) _selectModel(v);
                },
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        model.name,
                        style: TextStyle(
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                    if (isReady && !isDownloading)
                      Icon(Icons.check_circle, color: Colors.green, size: 18),
                  ],
                ),
                subtitle: isDownloading
                    ? Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _downloadProgress,
                              style: TextStyle(
                                color: cs.primary,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 4),
                            LinearProgressIndicator(
                              backgroundColor: cs.outline.withValues(alpha: 0.2),
                              color: cs.primary,
                            ),
                          ],
                        ),
                      )
                    : Text(
                        isReady
                            ? '已下载 · $downloaded/$total 文件 · ${_formatSize(size)}'
                            : downloaded > 0
                                ? '不完整 · $downloaded/$total 文件 · ${_formatSize(size)}'
                                : '未下载',
                        style: TextStyle(
                          color: isReady ? cs.onSurfaceVariant : cs.error,
                          fontSize: 12,
                        ),
                      ),
                secondary: isDownloading
                    ? SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.primary,
                        ),
                      )
                    : IconButton(
                        icon: Icon(
                          isReady ? Icons.refresh : Icons.download,
                          color: cs.onSurfaceVariant,
                          size: 22,
                        ),
                        tooltip: isReady ? '重新下载' : '下载',
                        onPressed: _downloadingModelId != null
                            ? null
                            : () => _redownloadModel(model.id),
                      ),
              ),
              if (model.id != SherpaAsrService.availableModels.last.id)
                Divider(height: 1, indent: 16, endIndent: 16, color: cs.outline.withValues(alpha: 0.2)),
            ],
          );
        }).toList(),
      ),
    );
  }
}
