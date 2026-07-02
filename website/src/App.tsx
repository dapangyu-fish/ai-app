import {
  BookOpen,
  Bot,
  Boxes,
  ChevronRight,
  CheckCircle2,
  Cloud,
  Code2,
  Database,
  Download,
  Github,
  Globe2,
  Layers3,
  LockKeyhole,
  MessageCircle,
  Network,
  PackageSearch,
  Play,
  Server,
  ShieldCheck,
  Smartphone,
  Sparkles,
  Workflow,
} from 'lucide-react';
import {
  type MouseEvent as ReactMouseEvent,
  useEffect,
  useState,
} from 'react';

type Lang = 'zh' | 'en' | 'de' | 'es' | 'fr' | 'pt' | 'ca' | 'hi' | 'ko' | 'ja' | 'it';
type Page = 'home' | 'docs';

const WEB_APP_URL = 'https://myapp-web.dapangyu.work/';
const TESTFLIGHT_URL = 'https://testflight.apple.com/join/3Fk5Exnn';
const APK_URL = 'https://myapp-oss-endpoint.dapangyu.work/myapp-releases/android/apk/latest.apk';
const GITHUB_URL = 'https://github.com/dapangyu-fish/ai-app';
const GITHUB_PUBLIC = GITHUB_URL.length > 0;
const REVIEW_BOUNDARY_URL = '/docs#runtime-boundary';

const languageOptions: Array<{ key: Lang; label: string; flag: string }> = [
  { key: 'zh', label: '中文', flag: '🇨🇳' },
  { key: 'en', label: 'English', flag: '🇺🇸' },
  { key: 'de', label: 'Deutsch', flag: '🇩🇪' },
  { key: 'es', label: 'Español', flag: '🇪🇸' },
  { key: 'fr', label: 'Français', flag: '🇫🇷' },
  { key: 'pt', label: 'Português', flag: '🇵🇹' },
  { key: 'ca', label: 'Català', flag: '🇪🇸' },
  { key: 'hi', label: 'हिन्दी', flag: '🇮🇳' },
  { key: 'ko', label: '한국어', flag: '🇰🇷' },
  { key: 'ja', label: '日本語', flag: '🇯🇵' },
  { key: 'it', label: 'Italiano', flag: '🇮🇹' },
];

