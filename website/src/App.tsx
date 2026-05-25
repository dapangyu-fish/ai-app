import {
  Bot,
  Boxes,
  ChevronRight,
  Cloud,
  Code2,
  Download,
  Globe2,
  MessageCircle,
  Play,
  Server,
  Smartphone,
  Sparkles,
  Terminal,
} from 'lucide-react';
import { useMemo, useState } from 'react';

type Lang = 'zh' | 'en';
type ThemeKey = 'orbit' | 'matrix' | 'prism' | 'slate';

const WEB_APP_URL = 'https://myapp-web.dapangyu.work/';

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
    navTry: '体验',
    navFeatures: '能力',
    navDownload: '下载',
    badge: 'AI 造 App · 服务端驱动 · Web / iOS / Android',
    titleA: '对 AI 说一句话',
    titleB: '拿到一个能用的 App',
    subtitle:
      '描述你想要的应用，AI 生成 JSON App，立刻在 Web 预览和移动端运行。不用重新编译，不用等商店审核。',
    primaryCta: '打开在线 Demo',
    secondaryCta: '查看部署命令',
    phoneCaption: '线上 Web 客户端，嵌在手机外框里做快速演示。',
    playgroundTitle: '选择官网科技风格',
    playgroundSubtitle: '同一套内容，切换不同视觉方向，后续可以按你选中的风格继续打磨。',
    tryTitle: '先在浏览器里试一下',
    tryBody:
      '右侧就是线上 Web 客户端。它和移动端共用同一套 JSON App 运行时，适合快速演示、体验应用市场和验证 AI 生成出来的应用。',
    deployTitle: '自部署入口',
    deployHint: 'bootstrap 会输出二维码和整段 JSON，客户端可扫码或粘贴后切换环境。',
    howTitle: '从想法到应用',
    howSubtitle: '官网第一屏直接给出路径，避免变成空泛营销页。',
    steps: [
      ['描述需求', '像聊天一样告诉 AI 你要什么应用。'],
      ['生成 JSON App', 'AI 输出可执行配置，调用框架里的组件、数据和网络能力。'],
      ['即时运行', 'Web / iOS / Android 使用同一套应用描述。'],
    ],
    featuresTitle: '平台能力',
    featuresSubtitle: '围绕 AI 生成、运行时渲染、应用市场和自部署构建。',
    features: [
      ['AI 原生 DSL', '结构适合大模型生成，不是只给人手写的配置格式。'],
      ['Web 兼容', '同一套 JSON App 能在 Web 版快速验证和展示。'],
      ['内置 IM', '好友、群聊、消息同步和 Web OpenIM 兼容层。'],
      ['应用市场', '包索引、版本、搜索、分页和组件复用。'],
      ['服务端驱动', 'UI 和业务配置可下发，不依赖商店审核周期。'],
      ['可自部署', '测试环境 bootstrap 一条链路拉起核心服务。'],
    ],
    downloadTitle: '移动端下载准备中',
    downloadBody: '现在先用 Web 版体验完整流程，移动端上架后可以沿用同一套应用生态。',
    openWeb: '打开 Web 版',
    appStore: 'App Store',
    googlePlay: 'Google Play',
    soon: '即将上线',
  },
  en: {
    navHow: 'Deploy',
    navTry: 'Try',
    navFeatures: 'Capabilities',
    navDownload: 'Download',
    badge: 'AI-built apps · Server-driven · Web / iOS / Android',
    titleA: 'Tell AI what you want',
    titleB: 'get a working app',
    subtitle:
      'Describe the app you want. AI generates a JSON App that runs immediately on the Web preview and mobile clients. No recompile, no store review.',
    primaryCta: 'Open live demo',
    secondaryCta: 'View deploy command',
    phoneCaption: 'Live Web client embedded in a phone frame for quick demos.',
    playgroundTitle: 'Choose a tech visual direction',
    playgroundSubtitle: 'Same product content, multiple visual directions. Pick one and we can refine from there.',
    tryTitle: 'Try it in the browser first',
    tryBody:
      'The live Web client is embedded on the right. It shares the same JSON App runtime as mobile, so it works for demos, marketplace browsing and checking AI-generated apps.',
    deployTitle: 'Self-host entry',
    deployHint: 'bootstrap outputs a QR code and full JSON. The client can scan or paste it to switch environments.',
    howTitle: 'Idea to app',
    howSubtitle: 'The homepage starts from the actual path instead of generic marketing copy.',
    steps: [
      ['Describe it', 'Tell AI what app you want in natural language.'],
      ['Generate JSON App', 'AI outputs executable config using framework components, data and network capabilities.'],
      ['Run instantly', 'Web / iOS / Android share the same app description.'],
    ],
    featuresTitle: 'Platform capabilities',
    featuresSubtitle: 'Built around AI generation, runtime rendering, marketplace distribution and self-hosting.',
    features: [
      ['AI-native DSL', 'Structured for LLM generation, not only hand-written config.'],
      ['Web compatible', 'Validate and demo the same JSON App on the Web client.'],
      ['Built-in IM', 'Friends, groups, sync and the OpenIM compatibility layer for Web.'],
      ['Marketplace', 'Package index, versions, search, pagination and component reuse.'],
      ['Server-driven', 'Ship UI and behavior config without store review cycles.'],
      ['Self-hostable', 'The test-env bootstrap brings up the core services end to end.'],
    ],
    downloadTitle: 'Mobile downloads coming soon',
    downloadBody: 'Use the Web version now. Mobile clients will share the same app ecosystem.',
    openWeb: 'Open Web app',
    appStore: 'App Store',
    googlePlay: 'Google Play',
    soon: 'Coming soon',
  },
};

