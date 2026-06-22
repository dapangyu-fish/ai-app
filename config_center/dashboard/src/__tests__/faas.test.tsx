import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, within } from '@testing-library/react';
import FaasTab from '../tabs/FaasTab';
import { mockFetch } from '../test/util';

const faasPayload = {
  services: [
    {
      service_id: 'svc-1', name: 'shop-api', function_name: 'fn-shop', owner_user_id: 'user1234abcd',
      status: 'active', running: true, deploy_mode: 'local-docker',
      public_base_url: 'https://x/shop', routes_count: 2, active_commit: 'abc1234',
      created_at: '2026-01-01T00:00:00Z', deployed_at: '2026-06-01T00:00:00Z',
      instances: 1, current_capacity: 1, capacity_min: 0, capacity_max: 1, running_replicas: 1,
    },
    {
      service_id: 'svc-2', name: 'sleepy-api', function_name: 'fn-sleepy', owner_user_id: 'user5678efgh',
      status: 'ready', running: true, deploy_mode: 'local-docker',
      public_base_url: null, routes_count: 1, active_commit: 'def5678',
      created_at: '2026-01-02T00:00:00Z', deployed_at: '2026-06-02T00:00:00Z',
      instances: 0, current_capacity: 0, capacity_min: 0, capacity_max: 5, running_replicas: 0,
    },
    {
      service_id: 'svc-3', name: 'dead-api', function_name: 'fn-dead', owner_user_id: 'user9999zzzz',
      status: 'disabled', running: false, deploy_mode: 'local-docker',
      public_base_url: null, routes_count: 1, active_commit: 'aaa0000',
      created_at: '2026-01-03T00:00:00Z', deployed_at: '2026-06-03T00:00:00Z',
      instances: 0, current_capacity: 0, capacity_min: 0, capacity_max: 5, running_replicas: 0,
    },
  ],
  overview: { total: 3, running: 2, stopped: 1, total_instances: 1 },
  deploy_mode: 'local-docker',
  health: {},
};

describe('FaasTab — metrics + lifecycle controls', () => {
  beforeEach(() => mockFetch({ '/faas': faasPayload }));

  it('renders services and the required metric columns', async () => {
    render(<FaasTab />);
    expect(await screen.findByText('shop-api')).toBeInTheDocument();
    const table = within(screen.getByRole('table'));
    expect(table.getByText('实例数量')).toBeInTheDocument();
    expect(table.getByText('当前容量')).toBeInTheDocument();
    expect(table.getByText('容量范围')).toBeInTheDocument();
    expect(table.getByText('启动时间')).toBeInTheDocument();
    expect(table.getByText('操作')).toBeInTheDocument();
    expect(table.getByText('0 – 1')).toBeInTheDocument();
    expect(screen.getByText('服务总数')).toBeInTheDocument();
  });

  it('shows real instance counts (scaled-to-zero is 0, not status-derived 1)', async () => {
    render(<FaasTab />);
    expect(await screen.findByText('sleepy-api')).toBeInTheDocument();
    // svc-2 is "ready" but has 0 running containers → rendered as 休眠, not running·1
    // (scope to the table; the same phrase also appears in the hint paragraph below)
    const table = within(screen.getByRole('table'));
    expect(table.getByText(/0\(休眠\)/)).toBeInTheDocument();
  });

  it('exposes 删除 for every service and 停用 only for non-disabled ones', async () => {
    render(<FaasTab />);
    await screen.findByText('shop-api');
    // delete available for all 3 (incl. the disabled one)
    expect(screen.getAllByRole('button', { name: '删除' })).toHaveLength(3);
    // disable available only for the 2 non-disabled services
    expect(screen.getAllByRole('button', { name: '停用' })).toHaveLength(2);
  });
});