const copy = {
  zh: {
    navHow: '部署',
    navStack: '架构',
    navTry: '演示',
    navFeatures: '能力',
    navDownload: '下载',
    badge: 'Vibe app,不是 codebase · Web · iOS · Android · 桌面',
    titleA: '别再 vibe coding。',
    titleB: '直接出 vibe app。',
    subtitle:
      'Vibe coding——哪怕最强的 AI 生成器——给你的还是一份要自己托管、维护的 web 代码库。Vibe app 直接就是活的——在你手机上原生、几秒即刻运行：描述你想要的，AI 一句话生成整条栈——UI + 真正的 Python/Flask 后端 + 独立 Postgres 数据库——在预编译的跨端运行时里即时跑起来。同一句话，能出一个能玩的游戏，也能出一个带真后端、能登录发帖盖楼的论坛。没有代码工程，不用打包，不用部署，不用上架。',
    primaryCta: '打开 Web 版',
    secondaryCta: '加入 TestFlight',
    phoneCaption: '一个真在跑的 app，不是一份要你托管的代码。现在就能在 Web 打开，任意一块屏都行。',
    heroConsoleTitle: '一句话 → 一个上线的 app',
    heroConsoleLines: [
      '$ describe "一个能登录、发帖、楼中楼的论坛"',
      '→ AI 写好 UI + 真后端 + 数据库',
      '→ 不打包 · 不部署 · 不上架',
      '→ Web · iOS · Android · 桌面 即开',
    ],
    proofPoints: ['没有代码工程 · 不打包 · 不部署', '全栈：UI + 后端 + 数据库', '一句话 → iOS · Android · Web · 桌面'],
    authorNoteEyebrow: '来自作者',
    authorNoteTitle: '为什么会有这个项目',
    authorNoteBody: [
      '说实话，我很反感当下的 AI 狂热——没完没了的讨论、没完没了的营销。但无论我喜不喜欢，这股浪潮都不会退去。',
      '既然要拥抱 AI Coding，那就干脆做到底，而不是做一半。讽刺的是，这恰恰就是这个项目存在的原因。我的目标从来不是追风口，而是把这个想法推到逻辑的终点，然后问一句：如果 AI 真的是开发的未来，一个真正 AI-first 的工作流应该是什么样子？',
      '这个项目，就是我目前为止的答案。',
    ],
    trustTitle: '产品可信边界',
    trustPoints: [
      ['声明式 JSON', 'AI 不下发原生代码或二进制'],
      ['自部署后端', 'myapp-ctl 一键部署核心服务'],
      ['跨端运行时', 'Flutter Web、iOS、Android 共用能力层'],
    ],
    docsTitle: '开发者入口',
    docsLinks: [
      ['部署文档', '从 myapp-ctl 部署到客户端切换环境'],
      ['架构图', '理解运行时、AI Worker 与 Registry'],
      ['运行时边界', '理解预编译能力集合与审核友好的合规边界'],
    ],
    videosTitle: '真实生成案例',
    videosSubtitle: '展示 AI 可以生成的不同应用形态：工具、游戏和社区页面，而不是同一套界面的换壳。',
    deployTitle: '私有部署与客户端接入',
    deployHint: '私有部署主要是后端；客户端可以使用线上 Web，也可以自己 build iOS / Android / Web，然后在客户端切换环境。',
    backendDeployTitle: '1. 部署后端测试环境',
    clientBuildTitle: '2. 构建客户端',
    switchEnvTitle: '3. 客户端切换环境',
    switchEnvBody: '打开客户端的 Service Environment 页面，扫码或粘贴后端环境 JSON。保存后重新登录，客户端就会连接到你的后端。',
    usageTitle: '4. 怎么使用',
    usageBody: '登录测试账号后，可以打开应用库安装 JSON App，也可以用悬浮 AI 入口描述需求，让 AI 生成应用，再继续通过对话迭代。',
    howTitle: '从想法到应用',
    howSubtitle: '完整流程是部署后端、构建或打开客户端、切换环境、安装或生成应用。',
    steps: [
      ['准备环境', '安装 myapp-ctl，配置密钥，然后部署后端服务。'],
      ['连接客户端', 'Web / iOS / Android 都通过环境切换页连接到你的后端。'],
      ['生成或安装 App', '在应用库安装 JSON App，或让 AI 生成新的应用。'],
    ],
    featuresTitle: '平台能力',
    featuresSubtitle: '围绕 AI 全栈生成、运行时渲染、游戏、应用库和自部署。',
    stackTitle: '一套运行时，四条关键链路',
    stackSubtitle: '客户端只解释已允许的 JSON 能力；后端负责在隔离 agent 节点上的 AI 生成、AI 生成的 FaaS 后端、包分发、IM、配置和可恢复任务。',
    stackItems: [
      ['Flutter Runtime', '预编译控件、JsonLogic、Flame 游戏 atoms、IM 兼容层和媒体能力。'],
      ['AI Worker Queue', 'Redis 队列、隔离的 pull 式 agent-node 执行、SSE 恢复、并发控制和结果持久化。'],
      ['AI FaaS 后端', 'AI 生成的 Python/Flask 后端：bundle 校验、隔离 git push worker、自研容器化 FaaS 运行时（每服务独立容器、无函数数量上限、自动 scale-to-zero 与冷唤醒）、路由校验的调用代理，以及应用级权限模型——每应用隔离数据库、可信假名身份、后端中介的按调用者隔离数据访问层（函数不持数据库连接）、容器加固与可撤销的访问策略。'],
      ['Registry + Assets', '分页搜索、版本约束、组件依赖、跨实例镜像和 OSS/MinIO 资源分发。'],
    ],
    complianceTitle: '审核友好的边界',
    complianceBody: 'AI 为客户端生成的是声明式 JSON 配置：只组合已编译的控件和动作，不下发 Dart、Swift、Kotlin、插件或二进制。需要后端时，生成的 FaaS 服务运行在隔离的自研容器化 FaaS 运行时（服务端），同样不会向客户端下发可执行代码。',
    features: [
      ['全栈生成（核心差异化）', '别的 AI 生成器给你的还是一份要自己托管、维护的 web 代码库；MyApp 一句话同时生成 JSON 前端和配套的、经校验的 Python/Flask 后端，部署到隔离的自研容器化 FaaS 运行时（无函数数量上限、自动 scale-to-zero、冷唤醒与扩缩容）并立即运行。每个应用还自带隔离的 Postgres 数据库与应用级权限模型（所有者 / 维护者 / 消费者）——消费者数据由平台按调用者强制隔离，函数代码拿不到数据库连接。'],
      ['AI 原生 DSL', '为大模型生成而设计，并渲染成真正的原生 UI，而不只是手写配置。'],
      ['Flame 游戏', '真正的 2D 游戏引擎——精灵、物理、Tiled 地图——在 Web、iOS、Android 上运行，而不只是小玩具。'],
      ['内置 IM', '好友、群聊、消息同步和 Web OpenIM 兼容层。'],
      ['应用库', '带命名空间的 Registry：版本约束、依赖解析和跨实例镜像。'],
      ['能力边界', 'UI 和业务以数据形式下发，运行在预编译的能力集合内；登录 token 等敏感能力需按 App 授权。'],
      ['可自部署', 'myapp-ctl 一键部署整套后端、agent 运行时和 Registry；同一套 DSL 跑在 iOS、Android、Web 和桌面构建上。'],
    ],
    downloadTitle: '开始体验 MyApp',
    downloadBody: 'Web 版可直接打开；iOS 已开放 TestFlight Public Group 1（2500 人）；Android 可下载 APK，Google Play 正在准备中。',
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
    navTry: 'Tour',
    navFeatures: 'Capabilities',
    navDownload: 'Download',
    badge: 'A vibe app, not a codebase · Web · iOS · Android · Desktop',
    titleA: 'Stop vibe-coding.',
    titleB: 'Ship vibe-apps.',
    subtitle:
      'Vibe coding — even the best AI app builders — still gives you a web codebase to host and maintain. A vibe app is just live — native on your phone in seconds: describe what you want, and AI generates the whole stack — UI + a real Python/Flask backend + its own Postgres database — running instantly inside a precompiled, cross-platform runtime. The same sentence can spin up a playable game or a forum with a real backend. No codebase. No build. No deploy. No app store.',
    primaryCta: 'Open Web app',
    secondaryCta: 'Join TestFlight',
    phoneCaption: 'A real, running app — not a codebase you have to host. Open it on Web now, on any screen.',
    heroConsoleTitle: 'One sentence → a live app',
    heroConsoleLines: [
      '$ describe "a forum with login, posts & threaded replies"',
      '→ AI writes the UI + a real backend + database',
      '→ no build · no deploy · no app store',
      '→ live on Web · iOS · Android · desktop',
    ],
    proofPoints: ['No codebase · no build · no deploy', 'Full-stack: UI + backend + database', 'One prompt → iOS · Android · Web · desktop'],
    authorNoteEyebrow: 'From the author',
    authorNoteTitle: 'Why this exists',
    authorNoteBody: [
      'To be honest, I dislike today\'s AI hype — the endless discussion, the endless marketing. But whether I like it or not, this wave isn\'t going away.',
      'So if we\'re going to embrace AI coding, we might as well take it all the way instead of doing it halfway. Ironically, that\'s exactly why this project exists. The goal was never to chase the trend — it was to push the idea to its logical conclusion and ask: if AI really is the future of development, what would a truly AI-first workflow look like?',
      'This project is my answer so far.',
    ],
    trustTitle: 'Trust boundary',
    trustPoints: [
      ['Declarative JSON', 'AI does not ship native code or binaries'],
      ['Self-hostable backend', 'myapp-ctl deploy starts the core services'],
      ['Cross-client runtime', 'Flutter Web, iOS and Android share one capability layer'],
    ],
    docsTitle: 'Developer entry points',
    docsLinks: [
      ['Deployment docs', 'Deploy backend with myapp-ctl, then switch client environment'],
      ['Architecture diagram', 'Runtime, AI Worker and Registry in one view'],
      ['Runtime boundary', 'How the precompiled capability set and review-friendly boundary work'],
    ],
    videosTitle: 'Generated app examples',
    videosSubtitle: 'Three different app shapes show tools, games and community screens instead of one repeated shell.',
    deployTitle: 'Private backend and client setup',
    deployHint: 'Private deployment mainly means the backend. The client can use the hosted Web app, or you can build iOS / Android / Web yourself and switch environments in the client.',
    backendDeployTitle: '1. Deploy backend test environment',
    clientBuildTitle: '2. Build clients',
    switchEnvTitle: '3. Switch client environment',
    switchEnvBody: 'Open Service Environment in the client, then paste or scan the backend environment JSON. Save and sign in again to connect to your backend.',
    usageTitle: '4. How to use it',
    usageBody: 'After signing in with the test account, install JSON Apps from the app library or use the floating AI entry to describe an app and iterate through chat.',
    howTitle: 'Idea to app',
    howSubtitle: 'The full flow is myapp-ctl backend deployment, client build/open, environment switch, then install or generate apps.',
    steps: [
      ['Prepare environment', 'Use myapp-ctl to deploy services and manage backend secrets.'],
      ['Connect client', 'Web / iOS / Android all connect through the environment switch page.'],
      ['Generate or install apps', 'Install JSON Apps from the app library or ask AI to generate new ones.'],
    ],
    featuresTitle: 'Platform capabilities',
    featuresSubtitle: 'Built around AI full-stack generation, runtime rendering, games, an app library and self-hosting.',
    stackTitle: 'One runtime, four critical paths',
    stackSubtitle: 'The client interprets only approved JSON capabilities. The backend handles AI generation on isolated agent nodes, AI-generated FaaS backends, package distribution, IM, config and resumable tasks.',
    stackItems: [
      ['Flutter Runtime', 'Precompiled widgets, JsonLogic, Flame game atoms, IM compatibility and media capabilities.'],
      ['AI Worker Queue', 'Redis queue, isolated pull-based agent-node execution, resumable SSE, concurrency limits and durable results.'],
      ['AI FaaS backends', 'AI-generated Python/Flask backends: validated bundles, an isolated git push worker, a self-managed containerized FaaS runtime (one container per service, no function-count cap, automatic scale-to-zero and cold-wake), a route-enforced invoke proxy, and an application-level permission model — per-app isolated database, trusted pseudonymous identity, a backend-mediated per-caller data layer (functions hold no DB connection), container hardening and revocable access policies.'],
      ['Registry + Assets', 'Paginated search, semver, component dependencies, cross-instance mirror and OSS/MinIO asset delivery.'],
    ],
    complianceTitle: 'Review-friendly boundary',
    complianceBody: 'AI produces declarative JSON for the client: it composes only compiled widgets and actions, never Dart, Swift, Kotlin, plugins or binaries. When an app needs a backend, the generated FaaS services run server-side in an isolated self-managed containerized FaaS runtime, so no executable code is shipped to the client.',
    features: [
      ['Full-stack generation (the differentiator)', 'Other AI builders give you a web codebase to host and maintain. MyApp generates the JSON app and a matching validated Python/Flask backend from one prompt, deployed to an isolated self-managed containerized FaaS runtime (no function-count cap, automatic scale-to-zero, cold-wake and autoscaling), and runs it instantly. Each app also gets an isolated Postgres database and an application-level permission model (owner / maintainer / consumer) — consumer data is isolated per-caller by the platform, and function code never holds a database connection.'],
      ['AI-native DSL', 'Structured for LLM generation and rendered to real native UI, not just hand-written config.'],
      ['Flame games', 'A real 2D game engine — sprites, physics and tiled maps — running on Web, iOS and Android, not just toys.'],
      ['Built-in IM', 'Friends, groups, sync and the OpenIM compatibility layer for Web.'],
      ['App library', 'Namespaced registry with semver, dependency resolution and cross-instance mirroring.'],
      ['Capability boundary', 'UI and behavior ship as data inside a precompiled capability set; sensitive capabilities like the auth token need per-app authorization.'],
      ['Self-hostable', 'myapp-ctl deploys the whole backend, agent runtime and registry; one DSL renders on iOS, Android, Web and desktop builds.'],
    ],
    downloadTitle: 'Start using MyApp',
    downloadBody: 'Open the Web app now. iOS is available through TestFlight Public Group 1 with 2,500 seats. Android APK download is available while Google Play is being prepared.',
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
    navTry: 'Demo',
    navFeatures: 'Funktionen',
    navDownload: 'Download',
    badge: 'Eine vibe app, keine Codebasis · Web · iOS · Android · Desktop',
    titleA: 'Schluss mit vibe-coding.',
    titleB: 'Her mit vibe-apps.',
    subtitle:
      'Vibe coding — selbst die besten KI-App-Builder — gibt dir am Ende immer noch eine Web-Codebasis zum Hosten und Warten. Eine vibe app ist einfach live — nativ auf deinem Handy in Sekunden: Beschreibe, was du willst, und die KI erzeugt den ganzen Stack — UI + ein echtes Python/Flask-Backend + eine eigene Postgres-Datenbank — sofort lauffähig in einer vorkompilierten, plattformübergreifenden Laufzeitumgebung. Derselbe Satz bringt ein spielbares Spiel hervor oder ein Forum mit echtem Backend. Keine Codebasis. Kein Build. Kein Deploy. Kein App Store.',
    primaryCta: 'Live-Demo öffnen',
    secondaryCta: 'Deployment ansehen',
    phoneCaption: 'Eine echte, laufende App — keine Codebasis, die du hosten musst. Jetzt im Web öffnen, auf jedem Bildschirm.',
    heroConsoleTitle: 'Ein Satz → eine laufende App',
    heroConsoleLines: [
      '$ describe "ein Forum mit Login, Beiträgen und verschachtelten Antworten"',
      '→ KI schreibt UI + echtes Backend + Datenbank',
      '→ kein Build · kein Deploy · kein App Store',
      '→ live auf Web · iOS · Android · Desktop',
    ],
    proofPoints: ['Keine Codebasis · kein Build · kein Deploy', 'Full-Stack: UI + Backend + Datenbank', 'Ein Prompt → iOS · Android · Web · Desktop'],
    authorNoteEyebrow: 'Vom Autor',
    authorNoteTitle: 'Warum es dieses Projekt gibt',
    authorNoteBody: [
      'Ganz ehrlich: Ich mag den heutigen KI-Hype nicht — die endlosen Diskussionen, das endlose Marketing. Aber ob es mir gefällt oder nicht, diese Welle geht nicht wieder weg.',
      'Wenn wir uns also schon auf KI-Coding einlassen, dann können wir es genauso gut ganz durchziehen, statt es nur halb zu machen. Ironischerweise ist genau das der Grund, warum es dieses Projekt gibt. Das Ziel war nie, dem Trend hinterherzulaufen — sondern die Idee bis zu ihrem logischen Ende zu treiben und zu fragen: Wenn KI tatsächlich die Zukunft der Softwareentwicklung ist, wie sähe dann ein Workflow aus, der wirklich AI-first ist?',
      'Dieses Projekt ist meine bisherige Antwort.',
    ],
    trustTitle: 'Vertrauensgrenze',
    trustPoints: [
      ['Deklaratives JSON', 'Die KI liefert keinen nativen Code und keine Binaries.'],
      ['Self-hostable Backend', 'myapp-ctl deploy startet die Kernservices.'],
      ['Cross-Client-Runtime', 'Flutter Web, iOS und Android teilen eine Capability-Schicht.'],
    ],
    docsTitle: 'Einstiegspunkte für Entwickler',
    docsLinks: [
      ['Deployment-Docs', 'Backend mit myapp-ctl deployen, dann Client-Umgebung wechseln'],
      ['Architekturdiagramm', 'Runtime, AI Worker und Registry in einer Ansicht'],
      ['Runtime-Grenze', 'Vorkompiliertes Capability-Set und die review-freundliche Grenze'],
    ],
    videosTitle: 'Generierte App-Beispiele',
    videosSubtitle: 'Drei unterschiedliche App-Formen zeigen Tools, Games und Community-Screens statt einer wiederholten Hülle.',
    deployTitle: 'Private Backend-Bereitstellung und Client-Setup',
    deployHint: 'Privates Deployment betrifft vor allem das Backend. Den Client kannst du als gehostete Web-App nutzen oder iOS / Android / Web selbst bauen.',
    backendDeployTitle: '1. Backend-Testumgebung starten',
    clientBuildTitle: '2. Clients bauen',
    switchEnvTitle: '3. Client-Umgebung wechseln',
    switchEnvBody: 'Öffne im Client Service Environment, scanne oder füge das vollständige Environment-JSON ein. Danach speichern und neu anmelden.',
    usageTitle: '4. Nutzung',
    usageBody: 'Nach dem Login mit dem Testkonto kannst du Apps aus der App-Bibliothek installieren oder über den schwebenden KI-Einstieg neue Apps beschreiben und iterieren.',
    howTitle: 'Von der Idee zur App',
    howSubtitle: 'Der Ablauf: Backend starten, Client bauen oder öffnen, Umgebung wechseln, App installieren oder generieren.',
    steps: [
      ['Umgebung vorbereiten', 'myapp-ctl installieren, Secrets konfigurieren und Backend-Services bereitstellen.'],
      ['Client verbinden', 'Web / iOS / Android verbinden sich über die Environment-Seite.'],
      ['Apps nutzen', 'Apps aus der App-Bibliothek installieren oder per KI generieren.'],
    ],
    featuresTitle: 'Plattformfunktionen',
    featuresSubtitle: 'Rund um KI-Full-Stack-Generierung, Runtime-Rendering, Games, App-Bibliothek und Self-Hosting.',
    stackTitle: 'Eine Runtime, vier Kernpfade',
    stackSubtitle: 'Der Client interpretiert nur erlaubte JSON-Fähigkeiten. Das Backend steuert KI-Generierung auf isolierten Agent-Nodes, KI-generierte FaaS-Backends, Pakete, IM, Config und wiederaufnehmbare Tasks.',
    stackItems: [
      ['Flutter Runtime', 'Vorkompilierte Widgets, JsonLogic, Flame Game Atoms, IM-Kompatibilität und Medienfunktionen.'],
      ['AI Worker Queue', 'Redis-Queue, isolierte pull-basierte Agent-Node-Ausführung, wiederaufnehmbare SSE, Limits und persistente Ergebnisse.'],
      ['AI FaaS-Backends', 'KI-generierte Python/Flask-Backends: validierte Bundles, isolierter Git-Push-Worker, selbstverwaltete containerisierte FaaS-Runtime (ein Container pro Service, keine Funktionsanzahl-Grenze, automatisches Scale-to-Zero und Cold-Wake) und ein route-geprüfter Invoke-Proxy.'],
      ['Registry + Assets', 'Suche mit Pagination, Semver, Komponentenabhängigkeiten, Cross-Instance-Mirror und OSS/MinIO Assets.'],
    ],
    complianceTitle: 'Review-freundliche Grenze',
    complianceBody: 'Die KI erzeugt deklarative JSON-Konfiguration für den Client: nur kompilierte Widgets und Actions, kein Dart-, Swift-, Kotlin-, Plugin- oder Binärcode. Braucht eine App ein Backend, laufen die generierten FaaS-Services serverseitig in einer isolierten selbstverwalteten containerisierten FaaS-Runtime; es wird kein ausführbarer Code an den Client ausgeliefert.',
    features: [
      ['Full-Stack-Generierung (das Alleinstellungsmerkmal)', 'Andere KI-Builder liefern dir eine Web-Codebasis, die du selbst hosten und warten musst. MyApp erzeugt aus einem Prompt die JSON App und ein passendes validiertes Python/Flask-Backend in isolierter selbstverwalteter containerisierter FaaS-Runtime (keine Funktionsanzahl-Grenze, automatisches Scale-to-Zero, Cold-Wake und Autoscaling) und führt sie sofort aus. Jede App erhält außerdem eine isolierte Postgres-Datenbank und ein Berechtigungsmodell auf App-Ebene (Owner / Maintainer / Consumer) — Consumer-Daten werden von der Plattform pro Aufrufer isoliert, und Funktionscode erhält nie eine Datenbankverbindung.'],
      ['AI-native DSL', 'Für LLM-Generierung gebaut und in echtes natives UI gerendert, nicht nur manuelle Konfiguration.'],
      ['Flame Games', 'Eine echte 2D-Game-Engine – Sprites, Physik und Tiled-Maps – auf Web, iOS und Android, nicht nur Spielzeug.'],
      ['Integriertes IM', 'Freunde, Gruppen, Sync und OpenIM-Kompatibilität für Web.'],
      ['App-Bibliothek', 'Registry mit Namespaces: Semver, Abhängigkeitsauflösung und Cross-Instance-Mirror.'],
      ['Capability-Grenze', 'UI und Verhalten als Daten in einem vorkompilierten Capability-Set; sensible Funktionen wie das Auth-Token brauchen App-Freigabe.'],
      ['Self-hostable', 'myapp-ctl deployt Backend, Agent-Runtime und Registry; eine DSL läuft auf iOS, Android, Web und Desktop-Builds.'],
    ],
    downloadTitle: 'MyApp jetzt starten',
    downloadBody: 'Die Web-App ist direkt verfügbar. iOS läuft über TestFlight Public Group 1 mit 2.500 Plätzen. Der Android-APK-Download ist verfügbar, Google Play folgt.',
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
    navTry: 'Demo',
    navFeatures: 'Capacidades',
    navDownload: 'Descargar',
    badge: 'Una vibe app, no una base de código · Web · iOS · Android · Desktop',
    titleA: 'Deja el vibe-coding.',
    titleB: 'Lanza vibe-apps.',
    subtitle:
      'El vibe coding —incluso los mejores constructores de apps con IA— sigue entregándote una base de código web que alojar y mantener. Una vibe app simplemente está viva — nativa en tu teléfono en segundos: describe lo que quieres y la IA genera todo el stack — UI + un backend real de Python/Flask + su propia base de datos Postgres — en marcha al instante dentro de un runtime multiplataforma precompilado. La misma frase puede poner en marcha un juego jugable o un foro con un backend real. Sin base de código. Sin compilación. Sin despliegue. Sin tienda de apps.',
    primaryCta: 'Abrir demo',
    secondaryCta: 'Ver despliegue',
    phoneCaption: 'Una app real en ejecución, no una base de código que tengas que alojar. Ábrela en la Web ahora, en cualquier pantalla.',
    heroConsoleTitle: 'Una frase → una app en vivo',
    heroConsoleLines: [
      '$ describe "un foro con inicio de sesión, publicaciones y respuestas anidadas"',
      '→ la IA escribe la UI + un backend real + base de datos',
      '→ sin compilación · sin despliegue · sin tienda de apps',
      '→ en vivo en Web · iOS · Android · escritorio',
    ],
    proofPoints: ['Sin base de código · sin compilación · sin despliegue', 'Full-stack: UI + backend + base de datos', 'Un prompt → iOS · Android · Web · escritorio'],
    authorNoteEyebrow: 'Del autor',
    authorNoteTitle: 'Por qué existe esto',
    authorNoteBody: [
      'Si soy sincero, me desagrada el hype actual de la IA: las discusiones interminables, el marketing interminable. Pero, me guste o no, esta ola no va a desaparecer.',
      'Así que, puestos a abrazar el AI coding, más vale llegar hasta el final en lugar de quedarse a medias. Irónicamente, esa es exactamente la razón por la que existe este proyecto. El objetivo nunca fue perseguir la moda, sino llevar la idea hasta su conclusión lógica y preguntar: si la IA es de verdad el futuro del desarrollo, ¿cómo sería un flujo de trabajo verdaderamente AI-first?',
      'Este proyecto es mi respuesta hasta ahora.',
    ],
    trustTitle: 'Límite de confianza',
    trustPoints: [
      ['JSON declarativo', 'La IA no envía código nativo ni binarios.'],
      ['Backend autoalojable', 'myapp-ctl deploy levanta los servicios centrales.'],
      ['Runtime multicliente', 'Flutter Web, iOS y Android comparten una capa de capacidades.'],
    ],
    docsTitle: 'Puntos de entrada para desarrolladores',
    docsLinks: [
      ['Docs de despliegue', 'Despliega el backend con myapp-ctl y cambia el entorno del cliente'],
      ['Diagrama de arquitectura', 'Runtime, AI Worker y Registry en una vista'],
      ['Límite del runtime', 'El set de capacidades precompilado y el límite apto para revisión'],
    ],
    videosTitle: 'Ejemplos de apps generadas',
    videosSubtitle: 'Tres formas distintas muestran herramientas, juegos y pantallas de comunidad, no una misma carcasa repetida.',
    deployTitle: 'Backend privado y configuración del cliente',
    deployHint: 'El despliegue privado es principalmente el backend. Puedes usar la Web hospedada o compilar iOS / Android / Web por tu cuenta.',
    backendDeployTitle: '1. Desplegar backend de prueba',
    clientBuildTitle: '2. Compilar clientes',
    switchEnvTitle: '3. Cambiar entorno del cliente',
    switchEnvBody: 'Abre Service Environment en el cliente, escanea o pega el JSON completo del entorno. Guarda e inicia sesión de nuevo.',
    usageTitle: '4. Cómo usarlo',
    usageBody: 'Después de iniciar sesión con la cuenta de prueba, instala JSON Apps desde la biblioteca o usa la entrada flotante de IA para describir una app e iterar por chat.',
    howTitle: 'De idea a app',
    howSubtitle: 'El flujo completo: desplegar backend, abrir o compilar cliente, cambiar entorno y luego instalar o generar apps.',
    steps: [
      ['Preparar entorno', 'Instala myapp-ctl, configura secretos y despliega los servicios backend.'],
      ['Conectar cliente', 'Web / iOS / Android se conectan desde la página de entorno.'],
      ['Crear o instalar apps', 'Instala desde la biblioteca o pide a la IA que genere una nueva app.'],
    ],
    featuresTitle: 'Capacidades de la plataforma',
    featuresSubtitle: 'Centrada en generación full-stack con IA, runtime, juegos, biblioteca de apps y self-hosting.',
    stackTitle: 'Un runtime, cuatro rutas críticas',
    stackSubtitle: 'El cliente interpreta solo capacidades JSON aprobadas. El backend maneja la generación con IA en agent-nodes aislados, backends FaaS generados por IA, paquetes, IM, configuración y tareas recuperables.',
    stackItems: [
      ['Flutter Runtime', 'Widgets precompilados, JsonLogic, game atoms de Flame, compatibilidad IM y capacidades multimedia.'],
      ['AI Worker Queue', 'Cola Redis, ejecución aislada en agent-node (pull), SSE recuperable, límites de concurrencia y resultados persistentes.'],
      ['Backends FaaS con IA', 'Backends Python/Flask generados por IA: bundles validados, git push worker aislado, runtime FaaS contenedorizado propio (un contenedor por servicio, sin límite de número de funciones, scale-to-zero automático y cold-wake) y un proxy de invocación con rutas verificadas.'],
      ['Registry + Assets', 'Búsqueda paginada, semver, dependencias de componentes, mirror entre instancias y assets OSS/MinIO.'],
    ],
    complianceTitle: 'Límite claro para revisión',
    complianceBody: 'La IA produce configuración JSON declarativa para el cliente: solo compone widgets y acciones ya compilados, nunca Dart, Swift, Kotlin, plugins ni binarios. Cuando una app necesita backend, los servicios FaaS generados corren en el servidor dentro de un runtime FaaS contenedorizado propio y aislado; nunca se envía código ejecutable al cliente.',
    features: [
      ['Generación full-stack (el diferenciador)', 'Otros generadores de IA te dan una base de código web que debes alojar y mantener. MyApp genera de un solo prompt la app JSON y un backend Python/Flask validado a juego en un runtime FaaS contenedorizado propio y aislado (sin límite de número de funciones, scale-to-zero automático, cold-wake y autoescalado), y lo ejecuta al instante. Cada app obtiene además una base de datos Postgres aislada y un modelo de permisos a nivel de aplicación (propietario / mantenedor / consumidor): los datos de cada consumidor quedan aislados por llamante en la plataforma, y el código de la función nunca tiene una conexión a la base de datos.'],
      ['DSL nativa para IA', 'Pensada para LLMs y renderizada como UI nativa real, no solo configuración manual.'],
      ['Juegos con Flame', 'Un motor 2D real —sprites, física y mapas Tiled— en Web, iOS y Android, no solo juguetes.'],
      ['IM integrado', 'Amigos, grupos, sincronización y compatibilidad OpenIM para Web.'],
      ['Biblioteca de apps', 'Registry con namespaces: semver, resolución de dependencias y mirror entre instancias.'],
      ['Límite de capacidades', 'UI y comportamiento como datos dentro de un set de capacidades precompilado; las capacidades sensibles como el token de sesión requieren autorización por app.'],
      ['Autoalojable', 'myapp-ctl despliega backend, runtime de agentes y registry; una DSL corre en iOS, Android, Web y builds de escritorio.'],
    ],
    downloadTitle: 'Empieza con MyApp',
    downloadBody: 'La Web app está disponible ahora. iOS está en TestFlight Public Group 1 con 2.500 plazas. La descarga APK de Android está disponible mientras Google Play se prepara.',
    openWeb: 'Abrir Web app',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: 'Disponible',
    soon: 'Próximamente',
  },
  fr: {
    navHow: 'Déployer',
    navStack: 'Stack',
    navTry: 'Visite',
    navFeatures: 'Capacités',
    navDownload: 'Télécharger',
    badge: 'Une vibe app, pas une base de code · Web · iOS · Android · Desktop',
    titleA: 'Arrêtez le vibe-coding.',
    titleB: 'Livrez des vibe-apps.',
    subtitle:
      'Le vibe coding — même les meilleurs générateurs d\'applications par IA — vous remet toujours une base de code web à héberger et maintenir. Une vibe app est simplement live — native sur votre téléphone en quelques secondes : décrivez ce que vous voulez, et l\'IA génère toute la stack — UI + un vrai backend Python/Flask + sa propre base de données Postgres — exécutée instantanément dans un runtime précompilé et multiplateforme. La même phrase peut faire surgir un jeu jouable ou un forum doté d\'un vrai backend. Pas de base de code. Pas de build. Pas de déploiement. Pas d\'app store.',
    primaryCta: 'Ouvrir la Web app',
    secondaryCta: 'Rejoindre TestFlight',
    phoneCaption: 'Une vraie app qui tourne, pas une base de code à héberger. Ouvrez-la sur le Web dès maintenant, sur n\'importe quel écran.',
    heroConsoleTitle: 'Une phrase → une app en ligne',
    heroConsoleLines: [
      '$ describe "un forum avec connexion, publications et réponses imbriquées"',
      '→ l\'IA écrit l\'UI + un vrai backend + base de données',
      '→ pas de build · pas de déploiement · pas d\'app store',
      '→ en ligne sur Web · iOS · Android · desktop',
    ],
    proofPoints: ['Pas de base de code · pas de build · pas de déploiement', 'Full-stack : UI + backend + base de données', 'Un prompt → iOS · Android · Web · desktop'],
    authorNoteEyebrow: 'Un mot de l\'auteur',
    authorNoteTitle: 'Pourquoi ce projet existe',
    authorNoteBody: [
      'Pour être honnête, je n\'aime pas la hype actuelle autour de l\'IA — les discussions sans fin, le marketing sans fin. Mais que ça me plaise ou non, cette vague n\'est pas près de retomber.',
      'Alors si on doit embrasser l\'AI coding, autant aller jusqu\'au bout plutôt que de faire les choses à moitié. Ironiquement, c\'est exactement pour ça que ce projet existe. Le but n\'a jamais été de courir après la tendance — c\'était de pousser l\'idée jusqu\'à sa conclusion logique et de poser la question : si l\'IA est vraiment l\'avenir du développement, à quoi ressemblerait un workflow véritablement AI-first ?',
      'Ce projet, c\'est ma réponse à ce jour.',
    ],
    trustTitle: 'Frontière de confiance',
    trustPoints: [
      ['JSON déclaratif', 'L\'IA ne livre aucun code natif ni binaire'],
      ['Backend auto-hébergeable', 'myapp-ctl deploy démarre les services principaux'],
      ['Runtime multi-clients', 'Flutter Web, iOS et Android partagent une seule couche de capacités'],
    ],
    docsTitle: 'Points d\'entrée pour développeurs',
    docsLinks: [
      ['Documentation de déploiement', 'Déployez le backend avec myapp-ctl, puis changez l\'environnement du client'],
      ['Schéma d\'architecture', 'Runtime, AI Worker et Registry en une seule vue'],
      ['Frontière d\'exécution', 'Comment fonctionnent l\'ensemble de capacités précompilé et la frontière adaptée à la revue'],
    ],
    videosTitle: 'Exemples d\'applications générées',
    videosSubtitle: 'Trois formes d\'application différentes montrent des outils, des jeux et des écrans communautaires plutôt qu\'une seule coquille répétée.',
    deployTitle: 'Configuration du backend privé et du client',
    deployHint: 'Le déploiement privé concerne surtout le backend. Le client peut utiliser la Web app hébergée, ou vous pouvez compiler vous-même iOS / Android / Web et changer d\'environnement dans le client.',
    backendDeployTitle: '1. Déployer l\'environnement de test du backend',
    clientBuildTitle: '2. Compiler les clients',
    switchEnvTitle: '3. Changer l\'environnement du client',
    switchEnvBody: 'Ouvrez Environnement de service dans le client, puis collez ou scannez le JSON d\'environnement du backend. Enregistrez et reconnectez-vous pour vous connecter à votre backend.',
    usageTitle: '4. Comment l\'utiliser',
    usageBody: 'Après vous être connecté avec le compte de test, installez des JSON Apps depuis la bibliothèque d\'applications ou utilisez l\'entrée IA flottante pour décrire une application et itérer par le chat.',
    howTitle: 'De l\'idée à l\'application',
    howSubtitle: 'Le flux complet est le déploiement du backend avec myapp-ctl, la compilation/ouverture du client, le changement d\'environnement, puis l\'installation ou la génération d\'applications.',
    steps: [
      ['Préparer l\'environnement', 'Utilisez myapp-ctl pour déployer les services et gérer les secrets du backend.'],
      ['Connecter le client', 'Web / iOS / Android se connectent tous via la page de changement d\'environnement.'],
      ['Générer ou installer des applications', 'Installez des JSON Apps depuis la bibliothèque ou demandez à l\'IA d\'en générer de nouvelles.'],
    ],
    featuresTitle: 'Capacités de la plateforme',
    featuresSubtitle: 'Conçue autour de la génération full-stack par IA, du rendu à l\'exécution, des jeux, d\'une bibliothèque d\'applications et de l\'auto-hébergement.',
    stackTitle: 'Un runtime, quatre chemins critiques',
    stackSubtitle: 'Le client n\'interprète que les capacités JSON approuvées. Le backend gère la génération IA sur des agent nodes isolés, les backends FaaS générés par IA, la distribution de paquets, l\'IM, la configuration et les tâches reprenables.',
    stackItems: [
      ['Flutter Runtime', 'Widgets précompilés, JsonLogic, atomes de jeu Flame, compatibilité IM et capacités multimédias.'],
      ['File AI Worker', 'File Redis, exécution agent-node isolée en mode pull, SSE reprenable, limites de concurrence et résultats durables.'],
      ['Backends FaaS IA', 'Backends Python/Flask générés par IA : bundles validés, un worker git push isolé, un runtime FaaS conteneurisé autogéré (un conteneur par service, sans limite de nombre de fonctions, mise à zéro automatique et réveil à froid), un proxy d\'invocation contrôlé par routage, et un modèle de permissions au niveau application — base de données isolée par application, identité pseudonyme de confiance, une couche de données par appelant médiée par le backend (les fonctions ne détiennent aucune connexion DB), durcissement des conteneurs et politiques d\'accès révocables.'],
      ['Registry + Assets', 'Recherche paginée, semver, dépendances de composants, miroir inter-instances et livraison d\'assets OSS/MinIO.'],
    ],
    complianceTitle: 'Frontière adaptée à la revue',
    complianceBody: 'L\'IA produit du JSON déclaratif pour le client : il ne compose que des widgets et des actions compilés, jamais de Dart, Swift, Kotlin, plugins ou binaires. Lorsqu\'une application a besoin d\'un backend, les services FaaS générés s\'exécutent côté serveur dans un runtime FaaS conteneurisé autogéré et isolé, donc aucun code exécutable n\'est livré au client.',
    features: [
      ['Génération full-stack (le facteur différenciant)', 'Les autres générateurs IA vous donnent une base de code web à héberger et à maintenir. MyApp génère l\'application JSON et un backend Python/Flask validé assorti à partir d\'un seul prompt, déployé sur un runtime FaaS conteneurisé autogéré et isolé (sans limite de nombre de fonctions, mise à zéro automatique, réveil à froid et autoscaling), et l\'exécute instantanément. Chaque application reçoit aussi une base de données Postgres isolée et un modèle de permissions au niveau application (owner / maintainer / consumer) — les données du consommateur sont isolées par appelant par la plateforme, et le code des fonctions ne détient jamais de connexion à la base de données.'],
      ['DSL natif pour l\'IA', 'Structuré pour la génération par LLM et rendu en véritable UI native, pas seulement une config écrite à la main.'],
      ['Jeux Flame', 'Un vrai moteur de jeu 2D — sprites, physique et cartes tuilées — fonctionnant sur Web, iOS et Android, pas juste des jouets.'],
      ['IM intégrée', 'Amis, groupes, synchronisation et la couche de compatibilité OpenIM pour le Web.'],
      ['Bibliothèque d\'applications', 'Registry avec espaces de noms, semver, résolution de dépendances et miroir inter-instances.'],
      ['Frontière de capacités', 'L\'UI et le comportement sont livrés sous forme de données dans un ensemble de capacités précompilé ; les capacités sensibles comme le jeton d\'authentification nécessitent une autorisation par application.'],
      ['Auto-hébergeable', 'myapp-ctl déploie tout le backend, le runtime des agents et le registry ; un seul DSL s\'affiche sur les builds iOS, Android, Web et desktop.'],
    ],
    downloadTitle: 'Commencez à utiliser MyApp',
    downloadBody: 'Ouvrez la Web app maintenant. iOS est disponible via TestFlight Public Group 1 avec 2 500 places. Le téléchargement de l\'APK Android est disponible pendant que Google Play est en préparation.',
    openWeb: 'Ouvrir la Web app',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: 'Disponible',
    soon: 'Bientôt disponible',
  },
  pt: {
    navHow: 'Implementar',
    navStack: 'Stack',
    navTry: 'Visita',
    navFeatures: 'Capacidades',
    navDownload: 'Descarregar',
    badge: 'Uma vibe app, não uma codebase · Web · iOS · Android · Desktop',
    titleA: 'Chega de vibe-coding.',
    titleB: 'Lance vibe-apps.',
    subtitle:
      'O vibe coding — mesmo os melhores construtores de apps de IA — continua a entregar-te uma web codebase para alojar e manter. Uma vibe app está simplesmente viva — nativa no teu telemóvel em segundos: descreve o que queres e a IA gera toda a stack — UI + um backend Python/Flask real + a sua própria base de dados Postgres — a correr de imediato dentro de um runtime pré-compilado e multiplataforma. A mesma frase pode criar um jogo jogável ou um fórum com um backend real. Sem codebase. Sem build. Sem deploy. Sem app store.',
    primaryCta: 'Abrir a Web app',
    secondaryCta: 'Aderir ao TestFlight',
    phoneCaption: 'Uma app real a correr, não uma codebase que tens de alojar. Abre-a na Web agora, em qualquer ecrã.',
    heroConsoleTitle: 'Uma frase → uma app a correr',
    heroConsoleLines: [
      '$ describe "um fórum com login, publicações e respostas encadeadas"',
      '→ a IA escreve a UI + um backend real + base de dados',
      '→ sem build · sem deploy · sem app store',
      '→ a correr em Web · iOS · Android · desktop',
    ],
    proofPoints: ['Sem codebase · sem build · sem deploy', 'Full-stack: UI + backend + base de dados', 'Um prompt → iOS · Android · Web · desktop'],
    authorNoteEyebrow: 'Do autor',
    authorNoteTitle: 'Porque é que isto existe',
    authorNoteBody: [
      'Para ser honesto, não gosto do hype atual à volta da IA — a discussão interminável, o marketing interminável. Mas, quer eu goste quer não, esta onda não vai desaparecer.',
      'Por isso, já que vamos abraçar o AI coding, mais vale ir até ao fim em vez de ficar a meio caminho. Ironicamente, é exatamente por isso que este projeto existe. O objetivo nunca foi correr atrás da moda — foi levar a ideia até à sua conclusão lógica e perguntar: se a IA é mesmo o futuro do desenvolvimento, como seria um workflow verdadeiramente AI-first?',
      'Este projeto é a minha resposta até agora.',
    ],
    trustTitle: 'Fronteira de confiança',
    trustPoints: [
      ['JSON declarativo', 'A IA não distribui código nativo nem binários'],
      ['Backend auto-alojável', 'myapp-ctl deploy inicia os serviços principais'],
      ['Runtime multicliente', 'Flutter Web, iOS e Android partilham uma única camada de capacidades'],
    ],
    docsTitle: 'Pontos de entrada para programadores',
    docsLinks: [
      ['Documentação de implementação', 'Implemente o backend com myapp-ctl e depois mude o ambiente do cliente'],
      ['Diagrama de arquitetura', 'Runtime, AI Worker e Registry numa só vista'],
      ['Fronteira de execução', 'Como funcionam o conjunto de capacidades pré-compilado e a fronteira amigável à revisão'],
    ],
    videosTitle: 'Exemplos de aplicações geradas',
    videosSubtitle: 'Três formatos de aplicação diferentes mostram ferramentas, jogos e ecrãs de comunidade em vez de uma única estrutura repetida.',
    deployTitle: 'Configuração do backend privado e do cliente',
    deployHint: 'A implementação privada diz respeito sobretudo ao backend. O cliente pode usar a Web app alojada, ou pode compilar você mesmo iOS / Android / Web e mudar de ambiente no cliente.',
    backendDeployTitle: '1. Implementar o ambiente de teste do backend',
    clientBuildTitle: '2. Compilar os clientes',
    switchEnvTitle: '3. Mudar o ambiente do cliente',
    switchEnvBody: 'Abra Ambiente de Serviço no cliente, depois cole ou leia o JSON de ambiente do backend. Guarde e inicie sessão novamente para ligar ao seu backend.',
    usageTitle: '4. Como utilizar',
    usageBody: 'Depois de iniciar sessão com a conta de teste, instale JSON Apps a partir da biblioteca de aplicações ou use a entrada de IA flutuante para descrever uma aplicação e iterar através do chat.',
    howTitle: 'Da ideia à aplicação',
    howSubtitle: 'O fluxo completo é a implementação do backend com myapp-ctl, a compilação/abertura do cliente, a mudança de ambiente e depois a instalação ou geração de aplicações.',
    steps: [
      ['Preparar o ambiente', 'Use o myapp-ctl para implementar serviços e gerir os segredos do backend.'],
      ['Ligar o cliente', 'Web / iOS / Android ligam-se todos através da página de mudança de ambiente.'],
      ['Gerar ou instalar aplicações', 'Instale JSON Apps a partir da biblioteca ou peça à IA para gerar novas.'],
    ],
    featuresTitle: 'Capacidades da plataforma',
    featuresSubtitle: 'Construída em torno da geração full-stack por IA, do render em tempo de execução, dos jogos, de uma biblioteca de aplicações e do auto-alojamento.',
    stackTitle: 'Um runtime, quatro caminhos críticos',
    stackSubtitle: 'O cliente interpreta apenas as capacidades JSON aprovadas. O backend trata da geração por IA em agent nodes isolados, dos backends FaaS gerados por IA, da distribuição de pacotes, do IM, da configuração e das tarefas retomáveis.',
    stackItems: [
      ['Flutter Runtime', 'Widgets pré-compilados, JsonLogic, átomos de jogo Flame, compatibilidade de IM e capacidades multimédia.'],
      ['Fila AI Worker', 'Fila Redis, execução agent-node isolada baseada em pull, SSE retomável, limites de concorrência e resultados duráveis.'],
      ['Backends FaaS de IA', 'Backends Python/Flask gerados por IA: bundles validados, um worker git push isolado, um runtime FaaS conteinerizado autogerido (um contentor por serviço, sem limite do número de funções, redução a zero automática e despertar a frio), um proxy de invocação reforçado por rotas e um modelo de permissões ao nível da aplicação — base de dados isolada por aplicação, identidade pseudónima de confiança, uma camada de dados por chamador mediada pelo backend (as funções não detêm ligação à base de dados), reforço dos contentores e políticas de acesso revogáveis.'],
      ['Registry + Assets', 'Pesquisa paginada, semver, dependências de componentes, espelho entre instâncias e entrega de assets OSS/MinIO.'],
    ],
    complianceTitle: 'Fronteira amigável à revisão',
    complianceBody: 'A IA produz JSON declarativo para o cliente: compõe apenas widgets e ações compilados, nunca Dart, Swift, Kotlin, plugins ou binários. Quando uma aplicação precisa de um backend, os serviços FaaS gerados executam-se do lado do servidor num runtime FaaS conteinerizado autogerido e isolado, pelo que nenhum código executável é entregue ao cliente.',
    features: [
      ['Geração full-stack (o fator diferenciador)', 'Outros geradores de IA dão-lhe uma base de código web para alojar e manter por conta própria. A MyApp gera a aplicação JSON e um backend Python/Flask validado correspondente a partir de um único prompt, implementado num runtime FaaS conteinerizado autogerido e isolado (sem limite do número de funções, redução a zero automática, despertar a frio e autoscaling), e executa-o instantaneamente. Cada aplicação recebe também uma base de dados Postgres isolada e um modelo de permissões ao nível da aplicação (owner / maintainer / consumer) — os dados do consumidor são isolados por chamador pela plataforma, e o código das funções nunca detém uma ligação à base de dados.'],
      ['DSL nativo de IA', 'Estruturado para geração por LLM e renderizado em UI nativa real, não apenas configuração escrita à mão.'],
      ['Jogos Flame', 'Um verdadeiro motor de jogos 2D — sprites, física e mapas em mosaico — a correr em Web, iOS e Android, não apenas brinquedos.'],
      ['IM integrado', 'Amigos, grupos, sincronização e a camada de compatibilidade OpenIM para a Web.'],
      ['Biblioteca de aplicações', 'Registry com espaços de nomes, semver, resolução de dependências e espelho entre instâncias.'],
      ['Fronteira de capacidades', 'A UI e o comportamento são entregues como dados dentro de um conjunto de capacidades pré-compilado; capacidades sensíveis como o token de autenticação requerem autorização por aplicação.'],
      ['Auto-alojável', 'O myapp-ctl implementa todo o backend, o runtime de agentes e o registry; um só DSL renderiza em builds iOS, Android, Web e desktop.'],
    ],
    downloadTitle: 'Comece a usar a MyApp',
    downloadBody: 'Abra a Web app agora. O iOS está disponível através do TestFlight Public Group 1 com 2.500 lugares. A descarga do APK Android está disponível enquanto o Google Play é preparado.',
    openWeb: 'Abrir a Web app',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: 'Disponível',
    soon: 'Brevemente',
  },
  ca: {
    navHow: 'Desplegar',
    navStack: 'Stack',
    navTry: 'Visita',
    navFeatures: 'Capacitats',
    navDownload: 'Descarregar',
    badge: 'Una vibe app, no una base de codi · Web · iOS · Android · Desktop',
    titleA: 'Prou de vibe-coding.',
    titleB: 'Llança vibe-apps.',
    subtitle:
      'El vibe coding — fins i tot els millors constructors d\'apps amb IA — encara et lliura una base de codi web per allotjar i mantenir. Una vibe app simplement està viva — nativa al teu telèfon en segons: descriu el que vols i la IA genera tota la stack — UI + un backend real de Python/Flask + la seva pròpia base de dades Postgres — en marxa a l\'instant dins d\'un runtime multiplataforma precompilat. La mateixa frase pot engegar un joc jugable o un fòrum amb backend real. Sense base de codi. Sense compilació. Sense desplegament. Sense app store.',
    primaryCta: 'Obre la Web app',
    secondaryCta: 'Uneix-te a TestFlight',
    phoneCaption: 'Una app real en funcionament, no una base de codi que has d\'allotjar. Obre-la al Web ara, a qualsevol pantalla.',
    heroConsoleTitle: 'Una frase → una app en marxa',
    heroConsoleLines: [
      '$ describe "un fòrum amb inici de sessió, publicacions i respostes en fil"',
      '→ la IA escriu la UI + un backend real + base de dades',
      '→ sense compilació · sense desplegament · sense app store',
      '→ en marxa a Web · iOS · Android · escriptori',
    ],
    proofPoints: ['Sense base de codi · sense compilació · sense desplegament', 'Full-stack: UI + backend + base de dades', 'Un prompt → iOS · Android · Web · escriptori'],
    authorNoteEyebrow: 'De l\'autor',
    authorNoteTitle: 'Per què existeix això',
    authorNoteBody: [
      'Si he de ser sincer, no m\'agrada gens el hype actual al voltant de la IA — la discussió interminable, el màrqueting interminable. Però, m\'agradi o no, aquesta onada no desapareixerà.',
      'Així que, si hem d\'abraçar l\'AI coding, més val anar fins al final que quedar-se a mitges. Irònicament, és exactament per això que existeix aquest projecte. L\'objectiu mai no ha estat perseguir la moda — era portar la idea fins a la seva conclusió lògica i preguntar: si la IA és realment el futur del desenvolupament, com seria un flux de treball genuïnament AI-first?',
      'Aquest projecte és la meva resposta fins ara.',
    ],
    trustTitle: 'Frontera de confiança',
    trustPoints: [
      ['JSON declaratiu', 'La IA no distribueix codi natiu ni binaris'],
      ['Backend autoallotjable', 'myapp-ctl deploy engega els serveis principals'],
      ['Runtime multiclient', 'Flutter Web, iOS i Android comparteixen una sola capa de capacitats'],
    ],
    docsTitle: 'Punts d\'entrada per a desenvolupadors',
    docsLinks: [
      ['Documentació de desplegament', 'Desplega el backend amb myapp-ctl i després canvia l\'entorn del client'],
      ['Diagrama d\'arquitectura', 'Runtime, AI Worker i Registry en una sola vista'],
      ['Frontera d\'execució', 'Com funcionen el conjunt de capacitats precompilat i la frontera amigable per a la revisió'],
    ],
    videosTitle: 'Exemples d\'aplicacions generades',
    videosSubtitle: 'Tres formats d\'aplicació diferents mostren eines, jocs i pantalles de comunitat en lloc d\'una sola closca repetida.',
    deployTitle: 'Configuració del backend privat i del client',
    deployHint: 'El desplegament privat es refereix sobretot al backend. El client pot usar la Web app allotjada, o pots compilar tu mateix iOS / Android / Web i canviar d\'entorn al client.',
    backendDeployTitle: '1. Desplegar l\'entorn de proves del backend',
    clientBuildTitle: '2. Compilar els clients',
    switchEnvTitle: '3. Canviar l\'entorn del client',
    switchEnvBody: 'Obre Entorn de Servei al client, després enganxa o escaneja el JSON d\'entorn del backend. Desa i torna a iniciar sessió per connectar-te al teu backend.',
    usageTitle: '4. Com utilitzar-lo',
    usageBody: 'Després d\'iniciar sessió amb el compte de prova, instal·la JSON Apps des de la biblioteca d\'aplicacions o usa l\'entrada d\'IA flotant per descriure una aplicació i iterar mitjançant el xat.',
    howTitle: 'De la idea a l\'aplicació',
    howSubtitle: 'El flux complet és el desplegament del backend amb myapp-ctl, la compilació/obertura del client, el canvi d\'entorn i després la instal·lació o generació d\'aplicacions.',
    steps: [
      ['Preparar l\'entorn', 'Usa myapp-ctl per desplegar serveis i gestionar els secrets del backend.'],
      ['Connectar el client', 'Web / iOS / Android es connecten tots a través de la pàgina de canvi d\'entorn.'],
      ['Generar o instal·lar aplicacions', 'Instal·la JSON Apps des de la biblioteca o demana a la IA que en generi de noves.'],
    ],
    featuresTitle: 'Capacitats de la plataforma',
    featuresSubtitle: 'Construïda al voltant de la generació full-stack per IA, del render en temps d\'execució, dels jocs, d\'una biblioteca d\'aplicacions i de l\'autoallotjament.',
    stackTitle: 'Un runtime, quatre camins crítics',
    stackSubtitle: 'El client només interpreta les capacitats JSON aprovades. El backend gestiona la generació per IA en agent nodes aïllats, els backends FaaS generats per IA, la distribució de paquets, l\'IM, la configuració i les tasques reprenibles.',
    stackItems: [
      ['Flutter Runtime', 'Widgets precompilats, JsonLogic, àtoms de joc Flame, compatibilitat d\'IM i capacitats multimèdia.'],
      ['Cua AI Worker', 'Cua Redis, execució agent-node aïllada basada en pull, SSE reprenible, límits de concurrència i resultats duradors.'],
      ['Backends FaaS d\'IA', 'Backends Python/Flask generats per IA: bundles validats, un worker git push aïllat, un runtime FaaS contenidoritzat autogestionat (un contenidor per servei, sense límit del nombre de funcions, reducció a zero automàtica i despertar en fred), un proxy d\'invocació reforçat per rutes i un model de permisos a nivell d\'aplicació — base de dades aïllada per aplicació, identitat pseudònima de confiança, una capa de dades per cridador mediada pel backend (les funcions no tenen connexió a la base de dades), enduriment dels contenidors i polítiques d\'accés revocables.'],
      ['Registry + Assets', 'Cerca paginada, semver, dependències de components, mirall entre instàncies i lliurament d\'assets OSS/MinIO.'],
    ],
    complianceTitle: 'Frontera amigable per a la revisió',
    complianceBody: 'La IA produeix JSON declaratiu per al client: només composa widgets i accions compilats, mai Dart, Swift, Kotlin, plugins o binaris. Quan una aplicació necessita un backend, els serveis FaaS generats s\'executen al costat del servidor en un runtime FaaS contenidoritzat autogestionat i aïllat, de manera que cap codi executable no s\'entrega al client.',
    features: [
      ['Generació full-stack (el factor diferenciador)', 'Altres generadors d\'IA et donen una base de codi web que has d\'allotjar i mantenir. MyApp genera l\'aplicació JSON i un backend Python/Flask validat corresponent a partir d\'un sol prompt, desplegat en un runtime FaaS contenidoritzat autogestionat i aïllat (sense límit del nombre de funcions, reducció a zero automàtica, despertar en fred i autoscaling), i l\'executa a l\'instant. Cada aplicació també rep una base de dades Postgres aïllada i un model de permisos a nivell d\'aplicació (owner / maintainer / consumer) — les dades del consumidor estan aïllades per cridador per la plataforma, i el codi de les funcions mai no té una connexió a la base de dades.'],
      ['DSL natiu d\'IA', 'Estructurat per a la generació per LLM i renderitzat en UI nativa real, no només configuració escrita a mà.'],
      ['Jocs Flame', 'Un veritable motor de jocs 2D — sprites, física i mapes de mosaic — funcionant a Web, iOS i Android, no només joguines.'],
      ['IM integrat', 'Amics, grups, sincronització i la capa de compatibilitat OpenIM per al Web.'],
      ['Biblioteca d\'aplicacions', 'Registry amb espais de noms, semver, resolució de dependències i mirall entre instàncies.'],
      ['Frontera de capacitats', 'La UI i el comportament s\'entreguen com a dades dins d\'un conjunt de capacitats precompilat; les capacitats sensibles com el token d\'autenticació requereixen autorització per aplicació.'],
      ['Autoallotjable', 'myapp-ctl desplega tot el backend, el runtime d\'agents i el registry; un sol DSL es renderitza en builds iOS, Android, Web i desktop.'],
    ],
    downloadTitle: 'Comença a usar MyApp',
    downloadBody: 'Obre la Web app ara. iOS està disponible a través de TestFlight Public Group 1 amb 2.500 places. La descàrrega de l\'APK d\'Android està disponible mentre es prepara Google Play.',
    openWeb: 'Obre la Web app',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: 'Disponible',
    soon: 'Aviat',
  },
  hi: {
    navHow: 'डिप्लॉय करें',
    navStack: 'स्टैक',
    navTry: 'टूर',
    navFeatures: 'क्षमताएँ',
    navDownload: 'डाउनलोड',
    badge: 'एक vibe app, कोई codebase नहीं · Web · iOS · Android · डेस्कटॉप',
    titleA: 'vibe-coding बंद करें।',
    titleB: 'vibe-apps शिप करें।',
    subtitle:
      'Vibe coding — बेहतरीन AI ऐप बिल्डर तक — आपको फिर भी एक web codebase थमाता है जिसे host और maintain करना पड़ता है। एक vibe app बस लाइव होता है — सेकंडों में आपके फ़ोन पर नेटिव: आप जो चाहते हैं उसे बताइए, और AI पूरा स्टैक बना देता है — UI + एक असली Python/Flask बैकएंड + अपना खुद का Postgres डेटाबेस — जो एक पूर्व-संकलित, क्रॉस-प्लेटफ़ॉर्म रनटाइम में तुरंत चलता है। वही एक वाक्य एक खेलने योग्य गेम या असली बैकएंड वाला एक फ़ोरम खड़ा कर सकता है। न codebase। न build। न deploy। न ऐप स्टोर।',
    primaryCta: 'Web ऐप खोलें',
    secondaryCta: 'TestFlight से जुड़ें',
    phoneCaption: 'एक असली, चलता हुआ ऐप — कोई codebase नहीं जिसे आपको होस्ट करना पड़े। अभी Web पर खोलिए, किसी भी स्क्रीन पर।',
    heroConsoleTitle: 'एक वाक्य → एक लाइव ऐप',
    heroConsoleLines: [
      '$ describe "लॉगिन, पोस्ट और थ्रेडेड रिप्लाई वाला एक फ़ोरम"',
      '→ AI बनाता है UI + असली बैकएंड + डेटाबेस',
      '→ न build · न deploy · न ऐप स्टोर',
      '→ Web · iOS · Android · डेस्कटॉप पर लाइव',
    ],
    proofPoints: ['कोई codebase नहीं · न build · न deploy', 'फुल-स्टैक: UI + बैकएंड + डेटाबेस', 'एक प्रॉम्प्ट → iOS · Android · Web · डेस्कटॉप'],
    authorNoteEyebrow: 'लेखक की ओर से',
    authorNoteTitle: 'यह प्रोजेक्ट क्यों मौजूद है',
    authorNoteBody: [
      'सच कहूँ तो, मुझे आज की AI हाइप से चिढ़ है — न ख़त्म होने वाली बहसें, न ख़त्म होने वाली मार्केटिंग। लेकिन मुझे पसंद हो या न हो, यह लहर थमने वाली नहीं है।',
      'तो जब AI coding को अपनाना ही है, तो आधा-अधूरा करने के बजाय बात को आख़िर तक ले जाया जाए। विडंबना यह है कि ठीक यही इस प्रोजेक्ट के होने की वजह है। मक़सद कभी ट्रेंड के पीछे भागना नहीं था — मक़सद था इस विचार को उसके तार्किक अंजाम तक ले जाना और यह पूछना: अगर AI सचमुच डेवलपमेंट का भविष्य है, तो एक सच्चा AI-first वर्कफ़्लो कैसा दिखेगा?',
      'यह प्रोजेक्ट, अब तक का मेरा जवाब है।',
    ],
    trustTitle: 'विश्वास सीमा',
    trustPoints: [
      ['घोषणात्मक JSON', 'AI कोई नेटिव कोड या बाइनरी नहीं भेजता'],
      ['स्व-होस्ट करने योग्य बैकएंड', 'myapp-ctl deploy मुख्य सेवाएँ शुरू करता है'],
      ['क्रॉस-क्लाइंट रनटाइम', 'Flutter Web, iOS और Android एक ही क्षमता परत साझा करते हैं'],
    ],
    docsTitle: 'डेवलपर प्रवेश बिंदु',
    docsLinks: [
      ['डिप्लॉयमेंट दस्तावेज़', 'myapp-ctl से बैकएंड डिप्लॉय करें, फिर क्लाइंट वातावरण बदलें'],
      ['आर्किटेक्चर आरेख', 'रनटाइम, AI Worker और Registry एक ही दृश्य में'],
      ['रनटाइम सीमा', 'प्रीकंपाइल्ड क्षमता सेट और समीक्षा-अनुकूल सीमा कैसे काम करती है'],
    ],
    videosTitle: 'जनित ऐप उदाहरण',
    videosSubtitle: 'तीन अलग-अलग ऐप रूप एक ही दोहराए गए खोल के बजाय टूल, गेम और समुदाय स्क्रीन दिखाते हैं।',
    deployTitle: 'निजी बैकएंड और क्लाइंट सेटअप',
    deployHint: 'निजी डिप्लॉयमेंट मुख्यतः बैकएंड को संदर्भित करता है। क्लाइंट होस्ट की गई Web ऐप का उपयोग कर सकता है, या आप स्वयं iOS / Android / Web बना सकते हैं और क्लाइंट में वातावरण बदल सकते हैं।',
    backendDeployTitle: '1. बैकएंड परीक्षण वातावरण डिप्लॉय करें',
    clientBuildTitle: '2. क्लाइंट बनाएँ',
    switchEnvTitle: '3. क्लाइंट वातावरण बदलें',
    switchEnvBody: 'क्लाइंट में सेवा वातावरण खोलें, फिर बैकएंड वातावरण JSON पेस्ट करें या स्कैन करें। सहेजें और अपने बैकएंड से जुड़ने के लिए फिर से साइन इन करें।',
    usageTitle: '4. इसका उपयोग कैसे करें',
    usageBody: 'परीक्षण खाते से साइन इन करने के बाद, ऐप लाइब्रेरी से JSON Apps इंस्टॉल करें या किसी ऐप का वर्णन करने और चैट के माध्यम से पुनरावृत्ति करने के लिए फ्लोटिंग AI प्रवेश का उपयोग करें।',
    howTitle: 'विचार से ऐप तक',
    howSubtitle: 'पूरा प्रवाह है myapp-ctl बैकएंड डिप्लॉयमेंट, क्लाइंट बिल्ड/खोलना, वातावरण बदलना, फिर ऐप इंस्टॉल या जनित करना।',
    steps: [
      ['वातावरण तैयार करें', 'सेवाएँ डिप्लॉय करने और बैकएंड सीक्रेट प्रबंधित करने के लिए myapp-ctl का उपयोग करें।'],
      ['क्लाइंट जोड़ें', 'Web / iOS / Android सभी वातावरण बदलने वाले पृष्ठ के माध्यम से जुड़ते हैं।'],
      ['ऐप जनित या इंस्टॉल करें', 'ऐप लाइब्रेरी से JSON Apps इंस्टॉल करें या AI से नए जनित करने को कहें।'],
    ],
    featuresTitle: 'प्लेटफ़ॉर्म क्षमताएँ',
    featuresSubtitle: 'AI फुल-स्टैक जनरेशन, रनटाइम रेंडरिंग, गेम, ऐप लाइब्रेरी और स्व-होस्टिंग के इर्द-गिर्द निर्मित।',
    stackTitle: 'एक रनटाइम, चार महत्वपूर्ण पथ',
    stackSubtitle: 'क्लाइंट केवल अनुमोदित JSON क्षमताओं की व्याख्या करता है। बैकएंड पृथक agent nodes पर AI जनरेशन, AI-जनित FaaS बैकएंड, पैकेज वितरण, IM, कॉन्फ़िग और पुनः आरंभ योग्य कार्यों को संभालता है।',
    stackItems: [
      ['Flutter Runtime', 'प्रीकंपाइल्ड विजेट, JsonLogic, Flame गेम परमाणु, IM संगतता और मीडिया क्षमताएँ।'],
      ['AI Worker कतार', 'Redis कतार, पृथक pull-आधारित agent-node निष्पादन, पुनः आरंभ योग्य SSE, समवर्ती सीमाएँ और टिकाऊ परिणाम।'],
      ['AI FaaS बैकएंड', 'AI-जनित Python/Flask बैकएंड: सत्यापित बंडल, एक पृथक git push वर्कर, एक स्व-प्रबंधित कंटेनरीकृत FaaS रनटाइम (प्रति सेवा एक कंटेनर, फ़ंक्शन-संख्या की कोई सीमा नहीं, स्वचालित scale-to-zero और cold-wake), एक रूट-प्रवर्तित invoke प्रॉक्सी, और एक एप्लिकेशन-स्तरीय अनुमति मॉडल — प्रति-ऐप पृथक डेटाबेस, विश्वसनीय छद्मनाम पहचान, बैकएंड-मध्यस्थ प्रति-कॉलर डेटा परत (फ़ंक्शन कोई DB कनेक्शन नहीं रखते), कंटेनर सुदृढ़ीकरण और रद्द करने योग्य पहुँच नीतियाँ।'],
      ['Registry + Assets', 'पृष्ठांकित खोज, semver, घटक निर्भरताएँ, क्रॉस-इंस्टेंस मिरर और OSS/MinIO एसेट वितरण।'],
    ],
    complianceTitle: 'समीक्षा-अनुकूल सीमा',
    complianceBody: 'AI क्लाइंट के लिए घोषणात्मक JSON बनाता है: यह केवल संकलित विजेट और क्रियाएँ संयोजित करता है, कभी Dart, Swift, Kotlin, प्लगइन या बाइनरी नहीं। जब किसी ऐप को बैकएंड की आवश्यकता होती है, तो जनित FaaS सेवाएँ एक पृथक स्व-प्रबंधित कंटेनरीकृत FaaS रनटाइम में सर्वर-साइड चलती हैं, इसलिए कोई निष्पादन योग्य कोड क्लाइंट को नहीं भेजा जाता।',
    features: [
      ['फुल-स्टैक जनरेशन (विभेदक)', 'अन्य AI बिल्डर आपको एक वेब कोडबेस देते हैं जिसे आपको खुद होस्ट और मेंटेन करना पड़ता है। MyApp एक ही प्रॉम्प्ट से JSON ऐप और उससे मेल खाता सत्यापित Python/Flask बैकएंड जनित करता है, जो एक पृथक स्व-प्रबंधित कंटेनरीकृत FaaS रनटाइम (फ़ंक्शन-संख्या की कोई सीमा नहीं, स्वचालित scale-to-zero, cold-wake और autoscaling) पर डिप्लॉय होता है, और इसे तुरंत चलाता है। प्रत्येक ऐप को एक पृथक Postgres डेटाबेस और एक एप्लिकेशन-स्तरीय अनुमति मॉडल (owner / maintainer / consumer) भी मिलता है — उपभोक्ता डेटा प्लेटफ़ॉर्म द्वारा प्रति-कॉलर पृथक रहता है, और फ़ंक्शन कोड कभी डेटाबेस कनेक्शन नहीं रखता।'],
      ['AI-नेटिव DSL', 'LLM जनरेशन के लिए संरचित और वास्तविक नेटिव UI में रेंडर किया गया, केवल हाथ से लिखी कॉन्फ़िग नहीं।'],
      ['Flame गेम', 'एक वास्तविक 2D गेम इंजन — स्प्राइट, भौतिकी और टाइल्ड मानचित्र — Web, iOS और Android पर चलता है, केवल खिलौने नहीं।'],
      ['अंतर्निहित IM', 'मित्र, समूह, सिंक और Web के लिए OpenIM संगतता परत।'],
      ['ऐप लाइब्रेरी', 'नेमस्पेस वाला registry जिसमें semver, निर्भरता समाधान और क्रॉस-इंस्टेंस मिररिंग है।'],
      ['क्षमता सीमा', 'UI और व्यवहार एक प्रीकंपाइल्ड क्षमता सेट के भीतर डेटा के रूप में भेजे जाते हैं; प्रमाणन टोकन जैसी संवेदनशील क्षमताओं के लिए प्रति-ऐप प्राधिकरण आवश्यक है।'],
      ['स्व-होस्ट करने योग्य', 'myapp-ctl पूरे बैकएंड, agent रनटाइम और registry को डिप्लॉय करता है; एक ही DSL iOS, Android, Web और डेस्कटॉप बिल्ड पर रेंडर होता है।'],
    ],
    downloadTitle: 'MyApp का उपयोग शुरू करें',
    downloadBody: 'अभी Web ऐप खोलें। iOS, TestFlight Public Group 1 के माध्यम से 2,500 सीटों के साथ उपलब्ध है। Google Play तैयार किया जा रहा है, तब तक Android APK डाउनलोड उपलब्ध है।',
    openWeb: 'Web ऐप खोलें',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: 'उपलब्ध',
    soon: 'जल्द आ रहा है',
  },
  ko: {
    navHow: '배포',
    navStack: '스택',
    navTry: '둘러보기',
    navFeatures: '기능',
    navDownload: '다운로드',
    badge: 'codebase가 아니라 vibe app · Web · iOS · Android · 데스크톱',
    titleA: 'Vibe coding은 그만.',
    titleB: 'Vibe app을 출시하세요.',
    subtitle:
      'Vibe coding은 — 최고의 AI 앱 빌더조차도 — 여전히 호스팅하고 유지보수해야 하는 웹 코드베이스를 건네줍니다. Vibe app은 그냥 살아 있습니다 — 몇 초 만에 폰에서 네이티브로: 원하는 것을 설명하면 AI가 전체 스택을 생성합니다 — UI + 실제 Python/Flask 백엔드 + 자체 Postgres 데이터베이스 — 사전 컴파일된 크로스플랫폼 런타임 안에서 즉시 실행됩니다. 똑같은 한 문장이 플레이 가능한 게임이나 실제 백엔드를 갖춘 포럼을 띄울 수 있습니다. 코드베이스 없음. 빌드 없음. 배포 없음. 앱스토어 없음.',
    primaryCta: 'Web 앱 열기',
    secondaryCta: 'TestFlight 참여',
    phoneCaption: '직접 호스팅할 코드베이스가 아니라, 실제로 실행 중인 앱. 지금 어떤 화면에서든 Web에서 바로 열어보세요.',
    heroConsoleTitle: '한 문장 → 실행 중인 앱',
    heroConsoleLines: [
      '$ describe "로그인, 게시글, 스레드형 답글이 있는 포럼"',
      '→ AI가 UI + 실제 백엔드 + 데이터베이스를 작성',
      '→ 빌드 없음 · 배포 없음 · 앱스토어 없음',
      '→ Web · iOS · Android · 데스크톱에서 바로 실행',
    ],
    proofPoints: ['코드베이스 없음 · 빌드 없음 · 배포 없음', '풀스택: UI + 백엔드 + 데이터베이스', '한 번의 프롬프트 → iOS · Android · Web · 데스크톱'],
    authorNoteEyebrow: '만든이의 말',
    authorNoteTitle: '이 프로젝트가 존재하는 이유',
    authorNoteBody: [
      '솔직히 말하면, 저는 요즘의 AI 광풍이 싫습니다 — 끝없는 논의, 끝없는 마케팅. 하지만 제가 좋아하든 아니든, 이 물결은 물러가지 않을 겁니다.',
      '그러니 어차피 AI coding을 받아들일 거라면, 어중간하게 하느니 아예 끝까지 가 보는 편이 낫습니다. 아이러니하게도, 바로 그것이 이 프로젝트가 존재하는 이유입니다. 목표는 결코 유행을 좇는 것이 아니었습니다 — 이 생각을 논리적인 끝까지 밀어붙이고 이렇게 묻는 것이었습니다: AI가 정말 개발의 미래라면, 진정한 AI-first 워크플로우는 어떤 모습이어야 할까?',
      '이 프로젝트가 지금까지의 제 답입니다.',
    ],
    trustTitle: '신뢰 경계',
    trustPoints: [
      ['선언적 JSON', 'AI는 네이티브 코드나 바이너리를 배포하지 않습니다'],
      ['셀프 호스팅 가능한 백엔드', 'myapp-ctl deploy가 핵심 서비스를 시작합니다'],
      ['크로스 클라이언트 런타임', 'Flutter Web, iOS, Android가 하나의 기능 계층을 공유합니다'],
    ],
    docsTitle: '개발자 진입점',
    docsLinks: [
      ['배포 문서', 'myapp-ctl로 백엔드를 배포한 다음 클라이언트 환경을 전환하세요'],
      ['아키텍처 다이어그램', '런타임, AI Worker, Registry를 한눈에'],
      ['런타임 경계', '사전 컴파일된 기능 집합과 검토 친화적 경계가 작동하는 방식'],
    ],
    videosTitle: '생성된 앱 예시',
    videosSubtitle: '세 가지 다른 앱 형태가 하나의 반복된 껍데기 대신 도구, 게임, 커뮤니티 화면을 보여줍니다.',
    deployTitle: '프라이빗 백엔드 및 클라이언트 설정',
    deployHint: '프라이빗 배포는 주로 백엔드를 의미합니다. 클라이언트는 호스팅된 Web 앱을 사용하거나, iOS / Android / Web을 직접 빌드하여 클라이언트에서 환경을 전환할 수 있습니다.',
    backendDeployTitle: '1. 백엔드 테스트 환경 배포',
    clientBuildTitle: '2. 클라이언트 빌드',
    switchEnvTitle: '3. 클라이언트 환경 전환',
    switchEnvBody: '클라이언트에서 서비스 환경을 열고 백엔드 환경 JSON을 붙여넣거나 스캔하세요. 저장한 다음 다시 로그인하여 백엔드에 연결하세요.',
    usageTitle: '4. 사용 방법',
    usageBody: '테스트 계정으로 로그인한 후 앱 라이브러리에서 JSON Apps를 설치하거나, 플로팅 AI 진입점을 사용하여 앱을 설명하고 채팅을 통해 반복하세요.',
    howTitle: '아이디어에서 앱으로',
    howSubtitle: '전체 흐름은 myapp-ctl 백엔드 배포, 클라이언트 빌드/열기, 환경 전환, 그다음 앱 설치 또는 생성입니다.',
    steps: [
      ['환경 준비', 'myapp-ctl을 사용하여 서비스를 배포하고 백엔드 시크릿을 관리하세요.'],
      ['클라이언트 연결', 'Web / iOS / Android 모두 환경 전환 페이지를 통해 연결됩니다.'],
      ['앱 생성 또는 설치', '앱 라이브러리에서 JSON Apps를 설치하거나 AI에게 새로 생성하도록 요청하세요.'],
    ],
    featuresTitle: '플랫폼 기능',
    featuresSubtitle: 'AI 풀스택 생성, 런타임 렌더링, 게임, 앱 라이브러리, 셀프 호스팅을 중심으로 구축되었습니다.',
    stackTitle: '하나의 런타임, 네 가지 핵심 경로',
    stackSubtitle: '클라이언트는 승인된 JSON 기능만 해석합니다. 백엔드는 격리된 agent nodes에서의 AI 생성, AI가 생성한 FaaS 백엔드, 패키지 배포, IM, 구성, 재개 가능한 작업을 처리합니다.',
    stackItems: [
      ['Flutter Runtime', '사전 컴파일된 위젯, JsonLogic, Flame 게임 원자, IM 호환성, 미디어 기능.'],
      ['AI Worker 큐', 'Redis 큐, 격리된 pull 기반 agent-node 실행, 재개 가능한 SSE, 동시성 제한, 영속적 결과.'],
      ['AI FaaS 백엔드', 'AI가 생성한 Python/Flask 백엔드: 검증된 번들, 격리된 git push 워커, 자체 관리형 컨테이너화 FaaS 런타임(서비스당 컨테이너 하나, 함수 개수 제한 없음, 자동 scale-to-zero 및 cold-wake), 라우트로 강제되는 invoke 프록시, 그리고 애플리케이션 수준 권한 모델 — 앱별 격리 데이터베이스, 신뢰할 수 있는 가명 신원, 백엔드가 중개하는 호출자별 데이터 계층(함수는 DB 연결을 보유하지 않음), 컨테이너 강화, 취소 가능한 접근 정책.'],
      ['Registry + Assets', '페이지네이션 검색, semver, 컴포넌트 종속성, 인스턴스 간 미러, OSS/MinIO 에셋 전달.'],
    ],
    complianceTitle: '검토 친화적 경계',
    complianceBody: 'AI는 클라이언트를 위한 선언적 JSON을 생성합니다: 컴파일된 위젯과 액션만 구성하며, Dart, Swift, Kotlin, 플러그인, 바이너리는 절대 사용하지 않습니다. 앱에 백엔드가 필요할 때 생성된 FaaS 서비스는 격리된 자체 관리형 컨테이너화 FaaS 런타임에서 서버 측으로 실행되므로 실행 가능한 코드가 클라이언트에 전달되지 않습니다.',
    features: [
      ['풀스택 생성 (차별화 요소)', '다른 AI 빌더는 직접 호스팅하고 유지 관리해야 하는 웹 코드베이스를 제공합니다. MyApp은 하나의 프롬프트로 JSON 앱과 이에 맞는 검증된 Python/Flask 백엔드를 생성하여 격리된 자체 관리형 컨테이너화 FaaS 런타임(함수 개수 제한 없음, 자동 scale-to-zero, cold-wake, autoscaling)에 배포하고 즉시 실행합니다. 각 앱은 또한 격리된 Postgres 데이터베이스와 애플리케이션 수준 권한 모델(owner / maintainer / consumer)을 받습니다 — 소비자 데이터는 플랫폼에 의해 호출자별로 격리되며, 함수 코드는 절대 데이터베이스 연결을 보유하지 않습니다.'],
      ['AI 네이티브 DSL', 'LLM 생성에 맞게 구조화되고 손으로 작성한 구성이 아닌 실제 네이티브 UI로 렌더링됩니다.'],
      ['Flame 게임', '실제 2D 게임 엔진 — 스프라이트, 물리, 타일 맵 — 이 Web, iOS, Android에서 실행되며, 단순한 장난감이 아닙니다.'],
      ['내장 IM', '친구, 그룹, 동기화, Web을 위한 OpenIM 호환성 계층.'],
      ['앱 라이브러리', 'semver, 종속성 해결, 인스턴스 간 미러링을 갖춘 네임스페이스 registry.'],
      ['기능 경계', 'UI와 동작은 사전 컴파일된 기능 집합 내부의 데이터로 전달됩니다; 인증 토큰과 같은 민감한 기능은 앱별 권한 부여가 필요합니다.'],
      ['셀프 호스팅 가능', 'myapp-ctl이 전체 백엔드, agent 런타임, registry를 배포합니다; 하나의 DSL이 iOS, Android, Web, 데스크톱 빌드에서 렌더링됩니다.'],
    ],
    downloadTitle: 'MyApp 사용 시작',
    downloadBody: '지금 Web 앱을 여세요. iOS는 2,500석 규모의 TestFlight Public Group 1을 통해 이용할 수 있습니다. Google Play가 준비되는 동안 Android APK 다운로드를 이용할 수 있습니다.',
    openWeb: 'Web 앱 열기',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: '이용 가능',
    soon: '곧 출시',
  },
  ja: {
    navHow: 'デプロイ',
    navStack: 'スタック',
    navTry: 'ツアー',
    navFeatures: '機能',
    navDownload: 'ダウンロード',
    badge: 'コードベースではなく vibe app · Web · iOS · Android · デスクトップ',
    titleA: 'vibe-coding はもう終わり。',
    titleB: 'vibe-app を出荷しよう。',
    subtitle:
      'vibe coding は——最高の AI アプリビルダーでさえ——ホスティングし、メンテナンスすべき Web コードベースを渡してくるだけです。vibe app はただ動いています——スマホ上で数秒でネイティブに起動します：望むものを伝えれば、AI がスタック全体を生成します——UI + 本物の Python/Flask バックエンド + 独自の Postgres データベース——事前にコンパイルされたクロスプラットフォームのランタイムの中で即座に動き出します。同じ一文から、プレイ可能なゲームも、本物のバックエンド付きフォーラムも立ち上がります。コードベースなし。ビルドなし。デプロイなし。アプリストアなし。',
    primaryCta: 'Web アプリを開く',
    secondaryCta: 'TestFlight に参加',
    phoneCaption: '自分でホスティングするコードベースではなく、実際に動いているアプリ。いますぐ、どんな画面でも Web で開けます。',
    heroConsoleTitle: '一文 → 動作するアプリ',
    heroConsoleLines: [
      '$ describe "ログイン・投稿・スレッド形式の返信があるフォーラム"',
      '→ AI が UI + 本物のバックエンド + データベースを作成',
      '→ ビルドなし · デプロイなし · アプリストアなし',
      '→ Web · iOS · Android · デスクトップで稼働',
    ],
    proofPoints: ['コードベースなし · ビルドなし · デプロイなし', 'フルスタック：UI + バックエンド + データベース', '1 つのプロンプト → iOS · Android · Web · デスクトップ'],
    authorNoteEyebrow: '作者より',
    authorNoteTitle: 'なぜこのプロジェクトが存在するのか',
    authorNoteBody: [
      '正直に言うと、私は昨今の AI をめぐる熱狂が嫌いです——終わりのない議論、終わりのないマーケティング。しかし、私が好もうと好むまいと、この波が引くことはありません。',
      'だから、どうせ AI coding を受け入れるのなら、中途半端にやるのではなく、とことんまでやり切ったほうがいい。皮肉なことに、それこそがこのプロジェクトが存在する理由です。目標は流行を追いかけることでは決してなく、この発想を論理の行き着くところまで押し進めて、こう問うことでした——もし AI が本当に開発の未来なら、真に AI-first なワークフローとはどんな姿になるのか？',
      'このプロジェクトが、今のところの私の答えです。',
    ],
    trustTitle: '信頼境界',
    trustPoints: [
      ['宣言的 JSON', 'AI はネイティブコードやバイナリを配布しません'],
      ['セルフホスト可能なバックエンド', 'myapp-ctl deploy がコアサービスを起動します'],
      ['クロスクライアントランタイム', 'Flutter Web、iOS、Android が一つの機能レイヤーを共有します'],
    ],
    docsTitle: '開発者向けエントリーポイント',
    docsLinks: [
      ['デプロイドキュメント', 'myapp-ctl でバックエンドをデプロイし、クライアント環境を切り替えます'],
      ['アーキテクチャ図', 'ランタイム、AI Worker、Registry を一つのビューで'],
      ['ランタイム境界', 'プリコンパイルされた機能セットとレビューに適した境界の仕組み'],
    ],
    videosTitle: '生成されたアプリの例',
    videosSubtitle: '3 つの異なるアプリ形態が、一つの繰り返しの殻ではなく、ツール、ゲーム、コミュニティ画面を示します。',
    deployTitle: 'プライベートバックエンドとクライアントのセットアップ',
    deployHint: 'プライベートデプロイは主にバックエンドを指します。クライアントはホスト型 Web アプリを使用できるほか、iOS / Android / Web を自分でビルドしてクライアントで環境を切り替えることもできます。',
    backendDeployTitle: '1. バックエンドのテスト環境をデプロイ',
    clientBuildTitle: '2. クライアントをビルド',
    switchEnvTitle: '3. クライアント環境を切り替え',
    switchEnvBody: 'クライアントでサービス環境を開き、バックエンド環境 JSON を貼り付けるかスキャンします。保存して再度サインインし、バックエンドに接続します。',
    usageTitle: '4. 使い方',
    usageBody: 'テストアカウントでサインインした後、アプリライブラリから JSON Apps をインストールするか、フローティング AI エントリーを使ってアプリを説明し、チャットを通じて反復します。',
    howTitle: 'アイデアからアプリへ',
    howSubtitle: '全体の流れは、myapp-ctl によるバックエンドデプロイ、クライアントのビルド／起動、環境切り替え、その後のアプリのインストールまたは生成です。',
    steps: [
      ['環境を準備', 'myapp-ctl を使ってサービスをデプロイし、バックエンドのシークレットを管理します。'],
      ['クライアントを接続', 'Web / iOS / Android はすべて環境切り替えページを通じて接続します。'],
      ['アプリを生成またはインストール', 'アプリライブラリから JSON Apps をインストールするか、AI に新しいものを生成するよう依頼します。'],
    ],
    featuresTitle: 'プラットフォーム機能',
    featuresSubtitle: 'AI フルスタック生成、ランタイムレンダリング、ゲーム、アプリライブラリ、セルフホスティングを中心に構築されています。',
    stackTitle: '一つのランタイム、四つの重要パス',
    stackSubtitle: 'クライアントは承認された JSON 機能のみを解釈します。バックエンドは、分離された agent nodes での AI 生成、AI が生成した FaaS バックエンド、パッケージ配信、IM、設定、再開可能なタスクを処理します。',
    stackItems: [
      ['Flutter Runtime', 'プリコンパイルされたウィジェット、JsonLogic、Flame ゲームアトム、IM 互換性、メディア機能。'],
      ['AI Worker キュー', 'Redis キュー、分離された pull ベースの agent-node 実行、再開可能な SSE、並行性制限、永続的な結果。'],
      ['AI FaaS バックエンド', 'AI が生成した Python/Flask バックエンド：検証済みバンドル、分離された git push ワーカー、自己管理型のコンテナ化された FaaS ランタイム（サービスごとに一つのコンテナ、関数数の上限なし、自動 scale-to-zero と cold-wake）、ルートで強制される invoke プロキシ、そしてアプリケーションレベルの権限モデル — アプリごとに分離されたデータベース、信頼できる仮名 ID、バックエンドが仲介する呼び出し元ごとのデータレイヤー（関数は DB 接続を保持しない）、コンテナ強化、取り消し可能なアクセスポリシー。'],
      ['Registry + Assets', 'ページ分割された検索、semver、コンポーネント依存関係、インスタンス間ミラー、OSS/MinIO アセット配信。'],
    ],
    complianceTitle: 'レビューに適した境界',
    complianceBody: 'AI はクライアント向けに宣言的 JSON を生成します：コンパイル済みのウィジェットとアクションのみを構成し、Dart、Swift、Kotlin、プラグイン、バイナリは一切使用しません。アプリにバックエンドが必要な場合、生成された FaaS サービスは分離された自己管理型のコンテナ化された FaaS ランタイムでサーバーサイドで実行されるため、実行可能なコードがクライアントに配布されることはありません。',
    features: [
      ['フルスタック生成（差別化要因）', '他の AI ビルダーが提供するのは、自分でホスティングして保守する web コードベースです。MyApp は一つのプロンプトから JSON アプリと、それに対応する検証済みの Python/Flask バックエンドを生成し、分離された自己管理型のコンテナ化された FaaS ランタイム（関数数の上限なし、自動 scale-to-zero、cold-wake、autoscaling）にデプロイして即座に実行します。各アプリには、分離された Postgres データベースとアプリケーションレベルの権限モデル（owner / maintainer / consumer）も付与されます — 消費者データはプラットフォームによって呼び出し元ごとに分離され、関数コードがデータベース接続を保持することは決してありません。'],
      ['AI ネイティブ DSL', 'LLM 生成向けに構造化され、手書きの設定ではなく実際のネイティブ UI にレンダリングされます。'],
      ['Flame ゲーム', '実際の 2D ゲームエンジン — スプライト、物理、タイルマップ — が Web、iOS、Android で動作し、単なるおもちゃではありません。'],
      ['組み込み IM', '友達、グループ、同期、Web 向けの OpenIM 互換レイヤー。'],
      ['アプリライブラリ', 'semver、依存関係の解決、インスタンス間ミラーリングを備えた名前空間付き registry。'],
      ['機能境界', 'UI と動作はプリコンパイルされた機能セット内のデータとして配布されます；認証トークンのような機密性の高い機能にはアプリごとの認可が必要です。'],
      ['セルフホスト可能', 'myapp-ctl がバックエンド全体、agent ランタイム、registry をデプロイします；一つの DSL が iOS、Android、Web、デスクトップビルドでレンダリングされます。'],
    ],
    downloadTitle: 'MyApp を使い始める',
    downloadBody: '今すぐ Web アプリを開いてください。iOS は 2,500 席の TestFlight Public Group 1 を通じて利用できます。Google Play の準備中、Android APK のダウンロードが利用可能です。',
    openWeb: 'Web アプリを開く',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: '利用可能',
    soon: '近日公開',
  },
  it: {
    navHow: 'Distribuisci',
    navStack: 'Stack',
    navTry: 'Tour',
    navFeatures: 'Funzionalità',
    navDownload: 'Scarica',
    badge: 'Una vibe app, non un codebase · Web · iOS · Android · Desktop',
    titleA: 'Basta vibe-coding.',
    titleB: 'Lancia vibe-app.',
    subtitle:
      'Il vibe coding — anche i migliori costruttori di app IA — ti consegna comunque un codebase web da ospitare e mantenere. Una vibe app è semplicemente live — nativa sul tuo telefono in pochi secondi: descrivi ciò che vuoi e l\'IA genera l\'intero stack — UI + un vero backend Python/Flask + il proprio database Postgres — in esecuzione all\'istante dentro un runtime precompilato e multipiattaforma. La stessa frase può dar vita a un gioco giocabile o a un forum con un vero backend. Niente codebase. Niente build. Niente deploy. Niente app store.',
    primaryCta: 'Apri la Web app',
    secondaryCta: 'Unisciti a TestFlight',
    phoneCaption: 'Un\'app vera in esecuzione, non un codebase da ospitare. Aprila sul Web ora, su qualsiasi schermo.',
    heroConsoleTitle: 'Una frase → un\'app live',
    heroConsoleLines: [
      '$ describe "un forum con login, post e risposte in thread"',
      '→ l\'IA scrive la UI + un vero backend + database',
      '→ niente build · niente deploy · niente app store',
      '→ live su Web · iOS · Android · desktop',
    ],
    proofPoints: ['Niente codebase · niente build · niente deploy', 'Full-stack: UI + backend + database', 'Un prompt → iOS · Android · Web · desktop'],
    authorNoteEyebrow: 'Una nota dell\'autore',
    authorNoteTitle: 'Perché esiste questo progetto',
    authorNoteBody: [
      'Ad essere onesto, l\'hype odierno intorno all\'IA mi dà fastidio — le discussioni senza fine, il marketing senza fine. Ma che mi piaccia o no, questa ondata non se ne andrà.',
      'Quindi, se dobbiamo abbracciare l\'AI coding, tanto vale farlo fino in fondo invece che a metà. Ironia della sorte, è esattamente per questo che esiste questo progetto. L\'obiettivo non è mai stato inseguire il trend — era spingere l\'idea fino alla sua conclusione logica e chiedersi: se l\'IA è davvero il futuro dello sviluppo, che aspetto avrebbe un workflow veramente AI-first?',
      'Questo progetto è la mia risposta, finora.',
    ],
    trustTitle: 'Confine di fiducia',
    trustPoints: [
      ['JSON dichiarativo', 'L\'IA non distribuisce codice nativo né binari'],
      ['Backend auto-ospitabile', 'myapp-ctl deploy avvia i servizi principali'],
      ['Runtime multi-client', 'Flutter Web, iOS e Android condividono un solo livello di capacità'],
    ],
    docsTitle: 'Punti di ingresso per sviluppatori',
    docsLinks: [
      ['Documentazione di distribuzione', 'Distribuisci il backend con myapp-ctl, poi cambia l\'ambiente del client'],
      ['Diagramma dell\'architettura', 'Runtime, AI Worker e Registry in un\'unica vista'],
      ['Confine di esecuzione', 'Come funzionano l\'insieme di capacità precompilato e il confine adatto alla revisione'],
    ],
    videosTitle: 'Esempi di app generate',
    videosSubtitle: 'Tre forme di app diverse mostrano strumenti, giochi e schermate di comunità invece di un singolo guscio ripetuto.',
    deployTitle: 'Configurazione del backend privato e del client',
    deployHint: 'La distribuzione privata riguarda soprattutto il backend. Il client può usare la Web app ospitata, oppure puoi compilare tu stesso iOS / Android / Web e cambiare ambiente nel client.',
    backendDeployTitle: '1. Distribuire l\'ambiente di test del backend',
    clientBuildTitle: '2. Compilare i client',
    switchEnvTitle: '3. Cambiare l\'ambiente del client',
    switchEnvBody: 'Apri Ambiente di Servizio nel client, poi incolla o scansiona il JSON dell\'ambiente del backend. Salva e accedi di nuovo per connetterti al tuo backend.',
    usageTitle: '4. Come usarlo',
    usageBody: 'Dopo aver effettuato l\'accesso con l\'account di test, installa JSON Apps dalla libreria delle app o usa l\'ingresso IA fluttuante per descrivere un\'app e iterare tramite chat.',
    howTitle: 'Dall\'idea all\'app',
    howSubtitle: 'Il flusso completo è la distribuzione del backend con myapp-ctl, la compilazione/apertura del client, il cambio di ambiente e poi l\'installazione o la generazione di app.',
    steps: [
      ['Preparare l\'ambiente', 'Usa myapp-ctl per distribuire i servizi e gestire i segreti del backend.'],
      ['Connettere il client', 'Web / iOS / Android si connettono tutti tramite la pagina di cambio ambiente.'],
      ['Generare o installare app', 'Installa JSON Apps dalla libreria o chiedi all\'IA di generarne di nuove.'],
    ],
    featuresTitle: 'Capacità della piattaforma',
    featuresSubtitle: 'Costruita attorno alla generazione full-stack tramite IA, al rendering a runtime, ai giochi, a una libreria di app e all\'auto-ospitalità.',
    stackTitle: 'Un runtime, quattro percorsi critici',
    stackSubtitle: 'Il client interpreta solo le capacità JSON approvate. Il backend gestisce la generazione IA su agent nodes isolati, i backend FaaS generati dall\'IA, la distribuzione dei pacchetti, l\'IM, la configurazione e le attività riprendibili.',
    stackItems: [
      ['Flutter Runtime', 'Widget precompilati, JsonLogic, atomi di gioco Flame, compatibilità IM e capacità multimediali.'],
      ['Coda AI Worker', 'Coda Redis, esecuzione agent-node isolata basata su pull, SSE riprendibile, limiti di concorrenza e risultati durevoli.'],
      ['Backend FaaS IA', 'Backend Python/Flask generati dall\'IA: bundle validati, un worker git push isolato, un runtime FaaS containerizzato autogestito (un container per servizio, nessun limite al numero di funzioni, scale-to-zero automatico e cold-wake), un proxy di invocazione applicato dalle route e un modello di permessi a livello di applicazione — database isolato per app, identità pseudonima affidabile, un livello di dati per chiamante mediato dal backend (le funzioni non detengono connessioni al DB), rafforzamento dei container e politiche di accesso revocabili.'],
      ['Registry + Assets', 'Ricerca paginata, semver, dipendenze tra componenti, mirror tra istanze e distribuzione di asset OSS/MinIO.'],
    ],
    complianceTitle: 'Confine adatto alla revisione',
    complianceBody: 'L\'IA produce JSON dichiarativo per il client: compone solo widget e azioni compilati, mai Dart, Swift, Kotlin, plugin o binari. Quando un\'app ha bisogno di un backend, i servizi FaaS generati vengono eseguiti lato server in un runtime FaaS containerizzato autogestito e isolato, quindi nessun codice eseguibile viene distribuito al client.',
    features: [
      ['Generazione full-stack (il fattore differenziante)', 'Altri generatori IA ti danno una codebase web da ospitare e mantenere. MyApp genera l\'app JSON e un backend Python/Flask validato corrispondente da un solo prompt, distribuito su un runtime FaaS containerizzato autogestito e isolato (nessun limite al numero di funzioni, scale-to-zero automatico, cold-wake e autoscaling), e lo esegue istantaneamente. Ogni app riceve anche un database Postgres isolato e un modello di permessi a livello di applicazione (owner / maintainer / consumer) — i dati del consumatore sono isolati per chiamante dalla piattaforma, e il codice delle funzioni non detiene mai una connessione al database.'],
      ['DSL nativo per l\'IA', 'Strutturato per la generazione tramite LLM e renderizzato in vera UI nativa, non solo configurazione scritta a mano.'],
      ['Giochi Flame', 'Un vero motore di gioco 2D — sprite, fisica e mappe a tasselli — in esecuzione su Web, iOS e Android, non solo giocattoli.'],
      ['IM integrato', 'Amici, gruppi, sincronizzazione e il livello di compatibilità OpenIM per il Web.'],
      ['Libreria di app', 'Registry con namespace, semver, risoluzione delle dipendenze e mirroring tra istanze.'],
      ['Confine di capacità', 'UI e comportamento vengono distribuiti come dati all\'interno di un insieme di capacità precompilato; le capacità sensibili come il token di autenticazione richiedono un\'autorizzazione per app.'],
      ['Auto-ospitabile', 'myapp-ctl distribuisce l\'intero backend, il runtime degli agenti e il registry; un solo DSL viene renderizzato su build iOS, Android, Web e desktop.'],
    ],
    downloadTitle: 'Inizia a usare MyApp',
    downloadBody: 'Apri la Web app ora. iOS è disponibile tramite TestFlight Public Group 1 con 2.500 posti. Il download dell\'APK Android è disponibile mentre Google Play viene preparato.',
    openWeb: 'Apri la Web app',
    appStore: 'TestFlight Public Group 1',
    googlePlay: 'Google Play',
    apk: 'APK',
    available: 'Disponibile',
    soon: 'Prossimamente',
  },
};