function PhonePreview({ compact = false }: { compact?: boolean }) {
  return (
    <div className={`phoneStage ${compact ? 'compact' : ''}`} aria-label="MyApp Web live preview">
      <div className="phoneGlow" />
      <div className="phoneShell">
        <div className="phoneSpeaker" />
        <div className="phoneScreen">
          <iframe
            src={WEB_APP_URL}
            title="MyApp Web demo"
            loading={compact ? 'lazy' : 'eager'}
            allow="clipboard-read; clipboard-write; microphone; camera"
          />
        </div>
      </div>
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

  return (
    <main className={`site theme-${theme}`}>
      <nav className="nav">
        <div className="shell navInner">
          <a className="brand" href="#top" aria-label="MyApp">
            My<span>App</span>
          </a>
          <div className="navLinks">
            <a href="#deploy">{t.navHow}</a>
            <a href="#try">{t.navTry}</a>
            <a href="#features">{t.navFeatures}</a>
            <a href="#download">{t.navDownload}</a>
          </div>
          <button className="iconButton" type="button" onClick={() => setLang(lang === 'zh' ? 'en' : 'zh')}>
            <Globe2 size={16} />
            <span>{lang === 'zh' ? 'EN' : '中文'}</span>
          </button>
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
              <a className="button secondary" href="#deploy">
                <Terminal size={17} />
                {t.secondaryCta}
              </a>
            </div>
            <div className="metricRow">
              <div>
                <strong>Web</strong>
                <span>Cloudflare Pages</span>
              </div>
              <div>
                <strong>JSON</strong>
                <span>Runtime apps</span>
              </div>
              <div>
                <strong>OpenIM</strong>
                <span>Chat compatible</span>
              </div>
            </div>
          </div>
          <div>
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

      <section className="trySection" id="try">
        <div className="shell tryGrid">
          <div className="panel copyPanel">
            <p className="eyebrow">Live preview</p>
            <h2>{t.tryTitle}</h2>
            <p>{t.tryBody}</p>
            <a className="inlineLink" href={WEB_APP_URL} target="_blank" rel="noreferrer">
              {t.openWeb}
              <ChevronRight size={16} />
            </a>
          </div>
          <PhonePreview compact />
        </div>
      </section>

      <section className="deploySection" id="deploy">
        <div className="shell deployGrid">
          <div>
            <p className="eyebrow">Deploy first</p>
            <h2>{t.deployTitle}</h2>
            <p>{t.deployHint}</p>
          </div>
          <div className="terminalBox">
            <div className="terminalTop">
              <span />
              <span />
              <span />
            </div>
            <pre>{`$ ./deploy/test-env/bootstrap.sh
# scan QR or paste generated JSON
$ open ${WEB_APP_URL}`}</pre>
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
          <div className="featureGrid">
            {t.features.map(([title, body], index) => {
              const icons = [Bot, Smartphone, MessageCircle, Boxes, Cloud, Server];
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
            <a className="button secondary" href="#download">
              <Download size={17} />
              {t.appStore}
              <small>{t.soon}</small>
            </a>
            <a className="button secondary" href="#download">
              <Download size={17} />
              {t.googlePlay}
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
