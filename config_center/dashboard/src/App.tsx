import { useCallback, useState, type MouseEvent } from 'react';
import { SlidersHorizontal, Users, Boxes, Cpu, LogOut } from 'lucide-react';
import ConfigTab from './tabs/ConfigTab';
import UsersTab from './tabs/UsersTab';
import FaasTab from './tabs/FaasTab';
import AgentsTab from './tabs/AgentsTab';

type TabKey = 'config' | 'users' | 'faas' | 'agents';

const TABS: { key: TabKey; label: string; icon: typeof Users }[] = [
  { key: 'config', label: '配置下发', icon: SlidersHorizontal },
  { key: 'users', label: '用户管理', icon: Users },
  { key: 'faas', label: 'FaaS 服务', icon: Boxes },
  { key: 'agents', label: 'Agent 节点', icon: Cpu },
];

export default function App() {
  const [tab, setTab] = useState<TabKey>('config');
  const [toast, setToast] = useState<{ msg: string; ok: boolean } | null>(null);

  const showToast = useCallback((msg: string, ok = true) => {
    setToast({ msg, ok });
    window.setTimeout(() => setToast(null), 2600);
  }, []);

  function logout(e: MouseEvent) {
    e.preventDefault();
    fetch('/logout', { method: 'POST', credentials: 'same-origin' }).finally(() => {
      window.location.href = '/login';
    });
  }

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="logo">
          <div className="logo-mark">M</div>
          <div className="logo-text"><b>MyApp</b><span>统一控制台</span></div>
        </div>
        <nav className="nav" role="tablist">
          {TABS.map((t) => {
            const Icon = t.icon;
            return (
              <button
                key={t.key}
                role="tab"
                aria-selected={tab === t.key}
                className={`nav-item ${tab === t.key ? 'active' : ''}`}
                onClick={() => setTab(t.key)}
              >
                <Icon /> {t.label}
              </button>
            );
          })}
        </nav>
        <div className="sidebar-foot">
          <a href="/logout" onClick={logout}><LogOut size={16} /> 退出登录</a>
        </div>
      </aside>

      <div className="main">
        <main className="content">
          {tab === 'config' && <ConfigTab toast={showToast} />}
          {tab === 'users' && <UsersTab toast={showToast} />}
          {tab === 'faas' && <FaasTab />}
          {tab === 'agents' && <AgentsTab />}
        </main>
      </div>

      {toast && <div className={`toast ${toast.ok ? 'ok' : 'err'}`}>{toast.msg}</div>}
    </div>
  );
}
