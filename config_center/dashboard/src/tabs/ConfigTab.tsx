import { useState } from 'react';
import { SlidersHorizontal, PackageCheck, History } from 'lucide-react';
import { api } from '../api';
import { useApi } from '../useApi';
import { KPI, Badge, Loading, ErrorBanner, Empty, fmtTime } from '../ui';
import type { ConfigRow } from '../types';

const TYPES = ['string', 'bool', 'number', 'json'];

export default function ConfigTab({ toast }: { toast: (m: string, ok?: boolean) => void }) {
  const { data, loading, error, reload } = useApi(() => api.configs(), []);
  const [edit, setEdit] = useState<ConfigRow | null>(null);
  const [draft, setDraft] = useState({ key: '', value_type: 'string', value: '', comment: '' });
  const [busy, setBusy] = useState(false);

  function startNew() {
    setDraft({ key: '', value_type: 'string', value: '', comment: '' });
    setEdit({ key: '', value: '', value_type: 'string', comment: '', updated_at: 0, updated_by: '' });
  }
  function startEdit(c: ConfigRow) {
    setDraft({ key: c.key, value_type: c.value_type, value: c.value, comment: c.comment || '' });
    setEdit(c);
  }

  async function save(isNew: boolean) {
    setBusy(true);
    try {
      await api.upsertConfig(draft.key, draft.value_type, draft.value, draft.comment, isNew);
      toast('已保存', true);
      setEdit(null);
      reload();
    } catch (e) {
      toast(e instanceof Error ? e.message : String(e), false);
    } finally {
      setBusy(false);
    }
  }
  async function del(key: string) {
    if (!window.confirm(`删除配置项 "${key}"？`)) return;
    try {
      await api.deleteConfig(key);
      toast('已删除', true);
      reload();
    } catch (e) {
      toast(e instanceof Error ? e.message : String(e), false);
    }
  }

  if (loading) return <Loading />;
  if (error) return <ErrorBanner message={error} onRetry={reload} />;
  if (!data) return <Empty />;

  const isNew = edit !== null && !data.configs.some((c) => c.key === edit.key);

  return (
    <div>
      <div className="section-head">
        <h2>配置下发</h2>
        <span className="spacer" />
        <button className="btn btn-primary btn-sm" onClick={startNew}>+ 新建配置</button>
        <button className="btn btn-sm" onClick={reload}>刷新</button>
      </div>

      <div className="kpis">
        <KPI label="配置项" value={data.configs.length} tone="accent" icon={<SlidersHorizontal />} />
        <KPI label="APK 发布" value={data.apk?.exists ? '已发布' : '未发布'} tone={data.apk?.exists ? 'ok' : 'warn'} icon={<PackageCheck />} />
        <KPI label="审计记录" value={data.audit.length} icon={<History />} />
      </div>

      {edit && (
        <div className="card">
          <h3>{isNew ? '新建配置项' : `编辑：${edit.key}`}</h3>
          <div className="form-grid">
            <div className="field"><label>Key</label>
              <input value={draft.key} disabled={!isNew} onChange={(e) => setDraft({ ...draft, key: e.target.value })} /></div>
            <div className="field"><label>类型</label>
              <select value={draft.value_type} onChange={(e) => setDraft({ ...draft, value_type: e.target.value })}>
                {TYPES.map((t) => <option key={t}>{t}</option>)}
              </select></div>
            <div className="field"><label>值</label>
              <input value={draft.value} onChange={(e) => setDraft({ ...draft, value: e.target.value })} /></div>
            <div className="field"><label>备注</label>
              <input value={draft.comment} onChange={(e) => setDraft({ ...draft, comment: e.target.value })} /></div>
            <div className="row-actions">
              <button className="btn btn-primary" disabled={busy || !draft.key} onClick={() => save(isNew)}>保存</button>
              <button className="btn" onClick={() => setEdit(null)}>取消</button>
            </div>
          </div>
        </div>
      )}

      <div className="table-wrap">
        <table>
          <thead><tr><th>Key</th><th>类型</th><th>值</th><th>备注</th><th>更新</th><th>操作</th></tr></thead>
          <tbody>
            {data.configs.map((c) => (
              <tr key={c.key}>
                <td className="mono">{c.key}</td>
                <td><Badge tone="neutral">{c.value_type}</Badge></td>
                <td className="mono">{(c.display ?? c.value)?.toString().slice(0, 80)}</td>
                <td>{c.comment || '—'}</td>
                <td>{c.updated_at ? fmtTime(c.updated_at) : '—'}</td>
                <td>
                  <div className="row-actions">
                    <button className="btn btn-sm" onClick={() => startEdit(c)}>编辑</button>
                    <button className="btn btn-sm btn-danger" onClick={() => del(c.key)}>删除</button>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ marginTop: 16 }}>
        <h3>审计日志（最近 {data.audit.length}）</h3>
        <div className="table-wrap">
          <table>
            <thead><tr><th>时间</th><th>Key</th><th>动作</th><th>操作者</th></tr></thead>
            <tbody>
              {data.audit.map((a) => (
                <tr key={a.id}>
                  <td>{fmtTime(a.ts)}</td>
                  <td className="mono">{a.key}</td>
                  <td><Badge tone={a.action === 'delete' ? 'err' : a.action === 'create' ? 'ok' : 'neutral'}>{a.action}</Badge></td>
                  <td>{a.actor}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
