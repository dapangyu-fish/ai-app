#!/usr/bin/env python3
"""AI worker daemon.

Run this as a separate process from Flask/gunicorn:
    python -m backend.ai_worker_daemon

It consumes Redis-backed AI jobs and starts Claude CLI workers.
"""

try:
    from .ai_session import run_worker_daemon
except ImportError:
    from ai_session import run_worker_daemon


if __name__ == "__main__":
    run_worker_daemon()
