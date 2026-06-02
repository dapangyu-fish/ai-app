import {
  Bot,
  Boxes,
  ChevronRight,
  CheckCircle2,
  Cloud,
  Code2,
  Database,
  Download,
  Film,
  GitBranch,
  Globe2,
  Layers3,
  LockKeyhole,
  MessageCircle,
  PackageSearch,
  Play,
  Rocket,
  Server,
  ShieldCheck,
  Smartphone,
  Sparkles,
  Workflow,
  Zap,
} from 'lucide-react';
import { type CSSProperties, type PointerEvent as ReactPointerEvent, useMemo, useState } from 'react';

type Lang = 'zh' | 'en' | 'de' | 'es';
type ThemeKey = 'orbit' | 'matrix' | 'prism' | 'slate';

const WEB_APP_URL = 'https://myapp-web.dapangyu.work/';
const TESTFLIGHT_URL = 'https://testflight.apple.com/join/3Fk5Exnn';

const languageOptions: Array<{ key: Lang; label: string; flag: string }> = [
  { key: 'zh', label: '中文', flag: '🇨🇳' },
  { key: 'en', label: 'English', flag: '🇺🇸' },
  { key: 'de', label: 'Deutsch', flag: '🇩🇪' },
  { key: 'es', label: 'Español', flag: '🇪🇸' },
];

const themes: Array<{
  key: ThemeKey;
  label: string;
  tone: string;
  description: string;
}> = [
  {
    key: 'orbit',
    label: 'Orbit Lab',
    tone: 'Blue / Cyan',
    description: '深色实验室风格，适合默认官网和技术产品主页。',
  },
  {
    key: 'matrix',
    label: 'Command Deck',
    tone: 'Green / Graphite',
    description: '偏 CLI 和部署文档风格，开局强调自部署能力。',
  },
  {
    key: 'prism',
    label: 'Neon Studio',
    tone: 'Violet / Amber',
    description: '更强的展示感，适合发布会、演示和社交传播。',
  },
  {
    key: 'slate',
    label: 'Systems UI',
    tone: 'Slate / White',
    description: '克制、产品化，更像成熟开发者工具。',
  },
];

