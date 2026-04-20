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

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _forceOffline = prefs.getBool('force_offline_asr') ?? false;
      _selectedModelId = prefs.getString('asr_model_id') ?? 'sensevoice';
    });
  }

  Future<void> _toggleOffline(bool value) async {
    await _sherpaAsr.setForceOffline(value);
    setState(() {
      _forceOffline = value;
    });
  }

  Future<void> _selectModel(String modelId) async {
    await _sherpaAsr.setModel(modelId);
    setState(() {
      _selectedModelId = modelId;
    });
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
                subtitle: const Text(
                  '开启后，语音识别会优先使用本地模型，不依赖网络',
                ),
                value: _forceOffline,
                onChanged: _toggleOffline,
              ),
            ),
            const SizedBox(height: 16.0),
            Text(
              '语音模型',
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8.0),
            Card(
              child: Column(
                children: SherpaAsrService.availableModels.map((model) {
                  final selected = model.id == _selectedModelId;
                  return RadioListTile<String>(
                    value: model.id,
                    groupValue: _selectedModelId,
                    onChanged: (v) {
                      if (v != null) _selectModel(v);
                    },
                    title: Text(
                      model.name,
                      style: TextStyle(
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                    secondary: Icon(
                      Icons.model_training,
                      color: selected ? cs.primary : cs.outline,
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
