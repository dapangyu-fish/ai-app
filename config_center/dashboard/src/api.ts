// All requests are same-origin under config-center, so the cc_session cookie rides along.
const DASH = '/api/admin/dashboard';

async function getJSON<T>(path: string): Promise<T> {
  const r = await fetch(path, { credentials: 'same-origin', headers: { Accept: 'application/json' } });
  if (r.status === 401) {
    window.location.href = '/login';
    throw new Error('未登录');
  }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error((data as { error?: string })?.error || `请求失败 (${r.status})`);
  return data as T;
}

async function postJSON<T>(path: string, body: unknown): Promise<T> {
  const r = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify(body ?? {}),
  });
  if (r.status === 401) {
    window.location.href = '/login';
    throw new Error('未登录');
  }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error((data as { error?: string })?.error || `操作失败 (${r.status})`);
  return data as T;
}

// Config mutations reuse config-center's existing form endpoints (cc_session-gated, 302).
async function postForm(path: string, fields: Record<string, string>): Promise<void> {
  const body = new URLSearchParams(fields).toString();
  const r = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body,
    redirect: 'manual',
  });
  // existing endpoints answer 302 (redirect:'manual' → opaqueredirect/0) on success
  if (!(r.ok || r.status === 0 || (r.status >= 300 && r.status < 400))) {
    throw new Error(`操作失败 (${r.status})`);
  }
}

import type {
  ConfigsResponse, UsersResponse, FaasResponse, AgentsResponse, AgentNode,
} from './types';

export const api = {
  configs: () => getJSON<ConfigsResponse>(`${DASH}/configs`),
  upsertConfig: (key: string, value_type: string, value: string, comment: string, isNew: boolean) =>
    postForm(isNew ? '/admin/configs/new' : `/admin/configs/${encodeURIComponent(key)}`,
      { key, value_type, value, comment }),
  deleteConfig: (key: string) => postForm(`/admin/configs/${encodeURIComponent(key)}/delete`, {}),

  users: (page = 1, perPage = 100) => getJSON<UsersResponse>(`${DASH}/users?page=${page}&per_page=${perPage}`),
  createUser: (b: { email: string; password: string; role: string; username?: string }) =>
    postJSON<{ ok: boolean }>(`${DASH}/users/create`, b),
  setRole: (id: string, role: string) => postJSON(`${DASH}/users/${id}/role`, { role }),
  setBan: (id: string, ban: boolean) => postJSON(`${DASH}/users/${id}/ban`, { ban }),
  confirmEmail: (id: string) => postJSON(`${DASH}/users/${id}/confirm_email`, {}),
  sendRecovery: (id: string) => postJSON(`${DASH}/users/${id}/recovery`, {}),
  setQuota: (id: string, quota: string | null) => postJSON(`${DASH}/users/${id}/quota`, { quota }),

  faas: () => getJSON<FaasResponse>(`${DASH}/faas`),
  agents: (probe = false) => getJSON<AgentsResponse>(`${DASH}/agents?probe=${probe ? 1 : 0}`),
  agentDetail: (id: string) => getJSON<{ node: AgentNode; runs?: unknown[] }>(`${DASH}/agents/${id}`),
};
