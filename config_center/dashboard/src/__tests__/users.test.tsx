import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, fireEvent, within } from '@testing-library/react';
import UsersTab from '../tabs/UsersTab';
import { mockFetch } from '../test/util';

const usersPayload = {
  users: [
    { id: 'u1', email: 'alice@x.com', username: 'alice', role: 'admin', quota_override: 50, banned: false, email_confirmed: true, created_at: '2026-01-01T00:00:00Z', last_sign_in_at: null },
    { id: 'u2', email: 'bob@x.com', username: 'bob', role: 'user', quota_override: null, banned: true, email_confirmed: false, created_at: '2026-02-01T00:00:00Z', last_sign_in_at: null },
  ],
  count: 2,
};

describe('UsersTab', () => {
  beforeEach(() => mockFetch({ '/users': usersPayload }));

  it('renders users and KPIs', async () => {
    render(<UsersTab toast={() => {}} />);
    expect(await screen.findByText('alice@x.com')).toBeInTheDocument();
    const table = within(screen.getByRole('table'));
    expect(table.getByText('bob@x.com')).toBeInTheDocument();
    // bob is banned → a "已封禁" badge appears in the table row
    expect(table.getByText('已封禁')).toBeInTheDocument();
    // alice is admin → role badge in the table
    expect(table.getAllByText('admin').length).toBeGreaterThan(0);
  });

  it('filters via search box', async () => {
    render(<UsersTab toast={() => {}} />);
    await screen.findByText('alice@x.com');
    fireEvent.change(screen.getByPlaceholderText(/搜索/), { target: { value: 'bob' } });
    expect(screen.queryByText('alice@x.com')).not.toBeInTheDocument();
    expect(screen.getByText('bob@x.com')).toBeInTheDocument();
  });
});
