import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_storage.dart';
import 'ai_chat_service.dart';
// AsrMode + AsrModePrefs 共用 designer_ball 定义的，避免两份枚举漂移
import 'designer_ball.dart' show AsrMode, AsrModePrefs;
import 'default_startup_page.dart';
import 'default_startup_prefs.dart';
import 'hidden_env_entry.dart';
import 'private_agent_nodes_page.dart';
import '../i18n/framework_strings.dart';
import '../i18n/language_switcher.dart';
import '../im/im_cache_manage_entry.dart';
import '../theme/theme_controller.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AsrMode _asrMode = AsrMode.online;
  ThemeMode _themeMode = appThemeMode.value;
  String _selectedProvider = AiChatService.selectedProvider;
  String _agentScope = AiChatService.selectedAgentScope;
  List<AiProvider> _providers = AiChatService.providers;
  List<AiAgent> _agents = AiChatService.agents;
  bool _loadingProviders = false;

  // 默认启动 App 当前选择（subtitle 展示用，进选择页改完再 reload）
  DefaultStartupConfig _defaultStartup = const DefaultStartupConfig.none();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _fetchProviders();
    _fetchAgents();
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
      _themeMode = appThemeMode.value;
      _selectedProvider = AiChatService.selectedProvider;
      _agentScope = AiChatService.selectedAgentScope;
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

  Future<void> _fetchAgents() async {
    final agents = await AiChatService.fetchAgents();
    if (mounted) {
      setState(() {
        _agents = agents;
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

  Future<void> _selectThemeMode(ThemeMode mode) async {
    await ThemeController.setThemeMode(mode);
    if (mounted) {
      setState(() {
        _themeMode = mode;
      });
    }
  }

  Future<void> _selectProvider(String providerId) async {
    await AiChatService.setProvider(providerId);
    setState(() {
      _selectedProvider = providerId;
    });
  }

  Future<void> _selectProviderAgent(String providerId, String agentId) async {
    await AiChatService.setProvider(providerId);
    await AiChatService.setAgentForProvider(providerId, agentId);
    setState(() {
      _selectedProvider = providerId;
    });
  }

  Future<void> _selectAgentScope(String scope) async {
    await AiChatService.setAgentScope(scope);
    setState(() => _agentScope = AiChatService.selectedAgentScope);
  }

  String _privateAgentText({
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

  @override
  Widget build(BuildContext context) {
    CurrentPageState.instance.setFrameworkPage('settings');
    final cs = Theme.of(context).colorScheme;
    final t = T.of(context);

    return Scaffold(
      appBar: AppBar(
        title: HiddenEnvEntry(
          child: Text(
            t.settingsTitle,
            style: GoogleFonts.inter(fontWeight: FontWeight.w600),
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            Card(child: LanguageSwitcher.tile(context)),
            const SizedBox(height: 8.0),
            _buildThemeModeSelector(cs),
            const SizedBox(height: 24.0),
            _buildSectionTitle(t.settingsAiProvider, cs),
            const SizedBox(height: 8.0),
            _buildProviderSelector(cs),
            const SizedBox(height: 8.0),
            _buildAgentScopeSelector(cs),
            const SizedBox(height: 8.0),
            _buildPrivateAgentNodeTile(cs),
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
                  _defaultStartup.displaySummary(
                    noneLabel: t.defaultStartupSubtitleNone,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const DefaultStartupPage(),
                    ),
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

  Widget _buildThemeModeSelector(ColorScheme cs) {
    final t = T.of(context);
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: Text(t.settingsTheme),
          ),
          Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: cs.outline.withValues(alpha: 0.2),
          ),
          _buildThemeModeTile(
            mode: ThemeMode.system,
            label: t.settingsThemeSystem,
            icon: Icons.brightness_auto_outlined,
            cs: cs,
          ),
          Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: cs.outline.withValues(alpha: 0.2),
          ),
          _buildThemeModeTile(
            mode: ThemeMode.light,
            label: t.settingsThemeLight,
            icon: Icons.light_mode_outlined,
            cs: cs,
          ),
          Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: cs.outline.withValues(alpha: 0.2),
          ),
          _buildThemeModeTile(
            mode: ThemeMode.dark,
            label: t.settingsThemeDark,
            icon: Icons.dark_mode_outlined,
            cs: cs,
          ),
        ],
      ),
    );
  }

  Widget _buildThemeModeTile({
    required ThemeMode mode,
    required String label,
    required IconData icon,
    required ColorScheme cs,
  }) {
    final selected = _themeMode == mode;
    return ListTile(
      leading: Icon(icon, color: selected ? cs.primary : cs.outline),
      title: Text(label),
      trailing: selected ? Icon(Icons.check, color: cs.primary) : null,
      onTap: () => _selectThemeMode(mode),
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
          Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: cs.outline.withValues(alpha: 0.2),
          ),
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
          final agents = _agentsForProvider(provider);
          final selectedAgent =
              agents.any(
                (agent) =>
                    agent.id ==
                    AiChatService.selectedAgentForProvider(provider.id),
              )
              ? AiChatService.selectedAgentForProvider(provider.id)
              : agents.first.id;
          return InkWell(
            onTap: () => _selectProvider(provider.id),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: selected ? cs.primary : cs.outline,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          provider.name,
                          style: TextStyle(
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          provider.description.isNotEmpty
                              ? '${provider.description} (${provider.defaultModel})'
                              : T.fmt(T.of(context).settingsModelWith, {
                                  'model': provider.defaultModel,
                                }),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 128,
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedAgent,
                        isExpanded: true,
                        items: agents.map((agent) {
                          return DropdownMenuItem<String>(
                            value: agent.id,
                            child: Text(
                              agent.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            _selectProviderAgent(provider.id, value);
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildAgentScopeSelector(ColorScheme cs) {
    final labels = {
      'public': _privateAgentText(
        zh: '平台',
        en: 'Platform',
        de: 'Plattform',
        es: 'Plataforma',
      ),
      'private': _privateAgentText(
        zh: '私有',
        en: 'Private',
        de: 'Privat',
        es: 'Privado',
      ),
      'auto': _privateAgentText(zh: '自动', en: 'Auto', de: 'Auto', es: 'Auto'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.hub_outlined, color: cs.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _privateAgentText(
                      zh: 'Agent 调度',
                      en: 'Agent routing',
                      de: 'Agent-Routing',
                      es: 'Enrutamiento de agent',
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: labels.entries
                    .map(
                      (entry) => ButtonSegment<String>(
                        value: entry.key,
                        label: Text(
                          entry.value,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                selected: {_agentScope},
                onSelectionChanged: (selected) {
                  if (selected.isNotEmpty) {
                    _selectAgentScope(selected.first);
                  }
                },
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _privateAgentText(
                zh: '平台使用官方 Agent；私有仅使用你的私有节点；自动优先私有，无可用节点时回落平台。',
                en: 'Platform uses official agents. Private uses only your nodes. Auto prefers private and falls back to platform.',
                de: 'Plattform nutzt offizielle Agents. Privat nutzt nur deine Nodes. Auto bevorzugt privat und faellt auf Plattform zurueck.',
                es: 'Plataforma usa agents oficiales. Privado usa solo tus nodos. Auto prefiere privado y vuelve a plataforma.',
              ),
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrivateAgentNodeTile(ColorScheme cs) {
    return Card(
      child: ListTile(
        leading: Icon(Icons.private_connectivity_outlined, color: cs.primary),
        title: Text(
          _privateAgentText(
            zh: '私有 Agent Node',
            en: 'Private Agent Node',
            de: 'Private Agent Node',
            es: 'Agent Node privado',
          ),
        ),
        subtitle: Text(
          _privateAgentText(
            zh: '查看你的私有节点，生成加入命令，暂停调度或调整容量',
            en: 'View your private nodes, create join commands, pause routing, or adjust limits',
            de: 'Private Nodes anzeigen, Join-Befehle erstellen, Routing pausieren oder Limits anpassen',
            es: 'Ver tus nodos privados, crear comandos de union, pausar o ajustar limites',
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const PrivateAgentNodesPage()),
        ),
      ),
    );
  }

  List<AiAgent> _agentsForProvider(AiProvider provider) {
    final ids = provider.supportedAgentIds.isEmpty
        ? const ['claude']
        : provider.supportedAgentIds;
    final result = <AiAgent>[];
    for (final id in ids) {
      AiAgent? agent;
      for (final candidate in _agents) {
        if (candidate.id == id) {
          agent = candidate;
          break;
        }
      }
      result.add(
        agent ?? AiAgent(id: id, name: id, description: '', configured: true),
      );
    }
    return result;
  }
}
