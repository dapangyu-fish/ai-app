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
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Icon(Icons.model_training, color: cs.onSurface),
                    const SizedBox(width: 12.0),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'SenseVoice',
                            style: GoogleFonts.inter(
                              fontWeight: FontWeight.w600,
                              fontSize: 16.0,
                              color: cs.onSurface,
                            ),
                          ),
                          Text(
                            '支持：中文、英文、日文、韩文、粤语',
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
