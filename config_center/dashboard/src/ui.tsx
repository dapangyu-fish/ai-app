import type { ReactNode } from 'react';

export function fmtTime(v: number | string | null | undefined): string {
  if (v === null || v === undefined || v === '') return '—';
  let d: Date;
  if (typeof v === 'number') {
    d = new Date(v < 1e12 ? v * 1000 : v); // unix seconds vs ms
  } else {
    const n = Number(v);
    d = Number.isFinite(n) && /^\d+$/.test(v) ? new Date(n < 1e12 ? n * 1000 : n) : new Date(v);
  }
  if (isNaN(d.getTime())) return String(v);
  const p = (x: number) => String(x).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

export function ago(v: number | string | null | undefined): string {
  if (v === null || v === undefined || v === '') return '—';
  const d = typeof v === 'number' ? new Date(v < 1e12 ? v * 1000 : v) : new Date(v);
  if (isNaN(d.getTime())) return String(v);
  const s = Math.max(0, Math.floor((Date.now() - d.getTime()) / 1000));
  if (s < 60) return `${s}秒前`;
  if (s < 3600) return `${Math.floor(s / 60)}分钟前`;
  if (s < 86400) return `${Math.floor(s / 3600)}小时前`;
  return `${Math.floor(s / 86400)}天前`;
}

export function KPI({ label, value, tone }: { label: string; value: ReactNode; tone?: string }) {
  return (
    <div className={`kpi ${tone ? `kpi-${tone}` : ''}`}>
      <div className="kpi-value">{value}</div>
      <div className="kpi-label">{label}</div>
    </div>
  );
}

export function Badge({ children, tone = 'neutral' }: { children: ReactNode; tone?: string }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

export function Loading({ label = '加载中…' }: { label?: string }) {
  return <div className="state" role="status">{label}</div>;
}

export function ErrorBanner({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div className="state state-error" role="alert">
      <span>⚠ {message}</span>
      {onRetry && <button className="btn btn-sm" onClick={onRetry}>重试</button>}
    </div>
  );
}

export function Empty({ label = '暂无数据' }: { label?: string }) {
  return <div className="state">{label}</div>;
}
