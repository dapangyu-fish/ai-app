import { useState } from 'react';
import { Boxes, Play, CircleSlash, Layers } from 'lucide-react';
import { api } from '../api';
import { useApi } from '../useApi';
import { KPI, Badge, Loading, ErrorBanner, Empty, fmtTime } from '../ui';
import type { FaasService } from '../types';

function statusBadge(s: FaasService) {
  if (s.status === 'disabled') return <Badge tone="err" dot>已停用</Badge>;
  if ((s.instances ?? 0) > 0) return <Badge tone="ok" dot>{s.status || 'running'} · {s.instances}</Badge>;
  // ready but no live container: scaled to zero, cold-wakes on next invoke
  return <Badge tone="warn" dot>{s.status || 'ready'} · 0(休眠)</Badge>;
}

export default function FaasTab() {
  const { data, loading, error, reload } = useApi(() => api.faas(), []);
  const [busy, setBusy] = useState<string>('');
  const [actionErr, setActionErr] = useState<string>('');

  if (loading) return <Loading />;
  if (error) return <ErrorBanner message={error} onRetry={reload} />;
  if (!data) return <Empty />;

  const { services, overview, deploy_mode } = data;

  async function run(id: string, label: string, fn: () => Promise<unknown>) {
    setActionErr('');
    setBusy(id + label);
    try {
      await fn();
      await reload();
    } catch (e) {
      setActionErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy('');
    }
  }

  function onDisable(s: FaasService) {
    if (!window.confirm(`停用服务「${s.name}」？\n会停掉所有容器并置为已停用，记录与代码保留，可重新部署恢复。`)) return;
    run(s.service_id, 'disable', () => api.faasDisable(s.service_id));
  }

  function onDelete(s: FaasService) {
    if (!window.confirm(`彻底删除服务「${s.name}」？\n会删除容器、数据库记录和代码，不可恢复（已停用的服务也用它清理）。`)) return;
    run(s.service_id, 'delete', () => api.faasDelete(s.service_id));
  }

  return (
    <div>
      <div className="section-head">
        <h2>FaaS 服务</h2>
        <Badge tone="accent">部署模式: {deploy_mode}</Badge>
        <span className="spacer" />
        <button className="btn btn-sm" onClick={reload}>刷新</button>
      </div>

      {actionErr && <ErrorBanner message={actionErr} />}

      <div className="kpis">
        <KPI label="服务总数" value={overview.total} tone="accent" icon={<Boxes />} />
        <KPI label="启用中" value={overview.running} tone="ok" icon={<Play />} />
        <KPI label="已停用" value={overview.stopped} tone={overview.stopped ? 'warn' : undefined} icon={<CircleSlash />} />
        <KPI label="运行实例总数" value={overview.total_instances} icon={<Layers />} />
      </div>

      {services.length === 0 ? (
        <Empty label="还没有生成的 FaaS 服务" />
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th>服务</th>
                <th>负责人</th>
                <th>状态</th>
                <th className="num">实例数量</th>
                <th className="num">当前容量</th>
                <th>容量范围</th>
                <th>启动时间</th>
                <th>创建时间</th>
                <th className="num">路由</th>
                <th>访问地址</th>
                <th>操作</th>
              </tr>
            </thead>
            <tbody>
              {services.map((s) => (
                <tr key={s.service_id}>
                  <td>
                    <div>{s.name}</div>
                    <div className="mono">{s.function_name}</div>
                  </td>
                  <td className="mono">{(s.owner_user_id || '—').slice(0, 8)}</td>
                  <td>{statusBadge(s)}</td>
                  <td className="num">{s.instances}</td>
                  <td className="num">{s.current_capacity}</td>
                  <td className="mono">{s.capacity_min} – {s.capacity_max}</td>
                  <td>{fmtTime(s.deployed_at)}</td>
                  <td>{fmtTime(s.created_at)}</td>
                  <td className="num">{s.routes_count}</td>
                  <td>
                    {s.public_base_url ? (
                      <a className="link" href={s.public_base_url} target="_blank" rel="noreferrer">
                        {s.public_base_url.replace(/^https?:\/\//, '')}
                      </a>
                    ) : '—'}
                  </td>
                  <td>
                    <div className="row-actions">
                      {s.status !== 'disabled' && (
                        <button
                          className="btn btn-sm"
                          disabled={!!busy}
                          onClick={() => onDisable(s)}
                        >
                          {busy === s.service_id + 'disable' ? '停用中…' : '停用'}
                        </button>
                      )}
                      <button
                        className="btn btn-sm btn-danger"
                        disabled={!!busy}
                        onClick={() => onDelete(s)}
                      >
                        {busy === s.service_id + 'delete' ? '删除中…' : '删除'}
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="hint">
        实例数量/当前容量为真实运行容器数（与 <span className="mono">myapp-ctl faas ls</span> 同源）：
        <b>0(休眠)</b> 表示已缩容到零，下次调用会自动冷唤醒；<b>停用</b> 会停掉容器并保留记录，
        <b>删除</b> 会连记录和代码一起清除（已停用的服务也用删除来彻底清理）。容量范围取配置 {'{min..max}'}。
      </p>
    </div>
  );
}
