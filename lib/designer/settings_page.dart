import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sherpa_asr_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final SherpaAsrService _sherpaAsr = SherpaAsrService.instance;

  bool _forceOffline = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _forceOffline = prefs.getBool('force_offline_asr') ?? false;
    });
  }

  Future<void> _toggleOffline(bool value) async {
    await _sherpaAsr.setForceOffline(value);
    setState(() {
      _forceOffline = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            _buildSectionTitle('语音识别'),
            const SizedBox(height: 8.0),
            _buildOfflineSwitch(),
            const SizedBox(height: 16.0),
            _buildModelInfo(colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
    );
  }

  Widget _buildOfflineSwitch() {
    return Card(
      child: SwitchListTile(
        secondary: const Icon(Icons.mic_off),
        title: const Text('强制使用离线语音'),
        subtitle: const Text(
          '开启后，语音识别会优先使用本地模型，不依赖网络',
        ),
        value: _forceOffline,
        onChanged: _toggleOffline,
      ),
    );
  }

  Widget _buildModelInfo(ColorScheme colorScheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            const Icon(Icons.model_training),
            const SizedBox(width: 12.0),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'SenseVoice',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16.0,
                    ),
                  ),
                  Text(
                    '支持：中文、英文、日文、韩文、粤语',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
