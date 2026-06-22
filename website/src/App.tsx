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

type Lang = 'zh' | 'en' | 'de' | 'es';
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
];

const copy = {
  zh: {
    navHow: '部署',
    navStack: '架构',
    navTry: '演示',
    navFeatures: '能力',
    navDownload: '下载',
    badge: 'AI 生成应用 · Web / iOS / Android 已可体验',
    titleA: '一句话生成',
    titleB: '可运行的应用体验',
    subtitle:
      'MyApp 让用户用自然语言创建工具、游戏、社区页面和业务面板。AI 生成声明式 JSON App——需要后端时还会生成配套的 FaaS 后端——直接在 Web、TestFlight 或 Android APK 中运行，再通过对话继续迭代。',
    primaryCta: '打开 Web 版',
    secondaryCta: '加入 TestFlight',
    phoneCaption: '真实客户端同一套运行时：Web 立即打开，移动端可接入自部署后端。',
    heroConsoleTitle: '从提示词到可运行应用',
    heroConsoleLines: [
      '$ tell ai "生成一个露营装备打包 App"',
      '→ AI builds a JSON App',
      '→ personalize the experience',
      '→ run it on Web / iOS / Android',
    ],
    proofPoints: ['用户生成应用内容', 'AI 辅助构建和迭代', 'Web 与移动端同一生态'],
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
      ['AI 原生 DSL', '为大模型生成而设计，并渲染成真正的原生 UI，而不只是手写配置。'],
      ['全栈生成', 'AI 生成 JSON 应用，需要时再生成经校验的 Python/Flask 后端，部署到隔离的自研容器化 FaaS 运行时（无函数数量上限、自动 scale-to-zero、冷唤醒与扩缩容）。每个应用还自带隔离的 Postgres 数据库与应用级权限模型（所有者 / 维护者 / 消费者）——消费者数据由平台按调用者强制隔离，函数代码拿不到数据库连接。'],
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
    badge: 'AI-generated apps · Web / iOS / Android ready',
    titleA: 'Generate runnable',
    titleB: 'app experiences from one prompt',
    subtitle:
      'MyApp lets users create tools, games, community screens and dashboards with natural language. AI generates a declarative JSON App — and, when it needs one, a backend (FaaS) to go with it — that runs in Web, TestFlight or Android APK, then keeps improving through chat.',
    primaryCta: 'Open Web app',
    secondaryCta: 'Join TestFlight',
    phoneCaption: 'One real runtime across clients: open Web now, or connect mobile builds to your backend.',
    heroConsoleTitle: 'Prompt to runnable app',
    heroConsoleLines: [
      '$ tell ai "build a camping packing app"',
      '→ AI builds a JSON App',
      '→ personalize the experience',
      '→ run it on Web / iOS / Android',
    ],
    proofPoints: ['User-generated app content', 'AI-assisted building and iteration', 'One ecosystem across Web and mobile'],
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
      ['AI-native DSL', 'Structured for LLM generation and rendered to real native UI, not just hand-written config.'],
      ['Full-stack generation', 'AI emits the JSON app and, when needed, a validated Python/Flask backend deployed to an isolated self-managed containerized FaaS runtime (no function-count cap, automatic scale-to-zero, cold-wake and autoscaling). Each app also gets an isolated Postgres database and an application-level permission model (owner / maintainer / consumer) — consumer data is isolated per-caller by the platform, and function code never holds a database connection.'],
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
    badge: 'AI-App-Erstellung · Server-driven · Web / iOS / Android',
    titleA: 'Sag der KI, was du brauchst',
    titleB: 'und erhalte eine lauffähige App',
    subtitle:
      'Mit MyApp erstellen Nutzer Tools, Games, Community-Screens und Dashboards in natürlicher Sprache. Die KI erzeugt eine deklarative JSON App – bei Bedarf samt passendem FaaS-Backend – die sofort auf Web, iOS und Android läuft und per Chat weiter verbessert wird.',
    primaryCta: 'Live-Demo öffnen',
    secondaryCta: 'Deployment ansehen',
    phoneCaption: 'Web-Client-Vorschau. Für die echte Nutzung die gehostete Web-App öffnen.',
    heroConsoleTitle: 'Vom Prompt zur laufenden App',
    heroConsoleLines: [
      '$ tell ai "build an inventory app"',
      '→ validate JSON DSL',
      '→ prepare config + assets',
      '→ run on Web / iOS / Android',
    ],
    proofPoints: ['Nutzergenerierte App-Inhalte', 'KI-gestütztes Bauen und Iterieren', 'Ein Ökosystem für Web und Mobile'],
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
      ['AI-native DSL', 'Für LLM-Generierung gebaut und in echtes natives UI gerendert, nicht nur manuelle Konfiguration.'],
      ['Full-Stack-Generierung', 'Die KI erzeugt die JSON App und bei Bedarf ein validiertes Python/Flask-Backend in isolierter selbstverwalteter containerisierter FaaS-Runtime (keine Funktionsanzahl-Grenze, automatisches Scale-to-Zero, Cold-Wake und Autoscaling). Jede App erhält außerdem eine isolierte Postgres-Datenbank und ein Berechtigungsmodell auf App-Ebene (Owner / Maintainer / Consumer) — Consumer-Daten werden von der Plattform pro Aufrufer isoliert, und Funktionscode erhält nie eine Datenbankverbindung.'],
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
    badge: 'Apps con IA · Server-driven · Web / iOS / Android',
    titleA: 'Dile a la IA lo que quieres',
    titleB: 'y obtén una app funcional',
    subtitle:
      'Con MyApp, los usuarios crean herramientas, juegos, pantallas de comunidad y paneles con lenguaje natural. La IA genera una JSON App declarativa —y, cuando hace falta, su backend FaaS— que corre al instante en Web, iOS y Android y sigue mejorando por chat.',
    primaryCta: 'Abrir demo',
    secondaryCta: 'Ver despliegue',
    phoneCaption: 'Vista previa del cliente Web. Abre la Web hospedada para usarlo.',
    heroConsoleTitle: 'De prompt a app ejecutable',
    heroConsoleLines: [
      '$ tell ai "build an inventory app"',
      '→ validate JSON DSL',
      '→ prepare config + assets',
      '→ run on Web / iOS / Android',
    ],
    proofPoints: ['Contenido de apps generado por usuarios', 'Construcción e iteración asistidas por IA', 'Un ecosistema para Web y móvil'],
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
      ['DSL nativa para IA', 'Pensada para LLMs y renderizada como UI nativa real, no solo configuración manual.'],
      ['Generación full-stack', 'La IA genera la app JSON y, si hace falta, un backend Python/Flask validado en un runtime FaaS contenedorizado propio y aislado (sin límite de número de funciones, scale-to-zero automático, cold-wake y autoescalado). Cada app obtiene además una base de datos Postgres aislada y un modelo de permisos a nivel de aplicación (propietario / mantenedor / consumidor): los datos de cada consumidor quedan aislados por llamante en la plataforma, y el código de la función nunca tiene una conexión a la base de datos.'],
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
};

function PhonePreview({ compact = false }: { compact?: boolean }) {
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
              src={WEB_APP_URL}
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
  const zh = lang === 'zh';
  const groups = [
    {
      title: zh ? '入口' : 'Entry',
      icon: Smartphone,
      nodes: [
        [zh ? 'Web 客户端' : 'Web client', 'Cloudflare Pages / Flutter Web'],
        [zh ? 'iOS / Android' : 'iOS / Android', 'TestFlight / APK / Play'],
      ],
    },
    {
      title: zh ? '运行时' : 'Runtime',
      icon: Layers3,
      nodes: [
        [zh ? 'JSON DSL 解释器' : 'JSON DSL interpreter', zh ? '只组合已编译能力' : 'compiled capabilities only'],
        [zh ? 'IM / 游戏 / 媒体 atoms' : 'IM / game / media atoms', zh ? '通用能力层' : 'general capability layer'],
      ],
    },
    {
      title: zh ? '后端' : 'Backend',
      icon: Server,
      nodes: [
        [zh ? 'Flask API + SSE' : 'Flask API + SSE', zh ? '会话、鉴权、恢复' : 'sessions, auth, recovery'],
        [zh ? 'AI Worker Queue' : 'AI worker queue', zh ? 'Redis 队列 + Agent 执行' : 'Redis queue + agents'],
      ],
    },
    {
      title: zh ? '平台服务' : 'Platform services',
      icon: Network,
      nodes: [
        [zh ? 'Registry / Config Center' : 'Registry / config center', zh ? 'JSON App、版本、APK' : 'JSON Apps, versions, APK'],
        [zh ? 'User Center / OpenIM' : 'User center / OpenIM', zh ? '用户、好友、消息' : 'users, friends, messages'],
      ],
    },
    {
      title: zh ? '数据与资产' : 'Data and assets',
      icon: Database,
      nodes: [
        ['Postgres / Redis', zh ? '业务数据、队列、会话' : 'business data, queues, sessions'],
        ['OSS / MinIO', zh ? 'JSON、图片、安装包' : 'JSON, media, release files'],
      ],
    },
  ];

  return (
    <div className="architecturePanel">
      <div className="archHeader">
        <div>
          <p className="eyebrow">{zh ? '系统架构' : 'System architecture'}</p>
          <h3>{zh ? '客户端解释 JSON，后端负责生成、分发和恢复任务' : 'Clients interpret JSON; backend generates, distributes and resumes work'}</h3>
        </div>
        {GITHUB_PUBLIC ? (
          <a className="inlineLink" href={GITHUB_URL} target="_blank" rel="noreferrer">
            <Github size={16} />
            GitHub
          </a>
        ) : (
          <span className="inlineLink disabledLink">
            <Github size={16} />
            {zh ? 'GitHub 即将公开' : 'GitHub coming soon'}
          </span>
        )}
      </div>
      <div className="archDiagram" aria-label={zh ? 'MyApp 系统架构图' : 'MyApp system architecture diagram'}>
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
        <span>{zh ? '声明式 JSON App' : 'Declarative JSON Apps'}</span>
        <span>{zh ? '通用 Flutter 能力层' : 'General Flutter capability layer'}</span>
        <span>{zh ? '可私有部署后端' : 'Self-hostable backend'}</span>
      </div>
    </div>
  );
}

function ValueArchitecture({ lang }: { lang: Lang }) {
  const zh = lang === 'zh';
  const steps = [
    [zh ? '描述需求' : 'Describe an idea', zh ? '用户说清楚要什么工具、游戏或页面。' : 'User describes a tool, game or screen.'],
    [zh ? '生成 JSON App' : 'Generate JSON App', zh ? 'AI 输出声明式 JSON，并通过校验。' : 'AI produces declarative JSON and validation passes.'],
    [zh ? '跨端运行' : 'Run everywhere', zh ? '同一份 JSON 在 Web、iOS、Android 运行时中渲染。' : 'One JSON renders in Web, iOS and Android runtimes.'],
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
          <strong>{zh ? '审核友好的边界' : 'Review-friendly boundary'}</strong>
          <span>
            {zh
              ? 'AI 只能组合已编译进客户端的通用控件和动作，不能下发原生代码、插件或二进制。'
              : 'AI can only compose compiled widgets and actions. It cannot ship native code, plugins or binaries.'}
          </span>
        </div>
      </div>
    </div>
  );
}

function DocsPage({ lang }: { lang: Lang }) {
  const zh = lang === 'zh';
  const cliLang = lang === 'zh' ? 'zh' : lang === 'de' ? 'de' : lang === 'es' ? 'es' : 'en';
  const docs = {
    badge: zh ? 'myapp-ctl 部署手册' : 'myapp-ctl deployment guide',
    title: zh ? '用 myapp-ctl 安装、部署、更新和扩展 MyApp' : 'Install, deploy, update and extend MyApp with myapp-ctl',
    subtitle: zh
      ? '当前后端统一走 deploy/production 下的 myapp-ctl。旧 bootstrap、裸跑服务和手工迁移路径已经废弃。'
      : 'The backend is now managed through myapp-ctl under deploy/production. Legacy bootstrap scripts, bare services and one-off migration paths are deprecated.',
    quickTitle: zh ? '最快全新部署' : 'Fast fresh deploy',
    quickBody: zh
      ? '准备一台 Ubuntu 主机、Docker 和仓库源码。先安装 myapp-ctl，再配置密钥，最后部署整套后端并把客户端环境 JSON 导入 App。'
      : 'Prepare an Ubuntu host, Docker and a source checkout. Install myapp-ctl, configure secrets, deploy the stack, then import the client environment JSON into the app.',
    backendTitle: zh ? '后端安装和首次配置' : 'Backend install and first setup',
    backendBody: zh
      ? 'myapp-ctl 负责安装控制入口、生成基础密钥、管理 AI/SMTP/推送配置、部署 Docker 服务并输出客户端导入二维码。生产密钥只写入 /etc/myapp 和 data root，不进入 Git。'
      : 'myapp-ctl installs the control entrypoint, generates base secrets, manages AI/SMTP/push configuration, deploys Docker services and prints a client import QR code. Production secrets stay under /etc/myapp and the data root, never Git.',
    clientTitle: zh ? '客户端接入' : 'Client connection',
    clientBody: zh
      ? 'Web、iOS TestFlight、Android APK 都可以连接私有后端。打开 Service Environment 页面，扫码或粘贴 myapp-ctl 输出的 JSON，保存后重新登录。'
      : 'Web, iOS TestFlight and Android APK can all connect to a private backend. Open Service Environment, scan or paste the JSON printed by myapp-ctl, save and sign in again.',
    buildTitle: zh ? '客户端和官网构建' : 'Client and website builds',
    websiteTitle: zh ? '官网发布' : 'Website deployment',
    releaseTitle: zh ? '发布和分发' : 'Release and distribution',
    releaseBody: zh
      ? 'JSON App 通过 Registry 发布并存到 OSS/MinIO；Android APK 走配置中心上传到固定对象路径；Flutter Web 客户端构建到 build/web；官网是 website 目录下的 Vite 站点。iOS 通过 TestFlight 分发。'
      : 'JSON Apps are published through Registry and stored in OSS/MinIO. Android APK uploads through config center to a fixed object path. Flutter Web client builds to build/web; this marketing website is the Vite app under website. iOS is distributed through TestFlight.',
    configTitle: zh ? '配置和安全边界' : 'Configuration and security boundary',
    configBody: zh
      ? 'AI 生成的是声明式 JSON，不下发 Dart、Swift、Kotlin、插件或二进制。运行时只解释客户端已经编译进包内的通用控件、动作和媒体能力。'
      : 'AI produces declarative JSON, not Dart, Swift, Kotlin, plugins or binaries. The runtime only interprets generic widgets, actions and media capabilities already compiled into the client.',
  };
  const quickSteps = zh
    ? [
        ['安装控制器', '在源码根目录运行 install_ctl.sh，myapp-ctl 会记录当前 checkout 作为 build context。'],
        ['交互配置', 'setup 会配置语言、data root、AI 供应商、SMTP、APNs、FCM、GeTui 等。'],
        ['部署服务', 'deploy --build 从源码构建；deploy --pull 使用已发布镜像。'],
        ['连接客户端', 'client-env 输出 JSON 和二维码，客户端导入后重新登录。'],
      ]
    : [
        ['Install control CLI', 'Run install_ctl.sh from the source root; myapp-ctl records that checkout as the build context.'],
        ['Configure secrets', 'setup configures language, data root, AI providers, SMTP, APNs, FCM and GeTui.'],
        ['Deploy services', 'deploy --build builds from source; deploy --pull uses published images.'],
        ['Connect clients', 'client-env prints JSON and a QR code; import it in the client and sign in again.'],
      ];
  const stackItems = zh
    ? [
        ['核心服务', 'backend、ai-worker、Registry、Config Center、User Center'],
        ['基础设施', 'JSON App Postgres、AI Redis、App MinIO、Supabase、OpenIM'],
        ['AI 执行', 'agent-node 调度 Docker runtime，Claude/Codex 在 Ubuntu 隔离容器中运行'],
        ['持久数据', '默认 data root 是 /mnt/myapp，数据库和对象存储都走本地 path bind mount'],
      ]
    : [
        ['Core services', 'backend, ai-worker, Registry, Config Center and User Center'],
        ['Infrastructure', 'JSON App Postgres, AI Redis, App MinIO, Supabase and OpenIM'],
        ['AI execution', 'agent-node schedules Docker runtimes; Claude/Codex run inside isolated Ubuntu containers'],
        ['Persistent data', 'Default data root is /mnt/myapp; databases and object stores use local bind mounts'],
      ];
  const updateItems = zh
    ? [
        ['更新控制器', ['myapp-ctl update']],
        ['只改后端路由', ['myapp-ctl deploy backend --build --no-setup --no-test-user']],
        ['改 worker / prompt / validator', ['myapp-ctl deploy backend ai-worker --build --no-setup --no-test-user']],
        ['改 agent-node', ['myapp-ctl agent ls', 'myapp-ctl deploy agent-node --build --no-setup --no-test-user']],
        ['改 runtime 镜像', ['myapp-ctl deploy agent-runtime --build --no-setup --no-test-user']],
        ['镜像部署主机', ['myapp-ctl update', 'myapp-ctl deploy backend ai-worker --pull --no-setup --no-test-user']],
      ]
    : [
        ['Refresh control files', ['myapp-ctl update']],
        ['Backend routes only', ['myapp-ctl deploy backend --build --no-setup --no-test-user']],
        ['Worker / prompts / validators', ['myapp-ctl deploy backend ai-worker --build --no-setup --no-test-user']],
        ['agent-node changes', ['myapp-ctl agent ls', 'myapp-ctl deploy agent-node --build --no-setup --no-test-user']],
        ['Runtime image changes', ['myapp-ctl deploy agent-runtime --build --no-setup --no-test-user']],
        ['Image-based host', ['myapp-ctl update', 'myapp-ctl deploy backend ai-worker --pull --no-setup --no-test-user']],
      ];
  const opsGroups = zh
    ? [
        {
          title: '服务运维',
          lines: [
            'myapp-ctl status',
            'myapp-ctl status backend ai-worker agent-node',
            'myapp-ctl restart backend ai-worker',
            'myapp-ctl log backend -f -n 120',
          ],
        },
        {
          title: '密钥和配置',
          lines: [
            'myapp-ctl secret ls',
            'myapp-ctl secret get <group> <key> --show',
            'myapp-ctl secret set <group> KEY=value',
            'myapp-ctl config view',
          ],
        },
        {
          title: '备份和恢复',
          lines: [
            'myapp-ctl config export --out /root/myapp-config.json',
            'myapp-ctl config export --redacted --out /root/myapp-config.redacted.json',
            'myapp-ctl config import /root/myapp-config.json --yes',
          ],
        },
        {
          title: '清理环境',
          lines: [
            'myapp-ctl uninstall --yes',
            '# 配置和 data root 不会自动删除；确认销毁时手动 rm -rf /mnt/myapp',
          ],
        },
      ]
    : [
        {
          title: 'Service operations',
          lines: [
            'myapp-ctl status',
            'myapp-ctl status backend ai-worker agent-node',
            'myapp-ctl restart backend ai-worker',
            'myapp-ctl log backend -f -n 120',
          ],
        },
        {
          title: 'Secrets and config',
          lines: [
            'myapp-ctl secret ls',
            'myapp-ctl secret get <group> <key> --show',
            'myapp-ctl secret set <group> KEY=value',
            'myapp-ctl config view',
          ],
        },
        {
          title: 'Backup and restore',
          lines: [
            'myapp-ctl config export --out /root/myapp-config.json',
            'myapp-ctl config export --redacted --out /root/myapp-config.redacted.json',
            'myapp-ctl config import /root/myapp-config.json --yes',
          ],
        },
        {
          title: 'Uninstall',
          lines: [
            'myapp-ctl uninstall --yes',
            '# config and data root are preserved; manually rm -rf /mnt/myapp only when destroying data',
          ],
        },
      ];
  const commandReferenceGroups = zh
    ? [
        {
          title: '生命周期和服务',
          body: '部署、更新、重启、日志和卸载。targets 可以是服务名，也可以配合 --group 使用 infra / supabase / openim / agent / core。',
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
          title: '首次配置和密钥',
          body: 'setup 是交互式入口；secret 用来查看、生成、设置和删除服务器本机密钥。生产密钥不要写入 Git。',
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
          title: '配置、域名和客户端环境',
          body: '配置包可用于迁移和恢复；client-env 会输出客户端可导入的环境 JSON 和二维码。',
          lines: [
            'myapp-ctl config view [--show-secrets]',
            'myapp-ctl config export --out <path.json|path.yaml> [--redacted]',
            'myapp-ctl config import <path.json|path.yaml> --yes',
            'myapp-ctl config lang [zh|en|de|es]',
            'myapp-ctl domain ls',
            'myapp-ctl domain set <name> <url>',
            'myapp-ctl domain rm <name>',
            'myapp-ctl client-env [--host <host>] [--name <name>] [--json] [--terminal-qr]',
          ],
        },
        {
          title: '镜像',
          body: '镜像目标目前是 all、backend、agent-node、agent-runtime。--build 走源码，--pull 走已发布镜像。',
          lines: [
            'myapp-ctl image ls',
            'myapp-ctl image build [all|backend|agent-node|agent-runtime]',
            'myapp-ctl image pull [all|backend|agent-node|agent-runtime]',
            'myapp-ctl image push [all|backend|agent-node|agent-runtime]',
          ],
        },
        {
          title: '公共 Agent Node',
          body: 'agent-node ls 是集群视角；agent ls 只看当前机器正在跑的 agent 容器。',
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
          title: '用户私有 Agent Node',
          body: '私有节点只服务所属用户，长效 provider key 留在节点本地。App 设置页会生成一次性 join token 和 join command。',
          lines: [
            'MYAPP_PRIVATE_AGENT_JOIN_TOKEN=<token> myapp-ctl agent-node private join --backend <url> --node-id <id> --name <name> --pull',
            'myapp-ctl agent-node private join --backend <url> --node-id <id> --name <name> --provider deepseek --agent claude --capacity 2 --queue-max 10',
            'myapp-ctl agent-node private ls',
            'myapp-ctl agent-node private status [node-id]',
            'myapp-ctl agent-node private ls --auth-token <user-token>',
          ],
        },
      ]
    : [
        {
          title: 'Lifecycle and services',
          body: 'Deploy, update, restart, logs and uninstall. Targets can be service names, or use --group with infra / supabase / openim / agent / core.',
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
          title: 'Setup and secrets',
          body: 'setup is the interactive entrypoint; secret manages host-local credentials. Do not put production secrets in Git.',
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
          title: 'Config, domains and client env',
          body: 'Config bundles are used for migration and recovery; client-env prints importable client JSON and QR codes.',
          lines: [
            'myapp-ctl config view [--show-secrets]',
            'myapp-ctl config export --out <path.json|path.yaml> [--redacted]',
            'myapp-ctl config import <path.json|path.yaml> --yes',
            'myapp-ctl config lang [zh|en|de|es]',
            'myapp-ctl domain ls',
            'myapp-ctl domain set <name> <url>',
            'myapp-ctl domain rm <name>',
            'myapp-ctl client-env [--host <host>] [--name <name>] [--json] [--terminal-qr]',
          ],
        },
        {
          title: 'Images',
          body: 'Current image targets are all, backend, agent-node and agent-runtime. --build uses source; --pull uses published images.',
          lines: [
            'myapp-ctl image ls',
            'myapp-ctl image build [all|backend|agent-node|agent-runtime]',
            'myapp-ctl image pull [all|backend|agent-node|agent-runtime]',
            'myapp-ctl image push [all|backend|agent-node|agent-runtime]',
          ],
        },
        {
          title: 'Public Agent Node',
          body: 'agent-node ls is the cluster view; agent ls is local-only and shows running agent containers on this host.',
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
          title: 'User-private Agent Node',
          body: 'Private nodes serve only their owner, and long-lived provider keys stay on the node host. The app settings page creates a one-time join token and command.',
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
                  {zh ? 'GitHub 即将公开' : 'GitHub coming soon'}
                </span>
              )}
              <a className="button secondary" href={WEB_APP_URL} target="_blank" rel="noreferrer">
                <Play size={17} />
                {zh ? '打开 Web 版' : 'Open Web app'}
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
            <a href="#architecture-docs">{zh ? '架构图' : 'Architecture'}</a>
            <a href="#install">{zh ? '安装部署' : 'Install'}</a>
            <a href="#operations">{zh ? '更新运维' : 'Operations'}</a>
            <a href="#cli-reference">{zh ? 'CLI 命令' : 'CLI reference'}</a>
            <a href="#agent-nodes">{zh ? 'Agent Node' : 'Agent Node'}</a>
            <a href="#private-agent">{zh ? '私有节点' : 'Private nodes'}</a>
            <a href="#clients">{zh ? '客户端' : 'Clients'}</a>
            <a href="#release">{docs.releaseTitle}</a>
          </aside>
          <div className="docsContent">
            <article className="docsBlock">
              <p className="eyebrow">{zh ? '推荐流程' : 'Recommended flow'}</p>
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
                  {zh
                    ? '官网、Flutter Web 客户端和后端是三条不同发布路径：官网构建 website/dist，Flutter Web 客户端构建 build/web，后端通过 deploy/production 和 myapp-ctl 部署。'
                    : 'The website, Flutter Web client and backend are three separate release paths: website builds website/dist, Flutter Web client builds build/web, and backend deployment runs through deploy/production and myapp-ctl.'}
                </p>
              </div>
            </article>

            <article className="docsBlock architectureDocs" id="architecture-docs">
              <ArchitectureDiagram lang={lang} />
            </article>

            <article className="docsBlock" id="install">
              <p className="eyebrow">{zh ? '后端控制面' : 'Backend control plane'}</p>
              <h2>{docs.backendTitle}</h2>
              <p>{docs.backendBody}</p>
              <div className="docsGrid">
                <div>
                  <h3>{zh ? '全新安装' : 'Fresh install'}</h3>
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
                  <h3>{zh ? '镜像部署' : 'Image-based deploy'}</h3>
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
                  {zh
                    ? 'setup 会要求填写 AI 供应商。DeepSeek、MiniMax 或自定义 Anthropic-compatible provider 都通过环境变量写入服务器专用 env 文件；APNs、FCM、GeTui、SMTP 可跳过，跳过只影响对应通道。'
                    : 'setup asks for AI providers. DeepSeek, MiniMax or custom Anthropic-compatible providers are written into server-local env files. APNs, FCM, GeTui and SMTP are optional; skipping them only disables that channel.'}
                </p>
              </div>
            </article>

            <article className="docsBlock" id="operations">
              <p className="eyebrow">{zh ? '日常更新' : 'Routine updates'}</p>
              <h2>{zh ? '按改动面部署，不要每次全量重启' : 'Deploy only the changed surface'}</h2>
              <p>
                {zh
                  ? '常规代码更新先运行 myapp-ctl update，再按改动范围重建或拉取对应组件。鉴权、Redis、Postgres、OpenIM、Supabase、MinIO 不需要因为普通后端或 agent 改动而重启。'
                  : 'For routine code updates, run myapp-ctl update first, then rebuild or pull only the changed components. Auth, Redis, Postgres, OpenIM, Supabase and MinIO should stay up for ordinary backend or agent changes.'}
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
              <p className="eyebrow">{zh ? '命令参考' : 'Command reference'}</p>
              <h2>{zh ? '常用二级命令和关键参数' : 'Common subcommands and key flags'}</h2>
              <p>
                {zh
                  ? '下面是官网内置的精简参考，覆盖当前主线最常用的二级命令。更细的参数以服务器上 myapp-ctl <命令> --help 为准。'
                  : 'This is the compact reference embedded in the website. For the full argument list, run myapp-ctl <command> --help on the host.'}
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
                  {zh
                    ? '兼容说明：myapp-ctl agent add 和 myapp-ctl agent register 仍是旧别名，新文档统一使用 agent-node add / register。'
                    : 'Compatibility note: myapp-ctl agent add and myapp-ctl agent register remain old aliases; new docs use agent-node add / register.'}
                </p>
              </div>
            </article>

            <article className="docsBlock" id="agent-nodes">
              <p className="eyebrow">{zh ? '公共 Agent Node' : 'Public Agent Nodes'}</p>
              <h2>{zh ? '多机器 Agent 采用 pull 模式' : 'Multi-host agents use pull mode'}</h2>
              <p>
                {zh
                  ? '默认架构是 agent-node 主动轮询后端获取任务，客户端 SSE 仍然是 client -> backend。第二台 agent 机器只需要能出站访问后端，不需要公网入站端口。节点注册信息在 Postgres，运行队列和心跳在 Redis。'
                  : 'The default architecture is pull-based: agent-node polls the backend for work, while client SSE remains client -> backend. A secondary agent host only needs outbound access to the backend and no public inbound port. Node registration lives in Postgres; queues and heartbeats use Redis.'}
              </p>
              <div className="docsGrid">
                <div>
                  <h3>{zh ? '主节点生成加入命令' : 'Generate join command on master'}</h3>
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
                  <h3>{zh ? '节点运维' : 'Node operations'}</h3>
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
                {(zh
                  ? [
                      ['KEY_SRC=master', '后端发送 provider 配置，agent-node 只拿一次性代理 token。'],
                      ['KEY_SRC=local', 'provider key 留在 agent 机器本地 ai-providers.env。'],
                      ['RUNS / CAP / QUEUE / QMAX', '分别表示当前运行、最大并发、当前队列和最大队列。'],
                      ['同会话亲和', '同一个 session 后续打磨优先回到同一个在线节点。'],
                    ]
                  : [
                      ['KEY_SRC=master', 'Backend sends provider config; agent-node mints one-time proxy tokens.'],
                      ['KEY_SRC=local', 'Provider keys stay in the agent host local ai-providers.env.'],
                      ['RUNS / CAP / QUEUE / QMAX', 'Current runs, max concurrency, current queue and max queue.'],
                      ['Session affinity', 'Later turns of one session prefer the same online node.'],
                    ]).map(([title, body]) => (
                  <div className="docsPill" key={title}>
                    <strong>{title}</strong>
                    <span>{body}</span>
                  </div>
                ))}
              </div>
            </article>

            <article className="docsBlock" id="private-agent">
              <p className="eyebrow">{zh ? '用户私有 Agent Node' : 'User-private Agent Nodes'}</p>
              <h2>{zh ? '普通用户可以接入自己的 agent 机器和 provider key' : 'Users can attach their own agent host and provider keys'}</h2>
              <p>
                {zh
                  ? '私有节点只服务所属用户。用户在 App 设置页生成一次性加入 token，节点本地交互填写 provider；长效 provider key 不上传到后端。客户端切换到私有调度时，只显示该用户私有节点上报的供应商。'
                  : 'Private nodes serve only their owner. The user creates a one-time join token in app settings, then configures provider keys locally on the node. Long-lived provider keys are never uploaded to the backend. When the client switches to private routing, it shows only providers reported by that user’s private nodes.'}
              </p>
              <div className="docsGrid">
                <div>
                  <h3>{zh ? '用户侧流程' : 'User flow'}</h3>
                  <ol className="docsOrdered">
                    {(zh
                      ? [
                          '登录 App，打开设置里的 Private Agent Node 页面。',
                          '在设置里确认当前 provider / agent 和调度模式，然后创建加入命令。',
                          '输入节点名称并复制 join command。',
                          '在自己的机器上安装 myapp-ctl，执行 join command。',
                          '按提示输入本节点自己的 DeepSeek / MiniMax / 自定义 provider 配置。',
                          '回到 App，把 Agent 调度切到 private，只使用自己的节点。',
                        ]
                      : [
                          'Sign in to the app and open Private Agent Node in settings.',
                          'Confirm the current provider / agent and routing mode in settings, then create a join command.',
                          'Enter a node name and copy the join command.',
                          'Install myapp-ctl on your own host and run the join command.',
                          'Enter this node’s own DeepSeek / MiniMax / custom provider configuration.',
                          'Switch Agent routing to private in the app; only your nodes are used.',
                        ]).map((item) => (
                      <li key={item}>{item}</li>
                    ))}
                  </ol>
                </div>
                <div>
                  <h3>{zh ? '私有节点加入' : 'Private node join'}</h3>
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
                  {zh
                    ? '当前客户端调度只有 public 和 private 两种。public 使用公开节点池；private 只使用当前登录用户的私有节点，私有节点离线时不会自动回落公开节点。'
                    : 'Client routing currently has only public and private modes. public uses the platform pool; private uses only the signed-in user’s private nodes and does not automatically fall back to public when offline.'}
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
                    {zh
                      ? '官网是 website 目录下的 Vite 项目。发布到 Cloudflare Pages 时应构建 website/dist，不要和 Flutter Web 客户端的 build/web 混用。'
                      : 'The website is the Vite project under website. Deploy website/dist to Cloudflare Pages; do not confuse it with the Flutter Web client build/web output.'}
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
  const [lang, setLang] = useState<Lang>(() =>
    navigator.language.toLowerCase().startsWith('zh') ? 'zh' : 'en',
  );
  const [page, setPage] = useState<Page>(() => (window.location.pathname === '/docs' ? 'docs' : 'home'));
  const t = copy[lang];
  const activeLanguage = languageOptions.find((item) => item.key === lang) ?? languageOptions[1];
  const docsLabel = lang === 'zh' ? '文档' : 'Docs';
  const zh = lang === 'zh';
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
  const showcaseCards = zh
    ? [
        {
          title: '露营装备管家',
          prompt: '生成一个露营装备打包 App，支持清单、天气、共享备注',
          body: 'AI 生成清单、状态统计、团队备注和跨端运行界面。',
          tags: ['工具', '清单', '共享'],
        },
        {
          title: '星际跑酷小游戏',
          prompt: '横版星际跑酷：跳跃躲障碍，收集星星，分数和生命完整',
          body: 'JSON App 组合游戏 atoms、状态栏、暂停和重开流程。',
          tags: ['游戏', '状态', '动画'],
        },
        {
          title: '小型社区空间',
          prompt: '做一个小红书风格的内容社区，有首页、发布、收藏、个人页',
          body: '用预编译运行时渲染多 tab、内容流和个人资料体验。',
          tags: ['社区', '内容流', '个人页'],
        },
      ]
    : [
        {
          title: 'Camping kit planner',
          prompt: 'Build a camping packing app with checklist, weather and shared notes',
          body: 'AI creates checklist states, trip summary, team notes and a cross-client UI.',
          tags: ['Tool', 'Checklist', 'Shared'],
        },
        {
          title: 'Star runner mini-game',
          prompt: 'Create a side-scrolling space runner with jump, obstacles, stars and lives',
          body: 'JSON App composes game atoms, score/life HUD, pause and restart flows.',
          tags: ['Game', 'State', 'Motion'],
        },
        {
          title: 'Creator community',
          prompt: 'Make a lifestyle content app with feed, publish, favorites and profile',
          body: 'The precompiled runtime renders tabs, feeds and profile screens from JSON.',
          tags: ['Community', 'Feed', 'Profile'],
        },
      ];
  const downloadOptions = [
    {
      title: zh ? 'Web 立即体验' : 'Web app',
      body: zh ? '无需安装，直接打开线上 Web 客户端。' : 'No install required. Open the hosted Web client.',
      href: WEB_APP_URL,
      icon: Play,
      status: zh ? '可用' : 'Available',
      primary: true,
    },
    {
      title: 'iOS TestFlight',
      body: zh ? 'Public Group 1 已开放，适合真实手机体验。' : 'Public Group 1 is open for real-device testing.',
      href: TESTFLIGHT_URL,
      icon: Smartphone,
      status: zh ? '2500 人公开组' : 'Public group',
      primary: false,
    },
    {
      title: zh ? 'Android APK' : 'Android APK',
      body: zh ? '固定链接下载最新版 APK；Google Play 正在准备。' : 'Download the latest APK from a fixed link. Google Play is preparing.',
      href: APK_URL,
      icon: Download,
      status: zh ? '直接下载' : 'Direct download',
      primary: false,
    },
    {
      title: zh ? '自部署后端' : 'Self-host backend',
      body: zh ? '用自己的后端连接 Web、iOS 或 Android 客户端。' : 'Connect Web, iOS or Android clients to your backend.',
      href: '/docs',
      icon: Server,
      status: zh ? '文档' : 'Docs',
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

  function goHome(event: ReactMouseEvent<HTMLAnchorElement>, hash = '#top') {
    event.preventDefault();
    setPage('home');
    window.history.pushState(null, '', hash === '#top' ? '/' : `/${hash}`);
    requestAnimationFrame(() => document.querySelector(hash)?.scrollIntoView({ behavior: 'smooth' }));
  }

  function goDocs(event: ReactMouseEvent<HTMLAnchorElement>, hash = '#docs') {
    event.preventDefault();
    setPage('docs');
    window.history.pushState(null, '', hash === '#docs' ? '/docs' : `/docs${hash}`);
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
              <span className="navIconLink disabledLink" aria-label={zh ? 'GitHub 即将公开' : 'GitHub coming soon'}>
                <Github size={17} />
                <span>{zh ? 'GitHub 即将公开' : 'GitHub soon'}</span>
              </span>
            )}
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
            <div className="heroLinkRow" aria-label={zh ? '快速入口' : 'Quick links'}>
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
                  {zh ? 'GitHub 即将公开' : 'GitHub soon'}
                </span>
              )}
              <a href={REVIEW_BOUNDARY_URL} onClick={(event) => goDocs(event, '#runtime-boundary')}>
                <ShieldCheck size={15} />
                {zh ? '合规边界' : 'Review boundary'}
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
                <span>{zh ? '即开即用' : 'open now'}</span>
              </div>
              <div>
                <strong>iOS</strong>
                <span>TestFlight</span>
              </div>
              <div>
                <strong>APK</strong>
                <span>{zh ? '直接下载' : 'direct download'}</span>
              </div>
            </div>
          </div>
          <div className="heroAside">
            <PhonePreview />
            <p className="phoneCaption">{t.phoneCaption}</p>
          </div>
        </div>
        <div className="shell heroTrustGrid">
          <div className="trustPanel" aria-labelledby="trust-title">
            <p className="eyebrow">{zh ? '为什么可信' : 'Why it is credible'}</p>
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
            <p className="eyebrow">{zh ? '继续了解' : 'Keep exploring'}</p>
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

      <section className="videosSection" id="videos">
        <div className="shell">
          <div className="sectionHeader split">
            <div>
              <p className="eyebrow">{lang === 'zh' ? '生成案例' : 'Generated examples'}</p>
              <h2>{t.videosTitle}</h2>
              <p>{t.videosSubtitle}</p>
            </div>
            <a className="button secondary" href={WEB_APP_URL} target="_blank" rel="noreferrer">
              <Play size={17} />
              {zh ? '直接试用' : 'Try it live'}
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
              <p>{zh ? '用 myapp-ctl 部署后端，管理密钥、服务状态和组件发布。' : 'Use myapp-ctl to deploy the backend, manage secrets, inspect status and ship components.'}</p>
              <span className="deployMeta">{zh ? '后端优先' : 'Backend first'}</span>
            </article>
            <article className="deployCard">
              <div className="deployIcon"><Smartphone size={20} /></div>
              <h3>{t.clientBuildTitle}</h3>
              <p>{zh ? '可以直接用线上 Web，也可以自行构建 Flutter Web、iOS 或 Android 客户端。' : 'Use the hosted Web app directly, or build Flutter Web, iOS or Android yourself.'}</p>
              <span className="deployMeta">{zh ? '客户端可替换' : 'Replaceable clients'}</span>
            </article>
            <article className="deployCard">
              <div className="deployIcon"><Network size={20} /></div>
              <h3>{t.switchEnvTitle}</h3>
              <p>{t.switchEnvBody}</p>
              <span className="deployMeta">{zh ? '扫码或粘贴' : 'Scan or paste'}</span>
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
                    {zh ? '继续' : 'Continue'}
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
              <span>{zh ? 'GitHub 即将公开' : 'GitHub soon'}</span>
            )}
            <a href="mailto:2501808198@qq.com">fish</a>
          </div>
        </div>
      </footer>
    </main>
  );
}

export default App;
