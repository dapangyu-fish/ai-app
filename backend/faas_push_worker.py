"""Isolated FaaS git push worker.

The backend validates a bundle and ENQUEUES a push job. This worker — which runs
outside the request path and outside any Agent container — commits ONLY the one
user's service subtree and pushes it to the shared myapp-faas-services repo,
serialized with retry/backoff. One user's failure is contained to its own job
and never blocks another user's services. The deploy SSH key lives only where
this worker runs; Agent runtimes never receive it.

Design notes:
- Jobs are claimed atomically with `FOR UPDATE SKIP LOCKED`, so the loop is safe
  even if more than one worker is ever started.
- A commit only stages `service_rel` (one user's subtree), so a bad/oversized
  payload for user A cannot rewrite user B's files.
- Push is idempotent: every attempt re-pushes `HEAD:<branch>` (a no-op when the
  branch is already up to date), so a commit that landed locally but failed to
  push is retried correctly.
"""

from __future__ import annotations

import json
import time
import traceback
import uuid
from pathlib import Path
from typing import Any

try:
    from config import (
        FAAS_CODE_ROOT,
        FAAS_GIT_BRANCH,
        FAAS_GIT_ENABLED,
        FAAS_GIT_PUSH_ENABLED,
        FAAS_GIT_REMOTE,
    )
    from database import db_execute, get_db_connection
    import faas_store
except ModuleNotFoundError:  # pragma: no cover - import shim for package context
    from backend.config import (
        FAAS_CODE_ROOT,
        FAAS_GIT_BRANCH,
        FAAS_GIT_ENABLED,
        FAAS_GIT_PUSH_ENABLED,
        FAAS_GIT_REMOTE,
    )
    from backend.database import db_execute, get_db_connection
    from backend import faas_store


_PUSH_BACKOFF_BASE = 2.0
_PUSH_BACKOFF_MAX = 120.0
_POLL_INTERVAL = 2.0
_DEFAULT_MAX_ATTEMPTS = 5


def ensure_tables() -> None:
    db_execute(
        """
        CREATE TABLE IF NOT EXISTS faas_push_jobs (
            job_id          TEXT PRIMARY KEY,
            owner_user_id   TEXT NOT NULL,
            service_id      TEXT NOT NULL,
            service_rel     TEXT NOT NULL,
            files           JSONB NOT NULL DEFAULT '{}'::jsonb,
            commit_message  TEXT NOT NULL DEFAULT '',
            status          TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'running', 'success', 'failed')),
            attempts        INT NOT NULL DEFAULT 0,
            max_attempts    INT NOT NULL DEFAULT 5,
            commit_sha      TEXT NOT NULL DEFAULT '',
            pushed          BOOLEAN NOT NULL DEFAULT FALSE,
            error           TEXT NOT NULL DEFAULT '',
            next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            started_at      TIMESTAMPTZ,
            finished_at     TIMESTAMPTZ
        )
        """
    )
    db_execute(
        "CREATE INDEX IF NOT EXISTS idx_faas_push_jobs_claim "
        "ON faas_push_jobs(status, next_attempt_at, created_at)"
    )
    db_execute(
        "CREATE INDEX IF NOT EXISTS idx_faas_push_jobs_service "
        "ON faas_push_jobs(service_id, created_at DESC)"
    )
    db_execute(
        "CREATE INDEX IF NOT EXISTS idx_faas_push_jobs_owner "
        "ON faas_push_jobs(owner_user_id, created_at DESC)"
    )


def enqueue_push_job(
    owner_user_id: str,
    service_id: str,
    service_rel: str,
    files: dict[str, str],
    commit_message: str,
    *,
    max_attempts: int = _DEFAULT_MAX_ATTEMPTS,
) -> str:
    if not owner_user_id or not service_id or not service_rel:
        raise ValueError("owner_user_id, service_id and service_rel are required")
    job_id = f"push-{uuid.uuid4().hex}"
    db_execute(
        """
        INSERT INTO faas_push_jobs
            (job_id, owner_user_id, service_id, service_rel, files, commit_message, max_attempts)
        VALUES (%s, %s, %s, %s, %s::jsonb, %s, %s)
        """,
        [
            job_id,
            owner_user_id,
            service_id,
            service_rel,
            json.dumps(files, ensure_ascii=False),
            commit_message,
            max(1, int(max_attempts)),
        ],
    )
    return job_id


def _claim_next_job() -> dict[str, Any] | None:
    """Atomically claim the oldest due pending job (commit-on-claim)."""
    from psycopg2.extras import DictCursor

    conn = get_db_connection()
    try:
        with conn.cursor(cursor_factory=DictCursor) as cur:
            cur.execute(
                """
                UPDATE faas_push_jobs
                SET status = 'running', attempts = attempts + 1,
                    started_at = NOW(), updated_at = NOW()
                WHERE job_id = (
                    SELECT job_id FROM faas_push_jobs
                    WHERE status = 'pending' AND next_attempt_at <= NOW()
                    ORDER BY created_at
                    FOR UPDATE SKIP LOCKED
                    LIMIT 1
                )
                RETURNING job_id, owner_user_id, service_id, service_rel,
                          files, commit_message, attempts, max_attempts
                """
            )
            row = cur.fetchone()
            conn.commit()
            return dict(row) if row else None
    finally:
        conn.close()