const docsI18n: Record<string, Partial<Record<Lang, string>>> = {
  'The demo is an accelerated replay of a real, recorded generation run; multilingual support was added later.': { de: 'Die Demo ist eine beschleunigte Wiedergabe eines echten, aufgezeichneten Generierungslaufs; die Mehrsprachigkeit kam später dazu.', es: 'La demo es una reproducción acelerada de una ejecución de generación real grabada; el soporte multilingüe se añadió después.', fr: "La démo est une relecture accélérée d'une génération réelle enregistrée ; le multilingue a été ajouté par la suite.", pt: 'A demo é uma reprodução acelerada de uma execução de geração real gravada; o suporte multilíngue foi adicionado depois.', ca: "La demo és una reproducció accelerada d'una execució de generació real enregistrada; el suport multilingüe es va afegir després.", hi: 'यह डेमो वास्तविक, रिकॉर्ड किए गए जेनरेशन रन का त्वरित रीप्ले है; बहुभाषी समर्थन बाद में जोड़ा गया।', ko: '이 데모는 실제로 기록된 생성 실행의 가속 재생이며, 다국어 지원은 나중에 추가되었습니다.', ja: 'このデモは実際に記録した生成フローの加速再生で、多言語対応は後から追加しました。', it: 'La demo è una riproduzione accelerata di una esecuzione di generazione reale registrata; il supporto multilingue è stato aggiunto in seguito.' },
  'Entry': { de: 'Einstieg', es: 'Entrada', fr: 'Entrée', pt: 'Entrada', ca: 'Entrada', hi: 'प्रवेश बिंदु', ko: '진입점', ja: '入口', it: 'Ingresso' },
  'Web client': { de: 'Web-Client', es: 'Cliente Web', fr: 'Client Web', pt: 'Cliente Web', ca: 'Client web', hi: 'Web क्लाइंट', ko: 'Web 클라이언트', ja: 'Web クライアント', it: 'Client Web' },
  'iOS / Android': { de: 'iOS / Android', es: 'iOS / Android', fr: 'iOS / Android', pt: 'iOS / Android', ca: 'iOS / Android', hi: 'iOS / Android', ko: 'iOS / Android', ja: 'iOS / Android', it: 'iOS / Android' },
  'Runtime': { de: 'Laufzeitumgebung', es: 'Entorno de ejecución', fr: 'Runtime', pt: 'Runtime', ca: 'Entorn d\'execució', hi: 'रनटाइम', ko: '런타임', ja: 'ランタイム', it: 'Runtime' },
  'JSON DSL interpreter': { de: 'JSON-DSL-Interpreter', es: 'Intérprete de JSON DSL', fr: 'Interpréteur JSON DSL', pt: 'Interpretador de JSON DSL', ca: 'Intèrpret de JSON DSL', hi: 'JSON DSL इंटरप्रेटर', ko: 'JSON DSL 인터프리터', ja: 'JSON DSL インタープリター', it: 'Interprete JSON DSL' },
  'compiled capabilities only': { de: 'nur kompilierte Funktionen', es: 'solo capacidades compiladas', fr: 'capacités compilées uniquement', pt: 'apenas capacidades compiladas', ca: 'només capacitats compilades', hi: 'केवल कंपाइल की गई क्षमताएँ', ko: '컴파일된 기능만 사용', ja: 'コンパイル済み機能のみ', it: 'solo funzionalità compilate' },
  'IM / game / media atoms': { de: 'IM-/Spiel-/Medien-Atome', es: 'Átomos de IM / juegos / multimedia', fr: 'atomes IM / jeu / média', pt: 'Átomos de IM / jogo / multimédia', ca: 'Àtoms d\'IM / joc / multimèdia', hi: 'IM / गेम / मीडिया एटम', ko: 'IM / 게임 / 미디어 원자 위젯', ja: 'IM / ゲーム / メディアの構成要素', it: 'Atomi IM / giochi / media' },
  'general capability layer': { de: 'generische Funktionsschicht', es: 'capa de capacidades generales', fr: 'couche de capacités génériques', pt: 'camada de capacidades genéricas', ca: 'capa de capacitats generals', hi: 'सामान्य क्षमता परत', ko: '범용 기능 계층', ja: '汎用機能レイヤー', it: 'livello di funzionalità generiche' },
  'Backend': { de: 'Backend', es: 'Backend', fr: 'Backend', pt: 'Backend', ca: 'Backend', hi: 'बैकएंड', ko: '백엔드', ja: 'バックエンド', it: 'Backend' },
  'Flask API + SSE': { de: 'Flask-API + SSE', es: 'API Flask + SSE', fr: 'API Flask + SSE', pt: 'API Flask + SSE', ca: 'API Flask + SSE', hi: 'Flask API + SSE', ko: 'Flask API + SSE', ja: 'Flask API + SSE', it: 'API Flask + SSE' },
  'sessions, auth, recovery': { de: 'Sitzungen, Auth, Wiederherstellung', es: 'sesiones, autenticación, recuperación', fr: 'sessions, authentification, reprise', pt: 'sessões, autenticação, recuperação', ca: 'sessions, autenticació, recuperació', hi: 'सेशन, प्रमाणीकरण, रिकवरी', ko: '세션, 인증, 복구', ja: 'セッション、認証、復旧', it: 'sessioni, autenticazione, ripristino' },
  'AI worker queue': { de: 'AI-Worker-Queue', es: 'Cola de workers de IA', fr: 'File de workers IA', pt: 'Fila de workers de IA', ca: 'Cua de workers d\'IA', hi: 'AI वर्कर क्यू', ko: 'AI 워커 큐', ja: 'AI ワーカーキュー', it: 'Coda worker IA' },
  'Redis queue + agents': { de: 'Redis-Queue + Agents', es: 'Cola Redis + agentes', fr: 'File Redis + agents', pt: 'Fila Redis + agentes', ca: 'Cua Redis + agents', hi: 'Redis क्यू + एजेंट', ko: 'Redis 큐 + 에이전트', ja: 'Redis キュー + エージェント', it: 'Coda Redis + agenti' },
  'Platform services': { de: 'Plattformdienste', es: 'Servicios de plataforma', fr: 'Services de plateforme', pt: 'Serviços de plataforma', ca: 'Serveis de plataforma', hi: 'प्लेटफ़ॉर्म सेवाएँ', ko: '플랫폼 서비스', ja: 'プラットフォームサービス', it: 'Servizi di piattaforma' },
  'Registry / config center': { de: 'Registry / Konfigurationszentrale', es: 'Registry / centro de configuración', fr: 'Registry / centre de configuration', pt: 'Registry / centro de configuração', ca: 'Registry / centre de configuració', hi: 'Registry / कॉन्फ़िग केंद्र', ko: 'Registry / 설정 센터', ja: 'Registry / 構成センター', it: 'Registry / centro di configurazione' },
  'JSON Apps, versions, APK': { de: 'JSON-Apps, Versionen, APK', es: 'Apps JSON, versiones, APK', fr: 'Apps JSON, versions, APK', pt: 'JSON Apps, versões, APK', ca: 'JSON Apps, versions, APK', hi: 'JSON ऐप, वर्शन, APK', ko: 'JSON App, 버전, APK', ja: 'JSON アプリ、バージョン、APK', it: 'App JSON, versioni, APK' },
  'User center / OpenIM': { de: 'Benutzerzentrale / OpenIM', es: 'Centro de usuarios / OpenIM', fr: 'Centre utilisateur / OpenIM', pt: 'Centro de utilizadores / OpenIM', ca: 'Centre d\'usuaris / OpenIM', hi: 'यूज़र केंद्र / OpenIM', ko: '사용자 센터 / OpenIM', ja: 'ユーザーセンター / OpenIM', it: 'Centro utenti / OpenIM' },
  'users, friends, messages': { de: 'Benutzer, Freunde, Nachrichten', es: 'usuarios, amigos, mensajes', fr: 'utilisateurs, amis, messages', pt: 'utilizadores, amigos, mensagens', ca: 'usuaris, amics, missatges', hi: 'उपयोगकर्ता, मित्र, संदेश', ko: '사용자, 친구, 메시지', ja: 'ユーザー、フレンド、メッセージ', it: 'utenti, amici, messaggi' },
  'Data and assets': { de: 'Daten und Assets', es: 'Datos y recursos', fr: 'Données et ressources', pt: 'Dados e recursos', ca: 'Dades i recursos', hi: 'डेटा और एसेट', ko: '데이터 및 에셋', ja: 'データとアセット', it: 'Dati e risorse' },
  'business data, queues, sessions': { de: 'Geschäftsdaten, Queues, Sitzungen', es: 'datos de negocio, colas, sesiones', fr: 'données métier, files, sessions', pt: 'dados de negócio, filas, sessões', ca: 'dades de negoci, cues, sessions', hi: 'बिज़नेस डेटा, क्यू, सेशन', ko: '비즈니스 데이터, 큐, 세션', ja: '業務データ、キュー、セッション', it: 'dati di business, code, sessioni' },
  'JSON, media, release files': { de: 'JSON, Medien, Release-Dateien', es: 'JSON, multimedia, archivos de publicación', fr: 'JSON, médias, fichiers de publication', pt: 'JSON, multimédia, ficheiros de versão', ca: 'JSON, multimèdia, fitxers de publicació', hi: 'JSON, मीडिया, रिलीज़ फ़ाइलें', ko: 'JSON, 미디어, 릴리스 파일', ja: 'JSON、メディア、リリースファイル', it: 'JSON, media, file di release' },
  'System architecture': { de: 'Systemarchitektur', es: 'Arquitectura del sistema', fr: 'Architecture du système', pt: 'Arquitetura do sistema', ca: 'Arquitectura del sistema', hi: 'सिस्टम आर्किटेक्चर', ko: '시스템 아키텍처', ja: 'システムアーキテクチャ', it: 'Architettura del sistema' },
  'Clients interpret JSON; backend generates, distributes and resumes work': { de: 'Clients interpretieren JSON; das Backend generiert, verteilt und setzt Aufgaben fort', es: 'Los clientes interpretan JSON; el backend genera, distribuye y reanuda el trabajo', fr: 'Les clients interprètent le JSON ; le backend génère, distribue et reprend le travail', pt: 'Os clientes interpretam JSON; o backend gera, distribui e retoma o trabalho', ca: 'Els clients interpreten JSON; el backend genera, distribueix i reprèn la feina', hi: 'क्लाइंट JSON की व्याख्या करते हैं; बैकएंड काम जेनरेट, वितरित और पुनः शुरू करता है', ko: '클라이언트는 JSON을 해석하고, 백엔드는 작업을 생성·배포·재개합니다', ja: 'クライアントが JSON を解釈し、バックエンドが生成・配信・処理の再開を担う', it: 'I client interpretano il JSON; il backend genera, distribuisce e riprende i lavori' },
  'GitHub coming soon': { de: 'GitHub folgt in Kürze', es: 'GitHub próximamente', fr: 'GitHub bientôt disponible', pt: 'GitHub em breve', ca: 'GitHub disponible aviat', hi: 'GitHub जल्द आ रहा है', ko: 'GitHub 공개 예정', ja: 'GitHub は近日公開', it: 'GitHub in arrivo' },
  'MyApp system architecture diagram': { de: 'Systemarchitektur-Diagramm von MyApp', es: 'Diagrama de arquitectura del sistema MyApp', fr: 'Diagramme d\'architecture du système MyApp', pt: 'Diagrama de arquitetura do sistema MyApp', ca: 'Diagrama d\'arquitectura del sistema MyApp', hi: 'MyApp सिस्टम आर्किटेक्चर आरेख', ko: 'MyApp 시스템 아키텍처 다이어그램', ja: 'MyApp システムアーキテクチャ図', it: 'Diagramma dell\'architettura di sistema di MyApp' },
  'Declarative JSON Apps': { de: 'Deklarative JSON-Apps', es: 'Apps JSON declarativas', fr: 'Apps JSON déclaratives', pt: 'JSON Apps declarativos', ca: 'JSON Apps declaratives', hi: 'घोषणात्मक JSON ऐप', ko: '선언형 JSON App', ja: '宣言的な JSON アプリ', it: 'App JSON dichiarative' },
  'General Flutter capability layer': { de: 'Generische Flutter-Funktionsschicht', es: 'Capa general de capacidades Flutter', fr: 'Couche de capacités Flutter génériques', pt: 'Camada de capacidades genéricas Flutter', ca: 'Capa general de capacitats Flutter', hi: 'सामान्य Flutter क्षमता परत', ko: '범용 Flutter 기능 계층', ja: '汎用 Flutter 機能レイヤー', it: 'Livello generico di funzionalità Flutter' },
  'Self-hostable backend': { de: 'Selbst hostbares Backend', es: 'Backend autoalojable', fr: 'Backend auto-hébergeable', pt: 'Backend auto-hospedável', ca: 'Backend autoallotjable', hi: 'स्व-होस्ट किया जाने वाला बैकएंड', ko: '셀프 호스팅 가능한 백엔드', ja: 'セルフホスト可能なバックエンド', it: 'Backend self-hosted' },
  'Describe an idea': { de: 'Eine Idee beschreiben', es: 'Describe una idea', fr: 'Décrire une idée', pt: 'Descrever uma ideia', ca: 'Descriu una idea', hi: 'एक विचार बताएँ', ko: '아이디어 설명', ja: 'アイデアを記述する', it: 'Descrivi un\'idea' },
  'User describes a tool, game or screen.': { de: 'Der Nutzer beschreibt ein Tool, ein Spiel oder eine Ansicht.', es: 'El usuario describe una herramienta, un juego o una pantalla.', fr: 'L\'utilisateur décrit un outil, un jeu ou un écran.', pt: 'O utilizador descreve uma ferramenta, jogo ou ecrã.', ca: 'L\'usuari descriu una eina, un joc o una pantalla.', hi: 'उपयोगकर्ता किसी टूल, गेम या स्क्रीन का वर्णन करता है।', ko: '사용자가 도구, 게임 또는 화면을 설명합니다.', ja: 'ユーザーがツール、ゲーム、または画面を記述します。', it: 'L\'utente descrive uno strumento, un gioco o una schermata.' },
  'Generate JSON App': { de: 'JSON-App generieren', es: 'Generar App JSON', fr: 'Générer une App JSON', pt: 'Gerar JSON App', ca: 'Genera una JSON App', hi: 'JSON ऐप जेनरेट करें', ko: 'JSON App 생성', ja: 'JSON アプリを生成する', it: 'Genera l\'App JSON' },
  'AI produces declarative JSON and validation passes.': { de: 'Die AI erzeugt deklaratives JSON und die Validierung besteht.', es: 'La IA produce JSON declarativo y la validación se supera.', fr: 'L\'IA produit du JSON déclaratif et la validation réussit.', pt: 'A IA produz JSON declarativo e a validação é aprovada.', ca: 'La IA produeix JSON declaratiu i la validació passa.', hi: 'AI घोषणात्मक JSON तैयार करती है और सत्यापन पास हो जाता है।', ko: 'AI가 선언형 JSON을 생성하고 검증을 통과합니다.', ja: 'AI が宣言的な JSON を生成し、検証を通過します。', it: 'L\'IA produce JSON dichiarativo e la validazione viene superata.' },
  'Run everywhere': { de: 'Überall ausführen', es: 'Ejecuta en todas partes', fr: 'Exécuter partout', pt: 'Executar em qualquer lado', ca: 'Executa-ho a tot arreu', hi: 'हर जगह चलाएँ', ko: '어디서나 실행', ja: 'どこでも実行', it: 'Esegui ovunque' },
  'One JSON renders in Web, iOS and Android runtimes.': { de: 'Ein JSON wird in Web-, iOS- und Android-Laufzeiten gerendert.', es: 'Un único JSON se renderiza en los entornos Web, iOS y Android.', fr: 'Un seul JSON s\'affiche dans les runtimes Web, iOS et Android.', pt: 'Um único JSON é renderizado nos runtimes Web, iOS e Android.', ca: 'Un sol JSON es renderitza als entorns Web, iOS i Android.', hi: 'एक ही JSON Web, iOS और Android रनटाइम में रेंडर होता है।', ko: '하나의 JSON이 Web, iOS, Android 런타임에서 렌더링됩니다.', ja: '1 つの JSON が Web、iOS、Android のランタイムで描画されます。', it: 'Un unico JSON viene reso nei runtime Web, iOS e Android.' },
  'Review-friendly boundary': { de: 'Prüffreundliche Grenze', es: 'Límite fácil de revisar', fr: 'Périmètre propice à la revue', pt: 'Fronteira fácil de rever', ca: 'Límit fàcil de revisar', hi: 'समीक्षा-अनुकूल सीमा', ko: '검토 친화적인 경계', ja: 'レビューしやすい境界', it: 'Confine adatto alla revisione' },
  'AI can only compose compiled widgets and actions. It cannot ship native code, plugins or binaries.': { de: 'Die AI kann nur kompilierte Widgets und Aktionen kombinieren. Sie kann keinen nativen Code, keine Plugins und keine Binärdateien ausliefern.', es: 'La IA solo puede componer widgets y acciones compilados. No puede entregar código nativo, plugins ni binarios.', fr: 'L\'IA peut uniquement composer des widgets et des actions compilés. Elle ne peut pas livrer de code natif, de plugins ni de binaires.', pt: 'A IA só pode compor widgets e ações compilados. Não pode distribuir código nativo, plugins ou binários.', ca: 'La IA només pot compondre widgets i accions compilats. No pot distribuir codi natiu, plugins ni binaris.', hi: 'AI केवल कंपाइल किए गए विजेट और एक्शन ही जोड़ सकती है। यह नेटिव कोड, प्लगइन या बाइनरी नहीं भेज सकती।', ko: 'AI는 컴파일된 위젯과 액션만 조합할 수 있습니다. 네이티브 코드, 플러그인 또는 바이너리를 배포할 수 없습니다.', ja: 'AI はコンパイル済みのウィジェットとアクションを組み合わせることしかできません。ネイティブコード、プラグイン、バイナリを配信することはできません。', it: 'L\'IA può solo comporre widget e azioni compilati. Non può distribuire codice nativo, plugin o binari.' },
  'myapp-ctl deployment guide': { de: 'myapp-ctl-Bereitstellungsanleitung', es: 'Guía de despliegue de myapp-ctl', fr: 'Guide de déploiement myapp-ctl', pt: 'Guia de implementação do myapp-ctl', ca: 'Guia de desplegament de myapp-ctl', hi: 'myapp-ctl परिनियोजन गाइड', ko: 'myapp-ctl 배포 가이드', ja: 'myapp-ctl デプロイガイド', it: 'Guida al deployment con myapp-ctl' },
  'Install, deploy, update and extend MyApp with myapp-ctl': { de: 'MyApp mit myapp-ctl installieren, bereitstellen, aktualisieren und erweitern', es: 'Instala, despliega, actualiza y amplía MyApp con myapp-ctl', fr: 'Installer, déployer, mettre à jour et étendre MyApp avec myapp-ctl', pt: 'Instalar, implementar, atualizar e estender o MyApp com o myapp-ctl', ca: 'Instal·la, desplega, actualitza i amplia MyApp amb myapp-ctl', hi: 'myapp-ctl के साथ MyApp को इंस्टॉल, परिनियोजित, अपडेट और विस्तारित करें', ko: 'myapp-ctl로 MyApp을 설치, 배포, 업데이트 및 확장하기', ja: 'myapp-ctl で MyApp をインストール、デプロイ、更新、拡張する', it: 'Installa, distribuisci, aggiorna ed estendi MyApp con myapp-ctl' },
  'The backend is now managed through myapp-ctl under deploy/production. Legacy bootstrap scripts, bare services and one-off migration paths are deprecated.': { de: 'Das Backend wird jetzt über myapp-ctl unter deploy/production verwaltet. Alte Bootstrap-Skripte, blanke Dienste und einmalige Migrationspfade sind veraltet.', es: 'El backend ahora se gestiona mediante myapp-ctl en deploy/production. Los scripts de arranque heredados, los servicios sueltos y las rutas de migración puntuales están obsoletos.', fr: 'Le backend est désormais géré via myapp-ctl sous deploy/production. Les anciens scripts d\'amorçage, les services bruts et les chemins de migration ponctuels sont obsolètes.', pt: 'O backend é agora gerido através do myapp-ctl em deploy/production. Scripts de arranque antigos, serviços diretos e migrações pontuais estão obsoletos.', ca: 'El backend ara es gestiona amb myapp-ctl dins de deploy/production. Els scripts d\'arrencada antics, els serveis nus i les vies de migració puntuals estan obsolets.', hi: 'अब बैकएंड को deploy/production के अंतर्गत myapp-ctl के माध्यम से प्रबंधित किया जाता है। पुराने bootstrap स्क्रिप्ट, बेयर सेवाएँ और एकबारगी माइग्रेशन पथ अप्रचलित हैं।', ko: '백엔드는 이제 deploy/production 아래의 myapp-ctl을 통해 관리됩니다. 기존 부트스트랩 스크립트, 베어 서비스 및 일회성 마이그레이션 경로는 더 이상 사용되지 않습니다.', ja: 'バックエンドは deploy/production 配下の myapp-ctl で管理されるようになりました。従来のブートストラップスクリプト、ベアサービス、1 回限りの移行手順は非推奨です。', it: 'Il backend è ora gestito tramite myapp-ctl in deploy/production. Gli script di bootstrap legacy, i servizi nudi e i percorsi di migrazione una tantum sono deprecati.' },
  'Fast fresh deploy': { de: 'Schnelle Neuinstallation', es: 'Despliegue limpio rápido', fr: 'Déploiement initial rapide', pt: 'Implementação de raiz rápida', ca: 'Desplegament nou ràpid', hi: 'तेज़ नया परिनियोजन', ko: '빠른 신규 배포', ja: '高速な新規デプロイ', it: 'Deployment rapido da zero' },
  'Prepare an Ubuntu host, Docker and a source checkout. Install myapp-ctl, configure secrets, deploy the stack, then import the client environment JSON into the app.': { de: 'Bereiten Sie einen Ubuntu-Host, Docker und ein Source-Checkout vor. Installieren Sie myapp-ctl, konfigurieren Sie die Secrets, stellen Sie den Stack bereit und importieren Sie dann das Client-Umgebungs-JSON in die App.', es: 'Prepara un host Ubuntu, Docker y una copia del código fuente. Instala myapp-ctl, configura los secretos, despliega el stack y luego importa el JSON de entorno del cliente en la app.', fr: 'Préparez un hôte Ubuntu, Docker et un checkout des sources. Installez myapp-ctl, configurez les secrets, déployez la stack, puis importez le JSON d\'environnement client dans l\'app.', pt: 'Prepare um host Ubuntu, o Docker e um checkout do código-fonte. Instale o myapp-ctl, configure os segredos, implemente a stack e depois importe o JSON de ambiente do cliente para a app.', ca: 'Prepara un host Ubuntu, Docker i una còpia del codi font. Instal·la myapp-ctl, configura els secrets, desplega l\'stack i després importa el JSON d\'entorn del client a l\'app.', hi: 'एक Ubuntu होस्ट, Docker और एक सोर्स चेकआउट तैयार करें। myapp-ctl इंस्टॉल करें, सीक्रेट कॉन्फ़िगर करें, स्टैक परिनियोजित करें, फिर क्लाइंट एनवायरनमेंट JSON को ऐप में इम्पोर्ट करें।', ko: 'Ubuntu 호스트, Docker, 소스 체크아웃을 준비합니다. myapp-ctl을 설치하고 시크릿을 설정한 뒤 스택을 배포하고, 클라이언트 환경 JSON을 앱으로 가져옵니다.', ja: 'Ubuntu ホスト、Docker、ソースのチェックアウトを準備します。myapp-ctl をインストールし、シークレットを設定し、スタックをデプロイした後、クライアント環境 JSON をアプリにインポートします。', it: 'Prepara un host Ubuntu, Docker e un checkout del sorgente. Installa myapp-ctl, configura i segreti, distribuisci lo stack, quindi importa nell\'app il JSON dell\'ambiente client.' },
  'Backend install and first setup': { de: 'Backend-Installation und Ersteinrichtung', es: 'Instalación del backend y configuración inicial', fr: 'Installation du backend et première configuration', pt: 'Instalação do backend e configuração inicial', ca: 'Instal·lació del backend i primera configuració', hi: 'बैकएंड इंस्टॉल और प्रारंभिक सेटअप', ko: '백엔드 설치 및 초기 설정', ja: 'バックエンドのインストールと初期セットアップ', it: 'Installazione del backend e primo setup' },
  'myapp-ctl installs the control entrypoint, generates base secrets, manages AI/SMTP/push configuration, deploys Docker services and prints a client import QR code. Production secrets stay under /etc/myapp and the data root, never Git.': { de: 'myapp-ctl installiert den Steuerungs-Einstiegspunkt, generiert Basis-Secrets, verwaltet die AI-/SMTP-/Push-Konfiguration, stellt Docker-Dienste bereit und gibt einen QR-Code für den Client-Import aus. Produktions-Secrets verbleiben unter /etc/myapp und im Daten-Root, niemals in Git.', es: 'myapp-ctl instala el punto de entrada de control, genera los secretos base, gestiona la configuración de IA/SMTP/push, despliega los servicios Docker e imprime un código QR de importación para el cliente. Los secretos de producción permanecen en /etc/myapp y en el directorio raíz de datos, nunca en Git.', fr: 'myapp-ctl installe le point d\'entrée de contrôle, génère les secrets de base, gère la configuration IA/SMTP/push, déploie les services Docker et affiche un QR code d\'import client. Les secrets de production restent sous /etc/myapp et la racine des données, jamais dans Git.', pt: 'O myapp-ctl instala o ponto de entrada de controlo, gera os segredos base, gere a configuração de AI/SMTP/push, implementa os serviços Docker e imprime um código QR de importação para o cliente. Os segredos de produção ficam em /etc/myapp e na raiz de dados, nunca no Git.', ca: 'myapp-ctl instal·la el punt d\'entrada de control, genera els secrets base, gestiona la configuració d\'AI/SMTP/push, desplega els serveis Docker i imprimeix un codi QR d\'importació per al client. Els secrets de producció es queden a /etc/myapp i a l\'arrel de dades, mai a Git.', hi: 'myapp-ctl कंट्रोल एंट्रीपॉइंट इंस्टॉल करता है, बेस सीक्रेट जेनरेट करता है, AI/SMTP/पुश कॉन्फ़िगरेशन प्रबंधित करता है, Docker सेवाएँ परिनियोजित करता है और एक क्लाइंट इम्पोर्ट QR कोड प्रिंट करता है। प्रोडक्शन सीक्रेट /etc/myapp और डेटा रूट के अंतर्गत रहते हैं, कभी Git में नहीं।', ko: 'myapp-ctl은 제어 진입점을 설치하고 기본 시크릿을 생성하며 AI/SMTP/푸시 설정을 관리하고 Docker 서비스를 배포한 뒤 클라이언트 가져오기 QR 코드를 출력합니다. 프로덕션 시크릿은 /etc/myapp과 데이터 루트에만 보관되며 Git에는 절대 저장되지 않습니다.', ja: 'myapp-ctl は制御用エントリポイントをインストールし、基本シークレットを生成し、AI/SMTP/プッシュの設定を管理し、Docker サービスをデプロイして、クライアントインポート用の QR コードを出力します。本番環境のシークレットは /etc/myapp とデータルート配下に保持され、Git には保存されません。', it: 'myapp-ctl installa l\'entrypoint di controllo, genera i segreti di base, gestisce la configurazione AI/SMTP/push, distribuisce i servizi Docker e stampa un codice QR per l\'importazione nel client. I segreti di produzione restano in /etc/myapp e nella data root, mai in Git.' },
  'Client connection': { de: 'Client-Verbindung', es: 'Conexión del cliente', fr: 'Connexion du client', pt: 'Ligação do cliente', ca: 'Connexió del client', hi: 'क्लाइंट कनेक्शन', ko: '클라이언트 연결', ja: 'クライアント接続', it: 'Connessione del client' },
  'Web, iOS TestFlight and Android APK can all connect to a private backend. Open Service Environment, scan or paste the JSON printed by myapp-ctl, save and sign in again.': { de: 'Web, iOS TestFlight und Android APK können sich alle mit einem privaten Backend verbinden. Öffnen Sie die Dienstumgebung, scannen oder fügen Sie das von myapp-ctl ausgegebene JSON ein, speichern Sie und melden Sie sich erneut an.', es: 'Web, iOS TestFlight y el APK de Android pueden conectarse a un backend privado. Abre el Entorno de servicio, escanea o pega el JSON que imprime myapp-ctl, guarda e inicia sesión de nuevo.', fr: 'Web, iOS TestFlight et l\'APK Android peuvent tous se connecter à un backend privé. Ouvrez Environnement de service, scannez ou collez le JSON affiché par myapp-ctl, enregistrez et reconnectez-vous.', pt: 'A Web, o iOS TestFlight e o APK Android podem todos ligar-se a um backend privado. Abra o Ambiente de Serviço, leia ou cole o JSON impresso pelo myapp-ctl, guarde e inicie sessão novamente.', ca: 'Web, iOS TestFlight i l\'APK d\'Android poden connectar-se a un backend privat. Obre Entorn de servei, escaneja o enganxa el JSON imprès per myapp-ctl, desa-ho i torna a iniciar la sessió.', hi: 'Web, iOS TestFlight और Android APK सभी एक निजी बैकएंड से कनेक्ट हो सकते हैं। Service Environment खोलें, myapp-ctl द्वारा प्रिंट किए गए JSON को स्कैन या पेस्ट करें, सहेजें और फिर से साइन इन करें।', ko: 'Web, iOS TestFlight, Android APK 모두 프라이빗 백엔드에 연결할 수 있습니다. 서비스 환경을 열고 myapp-ctl이 출력한 JSON을 스캔하거나 붙여넣은 뒤 저장하고 다시 로그인하세요.', ja: 'Web、iOS TestFlight、Android APK はすべてプライベートバックエンドに接続できます。サービス環境を開き、myapp-ctl が出力した JSON をスキャンまたは貼り付け、保存して再度サインインします。', it: 'Web, iOS TestFlight e APK Android possono tutti connettersi a un backend privato. Apri Ambiente di servizio, scansiona o incolla il JSON stampato da myapp-ctl, salva e accedi di nuovo.' },
  'Client and website builds': { de: 'Client- und Website-Builds', es: 'Compilaciones del cliente y del sitio web', fr: 'Builds du client et du site web', pt: 'Builds do cliente e do site', ca: 'Builds del client i del lloc web', hi: 'क्लाइंट और वेबसाइट बिल्ड', ko: '클라이언트 및 웹사이트 빌드', ja: 'クライアントとウェブサイトのビルド', it: 'Build del client e del sito web' },
  'Website deployment': { de: 'Website-Bereitstellung', es: 'Despliegue del sitio web', fr: 'Déploiement du site web', pt: 'Implementação do site', ca: 'Desplegament del lloc web', hi: 'वेबसाइट परिनियोजन', ko: '웹사이트 배포', ja: 'ウェブサイトのデプロイ', it: 'Deployment del sito web' },
  'Release and distribution': { de: 'Release und Verteilung', es: 'Publicación y distribución', fr: 'Publication et distribution', pt: 'Lançamento e distribuição', ca: 'Publicació i distribució', hi: 'रिलीज़ और वितरण', ko: '릴리스 및 배포', ja: 'リリースと配布', it: 'Release e distribuzione' },
  'JSON Apps are published through Registry and stored in OSS/MinIO. Android APK uploads through config center to a fixed object path. Flutter Web client builds to build/web; this marketing website is the Vite app under website. iOS is distributed through TestFlight.': { de: 'JSON-Apps werden über die Registry veröffentlicht und in OSS/MinIO gespeichert. Das Android-APK wird über die Konfigurationszentrale auf einen festen Objektpfad hochgeladen. Der Flutter-Web-Client baut nach build/web; diese Marketing-Website ist die Vite-App unter website. iOS wird über TestFlight verteilt.', es: 'Las Apps JSON se publican a través de Registry y se almacenan en OSS/MinIO. El APK de Android se sube mediante el centro de configuración a una ruta de objeto fija. El cliente Flutter Web se compila en build/web; este sitio web de marketing es la app Vite ubicada en website. iOS se distribuye a través de TestFlight.', fr: 'Les Apps JSON sont publiées via Registry et stockées dans OSS/MinIO. L\'APK Android est téléversé via le centre de configuration vers un chemin d\'objet fixe. Le client Flutter Web se compile vers build/web ; ce site marketing est l\'app Vite sous website. iOS est distribué via TestFlight.', pt: 'Os JSON Apps são publicados através do Registry e armazenados em OSS/MinIO. O APK Android é carregado através do centro de configuração para um caminho de objeto fixo. O cliente Flutter Web é compilado para build/web; este site de marketing é a app Vite em website. O iOS é distribuído através do TestFlight.', ca: 'Les JSON Apps es publiquen mitjançant Registry i s\'emmagatzemen a OSS/MinIO. L\'APK d\'Android es puja a través del centre de configuració a una ruta d\'objecte fixa. El client Flutter Web es construeix a build/web; aquest lloc web de màrqueting és l\'app Vite dins de website. iOS es distribueix mitjançant TestFlight.', hi: 'JSON ऐप Registry के माध्यम से प्रकाशित होते हैं और OSS/MinIO में संग्रहीत होते हैं। Android APK कॉन्फ़िग केंद्र के माध्यम से एक निश्चित ऑब्जेक्ट पथ पर अपलोड होता है। Flutter Web क्लाइंट build/web में बिल्ड होता है; यह मार्केटिंग वेबसाइट website के अंतर्गत Vite ऐप है। iOS को TestFlight के माध्यम से वितरित किया जाता है।', ko: 'JSON App은 Registry를 통해 게시되고 OSS/MinIO에 저장됩니다. Android APK는 설정 센터를 통해 고정된 오브젝트 경로로 업로드됩니다. Flutter Web 클라이언트는 build/web으로 빌드되며, 이 마케팅 웹사이트는 website 아래의 Vite 앱입니다. iOS는 TestFlight를 통해 배포됩니다.', ja: 'JSON アプリは Registry を通じて公開され、OSS/MinIO に保存されます。Android APK は構成センター経由で固定のオブジェクトパスにアップロードされます。Flutter Web クライアントは build/web にビルドされ、このマーケティングサイトは website 配下の Vite アプリです。iOS は TestFlight で配布されます。', it: 'Le App JSON vengono pubblicate tramite Registry e archiviate in OSS/MinIO. L\'APK Android viene caricato tramite il centro di configurazione in un percorso oggetto fisso. Il client Flutter Web compila in build/web; questo sito di marketing è l\'app Vite nella cartella website. iOS viene distribuito tramite TestFlight.' },
  'Configuration and security boundary': { de: 'Konfigurations- und Sicherheitsgrenze', es: 'Configuración y límite de seguridad', fr: 'Configuration et périmètre de sécurité', pt: 'Fronteira de configuração e segurança', ca: 'Límit de configuració i seguretat', hi: 'कॉन्फ़िगरेशन और सुरक्षा सीमा', ko: '설정 및 보안 경계', ja: '構成とセキュリティの境界', it: 'Confine di configurazione e sicurezza' },
  'AI produces declarative JSON, not Dart, Swift, Kotlin, plugins or binaries. The runtime only interprets generic widgets, actions and media capabilities already compiled into the client.': { de: 'Die AI erzeugt deklaratives JSON, kein Dart, Swift, Kotlin, keine Plugins oder Binärdateien. Die Laufzeit interpretiert nur generische Widgets, Aktionen und Medienfunktionen, die bereits in den Client kompiliert sind.', es: 'La IA produce JSON declarativo, no Dart, Swift, Kotlin, plugins ni binarios. El entorno de ejecución solo interpreta widgets, acciones y capacidades multimedia genéricas ya compiladas en el cliente.', fr: 'L\'IA produit du JSON déclaratif, et non du Dart, Swift, Kotlin, des plugins ou des binaires. Le runtime interprète uniquement les widgets, actions et capacités média génériques déjà compilés dans le client.', pt: 'A IA produz JSON declarativo, não Dart, Swift, Kotlin, plugins ou binários. O runtime apenas interpreta widgets genéricos, ações e capacidades multimédia já compilados no cliente.', ca: 'La IA produeix JSON declaratiu, no Dart, Swift, Kotlin, plugins ni binaris. L\'entorn d\'execució només interpreta widgets, accions i capacitats multimèdia genèrics ja compilats dins del client.', hi: 'AI घोषणात्मक JSON तैयार करती है, Dart, Swift, Kotlin, प्लगइन या बाइनरी नहीं। रनटाइम केवल उन सामान्य विजेट, एक्शन और मीडिया क्षमताओं की व्याख्या करता है जो पहले से क्लाइंट में कंपाइल हैं।', ko: 'AI는 Dart, Swift, Kotlin, 플러그인 또는 바이너리가 아닌 선언형 JSON을 생성합니다. 런타임은 이미 클라이언트에 컴파일된 범용 위젯, 액션, 미디어 기능만 해석합니다.', ja: 'AI が生成するのは宣言的な JSON であり、Dart、Swift、Kotlin、プラグイン、バイナリではありません。ランタイムは、すでにクライアントにコンパイルされている汎用ウィジェット、アクション、メディア機能のみを解釈します。', it: 'L\'IA produce JSON dichiarativo, non Dart, Swift, Kotlin, plugin o binari. Il runtime interpreta solo widget, azioni e funzionalità media generici già compilati nel client.' },
  'Install control CLI': { de: 'Steuerungs-CLI installieren', es: 'Instalar la CLI de control', fr: 'Installer la CLI de contrôle', pt: 'Instalar a CLI de controlo', ca: 'Instal·la la CLI de control', hi: 'कंट्रोल CLI इंस्टॉल करें', ko: '제어 CLI 설치', ja: '制御 CLI をインストールする', it: 'Installa la CLI di controllo' },
  'Run install_ctl.sh from the source root; myapp-ctl records that checkout as the build context.': { de: 'Führen Sie install_ctl.sh aus dem Source-Root aus; myapp-ctl merkt sich dieses Checkout als Build-Kontext.', es: 'Ejecuta install_ctl.sh desde la raíz del código fuente; myapp-ctl registra esa copia como contexto de compilación.', fr: 'Exécutez install_ctl.sh depuis la racine des sources ; myapp-ctl enregistre ce checkout comme contexte de build.', pt: 'Execute o install_ctl.sh a partir da raiz do código-fonte; o myapp-ctl regista esse checkout como o contexto de build.', ca: 'Executa install_ctl.sh des de l\'arrel del codi font; myapp-ctl registra aquesta còpia com a context de build.', hi: 'सोर्स रूट से install_ctl.sh चलाएँ; myapp-ctl उस चेकआउट को बिल्ड कॉन्टेक्स्ट के रूप में रिकॉर्ड करता है।', ko: '소스 루트에서 install_ctl.sh를 실행하세요. myapp-ctl은 해당 체크아웃을 빌드 컨텍스트로 기록합니다.', ja: 'ソースルートで install_ctl.sh を実行します。myapp-ctl はそのチェックアウトをビルドコンテキストとして記録します。', it: 'Esegui install_ctl.sh dalla radice del sorgente; myapp-ctl registra quel checkout come contesto di build.' },
  'Configure secrets': { de: 'Secrets konfigurieren', es: 'Configurar secretos', fr: 'Configurer les secrets', pt: 'Configurar segredos', ca: 'Configura els secrets', hi: 'सीक्रेट कॉन्फ़िगर करें', ko: '시크릿 설정', ja: 'シークレットを設定する', it: 'Configura i segreti' },
  'setup configures language, data root, AI providers, SMTP, APNs, FCM and GeTui.': { de: 'setup konfiguriert Sprache, Daten-Root, AI-Anbieter, SMTP, APNs, FCM und GeTui.', es: 'setup configura el idioma, el directorio raíz de datos, los proveedores de IA, SMTP, APNs, FCM y GeTui.', fr: 'setup configure la langue, la racine des données, les fournisseurs IA, SMTP, APNs, FCM et GeTui.', pt: 'O setup configura o idioma, a raiz de dados, os fornecedores de IA, SMTP, APNs, FCM e GeTui.', ca: 'setup configura l\'idioma, l\'arrel de dades, els proveïdors d\'IA, SMTP, APNs, FCM i GeTui.', hi: 'setup भाषा, डेटा रूट, AI प्रोवाइडर, SMTP, APNs, FCM और GeTui कॉन्फ़िगर करता है।', ko: 'setup은 언어, 데이터 루트, AI 제공자, SMTP, APNs, FCM, GeTui를 설정합니다.', ja: 'setup は言語、データルート、AI プロバイダー、SMTP、APNs、FCM、GeTui を設定します。', it: 'setup configura lingua, data root, provider IA, SMTP, APNs, FCM e GeTui.' },
  'Deploy services': { de: 'Dienste bereitstellen', es: 'Desplegar servicios', fr: 'Déployer les services', pt: 'Implementar serviços', ca: 'Desplega els serveis', hi: 'सेवाएँ परिनियोजित करें', ko: '서비스 배포', ja: 'サービスをデプロイする', it: 'Distribuisci i servizi' },
  'deploy --build builds from source; deploy --pull uses published images.': { de: 'deploy --build baut aus dem Quellcode; deploy --pull verwendet veröffentlichte Images.', es: 'deploy --build compila desde el código fuente; deploy --pull usa imágenes publicadas.', fr: 'deploy --build compile depuis les sources ; deploy --pull utilise les images publiées.', pt: 'deploy --build compila a partir do código-fonte; deploy --pull usa imagens publicadas.', ca: 'deploy --build construeix des del codi font; deploy --pull utilitza imatges publicades.', hi: 'deploy --build सोर्स से बिल्ड करता है; deploy --pull प्रकाशित इमेज का उपयोग करता है।', ko: 'deploy --build는 소스에서 빌드하고, deploy --pull은 게시된 이미지를 사용합니다.', ja: 'deploy --build はソースからビルドし、deploy --pull は公開済みイメージを使用します。', it: 'deploy --build compila dal sorgente; deploy --pull usa le immagini pubblicate.' },
  'Connect clients': { de: 'Clients verbinden', es: 'Conectar clientes', fr: 'Connecter les clients', pt: 'Ligar clientes', ca: 'Connecta els clients', hi: 'क्लाइंट कनेक्ट करें', ko: '클라이언트 연결', ja: 'クライアントを接続する', it: 'Connetti i client' },
  'client-env prints JSON and a QR code; import it in the client and sign in again.': { de: 'client-env gibt JSON und einen QR-Code aus; importieren Sie ihn im Client und melden Sie sich erneut an.', es: 'client-env imprime un JSON y un código QR; impórtalo en el cliente e inicia sesión de nuevo.', fr: 'client-env affiche du JSON et un QR code ; importez-le dans le client et reconnectez-vous.', pt: 'O client-env imprime o JSON e um código QR; importe-o no cliente e inicie sessão novamente.', ca: 'client-env imprimeix el JSON i un codi QR; importa\'l al client i torna a iniciar la sessió.', hi: 'client-env JSON और एक QR कोड प्रिंट करता है; इसे क्लाइंट में इम्पोर्ट करें और फिर से साइन इन करें।', ko: 'client-env는 JSON과 QR 코드를 출력합니다. 클라이언트에서 가져온 뒤 다시 로그인하세요.', ja: 'client-env は JSON と QR コードを出力します。クライアントにインポートして再度サインインします。', it: 'client-env stampa il JSON e un codice QR; importalo nel client e accedi di nuovo.' },
  'Core services': { de: 'Kerndienste', es: 'Servicios principales', fr: 'Services principaux', pt: 'Serviços principais', ca: 'Serveis principals', hi: 'कोर सेवाएँ', ko: '핵심 서비스', ja: 'コアサービス', it: 'Servizi core' },
  'backend, ai-worker, Registry, Config Center and User Center': { de: 'backend, ai-worker, Registry, Config Center und User Center', es: 'backend, ai-worker, Registry, Config Center y User Center', fr: 'backend, ai-worker, Registry, Config Center et User Center', pt: 'backend, ai-worker, Registry, Config Center e User Center', ca: 'backend, ai-worker, Registry, Config Center i User Center', hi: 'backend, ai-worker, Registry, Config Center और User Center', ko: 'backend, ai-worker, Registry, Config Center, User Center', ja: 'backend、ai-worker、Registry、Config Center、User Center', it: 'backend, ai-worker, Registry, Config Center e User Center' },
  'Infrastructure': { de: 'Infrastruktur', es: 'Infraestructura', fr: 'Infrastructure', pt: 'Infraestrutura', ca: 'Infraestructura', hi: 'इन्फ्रास्ट्रक्चर', ko: '인프라', ja: 'インフラストラクチャ', it: 'Infrastruttura' },
  'JSON App Postgres, AI Redis, App MinIO, Supabase and OpenIM': { de: 'JSON-App-Postgres, AI-Redis, App-MinIO, Supabase und OpenIM', es: 'Postgres de Apps JSON, Redis de IA, App MinIO, Supabase y OpenIM', fr: 'Postgres des Apps JSON, Redis IA, MinIO de l\'app, Supabase et OpenIM', pt: 'Postgres do JSON App, Redis da IA, MinIO da App, Supabase e OpenIM', ca: 'Postgres de JSON App, Redis d\'IA, MinIO d\'App, Supabase i OpenIM', hi: 'JSON ऐप Postgres, AI Redis, App MinIO, Supabase और OpenIM', ko: 'JSON App용 Postgres, AI용 Redis, App MinIO, Supabase, OpenIM', ja: 'JSON アプリ用 Postgres、AI 用 Redis、アプリ用 MinIO、Supabase、OpenIM', it: 'Postgres delle App JSON, Redis IA, MinIO dell\'app, Supabase e OpenIM' },
  'AI execution': { de: 'AI-Ausführung', es: 'Ejecución de IA', fr: 'Exécution IA', pt: 'Execução de IA', ca: 'Execució d\'IA', hi: 'AI निष्पादन', ko: 'AI 실행', ja: 'AI 実行', it: 'Esecuzione IA' },
  'agent-node schedules Docker runtimes; Claude/Codex run inside isolated Ubuntu containers': { de: 'agent-node plant Docker-Laufzeiten; Claude/Codex laufen in isolierten Ubuntu-Containern', es: 'agent-node programa los entornos Docker; Claude/Codex se ejecutan dentro de contenedores Ubuntu aislados', fr: 'agent-node planifie les runtimes Docker ; Claude/Codex s\'exécutent dans des conteneurs Ubuntu isolés', pt: 'O agent-node agenda runtimes Docker; o Claude/Codex correm dentro de contentores Ubuntu isolados', ca: 'agent-node planifica entorns Docker; Claude/Codex s\'executen dins de contenidors Ubuntu aïllats', hi: 'agent-node Docker रनटाइम शेड्यूल करता है; Claude/Codex अलग-थलग Ubuntu कंटेनरों के अंदर चलते हैं', ko: 'agent-node가 Docker 런타임을 스케줄링하며, Claude/Codex는 격리된 Ubuntu 컨테이너 내부에서 실행됩니다', ja: 'agent-node が Docker ランタイムをスケジューリングし、Claude/Codex は隔離された Ubuntu コンテナ内で実行されます', it: 'agent-node pianifica i runtime Docker; Claude/Codex girano in container Ubuntu isolati' },
  'Persistent data': { de: 'Persistente Daten', es: 'Datos persistentes', fr: 'Données persistantes', pt: 'Dados persistentes', ca: 'Dades persistents', hi: 'स्थायी डेटा', ko: '영구 데이터', ja: '永続データ', it: 'Dati persistenti' },
  'Default data root is /mnt/myapp; databases and object stores use local bind mounts': { de: 'Der Standard-Daten-Root ist /mnt/myapp; Datenbanken und Objektspeicher verwenden lokale Bind-Mounts', es: 'El directorio raíz de datos por defecto es /mnt/myapp; las bases de datos y los almacenes de objetos usan bind mounts locales', fr: 'La racine des données par défaut est /mnt/myapp ; les bases de données et les stores d\'objets utilisent des bind mounts locaux', pt: 'A raiz de dados predefinida é /mnt/myapp; as bases de dados e os armazenamentos de objetos usam bind mounts locais', ca: 'L\'arrel de dades per defecte és /mnt/myapp; les bases de dades i els magatzems d\'objectes utilitzen bind mounts locals', hi: 'डिफ़ॉल्ट डेटा रूट /mnt/myapp है; डेटाबेस और ऑब्जेक्ट स्टोर लोकल बाइंड माउंट का उपयोग करते हैं', ko: '기본 데이터 루트는 /mnt/myapp이며, 데이터베이스와 오브젝트 스토어는 로컬 바인드 마운트를 사용합니다', ja: 'デフォルトのデータルートは /mnt/myapp です。データベースとオブジェクトストアはローカルのバインドマウントを使用します', it: 'La data root predefinita è /mnt/myapp; database e object store usano bind mount locali' },
  'Refresh control files': { de: 'Steuerungsdateien aktualisieren', es: 'Actualizar los archivos de control', fr: 'Rafraîchir les fichiers de contrôle', pt: 'Atualizar ficheiros de controlo', ca: 'Actualitza els fitxers de control', hi: 'कंट्रोल फ़ाइलें रिफ़्रेश करें', ko: '제어 파일 새로 고침', ja: '制御ファイルを更新する', it: 'Aggiorna i file di controllo' },
  'Backend routes only': { de: 'Nur Backend-Routen', es: 'Solo rutas del backend', fr: 'Routes backend uniquement', pt: 'Apenas rotas do backend', ca: 'Només les rutes del backend', hi: 'केवल बैकएंड रूट', ko: '백엔드 라우트만', ja: 'バックエンドのルートのみ', it: 'Solo route del backend' },
  'Worker / prompts / validators': { de: 'Worker / Prompts / Validatoren', es: 'Worker / prompts / validadores', fr: 'Worker / prompts / validateurs', pt: 'Worker / prompts / validadores', ca: 'Worker / prompts / validadors', hi: 'Worker / prompts / validators', ko: '워커 / 프롬프트 / 검증기', ja: 'ワーカー / プロンプト / バリデーター', it: 'Worker / prompt / validatori' },
  'agent-node changes': { de: 'agent-node-Änderungen', es: 'Cambios en agent-node', fr: 'Modifications d\'agent-node', pt: 'Alterações ao agent-node', ca: 'Canvis a agent-node', hi: 'agent-node में बदलाव', ko: 'agent-node 변경', ja: 'agent-node の変更', it: 'Modifiche ad agent-node' },
  'Runtime image changes': { de: 'Änderungen am Laufzeit-Image', es: 'Cambios en la imagen de ejecución', fr: 'Modifications de l\'image runtime', pt: 'Alterações à imagem de runtime', ca: 'Canvis a la imatge d\'execució', hi: 'रनटाइम इमेज में बदलाव', ko: '런타임 이미지 변경', ja: 'ランタイムイメージの変更', it: 'Modifiche all\'immagine di runtime' },
  'Image-based host': { de: 'Image-basierter Host', es: 'Host basado en imágenes', fr: 'Hôte basé sur images', pt: 'Host baseado em imagens', ca: 'Host basat en imatges', hi: 'इमेज-आधारित होस्ट', ko: '이미지 기반 호스트', ja: 'イメージベースのホスト', it: 'Host basato su immagini' },
  'Service operations': { de: 'Dienstbetrieb', es: 'Operaciones de servicio', fr: 'Opérations sur les services', pt: 'Operações de serviço', ca: 'Operacions de serveis', hi: 'सेवा संचालन', ko: '서비스 운영', ja: 'サービス運用', it: 'Operazioni sui servizi' },
  'Secrets and config': { de: 'Secrets und Konfiguration', es: 'Secretos y configuración', fr: 'Secrets et configuration', pt: 'Segredos e configuração', ca: 'Secrets i configuració', hi: 'सीक्रेट और कॉन्फ़िग', ko: '시크릿 및 설정', ja: 'シークレットと構成', it: 'Segreti e configurazione' },
  'Backup and restore': { de: 'Sicherung und Wiederherstellung', es: 'Copia de seguridad y restauración', fr: 'Sauvegarde et restauration', pt: 'Cópia de segurança e restauro', ca: 'Còpia de seguretat i restauració', hi: 'बैकअप और रिस्टोर', ko: '백업 및 복원', ja: 'バックアップと復元', it: 'Backup e ripristino' },
  'Uninstall': { de: 'Deinstallieren', es: 'Desinstalar', fr: 'Désinstaller', pt: 'Desinstalar', ca: 'Desinstal·la', hi: 'अनइंस्टॉल', ko: '제거', ja: 'アンインストール', it: 'Disinstallazione' },
  '# config and data root are preserved; manually rm -rf /mnt/myapp only when destroying data': { de: '# Konfiguration und Daten-Root bleiben erhalten; manuelles rm -rf /mnt/myapp nur beim Löschen der Daten', es: '# la configuración y el directorio raíz de datos se conservan; ejecuta manualmente rm -rf /mnt/myapp solo cuando quieras destruir los datos', fr: '# la config et la racine des données sont conservées ; n\'exécutez rm -rf /mnt/myapp manuellement que pour détruire les données', pt: '# a configuração e a raiz de dados são preservadas; faça rm -rf /mnt/myapp manualmente apenas ao destruir os dados', ca: '# la configuració i l\'arrel de dades es conserven; fes rm -rf /mnt/myapp manualment només quan vulguis destruir les dades', hi: '# कॉन्फ़िग और डेटा रूट सुरक्षित रहते हैं; डेटा नष्ट करते समय ही मैन्युअल रूप से rm -rf /mnt/myapp चलाएँ', ko: '# 설정과 데이터 루트는 보존됩니다. 데이터를 완전히 삭제할 때만 수동으로 rm -rf /mnt/myapp을 실행하세요', ja: '# 構成とデータルートは保持されます。データを完全に削除する場合のみ手動で rm -rf /mnt/myapp を実行してください', it: '# config e data root vengono conservati; esegui manualmente rm -rf /mnt/myapp solo per eliminare i dati' },
  'Lifecycle and services': { de: 'Lebenszyklus und Dienste', es: 'Ciclo de vida y servicios', fr: 'Cycle de vie et services', pt: 'Ciclo de vida e serviços', ca: 'Cicle de vida i serveis', hi: 'लाइफ़साइकल और सेवाएँ', ko: '라이프사이클 및 서비스', ja: 'ライフサイクルとサービス', it: 'Ciclo di vita e servizi' },
  'Deploy, update, restart, logs and uninstall. Targets can be service names, or use --group with infra / supabase / openim / agent / core.': { de: 'Bereitstellen, aktualisieren, neu starten, Logs und deinstallieren. Ziele können Dienstnamen sein, oder verwenden Sie --group mit infra / supabase / openim / agent / core.', es: 'Desplegar, actualizar, reiniciar, ver logs y desinstalar. Los destinos pueden ser nombres de servicio, o usa --group con infra / supabase / openim / agent / core.', fr: 'Déployer, mettre à jour, redémarrer, consulter les logs et désinstaller. Les cibles peuvent être des noms de services, ou utilisez --group avec infra / supabase / openim / agent / core.', pt: 'Implementar, atualizar, reiniciar, ver logs e desinstalar. Os alvos podem ser nomes de serviços ou usar --group com infra / supabase / openim / agent / core.', ca: 'Desplega, actualitza, reinicia, registres i desinstal·la. Els objectius poden ser noms de servei, o pots fer servir --group amb infra / supabase / openim / agent / core.', hi: 'परिनियोजित, अपडेट, रीस्टार्ट, लॉग और अनइंस्टॉल करें। टारगेट सेवा के नाम हो सकते हैं, या infra / supabase / openim / agent / core के साथ --group का उपयोग करें।', ko: '배포, 업데이트, 재시작, 로그, 제거. 대상은 서비스 이름이거나 --group과 함께 infra / supabase / openim / agent / core를 사용할 수 있습니다.', ja: 'デプロイ、更新、再起動、ログ、アンインストール。対象にはサービス名を指定するか、--group で infra / supabase / openim / agent / core を使用できます。', it: 'Distribuisci, aggiorna, riavvia, log e disinstalla. I target possono essere nomi di servizio, oppure usa --group con infra / supabase / openim / agent / core.' },
  'Setup and secrets': { de: 'Einrichtung und Secrets', es: 'Configuración y secretos', fr: 'Configuration et secrets', pt: 'Configuração e segredos', ca: 'Configuració i secrets', hi: 'सेटअप और सीक्रेट', ko: '설정 및 시크릿', ja: 'セットアップとシークレット', it: 'Setup e segreti' },
  'setup is the interactive entrypoint; secret manages host-local credentials. Do not put production secrets in Git.': { de: 'setup ist der interaktive Einstiegspunkt; secret verwaltet host-lokale Zugangsdaten. Legen Sie keine Produktions-Secrets in Git ab.', es: 'setup es el punto de entrada interactivo; secret gestiona las credenciales locales del host. No pongas secretos de producción en Git.', fr: 'setup est le point d\'entrée interactif ; secret gère les identifiants locaux à l\'hôte. Ne placez pas les secrets de production dans Git.', pt: 'O setup é o ponto de entrada interativo; o secret gere as credenciais locais do host. Não coloque segredos de produção no Git.', ca: 'setup és el punt d\'entrada interactiu; secret gestiona les credencials locals del host. No posis secrets de producció a Git.', hi: 'setup इंटरैक्टिव एंट्रीपॉइंट है; secret होस्ट-लोकल क्रेडेंशियल प्रबंधित करता है। प्रोडक्शन सीक्रेट को Git में न रखें।', ko: 'setup은 대화형 진입점이며, secret은 호스트 로컬 자격 증명을 관리합니다. 프로덕션 시크릿을 Git에 넣지 마세요.', ja: 'setup は対話型のエントリポイントで、secret はホストローカルの資格情報を管理します。本番環境のシークレットを Git に置かないでください。', it: 'setup è l\'entrypoint interattivo; secret gestisce le credenziali locali dell\'host. Non mettere i segreti di produzione in Git.' },
  'Config, domains and client env': { de: 'Konfiguration, Domains und Client-Umgebung', es: 'Configuración, dominios y entorno del cliente', fr: 'Config, domaines et environnement client', pt: 'Configuração, domínios e ambiente do cliente', ca: 'Configuració, dominis i entorn del client', hi: 'कॉन्फ़िग, डोमेन और क्लाइंट env', ko: '설정, 도메인, 클라이언트 환경', ja: '構成、ドメイン、クライアント環境', it: 'Configurazione, domini e ambiente client' },
  'Config bundles are used for migration and recovery; client-env prints importable client JSON and QR codes.': { de: 'Konfigurations-Bundles dienen der Migration und Wiederherstellung; client-env gibt importierbares Client-JSON und QR-Codes aus.', es: 'Los paquetes de configuración se usan para migración y recuperación; client-env imprime el JSON del cliente y los códigos QR importables.', fr: 'Les bundles de configuration servent à la migration et à la reprise ; client-env affiche du JSON client importable et des QR codes.', pt: 'Os pacotes de configuração são usados para migração e recuperação; o client-env imprime JSON e códigos QR de cliente importáveis.', ca: 'Els paquets de configuració s\'utilitzen per a la migració i la recuperació; client-env imprimeix JSON i codis QR del client importables.', hi: 'कॉन्फ़िग बंडल माइग्रेशन और रिकवरी के लिए उपयोग होते हैं; client-env इम्पोर्ट योग्य क्लाइंट JSON और QR कोड प्रिंट करता है।', ko: '설정 번들은 마이그레이션과 복구에 사용됩니다. client-env는 가져올 수 있는 클라이언트 JSON과 QR 코드를 출력합니다.', ja: '構成バンドルは移行と復旧に使用します。client-env はインポート可能なクライアント JSON と QR コードを出力します。', it: 'I bundle di configurazione servono per migrazione e ripristino; client-env stampa JSON e codici QR del client importabili.' },
  'Images': { de: 'Images', es: 'Imágenes', fr: 'Images', pt: 'Imagens', ca: 'Imatges', hi: 'इमेज', ko: '이미지', ja: 'イメージ', it: 'Immagini' },
  'Current image targets are all, backend, agent-node and agent-runtime. --build uses source; --pull uses published images.': { de: 'Aktuelle Image-Ziele sind all, backend, agent-node und agent-runtime. --build verwendet den Quellcode; --pull verwendet veröffentlichte Images.', es: 'Los destinos de imagen actuales son all, backend, agent-node y agent-runtime. --build usa el código fuente; --pull usa imágenes publicadas.', fr: 'Les cibles d\'images actuelles sont all, backend, agent-node et agent-runtime. --build utilise les sources ; --pull utilise les images publiées.', pt: 'Os alvos de imagem atuais são all, backend, agent-node e agent-runtime. --build usa o código-fonte; --pull usa imagens publicadas.', ca: 'Els objectius d\'imatge actuals són all, backend, agent-node i agent-runtime. --build utilitza el codi font; --pull utilitza imatges publicades.', hi: 'वर्तमान इमेज टारगेट हैं all, backend, agent-node और agent-runtime। --build सोर्स का उपयोग करता है; --pull प्रकाशित इमेज का उपयोग करता है।', ko: '현재 이미지 대상은 all, backend, agent-node, agent-runtime입니다. --build는 소스를 사용하고, --pull은 게시된 이미지를 사용합니다.', ja: '現在のイメージ対象は all、backend、agent-node、agent-runtime です。--build はソースを使用し、--pull は公開済みイメージを使用します。', it: 'I target di immagine attuali sono all, backend, agent-node e agent-runtime. --build usa il sorgente; --pull usa le immagini pubblicate.' },
  'Public Agent Node': { de: 'Öffentliche Agent Node', es: 'Agent Node público', fr: 'Agent Node public', pt: 'Agent Node público', ca: 'Agent Node públic', hi: 'सार्वजनिक Agent Node', ko: '공용 Agent Node', ja: 'パブリック Agent Node', it: 'Agent Node pubblico' },
  'agent-node ls is the cluster view; agent ls is local-only and shows running agent containers on this host.': { de: 'agent-node ls ist die Cluster-Ansicht; agent ls ist rein lokal und zeigt laufende Agent-Container auf diesem Host.', es: 'agent-node ls es la vista del clúster; agent ls es solo local y muestra los contenedores de agente en ejecución en este host.', fr: 'agent-node ls donne la vue du cluster ; agent ls est local uniquement et affiche les conteneurs d\'agents en cours d\'exécution sur cet hôte.', pt: 'O agent-node ls é a vista do cluster; o agent ls é apenas local e mostra os contentores de agente em execução neste host.', ca: 'agent-node ls és la vista del clúster; agent ls és només local i mostra els contenidors d\'agent en execució en aquest host.', hi: 'agent-node ls क्लस्टर व्यू है; agent ls केवल लोकल है और इस होस्ट पर चल रहे एजेंट कंटेनर दिखाता है।', ko: 'agent-node ls는 클러스터 뷰이며, agent ls는 로컬 전용으로 이 호스트에서 실행 중인 에이전트 컨테이너를 보여줍니다.', ja: 'agent-node ls はクラスター全体のビューで、agent ls はローカル専用で、このホスト上で稼働中のエージェントコンテナを表示します。', it: 'agent-node ls è la vista del cluster; agent ls è solo locale e mostra i container agente in esecuzione su questo host.' },
  'User-private Agent Node': { de: 'Benutzerprivate Agent Node', es: 'Agent Node privado del usuario', fr: 'Agent Node privé à l\'utilisateur', pt: 'Agent Node privado do utilizador', ca: 'Agent Node privat d\'usuari', hi: 'उपयोगकर्ता-निजी Agent Node', ko: '사용자 전용 Agent Node', ja: 'ユーザー専用 Agent Node', it: 'Agent Node privato dell\'utente' },
  'Private nodes serve only their owner, and long-lived provider keys stay on the node host. The app settings page creates a one-time join token and command.': { de: 'Private Nodes bedienen nur ihren Eigentümer, und langlebige Anbieter-Schlüssel verbleiben auf dem Node-Host. Die Einstellungsseite der App erstellt ein einmaliges Beitritts-Token und den zugehörigen Befehl.', es: 'Los nodos privados sirven únicamente a su propietario, y las claves de proveedor de larga duración permanecen en el host del nodo. La página de ajustes de la app crea un token y un comando de unión de un solo uso.', fr: 'Les nœuds privés ne servent que leur propriétaire, et les clés de fournisseur à longue durée de vie restent sur l\'hôte du nœud. La page de paramètres de l\'app crée un jeton et une commande de jonction à usage unique.', pt: 'Os nós privados servem apenas o seu proprietário e as chaves de fornecedor de longa duração ficam no host do nó. A página de definições da app cria um token e comando de adesão de utilização única.', ca: 'Els nodes privats només serveixen el seu propietari, i les claus de proveïdor de llarga durada es queden al host del node. La pàgina de configuració de l\'app crea un token i una ordre d\'incorporació d\'un sol ús.', hi: 'निजी नोड केवल अपने मालिक की सेवा करते हैं, और दीर्घकालिक प्रोवाइडर की नोड होस्ट पर ही रहती हैं। ऐप की सेटिंग पेज एक बार उपयोग होने वाला join टोकन और कमांड बनाती है।', ko: '프라이빗 노드는 소유자에게만 서비스를 제공하며, 장기 제공자 키는 노드 호스트에 남아 있습니다. 앱 설정 페이지에서 일회용 조인 토큰과 명령을 생성합니다.', ja: 'プライベートノードは所有者のみにサービスを提供し、長期間有効なプロバイダーキーはノードホスト上に保持されます。アプリの設定ページで 1 回限りの参加トークンとコマンドを作成します。', it: 'I nodi privati servono solo il loro proprietario e le chiavi provider a lunga durata restano sull\'host del nodo. La pagina delle impostazioni dell\'app crea un token e un comando di join monouso.' },
  'Open Web app': { de: 'Web-App öffnen', es: 'Abrir la app Web', fr: 'Ouvrir l\'app Web', pt: 'Abrir a app Web', ca: 'Obre l\'app web', hi: 'Web ऐप खोलें', ko: 'Web 앱 열기', ja: 'Web アプリを開く', it: 'Apri l\'app Web' },
  'Architecture': { de: 'Architektur', es: 'Arquitectura', fr: 'Architecture', pt: 'Arquitetura', ca: 'Arquitectura', hi: 'आर्किटेक्चर', ko: '아키텍처', ja: 'アーキテクチャ', it: 'Architettura' },
  'Install': { de: 'Installation', es: 'Instalar', fr: 'Installation', pt: 'Instalar', ca: 'Instal·lació', hi: 'इंस्टॉल', ko: '설치', ja: 'インストール', it: 'Installazione' },
  'Operations': { de: 'Betrieb', es: 'Operaciones', fr: 'Opérations', pt: 'Operações', ca: 'Operacions', hi: 'संचालन', ko: '운영', ja: '運用', it: 'Operazioni' },
  'CLI reference': { de: 'CLI-Referenz', es: 'Referencia de la CLI', fr: 'Référence CLI', pt: 'Referência da CLI', ca: 'Referència de la CLI', hi: 'CLI संदर्भ', ko: 'CLI 레퍼런스', ja: 'CLI リファレンス', it: 'Riferimento CLI' },
  'Agent Node': { de: 'Agent Node', es: 'Agent Node', fr: 'Agent Node', pt: 'Agent Node', ca: 'Agent Node', hi: 'Agent Node', ko: 'Agent Node', ja: 'Agent Node', it: 'Agent Node' },
  'Private nodes': { de: 'Private Nodes', es: 'Nodos privados', fr: 'Nœuds privés', pt: 'Nós privados', ca: 'Nodes privats', hi: 'निजी नोड', ko: '프라이빗 노드', ja: 'プライベートノード', it: 'Nodi privati' },
  'Clients': { de: 'Clients', es: 'Clientes', fr: 'Clients', pt: 'Clientes', ca: 'Clients', hi: 'क्लाइंट', ko: '클라이언트', ja: 'クライアント', it: 'Client' },
  'Recommended flow': { de: 'Empfohlener Ablauf', es: 'Flujo recomendado', fr: 'Flux recommandé', pt: 'Fluxo recomendado', ca: 'Flux recomanat', hi: 'अनुशंसित प्रवाह', ko: '권장 흐름', ja: '推奨フロー', it: 'Flusso consigliato' },
  'The website, Flutter Web client and backend are three separate release paths: website builds website/dist, Flutter Web client builds build/web, and backend deployment runs through deploy/production and myapp-ctl.': { de: 'Website, Flutter-Web-Client und Backend sind drei separate Release-Pfade: Die Website baut nach website/dist, der Flutter-Web-Client nach build/web, und die Backend-Bereitstellung läuft über deploy/production und myapp-ctl.', es: 'El sitio web, el cliente Flutter Web y el backend son tres rutas de publicación independientes: el sitio web se compila en website/dist, el cliente Flutter Web se compila en build/web, y el despliegue del backend se realiza mediante deploy/production y myapp-ctl.', fr: 'Le site web, le client Flutter Web et le backend constituent trois chemins de publication distincts : le site web se compile vers website/dist, le client Flutter Web vers build/web, et le déploiement du backend passe par deploy/production et myapp-ctl.', pt: 'O site, o cliente Flutter Web e o backend são três caminhos de lançamento distintos: o site compila para website/dist, o cliente Flutter Web compila para build/web e a implementação do backend passa por deploy/production e pelo myapp-ctl.', ca: 'El lloc web, el client Flutter Web i el backend són tres vies de publicació independents: el lloc web es construeix a website/dist, el client Flutter Web a build/web, i el desplegament del backend es fa mitjançant deploy/production i myapp-ctl.', hi: 'वेबसाइट, Flutter Web क्लाइंट और बैकएंड तीन अलग रिलीज़ पथ हैं: वेबसाइट website/dist में बिल्ड होती है, Flutter Web क्लाइंट build/web में बिल्ड होता है, और बैकएंड परिनियोजन deploy/production और myapp-ctl के माध्यम से चलता है।', ko: '웹사이트, Flutter Web 클라이언트, 백엔드는 세 개의 별도 릴리스 경로입니다. 웹사이트는 website/dist로 빌드되고, Flutter Web 클라이언트는 build/web으로 빌드되며, 백엔드 배포는 deploy/production과 myapp-ctl을 통해 진행됩니다.', ja: 'ウェブサイト、Flutter Web クライアント、バックエンドは 3 つの独立したリリース経路です。ウェブサイトは website/dist にビルドされ、Flutter Web クライアントは build/web にビルドされ、バックエンドのデプロイは deploy/production と myapp-ctl を通じて実行されます。', it: 'Il sito web, il client Flutter Web e il backend sono tre percorsi di release distinti: il sito web compila in website/dist, il client Flutter Web compila in build/web e il deployment del backend passa per deploy/production e myapp-ctl.' },
  'Backend control plane': { de: 'Backend-Steuerungsebene', es: 'Plano de control del backend', fr: 'Plan de contrôle du backend', pt: 'Plano de controlo do backend', ca: 'Pla de control del backend', hi: 'बैकएंड कंट्रोल प्लेन', ko: '백엔드 제어 플레인', ja: 'バックエンドのコントロールプレーン', it: 'Piano di controllo del backend' },
  'Fresh install': { de: 'Neuinstallation', es: 'Instalación limpia', fr: 'Installation initiale', pt: 'Instalação de raiz', ca: 'Instal·lació nova', hi: 'नया इंस्टॉल', ko: '신규 설치', ja: '新規インストール', it: 'Installazione da zero' },
  'Image-based deploy': { de: 'Image-basierte Bereitstellung', es: 'Despliegue basado en imágenes', fr: 'Déploiement basé sur images', pt: 'Implementação baseada em imagens', ca: 'Desplegament basat en imatges', hi: 'इमेज-आधारित परिनियोजन', ko: '이미지 기반 배포', ja: 'イメージベースのデプロイ', it: 'Deployment basato su immagini' },
  'setup asks for AI providers. DeepSeek, MiniMax or custom Anthropic-compatible providers are written into server-local env files. APNs, FCM, GeTui and SMTP are optional; skipping them only disables that channel.': { de: 'setup fragt nach AI-Anbietern. DeepSeek, MiniMax oder benutzerdefinierte Anthropic-kompatible Anbieter werden in server-lokale env-Dateien geschrieben. APNs, FCM, GeTui und SMTP sind optional; ein Überspringen deaktiviert lediglich den jeweiligen Kanal.', es: 'setup solicita los proveedores de IA. DeepSeek, MiniMax o proveedores personalizados compatibles con Anthropic se escriben en archivos env locales del servidor. APNs, FCM, GeTui y SMTP son opcionales; omitirlos solo desactiva ese canal.', fr: 'setup demande les fournisseurs IA. DeepSeek, MiniMax ou des fournisseurs personnalisés compatibles Anthropic sont écrits dans des fichiers env locaux au serveur. APNs, FCM, GeTui et SMTP sont optionnels ; les ignorer ne désactive que ce canal.', pt: 'O setup pergunta pelos fornecedores de IA. O DeepSeek, o MiniMax ou fornecedores personalizados compatíveis com a Anthropic são gravados em ficheiros env locais do servidor. APNs, FCM, GeTui e SMTP são opcionais; ignorá-los apenas desativa esse canal.', ca: 'setup demana els proveïdors d\'IA. DeepSeek, MiniMax o proveïdors personalitzats compatibles amb Anthropic s\'escriuen en fitxers env locals del servidor. APNs, FCM, GeTui i SMTP són opcionals; ometre\'ls només desactiva aquell canal.', hi: 'setup AI प्रोवाइडर के बारे में पूछता है। DeepSeek, MiniMax या कस्टम Anthropic-संगत प्रोवाइडर सर्वर-लोकल env फ़ाइलों में लिखे जाते हैं। APNs, FCM, GeTui और SMTP वैकल्पिक हैं; इन्हें छोड़ने से केवल वही चैनल अक्षम होता है।', ko: 'setup은 AI 제공자를 묻습니다. DeepSeek, MiniMax 또는 사용자 지정 Anthropic 호환 제공자가 서버 로컬 env 파일에 기록됩니다. APNs, FCM, GeTui, SMTP는 선택 사항이며, 건너뛰면 해당 채널만 비활성화됩니다.', ja: 'setup は AI プロバイダーを尋ねます。DeepSeek、MiniMax、またはカスタムの Anthropic 互換プロバイダーはサーバーローカルの env ファイルに書き込まれます。APNs、FCM、GeTui、SMTP は任意で、スキップするとそのチャネルが無効になるだけです。', it: 'setup chiede i provider IA. DeepSeek, MiniMax o provider personalizzati compatibili con Anthropic vengono scritti in file env locali del server. APNs, FCM, GeTui e SMTP sono opzionali; saltarli disabilita solo quel canale.' },
  'Routine updates': { de: 'Routine-Updates', es: 'Actualizaciones rutinarias', fr: 'Mises à jour de routine', pt: 'Atualizações de rotina', ca: 'Actualitzacions rutinàries', hi: 'नियमित अपडेट', ko: '일상적인 업데이트', ja: '定常的な更新', it: 'Aggiornamenti di routine' },
  'Deploy only the changed surface': { de: 'Nur den geänderten Teil bereitstellen', es: 'Despliega solo lo que ha cambiado', fr: 'Ne déployer que la surface modifiée', pt: 'Implementar apenas o que foi alterado', ca: 'Desplega només la part que ha canviat', hi: 'केवल बदले गए हिस्से को परिनियोजित करें', ko: '변경된 부분만 배포', ja: '変更箇所のみをデプロイする', it: 'Distribuisci solo la parte modificata' },
  'For routine code updates, run myapp-ctl update first, then rebuild or pull only the changed components. Auth, Redis, Postgres, OpenIM, Supabase and MinIO should stay up for ordinary backend or agent changes.': { de: 'Führen Sie bei routinemäßigen Code-Updates zuerst myapp-ctl update aus und bauen oder pullen Sie dann nur die geänderten Komponenten. Auth, Redis, Postgres, OpenIM, Supabase und MinIO sollten bei gewöhnlichen Backend- oder Agent-Änderungen weiterlaufen.', es: 'Para actualizaciones rutinarias de código, ejecuta primero myapp-ctl update y luego recompila o descarga solo los componentes que han cambiado. Auth, Redis, Postgres, OpenIM, Supabase y MinIO deben permanecer activos para los cambios habituales de backend o de agente.', fr: 'Pour les mises à jour de code de routine, exécutez d\'abord myapp-ctl update, puis recompilez ou récupérez uniquement les composants modifiés. L\'authentification, Redis, Postgres, OpenIM, Supabase et MinIO doivent rester actifs pour les modifications ordinaires du backend ou des agents.', pt: 'Para atualizações de código de rotina, execute primeiro o myapp-ctl update e depois recompile ou faça pull apenas dos componentes alterados. Auth, Redis, Postgres, OpenIM, Supabase e MinIO devem permanecer ativos para alterações comuns ao backend ou ao agente.', ca: 'Per a actualitzacions de codi rutinàries, executa primer myapp-ctl update i després reconstrueix o descarrega només els components que han canviat. Auth, Redis, Postgres, OpenIM, Supabase i MinIO haurien de continuar actius per als canvis habituals de backend o d\'agent.', hi: 'नियमित कोड अपडेट के लिए, पहले myapp-ctl update चलाएँ, फिर केवल बदले गए कॉम्पोनेंट को rebuild या pull करें। सामान्य बैकएंड या एजेंट बदलावों के लिए Auth, Redis, Postgres, OpenIM, Supabase और MinIO चलते रहने चाहिए।', ko: '일상적인 코드 업데이트의 경우 먼저 myapp-ctl update를 실행한 뒤 변경된 컴포넌트만 다시 빌드하거나 풀하세요. 일반적인 백엔드 또는 에이전트 변경 시에는 Auth, Redis, Postgres, OpenIM, Supabase, MinIO를 계속 가동 상태로 유지해야 합니다.', ja: '定常的なコード更新では、まず myapp-ctl update を実行し、その後で変更されたコンポーネントのみを再ビルドまたはプルします。通常のバックエンドやエージェントの変更では、Auth、Redis、Postgres、OpenIM、Supabase、MinIO は稼働させたままにします。', it: 'Per gli aggiornamenti di routine del codice, esegui prima myapp-ctl update, poi ricompila o esegui il pull solo dei componenti modificati. Auth, Redis, Postgres, OpenIM, Supabase e MinIO dovrebbero restare attivi per le normali modifiche al backend o agli agenti.' },
  'Command reference': { de: 'Befehlsreferenz', es: 'Referencia de comandos', fr: 'Référence des commandes', pt: 'Referência de comandos', ca: 'Referència d\'ordres', hi: 'कमांड संदर्भ', ko: '명령어 레퍼런스', ja: 'コマンドリファレンス', it: 'Riferimento dei comandi' },
  'Common subcommands and key flags': { de: 'Gängige Unterbefehle und wichtige Flags', es: 'Subcomandos habituales y flags clave', fr: 'Sous-commandes courantes et options clés', pt: 'Subcomandos comuns e flags principais', ca: 'Subordres habituals i opcions clau', hi: 'सामान्य सबकमांड और प्रमुख फ़्लैग', ko: '주요 하위 명령어 및 핵심 플래그', ja: '主なサブコマンドと重要なフラグ', it: 'Sottocomandi comuni e flag principali' },
  'This is the compact reference embedded in the website. For the full argument list, run myapp-ctl <command> --help on the host.': { de: 'Dies ist die kompakte, in die Website eingebettete Referenz. Die vollständige Argumentliste erhalten Sie mit myapp-ctl <command> --help auf dem Host.', es: 'Esta es la referencia compacta integrada en el sitio web. Para ver la lista completa de argumentos, ejecuta myapp-ctl <command> --help en el host.', fr: 'Ceci est la référence condensée intégrée au site web. Pour la liste complète des arguments, exécutez myapp-ctl <command> --help sur l\'hôte.', pt: 'Esta é a referência compacta incorporada no site. Para a lista completa de argumentos, execute myapp-ctl <command> --help no host.', ca: 'Aquesta és la referència compacta incrustada al lloc web. Per a la llista completa d\'arguments, executa myapp-ctl <command> --help al host.', hi: 'यह वेबसाइट में एम्बेड किया गया संक्षिप्त संदर्भ है। पूरी आर्ग्युमेंट सूची के लिए, होस्ट पर myapp-ctl <command> --help चलाएँ।', ko: '이것은 웹사이트에 포함된 간략한 레퍼런스입니다. 전체 인자 목록은 호스트에서 myapp-ctl <command> --help를 실행하세요.', ja: 'これはウェブサイトに組み込まれた簡易リファレンスです。引数の完全な一覧は、ホストで myapp-ctl <command> --help を実行してください。', it: 'Questo è il riferimento compatto incluso nel sito web. Per l\'elenco completo degli argomenti, esegui myapp-ctl <command> --help sull\'host.' },
  'Compatibility note: myapp-ctl agent add and myapp-ctl agent register remain old aliases; new docs use agent-node add / register.': { de: 'Kompatibilitätshinweis: myapp-ctl agent add und myapp-ctl agent register bleiben alte Aliasse; die neue Dokumentation verwendet agent-node add / register.', es: 'Nota de compatibilidad: myapp-ctl agent add y myapp-ctl agent register siguen siendo alias antiguos; la nueva documentación usa agent-node add / register.', fr: 'Note de compatibilité : myapp-ctl agent add et myapp-ctl agent register restent d\'anciens alias ; la nouvelle documentation utilise agent-node add / register.', pt: 'Nota de compatibilidade: myapp-ctl agent add e myapp-ctl agent register continuam a ser aliases antigos; a nova documentação usa agent-node add / register.', ca: 'Nota de compatibilitat: myapp-ctl agent add i myapp-ctl agent register continuen com a àlies antics; la documentació nova fa servir agent-node add / register.', hi: 'संगतता नोट: myapp-ctl agent add और myapp-ctl agent register पुराने उपनाम के रूप में बने रहते हैं; नए दस्तावेज़ agent-node add / register का उपयोग करते हैं।', ko: '호환성 참고: myapp-ctl agent add와 myapp-ctl agent register는 이전 별칭으로 유지됩니다. 새 문서에서는 agent-node add / register를 사용합니다.', ja: '互換性に関する注意: myapp-ctl agent add と myapp-ctl agent register は旧来のエイリアスとして残っています。新しいドキュメントでは agent-node add / register を使用します。', it: 'Nota di compatibilità: myapp-ctl agent add e myapp-ctl agent register restano vecchi alias; la nuova documentazione usa agent-node add / register.' },
  'Public Agent Nodes': { de: 'Öffentliche Agent Nodes', es: 'Agent Nodes públicos', fr: 'Agent Nodes publics', pt: 'Agent Nodes públicos', ca: 'Agent Nodes públics', hi: 'सार्वजनिक Agent Node', ko: '공용 Agent Node', ja: 'パブリック Agent Node', it: 'Agent Node pubblici' },
  'Multi-host agents use pull mode': { de: 'Multi-Host-Agents verwenden den Pull-Modus', es: 'Los agentes multihost usan el modo pull', fr: 'Les agents multi-hôtes utilisent le mode pull', pt: 'Os agentes multi-host usam o modo pull', ca: 'Els agents multi-host fan servir el mode pull', hi: 'मल्टी-होस्ट एजेंट pull मोड का उपयोग करते हैं', ko: '멀티 호스트 에이전트는 풀 모드를 사용합니다', ja: 'マルチホストのエージェントはプルモードを使用する', it: 'Gli agenti multi-host usano la modalità pull' },
  'The default architecture is pull-based: agent-node polls the backend for work, while client SSE remains client -> backend. A secondary agent host only needs outbound access to the backend and no public inbound port. Node registration lives in Postgres; queues and heartbeats use Redis.': { de: 'Die Standardarchitektur ist pull-basiert: agent-node fragt das Backend nach Aufgaben ab, während der Client-SSE-Verkehr Client -> Backend bleibt. Ein sekundärer Agent-Host benötigt nur ausgehenden Zugriff auf das Backend und keinen öffentlichen eingehenden Port. Die Node-Registrierung liegt in Postgres; Queues und Heartbeats nutzen Redis.', es: 'La arquitectura por defecto se basa en pull: agent-node consulta el backend en busca de trabajo, mientras que el SSE del cliente sigue siendo cliente -> backend. Un host de agente secundario solo necesita acceso de salida al backend y ningún puerto público de entrada. El registro de nodos reside en Postgres; las colas y los heartbeats usan Redis.', fr: 'L\'architecture par défaut est basée sur le pull : agent-node interroge le backend pour récupérer du travail, tandis que le SSE client reste client -> backend. Un hôte d\'agent secondaire n\'a besoin que d\'un accès sortant vers le backend et d\'aucun port entrant public. L\'enregistrement des nœuds réside dans Postgres ; les files et les heartbeats utilisent Redis.', pt: 'A arquitetura predefinida é baseada em pull: o agent-node consulta o backend à procura de trabalho, enquanto o SSE do cliente continua a ser cliente -> backend. Um host de agente secundário só precisa de acesso de saída ao backend e de nenhuma porta de entrada pública. O registo de nós reside no Postgres; as filas e os heartbeats usam o Redis.', ca: 'L\'arquitectura per defecte es basa en pull: agent-node consulta el backend per obtenir feina, mentre que el SSE del client continua sent client -> backend. Un host d\'agent secundari només necessita accés de sortida cap al backend i cap port d\'entrada públic. El registre de nodes resideix a Postgres; les cues i els batecs (heartbeats) utilitzen Redis.', hi: 'डिफ़ॉल्ट आर्किटेक्चर pull-आधारित है: agent-node काम के लिए बैकएंड को पोल करता है, जबकि क्लाइंट SSE client -> backend ही रहता है। एक द्वितीयक एजेंट होस्ट को केवल बैकएंड तक आउटबाउंड पहुँच चाहिए और किसी सार्वजनिक इनबाउंड पोर्ट की ज़रूरत नहीं। नोड रजिस्ट्रेशन Postgres में रहता है; क्यू और हार्टबीट Redis का उपयोग करते हैं।', ko: '기본 아키텍처는 풀 기반입니다. agent-node가 백엔드에서 작업을 폴링하고, 클라이언트 SSE는 클라이언트 -> 백엔드를 유지합니다. 보조 에이전트 호스트는 백엔드로의 아웃바운드 접근만 필요하며 공개 인바운드 포트는 필요 없습니다. 노드 등록은 Postgres에 저장되고, 큐와 하트비트는 Redis를 사용합니다.', ja: 'デフォルトのアーキテクチャはプルベースです。agent-node がバックエンドにジョブをポーリングし、クライアントの SSE は client -> backend のままです。セカンダリのエージェントホストはバックエンドへの送信アクセスのみが必要で、公開受信ポートは不要です。ノードの登録は Postgres に保存され、キューとハートビートは Redis を使用します。', it: 'L\'architettura predefinita è basata sul pull: agent-node interroga il backend per i lavori, mentre l\'SSE del client resta client -> backend. Un host agente secondario necessita solo di accesso in uscita verso il backend e di nessuna porta pubblica in entrata. La registrazione dei nodi risiede in Postgres; code e heartbeat usano Redis.' },
  'Generate join command on master': { de: 'Beitrittsbefehl auf dem Master generieren', es: 'Generar el comando de unión en el nodo maestro', fr: 'Générer la commande de jonction sur le master', pt: 'Gerar comando de adesão no master', ca: 'Genera l\'ordre d\'incorporació al màster', hi: 'मास्टर पर join कमांड जेनरेट करें', ko: '마스터에서 조인 명령 생성', ja: 'マスターで参加コマンドを生成する', it: 'Genera il comando di join sul master' },
  'Node operations': { de: 'Node-Betrieb', es: 'Operaciones de nodo', fr: 'Opérations sur les nœuds', pt: 'Operações de nós', ca: 'Operacions de nodes', hi: 'नोड संचालन', ko: '노드 운영', ja: 'ノード運用', it: 'Operazioni sui nodi' },
  'Backend sends provider config; agent-node mints one-time proxy tokens.': { de: 'Das Backend sendet die Anbieter-Konfiguration; agent-node erzeugt einmalige Proxy-Tokens.', es: 'El backend envía la configuración del proveedor; agent-node genera tokens de proxy de un solo uso.', fr: 'Le backend envoie la configuration du fournisseur ; agent-node génère des jetons de proxy à usage unique.', pt: 'O backend envia a configuração do fornecedor; o agent-node gera tokens de proxy de utilização única.', ca: 'El backend envia la configuració del proveïdor; agent-node encunya tokens de proxy d\'un sol ús.', hi: 'बैकएंड प्रोवाइडर कॉन्फ़िग भेजता है; agent-node एक बार उपयोग होने वाले प्रॉक्सी टोकन बनाता है।', ko: '백엔드는 제공자 설정을 전송하고, agent-node는 일회용 프록시 토큰을 발급합니다.', ja: 'バックエンドがプロバイダー構成を送信し、agent-node が 1 回限りのプロキシトークンを発行します。', it: 'Il backend invia la configurazione del provider; agent-node genera token proxy monouso.' },
  'Provider keys stay in the agent host local ai-providers.env.': { de: 'Anbieter-Schlüssel verbleiben in der lokalen Datei ai-providers.env des Agent-Hosts.', es: 'Las claves de proveedor permanecen en el archivo local ai-providers.env del host del agente.', fr: 'Les clés de fournisseur restent dans le fichier ai-providers.env local à l\'hôte de l\'agent.', pt: 'As chaves de fornecedor ficam no ai-providers.env local do host do agente.', ca: 'Les claus del proveïdor es queden al fitxer local ai-providers.env del host de l\'agent.', hi: 'प्रोवाइडर की एजेंट होस्ट की लोकल ai-providers.env में रहती हैं।', ko: '제공자 키는 에이전트 호스트의 로컬 ai-providers.env에 보관됩니다.', ja: 'プロバイダーキーはエージェントホストのローカルの ai-providers.env に保持されます。', it: 'Le chiavi provider restano nel file locale ai-providers.env dell\'host agente.' },
  'Current runs, max concurrency, current queue and max queue.': { de: 'Aktuelle Läufe, maximale Parallelität, aktuelle Queue und maximale Queue.', es: 'Ejecuciones actuales, concurrencia máxima, cola actual y cola máxima.', fr: 'Exécutions en cours, concurrence maximale, file actuelle et file maximale.', pt: 'Execuções atuais, concorrência máxima, fila atual e fila máxima.', ca: 'Execucions actuals, concurrència màxima, cua actual i cua màxima.', hi: 'वर्तमान रन, अधिकतम समवर्तीता, वर्तमान क्यू और अधिकतम क्यू।', ko: '현재 실행 수, 최대 동시 실행 수, 현재 큐, 최대 큐.', ja: '現在の実行数、最大同時実行数、現在のキュー、最大キュー。', it: 'Run correnti, concorrenza massima, coda corrente e coda massima.' },
  'Session affinity': { de: 'Sitzungsaffinität', es: 'Afinidad de sesión', fr: 'Affinité de session', pt: 'Afinidade de sessão', ca: 'Afinitat de sessió', hi: 'सेशन एफ़िनिटी', ko: '세션 어피니티', ja: 'セッションアフィニティ', it: 'Affinità di sessione' },
  'Later turns of one session prefer the same online node.': { de: 'Spätere Schritte einer Sitzung bevorzugen dieselbe Online-Node.', es: 'Los turnos posteriores de una misma sesión prefieren el mismo nodo en línea.', fr: 'Les tours suivants d\'une même session privilégient le même nœud en ligne.', pt: 'Os turnos seguintes de uma sessão preferem o mesmo nó online.', ca: 'Els torns posteriors d\'una mateixa sessió prefereixen el mateix node en línia.', hi: 'किसी सेशन के बाद के टर्न उसी ऑनलाइन नोड को प्राथमिकता देते हैं।', ko: '한 세션의 이후 턴은 동일한 온라인 노드를 우선합니다.', ja: '同一セッションの後続ターンは、同じオンラインノードを優先します。', it: 'I turni successivi di una sessione preferiscono lo stesso nodo online.' },
  'User-private Agent Nodes': { de: 'Benutzerprivate Agent Nodes', es: 'Agent Nodes privados del usuario', fr: 'Agent Nodes privés à l\'utilisateur', pt: 'Agent Nodes privados do utilizador', ca: 'Agent Nodes privats d\'usuari', hi: 'उपयोगकर्ता-निजी Agent Node', ko: '사용자 전용 Agent Node', ja: 'ユーザー専用 Agent Node', it: 'Agent Node privati dell\'utente' },
  'Users can attach their own agent host and provider keys': { de: 'Nutzer können ihren eigenen Agent-Host und ihre eigenen Anbieter-Schlüssel anbinden', es: 'Los usuarios pueden vincular su propio host de agente y sus claves de proveedor', fr: 'Les utilisateurs peuvent attacher leur propre hôte d\'agent et leurs clés de fournisseur', pt: 'Os utilizadores podem associar o seu próprio host de agente e chaves de fornecedor', ca: 'Els usuaris poden vincular el seu propi host d\'agent i les seves claus de proveïdor', hi: 'उपयोगकर्ता अपना स्वयं का एजेंट होस्ट और प्रोवाइडर की जोड़ सकते हैं', ko: '사용자는 자신의 에이전트 호스트와 제공자 키를 연결할 수 있습니다', ja: 'ユーザーは自分のエージェントホストとプロバイダーキーを接続できます', it: 'Gli utenti possono collegare il proprio host agente e le proprie chiavi provider' },
  'Private nodes serve only their owner. The user creates a one-time join token in app settings, then configures provider keys locally on the node. Long-lived provider keys are never uploaded to the backend. When the client switches to private routing, it shows only providers reported by that user’s private nodes.': { de: 'Private Nodes bedienen nur ihren Eigentümer. Der Nutzer erstellt in den App-Einstellungen ein einmaliges Beitritts-Token und konfiguriert dann die Anbieter-Schlüssel lokal auf der Node. Langlebige Anbieter-Schlüssel werden niemals zum Backend hochgeladen. Wenn der Client auf privates Routing umschaltet, zeigt er nur Anbieter an, die von den privaten Nodes dieses Nutzers gemeldet werden.', es: 'Los nodos privados sirven únicamente a su propietario. El usuario crea un token de unión de un solo uso en los ajustes de la app y luego configura las claves de proveedor localmente en el nodo. Las claves de proveedor de larga duración nunca se suben al backend. Cuando el cliente cambia al enrutamiento privado, solo muestra los proveedores notificados por los nodos privados de ese usuario.', fr: 'Les nœuds privés ne servent que leur propriétaire. L\'utilisateur crée un jeton de jonction à usage unique dans les paramètres de l\'app, puis configure les clés de fournisseur localement sur le nœud. Les clés de fournisseur à longue durée de vie ne sont jamais téléversées vers le backend. Lorsque le client bascule en routage privé, il n\'affiche que les fournisseurs signalés par les nœuds privés de cet utilisateur.', pt: 'Os nós privados servem apenas o seu proprietário. O utilizador cria um token de adesão de utilização única nas definições da app e depois configura as chaves de fornecedor localmente no nó. As chaves de fornecedor de longa duração nunca são carregadas para o backend. Quando o cliente muda para o encaminhamento privado, mostra apenas os fornecedores reportados pelos nós privados desse utilizador.', ca: 'Els nodes privats només serveixen el seu propietari. L\'usuari crea un token d\'incorporació d\'un sol ús a la configuració de l\'app i després configura les claus del proveïdor localment al node. Les claus de proveïdor de llarga durada no es pugen mai al backend. Quan el client canvia a l\'enrutament privat, només mostra els proveïdors reportats pels nodes privats d\'aquest usuari.', hi: 'निजी नोड केवल अपने मालिक की सेवा करते हैं। उपयोगकर्ता ऐप सेटिंग में एक बार उपयोग होने वाला join टोकन बनाता है, फिर नोड पर लोकल रूप से प्रोवाइडर की कॉन्फ़िगर करता है। दीर्घकालिक प्रोवाइडर की कभी बैकएंड पर अपलोड नहीं की जाती। जब क्लाइंट निजी रूटिंग पर स्विच करता है, तो वह केवल उस उपयोगकर्ता के निजी नोड द्वारा रिपोर्ट किए गए प्रोवाइडर दिखाता है।', ko: '프라이빗 노드는 소유자에게만 서비스를 제공합니다. 사용자는 앱 설정에서 일회용 조인 토큰을 생성한 뒤 노드에서 로컬로 제공자 키를 설정합니다. 장기 제공자 키는 백엔드로 절대 업로드되지 않습니다. 클라이언트가 프라이빗 라우팅으로 전환되면 해당 사용자의 프라이빗 노드가 보고한 제공자만 표시됩니다.', ja: 'プライベートノードは所有者のみにサービスを提供します。ユーザーはアプリ設定で 1 回限りの参加トークンを作成し、その後ノード上でローカルにプロバイダーキーを設定します。長期間有効なプロバイダーキーがバックエンドにアップロードされることはありません。クライアントがプライベートルーティングに切り替わると、そのユーザーのプライベートノードが報告したプロバイダーのみが表示されます。', it: 'I nodi privati servono solo il loro proprietario. L\'utente crea un token di join monouso nelle impostazioni dell\'app, poi configura le chiavi provider localmente sul nodo. Le chiavi provider a lunga durata non vengono mai caricate sul backend. Quando il client passa al routing privato, mostra solo i provider segnalati dai nodi privati di quell\'utente.' },
  'User flow': { de: 'Nutzerablauf', es: 'Flujo del usuario', fr: 'Parcours utilisateur', pt: 'Fluxo do utilizador', ca: 'Flux d\'usuari', hi: 'उपयोगकर्ता प्रवाह', ko: '사용자 흐름', ja: 'ユーザーフロー', it: 'Flusso utente' },
  'Sign in to the app and open Private Agent Node in settings.': { de: 'Melden Sie sich in der App an und öffnen Sie in den Einstellungen die Private Agent Node.', es: 'Inicia sesión en la app y abre Agent Node privado en los ajustes.', fr: 'Connectez-vous à l\'app et ouvrez Agent Node privé dans les paramètres.', pt: 'Inicie sessão na app e abra o Agent Node privado nas definições.', ca: 'Inicia la sessió a l\'app i obre Agent Node privat a la configuració.', hi: 'ऐप में साइन इन करें और सेटिंग में Private Agent Node खोलें।', ko: '앱에 로그인한 뒤 설정에서 프라이빗 Agent Node를 엽니다.', ja: 'アプリにサインインし、設定でプライベート Agent Node を開きます。', it: 'Accedi all\'app e apri Agent Node privato nelle impostazioni.' },
  'Confirm the current provider / agent and routing mode in settings, then create a join command.': { de: 'Bestätigen Sie in den Einstellungen den aktuellen Anbieter / Agent und den Routing-Modus und erstellen Sie dann einen Beitrittsbefehl.', es: 'Confirma el proveedor / agente actual y el modo de enrutamiento en los ajustes y luego crea un comando de unión.', fr: 'Confirmez le fournisseur / agent actuel et le mode de routage dans les paramètres, puis créez une commande de jonction.', pt: 'Confirme o fornecedor / agente atual e o modo de encaminhamento nas definições e depois crie um comando de adesão.', ca: 'Confirma el proveïdor / agent actual i el mode d\'enrutament a la configuració i, tot seguit, crea una ordre d\'incorporació.', hi: 'सेटिंग में वर्तमान प्रोवाइडर / एजेंट और रूटिंग मोड की पुष्टि करें, फिर एक join कमांड बनाएँ।', ko: '설정에서 현재 제공자 / 에이전트와 라우팅 모드를 확인한 뒤 조인 명령을 생성합니다.', ja: '設定で現在のプロバイダー / エージェントとルーティングモードを確認してから、参加コマンドを作成します。', it: 'Conferma il provider / agente attuale e la modalità di routing nelle impostazioni, poi crea un comando di join.' },
  'Enter a node name and copy the join command.': { de: 'Geben Sie einen Node-Namen ein und kopieren Sie den Beitrittsbefehl.', es: 'Introduce un nombre de nodo y copia el comando de unión.', fr: 'Saisissez un nom de nœud et copiez la commande de jonction.', pt: 'Introduza um nome de nó e copie o comando de adesão.', ca: 'Introdueix un nom de node i copia l\'ordre d\'incorporació.', hi: 'एक नोड नाम दर्ज करें और join कमांड कॉपी करें।', ko: '노드 이름을 입력하고 조인 명령을 복사합니다.', ja: 'ノード名を入力し、参加コマンドをコピーします。', it: 'Inserisci un nome per il nodo e copia il comando di join.' },
  'Install myapp-ctl on your own host and run the join command.': { de: 'Installieren Sie myapp-ctl auf Ihrem eigenen Host und führen Sie den Beitrittsbefehl aus.', es: 'Instala myapp-ctl en tu propio host y ejecuta el comando de unión.', fr: 'Installez myapp-ctl sur votre propre hôte et exécutez la commande de jonction.', pt: 'Instale o myapp-ctl no seu próprio host e execute o comando de adesão.', ca: 'Instal·la myapp-ctl al teu propi host i executa l\'ordre d\'incorporació.', hi: 'अपने स्वयं के होस्ट पर myapp-ctl इंस्टॉल करें और join कमांड चलाएँ।', ko: '자신의 호스트에 myapp-ctl을 설치하고 조인 명령을 실행합니다.', ja: '自分のホストに myapp-ctl をインストールし、参加コマンドを実行します。', it: 'Installa myapp-ctl sul tuo host ed esegui il comando di join.' },
  'Enter this node’s own DeepSeek / MiniMax / custom provider configuration.': { de: 'Geben Sie die eigene DeepSeek-/MiniMax-/benutzerdefinierte Anbieter-Konfiguration dieser Node ein.', es: 'Introduce la configuración propia de DeepSeek / MiniMax / proveedor personalizado de este nodo.', fr: 'Saisissez la configuration de fournisseur DeepSeek / MiniMax / personnalisée propre à ce nœud.', pt: 'Introduza a configuração própria de fornecedor DeepSeek / MiniMax / personalizado deste nó.', ca: 'Introdueix la configuració de proveïdor DeepSeek / MiniMax / personalitzat propi d\'aquest node.', hi: 'इस नोड का अपना DeepSeek / MiniMax / कस्टम प्रोवाइडर कॉन्फ़िगरेशन दर्ज करें।', ko: '이 노드 고유의 DeepSeek / MiniMax / 사용자 지정 제공자 설정을 입력합니다.', ja: 'このノード独自の DeepSeek / MiniMax / カスタムプロバイダーの構成を入力します。', it: 'Inserisci la configurazione provider DeepSeek / MiniMax / personalizzata propria di questo nodo.' },
  'Switch Agent routing to private in the app; only your nodes are used.': { de: 'Stellen Sie das Agent-Routing in der App auf privat um; es werden nur Ihre Nodes verwendet.', es: 'Cambia el enrutamiento del Agent a privado en la app; solo se usan tus nodos.', fr: 'Basculez le routage Agent en privé dans l\'app ; seuls vos nœuds sont utilisés.', pt: 'Mude o encaminhamento do Agent para privado na app; só são usados os seus nós.', ca: 'Canvia l\'enrutament de l\'Agent a privat dins de l\'app; només es fan servir els teus nodes.', hi: 'ऐप में Agent रूटिंग को private पर स्विच करें; केवल आपके नोड का उपयोग होता है।', ko: '앱에서 Agent 라우팅을 프라이빗으로 전환하면 자신의 노드만 사용됩니다.', ja: 'アプリで Agent ルーティングをプライベートに切り替えます。自分のノードのみが使用されます。', it: 'Imposta il routing degli Agent su privato nell\'app; vengono usati solo i tuoi nodi.' },
  'Private node join': { de: 'Beitritt einer privaten Node', es: 'Unión de nodo privado', fr: 'Jonction d\'un nœud privé', pt: 'Adesão de nó privado', ca: 'Incorporació de node privat', hi: 'निजी नोड join', ko: '프라이빗 노드 조인', ja: 'プライベートノードの参加', it: 'Join del nodo privato' },
  'Client routing currently has only public and private modes. public uses the platform pool; private uses only the signed-in user’s private nodes and does not automatically fall back to public when offline.': { de: 'Das Client-Routing kennt derzeit nur die Modi public und private. public nutzt den Plattform-Pool; private nutzt ausschließlich die privaten Nodes des angemeldeten Nutzers und fällt im Offline-Fall nicht automatisch auf public zurück.', es: 'El enrutamiento del cliente solo tiene actualmente los modos público y privado. public usa el pool de la plataforma; private usa únicamente los nodos privados del usuario que ha iniciado sesión y no recurre automáticamente a public cuando están sin conexión.', fr: 'Le routage client ne propose actuellement que les modes public et private. public utilise le pool de la plateforme ; private utilise uniquement les nœuds privés de l\'utilisateur connecté et ne bascule pas automatiquement vers public en cas de mise hors ligne.', pt: 'O encaminhamento do cliente tem atualmente apenas os modos público e privado. O público usa o pool da plataforma; o privado usa apenas os nós privados do utilizador com sessão iniciada e não recorre automaticamente ao público quando estes estão offline.', ca: 'L\'enrutament del client actualment només té els modes public i private. public utilitza el grup de la plataforma; private utilitza només els nodes privats de l\'usuari amb sessió iniciada i no torna automàticament a public quan està fora de línia.', hi: 'क्लाइंट रूटिंग में फ़िलहाल केवल public और private मोड हैं। public प्लेटफ़ॉर्म पूल का उपयोग करता है; private केवल साइन इन किए गए उपयोगकर्ता के निजी नोड का उपयोग करता है और ऑफ़लाइन होने पर स्वतः public पर वापस नहीं जाता।', ko: '클라이언트 라우팅에는 현재 public과 private 모드만 있습니다. public은 플랫폼 풀을 사용하고, private은 로그인한 사용자의 프라이빗 노드만 사용하며 오프라인일 때 자동으로 public으로 폴백하지 않습니다.', ja: 'クライアントのルーティングには現在 public と private の 2 つのモードのみがあります。public はプラットフォームのプールを使用し、private はサインイン中のユーザーのプライベートノードのみを使用し、オフライン時に自動的に public へフォールバックすることはありません。', it: 'Il routing del client attualmente prevede solo le modalità public e private. public usa il pool della piattaforma; private usa solo i nodi privati dell\'utente connesso e non torna automaticamente a public quando questi sono offline.' },
  'The website is the Vite project under website. Deploy website/dist to Cloudflare Pages; do not confuse it with the Flutter Web client build/web output.': { de: 'Die Website ist das Vite-Projekt unter website. Stellen Sie website/dist auf Cloudflare Pages bereit; verwechseln Sie sie nicht mit dem build/web-Output des Flutter-Web-Clients.', es: 'El sitio web es el proyecto Vite ubicado en website. Despliega website/dist en Cloudflare Pages; no lo confundas con la salida build/web del cliente Flutter Web.', fr: 'Le site web est le projet Vite sous website. Déployez website/dist sur Cloudflare Pages ; ne le confondez pas avec la sortie build/web du client Flutter Web.', pt: 'O site é o projeto Vite em website. Implemente website/dist no Cloudflare Pages; não o confunda com o resultado build/web do cliente Flutter Web.', ca: 'El lloc web és el projecte Vite dins de website. Desplega website/dist a Cloudflare Pages; no el confonguis amb la sortida build/web del client Flutter Web.', hi: 'वेबसाइट website के अंतर्गत Vite प्रोजेक्ट है। website/dist को Cloudflare Pages पर परिनियोजित करें; इसे Flutter Web क्लाइंट के build/web आउटपुट के साथ भ्रमित न करें।', ko: '웹사이트는 website 아래의 Vite 프로젝트입니다. website/dist를 Cloudflare Pages에 배포하세요. Flutter Web 클라이언트의 build/web 출력과 혼동하지 마세요.', ja: 'ウェブサイトは website 配下の Vite プロジェクトです。website/dist を Cloudflare Pages にデプロイしてください。Flutter Web クライアントの build/web 出力と混同しないでください。', it: 'Il sito web è il progetto Vite nella cartella website. Distribuisci website/dist su Cloudflare Pages; non confonderlo con l\'output build/web del client Flutter Web.' },
  'Web app': {de: 'Web-App', es: 'App web', fr: 'Application Web', pt: 'App Web', ca: 'App web', hi: 'Web ऐप', ko: '웹 앱', ja: 'Web アプリ', it: 'App web'},
  'No install required. Open the hosted Web client.': {de: 'Keine Installation nötig. Den gehosteten Web-Client öffnen.', es: 'Sin instalación. Abre el cliente web alojado.', fr: 'Aucune installation requise. Ouvrez le client Web hébergé.', pt: 'Sem instalação. Abra o cliente Web alojado.', ca: 'No cal instal·lar res. Obre el client web allotjat.', hi: 'इंस्टॉल की ज़रूरत नहीं। होस्ट किया गया Web क्लाइंट खोलें।', ko: '설치 불필요. 호스팅된 웹 클라이언트를 바로 여세요.', ja: 'インストール不要。ホスト型 Web クライアントをそのまま開けます。', it: 'Nessuna installazione richiesta. Apri il client web ospitato.'},
  'Available': {de: 'Verfügbar', es: 'Disponible', fr: 'Disponible', pt: 'Disponível', ca: 'Disponible', hi: 'उपलब्ध', ko: '사용 가능', ja: '利用可能', it: 'Disponibile'},
  'Public Group 1 is open for real-device testing.': {de: 'Public Group 1 ist für Tests auf echten Geräten geöffnet.', es: 'El Grupo público 1 está abierto para pruebas en dispositivos reales.', fr: 'Le Groupe public 1 est ouvert aux tests sur appareils réels.', pt: 'O Grupo Público 1 está aberto para testes em dispositivos reais.', ca: 'El Grup Públic 1 està obert per a proves en dispositius reals.', hi: 'Public Group 1 असली डिवाइस पर परीक्षण के लिए खुला है।', ko: '공개 그룹 1이 실기기 테스트용으로 열려 있습니다.', ja: 'Public Group 1 を公開中。実機での体験に最適です。', it: 'Il Gruppo pubblico 1 è aperto per i test su dispositivi reali.'},
  'Public group': {de: 'Öffentliche Gruppe', es: 'Grupo público', fr: 'Groupe public', pt: 'Grupo público', ca: 'Grup públic', hi: 'सार्वजनिक समूह', ko: '공개 그룹', ja: '公開グループ', it: 'Gruppo pubblico'},
  'Android APK': {de: 'Android APK', es: 'APK de Android', fr: 'APK Android', pt: 'APK Android', ca: 'APK d\'Android', hi: 'Android APK', ko: 'Android APK', ja: 'Android APK', it: 'APK Android'},
  'Download the latest APK from a fixed link. Google Play is preparing.': {de: 'Lade die neueste APK über einen festen Link herunter. Google Play wird vorbereitet.', es: 'Descarga el último APK desde un enlace fijo. Google Play está en preparación.', fr: 'Téléchargez le dernier APK via un lien fixe. Google Play est en préparation.', pt: 'Transfira o APK mais recente a partir de uma ligação fixa. A Google Play está a ser preparada.', ca: 'Descarrega l\'últim APK des d\'un enllaç fix. Google Play s\'està preparant.', hi: 'स्थायी लिंक से नवीनतम APK डाउनलोड करें। Google Play तैयार हो रहा है।', ko: '고정 링크에서 최신 APK를 내려받으세요. Google Play는 준비 중입니다.', ja: '固定リンクから最新の APK をダウンロード。Google Play は準備中です。', it: 'Scarica l\'ultimo APK da un link fisso. Google Play è in preparazione.'},
  'Direct download': {de: 'Direkter Download', es: 'Descarga directa', fr: 'Téléchargement direct', pt: 'Transferência direta', ca: 'Descàrrega directa', hi: 'सीधा डाउनलोड', ko: '직접 다운로드', ja: '直接ダウンロード', it: 'Download diretto'},
  'Self-host backend': {de: 'Backend selbst hosten', es: 'Backend autoalojado', fr: 'Backend auto-hébergé', pt: 'Backend autoalojado', ca: 'Backend autoallotjat', hi: 'बैकएंड स्वयं होस्ट करें', ko: '백엔드 자체 호스팅', ja: 'バックエンドを自分でホスト', it: 'Backend self-hosted'},
  'Connect Web, iOS or Android clients to your backend.': {de: 'Verbinde Web-, iOS- oder Android-Clients mit deinem Backend.', es: 'Conecta clientes web, iOS o Android a tu backend.', fr: 'Connectez des clients Web, iOS ou Android à votre backend.', pt: 'Ligue clientes Web, iOS ou Android ao seu backend.', ca: 'Connecta clients web, iOS o Android al teu backend.', hi: 'अपने बैकएंड से Web, iOS या Android क्लाइंट जोड़ें।', ko: '웹, iOS, Android 클라이언트를 직접 운영하는 백엔드에 연결하세요.', ja: 'Web、iOS、Android のクライアントを自分のバックエンドに接続できます。', it: 'Collega i client Web, iOS o Android al tuo backend.'},
  'Docs': {de: 'Doku', es: 'Documentación', fr: 'Docs', pt: 'Documentação', ca: 'Documentació', hi: 'दस्तावेज़', ko: '문서', ja: 'ドキュメント', it: 'Documentazione'},
  'GitHub soon': {de: 'GitHub bald', es: 'GitHub pronto', fr: 'GitHub bientôt', pt: 'GitHub em breve', ca: 'GitHub aviat', hi: 'GitHub जल्द', ko: 'GitHub 곧 공개', ja: 'GitHub 近日公開', it: 'GitHub a breve'},
  'Quick links': {de: 'Schnellzugriff', es: 'Enlaces rápidos', fr: 'Liens rapides', pt: 'Ligações rápidas', ca: 'Enllaços ràpids', hi: 'त्वरित लिंक', ko: '바로 가기', ja: 'クイックリンク', it: 'Link rapidi'},
  'Review boundary': {de: 'Prüfungsgrenze', es: 'Límite de revisión', fr: 'Périmètre de revue', pt: 'Limite de revisão', ca: 'Límit de revisió', hi: 'समीक्षा सीमा', ko: '심사 범위', ja: '審査の境界', it: 'Ambito di revisione'},
  'open now': {de: 'jetzt offen', es: 'abrir ahora', fr: 'ouvert maintenant', pt: 'já aberto', ca: 'obre ara', hi: 'अभी खुला', ko: '지금 열기', ja: '今すぐ開く', it: 'apri ora'},
  'direct download': {de: 'direkter Download', es: 'descarga directa', fr: 'téléchargement direct', pt: 'transferência direta', ca: 'descàrrega directa', hi: 'सीधा डाउनलोड', ko: '직접 다운로드', ja: '直接ダウンロード', it: 'download diretto'},
  'Why it is credible': {de: 'Warum es glaubwürdig ist', es: 'Por qué es fiable', fr: 'Pourquoi c\'est crédible', pt: 'Porque é credível', ca: 'Per què és fiable', hi: 'यह क्यों भरोसेमंद है', ko: '신뢰할 수 있는 이유', ja: '信頼できる理由', it: 'Perché è affidabile'},
  'Keep exploring': {de: 'Weiter erkunden', es: 'Sigue explorando', fr: 'Continuer à explorer', pt: 'Continue a explorar', ca: 'Continua explorant', hi: 'और जानें', ko: '계속 둘러보기', ja: 'さらに見る', it: 'Continua a esplorare'},
  'Try it live': {de: 'Live ausprobieren', es: 'Pruébalo en vivo', fr: 'Essayez en direct', pt: 'Experimente ao vivo', ca: 'Prova-ho en directe', hi: 'लाइव आज़माएँ', ko: '라이브로 사용해 보기', ja: '今すぐ試す', it: 'Provalo dal vivo'},
  'Use myapp-ctl to deploy the backend, manage secrets, inspect status and ship components.': {de: 'Mit myapp-ctl das Backend bereitstellen, Secrets verwalten, Status prüfen und Komponenten ausliefern.', es: 'Usa myapp-ctl para desplegar el backend, gestionar secretos, revisar el estado y publicar componentes.', fr: 'Utilisez myapp-ctl pour déployer le backend, gérer les secrets, inspecter l\'état et publier des composants.', pt: 'Use o myapp-ctl para implementar o backend, gerir segredos, inspecionar o estado e publicar componentes.', ca: 'Usa myapp-ctl per desplegar el backend, gestionar secrets, inspeccionar l\'estat i publicar components.', hi: 'बैकएंड डिप्लॉय करने, सीक्रेट प्रबंधित करने, स्थिति जाँचने और कंपोनेंट भेजने के लिए myapp-ctl का उपयोग करें।', ko: 'myapp-ctl로 백엔드를 배포하고 시크릿을 관리하며 상태를 확인하고 컴포넌트를 배포하세요.', ja: 'myapp-ctl でバックエンドをデプロイし、シークレットの管理、ステータスの確認、コンポーネントの配信を行えます。', it: 'Usa myapp-ctl per distribuire il backend, gestire i segreti, controllare lo stato e pubblicare i componenti.'},
  'Backend first': {de: 'Backend zuerst', es: 'Backend primero', fr: 'Le backend d\'abord', pt: 'Backend primeiro', ca: 'El backend primer', hi: 'पहले बैकएंड', ko: '백엔드 우선', ja: 'バックエンド優先', it: 'Backend prima di tutto'},
  'Use the hosted Web app directly, or build Flutter Web, iOS or Android yourself.': {de: 'Nutze die gehostete Web-App direkt oder baue Flutter Web, iOS oder Android selbst.', es: 'Usa directamente la app web alojada, o compila tú mismo Flutter Web, iOS o Android.', fr: 'Utilisez directement l\'application Web hébergée, ou compilez vous-même Flutter Web, iOS ou Android.', pt: 'Use diretamente a app Web alojada ou construa você mesmo o Flutter Web, iOS ou Android.', ca: 'Usa l\'app web allotjada directament o compila tu mateix Flutter Web, iOS o Android.', hi: 'होस्ट किया गया Web ऐप सीधे इस्तेमाल करें, या Flutter Web, iOS या Android खुद बनाएँ।', ko: '호스팅된 웹 앱을 바로 쓰거나, Flutter Web, iOS, Android를 직접 빌드하세요.', ja: 'ホスト型 Web アプリをそのまま使うか、Flutter Web、iOS、Android を自分でビルドできます。', it: 'Usa direttamente l\'app web ospitata oppure compila tu stesso Flutter Web, iOS o Android.'},
  'Replaceable clients': {de: 'Austauschbare Clients', es: 'Clientes intercambiables', fr: 'Clients remplaçables', pt: 'Clientes substituíveis', ca: 'Clients reemplaçables', hi: 'बदले जा सकने वाले क्लाइंट', ko: '교체 가능한 클라이언트', ja: '置き換え可能なクライアント', it: 'Client sostituibili'},
  'Scan or paste': {de: 'Scannen oder einfügen', es: 'Escanea o pega', fr: 'Scannez ou collez', pt: 'Digitalize ou cole', ca: 'Escaneja o enganxa', hi: 'स्कैन करें या पेस्ट करें', ko: '스캔 또는 붙여넣기', ja: 'スキャンまたは貼り付け', it: 'Scansiona o incolla'},
  'Continue': {de: 'Weiter', es: 'Continuar', fr: 'Continuer', pt: 'Continuar', ca: 'Continua', hi: 'जारी रखें', ko: '계속', ja: '続行', it: 'Continua'},
  'Camping kit planner': {de: 'Camping-Ausrüstungsplaner', es: 'Organizador de equipo de acampada', fr: 'Planificateur de kit de camping', pt: 'Planeador de equipamento de campismo', ca: 'Planificador d\'equip d\'acampada', hi: 'कैंपिंग किट प्लानर', ko: '캠핑 장비 플래너', ja: 'キャンプ装備プランナー', it: 'Pianificatore kit da campeggio'},
  'Build a camping packing app with checklist, weather and shared notes': {de: 'Erstelle eine Camping-Pack-App mit Checkliste, Wetter und geteilten Notizen', es: 'Crea una app de equipaje para acampar con lista de tareas, clima y notas compartidas', fr: 'Créez une appli de préparation de camping avec checklist, météo et notes partagées', pt: 'Cria uma app de bagagem para campismo com lista de verificação, meteorologia e notas partilhadas', ca: 'Crea una app per fer la motxilla d\'acampada amb llista de comprovació, temps i notes compartides', hi: 'चेकलिस्ट, मौसम और साझा नोट्स वाला कैंपिंग पैकिंग App बनाएं', ko: '체크리스트, 날씨, 공유 메모를 갖춘 캠핑 짐 싸기 앱 만들기', ja: 'チェックリスト・天気・共有メモ付きのキャンプ持ち物アプリを作成', it: 'Crea un\'app per il campeggio con checklist, meteo e note condivise'},
  'AI creates checklist states, trip summary, team notes and a cross-client UI.': {de: 'Die AI erstellt Checklisten-Status, Reiseübersicht, Teamnotizen und eine plattformübergreifende UI.', es: 'La IA crea estados de la lista, resumen del viaje, notas del equipo y una interfaz multiplataforma.', fr: 'L\'IA crée les états de la checklist, le récapitulatif du séjour, les notes d\'équipe et une UI multiplateforme.', pt: 'A IA gera estados da lista, resumo da viagem, notas da equipa e uma interface multiplataforma.', ca: 'La IA crea estats de la llista, resum del viatge, notes d\'equip i una interfície multiplataforma.', hi: 'AI चेकलिस्ट स्टेट्स, ट्रिप सारांश, टीम नोट्स और क्रॉस-क्लाइंट UI बनाता है।', ko: 'AI가 체크리스트 상태, 여행 요약, 팀 메모, 크로스 플랫폼 UI를 생성합니다.', ja: 'AI がチェックリスト・集計・チームメモ・マルチ端末対応 UI を生成します。', it: 'L\'AI genera stati della checklist, riepilogo del viaggio, note del team e un\'interfaccia multipiattaforma.'},
  'Tool': {de: 'Tool', es: 'Herramienta', fr: 'Outil', pt: 'Ferramenta', ca: 'Eina', hi: 'टूल', ko: '도구', ja: 'ツール', it: 'Strumento'},
  'Checklist': {de: 'Checkliste', es: 'Lista', fr: 'Checklist', pt: 'Lista de verificação', ca: 'Llista', hi: 'चेकलिस्ट', ko: '체크리스트', ja: 'チェックリスト', it: 'Checklist'},
  'Shared': {de: 'Geteilt', es: 'Compartido', fr: 'Partagé', pt: 'Partilhado', ca: 'Compartit', hi: 'साझा', ko: '공유', ja: '共有', it: 'Condiviso'},
  'Star runner mini-game': {de: 'Star-Runner-Minispiel', es: 'Minijuego de corredor estelar', fr: 'Mini-jeu de course aux étoiles', pt: 'Minijogo Star Runner', ca: 'Minijoc Star Runner', hi: 'स्टार रनर मिनी-गेम', ko: '스타 러너 미니 게임', ja: 'スターランナー ミニゲーム', it: 'Mini-gioco star runner'},
  'Create a side-scrolling space runner with jump, obstacles, stars and lives': {de: 'Erstelle einen Side-Scrolling-Weltraumläufer mit Sprung, Hindernissen, Sternen und Leben', es: 'Crea un corredor espacial de scroll lateral con salto, obstáculos, estrellas y vidas', fr: 'Créez un runner spatial à défilement latéral avec saut, obstacles, étoiles et vies', pt: 'Cria um runner espacial lateral com salto, obstáculos, estrelas e vidas', ca: 'Crea un runner espacial de scroll lateral amb salt, obstacles, estrelles i vides', hi: 'जंप, बाधाओं, सितारों और जीवन वाला साइड-स्क्रॉलिंग स्पेस रनर बनाएं', ko: '점프, 장애물, 별, 생명이 있는 횡스크롤 우주 러너 만들기', ja: 'ジャンプ・障害物・スター・ライフ付きの横スクロール宇宙ランナーを作成', it: 'Crea un runner spaziale a scorrimento con salti, ostacoli, stelle e vite'},
  'JSON App composes game atoms, score/life HUD, pause and restart flows.': {de: 'Die JSON-App kombiniert Spiel-Atoms, Punkte-/Leben-HUD, Pause- und Neustart-Abläufe.', es: 'La JSON App compone los átomos del juego, el HUD de puntuación/vidas y los flujos de pausa y reinicio.', fr: 'L\'appli JSON assemble les atomes de jeu, le HUD score/vies, la pause et le redémarrage.', pt: 'A JSON App combina átomos de jogo, HUD de pontuação/vidas e fluxos de pausa e reinício.', ca: 'L\'app JSON combina àtoms de joc, HUD de punts/vides i fluxos de pausa i reinici.', hi: 'JSON App गेम atoms, स्कोर/लाइफ HUD, पॉज़ और रीस्टार्ट फ्लो जोड़ता है।', ko: 'JSON App이 게임 atom, 점수/생명 HUD, 일시정지 및 재시작 흐름을 구성합니다.', ja: 'JSON App がゲーム atom・スコア/ライフ HUD・一時停止と再開フローを構成します。', it: 'L\'app JSON compone gli atomi di gioco, HUD punteggio/vite, pausa e riavvio.'},
  'Game': {de: 'Spiel', es: 'Juego', fr: 'Jeu', pt: 'Jogo', ca: 'Joc', hi: 'गेम', ko: '게임', ja: 'ゲーム', it: 'Gioco'},
  'State': {de: 'Status', es: 'Estado', fr: 'État', pt: 'Estado', ca: 'Estat', hi: 'स्टेट', ko: '상태', ja: '状態', it: 'Stato'},
  'Motion': {de: 'Animation', es: 'Animación', fr: 'Animation', pt: 'Movimento', ca: 'Moviment', hi: 'मोशन', ko: '애니메이션', ja: 'アニメーション', it: 'Movimento'},
  'Creator community': {de: 'Creator-Community', es: 'Comunidad de creadores', fr: 'Communauté de créateurs', pt: 'Comunidade de criadores', ca: 'Comunitat de creadors', hi: 'क्रिएटर कम्युनिटी', ko: '크리에이터 커뮤니티', ja: 'クリエイターコミュニティ', it: 'Community per creator'},
  'Make a lifestyle content app with feed, publish, favorites and profile': {de: 'Erstelle eine Lifestyle-Content-App mit Feed, Veröffentlichen, Favoriten und Profil', es: 'Crea una app de contenido de estilo de vida con feed, publicación, favoritos y perfil', fr: 'Créez une appli de contenu lifestyle avec fil, publication, favoris et profil', pt: 'Faz uma app de conteúdo de estilo de vida com feed, publicação, favoritos e perfil', ca: 'Fes una app de contingut d\'estil de vida amb feed, publicació, preferits i perfil', hi: 'फ़ीड, पब्लिश, पसंदीदा और प्रोफ़ाइल वाला लाइफस्टाइल कंटेंट App बनाएं', ko: '피드, 게시, 즐겨찾기, 프로필을 갖춘 라이프스타일 콘텐츠 앱 만들기', ja: 'フィード・投稿・お気に入り・プロフィール付きのライフスタイルアプリを作成', it: 'Crea un\'app di contenuti lifestyle con feed, pubblicazione, preferiti e profilo'},
  'The precompiled runtime renders tabs, feeds and profile screens from JSON.': {de: 'Die vorkompilierte Runtime rendert Tabs, Feeds und Profilseiten aus JSON.', es: 'El runtime precompilado renderiza pestañas, feeds y pantallas de perfil desde JSON.', fr: 'Le runtime précompilé affiche les onglets, les fils et les écrans de profil à partir du JSON.', pt: 'O runtime pré-compilado renderiza separadores, feeds e ecrãs de perfil a partir de JSON.', ca: 'El runtime precompilat renderitza pestanyes, feeds i pantalles de perfil a partir de JSON.', hi: 'प्रीकंपाइल्ड रनटाइम JSON से टैब, फ़ीड और प्रोफ़ाइल स्क्रीन रेंडर करता है।', ko: '사전 컴파일된 런타임이 JSON에서 탭, 피드, 프로필 화면을 렌더링합니다.', ja: 'プリコンパイル済みランタイムが JSON からタブ・フィード・プロフィール画面を描画します。', it: 'Il runtime precompilato genera schede, feed e schermate del profilo dal JSON.'},
  'Community': {de: 'Community', es: 'Comunidad', fr: 'Communauté', pt: 'Comunidade', ca: 'Comunitat', hi: 'कम्युनिटी', ko: '커뮤니티', ja: 'コミュニティ', it: 'Community'},
  'Feed': {de: 'Feed', es: 'Feed', fr: 'Fil', pt: 'Feed', ca: 'Feed', hi: 'फ़ीड', ko: '피드', ja: 'フィード', it: 'Feed'},
  'Profile': {de: 'Profil', es: 'Perfil', fr: 'Profil', pt: 'Perfil', ca: 'Perfil', hi: 'प्रोफ़ाइल', ko: '프로필', ja: 'プロフィール', it: 'Profilo'},
  'Generated examples': {de: 'Generierte Beispiele', es: 'Ejemplos generados', fr: 'Exemples générés', pt: 'Exemplos gerados', ca: 'Exemples generats', hi: 'जनरेटेड उदाहरण', ko: '생성된 예시', ja: '生成事例', it: 'Esempi generati'},
};
function tl(lang: Lang, zh: string, en: string): string {
  if (lang === 'zh') return zh;
  return docsI18n[en]?.[lang] ?? en;
}

