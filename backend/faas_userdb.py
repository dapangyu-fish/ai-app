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
# Host:port the FaaS RUNTIME containers use to reach Postgres. Functions can
# reach the docker bridge gateway IP, so Postgres is published there. Distinct
# from ADMIN_HOST (docker DNS for the backend).
RUNTIME_HOST = os.environ.get("FAAS_USER_DB_RUNTIME_HOST", "172.18.0.1").strip()
RUNTIME_PORT = int(os.environ.get("FAAS_USER_DB_RUNTIME_PORT", "5432"))
CONN_LIMIT = int(os.environ.get("FAAS_USER_DB_CONN_LIMIT", "8"))
STATEMENT_TIMEOUT = os.environ.get("FAAS_USER_DB_STATEMENT_TIMEOUT", "5s").strip() or "5s"
IDLE_TX_TIMEOUT = os.environ.get("FAAS_USER_DB_IDLE_TX_TIMEOUT", "10s").strip() or "10s"
# B2-G1 (R15): role passwords are RANDOM per tenant (never derived from user_id),
# stored ENCRYPTED at rest. The old FAAS_USER_DB_SECRET deterministic derivation is
# removed — a single leaked host secret must NOT yield every tenant's password.
PW_SECRET = os.environ.get("FAAS_USER_DB_SECRET", "").strip()  # legacy; no longer used for derivation
# Encryption key for credentials at rest. Falls back to AGENT_NODE_TOKEN so a
# deployment that hasn't set it still encrypts with a server-only, non-guessable
# key; if BOTH are empty, credential storage fails closed.
ENC_KEY = (
    os.environ.get("FAAS_USER_DB_ENC_KEY", "").strip()
    or os.environ.get("AGENT_NODE_TOKEN", "").strip()
)
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


def owner_role_name(user_id: str) -> str:
    # B1-G3: NOLOGIN role that OWNS the schema + tables. The runtime login role
    # (role_name) gets only DML, so runtime code cannot ALTER/DROP/TRUNCATE/DISABLE
    # RLS — closing R6 and making FORCE RLS (later) actually enforceable.
    return "o_" + _hash(user_id)


def _fernet():
    if not ENC_KEY:
        raise UserDBError("FAAS_USER_DB_ENC_KEY (or AGENT_NODE_TOKEN) is required to encrypt FaaS DB credentials")
    try:
        import base64
        from cryptography.fernet import Fernet
    except ModuleNotFoundError as exc:  # pragma: no cover
        raise UserDBError("cryptography is required for FaaS DB credential encryption") from exc
    # Any string → a valid 32-byte urlsafe Fernet key.
    key = base64.urlsafe_b64encode(hashlib.sha256(ENC_KEY.encode("utf-8")).digest())
    return Fernet(key)


def _encrypt(plaintext: str) -> str:
    return _fernet().encrypt(plaintext.encode("utf-8")).decode("ascii")


def _decrypt(token: str) -> str:
    try:
        return _fernet().decrypt(token.encode("utf-8")).decode("utf-8")
    except UserDBError:
        raise
    except Exception as exc:
        # Fail CLOSED — never silently fall back to an empty/wrong credential
        # (cold-wake must abort rather than start a container with a bad DSN).
        raise UserDBError("failed to decrypt stored FaaS DB credential") from exc


def _resolve_password(user_id: str, existing: Optional[dict[str, Any]]) -> str:
    """Resolve a STABLE password so repeated provisioning converges (provisioning
    runs more than once per deploy). B2-G1: reuse the encrypted stored password if
    present; migrate a legacy plaintext DSN's password on first re-provision;
    otherwise generate a fresh RANDOM password (never derived from user_id)."""
    if existing and existing.get("pw_enc"):
        return _decrypt(existing["pw_enc"])
    if existing and existing.get("dsn"):  # legacy plaintext row → migrate
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
    # B2-G1: store the password ENCRYPTED here; the plaintext `dsn` column is no
    # longer written (kept for legacy-row migration). Additive, idempotent.
    db_execute("ALTER TABLE faas_user_databases ADD COLUMN IF NOT EXISTS pw_enc TEXT NOT NULL DEFAULT ''")