def _finish_job(job_id: str, *, status: str, commit_sha: str = "", pushed: bool = False, error: str = "") -> None:
    db_execute(
        """
        UPDATE faas_push_jobs
        SET status = %s, commit_sha = %s, pushed = %s, error = %s,
            finished_at = NOW(), updated_at = NOW()
        WHERE job_id = %s
        """,
        [status, commit_sha, pushed, (error or "")[-4000:], job_id],
    )


def _retry_job(job_id: str, attempts: int, error: str) -> None:
    backoff = min(_PUSH_BACKOFF_MAX, _PUSH_BACKOFF_BASE ** max(1, attempts))
    db_execute(
        """
        UPDATE faas_push_jobs
        SET status = 'pending', error = %s,
            next_attempt_at = NOW() + (%s || ' seconds')::interval,
            updated_at = NOW()
        WHERE job_id = %s
        """,
        [(error or "")[-4000:], str(backoff), job_id],
    )


def _record_service_commit(service_id: str, commit_sha: str) -> None:
    if not commit_sha:
        return
    try:
        db_execute(
            "UPDATE faas_services SET active_commit = %s, updated_at = NOW() WHERE service_id = %s",
            [commit_sha, service_id],
        )
    except Exception:
        # Recording the commit is best-effort metadata; never fail the push for it.
        pass


def _git(args: list[str], *, cwd: Path, check: bool = False):
    return faas_store._run_git(args, cwd=cwd, check=check)


def _push_with_rebase(repo_root: Path) -> str:
    """Push HEAD to the configured branch; rebase once on non-fast-forward."""
    branch = FAAS_GIT_BRANCH
    push = _git(["push", "origin", f"HEAD:{branch}"], cwd=repo_root)
    if push.returncode != 0:
        # Only the worker pushes, so this is rare; reconcile and retry once.
        _git(["fetch", "origin", branch], cwd=repo_root)
        rebased = _git(["rebase", f"origin/{branch}"], cwd=repo_root)
        if rebased.returncode != 0:
            _git(["rebase", "--abort"], cwd=repo_root)
            raise faas_store.FaaSError((push.stderr or push.stdout or "git push failed").strip())
        push = _git(["push", "origin", f"HEAD:{branch}"], cwd=repo_root)
        if push.returncode != 0:
            raise faas_store.FaaSError((push.stderr or push.stdout or "git push failed").strip())
    head = _git(["rev-parse", "--verify", "HEAD"], cwd=repo_root, check=True)
    return head.stdout.strip()


def process_job(job: dict[str, Any]) -> None:
    job_id = str(job["job_id"])
    service_id = str(job["service_id"])
    service_rel = str(job["service_rel"])
    raw_files = job.get("files")
    files = raw_files if isinstance(raw_files, dict) else json.loads(raw_files or "{}")
    commit_message = str(job.get("commit_message") or f"deploy faas service {service_id}")
    attempts = int(job.get("attempts") or 1)
    max_attempts = int(job.get("max_attempts") or _DEFAULT_MAX_ATTEMPTS)

    repo_root = Path(FAAS_CODE_ROOT)
    service_dir = repo_root / service_rel
    try:
        if not FAAS_GIT_ENABLED:
            _finish_job(job_id, status="success", error="git disabled (noop)")
            return

        faas_store._ensure_git_repo(repo_root)
        # Materialize ONLY this user's subtree, then stage ONLY that subtree.
        faas_store._write_service_files(service_dir, files)
        _git(["add", "--", service_rel], cwd=repo_root, check=True)

        staged = _git(["diff", "--cached", "--quiet"], cwd=repo_root)
        if staged.returncode != 0:
            _git(["commit", "-m", commit_message], cwd=repo_root, check=True)

        push_enabled = bool(FAAS_GIT_PUSH_ENABLED and FAAS_GIT_REMOTE)
        if push_enabled:
            # Always re-push HEAD: a no-op if up to date, but ensures a commit
            # that landed locally on a previous failed attempt still reaches the
            # remote on retry.
            commit_sha = _push_with_rebase(repo_root)
            # Reconcile the strict bundle-serving checkout from the just-pushed
            # commit so the runtime serves code that came from git.
            try:
                faas_store._pull_bundle_serve_root()
            except Exception:
                pass
            _record_service_commit(service_id, commit_sha)
            _finish_job(job_id, status="success", commit_sha=commit_sha, pushed=True)
        else:
            head = _git(["rev-parse", "--verify", "HEAD"], cwd=repo_root)
            commit_sha = head.stdout.strip() if head.returncode == 0 else ""
            _record_service_commit(service_id, commit_sha)
            _finish_job(job_id, status="success", commit_sha=commit_sha, pushed=False)
    except Exception as exc:  # noqa: BLE001 - one job's failure must not crash the loop
        detail = f"{exc}\n{traceback.format_exc()}"
        if attempts >= max_attempts:
            _finish_job(job_id, status="failed", error=detail)
        else:
            _retry_job(job_id, attempts, str(exc))


def run_push_worker_loop(*, stop_event: Any = None, poll_interval: float = _POLL_INTERVAL) -> None:
    """Serialized poll loop. Pass a threading.Event as stop_event to stop."""
    ensure_tables()
    while stop_event is None or not stop_event.is_set():
        try:
            job = _claim_next_job()
        except Exception:
            time.sleep(poll_interval)
            continue
        if not job:
            time.sleep(poll_interval)
            continue
        process_job(job)


if __name__ == "__main__":
    run_push_worker_loop()
