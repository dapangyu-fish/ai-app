"""myapp-ctl: misc/small commands (split from monolithic myapp_ctl.py; logic unchanged)."""
from __future__ import annotations

import argparse
import ast
import base64
import getpass
import hashlib
import hmac
import json
import os
import re
import secrets as py_secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path
from urllib.parse import quote, urlencode, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from .core import *  # noqa: F401,F403

def cmd_setup(args) -> int:
    if args.no_ingress and args.no_ai and args.no_asr and args.no_email and args.no_push:
        print("nothing to configure: --no-ingress, --no-ai, --no-asr, --no-email, and --no-push were all passed", file=sys.stderr)
        return 2
    try:
        data_root = _ensure_data_root_config(getattr(args, "data_root", None), interactive=True)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    _ensure_data_root_layout(data_root)
    rc = _run_setup_wizard(
        host=args.host,
        force=args.force,
        include_ingress=not args.no_ingress,
        include_ai=not args.no_ai,
        include_asr=not args.no_asr,
        include_email=not args.no_email,
        include_push=not args.no_push,
    )
    if rc == 0:
        _safe_write_default_config_snapshot()
    return rc


def _config_bundle_format(path: Path, requested: str = "auto") -> str:
    if requested != "auto":
        return requested
    if str(path) != "-" and path.suffix.lower() in {".yaml", ".yml"}:
        return "yaml"
    return "json"


def cmd_config(args) -> int:
    if args.config_cmd == "view":
        bundle = _config_bundle(redacted=not args.show_secrets)
        print(json.dumps(bundle, indent=2, ensure_ascii=False))
        return 0
    if args.config_cmd == "export":
        if args.out == "-" and not args.redacted:
            print("refusing to print restorable secrets to stdout; pass --redacted or use --out <file>", file=sys.stderr)
            return 2
        bundle = _config_bundle(redacted=args.redacted)
        out = Path(args.out)
        try:
            _write_config_bundle(out, bundle, fmt=_config_bundle_format(out, args.format))
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 1
        if str(out) != "-":
            print(_t("config_exported", path=str(out)))
        return 0
    if args.config_cmd == "import":
        if not args.yes:
            print(_t("refuse_import_without_yes"), file=sys.stderr)
            return 2
        path = Path(args.path)
        try:
            bundle = _load_config_bundle(path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"config import failed: {exc}", file=sys.stderr)
            return 1
        _import_config_bundle_data(bundle)
        _safe_write_default_config_snapshot()
        print(_t("config_imported", path=str(path)))
        return 0
    if args.config_cmd == "lang":
        if not args.language:
            cfg = _cfg()
            lang = _read_language_preference_file() or _normalize_lang(str(cfg.get("language") or "")) or _LANG
            print(f"{lang} - {_LANGUAGES.get(lang, lang)}")
            return 0
        lang = _normalize_lang(args.language)
        if not lang:
            print("language must be one of: zh, en, de, es, fr, pt, ca, hi, ko, ja, it", file=sys.stderr)
            return 2
        cfg = _cfg()
        _write_language_preference(lang, cfg)
        _set_runtime_language(lang)
        _safe_write_default_config_snapshot()
        print(_t("language_saved", language=f"{lang} - {_LANGUAGES[lang]}"))
        return 0
    return 2


