import { useCallback, useState } from 'react';
import ConfigTab from './tabs/ConfigTab';
import UsersTab from './tabs/UsersTab';
import FaasTab from './tabs/FaasTab';
import AgentsTab from './tabs/AgentsTab';

type TabKey = 'config' | 'users' | 'faas' | 'agents';

const TABS: { key: TabKey; label: string }[] = [
  { key: 'config', label: '配置下发' },
  { key: 'users', label: '用户管理' },
  { key: 'faas', label: 'FaaS 服务' },
  { key: 'agents', label: 'Agent 节点' },
];

export default function App() {
  const [tab, setTab] = useState<TabKey>('config');
  const [toast, setToast] = useState<{ msg: string; ok: boolean } | null>(null);

  const showToast = useCallback((msg: string, ok = true) => {
    setToast({ msg, ok });
    window.setTimeout(() => setToast(null), 2600);
  }, []);

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">MyApp 管理后台<small>统一控制台</small></div>
        <span className="spacer" />
        <a className="btn btn-sm" href="/logout" onClick={(e) => {
          e.preventDefault();
          fetch('/logout', { method: 'POST', credentials: 'same-origin' }).finally(() => { window.location.href = '/login'; });
        }}>退出登录</a>
      </header>

      <nav className="tabs" role="tablist">
        {TABS.map((t) => (
          <button
            key={t.key}
            role="tab"
            aria-selected={tab === t.key}
            className={`tab ${tab === t.key ? 'active' : ''}`}
            onClick={() => setTab(t.key)}
          >
            {t.label}
          </button>
        ))}
      </nav>

      <main className="content">
        {tab === 'config' && <ConfigTab toast={showToast} />}
        {tab === 'users' && <UsersTab toast={showToast} />}
        {tab === 'faas' && <FaasTab />}
        {tab === 'agents' && <AgentsTab />}
      </main>

      {toast && <div className={`toast ${toast.ok ? 'ok' : 'err'}`}>{toast.msg}</div>}
    </div>
  );
}
