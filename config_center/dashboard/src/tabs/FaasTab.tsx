import { Boxes, Play, CircleSlash, Layers } from 'lucide-react';
import { api } from '../api';
import { useApi } from '../useApi';
import { KPI, Badge, Loading, ErrorBanner, Empty, fmtTime } from '../ui';
import type { FaasService } from '../types';

function statusBadge(s: FaasService) {
  if (s.running) return <Badge tone="ok" dot>{s.status || 'running'}</Badge>;
  return <Badge tone="err" dot>{s.status || 'stopped'}</Badge>;
}

export default function FaasTab() {
  const { data, loading, error, reload } = useApi(() => api.faas(), []);
  if (loading) return <Loading />;
  if (error) return <ErrorBanner message={error} onRetry={reload} />;
  if (!data) return <Empty />;

  const { services, overview, deploy_mode } = data;

  return (
    <div>
      <div className="section-head">
        <h2>FaaS 服务</h2>
        <Badge tone="accent">部署模式: {deploy_mode}</Badge>
        <span className="spacer" />
        <button className="btn btn-sm" onClick={reload}>刷新</button>
      </div>

      <div className="kpis">
        <KPI label="服务总数" value={overview.total} tone="accent" icon={<Boxes />} />
        <KPI label="运行中" value={overview.running} tone="ok" icon={<Play />} />
        <KPI label="已停止" value={overview.stopped} tone={overview.stopped ? 'warn' : undefined} icon={<CircleSlash />} />
        <KPI label="实例总数" value={overview.total_instances} icon={<Layers />} />
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
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <p className="hint">
        {deploy_mode === 'openfaas'
          ? 'OpenFaaS 模式：实例数量/当前容量按服务运行状态展示，容量范围取配置 {min..max}；启动时间为最近一次部署时间。'
          : 'local-docker 单实例模式：实例数量/当前容量按服务状态推导（运行=1，停止=0），容量范围取配置 {min..max}；启动时间为最近一次部署时间。'}
      </p>
    </div>
  );
}
