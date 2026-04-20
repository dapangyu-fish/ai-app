import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'sherpa_asr_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SherpaAsrService _sherpaAsr = SherpaAsrService.instance;

  bool _forceOffline = false;
  String _selectedModelId = 'sensevoice';
  final Map<String, bool> _modelReady = {};
  bool _loadingReady = true;
  String? _downloadingModelId;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final modelId = prefs.getString('asr_model_id') ?? 'sensevoice';
    setState(() {
      _forceOffline = prefs.getBool('force_offline_asr') ?? false;
      _selectedModelId = modelId;
    });
    await _checkAllModels();
  }

  Future<void> _checkAllModels() async {
    setState(() => _loadingReady = true);
    for (final model in kAsrModels) {
      final ready = await _sherpaAsr.isModelReady(model.id);
      _modelReady[model.id] = ready;
    }
    if (mounted) setState(() => _loadingReady = false);
  }

  Future<void> _toggleOffline(bool value) async {
    await _sherpaAsr.setForceOffline(value);
    setState(() => _forceOffline = value);
  }

  Future<void> _selectModel(String modelId) async {
    await _sherpaAsr.setModel(modelId);
    setState(() => _selectedModelId = modelId);

    if (_modelReady[modelId] != true) {
      if (!mounted) return;
      final shouldDownload = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('模型未下载'),
          content: Text('${getAsrModelById(modelId).name} 尚未下载，是否现在下载？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('下载'),
            ),
          ],
        ),
      );
      if (shouldDownload == true) {
        await _downloadModel(modelId);
      }
    }
  }

  Future<void> _downloadModel(String modelId) async {
    setState(() => _downloadingModelId = modelId);
    final ok = await _sherpaAsr.downloadModels(modelId);
    if (ok) {
      _modelReady[modelId] = true;
    }
    if (mounted) {
      setState(() => _downloadingModelId = null);
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${getAsrModelById(modelId).name} 下载完成')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${getAsrModelById(modelId).name} 下载失败')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
            Text(
              '语音识别',
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8.0),
            Card(
              child: SwitchListTile(
                secondary: Icon(Icons.mic_off, color: cs.onSurface),
                title: const Text('强制使用离线语音'),
                subtitle: const Text('开启后，语音识别会优先使用本地模型，不依赖网络'),
                value: _forceOffline,
                onChanged: _toggleOffline,
              ),
            ),
            const SizedBox(height: 16.0),
            Text(
              '识别模型',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8.0),
            RadioGroup<String>(
              groupValue: _selectedModelId,
              onChanged: (v) {
                if (v != null && _downloadingModelId == null) _selectModel(v);
              },
              child: Column(
                children: kAsrModels.map((model) => _buildModelTile(model, cs)).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelTile(AsrModel model, ColorScheme cs) {
    final isSelected = _selectedModelId == model.id;
    final isReady = _modelReady[model.id] ?? false;
    final isDownloading = _downloadingModelId == model.id;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected
            ? BorderSide(color: cs.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isDownloading ? null : () => _selectModel(model.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Radio<String>(
                value: model.id,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.name,
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      model.description,
                      style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (_loadingReady)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (isDownloading)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (isReady)
                Icon(Icons.check_circle, color: cs.primary, size: 20)
              else
                TextButton(
                  onPressed: () => _downloadModel(model.id),
                  child: const Text('下载'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