def cmd_secret(args) -> int:
    if args.secret_cmd == "init-stack":
        try:
            data_root = _ensure_data_root_config(getattr(args, "data_root", None), interactive=False)
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        _ensure_data_root_layout(data_root)
        return _init_stack_secrets(host=args.host, force=args.force)
    _secret_dir().mkdir(parents=True, exist_ok=True)
    if args.secret_cmd == "ls":
        rows = []
        for path in sorted(_secret_dir().glob("*.env")):
            for key, value in _parse_env(path).items():
                rows.append({"group": path.stem, "key": key, "value": _redact(value)})
        _print_table(rows, [("group", "GROUP"), ("key", "KEY"), ("value", "VALUE")])
        return 0
    path = _secret_path(args.group)
    data = _parse_env(path)
    if args.secret_cmd == "set":
        changed = []
        for item in args.items:
            if "=" in item:
                key, value = item.split("=", 1)
            else:
                key = item
                value = getpass.getpass(f"{args.group}.{key}: ")
            data[key] = value
            changed.append(key)
        _write_env(path, data)
        _safe_write_default_config_snapshot()
        print(f"updated {args.group}: {', '.join(changed)}")
        return 0
    if args.secret_cmd == "generate":
        changed = []
        for key in args.keys:
            data[key] = py_secrets.token_urlsafe(args.bytes)
            changed.append(key)
        _write_env(path, data)
        _safe_write_default_config_snapshot()
        print(f"generated {args.group}: {', '.join(changed)}")
        return 0
    if args.secret_cmd == "get":
        if args.key not in data:
            print(f"missing: {args.group}.{args.key}", file=sys.stderr)
            return 1
        print(data[args.key] if args.show else _redact(data[args.key]))
        return 0
    if args.secret_cmd == "rm":
        for key in args.keys:
            data.pop(key, None)
        _write_env(path, data)
        _safe_write_default_config_snapshot()
        print(f"updated {args.group}")
        return 0
    return 2


def cmd_registry(args) -> int:
    if args.registry_cmd == "upstream":
        return _registry_upstream(args)
    return 2


def _registry_upstream(args) -> int:
    # REGISTRY_UPSTREAM / REGISTRY_MIRROR_SYNC_INTERVAL_SEC live in the `backend`
    # secret group: the registry compose service loads backend.env, and the
    # deploy --env-file list feeds the ${REGISTRY_UPSTREAM} interpolation in the
    # registry service environment block. Writing here covers both paths.
    path = _secret_path("backend")
    data = _parse_env(path)
    if args.show:
        upstream = data.get("REGISTRY_UPSTREAM", "").strip()
        interval = data.get("REGISTRY_MIRROR_SYNC_INTERVAL_SEC", "").strip()
        print(f"REGISTRY_UPSTREAM={upstream or '(unset — standalone)'}")
        print(f"REGISTRY_MIRROR_SYNC_INTERVAL_SEC={interval or '600 (default)'}")
        return 0
    if args.clear:
        removed = [k for k in ("REGISTRY_UPSTREAM", "REGISTRY_MIRROR_SYNC_INTERVAL_SEC") if k in data]
        for key in removed:
            data.pop(key, None)
        _write_env(path, data)
        print(f"cleared registry upstream ({', '.join(removed) or 'nothing was set'})")
        print("apply with: myapp-ctl deploy --group core   (recreates registry as standalone)")
        return 0
    url = (args.url or "").strip().rstrip("/")
    if not url:
        print("usage: myapp-ctl registry upstream <url> [--sync-interval N] | --show | --clear", file=sys.stderr)
        return 2
    if not (url.startswith("http://") or url.startswith("https://")):
        print(f"invalid upstream url (must start with http:// or https://): {url}", file=sys.stderr)
        return 2
    data["REGISTRY_UPSTREAM"] = url
    if args.sync_interval is not None:
        data["REGISTRY_MIRROR_SYNC_INTERVAL_SEC"] = str(max(30, int(args.sync_interval)))
    _write_env(path, data)
    interval = (data.get("REGISTRY_MIRROR_SYNC_INTERVAL_SEC") or "600").strip()
    print(f"set REGISTRY_UPSTREAM={url} (index sync every {interval}s)")
    print("apply with: myapp-ctl deploy --group core   (syncs env + recreates registry)")
    return 0


def cmd_domain(args) -> int:
    data = _cfg()
    domains = data.setdefault("domains", {})
    if args.domain_cmd == "ls":
        _print_table([{"name": key, "value": value} for key, value in sorted(domains.items())], [("name", "NAME"), ("value", "VALUE")])
        return 0
    if args.domain_cmd == "set":
        domains[args.name] = args.value
        _save_json(CONFIG_PATH, data)
        _safe_write_default_config_snapshot()
        print(f"set domain {args.name}={args.value}")
        return 0
    if args.domain_cmd == "rm":
        domains.pop(args.name, None)
        _save_json(CONFIG_PATH, data)
        _safe_write_default_config_snapshot()
        print(f"removed domain {args.name}")
        return 0
    return 2


