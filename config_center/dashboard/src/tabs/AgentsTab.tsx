import { useState } from 'react';
import { api } from '../api';
import { useApi } from '../useApi';
import { KPI, Badge, Loading, ErrorBanner, Empty, ago } from '../ui';
import type { AgentNode } from '../types';

function statusTone(s?: string): string {
  const v = (s || '').toLowerCase();
  if (v === 'online') return 'ok';
  if (v === 'paused') return 'warn';
  if (v === 'stale') return 'warn';
  return 'err';
}

const SUMMARY_CARDS: { key: string; label: string; tone?: string }[] = [
  { key: 'total', label: '节点总数', tone: 'accent' },
  { key: 'online', label: '在线', tone: 'ok' },
  { key: 'paused', label: '暂停', tone: 'warn' },
  { key: 'down', label: '离线', tone: 'err' },
  { key: 'active_runs', label: '运行任务' },
  { key: 'queued', label: '排队任务' },
];

export default function AgentsTab() {
  const [probe, setProbe] = useState(false);
  const { data, loading, error, reload } = useApi(() => api.agents(probe), [probe]);
  if (loading) return <Loading />;
  if (error) return <ErrorBanner message={error} onRetry={reload} />;
  if (!data) return <Empty />;

  const { summary, nodes } = data;
  const name = (n: AgentNode) => n.display_name || n.name || n.node_id;

  return (
    <div>
      <div className="section-head">
        <h2>Agent 节点</h2>
        <span className="spacer" />
        <label className="hint" style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
          <input type="checkbox" checked={probe} onChange={(e) => setProbe(e.target.checked)} />
          实时探活 (慢)
        </label>
        <button className="btn btn-sm" onClick={reload}>刷新</button>
      </div>

      <div className="kpis">
        {SUMMARY_CARDS.filter((c) => summary[c.key] !== undefined).map((c) => (
          <KPI key={c.key} label={c.label} value={summary[c.key] ?? 0} tone={c.tone} />
        ))}
      </div>

      {nodes.length === 0 ? (
        <Empty label="还没有注册的 agent 节点" />
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>节点</th>
                <th>主机</th>
                <th>可见性</th>
                <th>状态</th>
                <th>健康</th>
                <th className="num">容量</th>
                <th className="num">队列上限</th>
                <th className="num">运行中</th>
                <th>最近心跳</th>
                <th>版本</th>
              </tr>
            </thead>
            <tbody>
              {nodes.map((n) => (
                <tr key={n.node_id}>
                  <td>
                    <div>{name(n)}</div>
                    <div className="mono">{n.node_id}</div>
                  </td>
                  <td className="mono">{n.host || n.url || '—'}</td>
                  <td>{n.visibility ? <Badge tone={n.visibility === 'public' ? 'accent' : 'neutral'}>{n.visibility}</Badge> : '—'}</td>
                  <td><Badge tone={statusTone(n.status)}>{n.status || 'unknown'}</Badge></td>
                  <td>{n.health || '—'}</td>
                  <td className="num">{n.capacity ?? '—'}</td>
                  <td className="num">{n.queue_max ?? '—'}</td>
                  <td className="num">{n.active_runs ?? 0}</td>
                  <td>{ago(n.last_seen)}</td>
                  <td className="mono">{n.build_version || n.version || '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