def get_user_db(user_id: str) -> Optional[dict[str, Any]]:
    try:
        from database import db_query
    except ModuleNotFoundError:
        from backend.database import db_query
    ensure_tables()
    return db_query(
        "SELECT user_id, db_name, schema_name, role_name, dsn, pw_enc, created_at "
        "FROM faas_user_databases WHERE user_id = %s",
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
    owner = owner_role_name(user_id)
    schema = schema_name(user_id)
    password = _resolve_password(user_id, get_user_db(user_id))
    # Identifiers are derived from a hash (^[suo]_[0-9a-f]{16}$) so direct
    # interpolation is safe; the password is set via parameter.
    ud = _admin_conn(USER_DB_NAME)
    try:
        with ud.cursor() as cur:
            # B1-G3: NOLOGIN owner role that OWNS schema + tables.
            cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", [owner])
            if cur.fetchone() is None:
                cur.execute(
                    f'CREATE ROLE "{owner}" NOLOGIN NOSUPERUSER NOCREATEDB '
                    f"NOCREATEROLE NOINHERIT NOREPLICATION"
                )
            # LOGIN runtime role (DML only).
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
            # Schema owned by the owner role. For a fresh user CREATE makes o_ the
            # owner; for an existing schema (previously AUTHORIZATION u_) the ALTER
            # transfers ownership. REASSIGN OWNED then moves any tables/sequences the
            # runtime role used to own (the migration the user authorized) — idempotent.
            cur.execute(f'CREATE SCHEMA IF NOT EXISTS "{schema}" AUTHORIZATION "{owner}"')
            cur.execute(f'ALTER SCHEMA "{schema}" OWNER TO "{owner}"')
            cur.execute(f'REASSIGN OWNED BY "{role}" TO "{owner}"')
            # Runtime role: USAGE (NOT CREATE) + table/sequence DML only. Revoke any
            # legacy CREATE so it can no longer ALTER/DROP/TRUNCATE/DISABLE RLS.
            cur.execute(f'REVOKE CREATE ON SCHEMA "{schema}" FROM "{role}"')
            cur.execute(f'GRANT USAGE ON SCHEMA "{schema}" TO "{role}"')
            cur.execute(
                f'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA "{schema}" TO "{role}"'
            )
            cur.execute(f'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA "{schema}" TO "{role}"')
            # New tables/sequences created by the owner role auto-grant DML to runtime.
            cur.execute(
                f'ALTER DEFAULT PRIVILEGES FOR ROLE "{owner}" IN SCHEMA "{schema}" '
                f'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO "{role}"'
            )
            cur.execute(
                f'ALTER DEFAULT PRIVILEGES FOR ROLE "{owner}" IN SCHEMA "{schema}" '
                f'GRANT USAGE, SELECT ON SEQUENCES TO "{role}"'
            )
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
    # B2-G1: persist the password ENCRYPTED (pw_enc); the plaintext `dsn` column is
    # cleared so credentials are no longer stored in the clear. The DSN is rebuilt
    # in memory from role + decrypted password whenever the runtime needs it.
    pw_enc = _encrypt(password)
    db_execute(
        """
        INSERT INTO faas_user_databases (user_id, db_name, schema_name, role_name, dsn, pw_enc)
        VALUES (%s, %s, %s, %s, '', %s)
        ON CONFLICT (user_id) DO UPDATE SET
            db_name = EXCLUDED.db_name, schema_name = EXCLUDED.schema_name,
            role_name = EXCLUDED.role_name, dsn = '', pw_enc = EXCLUDED.pw_enc
        """,
        [user_id, USER_DB_NAME, schema, role, pw_enc],
    )
    return {"user_id": user_id, "db_name": USER_DB_NAME, "schema_name": schema, "role_name": role, "dsn": dsn}


def list_user_tables(user_id: str) -> list[str]:
    """List the user's existing tables (read-only, best effort) so the agent can
    see the current schema when modifying a DB-backed app. Returns [] if the user
    has no DB yet or on any error."""
    mapping = get_user_db(user_id)
    if not mapping or not mapping.get("schema_name"):
        return []
    try:
        ud = _admin_conn(USER_DB_NAME)
    except Exception:
        return []
    try:
        with ud.cursor() as cur:
            cur.execute(
                "SELECT table_name FROM information_schema.tables "
                "WHERE table_schema = %s ORDER BY table_name",
                [mapping["schema_name"]],
            )
            return [r[0] for r in cur.fetchall()]
    except Exception:
        return []
    finally:
        ud.close()


def drop_user_db(tenant: str) -> None:
    """B3-G5: tear down a tenant's schema + roles + mapping row (app deletion /
    erasure). Idempotent; runs as the provisioning admin."""
    tenant = str(tenant or "").strip()
    if not tenant:
        return
    s, u, o = schema_name(tenant), role_name(tenant), owner_role_name(tenant)
    try:
        ud = _admin_conn(USER_DB_NAME)
    except Exception:
        ud = None
    if ud is not None:
        try:
            ud.autocommit = True
            with ud.cursor() as cur:
                cur.execute(f'DROP SCHEMA IF EXISTS "{s}" CASCADE')
                for role in (u, o):
                    try:
                        cur.execute(f'DROP OWNED BY "{role}"')
                    except Exception:
                        pass
                    try:
                        cur.execute(f'DROP ROLE IF EXISTS "{role}"')
                    except Exception:
                        pass
        finally:
            ud.close()
    try:
        from database import db_execute
    except ModuleNotFoundError:
        from backend.database import db_execute
    db_execute("DELETE FROM faas_user_databases WHERE user_id = %s", [tenant])


def dsn_for_user(user_id: str, *, provision: bool = True) -> Optional[str]:
    existing = get_user_db(user_id)
    if existing:
        # B2-G1: rebuild the DSN in memory from role + decrypted password.
        if existing.get("pw_enc"):
            return _dsn(existing["role_name"], _decrypt(existing["pw_enc"]))
        if existing.get("dsn"):  # legacy plaintext row (pre-B2-G1)
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
    schema = mapping["schema_name"]
    owner = owner_role_name(user_id)
    ud = _admin_conn(USER_DB_NAME)
    try:
        ud.autocommit = False
        with ud.cursor() as cur:
            # B1-G3: run DDL AS THE OWNER ROLE (o_), not the runtime role. Tables
            # thus belong to o_; the runtime role (u_) only ever gets DML (via the
            # default privileges set in provision), so it cannot ALTER/DROP them at
            # runtime. SET ROLE drops the admin's superuser powers for the migration.
            cur.execute(f'SET ROLE "{owner}"')
            cur.execute(f'SET search_path = "{schema}"')
            cur.execute(f"SET statement_timeout = '{STATEMENT_TIMEOUT}'")
            cur.execute(sql)
        ud.commit()
    except Exception:
        ud.rollback()
        raise
    finally:
        ud.close()
