#!/usr/bin/env python3
"""Per-user Postgres provisioning for FaaS backends (schema isolation).

Each user gets a dedicated schema + least-privilege login role in a dedicated
``userdata`` database, physically separated from the platform ``jsonapp`` DB.
The role can only touch its own schema (no cross-schema, no platform DB, no
superuser). Generated FaaS code reaches it through a scoped DSN (search_path +
statement_timeout pinned at the role level). See docs/faas-user-database-design.md.

Self-contained config (reads os.environ directly) so importing this module never
forces psycopg2 / DB config on callers that don't use it; faas_store imports it
lazily inside the deploy path.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import secrets
from typing import Any, Optional

ENABLED = os.environ.get("FAAS_USER_DB_ENABLED", "1").strip().lower() in {"1", "true", "yes", "on"}
USER_DB_NAME = os.environ.get("FAAS_USER_DB_NAME", "userdata").strip() or "userdata"
# Admin (superuser) connection — reuse the platform DB credentials (role jsonapp
# is a superuser in this cluster, so it can provision).
ADMIN_HOST = os.environ.get("DB_HOST", "127.0.0.1")
ADMIN_PORT = int(os.environ.get("DB_PORT", "5432"))
ADMIN_USER = os.environ.get("DB_USER", "jsonapp")
ADMIN_PASSWORD = os.environ.get("DB_PASSWORD", "")
PLATFORM_DB_NAME = os.environ.get("DB_NAME", "jsonapp")
# Host:port the FaaS RUNTIME (faasd CNI) uses to reach Postgres. Functions can
# reach the docker bridge gateway IP (same place the openfaas gateway lives), so
# Postgres is published there. Distinct from ADMIN_HOST (docker DNS for backend).
RUNTIME_HOST = os.environ.get("FAAS_USER_DB_RUNTIME_HOST", "172.18.0.1").strip()
RUNTIME_PORT = int(os.environ.get("FAAS_USER_DB_RUNTIME_PORT", "5432"))
CONN_LIMIT = int(os.environ.get("FAAS_USER_DB_CONN_LIMIT", "8"))
STATEMENT_TIMEOUT = os.environ.get("FAAS_USER_DB_STATEMENT_TIMEOUT", "5s").strip() or "5s"
IDLE_TX_TIMEOUT = os.environ.get("FAAS_USER_DB_IDLE_TX_TIMEOUT", "10s").strip() or "10s"
# Deterministic role passwords from a host secret (no secret storage). If unset,
# a random password is generated and stored in the mapping row.
PW_SECRET = os.environ.get("FAAS_USER_DB_SECRET", "").strip()
MIGRATION_MAX_BYTES = int(os.environ.get("FAAS_USER_DB_MIGRATION_MAX_BYTES", "65536"))
MIGRATION_MAX_STATEMENTS = int(os.environ.get("FAAS_USER_DB_MIGRATION_MAX_STATEMENTS", "100"))


class UserDBError(RuntimeError):
    pass


def _hash(user_id: str) -> str:
    return hashlib.sha256(str(user_id).encode("utf-8")).hexdigest()[:16]


def schema_name(user_id: str) -> str:
    return "s_" + _hash(user_id)


def role_name(user_id: str) -> str:
    return "u_" + _hash(user_id)


def _password(user_id: str) -> str:
    if PW_SECRET:
        return hmac.new(PW_SECRET.encode("utf-8"), str(user_id).encode("utf-8"), hashlib.sha256).hexdigest()
    return secrets.token_hex(24)


def _resolve_password(user_id: str, existing: Optional[dict[str, Any]]) -> str:
    """Resolve a STABLE password so repeated provisioning converges.

    With FAAS_USER_DB_SECRET set, the password is derived deterministically (no
    storage needed). Otherwise reuse the password already stored in the mapping
    row — critical because provisioning runs more than once per deploy (deploy +
    migration), and a fresh random each time would leave the injected DSN out of
    sync with the role's actual password.
    """
    if PW_SECRET:
        return _password(user_id)
    if existing and existing.get("dsn"):
        from urllib.parse import unquote, urlsplit
        pw = urlsplit(existing["dsn"]).password
        if pw:
            return unquote(pw)
    return secrets.token_hex(24)


def _dsn(role: str, password: str) -> str:
    from urllib.parse import quote
    return (
        f"postgresql://{quote(role)}:{quote(password)}@{RUNTIME_HOST}:{RUNTIME_PORT}/{USER_DB_NAME}"
    )


def _psycopg2():
    try:
        import psycopg2  # noqa: F401
        return psycopg2
    except ModuleNotFoundError as exc:  # pragma: no cover
        raise UserDBError("psycopg2 is required for FaaS user-db provisioning") from exc


def _admin_conn(dbname: str):
    psycopg2 = _psycopg2()
    conn = psycopg2.connect(
        host=ADMIN_HOST, port=ADMIN_PORT, dbname=dbname,
        user=ADMIN_USER, password=ADMIN_PASSWORD, connect_timeout=10,
    )
    conn.autocommit = True
    return conn


# ── platform-side mapping table (in the jsonapp DB) ──────────────────────────

def ensure_tables() -> None:
    try:
        from database import db_execute
    except ModuleNotFoundError:
        from backend.database import db_execute
    db_execute(
        """
        CREATE TABLE IF NOT EXISTS faas_user_databases (
            user_id TEXT PRIMARY KEY,
            db_name TEXT NOT NULL,
            schema_name TEXT NOT NULL,
            role_name TEXT NOT NULL,
            dsn TEXT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """
    )


def get_user_db(user_id: str) -> Optional[dict[str, Any]]:
    try:
        from database import db_query
    except ModuleNotFoundError:
        from backend.database import db_query
    ensure_tables()
    return db_query(
        "SELECT user_id, db_name, schema_name, role_name, dsn, created_at FROM faas_user_databases WHERE user_id = %s",
        [user_id],
        fetch_one=True,
    )


# ── provisioning ─────────────────────────────────────────────────────────────

_USERDATA_READY = False


def ensure_userdata_db() -> None:
    """Create the dedicated ``userdata`` DB + lockdown once (idempotent)."""
    global _USERDATA_READY
    if _USERDATA_READY:
        return
    psycopg2 = _psycopg2()
    admin = _admin_conn(PLATFORM_DB_NAME)
    try:
        with admin.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", [USER_DB_NAME])
            if not cur.fetchone():
                cur.execute(f'CREATE DATABASE "{USER_DB_NAME}"')
            # Platform DBs: only superusers may connect.
            for db in {PLATFORM_DB_NAME, "postgres"}:
                try:
                    cur.execute(f'REVOKE CONNECT ON DATABASE "{db}" FROM PUBLIC')
                except psycopg2.Error:
                    admin.rollback()
    finally:
        admin.close()
    ud = _admin_conn(USER_DB_NAME)
    try:
        with ud.cursor() as cur:
            cur.execute(f'REVOKE ALL ON DATABASE "{USER_DB_NAME}" FROM PUBLIC')
            cur.execute("REVOKE ALL ON SCHEMA public FROM PUBLIC")
    finally:
        ud.close()
    _USERDATA_READY = True


def provision_user_db(user_id: str) -> dict[str, Any]:
    """Idempotently ensure the user's schema + role exist; return the mapping.

    Re-runs the grants every time (cheap, converges) so a partially-provisioned
    or password-rotated user self-heals.
    """
    if not ENABLED:
        raise UserDBError("FaaS user database is disabled")
    user_id = str(user_id or "").strip()
    if not user_id:
        raise UserDBError("user_id is required")
    ensure_userdata_db()
    ensure_tables()

    role = role_name(user_id)
    schema = schema_name(user_id)
    password = _resolve_password(user_id, get_user_db(user_id))
    # Identifiers are derived from a hash (^[su]_[0-9a-f]{16}$) so direct
    # interpolation is safe; the password is set via parameter.
    ud = _admin_conn(USER_DB_NAME)
    try:
        with ud.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", [role])
            exists = cur.fetchone() is not None
            if not exists:
                cur.execute(
                    f'CREATE ROLE "{role}" LOGIN PASSWORD %s NOSUPERUSER NOCREATEDB '
                    f"NOCREATEROLE NOINHERIT NOREPLICATION CONNECTION LIMIT {int(CONN_LIMIT)}",
                    [password],
                )
            else:
                # Converge the password to the deterministic/derived value.
                cur.execute(f'ALTER ROLE "{role}" WITH PASSWORD %s', [password])
            cur.execute(f'GRANT CONNECT ON DATABASE "{USER_DB_NAME}" TO "{role}"')
            cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{schema}" AUTHORIZATION "{role}"')
            cur.execute(f'GRANT USAGE, CREATE ON SCHEMA "{schema}" TO "{role}"')
            cur.execute(f'ALTER ROLE "{role}" SET search_path = "{schema}"')
            cur.execute(f"ALTER ROLE \"{role}\" SET statement_timeout = '{STATEMENT_TIMEOUT}'")
            cur.execute(
                f"ALTER ROLE \"{role}\" SET idle_in_transaction_session_timeout = '{IDLE_TX_TIMEOUT}'"
            )
    finally:
        ud.close()

    dsn = _dsn(role, password)
    try:
        from database import db_execute
    except ModuleNotFoundError:
        from backend.database import db_execute
    db_execute(
        """
        INSERT INTO faas_user_databases (user_id, db_name, schema_name, role_name, dsn)
        VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT (user_id) DO UPDATE SET
            db_name = EXCLUDED.db_name, schema_name = EXCLUDED.schema_name,
            role_name = EXCLUDED.role_name, dsn = EXCLUDED.dsn
        """,
        [user_id, USER_DB_NAME, schema, role, dsn],
    )
    return {"user_id": user_id, "db_name": USER_DB_NAME, "schema_name": schema, "role_name": role, "dsn": dsn}


def dsn_for_user(user_id: str, *, provision: bool = True) -> Optional[str]:
    existing = get_user_db(user_id)
    if existing and existing.get("dsn"):
        return existing["dsn"]
    if not provision:
        return None
    return provision_user_db(user_id)["dsn"]


# ── migrations (DDL) run as the scoped role into the user schema ──────────────

def run_user_migration(user_id: str, sql: str) -> None:
    """Run a user's schema.sql as their scoped role so all objects land in their
    schema, owned by the role. Confined: even abusive SQL can't escape the role's
    own schema. Capped by size + statement count + statement_timeout."""
    sql = str(sql or "").strip()
    if not sql:
        return
    if len(sql.encode("utf-8")) > MIGRATION_MAX_BYTES:
        raise UserDBError(f"schema.sql too large (> {MIGRATION_MAX_BYTES} bytes)")
    if sql.count(";") > MIGRATION_MAX_STATEMENTS:
        raise UserDBError(f"schema.sql has too many statements (> {MIGRATION_MAX_STATEMENTS})")
    mapping = provision_user_db(user_id)
    role, schema = mapping["role_name"], mapping["schema_name"]
    ud = _admin_conn(USER_DB_NAME)
    try:
        ud.autocommit = False
        with ud.cursor() as cur:
            # Drop superuser powers for the migration: act AS the scoped role.
            cur.execute(f'SET ROLE "{role}"')
            cur.execute(f'SET search_path = "{schema}"')
            cur.execute(f"SET statement_timeout = '{STATEMENT_TIMEOUT}'")
            cur.execute(sql)
        ud.commit()
    except Exception:
        ud.rollback()
        raise
    finally:
        ud.close()
