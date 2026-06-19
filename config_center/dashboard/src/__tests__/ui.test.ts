import { describe, it, expect } from 'vitest';
import { fmtTime, ago } from '../ui';

describe('fmtTime', () => {
  it('renders dash for empty', () => {
    expect(fmtTime(null)).toBe('—');
    expect(fmtTime(undefined)).toBe('—');
    expect(fmtTime('')).toBe('—');
  });
  it('formats unix seconds', () => {
    // 2026-06-01T00:00:00Z in seconds → contains the date
    const s = fmtTime(1780272000);
    expect(s).toMatch(/2026-0[56]-/);
  });
  it('formats ISO strings', () => {
    expect(fmtTime('2026-06-01T08:30:00Z')).toMatch(/2026-06-01/);
  });
});

describe('ago', () => {
  it('handles empty', () => {
    expect(ago(null)).toBe('—');
  });
  it('reports seconds for recent', () => {
    expect(ago(new Date().toISOString())).toMatch(/秒前|分钟前/);
  });
});
