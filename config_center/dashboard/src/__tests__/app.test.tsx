import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import App from '../App';
import { mockFetch } from '../test/util';

beforeEach(() =>
  mockFetch({
    '/configs': { configs: [{ key: 'pause_login', value: 'false', value_type: 'bool', comment: '', updated_at: 0, updated_by: '' }], audit: [], apk: { exists: false } },
    '/faas': { services: [], overview: { total: 0, running: 0, stopped: 0, total_instances: 0 }, deploy_mode: 'local-docker', health: {} },
    '/users': { users: [], count: 0 },
    '/agents': { summary: { total: 0 }, nodes: [] },
  }),
);

describe('App shell', () => {
  it('renders all four tabs', async () => {
    render(<App />);
    for (const t of ['配置下发', '用户管理', 'FaaS 服务', 'Agent 节点']) {
      expect(screen.getByRole('tab', { name: t })).toBeInTheDocument();
    }
    // default Config tab loads its data
    expect(await screen.findByText('pause_login')).toBeInTheDocument();
  });

  it('switches to the FaaS tab', async () => {
    render(<App />);
    fireEvent.click(screen.getByRole('tab', { name: 'FaaS 服务' }));
    expect(await screen.findByText('服务总数')).toBeInTheDocument();
  });
});
