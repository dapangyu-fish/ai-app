import { useMemo, useState } from 'react';
import { Users, ShieldCheck, Ban, MailWarning } from 'lucide-react';
import { api } from '../api';
import { useApi } from '../useApi';
import { KPI, Badge, Loading, ErrorBanner, Empty, fmtTime } from '../ui';
import type { UserRow } from '../types';

const ROLES = ['user', 'pro', 'admin'];

function roleTone(r: string) {
  return r === 'admin' ? 'err' : r === 'pro' ? 'pro' : 'neutral';
}

export default function UsersTab({ toast }: { toast: (m: string, ok?: boolean) => void }) {
  const { data, loading, error, reload } = useApi(() => api.users(1, 100), []);
  const [q, setQ] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);
  const [nu, setNu] = useState({ email: '', password: '', role: 'user', username: '' });

  const filtered = useMemo(() => {
    const rows = data?.users ?? [];
    const t = q.trim().toLowerCase();
    if (!t) return rows;
    return rows.filter(
      (u) =>
        (u.email || '').toLowerCase().includes(t) ||
        (u.username || '').toLowerCase().includes(t) ||
        u.id.toLowerCase().includes(t),
    );
  }, [data, q]);

  async function act(id: string, label: string, fn: () => Promise<unknown>) {
    setBusy(id + label);
    try {
      await fn();
      toast(`${label} 成功`, true);
      reload();
    } catch (e) {
      toast(e instanceof Error ? e.message : String(e), false);
    } finally {
      setBusy(null);
    }
  }

  if (loading) return <Loading />;
  if (error) return <ErrorBanner message={error} onRetry={reload} />;

  const rows = data?.users ?? [];
  const counts = {
    total: rows.length,
    admin: rows.filter((u) => u.role === 'admin').length,
    banned: rows.filter((u) => u.banned).length,
    unconfirmed: rows.filter((u) => !u.email_confirmed).length,
  };

  return (
    <div>
      <div className="section-head">
        <h2>用户管理</h2>
        <span className="spacer" />
        <input className="search" placeholder="搜索 邮箱 / 用户名 / ID" value={q} onChange={(e) => setQ(e.target.value)} />
        <button className="btn btn-primary btn-sm" onClick={() => setShowCreate((v) => !v)}>+ 新建用户</button>
        <button className="btn btn-sm" onClick={reload}>刷新</button>
      </div>

      <div className="kpis">
        <KPI label="本页用户" value={counts.total} tone="accent" icon={<Users />} />
        <KPI label="管理员" value={counts.admin} icon={<ShieldCheck />} />
        <KPI label="已封禁" value={counts.banned} tone={counts.banned ? 'err' : undefined} icon={<Ban />} />
        <KPI label="未验证邮箱" value={counts.unconfirmed} tone={counts.unconfirmed ? 'warn' : undefined} icon={<MailWarning />} />
      </div>

      {showCreate && (
        <div className="card">
          <h3>新建用户</h3>
          <div className="form-grid">
            <div className="field"><label>邮箱</label><input value={nu.email} onChange={(e) => setNu({ ...nu, email: e.target.value })} /></div>
            <div className="field"><label>密码 (≥6)</label><input type="password" value={nu.password} onChange={(e) => setNu({ ...nu, password: e.target.value })} /></div>
            <div className="field"><label>用户名</label><input value={nu.username} onChange={(e) => setNu({ ...nu, username: e.target.value })} /></div>
            <div className="field"><label>角色</label>
              <select value={nu.role} onChange={(e) => setNu({ ...nu, role: e.target.value })}>
                {ROLES.map((r) => <option key={r}>{r}</option>)}
              </select>
            </div>
            <button className="btn btn-primary" disabled={busy === 'create'} onClick={() => act('create', '创建用户', async () => {
              await api.createUser({ email: nu.email, password: nu.password, role: nu.role, username: nu.username || undefined });
              setShowCreate(false); setNu({ email: '', password: '', role: 'user', username: '' });
            })}>创建</button>
          </div>
        </div>
      )}

      {filtered.length === 0 ? (
        <Empty label={q ? '没有匹配的用户' : '暂无用户'} />
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>邮箱 / 用户名</th><th>角色</th><th>状态</th><th>配额</th><th>注册时间</th><th>操作</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((u: UserRow) => (
                <tr key={u.id}>
                  <td>
                    <div>{u.email || '—'}</div>
                    <div className="mono">{u.username || u.id.slice(0, 8)}</div>
                  </td>
                  <td>
                    <select value={u.role} disabled={busy === u.id + '角色'}
                      onChange={(e) => act(u.id, '角色', () => api.setRole(u.id, e.target.value))}>
                      {ROLES.map((r) => <option key={r}>{r}</option>)}
                    </select>
                    {' '}<Badge tone={roleTone(u.role)}>{u.role}</Badge>
                  </td>
                  <td>
                    {u.banned ? <Badge tone="err" dot>已封禁</Badge> : <Badge tone="ok" dot>正常</Badge>}{' '}
                    {u.email_confirmed ? <Badge tone="neutral">已验证</Badge> : <Badge tone="warn">未验证</Badge>}
                  </td>
                  <td className="mono">{u.quota_override ?? '默认'}</td>
                  <td>{fmtTime(u.created_at)}</td>
                  <td>
                    <div className="row-actions">
                      <button className="btn btn-sm" onClick={() => act(u.id, u.banned ? '解封' : '封禁', () => api.setBan(u.id, !u.banned))}>
                        {u.banned ? '解封' : '封禁'}
                      </button>
                      {!u.email_confirmed && <button className="btn btn-sm" onClick={() => act(u.id, '确认邮箱', () => api.confirmEmail(u.id))}>确认邮箱</button>}
                      <button className="btn btn-sm" onClick={() => act(u.id, '发送重置', () => api.sendRecovery(u.id))}>重置密码</button>
                      <button className="btn btn-sm" onClick={() => {
                        const v = window.prompt('每日配额覆盖（留空=清除/默认）', String(u.quota_override ?? ''));
                        if (v === null) return;
                        act(u.id, '配额', () => api.setQuota(u.id, v.trim() === '' ? null : v.trim()));
                      }}>配额</button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="hint">用户数据来自 Supabase（每页最多 100）。搜索为本页过滤。</p>
    </div>
  );
}