function PhonePreview({ compact = false, lang }: { compact?: boolean; lang: Lang }) {
  return (
    <div className={`phoneStage ${compact ? 'compact' : ''}`} aria-label="MyApp live web preview">
      <div className="phoneGlow" />
      <div className="phoneShell">
        <div className="sideButton sideButtonPower" />
        <div className="sideButton sideButtonVolumeUp" />
        <div className="sideButton sideButtonVolumeDown" />
        <div className="phoneScreen">
          <div className="phoneStatusBar" aria-hidden="true">
            <span>9:41</span>
            <div className="phoneStatusIcons">
              <span className="phoneSignal"><i /><i /><i /></span>
              <span className="phoneWifi"><i /><i /><i /></span>
              <span className="phoneBattery"><i /></span>
            </div>
          </div>
          <div className="phoneDynamicIsland" aria-hidden="true" />
          <div className="phoneViewport">
            <iframe
              title="MyApp live Web client"
              src={`${WEB_APP_URL}?lang=${lang}`}
              loading="eager"
              referrerPolicy="no-referrer"
              allow="clipboard-read; clipboard-write; camera; microphone"
            />
          </div>
        </div>
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

function ArchitectureDiagram({ lang }: { lang: Lang }) {
  const groups = [
    {
      title: tl(lang, '入口', 'Entry'),
      icon: Smartphone,
      nodes: [
        [tl(lang, 'Web 客户端', 'Web client'), 'Cloudflare Pages / Flutter Web'],
        [tl(lang, 'iOS / Android', 'iOS / Android'), 'TestFlight / APK / Play'],
      ],
    },
    {
      title: tl(lang, '运行时', 'Runtime'),
      icon: Layers3,
      nodes: [
        [tl(lang, 'JSON DSL 解释器', 'JSON DSL interpreter'), tl(lang, '只组合已编译能力', 'compiled capabilities only')],
        [tl(lang, 'IM / 游戏 / 媒体 atoms', 'IM / game / media atoms'), tl(lang, '通用能力层', 'general capability layer')],
      ],
    },
    {
      title: tl(lang, '后端', 'Backend'),
      icon: Server,
      nodes: [
        [tl(lang, 'Flask API + SSE', 'Flask API + SSE'), tl(lang, '会话、鉴权、恢复', 'sessions, auth, recovery')],
        [tl(lang, 'AI Worker Queue', 'AI worker queue'), tl(lang, 'Redis 队列 + Agent 执行', 'Redis queue + agents')],
      ],
    },
    {
      title: tl(lang, '平台服务', 'Platform services'),
      icon: Network,
      nodes: [
        [tl(lang, 'Registry / Config Center', 'Registry / config center'), tl(lang, 'JSON App、版本、APK', 'JSON Apps, versions, APK')],
        [tl(lang, 'User Center / OpenIM', 'User center / OpenIM'), tl(lang, '用户、好友、消息', 'users, friends, messages')],
      ],
    },
    {
      title: tl(lang, '数据与资产', 'Data and assets'),
      icon: Database,
      nodes: [
        ['Postgres / Redis', tl(lang, '业务数据、队列、会话', 'business data, queues, sessions')],
        ['OSS / MinIO', tl(lang, 'JSON、图片、安装包', 'JSON, media, release files')],
      ],
    },
  ];

  return (
    <div className="architecturePanel">
      <div className="archHeader">
        <div>
          <p className="eyebrow">{tl(lang, '系统架构', 'System architecture')}</p>
          <h3>{tl(lang, '客户端解释 JSON，后端负责生成、分发和恢复任务', 'Clients interpret JSON; backend generates, distributes and resumes work')}</h3>
        </div>
        {GITHUB_PUBLIC ? (
          <a className="inlineLink" href={GITHUB_URL} target="_blank" rel="noreferrer">
            <Github size={16} />
            GitHub
          </a>
        ) : (
          <span className="inlineLink disabledLink">
            <Github size={16} />
            {tl(lang, 'GitHub 即将公开', 'GitHub coming soon')}
          </span>
        )}
      </div>
      <div className="archDiagram" aria-label={tl(lang, 'MyApp 系统架构图', 'MyApp system architecture diagram')}>
        {groups.map((group, index) => {
          const Icon = group.icon;
          return (
            <div className="archColumn" key={group.title}>
              <div className="archColumnTitle">
                <Icon size={18} />
                <span>{group.title}</span>
              </div>
              <div className="archNodes">
                {group.nodes.map(([title, body]) => (
                  <div className="archNode" key={title}>
                    <strong>{title}</strong>
                    <span>{body}</span>
                  </div>
                ))}
              </div>
              {index < groups.length - 1 ? (
                <div className="archArrow" aria-hidden="true">
                  <ChevronRight size={18} />
                </div>
              ) : null}
            </div>
          );
        })}
      </div>
      <div className="archLegend">
        <span>{tl(lang, '声明式 JSON App', 'Declarative JSON Apps')}</span>
        <span>{tl(lang, '通用 Flutter 能力层', 'General Flutter capability layer')}</span>
        <span>{tl(lang, '可私有部署后端', 'Self-hostable backend')}</span>
      </div>
    </div>
  );
}

function ValueArchitecture({ lang }: { lang: Lang }) {
  const steps = [
    [tl(lang, '描述需求', 'Describe an idea'), tl(lang, '用户说清楚要什么工具、游戏或页面。', 'User describes a tool, game or screen.')],
    [tl(lang, '生成 JSON App', 'Generate JSON App'), tl(lang, 'AI 输出声明式 JSON，并通过校验。', 'AI produces declarative JSON and validation passes.')],
    [tl(lang, '跨端运行', 'Run everywhere'), tl(lang, '同一份 JSON 在 Web、iOS、Android 运行时中渲染。', 'One JSON renders in Web, iOS and Android runtimes.')],
  ];

  return (
    <div className="valueArchPanel">
      <div className="valueArchFlow">
        {steps.map(([title, body], index) => (
          <article key={title}>
            <span>{String(index + 1).padStart(2, '0')}</span>
            <h3>{title}</h3>
            <p>{body}</p>
          </article>
        ))}
      </div>
      <div className="valueArchProof">
        <ShieldCheck size={22} />
        <div>
          <strong>{tl(lang, '审核友好的边界', 'Review-friendly boundary')}</strong>
          <span>
            {tl(
              lang,
              'AI 只能组合已编译进客户端的通用控件和动作，不能下发原生代码、插件或二进制。',
              'AI can only compose compiled widgets and actions. It cannot ship native code, plugins or binaries.',
            )}
          </span>
        </div>
      </div>
    </div>
  );
}

function DocsPage({ lang }: { lang: Lang }) {
  // myapp-ctl supports all 11 framework languages, so show the visitor's own code in CLI examples
  const cliLang = lang;
  const docs = {
    badge: tl(lang, 'myapp-ctl 部署手册', 'myapp-ctl deployment guide'),
    title: tl(lang, '用 myapp-ctl 安装、部署、更新和扩展 MyApp', 'Install, deploy, update and extend MyApp with myapp-ctl'),
    subtitle: tl(
      lang,
      '当前后端统一走 deploy/production 下的 myapp-ctl。旧 bootstrap、裸跑服务和手工迁移路径已经废弃。',
      'The backend is now managed through myapp-ctl under deploy/production. Legacy bootstrap scripts, bare services and one-off migration paths are deprecated.',
    ),
    quickTitle: tl(lang, '最快全新部署', 'Fast fresh deploy'),
    quickBody: tl(
      lang,
      '准备一台 Ubuntu 主机、Docker 和仓库源码。先安装 myapp-ctl，再配置密钥，最后部署整套后端并把客户端环境 JSON 导入 App。',
      'Prepare an Ubuntu host, Docker and a source checkout. Install myapp-ctl, configure secrets, deploy the stack, then import the client environment JSON into the app.',
    ),
    backendTitle: tl(lang, '后端安装和首次配置', 'Backend install and first setup'),
    backendBody: tl(
      lang,
      'myapp-ctl 负责安装控制入口、生成基础密钥、管理 AI/SMTP/推送配置、部署 Docker 服务并输出客户端导入二维码。生产密钥只写入 /etc/myapp 和 data root，不进入 Git。',
      'myapp-ctl installs the control entrypoint, generates base secrets, manages AI/SMTP/push configuration, deploys Docker services and prints a client import QR code. Production secrets stay under /etc/myapp and the data root, never Git.',
    ),
    clientTitle: tl(lang, '客户端接入', 'Client connection'),
    clientBody: tl(
      lang,
      'Web、iOS TestFlight、Android APK 都可以连接私有后端。打开 Service Environment 页面，扫码或粘贴 myapp-ctl 输出的 JSON，保存后重新登录。',
      'Web, iOS TestFlight and Android APK can all connect to a private backend. Open Service Environment, scan or paste the JSON printed by myapp-ctl, save and sign in again.',
    ),
    buildTitle: tl(lang, '客户端和官网构建', 'Client and website builds'),
    websiteTitle: tl(lang, '官网发布', 'Website deployment'),
    releaseTitle: tl(lang, '发布和分发', 'Release and distribution'),
    releaseBody: tl(
      lang,
      'JSON App 通过 Registry 发布并存到 OSS/MinIO；Android APK 走配置中心上传到固定对象路径；Flutter Web 客户端构建到 build/web；官网是 website 目录下的 Vite 站点。iOS 通过 TestFlight 分发。',
      'JSON Apps are published through Registry and stored in OSS/MinIO. Android APK uploads through config center to a fixed object path. Flutter Web client builds to build/web; this marketing website is the Vite app under website. iOS is distributed through TestFlight.',
    ),
    configTitle: tl(lang, '配置和安全边界', 'Configuration and security boundary'),
    configBody: tl(
      lang,
      'AI 生成的是声明式 JSON，不下发 Dart、Swift、Kotlin、插件或二进制。运行时只解释客户端已经编译进包内的通用控件、动作和媒体能力。',
      'AI produces declarative JSON, not Dart, Swift, Kotlin, plugins or binaries. The runtime only interprets generic widgets, actions and media capabilities already compiled into the client.',
    ),
  };
  const quickSteps = [
    [
      tl(lang, '安装控制器', 'Install control CLI'),
      tl(lang, '在源码根目录运行 install_ctl.sh，myapp-ctl 会记录当前 checkout 作为 build context。', 'Run install_ctl.sh from the source root; myapp-ctl records that checkout as the build context.'),
    ],
    [
      tl(lang, '交互配置', 'Configure secrets'),
      tl(lang, 'setup 会配置语言、data root、AI 供应商、SMTP、APNs、FCM、GeTui 等。', 'setup configures language, data root, AI providers, SMTP, APNs, FCM and GeTui.'),
    ],
    [
      tl(lang, '部署服务', 'Deploy services'),
      tl(lang, 'deploy --build 从源码构建；deploy --pull 使用已发布镜像。', 'deploy --build builds from source; deploy --pull uses published images.'),
    ],
    [
      tl(lang, '连接客户端', 'Connect clients'),
      tl(lang, 'client-env 输出 JSON 和二维码，客户端导入后重新登录。', 'client-env prints JSON and a QR code; import it in the client and sign in again.'),
    ],
  ];
  const stackItems = [
    [
      tl(lang, '核心服务', 'Core services'),
      tl(lang, 'backend、ai-worker、Registry、Config Center、User Center', 'backend, ai-worker, Registry, Config Center and User Center'),
    ],
    [
      tl(lang, '基础设施', 'Infrastructure'),
      tl(lang, 'JSON App Postgres、AI Redis、App MinIO、Supabase、OpenIM', 'JSON App Postgres, AI Redis, App MinIO, Supabase and OpenIM'),
    ],
    [
      tl(lang, 'AI 执行', 'AI execution'),
      tl(lang, 'agent-node 调度 Docker runtime，Claude/Codex 在 Ubuntu 隔离容器中运行', 'agent-node schedules Docker runtimes; Claude/Codex run inside isolated Ubuntu containers'),
    ],
    [
      tl(lang, '持久数据', 'Persistent data'),
      tl(lang, '默认 data root 是 /mnt/myapp，数据库和对象存储都走本地 path bind mount', 'Default data root is /mnt/myapp; databases and object stores use local bind mounts'),
    ],
  ];
  const updateItems = [
    [tl(lang, '更新控制器', 'Refresh control files'), ['myapp-ctl update']],
    [tl(lang, '只改后端路由', 'Backend routes only'), ['myapp-ctl deploy backend --build --no-setup --no-test-user']],
    [tl(lang, '改 worker / prompt / validator', 'Worker / prompts / validators'), ['myapp-ctl deploy backend ai-worker --build --no-setup --no-test-user']],
    [tl(lang, '改 agent-node', 'agent-node changes'), ['myapp-ctl agent ls', 'myapp-ctl deploy agent-node --build --no-setup --no-test-user']],
    [tl(lang, '改 runtime 镜像', 'Runtime image changes'), ['myapp-ctl deploy agent-runtime --build --no-setup --no-test-user']],
    [tl(lang, '镜像部署主机', 'Image-based host'), ['myapp-ctl update', 'myapp-ctl deploy backend ai-worker --pull --no-setup --no-test-user']],
  ];
  const opsGroups = [
    {
      title: tl(lang, '服务运维', 'Service operations'),
      lines: [
        'myapp-ctl status',
        'myapp-ctl status backend ai-worker agent-node',
        'myapp-ctl restart backend ai-worker',
        'myapp-ctl log backend -f -n 120',
      ],
    },
    {
      title: tl(lang, '密钥和配置', 'Secrets and config'),
      lines: [
        'myapp-ctl secret ls',
        'myapp-ctl secret get <group> <key> --show',
        'myapp-ctl secret set <group> KEY=value',
        'myapp-ctl config view',
      ],
    },
    {
      title: tl(lang, '备份和恢复', 'Backup and restore'),
      lines: [
        'myapp-ctl config export --out /root/myapp-config.json',
        'myapp-ctl config export --redacted --out /root/myapp-config.redacted.json',
        'myapp-ctl config import /root/myapp-config.json --yes',
      ],
    },
    {
      title: tl(lang, '清理环境', 'Uninstall'),
      lines: [
        'myapp-ctl uninstall --yes',
        tl(lang, '# 配置和 data root 不会自动删除；确认销毁时手动 rm -rf /mnt/myapp', '# config and data root are preserved; manually rm -rf /mnt/myapp only when destroying data'),
      ],
    },
  ];
  const commandReferenceGroups = [
    {
      title: tl(lang, '生命周期和服务', 'Lifecycle and services'),
      body: tl(
        lang,
        '部署、更新、重启、日志和卸载。targets 可以是服务名，也可以配合 --group 使用 infra / supabase / openim / agent / core。',
        'Deploy, update, restart, logs and uninstall. Targets can be service names, or use --group with infra / supabase / openim / agent / core.',
      ),
      lines: [
        'myapp-ctl status [service ...] [--json]',
        'myapp-ctl deploy [target ...] [--build|--pull|--plan|--dry-run]',
        'myapp-ctl deploy --group infra|supabase|openim|agent|core --pull',
        'myapp-ctl restart [service ...]',
        'myapp-ctl log <service> [-n 120] [-f]',
        'myapp-ctl update [--source <checkout>] [--no-pull]',
        'myapp-ctl uninstall --yes [--volumes] [--images] [--remove-ctl]',
      ],
    },
    {
      title: tl(lang, '首次配置和密钥', 'Setup and secrets'),
      body: tl(
        lang,
        'setup 是交互式入口；secret 用来查看、生成、设置和删除服务器本机密钥。生产密钥不要写入 Git。',
        'setup is the interactive entrypoint; secret manages host-local credentials. Do not put production secrets in Git.',
      ),
      lines: [
        'myapp-ctl setup [--host <host>] [--data-root /mnt/myapp] [--force]',
        'myapp-ctl setup [--no-ai] [--no-asr] [--no-email] [--no-push]',
        'myapp-ctl secret init-stack [--host <host>] [--data-root /mnt/myapp] [--force]',
        'myapp-ctl secret ls',
        'myapp-ctl secret get <group> <key> [--show]',
        'myapp-ctl secret set <group> KEY=value [KEY2=value2 ...]',
        'myapp-ctl secret generate <group> KEY [KEY2 ...] [--bytes 32]',
        'myapp-ctl secret rm <group> KEY [KEY2 ...]',
      ],
    },
    {
      title: tl(lang, '配置、域名和客户端环境', 'Config, domains and client env'),
      body: tl(
        lang,
        '配置包可用于迁移和恢复；client-env 会输出客户端可导入的环境 JSON 和二维码。',
        'Config bundles are used for migration and recovery; client-env prints importable client JSON and QR codes.',
      ),
      lines: [
        'myapp-ctl config view [--show-secrets]',
        'myapp-ctl config export --out <path.json|path.yaml> [--redacted]',
        'myapp-ctl config import <path.json|path.yaml> --yes',
        'myapp-ctl config lang [zh|en|de|es|fr|pt|ca|hi|ko|ja|it]',
        'myapp-ctl domain ls',
        'myapp-ctl domain set <name> <url>',
        'myapp-ctl domain rm <name>',
        'myapp-ctl client-env [--host <host>] [--name <name>] [--json] [--terminal-qr]',
      ],
    },
    {
      title: tl(lang, '镜像', 'Images'),
      body: tl(
        lang,
        '镜像目标目前是 all、backend、agent-node、agent-runtime。--build 走源码，--pull 走已发布镜像。',
        'Current image targets are all, backend, agent-node and agent-runtime. --build uses source; --pull uses published images.',
      ),
      lines: [
        'myapp-ctl image ls',
        'myapp-ctl image build [all|backend|agent-node|agent-runtime]',
        'myapp-ctl image pull [all|backend|agent-node|agent-runtime]',
        'myapp-ctl image push [all|backend|agent-node|agent-runtime]',
      ],
    },
    {
      title: tl(lang, '公共 Agent Node', 'Public Agent Node'),
      body: tl(
        lang,
        'agent-node ls 是集群视角；agent ls 只看当前机器正在跑的 agent 容器。',
        'agent-node ls is the cluster view; agent ls is local-only and shows running agent containers on this host.',
      ),
      lines: [
        'myapp-ctl agent ls',
        'myapp-ctl agent-node ls [--namespace public|all|<user-id>] [--json] [--no-probe]',
        'myapp-ctl agent-node status [node-id] [--namespace public|all|<user-id>] [--json] [--no-probe]',
        'myapp-ctl agent-node add --backend <url> --host <host> --node-id <id> --name <name> [--pull|--build]',
        'myapp-ctl agent-node join --backend <url> --node-id <id> --name <name> --agent-token <token> --registration-token <token>',
        'myapp-ctl agent-node register --backend <url> --node-id <id> --url <url>',
        'myapp-ctl agent-node pause [node-id] [--reason <text>]',
        'myapp-ctl agent-node resume [node-id]',
        'myapp-ctl agent-node capacity <n> [--queue-max <n>]',
        'myapp-ctl agent-node limits --capacity <n> --queue-max <n>',
        'myapp-ctl agent-node rm <node-id>',
      ],
    },
    {
      title: tl(lang, '用户私有 Agent Node', 'User-private Agent Node'),
      body: tl(
        lang,
        '私有节点只服务所属用户，长效 provider key 留在节点本地。App 设置页会生成一次性 join token 和 join command。',
        'Private nodes serve only their owner, and long-lived provider keys stay on the node host. The app settings page creates a one-time join token and command.',
      ),
      lines: [
        'MYAPP_PRIVATE_AGENT_JOIN_TOKEN=<token> myapp-ctl agent-node private join --backend <url> --node-id <id> --name <name> --pull',
        'myapp-ctl agent-node private join --backend <url> --node-id <id> --name <name> --provider deepseek --agent claude --capacity 2 --queue-max 10',
        'myapp-ctl agent-node private ls',
        'myapp-ctl agent-node private status [node-id]',
        'myapp-ctl agent-node private ls --auth-token <user-token>',
      ],
    },
  ];

  return (
    <>
      <section className="docsHero" id="docs">
        <div className="shell docsHeroGrid">
          <div>
            <div className="badge">
              <BookOpen size={15} />
              <span>{docs.badge}</span>
            </div>
            <h1>{docs.title}</h1>
            <p className="lead">{docs.subtitle}</p>
            <div className="actions">
              {GITHUB_PUBLIC ? (
                <a className="button primary" href={GITHUB_URL} target="_blank" rel="noreferrer">
                  <Github size={17} />
                  GitHub
                </a>
              ) : (
                <span className="button secondary unavailable">
                  <Github size={17} />
                  {tl(lang, 'GitHub 即将公开', 'GitHub coming soon')}
                </span>
              )}
              <a className="button secondary" href={WEB_APP_URL} target="_blank" rel="noreferrer">
                <Play size={17} />
                {tl(lang, '打开 Web 版', 'Open Web app')}
              </a>
            </div>
          </div>
          <TerminalBox
            lines={[
              '$ git clone <repository-url> ai-app',
              '$ cd ai-app',
              '$ ./deploy/production/install_ctl.sh',
              '$ myapp-ctl setup --host <public-host> --data-root /mnt/myapp',
              '$ myapp-ctl deploy --build',
              '$ myapp-ctl client-env --terminal-qr',
            ]}
          />
        </div>
      </section>

      <section className="docsSection" id="quick-start">
        <div className="shell docsLayout">
          <aside className="docsToc">
            <a href="#quick-start">{docs.quickTitle}</a>
            <a href="#architecture-docs">{tl(lang, '架构图', 'Architecture')}</a>
            <a href="#install">{tl(lang, '安装部署', 'Install')}</a>
            <a href="#operations">{tl(lang, '更新运维', 'Operations')}</a>
            <a href="#cli-reference">{tl(lang, 'CLI 命令', 'CLI reference')}</a>
            <a href="#agent-nodes">{tl(lang, 'Agent Node', 'Agent Node')}</a>
            <a href="#private-agent">{tl(lang, '私有节点', 'Private nodes')}</a>
            <a href="#clients">{tl(lang, '客户端', 'Clients')}</a>
            <a href="#release">{docs.releaseTitle}</a>
          </aside>
          <div className="docsContent">
            <article className="docsBlock">
              <p className="eyebrow">{tl(lang, '推荐流程', 'Recommended flow')}</p>
              <h2>{docs.quickTitle}</h2>
              <p>{docs.quickBody}</p>
              <div className="docsSteps">
                {quickSteps.map(([title, body], index) => (
                  <div className="docsStep" key={title}>
                    <span>{String(index + 1).padStart(2, '0')}</span>
                    <strong>{title}</strong>
                    <small>{body}</small>
                  </div>
                ))}
              </div>
              <div className="docsBoundaryNote">
                <ShieldCheck size={18} />
                <p>
                  {tl(
                    lang,
                    '官网、Flutter Web 客户端和后端是三条不同发布路径：官网构建 website/dist，Flutter Web 客户端构建 build/web，后端通过 deploy/production 和 myapp-ctl 部署。',
                    'The website, Flutter Web client and backend are three separate release paths: website builds website/dist, Flutter Web client builds build/web, and backend deployment runs through deploy/production and myapp-ctl.',
                  )}
                </p>
              </div>
            </article>

            <article className="docsBlock architectureDocs" id="architecture-docs">
              <ArchitectureDiagram lang={lang} />
            </article>

            <article className="docsBlock" id="install">
              <p className="eyebrow">{tl(lang, '后端控制面', 'Backend control plane')}</p>
              <h2>{docs.backendTitle}</h2>
              <p>{docs.backendBody}</p>
              <div className="docsGrid">
                <div>
                  <h3>{tl(lang, '全新安装', 'Fresh install')}</h3>
                  <TerminalBox
                    lines={[
                      '$ git clone <repository-url> ai-app',
                      '$ cd ai-app',
                      '$ ./deploy/production/install_ctl.sh',
                      `$ myapp-ctl config lang ${cliLang}`,
                      '$ myapp-ctl setup --host <public-host> --data-root /mnt/myapp',
                      '$ myapp-ctl deploy --build',
                    ]}
                  />
                </div>
                <div>
                  <h3>{tl(lang, '镜像部署', 'Image-based deploy')}</h3>
                  <TerminalBox
                    lines={[
                      '$ ./deploy/production/install_ctl.sh',
                      '$ myapp-ctl setup --host <public-host> --data-root /mnt/myapp',
                      '$ myapp-ctl deploy --pull',
                      '$ myapp-ctl status',
                    ]}
                  />
                </div>
              </div>
              <div className="docsMiniGrid">
                {stackItems.map(([title, body]) => (
                  <div className="docsInfoTile" key={title}>
                    <strong>{title}</strong>
                    <span>{body}</span>
                  </div>
                ))}
              </div>
              <div className="docsCallout">
                <LockKeyhole size={18} />
                <p>
                  {tl(
                    lang,
                    'setup 会要求填写 AI 供应商。DeepSeek、MiniMax 或自定义 Anthropic-compatible provider 都通过环境变量写入服务器专用 env 文件；APNs、FCM、GeTui、SMTP 可跳过，跳过只影响对应通道。',
                    'setup asks for AI providers. DeepSeek, MiniMax or custom Anthropic-compatible providers are written into server-local env files. APNs, FCM, GeTui and SMTP are optional; skipping them only disables that channel.',
                  )}
                </p>
              </div>
            </article>

            <article className="docsBlock" id="operations">
              <p className="eyebrow">{tl(lang, '日常更新', 'Routine updates')}</p>
              <h2>{tl(lang, '按改动面部署，不要每次全量重启', 'Deploy only the changed surface')}</h2>
              <p>
                {tl(
                  lang,
                  '常规代码更新先运行 myapp-ctl update，再按改动范围重建或拉取对应组件。鉴权、Redis、Postgres、OpenIM、Supabase、MinIO 不需要因为普通后端或 agent 改动而重启。',
                  'For routine code updates, run myapp-ctl update first, then rebuild or pull only the changed components. Auth, Redis, Postgres, OpenIM, Supabase and MinIO should stay up for ordinary backend or agent changes.',
                )}
              </p>
              <div className="docsCommandList">
                {updateItems.map(([title, lines]) => (
                  <div className="docsCommandItem" key={title as string}>
                    <strong>{title}</strong>
                    <TerminalBox lines={lines as string[]} />
                  </div>
                ))}
              </div>
              <div className="docsGrid opsGrid">
                {opsGroups.map((item) => (
                  <div key={item.title}>
                    <h3>{item.title}</h3>
                    <TerminalBox lines={item.lines} />
                  </div>
                ))}
              </div>
            </article>

            <article className="docsBlock" id="cli-reference">
              <p className="eyebrow">{tl(lang, '命令参考', 'Command reference')}</p>
              <h2>{tl(lang, '常用二级命令和关键参数', 'Common subcommands and key flags')}</h2>
              <p>
                {tl(
                  lang,
                  '下面是官网内置的精简参考，覆盖当前主线最常用的二级命令。更细的参数以服务器上 myapp-ctl <命令> --help 为准。',
                  'This is the compact reference embedded in the website. For the full argument list, run myapp-ctl <command> --help on the host.',
                )}
              </p>
              <div className="docsCommandList">
                {commandReferenceGroups.map((item) => (
                  <div className="docsCommandItem" key={item.title}>
                    <strong>{item.title}</strong>
                    <small>{item.body}</small>
                    <TerminalBox lines={item.lines} />
                  </div>
                ))}
              </div>
              <div className="docsBoundaryNote">
                <ShieldCheck size={18} />
                <p>
                  {tl(
                    lang,
                    '兼容说明：myapp-ctl agent add 和 myapp-ctl agent register 仍是旧别名，新文档统一使用 agent-node add / register。',
                    'Compatibility note: myapp-ctl agent add and myapp-ctl agent register remain old aliases; new docs use agent-node add / register.',
                  )}
                </p>
              </div>
            </article>

            <article className="docsBlock" id="agent-nodes">
              <p className="eyebrow">{tl(lang, '公共 Agent Node', 'Public Agent Nodes')}</p>
              <h2>{tl(lang, '多机器 Agent 采用 pull 模式', 'Multi-host agents use pull mode')}</h2>
              <p>
                {tl(
                  lang,
                  '默认架构是 agent-node 主动轮询后端获取任务，客户端 SSE 仍然是 client -> backend。第二台 agent 机器只需要能出站访问后端，不需要公网入站端口。节点注册信息在 Postgres，运行队列和心跳在 Redis。',
                  'The default architecture is pull-based: agent-node polls the backend for work, while client SSE remains client -> backend. A secondary agent host only needs outbound access to the backend and no public inbound port. Node registration lives in Postgres; queues and heartbeats use Redis.',
                )}
              </p>
              <div className="docsGrid">
                <div>
                  <h3>{tl(lang, '主节点生成加入命令', 'Generate join command on master')}</h3>
                  <TerminalBox
                    lines={[
                      '$ myapp-ctl agent-node add \\',
                      '  --backend http://<master-host>:5566 \\',
                      '  --host <agent-host> \\',
                      '  --node-id myapp-agent-2 \\',
                      '  --name "GPU agent 2" \\',
                      '  --capacity 2 \\',
                      '  --mode pull \\',
                      '  --provider-mode master',
                    ]}
                  />
                </div>
                <div>
                  <h3>{tl(lang, '节点运维', 'Node operations')}</h3>
                  <TerminalBox
                    lines={[
                      '$ myapp-ctl agent-node ls',
                      '$ myapp-ctl agent-node pause myapp-agent-2 --reason maintenance',
                      '$ myapp-ctl agent-node limits --capacity 3 --queue-max 20',
                      '$ myapp-ctl agent-node resume myapp-agent-2',
                      '$ myapp-ctl agent ls',
                    ]}
                  />
                </div>
              </div>
              <div className="docsPillList">
                {[
                  ['KEY_SRC=master', tl(lang, '后端发送 provider 配置，agent-node 只拿一次性代理 token。', 'Backend sends provider config; agent-node mints one-time proxy tokens.')],
                  ['KEY_SRC=local', tl(lang, 'provider key 留在 agent 机器本地 ai-providers.env。', 'Provider keys stay in the agent host local ai-providers.env.')],
                  ['RUNS / CAP / QUEUE / QMAX', tl(lang, '分别表示当前运行、最大并发、当前队列和最大队列。', 'Current runs, max concurrency, current queue and max queue.')],
                  [tl(lang, '同会话亲和', 'Session affinity'), tl(lang, '同一个 session 后续打磨优先回到同一个在线节点。', 'Later turns of one session prefer the same online node.')],
                ].map(([title, body]) => (
                  <div className="docsPill" key={title}>
                    <strong>{title}</strong>
                    <span>{body}</span>
                  </div>
                ))}
              </div>
            </article>

            <article className="docsBlock" id="private-agent">
              <p className="eyebrow">{tl(lang, '用户私有 Agent Node', 'User-private Agent Nodes')}</p>
              <h2>{tl(lang, '普通用户可以接入自己的 agent 机器和 provider key', 'Users can attach their own agent host and provider keys')}</h2>
              <p>
                {tl(
                  lang,
                  '私有节点只服务所属用户。用户在 App 设置页生成一次性加入 token，节点本地交互填写 provider；长效 provider key 不上传到后端。客户端切换到私有调度时，只显示该用户私有节点上报的供应商。',
                  'Private nodes serve only their owner. The user creates a one-time join token in app settings, then configures provider keys locally on the node. Long-lived provider keys are never uploaded to the backend. When the client switches to private routing, it shows only providers reported by that user’s private nodes.',
                )}
              </p>
              <div className="docsGrid">
                <div>
                  <h3>{tl(lang, '用户侧流程', 'User flow')}</h3>
                  <ol className="docsOrdered">
                    {[
                      tl(lang, '登录 App，打开设置里的 Private Agent Node 页面。', 'Sign in to the app and open Private Agent Node in settings.'),
                      tl(lang, '在设置里确认当前 provider / agent 和调度模式，然后创建加入命令。', 'Confirm the current provider / agent and routing mode in settings, then create a join command.'),
                      tl(lang, '输入节点名称并复制 join command。', 'Enter a node name and copy the join command.'),
                      tl(lang, '在自己的机器上安装 myapp-ctl，执行 join command。', 'Install myapp-ctl on your own host and run the join command.'),
                      tl(lang, '按提示输入本节点自己的 DeepSeek / MiniMax / 自定义 provider 配置。', 'Enter this node’s own DeepSeek / MiniMax / custom provider configuration.'),
                      tl(lang, '回到 App，把 Agent 调度切到 private，只使用自己的节点。', 'Switch Agent routing to private in the app; only your nodes are used.'),
                    ].map((item) => (
                      <li key={item}>{item}</li>
                    ))}
                  </ol>
                </div>
                <div>
                  <h3>{tl(lang, '私有节点加入', 'Private node join')}</h3>
                  <TerminalBox
                    lines={[
                      "$ export MYAPP_PRIVATE_AGENT_JOIN_TOKEN='<copied from app>'",
                      '$ myapp-ctl agent-node private join \\',
                      '  --backend https://<backend-host> \\',
                      '  --node-id my-private-agent \\',
                      '  --name "My private agent" \\',
                      '  --provider deepseek \\',
                      '  --agent claude \\',
                      '  --capacity 2 --queue-max 10 --pull',
                    ]}
                  />
                </div>
              </div>
              <div className="docsBoundaryNote">
                <ShieldCheck size={18} />
                <p>
                  {tl(
                    lang,
                    '当前客户端调度只有 public 和 private 两种。public 使用公开节点池；private 只使用当前登录用户的私有节点，私有节点离线时不会自动回落公开节点。',
                    'Client routing currently has only public and private modes. public uses the platform pool; private uses only the signed-in user’s private nodes and does not automatically fall back to public when offline.',
                  )}
                </p>
              </div>
            </article>

            <article className="docsBlock" id="clients">
              <div className="docsGrid">
                <div>
                  <h2>{docs.clientTitle}</h2>
                  <p>{docs.clientBody}</p>
                  <TerminalBox
                    lines={[
                      '$ flutter pub get',
                      '$ flutter run -d chrome',
                      '$ flutter build apk --release',
                      '$ ./scripts/build_cloudflare_pages.sh',
                    ]}
                  />
                </div>
                <div>
                  <h2>{docs.websiteTitle}</h2>
                  <p>
                    {tl(
                      lang,
                      '官网是 website 目录下的 Vite 项目。发布到 Cloudflare Pages 时应构建 website/dist，不要和 Flutter Web 客户端的 build/web 混用。',
                      'The website is the Vite project under website. Deploy website/dist to Cloudflare Pages; do not confuse it with the Flutter Web client build/web output.',
                    )}
                  </p>
                  <TerminalBox
                    lines={[
                      '$ cd website',
                      '$ PATH=/home/fish/ai-app/.tools/node/bin:$PATH npm run build',
                      '# deploy website/dist with your Pages workflow',
                    ]}
                  />
                </div>
              </div>
            </article>

            <article className="docsBlock" id="release">
              <div className="docsGrid">
                <div>
                  <h2>{docs.releaseTitle}</h2>
                  <p>{docs.releaseBody}</p>
                  <TerminalBox
                    lines={[
                      '$ myapp-ctl client-env --host <public-host> --terminal-qr',
                      '$ cat /mnt/myapp/state/client-environment.json',
                      '$ myapp-ctl status',
                    ]}
                  />
                </div>
                <div id="runtime-boundary">
                  <h2>{docs.configTitle}</h2>
                  <p>{docs.configBody}</p>
                  <TerminalBox
                    lines={[
                      '$ curl -fsS http://127.0.0.1:5566/api/ai/providers',
                      '$ curl -fsS http://127.0.0.1:5590/health',
                      '$ myapp-ctl agent-node ls',
                    ]}
                  />
                </div>
              </div>
            </article>
          </div>
        </div>
      </section>
    </>
  );
}

function App() {
  const [lang, setLang] = useState<Lang>(() => {
    const q = new URLSearchParams(window.location.search).get('lang') || '';
    if (['zh', 'en', 'de', 'es', 'fr', 'pt', 'ca', 'hi', 'ko', 'ja', 'it'].includes(q)) {
      return q as Lang;
    }
    return navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en';
  });
  const [page, setPage] = useState<Page>(() => (window.location.pathname === '/docs' ? 'docs' : 'home'));
  const t = copy[lang];
  const activeLanguage = languageOptions.find((item) => item.key === lang) ?? languageOptions[1];
  const docsLabel = tl(lang, '文档', 'Docs');
  const trustTitle = 'trustTitle' in t ? t.trustTitle : lang === 'de' ? 'Vertrauensgrenze' : 'Límite de confianza';
  const trustPoints =
    'trustPoints' in t
      ? t.trustPoints
      : [
          [lang === 'de' ? 'Deklaratives JSON' : 'JSON declarativo', lang === 'de' ? 'Keine nativen Code- oder Binär-Downloads' : 'Sin código nativo ni binarios enviados por IA'],
          [lang === 'de' ? 'Self-hostable Backend' : 'Backend autoalojable', lang === 'de' ? 'myapp-ctl stellt die Kernservices bereit' : 'myapp-ctl despliega los servicios centrales'],
          [lang === 'de' ? 'Cross-client Runtime' : 'Runtime multiplataforma', lang === 'de' ? 'Web, iOS und Android teilen Fähigkeiten' : 'Web, iOS y Android comparten capacidades'],
        ];
  const docsTitle = 'docsTitle' in t ? t.docsTitle : docsLabel;
  const docsLinks =
    'docsLinks' in t
      ? t.docsLinks
      : [
          [docsLabel, lang === 'de' ? 'Backend starten und Client verbinden' : 'Desplegar backend y conectar cliente'],
          [lang === 'de' ? 'Architekturdiagramm' : 'Diagrama de arquitectura', lang === 'de' ? 'Runtime, Worker und Registry' : 'Runtime, Worker y Registry'],
          [lang === 'de' ? 'Runtime-Grenze' : 'Límite del runtime', lang === 'de' ? 'Vorkompiliertes Capability-Set und review-freundliche Grenze' : 'Set de capacidades precompilado y límite apto para revisión'],
        ];
  const showcaseCards = [
    {
      title: tl(lang, '露营装备管家', 'Camping kit planner'),
      prompt: tl(lang, '生成一个露营装备打包 App，支持清单、天气、共享备注', 'Build a camping packing app with checklist, weather and shared notes'),
      body: tl(lang, 'AI 生成清单、状态统计、团队备注和跨端运行界面。', 'AI creates checklist states, trip summary, team notes and a cross-client UI.'),
      tags: [tl(lang, '工具', 'Tool'), tl(lang, '清单', 'Checklist'), tl(lang, '共享', 'Shared')],
    },
    {
      title: tl(lang, '星际跑酷小游戏', 'Star runner mini-game'),
      prompt: tl(lang, '横版星际跑酷：跳跃躲障碍，收集星星，分数和生命完整', 'Create a side-scrolling space runner with jump, obstacles, stars and lives'),
      body: tl(lang, 'JSON App 组合游戏 atoms、状态栏、暂停和重开流程。', 'JSON App composes game atoms, score/life HUD, pause and restart flows.'),
      tags: [tl(lang, '游戏', 'Game'), tl(lang, '状态', 'State'), tl(lang, '动画', 'Motion')],
    },
    {
      title: tl(lang, '小型社区空间', 'Creator community'),
      prompt: tl(lang, '做一个小红书风格的内容社区，有首页、发布、收藏、个人页', 'Make a lifestyle content app with feed, publish, favorites and profile'),
      body: tl(lang, '用预编译运行时渲染多 tab、内容流和个人资料体验。', 'The precompiled runtime renders tabs, feeds and profile screens from JSON.'),
      tags: [tl(lang, '社区', 'Community'), tl(lang, '内容流', 'Feed'), tl(lang, '个人页', 'Profile')],
    },
  ];
  const downloadOptions = [
    {
      title: tl(lang, 'Web 立即体验', 'Web app'),
      body: tl(lang, '无需安装，直接打开线上 Web 客户端。', 'No install required. Open the hosted Web client.'),
      href: WEB_APP_URL,
      icon: Play,
      status: tl(lang, '可用', 'Available'),
      primary: true,
    },
    {
      title: 'iOS TestFlight',
      body: tl(lang, 'Public Group 1 已开放，适合真实手机体验。', 'Public Group 1 is open for real-device testing.'),
      href: TESTFLIGHT_URL,
      icon: Smartphone,
      status: tl(lang, '2500 人公开组', 'Public group'),
      primary: false,
    },
    {
      title: tl(lang, 'Android APK', 'Android APK'),
      body: tl(lang, '固定链接下载最新版 APK；Google Play 正在准备。', 'Download the latest APK from a fixed link. Google Play is preparing.'),
      href: APK_URL,
      icon: Download,
      status: tl(lang, '直接下载', 'Direct download'),
      primary: false,
    },
    {
      title: tl(lang, '自部署后端', 'Self-host backend'),
      body: tl(lang, '用自己的后端连接 Web、iOS 或 Android 客户端。', 'Connect Web, iOS or Android clients to your backend.'),
      href: '/docs',
      icon: Server,
      status: tl(lang, '文档', 'Docs'),
      primary: false,
    },
  ];

  useEffect(() => {
    const onPopState = () => {
      setPage(window.location.pathname === '/docs' ? 'docs' : 'home');
    };
    window.addEventListener('popstate', onPopState);
    return () => window.removeEventListener('popstate', onPopState);
  }, []);

  // 切语言时把 lang 写进 URL（?lang=xx），刷新后仍保持；同时下方内嵌 iframe 的 src 也会带上它。
  function changeLang(next: Lang) {
    setLang(next);
    const u = new URL(window.location.href);
    u.searchParams.set('lang', next);
    window.history.replaceState(null, '', u.pathname + u.search + u.hash);
  }

  function goHome(event: ReactMouseEvent<HTMLAnchorElement>, hash = '#top') {
    event.preventDefault();
    setPage('home');
    const h = hash === '#top' ? '' : hash;
    window.history.pushState(null, '', `/?lang=${lang}${h}`);
    requestAnimationFrame(() => document.querySelector(hash)?.scrollIntoView({ behavior: 'smooth' }));
  }

  function goDocs(event: ReactMouseEvent<HTMLAnchorElement>, hash = '#docs') {
    event.preventDefault();
    setPage('docs');
    const h = hash === '#docs' ? '' : hash;
    window.history.pushState(null, '', `/docs?lang=${lang}${h}`);
    requestAnimationFrame(() => {
      if (hash === '#docs') {
        window.scrollTo({ top: 0, behavior: 'smooth' });
      } else {
        document.querySelector(hash)?.scrollIntoView({ behavior: 'smooth' });
      }
    });
  }

  return (
    <main className="site">
      <nav className="nav">
        <div className="shell navInner">
          <a className="brand" href="/" aria-label="MyApp" onClick={(event) => goHome(event)}>
            My<span>App</span>
          </a>
          <div className="navLinks">
            <a href="/#deploy" onClick={(event) => goHome(event, '#deploy')}>
              {t.navHow}
            </a>
            <a href="/#stack" onClick={(event) => goHome(event, '#stack')}>
              {t.navStack}
            </a>
            <a href="/#videos" onClick={(event) => goHome(event, '#videos')}>
              {t.navTry}
            </a>
            <a href="/#features" onClick={(event) => goHome(event, '#features')}>
              {t.navFeatures}
            </a>
            <a href="/#download" onClick={(event) => goHome(event, '#download')}>
              {t.navDownload}
            </a>
            <a href="/docs" onClick={goDocs}>
              {docsLabel}
            </a>
          </div>
          <div className="navActions">
            <a className="navIconLink mobileDocsLink" href="/docs" onClick={goDocs} aria-label={docsLabel}>
              <BookOpen size={17} />
              <span>{docsLabel}</span>
            </a>
            {GITHUB_PUBLIC ? (
              <a className="navIconLink" href={GITHUB_URL} target="_blank" rel="noreferrer" aria-label="GitHub">
                <Github size={17} />
                <span>GitHub</span>
              </a>
            ) : (
              <span className="navIconLink disabledLink" aria-label={tl(lang, 'GitHub 即将公开', 'GitHub coming soon')}>
                <Github size={17} />
                <span>{tl(lang, 'GitHub 即将公开', 'GitHub soon')}</span>
              </span>
            )}
            <label className="languageSelect" aria-label="Language">
              <Globe2 size={16} />
              <span>{activeLanguage.flag}</span>
              <select value={lang} onChange={(event) => changeLang(event.target.value as Lang)}>
                {languageOptions.map((item) => (
                  <option key={item.key} value={item.key}>
                    {item.label}
                  </option>
                ))}
              </select>
            </label>
          </div>
        </div>
      </nav>

      {page === 'docs' ? (
        <DocsPage lang={lang} />
      ) : (
        <>
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
              <a className="button quiet" href={APK_URL} target="_blank" rel="noreferrer">
                <Download size={17} />
                APK
              </a>
            </div>
            <div className="heroLinkRow" aria-label={tl(lang, '快速入口', 'Quick links')}>
              <a href="/docs" onClick={goDocs}>
                <BookOpen size={15} />
                {docsLabel}
              </a>
              {GITHUB_PUBLIC ? (
                <a href={GITHUB_URL} target="_blank" rel="noreferrer">
                  <Github size={15} />
                  GitHub
                </a>
              ) : (
                <span>
                  <Github size={15} />
                  {tl(lang, 'GitHub 即将公开', 'GitHub soon')}
                </span>
              )}
              <a href={REVIEW_BOUNDARY_URL} onClick={(event) => goDocs(event, '#runtime-boundary')}>
                <ShieldCheck size={15} />
                {tl(lang, '合规边界', 'Review boundary')}
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
                <strong>Web</strong>
                <span>{tl(lang, '即开即用', 'open now')}</span>
              </div>
              <div>
                <strong>iOS</strong>
                <span>TestFlight</span>
              </div>
              <div>
                <strong>APK</strong>
                <span>{tl(lang, '直接下载', 'direct download')}</span>
              </div>
            </div>
          </div>
          <div className="heroAside">
            <PhonePreview lang={lang} />
            <p className="phoneCaption">{t.phoneCaption}</p>
            <p className="phoneReplayNote">{tl(lang, '演示为真实生成链路的录制、加速回放；多语言为后期补充。', 'The demo is an accelerated replay of a real, recorded generation run; multilingual support was added later.')}</p>
          </div>
        </div>
        <div className="shell heroTrustGrid">
          <div className="trustPanel" aria-labelledby="trust-title">
            <p className="eyebrow">{tl(lang, '为什么可信', 'Why it is credible')}</p>
            <h2 id="trust-title">{trustTitle}</h2>
            <div className="trustItems">
              {trustPoints.map(([title, body]) => (
                <article key={title}>
                  <CheckCircle2 size={18} />
                  <strong>{title}</strong>
                  <span>{body}</span>
                </article>
              ))}
            </div>
          </div>
          <div className="docsEntryPanel" aria-labelledby="docs-entry-title">
            <p className="eyebrow">{tl(lang, '继续了解', 'Keep exploring')}</p>
            <h2 id="docs-entry-title">{docsTitle}</h2>
            <div className="docsEntryLinks">
              {docsLinks.map(([title, body], index) => {
                const href = index === 2 ? REVIEW_BOUNDARY_URL : index === 1 ? '/#stack' : '/docs';
                const Icon = index === 2 ? ShieldCheck : index === 1 ? Network : BookOpen;
                const external = false;
                const onClick =
                  index === 0
                    ? goDocs
                    : index === 1
                      ? (event: ReactMouseEvent<HTMLAnchorElement>) => goHome(event, '#stack')
                      : (event: ReactMouseEvent<HTMLAnchorElement>) => goDocs(event, '#runtime-boundary');
                return (
                  <a href={href} key={title} onClick={onClick} target={external ? '_blank' : undefined} rel={external ? 'noreferrer' : undefined}>
                    <Icon size={18} />
                    <span>
                      <strong>{title}</strong>
                      <small>{body}</small>
                    </span>
                    <ChevronRight size={16} />
                  </a>
                );
              })}
            </div>
          </div>
        </div>
      </section>

      <section className="conceptSection" id="no-coding">
        <div className="shell">
          <img
            className="conceptHeroImg"
            src={`/images/pic01-${lang === 'zh' ? 'zh' : 'en'}.png`}
            alt={tl(lang, '你描述，AI 编排能力，应用即刻上线——没有代码库、不用构建', 'You describe it, AI arranges the capabilities, the app goes live — no codebase, no build')}
            loading="lazy"
          />
          <div className="conceptCopy">
            <p className="eyebrow">{tl(lang, '从 vibe 编程到不写代码', 'From vibe coding to no coding')}</p>
            <h2>{tl(lang, '开发到头来都是在和 AI 吵架，不如直接冲手机里的 App 吵', 'You end up arguing with the AI either way — so argue straight at the app in your hand')}</h2>
            <p>
              {tl(
                lang,
                'Vibe 编程——哪怕最好的 AI 应用生成器——仍然把你困在循环里：写命令、构建、打包、发布、发现 bug、和 AI 吵、再绕回来。我们把 coding 这一步整个删掉了：你直接对手机里的应用提需求，它就变。没有东西要编译、没有东西要发布、没有工程要打开。',
                'Vibe coding — even the best AI app builders — still keeps you in the loop: write commands, build, package, deploy, spot the bug, argue with the AI, loop back. We removed the coding step entirely: you talk your requirements straight to the app on your phone and it changes. Nothing to compile, nothing to publish, no project to open.',
              )}
            </p>
          </div>
          <div className="conceptCompare">
            <figure>
              <img
                src={`/images/vibe-vs-no-${lang === 'zh' ? 'zh' : 'en'}.png`}
                alt={tl(lang, '传统 vibe 编程 vs 不写代码的应用', 'Traditional vibe coding versus a no-coding app')}
                loading="lazy"
              />
              <figcaption>
                {tl(lang, '左：写命令 → 构建 → 发布 → 发现 bug → 循环。右：直接告诉手机“把按钮改成绿色”。', 'Left: write commands → build → deploy → find the bug → loop. Right: just tell your phone “make this button green.”')}
              </figcaption>
            </figure>
            <figure>
              <img
                src={`/images/argue-${lang === 'zh' ? 'zh' : 'en'}.png`}
                alt={tl(lang, '横竖都要和 AI 吵，不如直接冲手机吵', 'You argue with the AI either way — so argue straight at your phone')}
                loading="lazy"
              />
              <figcaption>
                {tl(lang, '既然横竖都要吵，就跳过整条工具链，直接冲手里的 App 吵。', 'If you are going to argue anyway, skip the whole toolchain and argue at the app in your hand.')}
              </figcaption>
            </figure>
          </div>
        </div>
      </section>

      <section className="videosSection" id="videos">
        <div className="shell">
          <div className="sectionHeader split">
            <div>
              <p className="eyebrow">{tl(lang, '生成案例', 'Generated examples')}</p>
              <h2>{t.videosTitle}</h2>
              <p>{t.videosSubtitle}</p>
            </div>
            <a className="button secondary" href={WEB_APP_URL} target="_blank" rel="noreferrer">
              <Play size={17} />
              {tl(lang, '直接试用', 'Try it live')}
            </a>
          </div>
          <div className="showcaseGrid">
            {showcaseCards.map((item, index) => (
              <article className="showcaseCard" key={item.title}>
                <div className={`showcasePreview showcasePreview-${index + 1}`}>
                  <div className="previewTop">
                    <span>{String(index + 1).padStart(2, '0')}</span>
                    <small>JSON App</small>
                  </div>
                  <div className="previewScreen">
                    {index === 0 ? (
                      <div className="previewChecklist">
                        <strong>{item.title}</strong>
                        <span><CheckCircle2 size={13} /> Tent packed</span>
                        <span><CheckCircle2 size={13} /> Water checked</span>
                        <span><CheckCircle2 size={13} /> Route shared</span>
                      </div>
                    ) : index === 1 ? (
                      <div className="previewGame">
                        <div className="gameHud">
                          <span>Score 420</span>
                          <span>Life 3</span>
                        </div>
                        <div className="gameScene">
                          <i className="planet" />
                          <i className="runner" />
                          <i className="star starA" />
                          <i className="star starB" />
                          <i className="block" />
                        </div>
                      </div>
                    ) : (
                      <div className="previewFeed">
                        <strong>{item.title}</strong>
                        <span className="feedHero" />
                        <span className="feedLine wide" />
                        <span className="feedLine" />
                        <div className="feedActions">
                          <small />
                          <small />
                          <small />
                        </div>
                      </div>
                    )}
                  </div>
                </div>
                <span className="showcasePrompt">{item.prompt}</span>
                <h3>{item.title}</h3>
                <p>{item.body}</p>
                <div className="showcaseTags">
                  {item.tags.map((tag) => (
                    <small key={tag}>{tag}</small>
                  ))}
                </div>
              </article>
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
              href={REVIEW_BOUNDARY_URL}
              onClick={(event) => goDocs(event, '#runtime-boundary')}
            >
              <ShieldCheck size={17} />
              Runtime boundary
            </a>
          </div>
          <div className="stackGrid">
            {t.stackItems.map(([title, body], index) => {
              const icons = [Layers3, Workflow, Server, PackageSearch];
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
          <ValueArchitecture lang={lang} />
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
              <div className="deployIcon"><Server size={20} /></div>
              <h3>{t.backendDeployTitle}</h3>
              <p>{tl(lang, '用 myapp-ctl 部署后端，管理密钥、服务状态和组件发布。', 'Use myapp-ctl to deploy the backend, manage secrets, inspect status and ship components.')}</p>
              <span className="deployMeta">{tl(lang, '后端优先', 'Backend first')}</span>
            </article>
            <article className="deployCard">
              <div className="deployIcon"><Smartphone size={20} /></div>
              <h3>{t.clientBuildTitle}</h3>
              <p>{tl(lang, '可以直接用线上 Web，也可以自行构建 Flutter Web、iOS 或 Android 客户端。', 'Use the hosted Web app directly, or build Flutter Web, iOS or Android yourself.')}</p>
              <span className="deployMeta">{tl(lang, '客户端可替换', 'Replaceable clients')}</span>
            </article>
            <article className="deployCard">
              <div className="deployIcon"><Network size={20} /></div>
              <h3>{t.switchEnvTitle}</h3>
              <p>{t.switchEnvBody}</p>
              <span className="deployMeta">{tl(lang, '扫码或粘贴', 'Scan or paste')}</span>
            </article>
            <article className="deployCard">
              <div className="deployIcon"><Bot size={20} /></div>
              <h3>{t.usageTitle}</h3>
              <p>{t.usageBody}</p>
              <a className="inlineLink" href={WEB_APP_URL} target="_blank" rel="noreferrer">
                {t.openWeb}
                <ChevronRight size={16} />
              </a>
              <a className="inlineLink" href="/docs" onClick={goDocs}>
                {docsLabel}
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
              const icons = [Bot, Server, Play, MessageCircle, Boxes, ShieldCheck, Cloud];
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

      <section className="authorNoteSection" id="why">
        <div className="shell">
          <div className="authorNotePanel">
            <p className="eyebrow">{t.authorNoteEyebrow}</p>
            <h2>{t.authorNoteTitle}</h2>
            {t.authorNoteBody.map((para) => (
              <p key={para}>{para}</p>
            ))}
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
          <div className="downloadGrid">
            {downloadOptions.map((item) => {
              const Icon = item.icon;
              const isDocs = item.href === '/docs';
              return (
                <a
                  className={`downloadCard ${item.primary ? 'primary' : ''}`}
                  href={item.href}
                  key={item.title}
                  onClick={isDocs ? goDocs : undefined}
                  target={isDocs ? undefined : '_blank'}
                  rel={isDocs ? undefined : 'noreferrer'}
                >
                  <div>
                    <Icon size={20} />
                    <span>{item.status}</span>
                  </div>
                  <strong>{item.title}</strong>
                  <p>{item.body}</p>
                  <small>
                    {tl(lang, '继续', 'Continue')}
                    <ChevronRight size={14} />
                  </small>
                </a>
              );
            })}
          </div>
        </div>
      </section>
        </>
      )}

      <footer className="footer">
        <div className="shell">
          <span>MyApp</span>
          <div className="footerLinks">
            {GITHUB_PUBLIC ? (
              <a href={GITHUB_URL} target="_blank" rel="noreferrer">
                GitHub
              </a>
            ) : (
              <span>{tl(lang, 'GitHub 即将公开', 'GitHub soon')}</span>
            )}
            <a href="mailto:2501808198@qq.com">fish</a>
          </div>
        </div>
      </footer>
    </main>
  );
}

export default App;