const copy = {
  zh: {
    navHow: '部署',
    navStack: '架构',
    navTry: '视频',
    navFeatures: '能力',
    navDownload: '下载',
    badge: 'UGC 应用构建工具 · AI 生成 · Web / iOS / Android',
    titleA: '把想法变成',
    titleB: '每个人都能发布的小应用',
    subtitle:
      'MyApp 是一个用户生成内容（UGC）式的应用构建工具。描述你想要的工具、游戏、社区页面或业务面板，AI 生成可运行应用，用户可以安装、分享并继续迭代。',
    primaryCta: '打开 Web 版',
    secondaryCta: '加入 TestFlight',
    phoneCaption: '线上 Web 客户端，嵌在手机外框里做快速演示。',
    heroConsoleTitle: '从提示词到可运行应用',
    heroConsoleLines: [
      '$ tell ai "生成一个露营装备打包 App"',
      '→ AI builds a JSON App',
      '→ publish to the app marketplace',
      '→ users run it on Web / iOS / Android',
    ],
    proofPoints: ['用户生成应用内容', 'AI 辅助构建和迭代', 'Web 与移动端同一生态'],
    playgroundTitle: '选择官网科技风格',
    playgroundSubtitle: '同一套内容，切换不同视觉方向，后续可以按你选中的风格继续打磨。',
    videosTitle: '演示视频',
    videosSubtitle: '这里先放占位卡片，后续把视频链接补进去即可。',
    videoCards: [
      ['AI 生成 App', '从一句话开始生成可运行 JSON App。'],
      ['应用市场', '安装、搜索、运行 JSON App 和组件。'],
      ['切换环境', '扫码或粘贴 bootstrap JSON，连接你的后端。'],
    ],
    deployTitle: '私有部署与客户端接入',
    deployHint: '私有部署主要是后端；客户端可以使用线上 Web，也可以自己 build iOS / Android / Web，然后在客户端切换环境。',
    backendDeployTitle: '1. 部署后端测试环境',
    clientBuildTitle: '2. 构建客户端',
    switchEnvTitle: '3. 客户端切换环境',
    switchEnvBody: '打开客户端的 Service Environment 页面，扫码 bootstrap 输出的二维码，或粘贴整段 JSON。保存后重新登录，客户端就会连接到你的后端。',
    usageTitle: '4. 怎么使用',
    usageBody: '登录测试账号后，可以打开应用市场安装 JSON App，也可以用悬浮 AI 入口描述需求，让 AI 生成应用，再继续通过对话迭代。',
    howTitle: '从想法到应用',
    howSubtitle: '完整流程是部署后端、构建或打开客户端、切换环境、安装或生成应用。',
    steps: [
      ['准备环境', '先运行 bootstrap，拿到服务地址、测试账号和环境 JSON。'],
      ['连接客户端', 'Web / iOS / Android 都通过环境切换页连接到你的后端。'],
      ['生成或安装 App', '在应用市场安装 JSON App，或让 AI 生成新的应用。'],
    ],
    featuresTitle: '平台能力',
    featuresSubtitle: '围绕 AI 生成、运行时渲染、应用市场和自部署构建。',
    stackTitle: '一套运行时，三条关键链路',
    stackSubtitle: '客户端只负责解释已允许的 JSON 能力；后端负责 AI 生成、包分发、IM、配置和可恢复任务。',
    stackItems: [
      ['Flutter Runtime', '预编译控件、JsonLogic、游戏 atoms、IM 兼容层和媒体能力。'],
      ['AI Worker Queue', 'Redis 队列、SSE 恢复、并发控制和生成结果持久化。'],
      ['Registry + Assets', '分页搜索、版本约束、组件依赖、OSS/MinIO 资源分发。'],
    ],
    complianceTitle: '审核友好的边界',
    complianceBody: 'AI 生成的是声明式 JSON 配置。它只能组合客户端已经编译好的控件和动作，不能下发 Dart、Swift、Kotlin、插件或二进制。',
    features: [
      ['AI 原生 DSL', '结构适合大模型生成，不是只给人手写的配置格式。'],
      ['Web 兼容', '同一套 JSON App 能在 Web 版快速验证和展示。'],
      ['内置 IM', '好友、群聊、消息同步和 Web OpenIM 兼容层。'],
      ['应用市场', '包索引、版本、搜索、分页和组件复用。'],
      ['服务端驱动', 'UI 和业务配置可作为数据更新，但不能扩展客户端原生能力。'],
      ['可自部署', '测试环境 bootstrap 一条链路拉起核心服务。'],
    ],
    downloadTitle: '开始体验 MyApp',
    downloadBody: 'Web 版可直接打开；iOS 已开放 TestFlight Public Group 1（2500 人）；Google Play 和 APK 包正在准备中。',
    openWeb: '打开 Web 版',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: '可用',
    soon: '即将上线',
  },
  en: {
    navHow: 'Deploy',
    navStack: 'Stack',
    navTry: 'Videos',
    navFeatures: 'Capabilities',
    navDownload: 'Download',
    badge: 'UGC app builder · AI-generated · Web / iOS / Android',
    titleA: 'Turn ideas into',
    titleB: 'apps anyone can publish',
    subtitle:
      'MyApp is a user-generated app builder. Describe a tool, game, community screen or dashboard; AI builds a runnable app that users can install, share and keep improving.',
    primaryCta: 'Open Web app',
    secondaryCta: 'Join TestFlight',
    phoneCaption: 'Live Web client embedded in a phone frame for quick demos.',
    heroConsoleTitle: 'Prompt to runnable app',
    heroConsoleLines: [
      '$ tell ai "build a camping packing app"',
      '→ AI builds a JSON App',
      '→ publish to the app marketplace',
      '→ users run it on Web / iOS / Android',
    ],
    proofPoints: ['User-generated app content', 'AI-assisted building and iteration', 'One ecosystem across Web and mobile'],
    playgroundTitle: 'Choose a tech visual direction',
    playgroundSubtitle: 'Same product content, multiple visual directions. Pick one and we can refine from there.',
    videosTitle: 'Demo videos',
    videosSubtitle: 'Placeholder cards for now. Drop in real video links later.',
    videoCards: [
      ['AI app generation', 'Generate a runnable JSON App from one prompt.'],
      ['Marketplace', 'Search, install and run JSON Apps and components.'],
      ['Environment switch', 'Scan or paste bootstrap JSON to connect your backend.'],
    ],
    deployTitle: 'Private backend and client setup',
    deployHint: 'Private deployment mainly means the backend. The client can use the hosted Web app, or you can build iOS / Android / Web yourself and switch environments in the client.',
    backendDeployTitle: '1. Deploy backend test environment',
    clientBuildTitle: '2. Build clients',
    switchEnvTitle: '3. Switch client environment',
    switchEnvBody: 'Open Service Environment in the client, scan the QR code from bootstrap, or paste the full JSON. Save and sign in again to connect to your backend.',
    usageTitle: '4. How to use it',
    usageBody: 'After signing in with the test account, install JSON Apps from the marketplace or use the floating AI entry to describe an app and iterate through chat.',
    howTitle: 'Idea to app',
    howSubtitle: 'The full flow is backend bootstrap, client build/open, environment switch, then install or generate apps.',
    steps: [
      ['Prepare environment', 'Run bootstrap to get service URLs, test account and environment JSON.'],
      ['Connect client', 'Web / iOS / Android all connect through the environment switch page.'],
      ['Generate or install apps', 'Install JSON Apps from the marketplace or ask AI to generate new ones.'],
    ],
    featuresTitle: 'Platform capabilities',
    featuresSubtitle: 'Built around AI generation, runtime rendering, marketplace distribution and self-hosting.',
    stackTitle: 'One runtime, three critical paths',
    stackSubtitle: 'The client interprets only approved JSON capabilities. The backend handles AI generation, package distribution, IM, config and resumable tasks.',
    stackItems: [
      ['Flutter Runtime', 'Precompiled widgets, JsonLogic, game atoms, IM compatibility and media capabilities.'],
      ['AI Worker Queue', 'Redis queue, resumable SSE, concurrency limits and durable generation results.'],
      ['Registry + Assets', 'Paginated search, semver, component dependencies and OSS/MinIO asset delivery.'],
    ],
    complianceTitle: 'Review-friendly boundary',
    complianceBody: 'AI produces declarative JSON configuration. It can only compose compiled client widgets and actions, not Dart, Swift, Kotlin, plugins or binaries.',
    features: [
      ['AI-native DSL', 'Structured for LLM generation, not only hand-written config.'],
      ['Web compatible', 'Validate and demo the same JSON App on the Web client.'],
      ['Built-in IM', 'Friends, groups, sync and the OpenIM compatibility layer for Web.'],
      ['Marketplace', 'Package index, versions, search, pagination and component reuse.'],
      ['Server-driven', 'Ship UI and behavior data without extending native client capabilities.'],
      ['Self-hostable', 'The test-env bootstrap brings up the core services end to end.'],
    ],
    downloadTitle: 'Start using MyApp',
    downloadBody: 'Open the Web app now. iOS is available through TestFlight Public Group 1 with 2,500 seats. Google Play and APK builds are coming soon.',
    openWeb: 'Open Web app',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: 'Available',
    soon: 'Coming soon',
  },
  de: {
    navHow: 'Deployment',
    navStack: 'Stack',
    navTry: 'Videos',
    navFeatures: 'Funktionen',
    navDownload: 'Download',
    badge: 'AI-App-Erstellung · Server-driven · Web / iOS / Android',
    titleA: 'Sag der KI, was du brauchst',
    titleB: 'und erhalte eine lauffähige App',
    subtitle:
      'Beschreibe deine App. Die KI erzeugt eine JSON App, die sofort in der Web-Vorschau und auf mobilen Clients innerhalb der vorkompilierten Runtime laeuft.',
    primaryCta: 'Live-Demo öffnen',
    secondaryCta: 'Deployment ansehen',
    phoneCaption: 'Live-Web-Client im Smartphone-Rahmen für schnelle Demos.',
    heroConsoleTitle: 'Vom Prompt zur laufenden App',
    heroConsoleLines: [
      '$ tell ai "build an inventory app"',
      '→ validate JSON DSL',
      '→ publish package + assets',
      '→ run on Web / iOS / Android',
    ],
    proofPoints: ['Apache-2.0 Open Source', 'JSON ist kein dynamischer Code', 'Backend voll selbst hosten'],
    playgroundTitle: 'Technischen Look wählen',
    playgroundSubtitle: 'Gleicher Inhalt, mehrere visuelle Richtungen. Wähle eine aus und wir feilen daran weiter.',
    videosTitle: 'Demo-Videos',
    videosSubtitle: 'Noch Platzhalter. Später können hier echte Videolinks ergänzt werden.',
    videoCards: [
      ['KI generiert Apps', 'Aus einem Prompt entsteht eine lauffähige JSON App.'],
      ['App-Marktplatz', 'JSON Apps und Komponenten suchen, installieren und starten.'],
      ['Umgebung wechseln', 'QR-Code scannen oder bootstrap JSON einfügen.'],
    ],
    deployTitle: 'Private Backend-Bereitstellung und Client-Setup',
    deployHint: 'Privates Deployment betrifft vor allem das Backend. Den Client kannst du als gehostete Web-App nutzen oder iOS / Android / Web selbst bauen.',
    backendDeployTitle: '1. Backend-Testumgebung starten',
    clientBuildTitle: '2. Clients bauen',
    switchEnvTitle: '3. Client-Umgebung wechseln',
    switchEnvBody: 'Öffne im Client Service Environment, scanne den QR-Code aus bootstrap oder füge das vollständige JSON ein. Danach speichern und neu anmelden.',
    usageTitle: '4. Nutzung',
    usageBody: 'Nach dem Login mit dem Testkonto kannst du Apps aus dem Marktplatz installieren oder über den schwebenden KI-Einstieg neue Apps beschreiben und iterieren.',
    howTitle: 'Von der Idee zur App',
    howSubtitle: 'Der Ablauf: Backend starten, Client bauen oder öffnen, Umgebung wechseln, App installieren oder generieren.',
    steps: [
      ['Umgebung vorbereiten', 'bootstrap liefert Service-URLs, Testkonto und Umgebungs-JSON.'],
      ['Client verbinden', 'Web / iOS / Android verbinden sich über die Environment-Seite.'],
      ['Apps nutzen', 'Apps aus dem Marktplatz installieren oder per KI generieren.'],
    ],
    featuresTitle: 'Plattformfunktionen',
    featuresSubtitle: 'Gebaut für KI-Generierung, Runtime-Rendering, Marktplatz und Self-Hosting.',
    stackTitle: 'Eine Runtime, drei Kernpfade',
    stackSubtitle: 'Der Client interpretiert nur erlaubte JSON-Fähigkeiten. Das Backend steuert KI-Generierung, Pakete, IM, Config und wiederaufnehmbare Tasks.',
    stackItems: [
      ['Flutter Runtime', 'Vorkompilierte Widgets, JsonLogic, Game Atoms, IM-Kompatibilität und Medienfunktionen.'],
      ['AI Worker Queue', 'Redis-Queue, wiederaufnehmbare SSE, Limits und persistente Ergebnisse.'],
      ['Registry + Assets', 'Suche mit Pagination, Semver, Komponentenabhängigkeiten und OSS/MinIO Assets.'],
    ],
    complianceTitle: 'Review-freundliche Grenze',
    complianceBody: 'KI erzeugt deklarative JSON-Konfiguration. Sie kombiniert nur kompilierte Client-Widgets und Actions, aber keinen Dart-, Swift-, Kotlin-, Plugin- oder Binärcode.',
    features: [
      ['AI-native DSL', 'Struktur für LLM-Generierung statt nur manuelle Konfiguration.'],
      ['Web-kompatibel', 'Dieselbe JSON App im Web-Client validieren und demonstrieren.'],
      ['Integriertes IM', 'Freunde, Gruppen, Sync und OpenIM-Kompatibilität für Web.'],
      ['Marktplatz', 'Paketindex, Versionen, Suche, Pagination und Komponenten-Wiederverwendung.'],
      ['Server-driven', 'UI- und Verhaltensdaten ausliefern, ohne native Client-Faehigkeiten zu erweitern.'],
      ['Self-hostable', 'test-env bootstrap startet die Kernservices Ende zu Ende.'],
    ],
    downloadTitle: 'MyApp jetzt starten',
    downloadBody: 'Die Web-App ist direkt verfügbar. iOS läuft über TestFlight Public Group 1 mit 2.500 Plätzen. Google Play und APK folgen.',
    openWeb: 'Web-App öffnen',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: 'Verfügbar',
    soon: 'Demnächst',
  },
  es: {
    navHow: 'Despliegue',
    navStack: 'Stack',
    navTry: 'Videos',
    navFeatures: 'Capacidades',
    navDownload: 'Descargar',
    badge: 'Apps con IA · Server-driven · Web / iOS / Android',
    titleA: 'Dile a la IA lo que quieres',
    titleB: 'y obtén una app funcional',
    subtitle:
      'Describe la app que necesitas. La IA genera una JSON App que corre al instante en la vista Web y en clientes móviles, dentro del runtime precompilado.',
    primaryCta: 'Abrir demo',
    secondaryCta: 'Ver despliegue',
    phoneCaption: 'Cliente Web en vivo dentro de un marco de teléfono para demos rápidas.',
    heroConsoleTitle: 'De prompt a app ejecutable',
    heroConsoleLines: [
      '$ tell ai "build an inventory app"',
      '→ validate JSON DSL',
      '→ publish package + assets',
      '→ run on Web / iOS / Android',
    ],
    proofPoints: ['Apache-2.0 open source', 'JSON no es código dinámico', 'Backend completo autoalojable'],
    playgroundTitle: 'Elige un estilo tecnológico',
    playgroundSubtitle: 'Mismo contenido, varias direcciones visuales. Elige una y seguimos puliéndola.',
    videosTitle: 'Videos demo',
    videosSubtitle: 'Tarjetas de marcador por ahora. Luego puedes agregar enlaces reales.',
    videoCards: [
      ['Generación con IA', 'Crea una JSON App ejecutable desde un prompt.'],
      ['Marketplace', 'Busca, instala y ejecuta JSON Apps y componentes.'],
      ['Cambio de entorno', 'Escanea o pega el JSON de bootstrap para conectar tu backend.'],
    ],
    deployTitle: 'Backend privado y configuración del cliente',
    deployHint: 'El despliegue privado es principalmente el backend. Puedes usar la Web hospedada o compilar iOS / Android / Web por tu cuenta.',
    backendDeployTitle: '1. Desplegar backend de prueba',
    clientBuildTitle: '2. Compilar clientes',
    switchEnvTitle: '3. Cambiar entorno del cliente',
    switchEnvBody: 'Abre Service Environment en el cliente, escanea el QR de bootstrap o pega el JSON completo. Guarda e inicia sesión de nuevo.',
    usageTitle: '4. Cómo usarlo',
    usageBody: 'Después de iniciar sesión con la cuenta de prueba, instala JSON Apps desde el marketplace o usa la entrada flotante de IA para describir una app e iterar por chat.',
    howTitle: 'De idea a app',
    howSubtitle: 'El flujo completo: bootstrap del backend, abrir o compilar cliente, cambiar entorno y luego instalar o generar apps.',
    steps: [
      ['Preparar entorno', 'bootstrap entrega URLs, cuenta de prueba y JSON de entorno.'],
      ['Conectar cliente', 'Web / iOS / Android se conectan desde la página de entorno.'],
      ['Crear o instalar apps', 'Instala desde el marketplace o pide a la IA que genere una nueva app.'],
    ],
    featuresTitle: 'Capacidades de la plataforma',
    featuresSubtitle: 'Diseñada para generación con IA, runtime, marketplace y self-hosting.',
    stackTitle: 'Un runtime, tres rutas críticas',
    stackSubtitle: 'El cliente interpreta solo capacidades JSON aprobadas. El backend maneja IA, paquetes, IM, configuración y tareas recuperables.',
    stackItems: [
      ['Flutter Runtime', 'Widgets precompilados, JsonLogic, game atoms, compatibilidad IM y capacidades multimedia.'],
      ['AI Worker Queue', 'Cola Redis, SSE recuperable, límites de concurrencia y resultados persistentes.'],
      ['Registry + Assets', 'Búsqueda paginada, semver, dependencias de componentes y assets OSS/MinIO.'],
    ],
    complianceTitle: 'Límite claro para revisión',
    complianceBody: 'La IA produce configuración JSON declarativa. Solo compone widgets y acciones ya compilados, no Dart, Swift, Kotlin, plugins ni binarios.',
    features: [
      ['DSL nativa para IA', 'Estructura pensada para LLMs, no solo configuración manual.'],
      ['Compatible con Web', 'Valida y muestra la misma JSON App en el cliente Web.'],
      ['IM integrado', 'Amigos, grupos, sincronización y compatibilidad OpenIM para Web.'],
      ['Marketplace', 'Índice, versiones, búsqueda, paginación y reutilización de componentes.'],
      ['Server-driven', 'Envía datos de UI y comportamiento sin ampliar las capacidades nativas del cliente.'],
      ['Autoalojable', 'test-env bootstrap levanta los servicios centrales de punta a punta.'],
    ],
    downloadTitle: 'Empieza con MyApp',
    downloadBody: 'La Web app está disponible ahora. iOS está en TestFlight Public Group 1 con 2.500 plazas. Google Play y APK llegarán pronto.',
    openWeb: 'Abrir Web app',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: 'Disponible',
    soon: 'Próximamente',
  },
};

