(function () {
  function extractTextDelta(json) {
    if (!json || typeof json !== 'object') return '';
    const choices = json.choices;
    if (Array.isArray(choices) && choices.length > 0) {
      const first = choices[0] || {};
      if (first.delta && typeof first.delta.content === 'string') {
        return first.delta.content;
      }
      if (typeof first.text === 'string') return first.text;
    }
    if (json.type === 'response.output_text.delta' && typeof json.delta === 'string') {
      return json.delta;
    }
    return '';
  }

  function parseBlock(block) {
    const trimmed = block.trim();
    if (!trimmed) return null;
    const dataLines = [];
    let eventName = null;
    let id = null;
    let retry = null;

    for (const rawLine of block.split('\n')) {
      const line = rawLine.trimEnd();
      if (!line || line.startsWith(':')) continue;
      const sep = line.indexOf(':');
      const field = sep >= 0 ? line.slice(0, sep) : line;
      let value = sep >= 0 ? line.slice(sep + 1) : '';
      if (value.startsWith(' ')) value = value.slice(1);
      if (field === 'event') eventName = value;
      else if (field === 'data') dataLines.push(value);
      else if (field === 'id') id = value;
      else if (field === 'retry') retry = Number.parseInt(value, 10);
    }

    const data = dataLines.join('\n');
    const done = data.trim() === '[DONE]';
    let json = null;
    if (!done && data.trim()) {
      try {
        json = JSON.parse(data);
      } catch (_) {
        json = null;
      }
    }

    return {
      raw: block,
      event: eventName,
      id,
      retry: Number.isFinite(retry) ? retry : null,
      data,
      json,
      done,
      delta: extractTextDelta(json),
    };
  }

  async function stream(params, onEvent) {
    const events = [];
    try {
      const headers = Object.assign(
        { Accept: 'text/event-stream' },
        params.headers || {},
      );
      const init = {
        method: (params.method || 'POST').toUpperCase(),
        headers,
      };
      if (params.body !== undefined && params.body !== null) {
        const contentType = params.contentType || params.content_type || 'application/json';
        headers['Content-Type'] = contentType;
        init.body = contentType === 'application/json'
          ? JSON.stringify(params.body)
          : String(params.body);
      }

      const response = await fetch(params.url, init);
      if (!response.ok) {
        const text = await response.text().catch(() => '');
        return {
          status: response.status,
          events,
          done: false,
          error: text || response.statusText || `HTTP ${response.status}`,
        };
      }
      if (!response.body) {
        return {
          status: response.status,
          events,
          done: false,
          error: 'ReadableStream is not available for this response',
        };
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true }).replace(/\r\n/g, '\n');
        while (true) {
          const idx = buffer.indexOf('\n\n');
          if (idx < 0) break;
          const block = buffer.slice(0, idx);
          buffer = buffer.slice(idx + 2);
          const event = parseBlock(block);
          if (!event) continue;
          events.push(event);
          if (typeof onEvent === 'function') onEvent(event);
          if (event.done) {
            try { await reader.cancel(); } catch (_) {}
            return { status: response.status, events, done: true, error: null };
          }
        }
      }

      const tail = buffer.trim();
      if (tail) {
        const event = parseBlock(tail);
        if (event) {
          events.push(event);
          if (typeof onEvent === 'function') onEvent(event);
        }
      }
      return { status: response.status, events, done: true, error: null };
    } catch (error) {
      return {
        status: -1,
        events,
        done: false,
        error: error && error.message ? error.message : String(error),
      };
    }
  }

  window.MyAppHttpSSE = { stream };
})();
