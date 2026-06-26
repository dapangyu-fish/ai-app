import { vi } from 'vitest';

/** Minimal fetch Response stub (avoids depending on jsdom's Response). */
export function jr(obj: unknown, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: async () => obj,
  };
}

/** Install a global.fetch that routes by URL substring. */
export function mockFetch(routes: Record<string, unknown>) {
  const fn = vi.fn(async (input?: unknown) => {
    const url =
      typeof input === 'string'
        ? input
        : String((input as { url?: string } | null)?.url ?? input ?? '');
    for (const [frag, payload] of Object.entries(routes)) {
      if (url.includes(frag)) return jr(payload);
    }
    return jr({}, 404);
  });
  (globalThis as unknown as { fetch: unknown }).fetch = fn;
  return fn;
}