type PhoneSize = {
  width: number;
  height: number;
};

const PHONE_ASPECT_RATIO = 390 / 844;
const PHONE_MIN_WIDTH = 320;
const PHONE_MAX_WIDTH = 430;

function phoneSizeFromWidth(width: number): PhoneSize {
  const clampedWidth = Math.max(PHONE_MIN_WIDTH, Math.min(PHONE_MAX_WIDTH, Math.round(width)));
  return { width: clampedWidth, height: Math.round(clampedWidth / PHONE_ASPECT_RATIO) };
}

function initialPhoneSize(compact: boolean): PhoneSize {
  if (compact) {
    return phoneSizeFromWidth(320);
  }
  return phoneSizeFromWidth(390);
}

type ResizeHandle = 'n' | 'e' | 's' | 'w' | 'nw' | 'ne' | 'sw' | 'se';

function PhonePreview({ compact = false }: { compact?: boolean }) {
  const [size, setSize] = useState<PhoneSize>(() => initialPhoneSize(compact));
  const stageStyle = {
    '--phone-width': `${size.width}px`,
    '--phone-height': `${size.height}px`,
    '--phone-ratio': `${size.width} / ${size.height}`,
  } as CSSProperties;

  function startResize(handle: ResizeHandle, event: ReactPointerEvent<HTMLButtonElement>) {
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);

    const startX = event.clientX;
    const startY = event.clientY;
    const start = size;

    const onMove = (moveEvent: PointerEvent) => {
      const dx = moveEvent.clientX - startX;
      const dy = moveEvent.clientY - startY;
      const candidates: number[] = [];
      if (handle.includes('e')) {
        candidates.push(start.width + dx);
      } else if (handle.includes('w')) {
        candidates.push(start.width - dx);
      }
      if (handle.includes('s')) {
        candidates.push(start.width + dy * PHONE_ASPECT_RATIO);
      } else if (handle.includes('n')) {
        candidates.push(start.width - dy * PHONE_ASPECT_RATIO);
      }
      const nextWidth = candidates.reduce((current, candidate) => {
        return Math.abs(candidate - start.width) > Math.abs(current - start.width) ? candidate : current;
      }, start.width);
      setSize(phoneSizeFromWidth(nextWidth));
    };
    const onUp = () => {
      window.removeEventListener('pointermove', onMove);
      window.removeEventListener('pointerup', onUp);
    };

    window.addEventListener('pointermove', onMove);
    window.addEventListener('pointerup', onUp);
  }

  return (
    <div
      className={`phoneStage ${compact ? 'compact' : ''}`}
      style={stageStyle}
      aria-label="MyApp Web live preview"
    >
      <div className="phoneGlow" />
      <div className="phoneShell">
        <div className="sideButton sideButtonPower" />
        <div className="sideButton sideButtonVolumeUp" />
        <div className="sideButton sideButtonVolumeDown" />
        <div className="phoneSpeaker" />
        <div className="phoneScreen">
          <iframe
            src={WEB_APP_URL}
            title="MyApp Web demo"
            loading={compact ? 'lazy' : 'eager'}
            allow="clipboard-read; clipboard-write; microphone; camera"
            scrolling="no"
          />
        </div>
        {(['n', 'e', 's', 'w', 'nw', 'ne', 'sw', 'se'] as const).map((handle) => (
          <button
            aria-label={`Resize phone ${handle}`}
            className={`resizeHandle resizeHandle-${handle}`}
            key={handle}
            type="button"
            onPointerDown={(event) => startResize(handle, event)}
          />
        ))}
      </div>
    </div>
  );
}

