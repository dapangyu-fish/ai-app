import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, within } from '@testing-library/react';
import FaasTab from '../tabs/FaasTab';
import { mockFetch } from '../test/util';

const faasPayload = {
  services: [
    {
      service_id: 'svc-1', name: 'shop-api', function_name: 'fn-shop', owner_user_id: 'user1234abcd',
      status: 'active', running: true, deploy_mode: 'local-docker', node_id: 'n1',
      public_base_url: 'https://x/shop', routes_count: 2, active_commit: 'abc1234',
      created_at: '2026-01-01T00:00:00Z', deployed_at: '2026-06-01T00:00:00Z',
      instances: 1, current_capacity: 1, capacity_min: 0, capacity_max: 1,
    },
  ],
  overview: { total: 1, running: 1, stopped: 0, total_instances: 1 },
  deploy_mode: 'local-docker',
  health: {},
};

describe('FaasTab — the 4 required metrics', () => {
  beforeEach(() => mockFetch({ '/faas': faasPayload }));

  it('renders the service and all four metric columns', async () => {
    render(<FaasTab />);
    expect(await screen.findByText('shop-api')).toBeInTheDocument();
    // the 4 required metrics are present as table column headers (scope to the table;
    // the same words also appear in the explanatory hint paragraph below).
    const table = within(screen.getByRole('table'));
    expect(table.getByText('实例数量')).toBeInTheDocument();
    expect(table.getByText('当前容量')).toBeInTheDocument();
    expect(table.getByText('容量范围')).toBeInTheDocument();
    expect(table.getByText('启动时间')).toBeInTheDocument();
    // capacity range value rendered as "min – max"
    expect(table.getByText('0 – 1')).toBeInTheDocument();
    // overview KPI
    expect(screen.getByText('服务总数')).toBeInTheDocument();
  });
});
