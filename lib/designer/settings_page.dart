import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_storage.dart';
import 'ai_chat_service.dart';
// AsrMode + AsrModePrefs 共用 designer_ball 定义的，避免两份枚举漂移
import 'designer_ball.dart' show AsrMode, AsrModePrefs;
import 'default_startup_page.dart';
import 'default_startup_prefs.dart';
import '../i18n/framework_strings.dart';
import '../i18n/language_switcher.dart';
import '../im/im_cache_manage_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AsrMode _asrMode = AsrMode.online;
  String _selectedProvider = AiChatService.selectedProvider;
  List<AiProvider> _providers = AiChatService.providers;
  bool _loadingProviders = false;

  // 默认启动 App 当前选择（subtitle 展示用，进选择页改完再 reload）
  DefaultStartupConfig _defaultStartup = const DefaultStartupConfig.none();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _fetchProviders();
    _loadDefaultStartup();
  }

  Future<void> _loadDefaultStartup() async {
    final cfg = await DefaultStartupPrefs.read();
    if (mounted) setState(() => _defaultStartup = cfg);
  }

  Future<void> _loadSettings() async {
    // ASR 模式从 notifier 拿（DesignerBall 也用同一个），保证三处一致
    setState(() {
      _asrMode = AsrModePrefs.notifier.value;
      _selectedProvider = AiChatService.selectedProvider;
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

  Future<void> _selectAsrMode(AsrMode mode) async {
    // 写 prefs + 通知所有监听者（DesignerBall 在此重新挂载会立刻拿到新值）
    await AsrModePrefs.set(mode);
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

  @override
  Widget build(BuildContext context) {
    CurrentPageState.instance.setFrameworkPage('settings');
    final cs = Theme.of(context).colorScheme;
    final t = T.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.settingsTitle, style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            Card(
              child: LanguageSwitcher.tile(context),
            ),
            const SizedBox(height: 24.0),
            _buildSectionTitle(t.settingsAiProvider, cs),
            const SizedBox(height: 8.0),
            _buildProviderSelector(cs),
            const SizedBox(height: 24.0),
            _buildSectionTitle(t.settingsSectionAsr, cs),
            const SizedBox(height: 8.0),
            _buildAsrModeSelector(cs),
            const SizedBox(height: 24.0),
            Card(
              child: ListTile(
                leading: const Icon(Icons.rocket_launch_outlined),
                title: Text(t.defaultStartupEntry),
                subtitle: Text(
                  _defaultStartup.displaySummary(noneLabel: t.defaultStartupSubtitleNone),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DefaultStartupPage()),
                  );
                  await _loadDefaultStartup(); // 回来后刷新 subtitle
                },
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.storage_outlined),
                title: Text(t.imCacheEntry),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const IMCacheManagePage()),
                ),
              ),
            ),
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
    final t = T.of(context);
    return Card(
      child: Column(
        children: [
          RadioListTile<AsrMode>(
            value: AsrMode.online,
            groupValue: _asrMode,
            onChanged: (value) {
              if (value != null) _selectAsrMode(value);
            },
            title: Text(t.settingsAsrOnline),
            subtitle: Text(t.settingsAsrOnlineSubtitle),
            secondary: Icon(
              Icons.cloud,
              color: _asrMode == AsrMode.online ? cs.primary : cs.outline,
            ),
          ),
          Divider(height: 1, indent: 16, endIndent: 16, color: cs.outline.withValues(alpha: 0.2)),
          RadioListTile<AsrMode>(
            value: AsrMode.bytedance,
            groupValue: _asrMode,
            onChanged: (value) {
              if (value != null) _selectAsrMode(value);
            },
            title: Text(t.settingsAsrBytedance),
            subtitle: Text(t.settingsAsrBytedanceSubtitle),
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
      final t = T.of(context);
      return Card(
        child: ListTile(
          leading: const Icon(Icons.cloud_off),
          title: Text(t.settingsProvidersFailed),
          subtitle: Text(t.settingsProvidersFallback),
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
                  : T.fmt(T.of(context).settingsModelWith,
                      {'model': provider.defaultModel}),
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
}