function TerminalBox({ lines }: { lines: string[] }) {
  return (
    <div className="terminalBox">
      <div className="terminalTop">
        <span />
        <span />
        <span />
      </div>
      <pre>{lines.join('\n')}</pre>
    </div>
  );
}

function App() {
  const [lang, setLang] = useState<Lang>(() =>
    navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en',
  );
  const [theme, setTheme] = useState<ThemeKey>('orbit');
  const t = copy[lang];
  const activeTheme = useMemo(() => themes.find((item) => item.key === theme)!, [theme]);
  const activeLanguage = languageOptions.find((item) => item.key === lang) ?? languageOptions[1];

  return (
    <main className={`site theme-${theme}`}>
      <nav className="nav">
        <div className="shell navInner">
          <a className="brand" href="#top" aria-label="MyApp">
            My<span>App</span>
          </a>
          <div className="navLinks">
            <a href="#deploy">{t.navHow}</a>
            <a href="#stack">{t.navStack}</a>
            <a href="#videos">{t.navTry}</a>
            <a href="#features">{t.navFeatures}</a>
            <a href="#download">{t.navDownload}</a>
          </div>
          <label className="languageSelect" aria-label="Language">
            <Globe2 size={16} />
            <span>{activeLanguage.flag}</span>
            <select value={lang} onChange={(event) => setLang(event.target.value as Lang)}>
              {languageOptions.map((item) => (
                <option key={item.key} value={item.key}>
                  {item.label}
                </option>
              ))}
            </select>
          </label>
        </div>
      </nav>

      <section className="hero" id="top">
        <div className="gridFx" />
        <div className="shell heroGrid">
          <div className="heroCopy">
            <div className="badge">
              <Sparkles size={15} />
              <span>{t.badge}</span>
            </div>
            <h1>
              {t.titleA}
              <span>{t.titleB}</span>
            </h1>
            <p className="lead">{t.subtitle}</p>
            <div className="actions">
              <a className="button primary" href={WEB_APP_URL} target="_blank" rel="noreferrer">
                <Play size={17} />
                {t.primaryCta}
              </a>
              <a className="button secondary" href={TESTFLIGHT_URL} target="_blank" rel="noreferrer">
                <Smartphone size={17} />
                {t.secondaryCta}
              </a>
            </div>
            <div className="heroConsole">
              <div className="heroConsoleHeader">
                <span>{t.heroConsoleTitle}</span>
                <small>live path</small>
              </div>
              <TerminalBox lines={t.heroConsoleLines} />
            </div>
            <div className="proofRow">
              {t.proofPoints.map((item) => (
                <span key={item}>
                  <CheckCircle2 size={15} />
                  {item}
                </span>
              ))}
            </div>
            <div className="metricRow">
              <div>
                <strong>6+</strong>
                <span>client targets</span>
              </div>
              <div>
                <strong>30+</strong>
                <span>runtime atoms</span>
              </div>
              <div>
                <strong>26</strong>
                <span>test-env services</span>
              </div>
            </div>
          </div>
          <div className="heroAside">
            <PhonePreview />
            <p className="phoneCaption">{t.phoneCaption}</p>
          </div>
        </div>
      </section>

      <section className="playground">
        <div className="shell">
          <div className="sectionHeader split">
            <div>
              <p className="eyebrow">Style playground</p>
              <h2>{t.playgroundTitle}</h2>
              <p>{t.playgroundSubtitle}</p>
            </div>
            <div className="selectedTheme">
              <span>{activeTheme.label}</span>
              <small>{activeTheme.tone}</small>
            </div>
          </div>
          <div className="themeGrid">
            {themes.map((item) => (
              <button
                className={`themeCard ${theme === item.key ? 'active' : ''}`}
                type="button"
                key={item.key}
                onClick={() => setTheme(item.key)}
              >
                <span className={`swatch swatch-${item.key}`} />
                <strong>{item.label}</strong>
                <em>{item.tone}</em>
                <p>{item.description}</p>
              </button>
            ))}
          </div>
        </div>
      </section>

      <section className="stackSection" id="stack">
        <div className="shell">
          <div className="sectionHeader split">
            <div>
              <p className="eyebrow">Architecture</p>
              <h2>{t.stackTitle}</h2>
              <p>{t.stackSubtitle}</p>
            </div>
            <a
              className="button secondary"
              href="https://github.com/dapangyu-fish/ai-app/blob/alpha/v1000/docs/APP_STORE_COMPLIANCE.md"
              target="_blank"
              rel="noreferrer"
            >
              <ShieldCheck size={17} />
              Runtime boundary
            </a>
          </div>
          <div className="stackGrid">
            {t.stackItems.map(([title, body], index) => {
              const icons = [Layers3, Workflow, PackageSearch];
              const Icon = icons[index] ?? Server;
              return (
                <article className="stackCard" key={title}>
                  <div className="stackIcon">
                    <Icon size={22} />
                  </div>
                  <h3>{title}</h3>
                  <p>{body}</p>
                  <div className="stackTrace">
                    <span />
                    <span />
                    <span />
                  </div>
                </article>
              );
            })}
          </div>
          <div className="architectureBand">
            <div>
              <Smartphone size={19} />
              <span>Client runtime</span>
            </div>
            <ChevronRight size={18} />
            <div>
              <Rocket size={19} />
              <span>AI generation</span>
            </div>
            <ChevronRight size={18} />
            <div>
              <Database size={19} />
              <span>Registry + Redis + OSS</span>
            </div>
            <ChevronRight size={18} />
            <div>
              <GitBranch size={19} />
              <span>JSON Apps</span>
            </div>
          </div>
        </div>
      </section>

      <section className="videosSection" id="videos">
        <div className="shell">
          <div className="sectionHeader split">
            <div>
              <p className="eyebrow">Demo library</p>
              <h2>{t.videosTitle}</h2>
              <p>{t.videosSubtitle}</p>
            </div>
            <a className="button secondary" href="#videos">
              <Film size={17} />
              Video slots
            </a>
          </div>
          <div className="videoGrid">
            {t.videoCards.map(([title, body], index) => (
              <article className="videoCard" key={title}>
                <div className="videoThumb">
                  <Play size={28} />
                </div>
                <span>{String(index + 1).padStart(2, '0')}</span>
                <h3>{title}</h3>
                <p>{body}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="deploySection" id="deploy">
        <div className="shell">
          <div className="sectionHeader">
            <p className="eyebrow">Deploy first</p>
            <h2>{t.deployTitle}</h2>
            <p>{t.deployHint}</p>
          </div>
          <div className="deployCards">
            <article className="deployCard">
              <h3>{t.backendDeployTitle}</h3>
              <TerminalBox
                lines={[
                  '$ cd deploy/test-env',
                  '$ ./bootstrap.sh',
                  '# save the QR / JSON / test account from output',
                ]}
              />
            </article>
            <article className="deployCard">
              <h3>{t.clientBuildTitle}</h3>
              <TerminalBox
                lines={[
                  '$ flutter pub get',
                  '$ flutter run -d chrome',
                  '$ flutter build apk --release',
                  '$ flutter build ios --release',
                  '$ ./scripts/build_cloudflare_pages.sh',
                ]}
              />
            </article>
            <article className="deployCard">
              <h3>{t.switchEnvTitle}</h3>
              <p>{t.switchEnvBody}</p>
            </article>
            <article className="deployCard">
              <h3>{t.usageTitle}</h3>
              <p>{t.usageBody}</p>
              <a className="inlineLink" href={WEB_APP_URL} target="_blank" rel="noreferrer">
                {t.openWeb}
                <ChevronRight size={16} />
              </a>
            </article>
          </div>
        </div>
      </section>

      <section className="stepsSection">
        <div className="shell">
          <div className="sectionHeader">
            <p className="eyebrow">Workflow</p>
            <h2>{t.howTitle}</h2>
            <p>{t.howSubtitle}</p>
          </div>
          <div className="stepsGrid">
            {t.steps.map(([title, body], index) => (
              <article className="stepCard" key={title}>
                <span>{String(index + 1).padStart(2, '0')}</span>
                <h3>{title}</h3>
                <p>{body}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="featuresSection" id="features">
        <div className="shell">
          <div className="sectionHeader">
            <p className="eyebrow">Runtime stack</p>
            <h2>{t.featuresTitle}</h2>
            <p>{t.featuresSubtitle}</p>
          </div>
          <div className="compliancePanel">
            <div>
              <LockKeyhole size={22} />
              <h3>{t.complianceTitle}</h3>
            </div>
            <p>{t.complianceBody}</p>
          </div>
          <div className="featureGrid">
            {t.features.map(([title, body], index) => {
              const icons = [Bot, Smartphone, MessageCircle, Boxes, Cloud, Zap];
              const Icon = icons[index] ?? Code2;
              return (
                <article className="featureCard" key={title}>
                  <Icon size={22} />
                  <h3>{title}</h3>
                  <p>{body}</p>
                </article>
              );
            })}
          </div>
        </div>
      </section>

      <section className="downloadSection" id="download">
        <div className="shell downloadPanel">
          <div>
            <p className="eyebrow">Release path</p>
            <h2>{t.downloadTitle}</h2>
            <p>{t.downloadBody}</p>
          </div>
          <div className="actions">
            <a className="button primary" href={WEB_APP_URL} target="_blank" rel="noreferrer">
              <Play size={17} />
              {t.openWeb}
            </a>
            <a className="button secondary" href={TESTFLIGHT_URL} target="_blank" rel="noreferrer">
              <Smartphone size={17} />
              {t.appStore}
              <small>{t.available}</small>
            </a>
            <a className="button secondary unavailable" href="#download" aria-disabled="true">
              <Download size={17} />
              {t.googlePlay}
              <small>{t.soon}</small>
            </a>
            <a className="button secondary unavailable" href="#download" aria-disabled="true">
              <Download size={17} />
              {t.apk}
              <small>{t.soon}</small>
            </a>
          </div>
        </div>
      </section>

      <footer className="footer">
        <div className="shell">
          <span>MyApp</span>
          <a href="mailto:2501808198@qq.com">fish</a>
        </div>
      </footer>
    </main>
  );
}

export default App;