def cmd_ingress(args) -> int:
    if args.ingress_cmd == "setup":
        return _setup_ingress_from_args(args, interactive=sys.stdin.isatty() and not getattr(args, "yes", False))
    if args.ingress_cmd == "render":
        return _render_edge_nginx_config(dry_run=args.dry_run)
    if args.ingress_cmd == "reload":
        rc = _render_edge_nginx_config(dry_run=False)
        if rc != 0:
            return rc
        info = _docker_inspect("myapp-edge-nginx")
        if not info or info.get("State", {}).get("Status") != "running":
            print("myapp-edge-nginx is not running; run: myapp-ctl deploy --group edge --pull", file=sys.stderr)
            return 1
        rc = _run_or_print(["docker", "exec", "myapp-edge-nginx", "nginx", "-t"], dry_run=False)
        if rc != 0:
            return rc
        return _run_or_print(["docker", "exec", "myapp-edge-nginx", "nginx", "-s", "reload"], dry_run=False)
    if args.ingress_cmd == "status":
        config = _edge_effective_config()
        rows = [{"name": key, "host": host} for key, host in sorted(config["hosts"].items())]
        print(f"enabled: {config.get('enabled', True)}")
        print(f"tls: {config.get('tls_enabled')}")
        print(f"http port: {config.get('http_port')}")
        print(f"https port: {config.get('https_port')}")
        _print_table(rows, [("name", "NAME"), ("host", "HOST")])
        return 0
    return 2


def cmd_client_env(args) -> int:
    payload = _client_env_payload(host=args.host, name=args.name)
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    out_path = Path(args.out) if args.out else (None if args.json else _default_client_env_path())

    if out_path:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(body + "\n", encoding="utf-8")
        os.chmod(out_path, 0o644)

    qr_path = None
    if not args.no_qr:
        if args.qr:
            qr_path = Path(args.qr)
        elif out_path and not args.json:
            qr_path = out_path.with_suffix(".png")
        if qr_path:
            ok, detail = _write_qr_png(body, qr_path)
            if not ok:
                print(f"warning: QR PNG not generated: {detail}", file=sys.stderr)
            elif not args.json:
                print(_t("client_env_qr", path=detail))

    if args.terminal_qr:
        rc = _print_terminal_qr(body)
        if rc != 0:
            return rc

    if args.json:
        print(body)
        return 0

    if out_path:
        print(_t("client_env_json", path=str(out_path)))
    print(_t("copy_json"))
    print(body)
    return 0


def _image_targets_for_arg(target: str) -> list[str]:
    normalized = (target or "all").strip()
    if normalized in {"", "all"}:
        return list(IMAGE_TARGETS)
    if normalized not in IMAGE_TARGETS:
        raise KeyError(f"unknown image target: {normalized}")
    return [normalized]


def cmd_image(args) -> int:
    if args.image_cmd == "ls":
        rows = []
        for target in IMAGE_TARGETS:
            image = _configured_image(target)
            base_image = _configured_base_image(target)
            rows.append({
                "target": target,
                "image": image,
                "base_image": base_image,
                "state": "present" if _image_exists(image) else "missing",
                "base_state": "present" if _image_exists(base_image) else "missing",
            })
        _print_table(rows, [
            ("target", "TARGET"),
            ("state", "STATE"),
            ("image", "IMAGE"),
            ("base_state", "BASE"),
            ("base_image", "BASE_IMAGE"),
        ])
        return 0
    try:
        targets = _image_targets_for_arg(args.target)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return _deploy_images(
        targets,
        action=args.image_cmd,
        dry_run=args.dry_run,
        include_base=bool(getattr(args, "base", False)),
    )


__all__ = [
    'cmd_setup',
    '_config_bundle_format',
    'cmd_config',
    'cmd_secret',
    'cmd_registry',
    '_registry_upstream',
    'cmd_domain',
    'cmd_ingress',
    'cmd_client_env',
    '_image_targets_for_arg',
    'cmd_image',
]
