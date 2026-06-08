#!/usr/bin/env python3
"""Control CLI for MyApp backend hosts.

The CLI is intentionally small and dependency-free: service inventory is data
in /etc/myapp/*.json, secrets are host-local files, and Docker/Compose do the
actual process management.
"""

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
from urllib.parse import quote, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


CONFIG_PATH = Path(os.environ.get("MYAPP_CTL_CONFIG", "/etc/myapp/ctl.json"))
SERVICES_PATH = Path(os.environ.get("MYAPP_CTL_SERVICES", "/etc/myapp/services.json"))
LANGUAGE_PATH = Path(os.environ.get("MYAPP_CTL_LANGUAGE_PATH", "/etc/myapp/ctl-language"))
DEFAULT_DATA_ROOT = "/mnt/myapp"
SUPABASE_POSTGRES_IMAGE = "supabase/postgres:15.8.1.085"

DATA_ROOT_DIRS = [
    "state",
    "logs",
    "backend",
    "ai-worker",
    "registry",
    "config-center/data",
    "user-center",
    "agent-runtime",
    "agent-node/state",
    "agent-node/workspaces",
    "agent-node/logs",
    "agent-nodes",
    "jsonapp-postgres/data",
    "ai-session-redis/data",
    "app-minio/data",
    "supabase-studio",
    "supabase-kong",
    "supabase-auth",
    "supabase-rest",
    "supabase-realtime",
    "supabase-storage/data",
    "supabase-imgproxy",
    "supabase-meta",
    "supabase-edge-functions/deno-cache",
    "supabase-analytics",
    "supabase-db/data",
    "supabase-db/config",
    "supabase-vector",
    "supabase-pooler",
    "openim-mysql/data",
    "openim-mongo/data",
    "openim-redis/data",
    "openim-kafka/data",
    "openim-etcd/data",
    "openim-minio/data",
    "openim-server/logs",
]

DEPLOY_ORDER = [
    "agent-runtime",
    "jsonapp-postgres",
    "ai-session-redis",
    "app-minio",
    "supabase-db",
    "supabase-analytics",
    "supabase-studio",
    "supabase-kong",
    "supabase-auth",
    "supabase-rest",
    "supabase-realtime",
    "supabase-imgproxy",
    "supabase-storage",
    "supabase-meta",
    "supabase-edge-functions",
    "supabase-vector",
    "supabase-pooler",
    "openim-mysql",
    "openim-mongo",
    "openim-redis",
    "openim-kafka",
    "openim-etcd",
    "openim-minio",
    "openim-server",
    "agent-node",
    "registry",
    "backend",
    "ai-worker",
    "config-center",
    "user-center",
]
IMAGE_TARGETS = {
    "agent-runtime": ("agent_runtime", "deploy/production/Dockerfile.agent-runtime"),
    "agent-node": ("agent_node", "deploy/production/Dockerfile.agent-node"),
    "backend": ("backend", "deploy/production/Dockerfile.backend"),
}
BACKEND_IMAGE_SERVICES = {"backend", "ai-worker", "registry", "config-center", "user-center"}
DEFAULT_NETWORKS = ["myapp_default", "myapp_agent_runtime"]
COMPOSE_ENV_FILE_NAMES = [
    "backend.env",
    "supabase.env",
    "openim.env",
    "ai-providers.env",
    "agent.env",
    "push.env",
    "config-center.env",
    "user-center.env",
]
_SETUP_SECRET_FILE_CONTAINER_ROOT = "/etc/myapp/secret-files"
_SETUP_SECRET_FILE_HOST_DIR = "files"
_LANG = "en"
_LANGUAGES = {
    "zh": "中文",
    "en": "English",
    "de": "Deutsch",
    "es": "Español",
}
_MESSAGES = {
    "language_prompt": {
        "zh": "请选择 myapp-ctl 语言",
        "en": "Choose the myapp-ctl language",
        "de": "Sprache fuer myapp-ctl waehlen",
        "es": "Elige el idioma de myapp-ctl",
    },
    "language_saved": {
        "zh": "已保存语言: {language}",
        "en": "Saved language: {language}",
        "de": "Sprache gespeichert: {language}",
        "es": "Idioma guardado: {language}",
    },
    "required_value": {
        "zh": "必填，请输入一个值",
        "en": "required; please enter a value",
        "de": "Pflichtfeld; bitte einen Wert eingeben",
        "es": "obligatorio; introduce un valor",
    },
    "enter_yes_no": {
        "zh": "请输入 y 或 n",
        "en": "enter y or n",
        "de": "bitte y oder n eingeben",
        "es": "introduce y o n",
    },
    "input_file_or_paste_keep": {
        "zh": "输入服务器上的文件路径，或粘贴新内容后输入 EOF 结束。第一行直接回车表示保留现有值。",
        "en": "Enter a server file path, or paste new content and finish with EOF. Press Enter on the first line to keep existing.",
        "de": "Server-Dateipfad eingeben oder neuen Inhalt einfuegen und mit EOF beenden. Enter in der ersten Zeile behaelt den bestehenden Wert.",
        "es": "Introduce una ruta de archivo del servidor, o pega contenido nuevo y termina con EOF. Pulsa Enter en la primera linea para conservar el valor actual.",
    },
    "input_file_or_paste_required": {
        "zh": "输入服务器上的文件路径，或粘贴内容后输入 EOF 结束。",
        "en": "Enter a server file path, or paste content and finish with EOF.",
        "de": "Server-Dateipfad eingeben oder Inhalt einfuegen und mit EOF beenden.",
        "es": "Introduce una ruta de archivo del servidor, o pega contenido y termina con EOF.",
    },
    "input_file_or_paste_skip": {
        "zh": "输入服务器上的文件路径，或粘贴内容后输入 EOF 结束。第一行直接回车表示跳过。",
        "en": "Enter a server file path, or paste content and finish with EOF. Press Enter on the first line to skip.",
        "de": "Server-Dateipfad eingeben oder Inhalt einfuegen und mit EOF beenden. Enter in der ersten Zeile ueberspringt.",
        "es": "Introduce una ruta de archivo del servidor, o pega contenido y termina con EOF. Pulsa Enter en la primera linea para omitir.",
    },
    "file_read_error": {
        "zh": "无法读取文件 {path}: {error}",
        "en": "cannot read file {path}: {error}",
        "de": "Datei {path} kann nicht gelesen werden: {error}",
        "es": "no se puede leer el archivo {path}: {error}",
    },
    "required_multiline": {
        "zh": "必填；请输入文件路径，或粘贴内容并用 EOF 结束",
        "en": "required; enter a file path, or paste content and finish with EOF",
        "de": "Pflichtfeld; Dateipfad eingeben oder Inhalt einfuegen und mit EOF beenden",
        "es": "obligatorio; introduce una ruta o pega contenido y termina con EOF",
    },
    "running": {
        "zh": "仍在运行",
        "en": "still running",
        "de": "laeuft noch",
        "es": "sigue ejecutandose",
    },
    "setup_ai_title": {
        "zh": "AI 供应商配置",
        "en": "AI provider setup",
        "de": "KI-Anbieter einrichten",
        "es": "Configuracion del proveedor de IA",
    },
    "optional_push_title": {
        "zh": "可选推送配置。不需要的通道可以跳过。",
        "en": "Optional push setup. Skip a channel if it is not needed now.",
        "de": "Optionale Push-Konfiguration. Nicht benoetigte Kanaele koennen uebersprungen werden.",
        "es": "Configuracion opcional de push. Omite los canales que no necesites ahora.",
    },
    "optional_asr_title": {
        "zh": "可选语音识别配置。",
        "en": "Optional speech recognition setup.",
        "de": "Optionale Spracherkennung einrichten.",
        "es": "Configuracion opcional de reconocimiento de voz.",
    },
    "optional_email_title": {
        "zh": "可选邮箱 SMTP 配置。用于注册验证、找回密码等邮件能力。",
        "en": "Optional SMTP email setup. Used for signup verification, password recovery, and auth mail.",
        "de": "Optionale SMTP-E-Mail-Konfiguration fuer Registrierung, Passwort-Wiederherstellung und Auth-Mails.",
        "es": "Configuracion SMTP opcional para verificacion de registro, recuperacion de contrasena y correo de auth.",
    },
    "configure_smtp_prompt": {
        "zh": "配置 SMTP 邮箱服务器？",
        "en": "configure SMTP email server?",
        "de": "SMTP-Mailserver konfigurieren?",
        "es": "configurar servidor SMTP?",
    },
    "enable_email_signup_prompt": {
        "zh": "启用邮箱注册？",
        "en": "enable email signup?",
        "de": "E-Mail-Registrierung aktivieren?",
        "es": "activar registro por correo?",
    },
    "email_autoconfirm_prompt": {
        "zh": "自动确认邮箱注册并跳过邮件验证？",
        "en": "auto-confirm email signup and skip verification mail?",
        "de": "E-Mail-Registrierung automatisch bestaetigen und Verifizierungs-Mail ueberspringen?",
        "es": "confirmar automaticamente el registro por correo y omitir verificacion?",
    },
    "smtp_admin_email_prompt": {
        "zh": "SMTP 发件邮箱",
        "en": "SMTP admin/from email",
        "de": "SMTP Absender-E-Mail",
        "es": "correo remitente SMTP",
    },
    "smtp_host_prompt": {
        "zh": "SMTP 服务器地址",
        "en": "SMTP host",
        "de": "SMTP-Host",
        "es": "host SMTP",
    },
    "smtp_port_prompt": {
        "zh": "SMTP 端口",
        "en": "SMTP port",
        "de": "SMTP-Port",
        "es": "puerto SMTP",
    },
    "smtp_user_prompt": {
        "zh": "SMTP 用户名",
        "en": "SMTP user",
        "de": "SMTP-Benutzer",
        "es": "usuario SMTP",
    },
    "smtp_pass_prompt": {
        "zh": "SMTP 密码或授权码",
        "en": "SMTP password/app password",
        "de": "SMTP-Passwort/App-Passwort",
        "es": "contrasena SMTP o de aplicacion",
    },
    "smtp_sender_name_prompt": {
        "zh": "SMTP 发件人名称",
        "en": "SMTP sender name",
        "de": "SMTP-Absendername",
        "es": "nombre del remitente SMTP",
    },
    "smtp_config_skipped": {
        "zh": "已跳过 SMTP 邮箱配置",
        "en": "SMTP email config skipped",
        "de": "SMTP-E-Mail-Konfiguration uebersprungen",
        "es": "configuracion SMTP omitida",
    },
    "smtp_config_updated": {
        "zh": "已更新 SMTP 邮箱配置",
        "en": "updated optional SMTP email config",
        "de": "Optionale SMTP-E-Mail-Konfiguration aktualisiert",
        "es": "configuracion SMTP opcional actualizada",
    },
    "client_env_json": {
        "zh": "环境 JSON: {path}",
        "en": "Environment JSON: {path}",
        "de": "Umgebungs-JSON: {path}",
        "es": "JSON de entorno: {path}",
    },
    "client_env_qr": {
        "zh": "二维码 PNG: {path}",
        "en": "QR PNG: {path}",
        "de": "QR-PNG: {path}",
        "es": "PNG QR: {path}",
    },
    "copy_json": {
        "zh": "复制 JSON:",
        "en": "Copy JSON:",
        "de": "JSON kopieren:",
        "es": "Copiar JSON:",
    },
    "client_env_summary": {
        "zh": "客户端环境导入信息",
        "en": "Client environment import",
        "de": "Client-Umgebungsimport",
        "es": "Importacion de entorno del cliente",
    },
    "config_exported": {
        "zh": "已导出配置: {path}",
        "en": "Exported config: {path}",
        "de": "Konfiguration exportiert: {path}",
        "es": "Configuracion exportada: {path}",
    },
    "config_imported": {
        "zh": "已恢复配置: {path}",
        "en": "Imported config: {path}",
        "de": "Konfiguration importiert: {path}",
        "es": "Configuracion importada: {path}",
    },
    "refuse_import_without_yes": {
        "zh": "恢复配置会覆盖本机配置和密钥；请添加 --yes 确认",
        "en": "config import overwrites local config and secrets; pass --yes to confirm",
        "de": "config import ueberschreibt lokale Konfiguration und Secrets; mit --yes bestaetigen",
        "es": "config import sobrescribe configuracion y secretos locales; usa --yes para confirmar",
    },
    "create_test_user_prompt": {
        "zh": "创建/更新测试用户 test@example.com？",
        "en": "create/update test user test@example.com?",
        "de": "Testbenutzer test@example.com erstellen/aktualisieren?",
        "es": "crear/actualizar usuario de prueba test@example.com?",
    },
    "test_user_password_prompt": {
        "zh": "测试用户密码",
        "en": "test user password",
        "de": "Testbenutzer-Passwort",
        "es": "contrasena del usuario de prueba",
    },
    "test_user_password_confirm_prompt": {
        "zh": "再次输入测试用户密码",
        "en": "confirm test user password",
        "de": "Testbenutzer-Passwort bestaetigen",
        "es": "confirma la contrasena del usuario de prueba",
    },
    "password_too_short": {
        "zh": "密码至少需要 {min_len} 位",
        "en": "password must be at least {min_len} characters",
        "de": "Passwort muss mindestens {min_len} Zeichen lang sein",
        "es": "la contrasena debe tener al menos {min_len} caracteres",
    },
    "password_mismatch": {
        "zh": "两次输入的密码不一致",
        "en": "passwords do not match",
        "de": "Passwoerter stimmen nicht ueberein",
        "es": "las contrasenas no coinciden",
    },
    "test_user_skipped_noninteractive": {
        "zh": "跳过测试用户创建：当前不是交互式终端",
        "en": "skipped test user creation: stdin is not interactive",
        "de": "Testbenutzer uebersprungen: stdin ist nicht interaktiv",
        "es": "usuario de prueba omitido: stdin no es interactivo",
    },
    "test_user_skipped": {
        "zh": "已跳过测试用户创建",
        "en": "test user creation skipped",
        "de": "Testbenutzer-Erstellung uebersprungen",
        "es": "creacion de usuario de prueba omitida",
    },
    "test_user_created": {
        "zh": "已创建测试用户: {email}",
        "en": "created test user: {email}",
        "de": "Testbenutzer erstellt: {email}",
        "es": "usuario de prueba creado: {email}",
    },
    "test_user_updated": {
        "zh": "已更新测试用户密码/资料: {email}",
        "en": "updated test user password/profile: {email}",
        "de": "Testbenutzer-Passwort/Profil aktualisiert: {email}",
        "es": "contrasena/perfil del usuario de prueba actualizado: {email}",
    },
    "test_user_missing_supabase": {
        "zh": "缺少 Supabase 管理配置，无法创建测试用户",
        "en": "missing Supabase admin config; cannot create test user",
        "de": "Supabase-Admin-Konfiguration fehlt; Testbenutzer kann nicht erstellt werden",
        "es": "falta configuracion admin de Supabase; no se puede crear usuario de prueba",
    },
    "main_help": {
        "zh": """MyApp 后端控制台

用法:
  myapp-ctl <命令> [参数]
  myapp-ctl --lang zh <命令> [参数]

常用命令:
  status [service]              查看所有服务或单个服务状态
  deploy [all|service|group]    部署全部、某个组件或某个分组
  update                        从 Git 仓库拉取最新代码并刷新 myapp-ctl
  log <service> [-f]            查看服务日志
  restart [service|group]       重启组件或分组
  client-env [--terminal-qr]    生成客户端环境 JSON 和二维码

配置与密钥:
  setup                         首次交互配置 AI/SMTP/推送等
  secret ls|get|set|generate    管理本机密钥文件
  config view|export|import     查看、备份、恢复 ctl 配置
  config lang <zh|en|de|es>     切换 CLI 语言
  domain ls|set|rm              管理服务域名覆盖

镜像与 Agent:
  image ls|build|pull|push      管理 Docker 镜像
  agent ls                      查看当前机器正在运行的 Agent
  agent-node ls|status|register 管理集群 Agent 物理节点
  uninstall --yes [--purge]     停止部署；保留 data root 数据

示例:
  myapp-ctl status
  myapp-ctl update
  myapp-ctl deploy --pull
  myapp-ctl deploy --group core --build
  myapp-ctl log backend -f -n 120
  myapp-ctl config lang zh

查看命令详情:
  myapp-ctl <命令> --help
""",
        "en": """MyApp backend control console

Usage:
  myapp-ctl <command> [options]
  myapp-ctl --lang en <command> [options]

Common commands:
  status [service]              Show all service status or one service
  deploy [all|service|group]    Deploy all, one component, or one group
  update                        Pull latest Git source and refresh myapp-ctl
  log <service> [-f]            Show service logs
  restart [service|group]       Restart a component or group
  client-env [--terminal-qr]    Generate client environment JSON and QR

Configuration and secrets:
  setup                         First-run AI/SMTP/push setup wizard
  secret ls|get|set|generate    Manage host-local secret files
  config view|export|import     View, back up, or restore ctl config
  config lang <zh|en|de|es>     Change CLI language
  domain ls|set|rm              Manage service domain overrides

Images and agents:
  image ls|build|pull|push      Manage Docker images
  agent ls                      Inspect running agents on this host
  agent-node ls|status|register Manage cluster agent hosts
  uninstall --yes [--purge]     Stop deployment; preserve data root

Examples:
  myapp-ctl status
  myapp-ctl update
  myapp-ctl deploy --pull
  myapp-ctl deploy --group core --build
  myapp-ctl log backend -f -n 120
  myapp-ctl config lang en

Command help:
  myapp-ctl <command> --help
""",
        "de": """MyApp Backend-Steuerkonsole

Verwendung:
  myapp-ctl <Befehl> [Optionen]
  myapp-ctl --lang de <Befehl> [Optionen]

Wichtige Befehle:
  status [service]              Status aller Dienste oder eines Dienstes
  deploy [all|service|group]    Alles, eine Komponente oder Gruppe deployen
  update                        Neueste Git-Quelle holen und myapp-ctl aktualisieren
  log <service> [-f]            Dienst-Logs anzeigen
  restart [service|group]       Komponente oder Gruppe neu starten
  client-env [--terminal-qr]    Client-Umgebungs-JSON und QR erzeugen

Konfiguration und Secrets:
  setup                         Ersteinrichtung fuer AI/SMTP/Push
  secret ls|get|set|generate    Host-lokale Secret-Dateien verwalten
  config view|export|import     ctl-Konfiguration anzeigen/sichern/wiederherstellen
  config lang <zh|en|de|es>     CLI-Sprache wechseln
  domain ls|set|rm              Domain-Overrides verwalten

Images und Agents:
  image ls|build|pull|push      Docker-Images verwalten
  agent ls                      Laufende Agents auf diesem Host anzeigen
  agent-node ls|status|register Cluster-Agent-Hosts verwalten
  uninstall --yes [--purge]     Deployment stoppen; data root behalten

Beispiele:
  myapp-ctl status
  myapp-ctl update
  myapp-ctl deploy --pull
  myapp-ctl deploy --group core --build
  myapp-ctl log backend -f -n 120
  myapp-ctl config lang de

Hilfe zu Befehlen:
  myapp-ctl <Befehl> --help
""",
        "es": """Consola de control del backend MyApp

Uso:
  myapp-ctl <comando> [opciones]
  myapp-ctl --lang es <comando> [opciones]

Comandos comunes:
  status [service]              Muestra el estado de servicios
  deploy [all|service|group]    Despliega todo, un componente o un grupo
  update                        Hace git pull y actualiza myapp-ctl
  log <service> [-f]            Muestra logs del servicio
  restart [service|group]       Reinicia un componente o grupo
  client-env [--terminal-qr]    Genera JSON de entorno del cliente y QR

Configuracion y secretos:
  setup                         Configuracion inicial de AI/SMTP/push
  secret ls|get|set|generate    Gestiona secretos locales del host
  config view|export|import     Ver, respaldar o restaurar config de ctl
  config lang <zh|en|de|es>     Cambia el idioma del CLI
  domain ls|set|rm              Gestiona dominios de servicios

Imagenes y agentes:
  image ls|build|pull|push      Gestiona imagenes Docker
  agent ls                      Consulta agents activos en este host
  agent-node ls|status|register Gestiona hosts agent del cluster
  uninstall --yes [--purge]     Detiene el despliegue; conserva data root

Ejemplos:
  myapp-ctl status
  myapp-ctl update
  myapp-ctl deploy --pull
  myapp-ctl deploy --group core --build
  myapp-ctl log backend -f -n 120
  myapp-ctl config lang es

Ayuda de un comando:
  myapp-ctl <comando> --help
""",
    },
    "update_running": {
        "zh": "更新 myapp-ctl：{source}",
        "en": "Updating myapp-ctl: {source}",
        "de": "Aktualisiere myapp-ctl: {source}",
        "es": "Actualizando myapp-ctl: {source}",
    },
    "update_done": {
        "zh": "myapp-ctl 已更新",
        "en": "myapp-ctl updated",
        "de": "myapp-ctl aktualisiert",
        "es": "myapp-ctl actualizado",
    },
    "update_missing_source": {
        "zh": "找不到源码目录: {source}",
        "en": "source directory not found: {source}",
        "de": "Quellverzeichnis nicht gefunden: {source}",
        "es": "directorio de codigo no encontrado: {source}",
    },
    "update_missing_install": {
        "zh": "找不到安装脚本: {path}",
        "en": "install script not found: {path}",
        "de": "Installationsskript nicht gefunden: {path}",
        "es": "script de instalacion no encontrado: {path}",
    },
}


class _CtlHelpFormatter(argparse.RawTextHelpFormatter):
    def __init__(self, prog: str, *args, **kwargs):
        width = shutil.get_terminal_size((100, 24)).columns
        super().__init__(prog, *args, max_help_position=30, width=min(max(width, 88), 120), **kwargs)


class _CtlArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        self.print_usage(sys.stderr)
        self.exit(
            2,
            _tx(
                "%(prog)s: error: %(message)s\n",
                zh="%(prog)s: 错误: %(message)s\n",
                de="%(prog)s: Fehler: %(message)s\n",
                es="%(prog)s: error: %(message)s\n",
            ) % {"prog": self.prog, "message": message},
        )


def _new_parser(*args, **kwargs) -> argparse.ArgumentParser:
    _install_argparse_i18n()
    kwargs.setdefault("formatter_class", _CtlHelpFormatter)
    return _CtlArgumentParser(*args, **kwargs)


def _add_subcommands(parser: argparse.ArgumentParser, dest: str, *, required: bool = True):
    return parser.add_subparsers(
        dest=dest,
        required=required,
        title=_tx("commands", zh="命令", de="Befehle", es="comandos"),
        metavar=_tx("<command>", zh="<命令>", de="<Befehl>", es="<comando>"),
    )


def _load_json(path: Path, default: dict) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default


def _save_json(path: Path, data: dict, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if mode is not None:
        os.chmod(tmp, mode)
    tmp.replace(path)
    if mode is not None:
        os.chmod(path, mode)


def _default_cfg() -> dict:
    return {
        "paths": {
            "root": "/opt/myapp",
            "source": "/opt/myapp/current",
            "data_root": DEFAULT_DATA_ROOT,
            "state": f"{DEFAULT_DATA_ROOT}/state",
            "logs": f"{DEFAULT_DATA_ROOT}/logs",
            "secrets_dir": "/etc/myapp/secrets.d",
            "agent_log_dir": f"{DEFAULT_DATA_ROOT}/agent-node/logs",
            "config_bundle": f"{DEFAULT_DATA_ROOT}/myapp-config.json",
        },
        "domains": {},
    }


def _cfg() -> dict:
    return _load_json(CONFIG_PATH, _default_cfg())


def _data_root_from_cfg(cfg: dict | None = None) -> Path:
    cfg = cfg or _cfg()
    raw = (
        os.environ.get("MYAPP_DATA_ROOT")
        or cfg.get("paths", {}).get("data_root")
        or DEFAULT_DATA_ROOT
    )
    path = Path(str(raw)).expanduser()
    if not path.is_absolute():
        path = (Path.cwd() / path).resolve()
    return path


def _apply_data_root_to_cfg(cfg: dict, data_root: Path) -> dict:
    root = str(data_root)
    paths = cfg.setdefault("paths", {})
    paths["data_root"] = root
    paths.setdefault("root", "/opt/myapp")
    paths.setdefault("source", "/opt/myapp/current")
    paths["state"] = str(data_root / "state")
    paths["logs"] = str(data_root / "logs")
    paths.setdefault("secrets_dir", "/etc/myapp/secrets.d")
    paths["agent_log_dir"] = str(data_root / "agent-node" / "logs")
    paths["config_bundle"] = str(data_root / "myapp-config.json")
    return cfg


def _default_config_bundle_path(cfg: dict | None = None) -> Path:
    cfg = cfg or _cfg()
    configured = cfg.get("paths", {}).get("config_bundle")
    if configured:
        return Path(str(configured)).expanduser()
    return _data_root_from_cfg(cfg) / "myapp-config.json"


def _ensure_data_root_config(data_root: str | None = None, *, interactive: bool = False) -> Path:
    cfg = _cfg()
    existing = str(cfg.get("paths", {}).get("data_root") or "").strip()
    selected = data_root or os.environ.get("MYAPP_DATA_ROOT") or existing or DEFAULT_DATA_ROOT
    if interactive and sys.stdin.isatty():
        should_prompt = not data_root and not cfg.get("paths", {}).get("data_root_prompted")
        if should_prompt:
            selected = _prompt_line("MyApp data root", default=selected or DEFAULT_DATA_ROOT, required=True)
    root = Path(str(selected)).expanduser()
    if not root.is_absolute():
        root = (Path.cwd() / root).resolve()
    if str(root) in {"/", "/mnt", "/var", "/opt", "/etc"}:
        raise ValueError(f"unsafe MyApp data root: {root}")
    _apply_data_root_to_cfg(cfg, root)
    cfg.setdefault("paths", {})["data_root_prompted"] = True
    _save_json(CONFIG_PATH, cfg, mode=0o644)
    return root


def _ensure_data_root_layout(data_root: Path | None = None) -> Path:
    root = data_root or _data_root_from_cfg()
    root.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(root, 0o755)
    except OSError:
        pass
    parent_dirs: set[Path] = set()
    leaf_dirs: set[Path] = set()
    for rel in DATA_ROOT_DIRS:
        path = root / rel
        path.mkdir(parents=True, exist_ok=True)
        leaf_dirs.add(path)
        parent = path.parent
        while parent != root and root in parent.parents:
            parent_dirs.add(parent)
            parent = parent.parent
    for path in sorted(parent_dirs - leaf_dirs, key=lambda p: len(p.parts)):
        try:
            os.chmod(path, 0o755)
        except OSError:
            pass
    for path in sorted(leaf_dirs, key=lambda p: len(p.parts)):
        try:
            os.chmod(path, 0o777)
        except OSError:
            pass
    return root


def _seed_supabase_postgres_custom_config(*, dry_run: bool) -> int:
    """Seed Supabase Postgres custom config into the local data root.

    The Supabase Postgres image ships required files in /etc/postgresql-custom.
    Once that path is a bind mount, an empty host directory hides those files and
    Postgres fails before the health check. Preserve the directory after first
    seed because it also stores database-local custom configuration.
    """
    target = _data_root_from_cfg() / "supabase-db" / "config"
    target.mkdir(parents=True, exist_ok=True)
    try:
        if any(target.iterdir()):
            return 0
    except OSError as exc:
        print(f"cannot inspect Supabase Postgres custom config dir {target}: {exc}", file=sys.stderr)
        return 1
    cmd = [
        "docker",
        "run",
        "--rm",
        "--user",
        "0:0",
        "-v",
        f"{target}:/host",
        SUPABASE_POSTGRES_IMAGE,
        "sh",
        "-lc",
        "cp -a /etc/postgresql-custom/. /host/ && chmod -R a+rwX /host",
    ]
    return _run_or_print(cmd, dry_run=dry_run)


def _t(key: str, **kwargs) -> str:
    row = _MESSAGES.get(key, {})
    text = row.get(_LANG) or row.get("en") or key
    return text.format(**kwargs) if kwargs else text


def _tx(en: str, *, zh: str | None = None, de: str | None = None, es: str | None = None) -> str:
    row = {"en": en, "zh": zh, "de": de, "es": es}
    return row.get(_LANG) or row["en"]


_ARGPARSE_I18N = {
    "usage: ": {
        "zh": "用法: ",
        "en": "usage: ",
        "de": "Verwendung: ",
        "es": "uso: ",
    },
    "options": {
        "zh": "选项",
        "en": "options",
        "de": "Optionen",
        "es": "opciones",
    },
    "positional arguments": {
        "zh": "位置参数",
        "en": "positional arguments",
        "de": "Positionsargumente",
        "es": "argumentos posicionales",
    },
    "show this help message and exit": {
        "zh": "显示此帮助信息并退出",
        "en": "show this help message and exit",
        "de": "diese Hilfe anzeigen und beenden",
        "es": "muestra esta ayuda y termina",
    },
    "error: ": {
        "zh": "错误: ",
        "en": "error: ",
        "de": "Fehler: ",
        "es": "error: ",
    },
    "the following arguments are required: %s": {
        "zh": "缺少必填参数: %s",
        "en": "the following arguments are required: %s",
        "de": "folgende Argumente sind erforderlich: %s",
        "es": "faltan los argumentos obligatorios: %s",
    },
    "invalid choice: %(value)r (choose from %(choices)s)": {
        "zh": "无效选项: %(value)r (可选: %(choices)s)",
        "en": "invalid choice: %(value)r (choose from %(choices)s)",
        "de": "ungueltige Auswahl: %(value)r (waehle aus %(choices)s)",
        "es": "opcion invalida: %(value)r (elige entre %(choices)s)",
    },
    "unrecognized arguments: %s": {
        "zh": "无法识别的参数: %s",
        "en": "unrecognized arguments: %s",
        "de": "unbekannte Argumente: %s",
        "es": "argumentos no reconocidos: %s",
    },
    "argument %(argument_name)s: %(message)s": {
        "zh": "参数 %(argument_name)s: %(message)s",
        "en": "argument %(argument_name)s: %(message)s",
        "de": "Argument %(argument_name)s: %(message)s",
        "es": "argumento %(argument_name)s: %(message)s",
    },
}


def _argparse_gettext(text: str) -> str:
    row = _ARGPARSE_I18N.get(text)
    if not row:
        return text
    return row.get(_LANG) or row.get("en") or text


def _install_argparse_i18n() -> None:
    argparse._ = _argparse_gettext


def _preinitialize_language(raw_args: list[str]) -> None:
    cli_lang = None
    for index, item in enumerate(raw_args):
        if item == "--lang" and index + 1 < len(raw_args):
            cli_lang = _normalize_lang(raw_args[index + 1])
            break
        if item.startswith("--lang="):
            cli_lang = _normalize_lang(item.split("=", 1)[1])
            break
    env_lang = _normalize_lang(os.environ.get("MYAPP_CTL_LANG") or os.environ.get("MYAPP_LANG"))
    cfg = _cfg()
    file_lang = _read_language_preference_file()
    saved_lang = _normalize_lang(str(cfg.get("language") or cfg.get("lang") or ""))
    _set_runtime_language(cli_lang or env_lang or file_lang or saved_lang or "zh")


def _normalize_lang(value: str | None) -> str | None:
    if not value:
        return None
    value = value.strip().lower()
    aliases = {
        "cn": "zh",
        "zh-cn": "zh",
        "chinese": "zh",
        "deutsch": "de",
        "german": "de",
        "spanish": "es",
        "espanol": "es",
        "español": "es",
        "english": "en",
    }
    value = aliases.get(value, value)
    return value if value in _LANGUAGES else None


def _set_runtime_language(lang: str | None) -> None:
    global _LANG
    normalized = _normalize_lang(lang)
    if normalized:
        _LANG = normalized


def _read_language_preference_file() -> str | None:
    try:
        return _normalize_lang(LANGUAGE_PATH.read_text(encoding="utf-8").strip())
    except OSError:
        return None


def _write_language_preference(lang: str, cfg: dict | None = None) -> None:
    normalized = _normalize_lang(lang)
    if not normalized:
        return
    try:
        LANGUAGE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = LANGUAGE_PATH.with_suffix(LANGUAGE_PATH.suffix + ".tmp")
        tmp.write_text(normalized + "\n", encoding="utf-8")
        os.chmod(tmp, 0o644)
        tmp.replace(LANGUAGE_PATH)
        os.chmod(LANGUAGE_PATH, 0o644)
    except OSError:
        pass
    if cfg is None:
        cfg = _cfg()
    cfg["language"] = normalized
    _save_json(CONFIG_PATH, cfg)


def _choose_language_interactive() -> str:
    print(_MESSAGES["language_prompt"]["en"])
    for index, (code, name) in enumerate(_LANGUAGES.items(), start=1):
        print(f"  {index}) {code} - {name}")
    while True:
        value = input("language [1]: ").strip()
        if not value:
            return "zh"
        if value.isdigit():
            idx = int(value)
            codes = list(_LANGUAGES)
            if 1 <= idx <= len(codes):
                return codes[idx - 1]
        normalized = _normalize_lang(value)
        if normalized:
            return normalized
        print("please choose zh, en, de, or es")


def _is_config_lang_command(args) -> bool:
    return getattr(args, "cmd", None) == "config" and getattr(args, "config_cmd", None) == "lang"


def _is_help_command(args) -> bool:
    return getattr(args, "cmd", None) == "help"


def _initialize_language(args) -> None:
    env_lang = _normalize_lang(os.environ.get("MYAPP_CTL_LANG") or os.environ.get("MYAPP_LANG"))
    cli_lang = _normalize_lang(getattr(args, "lang", None))
    cfg = _cfg()
    file_lang = _read_language_preference_file()
    saved_lang = _normalize_lang(str(cfg.get("language") or cfg.get("lang") or ""))
    lang = cli_lang or env_lang or file_lang or saved_lang
    if not lang and sys.stdin.isatty() and not _is_config_lang_command(args) and not _is_help_command(args):
        lang = _choose_language_interactive()
        _write_language_preference(lang, cfg)
        _set_runtime_language(lang)
        print(_t("language_saved", language=f"{lang} - {_LANGUAGES[lang]}"))
        return
    _set_runtime_language(lang or "zh")


def _services() -> dict:
    return _load_json(SERVICES_PATH, {"services": {}}).get("services", {})


def _run_with_heartbeat(cmd: list[str]) -> subprocess.CompletedProcess:
    proc = subprocess.Popen(cmd)
    done = threading.Event()

    def beat() -> None:
        spinner = "|/-\\"
        started = time.time()
        index = 0
        while not done.wait(10):
            elapsed = int(time.time() - started)
            marker = spinner[index % len(spinner)]
            index += 1
            if sys.stderr.isatty():
                print(f"\r# {_t('running')} {marker} {elapsed}s: {cmd[0]}", end="", file=sys.stderr, flush=True)
            else:
                print(f"# {_t('running')} {elapsed}s: {' '.join(cmd[:4])}", file=sys.stderr, flush=True)
        if sys.stderr.isatty():
            print("\r" + " " * 80 + "\r", end="", file=sys.stderr, flush=True)

    thread = threading.Thread(target=beat, daemon=True)
    thread.start()
    returncode = proc.wait()
    done.set()
    thread.join(timeout=1)
    return subprocess.CompletedProcess(cmd, returncode)


def _run(cmd: list[str], *, capture: bool = True) -> subprocess.CompletedProcess:
    kwargs = {"text": True}
    if capture:
        kwargs.update({"stdout": subprocess.PIPE, "stderr": subprocess.PIPE})
        return subprocess.run(cmd, **kwargs)
    return _run_with_heartbeat(cmd)


def _run_capture_text(cmd: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, input=input_text, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def _docker_inspect(name: str) -> dict | None:
    proc = _run(["docker", "inspect", name])
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        rows = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    return rows[0] if rows else None


def _docker_container_running(name: str) -> bool:
    data = _docker_inspect(name)
    state = data.get("State") if isinstance(data, dict) else None
    return bool(isinstance(state, dict) and state.get("Running"))


def _agent_node_instance_slug(node_id: str) -> str:
    text = re.sub(r"[^a-zA-Z0-9_.-]+", "-", str(node_id or "agent-node")).strip(".-")
    return (text.lower() or "agent-node")[:96]


def _agent_node_instance_container_name(node_id: str) -> str:
    return f"myapp-agent-node-{_agent_node_instance_slug(node_id)}"


def _agent_node_instance_root(data_root: Path, node_id: str) -> Path:
    return data_root / "agent-nodes" / _agent_node_instance_slug(node_id)


def _agent_node_container_backend_url(backend_url: str) -> str:
    """Return a backend URL reachable from an extra agent-node container."""
    text = str(backend_url or "").strip().rstrip("/")
    parsed = urlparse(text)
    host = (parsed.hostname or "").lower()
    if host in {"127.0.0.1", "localhost", "0.0.0.0", "::1"} and (parsed.port or 80) == 5566:
        return "http://backend:5566"
    return text


def _write_agent_node_instance_env(path: Path, values: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for key in sorted(values):
        clean_key = str(key).strip()
        if not clean_key or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", clean_key):
            continue
        clean_value = str(values[key]).replace("\r", "").replace("\n", "\\n")
        lines.append(f"{clean_key}={clean_value}")
    path.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")


_AGENT_NODE_INSTANCE_OPTIONAL_PREFIXES = (
    "AGENT_NODE_POLL_",
    "AGENT_NODE_EVENT_",
    "AGENT_NODE_RUN_",
    "AGENT_NODE_CONTAINER_",
)


def _filtered_agent_node_instance_env(values: dict[str, str], keys: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for key in keys:
        value = values.get(key)
        if value is not None and str(value) != "":
            out[key] = str(value)
    for key, value in values.items():
        if any(str(key).startswith(prefix) for prefix in _AGENT_NODE_INSTANCE_OPTIONAL_PREFIXES) and str(value) != "":
            out.setdefault(str(key), str(value))
    return out


def _agent_node_provider_env_path(agent_root: Path) -> Path:
    return agent_root / "ai-providers.env"


def _run_agent_node_instance(
    *,
    node_id: str,
    env_path: Path,
    data_root: Path,
    provider_env_path: Path | None = None,
    build: bool = False,
    pull: bool = False,
) -> int:
    if build and pull:
        print("--build and --pull cannot be used together", file=sys.stderr)
        return 2
    image_targets = ["agent-runtime", "agent-node"]
    if build:
        rc = _deploy_images(image_targets, action="build", dry_run=False)
        if rc != 0:
            return rc
    elif pull:
        rc = _deploy_images(image_targets, action="pull", dry_run=False)
        if rc != 0:
            return rc
    for network in DEFAULT_NETWORKS:
        if not _docker_network_exists(network):
            rc = _run(["docker", "network", "create", network], capture=False).returncode
            if rc != 0:
                return rc
    container = _agent_node_instance_container_name(node_id)
    instance_root = _agent_node_instance_root(data_root, node_id)
    instance_root.mkdir(parents=True, exist_ok=True)
    _run(["docker", "rm", "-f", container], capture=True)
    image = _configured_image("agent-node")
    cmd = [
        "docker",
        "run",
        "-d",
        "--name",
        container,
        "--restart",
        "unless-stopped",
        "--network",
        "myapp_default",
    ]
    if provider_env_path and provider_env_path.exists():
        cmd.extend(["--env-file", str(provider_env_path)])
    cmd.extend(
        [
            "--env-file",
            str(env_path),
            "-e",
            f"AGENT_NODE_PROVIDER_PROXY_BASE_URL=http://{container}:5590",
        ]
    )
    cmd.extend([
        "-e",
        f"AGENT_NODE_RUNTIME_IMAGE={_configured_image('agent-runtime')}",
        "-e",
        "AGENT_NODE_DOCKER_NETWORK=myapp_agent_runtime",
        "-e",
        "AGENT_NODE_STATE_ROOT=/var/lib/myapp/agent-node/state",
        "-e",
        "AGENT_NODE_WORKSPACE_ROOT=/var/lib/myapp/agent-node/workspaces",
        "-e",
        f"AGENT_NODE_HOST_STATE_ROOT={instance_root}/state",
        "-e",
        f"AGENT_NODE_HOST_WORKSPACE_ROOT={instance_root}/workspaces",
        "-e",
        "AGENT_NODE_LOG_DIR=/var/lib/myapp/agent-node/logs",
        "-v",
        "/var/run/docker.sock:/var/run/docker.sock",
        "-v",
        f"{instance_root}:/var/lib/myapp/agent-node",
        image,
    ])
    rc = _run(cmd, capture=False).returncode
    if rc != 0:
        return rc
    rc = _run(["docker", "network", "connect", "myapp_agent_runtime", container], capture=True).returncode
    if rc != 0:
        _run(["docker", "rm", "-f", container], capture=True)
        return rc
    print(f"started agent-node instance: {container}")
    return 0


def _docker_ps_all() -> list[dict]:
    proc = _run(["docker", "ps", "-a", "--format", "{{json .}}"])
    if proc.returncode != 0:
        return []
    rows = []
    for line in proc.stdout.splitlines():
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return rows


def _health(spec: dict | None) -> str:
    if not spec:
        return "-"
    if spec.get("type") == "http":
        try:
            req = Request(str(spec.get("url") or ""), headers={"User-Agent": "myapp-ctl/1"})
            with urlopen(req, timeout=1.2) as resp:
                return "ok" if 200 <= getattr(resp, "status", 0) < 400 else f"http-{resp.status}"
        except HTTPError as exc:
            return f"http-{exc.code}"
        except (URLError, ValueError, OSError):
            return "down"
    if spec.get("type") == "tcp":
        host = str(spec.get("host") or "127.0.0.1")
        try:
            port = int(spec.get("port"))
            with socket.create_connection((host, port), timeout=1.2):
                return "ok"
        except (TypeError, ValueError, OSError):
            return "down"
    return "-"


def _http_json(url: str, *, token: str = "", timeout: float = 3.0) -> dict | None:
    headers = {"User-Agent": "myapp-ctl/1"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    try:
        req = Request(url, headers=headers)
        with urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", errors="replace"))
    except (HTTPError, URLError, OSError, json.JSONDecodeError, ValueError):
        return None


def _image_exists(image: str) -> bool:
    return _run(["docker", "image", "inspect", image]).returncode == 0


def _source_dir() -> Path:
    cfg = _cfg()
    candidates = [
        os.environ.get("MYAPP_SOURCE_DIR"),
        cfg.get("paths", {}).get("source"),
        str(Path(cfg.get("paths", {}).get("root", "/opt/myapp")) / "current"),
        "/opt/myapp/current",
        os.getcwd(),
    ]
    for raw in candidates:
        if not raw:
            continue
        path = Path(str(raw))
        if (path / "deploy/production").is_dir() and (path / "backend").is_dir():
            return path
    return Path(os.getcwd())


def _build_commit_for_source(source_dir: Path) -> str:
    override = str(os.environ.get("MYAPP_BUILD_COMMIT") or "").strip()
    if override:
        return override[:128]
    if not shutil.which("git"):
        return "unknown"
    proc = _run(["git", "-C", str(source_dir), "rev-parse", "--verify", "HEAD"])
    if proc.returncode == 0:
        commit = proc.stdout.strip()
        if commit:
            return commit[:128]
    return "unknown"


def _configured_image(target: str) -> str:
    cfg_images = _cfg().get("images", {})
    key, _ = IMAGE_TARGETS[target]
    default = f"dapangyufish/myapp-{target}:agent-control-plane"
    return str(cfg_images.get(key) or default)


def _image_targets_for_names(names: list[str]) -> list[str]:
    targets: list[str] = []
    if "agent-runtime" in names:
        targets.append("agent-runtime")
    if "agent-node" in names:
        targets.append("agent-node")
    if any(name in BACKEND_IMAGE_SERVICES for name in names):
        targets.append("backend")
    return [target for target in IMAGE_TARGETS if target in targets]


def _ordered_service_names(names: list[str]) -> list[str]:
    known = set(_services())
    seen = set()
    out: list[str] = []
    for name in DEPLOY_ORDER + names:
        if name in known and name in names and name not in seen:
            out.append(name)
            seen.add(name)
    for name in names:
        if name in known and name not in seen:
            out.append(name)
            seen.add(name)
    return out


def _service_names_for_target(target: str | None, group: str | None = None) -> list[str]:
    services = _services()
    if group:
        names = [name for name, spec in services.items() if spec.get("group") == group]
        if not names:
            raise KeyError(f"unknown group: {group}")
        return _ordered_service_names(names)
    normalized = (target or "all").strip()
    if normalized in {"", "all"}:
        return _ordered_service_names([name for name in DEPLOY_ORDER if name in services])
    if normalized in {spec.get("group") for spec in services.values()}:
        names = [name for name, spec in services.items() if spec.get("group") == normalized]
        return _ordered_service_names(names)
    if normalized not in services:
        raise KeyError(f"unknown service or group: {normalized}")
    return [normalized]


def _service_names_for_targets(targets: list[str] | None, group: str | None = None) -> list[str]:
    raw_targets = [str(target).strip() for target in (targets or []) if str(target).strip()]
    if group:
        if raw_targets and raw_targets != ["all"]:
            raise KeyError("--group cannot be combined with explicit service targets")
        return _service_names_for_target(None, group)
    if not raw_targets:
        return _service_names_for_target("all")
    if len(raw_targets) == 1:
        return _service_names_for_target(raw_targets[0])
    if any(target in {"all", ""} for target in raw_targets):
        raise KeyError("'all' cannot be combined with other deploy targets")
    names: list[str] = []
    for target in raw_targets:
        names.extend(_service_names_for_target(target))
    return _ordered_service_names(names)


def _compose_command(spec: dict, command: list[str]) -> list[str]:
    project_dir = Path(spec.get("project_dir", "."))
    files = spec.get("compose_files") or []
    cmd = ["docker", "compose"]
    for env_file in _compose_env_files():
        cmd.extend(["--env-file", str(env_file)])
    for name in files:
        cmd.extend(["-f", str(project_dir / name)])
    cmd.extend(command)
    return [part for part in cmd if part]


def _compose_env_files() -> list[Path]:
    secret_dir = _secret_dir()
    return [secret_dir / name for name in COMPOSE_ENV_FILE_NAMES if (secret_dir / name).exists()]


def _run_or_print(cmd: list[str], *, dry_run: bool) -> int:
    print("+ " + " ".join(cmd))
    if dry_run:
        return 0
    return _run(cmd, capture=False).returncode


def _process_status(spec: dict) -> dict:
    pid_file = spec.get("pid_file")
    pid = None
    alive = False
    if pid_file and Path(pid_file).exists():
        try:
            pid = int(Path(pid_file).read_text(encoding="utf-8").strip())
            os.kill(pid, 0)
            alive = True
        except (OSError, ValueError):
            alive = False
    return {
        "state": "running" if alive else "stopped",
        "pid": pid,
        "status": f"pid {pid}" if alive else "not running",
        "health": _health(spec.get("health")) if alive else "-",
    }


def _service_status(name: str, spec: dict) -> dict:
    kind = spec.get("kind", "docker")
    if kind == "process":
        return {"name": name, "group": spec.get("group", "-"), "kind": kind, **_process_status(spec)}
    if kind == "image":
        image = _configured_image(name) if name in IMAGE_TARGETS else spec.get("image", name)
        return {
            "name": name,
            "group": spec.get("group", "-"),
            "kind": kind,
            "state": "present" if _image_exists(image) else "missing",
            "health": "-",
            "status": image,
        }
    container = spec.get("container") or name
    info = _docker_inspect(container)
    if not info:
        return {
            "name": name,
            "group": spec.get("group", "-"),
            "kind": kind,
            "state": "missing",
            "health": "-",
            "status": container,
        }
    state = info.get("State", {})
    return {
        "name": name,
        "group": spec.get("group", "-"),
        "kind": kind,
        "state": state.get("Status", "unknown"),
        "health": state.get("Health", {}).get("Status") or _health(spec.get("health")),
        "status": container,
    }


def _print_table(rows: list[dict], columns: list[tuple[str, str]]) -> None:
    if not rows:
        print("(empty)")
        return
    widths = [max(len(title), *(len(str(row.get(key, ""))) for row in rows)) for key, title in columns]
    print("  ".join(title.ljust(widths[i]) for i, (_, title) in enumerate(columns)))
    print("  ".join("-" * width for width in widths))
    for row in rows:
        print("  ".join(str(row.get(key, "")).ljust(widths[i]) for i, (key, _) in enumerate(columns)))


def cmd_status(args) -> int:
    services = _services()
    requested = getattr(args, "services", None) or []
    names = requested if requested else sorted(services)
    rows = []
    for name in names:
        if name not in services:
            print(f"unknown service: {name}", file=sys.stderr)
            return 2
        rows.append(_service_status(name, services[name]))
    if not requested:
        declared = {spec.get("container") or name for name, spec in services.items()}
        for item in _docker_ps_all():
            name = item.get("Names") or item.get("Name")
            if name and name not in declared:
                rows.append(
                    {
                        "group": "docker:auto",
                        "name": name,
                        "kind": "docker",
                        "state": item.get("State", "-"),
                        "health": "-",
                        "status": item.get("Status", "-"),
                    }
                )
    if args.json:
        print(json.dumps(rows, indent=2, ensure_ascii=False))
    else:
        _print_table(
            rows,
            [("group", "GROUP"), ("name", "SERVICE"), ("kind", "KIND"), ("state", "STATE"), ("health", "HEALTH"), ("status", "DETAIL")],
        )
    return 0


def _compose_cmd(spec: dict, action: str) -> int:
    project_dir = Path(spec.get("project_dir", "."))
    files = spec.get("compose_files") or []
    if not project_dir.exists():
        print(f"compose project missing: {project_dir}", file=sys.stderr)
        return 1
    if not files:
        print("compose_files is empty", file=sys.stderr)
        return 1
    if action == "deploy":
        cmd = _compose_command(spec, ["up", "-d", spec.get("compose_service", "")])
    else:
        cmd = _compose_command(spec, ["restart", spec.get("compose_service", "")])
    return _run(cmd, capture=False).returncode


def _deploy_images(targets: list[str], *, action: str, dry_run: bool) -> int:
    source_dir = _source_dir()
    build_commit = ""
    build_version = ""
    for target in targets:
        image = _configured_image(target)
        if action == "build":
            if not build_commit:
                build_commit = _build_commit_for_source(source_dir)
                build_version = str(os.environ.get("MYAPP_BUILD_VERSION") or build_commit).strip()[:128] or build_commit
            _, dockerfile = IMAGE_TARGETS[target]
            cmd = [
                "docker",
                "build",
                "--build-arg",
                f"MYAPP_BUILD_COMMIT={build_commit}",
                "--build-arg",
                f"MYAPP_BUILD_VERSION={build_version}",
                "-f",
                str(source_dir / dockerfile),
                "-t",
                image,
                str(source_dir),
            ]
        elif action == "push":
            cmd = ["docker", "push", image]
        elif action == "pull":
            cmd = ["docker", "pull", image]
        else:
            raise ValueError(action)
        rc = _run_or_print(cmd, dry_run=dry_run)
        if rc != 0:
            return rc
    return 0


def _group_in_names(names: list[str], group: str) -> bool:
    services = _services()
    return any(services.get(name, {}).get("group") == group for name in names)


def _prepare_openim_config(spec: dict, *, dry_run: bool) -> int:
    project_dir = Path(spec.get("project_dir", "."))
    cfg_dir = project_dir / "config-rendered"
    env = _parse_env(_secret_path("openim"))
    required = [
        "HOST_IP",
        "OPENIM_MONGO_PASSWORD",
        "OPENIM_REDIS_PASSWORD",
        "OPENIM_MINIO_ACCESS_KEY",
        "OPENIM_MINIO_SECRET_KEY",
        "OPENIM_MINIO_PORT",
        "OPENIM_SECRET",
    ]
    missing = [key for key in required if not env.get(key)]
    if missing:
        print("missing OpenIM env keys: " + ", ".join(missing), file=sys.stderr)
        print("run: myapp-ctl secret init-stack", file=sys.stderr)
        return 1
    image = "openim/openim-server:v3.8.3-patch.12"
    print(f"+ render OpenIM config: {cfg_dir}")
    if dry_run:
        return 0
    if not project_dir.exists():
        print(f"compose project missing: {project_dir}", file=sys.stderr)
        return 1
    if cfg_dir.exists():
        shutil.rmtree(cfg_dir)
    cfg_dir.mkdir(parents=True, exist_ok=True)
    rc = _run(
        [
            "docker",
            "run",
            "--rm",
            "--entrypoint",
            "sh",
            "-v",
            f"{cfg_dir}:/host",
            image,
            "-c",
            "cp -a /openim-server/config/. /host/ && chmod -R a+rwX /host/",
        ],
        capture=False,
    ).returncode
    if rc != 0:
        return rc
    replacements = {
        "mongodb.yml": [
            ("localhost:37017", "mongodb:27017"),
            ("username: openIM", "username: openim"),
            ("password: openIM123", f"password: {env['OPENIM_MONGO_PASSWORD']}"),
            ("authSource: openim_v3", "authSource: admin"),
        ],
        "redis.yml": [
            ("localhost:16379", "redis:6379"),
            ("password: openIM123", f"password: {env['OPENIM_REDIS_PASSWORD']}"),
        ],
        "kafka.yml": [("localhost:19094", "kafka:9092")],
        "discovery.yml": [("localhost:12379", "etcd:2379")],
        "minio.yml": [
            ("accessKeyID: root", f"accessKeyID: {env['OPENIM_MINIO_ACCESS_KEY']}"),
            ("secretAccessKey: openIM123", f"secretAccessKey: {env['OPENIM_MINIO_SECRET_KEY']}"),
            ("localhost:10005", "minio:9000"),
            ("http://external_ip:10005", f"http://{env['HOST_IP']}:{env['OPENIM_MINIO_PORT']}"),
        ],
        "share.yml": [("secret: openIM123", f"secret: {env['OPENIM_SECRET']}")],
    }
    for rel, pairs in replacements.items():
        path = cfg_dir / rel
        if not path.exists():
            print(f"OpenIM config file missing after extract: {path}", file=sys.stderr)
            return 1
        text = path.read_text(encoding="utf-8")
        for old, new in pairs:
            text = text.replace(old, new)
        path.write_text(text, encoding="utf-8")
    return 0


def _prepare_deploy(names: list[str], *, dry_run: bool) -> int:
    if _group_in_names(names, "supabase"):
        rc = _seed_supabase_postgres_custom_config(dry_run=dry_run)
        if rc != 0:
            return rc
    if not _group_in_names(names, "openim"):
        return 0
    services = _services()
    for name in names:
        spec = services.get(name, {})
        if spec.get("group") == "openim" and spec.get("kind") == "compose":
            return _prepare_openim_config(spec, dry_run=dry_run)
    return 0


def _ensure_images(targets: list[str], *, dry_run: bool) -> int:
    if dry_run:
        return 0
    missing = [target for target in targets if not _image_exists(_configured_image(target))]
    if missing:
        for target in missing:
            print(f"missing image: {_configured_image(target)}", file=sys.stderr)
        print("run with --pull to pull images or --build to build them locally", file=sys.stderr)
        return 1
    return 0


def _deploy_compose_services(names: list[str], *, dry_run: bool) -> int:
    services = _services()
    current_key: tuple[str, tuple[str, ...]] | None = None
    current_spec: dict | None = None
    current_services: list[str] = []

    def flush() -> int:
        nonlocal current_key, current_spec, current_services
        if not current_spec or not current_services:
            current_key = None
            current_spec = None
            current_services = []
            return 0
        cmd = _compose_command(current_spec, ["up", "-d", *current_services])
        rc = _run_or_print(cmd, dry_run=dry_run)
        current_key = None
        current_spec = None
        current_services = []
        return rc

    for name in names:
        spec = services[name]
        kind = spec.get("kind")
        if kind == "docker":
            rc = flush()
            if rc != 0:
                return rc
            rc = _run_or_print(["docker", "start", spec.get("container") or name], dry_run=dry_run)
            if rc != 0:
                return rc
            continue
        if kind != "compose":
            rc = flush()
            if rc != 0:
                return rc
            continue
        project_dir = str(spec.get("project_dir", "."))
        compose_files = tuple(spec.get("compose_files") or [])
        key = (project_dir, compose_files)
        if current_key is not None and key != current_key:
            rc = flush()
            if rc != 0:
                return rc
        current_key = key
        current_spec = spec
        current_services.append(str(spec.get("compose_service") or name))
    return flush()


def _deploy_needs_supabase_auth_migration(names: list[str]) -> bool:
    services = _services()
    return any(services.get(name, {}).get("group") == "supabase" for name in names)


def _run_supabase_auth_migrations(*, dry_run: bool) -> int:
    cmd = ["docker", "exec", "supabase-auth", "gotrue", "migrate"]
    print("+ " + " ".join(cmd))
    if dry_run:
        return 0
    info = _docker_inspect("supabase-auth")
    if not info or info.get("State", {}).get("Status") != "running":
        print("supabase-auth is not running; cannot run GoTrue migrations", file=sys.stderr)
        return 1
    return _run(cmd, capture=False).returncode


def _compose_specs_for_names(names: list[str]) -> list[dict]:
    services = _services()
    seen: set[tuple[str, tuple[str, ...]]] = set()
    specs: list[dict] = []
    for name in names:
        spec = services[name]
        if spec.get("kind") != "compose":
            continue
        key = (str(spec.get("project_dir", ".")), tuple(spec.get("compose_files") or []))
        if key in seen:
            continue
        seen.add(key)
        specs.append(spec)
    return specs


def _remove_path(path: Path, *, dry_run: bool) -> int:
    print(f"+ rm -rf {path}")
    if dry_run or not path.exists():
        return 0
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    else:
        path.unlink()
    return 0


def _remove_installed_config_path(path: Path, *, dry_run: bool) -> int:
    if not path.is_absolute():
        print(f"# skip non-installed config path: {path}")
        return 0
    data_root = _data_root_from_cfg()
    try:
        path.resolve().relative_to(data_root.resolve())
        print(f"# preserve data-root config path: {path}")
        return 0
    except (OSError, ValueError):
        pass
    return _remove_path(path, dry_run=dry_run)


def _docker_container_names(pattern: str) -> list[str]:
    proc = _run(["docker", "ps", "-a", "--filter", f"name={pattern}", "--format", "{{.Names}}"])
    if proc.returncode != 0:
        return []
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def _docker_network_exists(name: str) -> bool:
    return _run(["docker", "network", "inspect", name]).returncode == 0


def cmd_uninstall(args) -> int:
    if not args.yes:
        print("refusing to uninstall without --yes", file=sys.stderr)
        return 2
    services = _services()
    names = _ordered_service_names(list(services))
    purge = bool(args.purge)
    remove_images = bool(args.images or purge)
    dry_run = bool(args.dry_run)
    data_root = _data_root_from_cfg()

    for spec in _compose_specs_for_names(names):
        project_dir = Path(spec.get("project_dir", "."))
        compose_files = [project_dir / name for name in (spec.get("compose_files") or [])]
        if not dry_run and (not project_dir.exists() or any(not path.exists() for path in compose_files)):
            continue
        cmd = _compose_command(spec, ["down", "--remove-orphans"])
        if purge or args.volumes:
            cmd.append("--volumes")
        rc = _run_or_print(cmd, dry_run=dry_run)
        if rc != 0:
            return rc

    docker_names = []
    for name in names:
        spec = services[name]
        if spec.get("kind") == "docker":
            docker_names.append(spec.get("container") or name)
    docker_names.extend(name for name in _docker_container_names("myapp-agent-") if name != "myapp-agent-node")
    seen_containers: set[str] = set()
    for container in docker_names:
        if container in seen_containers:
            continue
        seen_containers.add(container)
        if not dry_run and not _docker_inspect(container):
            continue
        rc = _run_or_print(["docker", "rm", "-f", container], dry_run=dry_run)
        if rc != 0:
            return rc

    for network in DEFAULT_NETWORKS:
        if not dry_run and not _docker_network_exists(network):
            continue
        rc = _run_or_print(["docker", "network", "rm", network], dry_run=dry_run)
        if rc != 0:
            return rc

    if remove_images:
        for target in IMAGE_TARGETS:
            if not dry_run and not _image_exists(_configured_image(target)):
                continue
            rc = _run_or_print(["docker", "rmi", "-f", _configured_image(target)], dry_run=dry_run)
            if rc != 0:
                return rc

    if purge or args.state:
        print(f"# preserve MyApp data/state under {data_root}")
    if purge or args.logs:
        print(f"# preserve MyApp data/logs under {data_root}")
    if purge or args.secrets:
        try:
            _secret_dir().resolve().relative_to(data_root.resolve())
            print(f"# preserve data-root secrets dir: {_secret_dir()}")
        except (OSError, ValueError):
            _remove_path(_secret_dir(), dry_run=dry_run)
    if purge or args.install_files:
        cfg = _cfg()
        root = Path(cfg.get("paths", {}).get("root", "/opt/myapp"))
        _remove_path(root / "deploy/production", dry_run=dry_run)
        _remove_installed_config_path(CONFIG_PATH, dry_run=dry_run)
        _remove_installed_config_path(SERVICES_PATH, dry_run=dry_run)
    if args.remove_ctl:
        _remove_path(Path("/usr/local/bin/myapp-ctl"), dry_run=dry_run)
        _remove_path(Path("/opt/myapp/bin/myapp-ctl"), dry_run=dry_run)
    print("uninstall completed" if not dry_run else "uninstall dry-run completed")
    print(f"data root preserved: {data_root}")
    print("to permanently delete all MyApp local data and the restorable config snapshot, run manually:")
    print(f"  rm -rf -- {shlex.quote(str(data_root))}")
    return 0


def cmd_deploy(args) -> int:
    if args.build and args.pull:
        print("--build and --pull cannot be used together", file=sys.stderr)
        return 2
    try:
        names = _service_names_for_targets(args.targets, args.group)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    image_targets = _image_targets_for_names(names)
    if args.plan:
        services = _services()
        compose_names = [name for name in names if services[name].get("kind") == "compose"]
        docker_names = [name for name in names if services[name].get("kind") == "docker"]
        print("deploy plan:")
        if image_targets:
            print("  images: " + ", ".join(image_targets))
        if compose_names:
            print("  compose services: " + ", ".join(compose_names))
        if docker_names:
            print("  docker containers: " + ", ".join(docker_names))
        return 0
    try:
        data_root = _ensure_data_root_config(
            getattr(args, "data_root", None),
            interactive=not getattr(args, "no_setup", False),
        )
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    try:
        _restore_data_root_config_if_needed(data_root)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"data root config restore failed: {exc}", file=sys.stderr)
        return 1
    _ensure_data_root_layout(data_root)
    rc = _ensure_human_config_for_deploy(args, names)
    if rc != 0:
        return rc
    if args.build:
        rc = _deploy_images(image_targets, action="build", dry_run=args.dry_run)
        if rc != 0:
            return rc
    elif args.pull:
        rc = _deploy_images(image_targets, action="pull", dry_run=args.dry_run)
        if rc != 0:
            return rc
    else:
        rc = _ensure_images(image_targets, dry_run=args.dry_run)
        if rc != 0:
            return rc
    if not args.dry_run:
        _init_stack_secrets(quiet=True)
    rc = _prepare_deploy(names, dry_run=args.dry_run)
    if rc != 0:
        return rc
    rc = _guard_active_ai_runs_for_deploy(args, names)
    if rc != 0:
        return rc
    rc = _deploy_compose_services(names, dry_run=args.dry_run)
    if rc != 0:
        return rc
    if "agent-node" in names:
        rc = _ensure_local_agent_node_registration_timer(dry_run=args.dry_run)
        if rc != 0:
            return rc
    if _deploy_needs_supabase_auth_migration(names):
        rc = _run_supabase_auth_migrations(dry_run=args.dry_run)
        if rc != 0:
            return rc
    if not args.dry_run and not args.no_test_user and _deploy_can_seed_test_user(names):
        rc = _maybe_seed_test_user(args)
        if rc != 0:
            return rc
    if not args.dry_run and not args.no_client_env and _is_full_deploy(args):
        _emit_client_env_summary(
            host=args.client_env_host or args.host,
            name=args.client_env_name,
            terminal_qr=not args.no_terminal_qr,
        )
    if not args.dry_run:
        _safe_write_default_config_snapshot()
    return 0


def _is_full_deploy(args) -> bool:
    targets = [str(target).strip() for target in (getattr(args, "targets", None) or []) if str(target).strip()]
    return not args.group and (not targets or targets == ["all"])


def cmd_setup(args) -> int:
    if args.no_ai and args.no_asr and args.no_email and args.no_push:
        print("nothing to configure: --no-ai, --no-asr, --no-email, and --no-push were all passed", file=sys.stderr)
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
        include_ai=not args.no_ai,
        include_asr=not args.no_asr,
        include_email=not args.no_email,
        include_push=not args.no_push,
    )
    if rc == 0:
        _safe_write_default_config_snapshot()
    return rc


def cmd_update(args) -> int:
    source = Path(args.source).expanduser() if args.source else _source_dir()
    if not source.exists():
        print(_t("update_missing_source", source=str(source)), file=sys.stderr)
        return 1
    install_script = source / "deploy/production/install_ctl.sh"
    if not install_script.exists():
        print(_t("update_missing_install", path=str(install_script)), file=sys.stderr)
        return 1
    print(_t("update_running", source=str(source)))
    if not args.no_pull:
        if (source / ".git").exists():
            rc = _run(["git", "-C", str(source), "pull", "--ff-only"], capture=False).returncode
            if rc != 0:
                return rc
        else:
            print(f"source is not a git checkout; skipping git pull: {source}")
    rc = _run(["bash", str(install_script)], capture=False).returncode
    if rc != 0:
        return rc
    print(_t("update_done"))
    return 0


def cmd_restart(args) -> int:
    try:
        names = _service_names_for_targets(args.targets, args.group)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    for name in names:
        spec = _services()[name]
        kind = spec.get("kind", "docker")
        if kind == "compose":
            rc = _compose_cmd(spec, "restart")
            if rc != 0:
                return rc
            continue
        if kind == "image":
            print(f"skip image target {name}; use myapp-ctl image build/pull/push {name}")
            continue
        if kind != "process":
            rc = _run(["docker", "restart", spec.get("container") or name], capture=False).returncode
            if rc != 0:
                return rc
            continue
        status = _process_status(spec)
        if status.get("pid") and status.get("state") == "running":
            os.kill(int(status["pid"]), signal.SIGTERM)
            time.sleep(1)
        command = spec.get("command")
        if not command:
            print(f"{name} has no command", file=sys.stderr)
            return 1
        log_file = spec.get("log_file") or f"/var/log/myapp/{name}.log"
        Path(log_file).parent.mkdir(parents=True, exist_ok=True)
        with open(log_file, "ab") as out:
            subprocess.Popen(command, stdout=out, stderr=out, stdin=subprocess.DEVNULL, start_new_session=True)
        print(f"restarted process {name}")
    return 0


def cmd_log(args) -> int:
    spec = _services().get(args.service)
    if not spec:
        print(f"unknown service: {args.service}", file=sys.stderr)
        return 2
    if spec.get("log_file"):
        cmd = ["tail", "-n", str(args.lines)]
        if args.follow:
            cmd.append("-f")
        cmd.append(spec["log_file"])
        return _run(cmd, capture=False).returncode
    cmd = ["docker", "logs", "--tail", str(args.lines)]
    if args.follow:
        cmd.append("-f")
    cmd.append(spec.get("container") or args.service)
    return _run(cmd, capture=False).returncode


def _secret_dir() -> Path:
    return Path(_cfg().get("paths", {}).get("secrets_dir", "/etc/myapp/secrets.d"))


def _secret_path(group: str) -> Path:
    return _secret_dir() / f"{group.replace('/', '_').replace('..', '_')}.env"


def _decode_env_value(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        try:
            decoded = ast.literal_eval(value)
            return str(decoded)
        except (SyntaxError, ValueError):
            return value[1:-1]
    return value


def _quote_env_value(value: object) -> str:
    text = "" if value is None else str(value)
    if text and re.fullmatch(r"[A-Za-z0-9_./:@%+=,\-\[\]]+", text):
        return text
    escaped = (
        text.replace("\\", "\\\\")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace('"', '\\"')
    )
    return f'"{escaped}"'


def _parse_env(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    data = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = _decode_env_value(value)
    return data


def _write_env(path: Path, data: dict[str, str]) -> None:
    body = "".join(f"{key}={_quote_env_value(value)}\n" for key, value in sorted(data.items()))
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(body, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def _setup_secret_host_root() -> Path:
    return _secret_dir() / _SETUP_SECRET_FILE_HOST_DIR


def _setup_secret_container_path(*parts: str) -> str:
    safe_parts = [part.strip("/").replace("..", "") for part in parts if part]
    return "/".join([_SETUP_SECRET_FILE_CONTAINER_ROOT.rstrip("/"), *safe_parts])


def _write_secret_file(*, subdir: str, filename: str, content: str) -> str:
    safe_name = Path(filename).name
    if not safe_name:
        raise ValueError("secret filename is empty")
    host_dir = _setup_secret_host_root() / subdir
    host_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(host_dir, 0o700)
    host_path = host_dir / safe_name
    body = content if content.endswith("\n") else content + "\n"
    tmp = host_path.with_suffix(host_path.suffix + ".tmp")
    tmp.write_text(body, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(host_path)
    os.chmod(host_path, 0o600)
    return _setup_secret_container_path(subdir, safe_name)


def _truthy_env(value: str | None) -> bool:
    return (value or "").strip().lower() in {"1", "true", "yes", "y", "on"}


def _prompt_line(prompt: str, *, default: str = "", required: bool = False, secret: bool = False) -> str:
    suffix = ""
    if default and secret:
        suffix = " [keep existing]"
    elif default:
        suffix = f" [{default}]"
    while True:
        label = f"{prompt}{suffix}: "
        if secret and sys.stdin.isatty():
            value = getpass.getpass(label)
        else:
            value = input(label)
        value = value.strip()
        if value:
            return value
        if default:
            return default
        if not required:
            return ""
        print(_t("required_value"), file=sys.stderr)


def _prompt_bool(prompt: str, *, default: bool = False) -> bool:
    suffix = "Y/n" if default else "y/N"
    while True:
        value = input(f"{prompt} [{suffix}]: ").strip().lower()
        if not value:
            return default
        if value in {"y", "yes", "1", "true"}:
            return True
        if value in {"n", "no", "0", "false"}:
            return False
        print(_t("enter_yes_no"), file=sys.stderr)


def _prompt_multiline(prompt: str, *, default: str = "", required: bool = False) -> str:
    print(prompt)
    if default:
        print(_t("input_file_or_paste_keep"))
    elif required:
        print(_t("input_file_or_paste_required"))
    else:
        print(_t("input_file_or_paste_skip"))
    while True:
        try:
            first = input()
        except EOFError:
            first = ""
        if first == "" and (default or not required):
            return default
        if first.strip() == "EOF":
            if default:
                return default
            if not required:
                return ""
            print(_t("required_multiline"), file=sys.stderr)
            continue

        candidate = first.strip()
        path_text = candidate[1:] if candidate.startswith("@") else candidate
        looks_like_path = candidate.startswith("@") or path_text.startswith(("/", "~", "./", "../"))
        if looks_like_path:
            path = Path(path_text).expanduser()
            try:
                return path.read_text(encoding="utf-8").strip()
            except OSError as exc:
                print(_t("file_read_error", path=str(path), error=exc), file=sys.stderr)
                if required:
                    continue
                return default

        if not first and required:
            print(_t("required_multiline"), file=sys.stderr)
            continue
        lines: list[str] = []
        if first:
            lines.append(first)
        while True:
            try:
                line = input()
            except EOFError:
                line = "EOF"
            if line == "EOF":
                break
            lines.append(line)
        value = "\n".join(lines).strip()
        if value:
            return value
        if default:
            return default
        if not required:
            return ""
        print(_t("required_multiline"), file=sys.stderr)


def _normalize_provider_id(value: str) -> str:
    normalized = re.sub(r"[^a-z0-9]+", "-", value.strip().lower()).strip("-")
    return normalized or "custom"


def _provider_prefix(provider_id: str) -> str:
    return "".join(ch.upper() if ch.isalnum() else "_" for ch in provider_id)


def _split_csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def _ai_provider_ids_from_env(env: dict[str, str]) -> list[str]:
    ids = [_normalize_provider_id(item) for item in _split_csv(env.get("AI_PROVIDER_IDS", ""))]
    seen = set()
    out: list[str] = []
    for provider_id in ids:
        if provider_id not in seen:
            out.append(provider_id)
            seen.add(provider_id)
    if out:
        return out
    for key, value in env.items():
        if key.endswith("_ANTHROPIC_AUTH_TOKEN") and value:
            out.append(_normalize_provider_id(key[: -len("_ANTHROPIC_AUTH_TOKEN")]))
    for key, value in env.items():
        if key.endswith("_CODEX_BASE_URL") and value:
            provider_id = _normalize_provider_id(key[: -len("_CODEX_BASE_URL")])
            prefix = _provider_prefix(provider_id)
            env_key = env.get(f"{prefix}_CODEX_ENV_KEY") or f"{prefix}_CODEX_AUTH_TOKEN"
            if env.get(f"{prefix}_CODEX_MODEL") and env_key and env.get(env_key) and provider_id not in out:
                out.append(provider_id)
    for key, value in env.items():
        if key.endswith("_OPENCODE_BASE_URL") and value:
            provider_id = _normalize_provider_id(key[: -len("_OPENCODE_BASE_URL")])
            prefix = _provider_prefix(provider_id)
            env_key = env.get(f"{prefix}_OPENCODE_ENV_KEY") or f"{prefix}_OPENCODE_AUTH_TOKEN"
            if env.get(f"{prefix}_OPENCODE_MODEL") and env_key and env.get(env_key) and provider_id not in out:
                out.append(provider_id)
    return out


def _provider_has_anthropic_adapter(env: dict[str, str], provider_id: str) -> bool:
    prefix = _provider_prefix(provider_id)
    return bool(
        env.get(f"{prefix}_ANTHROPIC_BASE_URL")
        and env.get(f"{prefix}_ANTHROPIC_AUTH_TOKEN")
        and env.get(f"{prefix}_ANTHROPIC_MODEL")
    )


def _provider_has_codex_responses_adapter(env: dict[str, str], provider_id: str) -> bool:
    prefix = _provider_prefix(provider_id)
    env_key = env.get(f"{prefix}_CODEX_ENV_KEY") or f"{prefix}_CODEX_AUTH_TOKEN"
    return bool(
        env.get(f"{prefix}_CODEX_BASE_URL")
        and env.get(f"{prefix}_CODEX_MODEL")
        and env_key
        and env.get(env_key)
        and (env.get(f"{prefix}_CODEX_WIRE_API") or "responses").strip().lower() == "responses"
    )


def _provider_has_opencode_adapter(env: dict[str, str], provider_id: str) -> bool:
    prefix = _provider_prefix(provider_id)
    env_key = env.get(f"{prefix}_OPENCODE_ENV_KEY") or f"{prefix}_OPENCODE_AUTH_TOKEN"
    return bool(
        env.get(f"{prefix}_OPENCODE_BASE_URL")
        and env.get(f"{prefix}_OPENCODE_MODEL")
        and env_key
        and env.get(env_key)
    )


def _provider_codex_adapter_kind(env: dict[str, str], provider_id: str) -> str:
    prefix = _provider_prefix(provider_id)
    relay = (env.get(f"{prefix}_CODEX_RELAY") or "").strip().lower().replace("_", "-")
    upstream_wire_api = (env.get(f"{prefix}_CODEX_UPSTREAM_WIRE_API") or "").strip().lower().replace("_", "-")
    if relay or upstream_wire_api in {"chat-completions", "openai-chat-completions"}:
        return "openai-chat-completions-relay"
    return "openai-responses"


def _provider_allows_agent(env: dict[str, str], provider_id: str, agent_id: str) -> bool:
    prefix = _provider_prefix(provider_id)
    raw = env.get(f"{prefix}_SUPPORTED_AGENTS", "")
    if raw:
        allowed = {
            str(item or "").strip().lower().replace("_", "-")
            for item in raw.split(",")
            if str(item or "").strip()
        }
        return str(agent_id or "").strip().lower().replace("_", "-") in allowed
    return True


def _builtin_supported_agents(existing: dict[str, str], prefix: str) -> str:
    raw = existing.get(f"{prefix}_SUPPORTED_AGENTS", "").strip()
    if not raw:
        return "claude,codex,opencode"
    agents = [
        item.strip().lower().replace("_", "-")
        for item in raw.split(",")
        if item.strip()
    ]
    if set(agents) == {"claude", "codex"}:
        return "claude,codex,opencode"
    return ",".join(agents)


def _default_adapter_kind(agent_id: str) -> str:
    normalized = str(agent_id or "").strip().lower().replace("_", "-")
    if normalized == "claude":
        return "anthropic"
    if normalized == "opencode":
        return "opencode"
    if normalized == "codex":
        return "openai-responses"
    return normalized or "unknown"


def _ai_provider_capabilities_from_env(
    env: dict[str, str],
    *,
    provider_filter: list[str] | None = None,
    agent_filter: list[str] | None = None,
) -> list[dict[str, object]]:
    allowed_providers = {
        _normalize_provider_id(item)
        for item in (provider_filter or [])
        if str(item or "").strip()
    }
    allowed_agents = {
        str(item or "").strip().lower().replace("_", "-")
        for item in (agent_filter or [])
        if str(item or "").strip()
    }
    capabilities: list[dict[str, object]] = []
    for provider_id in _ai_provider_ids_from_env(env):
        if allowed_providers and provider_id not in allowed_providers:
            continue
        if (
            _provider_has_anthropic_adapter(env, provider_id)
            and _provider_allows_agent(env, provider_id, "claude")
            and (not allowed_agents or "claude" in allowed_agents)
        ):
            capabilities.append(
                {
                    "provider_id": provider_id,
                    "agent_id": "claude",
                    "adapter_kind": "anthropic",
                    "status": "configured",
                    "enabled": True,
                }
            )
        if (
            _provider_has_codex_responses_adapter(env, provider_id)
            and _provider_allows_agent(env, provider_id, "codex")
            and (not allowed_agents or "codex" in allowed_agents)
        ):
            capabilities.append(
                {
                    "provider_id": provider_id,
                    "agent_id": "codex",
                    "adapter_kind": _provider_codex_adapter_kind(env, provider_id),
                    "status": "configured",
                    "enabled": True,
                }
            )
        if (
            _provider_has_opencode_adapter(env, provider_id)
            and _provider_allows_agent(env, provider_id, "opencode")
            and (not allowed_agents or "opencode" in allowed_agents)
        ):
            capabilities.append(
                {
                    "provider_id": provider_id,
                    "agent_id": "opencode",
                    "adapter_kind": "opencode",
                    "status": "configured",
                    "enabled": True,
                }
            )
    return capabilities


def _ai_providers_configured(path: Path | None = None) -> bool:
    env = _parse_env(path or _secret_path("ai-providers"))
    return bool(_ai_provider_capabilities_from_env(env))


def _default_agent_from_provider_env(env: dict[str, str], provider_id: str) -> str:
    if _provider_has_anthropic_adapter(env, provider_id):
        return "claude"
    if _provider_has_codex_responses_adapter(env, provider_id):
        return "codex"
    if _provider_has_opencode_adapter(env, provider_id):
        return "opencode"
    return "claude"


def _base_provider_env(
    *,
    prefix: str,
    name: str,
    description: str,
    base_url: str,
    token: str,
    model: str,
    effort: str = "max",
    visible: str = "1",
) -> dict[str, str]:
    return {
        f"{prefix}_PROVIDER_NAME": name,
        f"{prefix}_PROVIDER_DESCRIPTION": description,
        f"{prefix}_PROVIDER_VISIBLE": visible,
        f"{prefix}_ANTHROPIC_BASE_URL": base_url,
        f"{prefix}_ANTHROPIC_AUTH_TOKEN": token,
        f"{prefix}_ANTHROPIC_MODEL": model,
        f"{prefix}_ANTHROPIC_DEFAULT_OPUS_MODEL": model,
        f"{prefix}_ANTHROPIC_DEFAULT_SONNET_MODEL": model,
        f"{prefix}_ANTHROPIC_DEFAULT_HAIKU_MODEL": model,
        f"{prefix}_CLAUDE_CODE_SUBAGENT_MODEL": model,
        f"{prefix}_CLAUDE_CODE_EFFORT_LEVEL": effort,
    }


def _prompt_deepseek_provider(existing: dict[str, str]) -> tuple[str, dict[str, str]]:
    provider_id = "deepseek"
    prefix = _provider_prefix(provider_id)
    model = _prompt_line(f"{provider_id} model", default=existing.get(f"{prefix}_ANTHROPIC_MODEL", "deepseek-v4-pro[1m]"))
    base_url = _prompt_line(
        f"{provider_id} Anthropic base URL",
        default=existing.get(f"{prefix}_ANTHROPIC_BASE_URL", "https://api.deepseek.com/anthropic"),
    )
    token = _prompt_line(
        f"{provider_id} Anthropic auth token",
        default=existing.get(f"{prefix}_ANTHROPIC_AUTH_TOKEN", ""),
        required=True,
        secret=True,
    )
    data = _base_provider_env(
        prefix=prefix,
        name="DeepSeek V4 Pro",
        description="DeepSeek Anthropic-compatible Claude Code provider",
        base_url=base_url,
        token=token,
        model=model,
    )
    data[f"{prefix}_SUPPORTED_AGENTS"] = _builtin_supported_agents(existing, prefix)
    data.update(
        {
            f"{prefix}_CODEX_PROVIDER_NAME": existing.get(f"{prefix}_CODEX_PROVIDER_NAME", "DeepSeek"),
            f"{prefix}_CODEX_BASE_URL": existing.get(f"{prefix}_CODEX_BASE_URL", "https://api.deepseek.com/v1"),
            f"{prefix}_CODEX_MODEL": existing.get(f"{prefix}_CODEX_MODEL", "deepseek-v4-pro"),
            f"{prefix}_CODEX_ENV_KEY": existing.get(f"{prefix}_CODEX_ENV_KEY", f"{prefix}_ANTHROPIC_AUTH_TOKEN"),
            f"{prefix}_CODEX_WIRE_API": existing.get(f"{prefix}_CODEX_WIRE_API", "responses"),
            f"{prefix}_CODEX_UPSTREAM_WIRE_API": existing.get(f"{prefix}_CODEX_UPSTREAM_WIRE_API", "chat-completions"),
            f"{prefix}_CODEX_RELAY": existing.get(f"{prefix}_CODEX_RELAY", "codex-relay"),
            f"{prefix}_CODEX_CONTEXT_WINDOW": existing.get(f"{prefix}_CODEX_CONTEXT_WINDOW", "262144"),
            f"{prefix}_OPENCODE_PROVIDER_NAME": existing.get(f"{prefix}_OPENCODE_PROVIDER_NAME", "DeepSeek"),
            f"{prefix}_OPENCODE_BASE_URL": existing.get(f"{prefix}_OPENCODE_BASE_URL", "https://api.deepseek.com/v1"),
            f"{prefix}_OPENCODE_MODEL": existing.get(f"{prefix}_OPENCODE_MODEL", "deepseek-v4-pro"),
            f"{prefix}_OPENCODE_ENV_KEY": existing.get(f"{prefix}_OPENCODE_ENV_KEY", f"{prefix}_ANTHROPIC_AUTH_TOKEN"),
            f"{prefix}_OPENCODE_PROVIDER_NPM": existing.get(f"{prefix}_OPENCODE_PROVIDER_NPM", "@ai-sdk/openai-compatible"),
        }
    )
    data[f"{prefix}_AI_WORKER_MAX_CONCURRENCY"] = existing.get(f"{prefix}_AI_WORKER_MAX_CONCURRENCY", "20")
    data[f"{prefix}_AI_WORKER_QUEUE_MAX"] = existing.get(f"{prefix}_AI_WORKER_QUEUE_MAX", "100")
    return provider_id, data


def _prompt_minimax_provider(existing: dict[str, str]) -> tuple[str, dict[str, str]]:
    provider_id = "minimax"
    prefix = _provider_prefix(provider_id)
    model = _prompt_line(f"{provider_id} model", default=existing.get(f"{prefix}_ANTHROPIC_MODEL", "MiniMax-M3"))
    base_url = _prompt_line(
        f"{provider_id} Anthropic base URL",
        default=existing.get(f"{prefix}_ANTHROPIC_BASE_URL", "https://api.minimaxi.com/anthropic"),
    )
    token = _prompt_line(
        f"{provider_id} Anthropic auth token",
        default=existing.get(f"{prefix}_ANTHROPIC_AUTH_TOKEN", ""),
        required=True,
        secret=True,
    )
    data = _base_provider_env(
        prefix=prefix,
        name="MiniMax M3",
        description="MiniMax Anthropic-compatible and native Responses provider",
        base_url=base_url,
        token=token,
        model=model,
    )
    data.update(
        {
            f"{prefix}_SUPPORTED_AGENTS": _builtin_supported_agents(existing, prefix),
            f"{prefix}_AI_WORKER_MAX_CONCURRENCY": existing.get(f"{prefix}_AI_WORKER_MAX_CONCURRENCY", "5"),
            f"{prefix}_AI_WORKER_QUEUE_MAX": existing.get(f"{prefix}_AI_WORKER_QUEUE_MAX", "20"),
            f"{prefix}_CODEX_PROVIDER_NAME": existing.get(f"{prefix}_CODEX_PROVIDER_NAME", "MiniMax"),
            f"{prefix}_CODEX_BASE_URL": existing.get(f"{prefix}_CODEX_BASE_URL", "https://api.minimaxi.com/v1"),
            f"{prefix}_CODEX_MODEL": existing.get(f"{prefix}_CODEX_MODEL", model),
            f"{prefix}_CODEX_ENV_KEY": existing.get(f"{prefix}_CODEX_ENV_KEY", f"{prefix}_ANTHROPIC_AUTH_TOKEN"),
            f"{prefix}_CODEX_WIRE_API": existing.get(f"{prefix}_CODEX_WIRE_API", "responses"),
            f"{prefix}_CODEX_UPSTREAM_WIRE_API": existing.get(f"{prefix}_CODEX_UPSTREAM_WIRE_API", ""),
            f"{prefix}_CODEX_RELAY": existing.get(f"{prefix}_CODEX_RELAY", ""),
            f"{prefix}_CODEX_CONTEXT_WINDOW": existing.get(f"{prefix}_CODEX_CONTEXT_WINDOW", "512000"),
            f"{prefix}_OPENCODE_PROVIDER_NAME": existing.get(f"{prefix}_OPENCODE_PROVIDER_NAME", "MiniMax"),
            f"{prefix}_OPENCODE_BASE_URL": existing.get(f"{prefix}_OPENCODE_BASE_URL", "https://api.minimaxi.com/anthropic/v1"),
            f"{prefix}_OPENCODE_MODEL": existing.get(f"{prefix}_OPENCODE_MODEL", model),
            f"{prefix}_OPENCODE_ENV_KEY": existing.get(f"{prefix}_OPENCODE_ENV_KEY", f"{prefix}_ANTHROPIC_AUTH_TOKEN"),
            f"{prefix}_OPENCODE_PROVIDER_NPM": existing.get(f"{prefix}_OPENCODE_PROVIDER_NPM", "@ai-sdk/anthropic"),
        }
    )
    return provider_id, data


def _prompt_custom_provider(existing: dict[str, str]) -> tuple[str, dict[str, str]]:
    provider_id = _normalize_provider_id(_prompt_line("custom provider id", required=True))
    prefix = _provider_prefix(provider_id)
    data: dict[str, str] = {
        f"{prefix}_PROVIDER_NAME": _prompt_line(
            f"{provider_id} display name",
            default=existing.get(f"{prefix}_PROVIDER_NAME", provider_id),
        ),
        f"{prefix}_PROVIDER_DESCRIPTION": _prompt_line(
            f"{provider_id} description",
            default=existing.get(f"{prefix}_PROVIDER_DESCRIPTION", "Custom AI provider"),
        ),
        f"{prefix}_PROVIDER_VISIBLE": existing.get(f"{prefix}_PROVIDER_VISIBLE", "1"),
    }
    add_claude = _prompt_bool(
        f"Add Claude Code via Anthropic-compatible API for {provider_id}?",
        default=bool(existing.get(f"{prefix}_ANTHROPIC_MODEL")),
    )
    model = existing.get(f"{prefix}_ANTHROPIC_MODEL", "")
    if add_claude:
        model = _prompt_line(f"{provider_id} ANTHROPIC_MODEL", default=model, required=True)
        base_url = _prompt_line(
            f"{provider_id} ANTHROPIC_BASE_URL",
            default=existing.get(f"{prefix}_ANTHROPIC_BASE_URL", ""),
            required=True,
        )
        token = _prompt_line(
            f"{provider_id} ANTHROPIC_AUTH_TOKEN",
            default=existing.get(f"{prefix}_ANTHROPIC_AUTH_TOKEN", ""),
            required=True,
            secret=True,
        )
        data.update(
            _base_provider_env(
                prefix=prefix,
                name=data[f"{prefix}_PROVIDER_NAME"],
                description=data[f"{prefix}_PROVIDER_DESCRIPTION"],
                base_url=base_url,
                token=token,
                model=model,
                effort=_prompt_line(
                    f"{provider_id} CLAUDE_CODE_EFFORT_LEVEL",
                    default=existing.get(f"{prefix}_CLAUDE_CODE_EFFORT_LEVEL", "max"),
                ),
            )
        )
        data[f"{prefix}_ANTHROPIC_DEFAULT_OPUS_MODEL"] = _prompt_line(
            f"{provider_id} ANTHROPIC_DEFAULT_OPUS_MODEL",
            default=existing.get(f"{prefix}_ANTHROPIC_DEFAULT_OPUS_MODEL", model),
            required=True,
        )
        data[f"{prefix}_ANTHROPIC_DEFAULT_SONNET_MODEL"] = _prompt_line(
            f"{provider_id} ANTHROPIC_DEFAULT_SONNET_MODEL",
            default=existing.get(f"{prefix}_ANTHROPIC_DEFAULT_SONNET_MODEL", model),
            required=True,
        )
        data[f"{prefix}_ANTHROPIC_DEFAULT_HAIKU_MODEL"] = _prompt_line(
            f"{provider_id} ANTHROPIC_DEFAULT_HAIKU_MODEL",
            default=existing.get(f"{prefix}_ANTHROPIC_DEFAULT_HAIKU_MODEL", model),
            required=True,
        )
        data[f"{prefix}_CLAUDE_CODE_SUBAGENT_MODEL"] = _prompt_line(
            f"{provider_id} CLAUDE_CODE_SUBAGENT_MODEL",
            default=existing.get(f"{prefix}_CLAUDE_CODE_SUBAGENT_MODEL", model),
            required=True,
        )
    data[f"{prefix}_AI_WORKER_MAX_CONCURRENCY"] = _prompt_line(
        f"{provider_id} worker max concurrency",
        default=existing.get(f"{prefix}_AI_WORKER_MAX_CONCURRENCY", "3"),
    )
    data[f"{prefix}_AI_WORKER_QUEUE_MAX"] = _prompt_line(
        f"{provider_id} worker queue max",
        default=existing.get(f"{prefix}_AI_WORKER_QUEUE_MAX", "50"),
    )
    if _prompt_bool(
        f"Add Codex via OpenAI Responses API for {provider_id}?",
        default=bool(existing.get(f"{prefix}_CODEX_MODEL")),
    ):
        data[f"{prefix}_CODEX_PROVIDER_NAME"] = _prompt_line(
            f"{provider_id} CODEX provider name",
            default=existing.get(f"{prefix}_CODEX_PROVIDER_NAME", provider_id),
        )
        data[f"{prefix}_CODEX_BASE_URL"] = _prompt_line(
            f"{provider_id} CODEX base URL",
            default=existing.get(f"{prefix}_CODEX_BASE_URL", ""),
            required=True,
        )
        data[f"{prefix}_CODEX_MODEL"] = _prompt_line(
            f"{provider_id} CODEX model",
            default=existing.get(f"{prefix}_CODEX_MODEL", model),
            required=True,
        )
        data[f"{prefix}_CODEX_ENV_KEY"] = _prompt_line(
            f"{provider_id} CODEX token env key",
            default=existing.get(f"{prefix}_CODEX_ENV_KEY", f"{prefix}_CODEX_AUTH_TOKEN"),
        )
        code_token_key = data[f"{prefix}_CODEX_ENV_KEY"]
        data[code_token_key] = _prompt_line(
            f"{provider_id} CODEX auth token",
            default=existing.get(code_token_key, ""),
            required=True,
            secret=True,
        )
        data[f"{prefix}_CODEX_WIRE_API"] = _prompt_line(
            f"{provider_id} CODEX wire api",
            default=existing.get(f"{prefix}_CODEX_WIRE_API", "responses"),
        )
        data[f"{prefix}_CODEX_CONTEXT_WINDOW"] = _prompt_line(
            f"{provider_id} CODEX context window",
            default=existing.get(f"{prefix}_CODEX_CONTEXT_WINDOW", "200000"),
        )
        use_relay = _prompt_bool(
            f"Use codex-relay to convert Codex Responses to upstream chat/completions for {provider_id}?",
            default=bool(existing.get(f"{prefix}_CODEX_RELAY")),
        )
        if use_relay:
            data[f"{prefix}_CODEX_RELAY"] = _prompt_line(
                f"{provider_id} CODEX relay",
                default=existing.get(f"{prefix}_CODEX_RELAY", "codex-relay"),
            )
            data[f"{prefix}_CODEX_UPSTREAM_WIRE_API"] = _prompt_line(
                f"{provider_id} CODEX upstream wire api",
                default=existing.get(f"{prefix}_CODEX_UPSTREAM_WIRE_API", "chat-completions"),
            )
    if _prompt_bool(
        f"Add OpenCode via OpenCode provider adapter for {provider_id}?",
        default=bool(existing.get(f"{prefix}_OPENCODE_MODEL")),
    ):
        data[f"{prefix}_OPENCODE_PROVIDER_NAME"] = _prompt_line(
            f"{provider_id} OPENCODE provider name",
            default=existing.get(f"{prefix}_OPENCODE_PROVIDER_NAME", existing.get(f"{prefix}_CODEX_PROVIDER_NAME", provider_id)),
        )
        data[f"{prefix}_OPENCODE_BASE_URL"] = _prompt_line(
            f"{provider_id} OPENCODE base URL",
            default=existing.get(f"{prefix}_OPENCODE_BASE_URL", existing.get(f"{prefix}_CODEX_BASE_URL", "")),
            required=True,
        )
        data[f"{prefix}_OPENCODE_MODEL"] = _prompt_line(
            f"{provider_id} OPENCODE model",
            default=existing.get(f"{prefix}_OPENCODE_MODEL", existing.get(f"{prefix}_CODEX_MODEL", model)),
            required=True,
        )
        data[f"{prefix}_OPENCODE_ENV_KEY"] = _prompt_line(
            f"{provider_id} OPENCODE token env key",
            default=existing.get(f"{prefix}_OPENCODE_ENV_KEY", existing.get(f"{prefix}_CODEX_ENV_KEY", f"{prefix}_OPENCODE_AUTH_TOKEN")),
        )
        opencode_token_key = data[f"{prefix}_OPENCODE_ENV_KEY"]
        data[opencode_token_key] = _prompt_line(
            f"{provider_id} OPENCODE auth token",
            default=existing.get(opencode_token_key, ""),
            required=True,
            secret=True,
        )
        data[f"{prefix}_OPENCODE_PROVIDER_NPM"] = _prompt_line(
            f"{provider_id} OPENCODE provider npm package",
            default=existing.get(f"{prefix}_OPENCODE_PROVIDER_NPM", "@ai-sdk/openai-compatible"),
        )
    if not _ai_provider_capabilities_from_env({**existing, **data}, provider_filter=[provider_id]):
        print(f"{provider_id} has no configured adapter; add at least Claude, Codex, or OpenCode", file=sys.stderr)
        return _prompt_custom_provider(existing)
    ordered_agents = ["claude", "codex", "opencode"]
    caps = _ai_provider_capabilities_from_env({**existing, **data}, provider_filter=[provider_id])
    supported = [
        agent_id
        for agent_id in ordered_agents
        if any(cap.get("agent_id") == agent_id for cap in caps)
    ]
    data[f"{prefix}_SUPPORTED_AGENTS"] = ",".join(supported)
    return provider_id, data


def _setup_ai_providers(*, force: bool = False, path: Path | None = None, title: str = "AI provider setup") -> int:
    path = path or _secret_path("ai-providers")
    existing = _parse_env(path)
    if existing and not force and _ai_providers_configured(path):
        if _prompt_bool(f"AI providers are already configured at {path}. Keep current provider config?", default=True):
            print("kept existing AI provider config")
            return 0
    data = dict(existing) if not force else {}
    provider_ids: list[str] = []
    path.parent.mkdir(parents=True, exist_ok=True)
    print(title)
    print(f"provider env: {path}")
    while True:
        print("  1) deepseek")
        print("  2) minimax")
        print("  3) custom")
        choice = _prompt_line("select provider", default="1" if not provider_ids else "n")
        if choice.lower() in {"n", "next", "done", "q", "quit"} and provider_ids:
            break
        if choice == "1" or choice.lower() == "deepseek":
            provider_id, values = _prompt_deepseek_provider(existing)
        elif choice == "2" or choice.lower() == "minimax":
            provider_id, values = _prompt_minimax_provider(existing)
        elif choice == "3" or choice.lower() in {"custom", "other"}:
            provider_id, values = _prompt_custom_provider(existing)
        else:
            print("unknown provider choice", file=sys.stderr)
            continue
        data.update(values)
        if provider_id not in provider_ids:
            provider_ids.append(provider_id)
        if not _prompt_bool("add another provider?", default=False):
            break
    if not provider_ids:
        print("no AI provider configured", file=sys.stderr)
        return 1
    data["AI_PROVIDER_IDS"] = ",".join(provider_ids)
    default_provider = _prompt_line("default provider", default=provider_ids[0])
    data["AI_DEFAULT_PROVIDER"] = default_provider if default_provider in provider_ids else provider_ids[0]
    data["AI_DEFAULT_AGENT"] = _prompt_line(
        "default agent",
        default=_default_agent_from_provider_env(data, data["AI_DEFAULT_PROVIDER"]),
    )
    _write_env(path, data)
    print(f"updated AI providers: {', '.join(provider_ids)}")
    return 0


def _setup_apns_push(existing: dict[str, str], data: dict[str, str]) -> None:
    key_id = _prompt_line("APNs Key ID", default=existing.get("APNS_KEY_ID", ""), required=True)
    team_id = _prompt_line("APNs Team ID", default=existing.get("APNS_TEAM_ID", ""), required=True)
    bundle_id = _prompt_line("APNs Bundle ID", default=existing.get("APNS_BUNDLE_ID", ""), required=True)
    use_sandbox = _prompt_bool("APNs use sandbox by default?", default=_truthy_env(existing.get("APNS_USE_SANDBOX", "true")))
    current_path = existing.get("APNS_KEY_PATH", "")
    p8 = _prompt_multiline("APNs .p8 private key", default="" if not current_path else "__KEEP__", required=not bool(current_path))
    key_path = current_path
    if p8 and p8 != "__KEEP__":
        key_path = _write_secret_file(subdir="apns", filename=f"AuthKey_{key_id}.p8", content=p8)
    data.update(
        {
            "APNS_KEY_ID": key_id,
            "APNS_TEAM_ID": team_id,
            "APNS_BUNDLE_ID": bundle_id,
            "APNS_USE_SANDBOX": "true" if use_sandbox else "false",
        }
    )
    if key_path:
        data["APNS_KEY_PATH"] = key_path


def _setup_fcm_push(existing: dict[str, str], data: dict[str, str]) -> None:
    current_path = existing.get("FCM_SERVICE_ACCOUNT_PATH", "")
    raw_json = _prompt_multiline("FCM service account JSON", default="" if not current_path else "__KEEP__", required=not bool(current_path))
    service_account_path = current_path
    parsed: dict | None = None
    if raw_json and raw_json != "__KEEP__":
        try:
            parsed = json.loads(raw_json)
        except json.JSONDecodeError as exc:
            print(f"invalid FCM service account JSON: {exc}", file=sys.stderr)
            raise SystemExit(1)
        service_account_path = _write_secret_file(
            subdir="fcm",
            filename="service-account.json",
            content=json.dumps(parsed, indent=2, ensure_ascii=False),
        )
    default_project = existing.get("FCM_PROJECT_ID", "") or (str(parsed.get("project_id")) if parsed and parsed.get("project_id") else "")
    project_id = _prompt_line("FCM project id", default=default_project, required=True)
    data["FCM_PROJECT_ID"] = project_id
    if service_account_path:
        data["FCM_SERVICE_ACCOUNT_PATH"] = service_account_path


def _setup_getui_push(existing: dict[str, str], data: dict[str, str]) -> None:
    data["GETUI_BASE_URL"] = _prompt_line("GeTui base URL", default=existing.get("GETUI_BASE_URL", "https://restapi.getui.com/v2"))
    data["GETUI_APP_ID"] = _prompt_line("GeTui App ID", default=existing.get("GETUI_APP_ID", ""), required=True)
    data["GETUI_APP_KEY"] = _prompt_line("GeTui App Key", default=existing.get("GETUI_APP_KEY", ""), required=True, secret=True)
    app_secret = _prompt_line("GeTui App Secret (optional)", default=existing.get("GETUI_APP_SECRET", ""), secret=True)
    if app_secret:
        data["GETUI_APP_SECRET"] = app_secret
    data["GETUI_MASTER_SECRET"] = _prompt_line(
        "GeTui Master Secret",
        default=existing.get("GETUI_MASTER_SECRET", ""),
        required=True,
        secret=True,
    )
    data["GETUI_TTL_MS"] = _prompt_line("GeTui TTL ms", default=existing.get("GETUI_TTL_MS", "7200000"))


def _setup_push_providers(*, force: bool = False) -> int:
    path = _secret_path("push")
    existing = _parse_env(path)
    data = {} if force else dict(existing)
    print("Optional push setup. Skip a channel if it is not needed now.")
    if _prompt_bool("configure APNs?", default=bool(existing.get("APNS_KEY_PATH") and existing.get("APNS_KEY_ID"))):
        _setup_apns_push(existing, data)
    if _prompt_bool("configure FCM?", default=bool(existing.get("FCM_SERVICE_ACCOUNT_PATH") and existing.get("FCM_PROJECT_ID"))):
        _setup_fcm_push(existing, data)
    if _prompt_bool("configure GeTui?", default=bool(existing.get("GETUI_APP_ID") and existing.get("GETUI_MASTER_SECRET"))):
        _setup_getui_push(existing, data)
    if data:
        _write_env(path, data)
        print("updated optional push config")
    else:
        print("push config skipped")
    return 0


def _setup_asr_provider(*, force: bool = False) -> int:
    path = _secret_path("backend")
    existing = _parse_env(path)
    data = dict(existing)
    default_enabled = bool(existing.get("BYTEDANCE_ASR_APP_KEY") and existing.get("BYTEDANCE_ASR_ACCESS_KEY"))
    print("Optional speech recognition setup.")
    if not _prompt_bool("configure ByteDance ASR?", default=default_enabled):
        print("ASR config skipped")
        return 0
    data["BYTEDANCE_ASR_APP_KEY"] = _prompt_line(
        "ByteDance ASR App Key",
        default=existing.get("BYTEDANCE_ASR_APP_KEY", ""),
        required=True,
        secret=True,
    )
    data["BYTEDANCE_ASR_ACCESS_KEY"] = _prompt_line(
        "ByteDance ASR Access Key",
        default=existing.get("BYTEDANCE_ASR_ACCESS_KEY", ""),
        required=True,
        secret=True,
    )
    data["BYTEDANCE_ASR_RESOURCE_ID"] = _prompt_line(
        "ByteDance ASR Resource ID",
        default=existing.get("BYTEDANCE_ASR_RESOURCE_ID", "volc.bigasr.sauc.duration"),
    )
    data["BYTEDANCE_ASR_WS_URL"] = _prompt_line(
        "ByteDance ASR WebSocket URL",
        default=existing.get("BYTEDANCE_ASR_WS_URL", "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"),
    )
    _write_env(path, data)
    print("updated optional ASR config")
    return 0


def _smtp_already_configured(existing: dict[str, str]) -> bool:
    host = existing.get("SMTP_HOST", "").strip().lower()
    return bool(host and host != "localhost" and existing.get("SMTP_ADMIN_EMAIL"))


def _prompt_port(prompt: str, *, default: str) -> str:
    while True:
        value = _prompt_line(prompt, default=default, required=True)
        try:
            port = int(value)
        except ValueError:
            print("port must be a number", file=sys.stderr)
            continue
        if 1 <= port <= 65535:
            return str(port)
        print("port must be between 1 and 65535", file=sys.stderr)


def _setup_email_provider(*, force: bool = False) -> int:
    path = _secret_path("supabase")
    existing = _parse_env(path)
    data = dict(existing)
    default_enabled = _smtp_already_configured(existing)
    print(_t("optional_email_title"))
    if not _prompt_bool(_t("configure_smtp_prompt"), default=default_enabled):
        print(_t("smtp_config_skipped"))
        return 0
    data["ENABLE_EMAIL_SIGNUP"] = "true" if _prompt_bool(
        _t("enable_email_signup_prompt"),
        default=_truthy_env(existing.get("ENABLE_EMAIL_SIGNUP", "true")),
    ) else "false"
    autoconfirm_default = _truthy_env(existing.get("ENABLE_EMAIL_AUTOCONFIRM", "false")) if default_enabled else False
    data["ENABLE_EMAIL_AUTOCONFIRM"] = "true" if _prompt_bool(
        _t("email_autoconfirm_prompt"),
        default=autoconfirm_default,
    ) else "false"
    data["SMTP_ADMIN_EMAIL"] = _prompt_line(
        _t("smtp_admin_email_prompt"),
        default=existing.get("SMTP_ADMIN_EMAIL", "noreply@example.local"),
        required=True,
    )
    data["SMTP_HOST"] = _prompt_line(
        _t("smtp_host_prompt"),
        default="" if existing.get("SMTP_HOST") == "localhost" else existing.get("SMTP_HOST", ""),
        required=True,
    )
    data["SMTP_PORT"] = _prompt_port(
        _t("smtp_port_prompt"),
        default=existing.get("SMTP_PORT", "587"),
    )
    data["SMTP_USER"] = _prompt_line(
        _t("smtp_user_prompt"),
        default=existing.get("SMTP_USER", ""),
    )
    data["SMTP_PASS"] = _prompt_line(
        _t("smtp_pass_prompt"),
        default=existing.get("SMTP_PASS", ""),
        secret=True,
    )
    data["SMTP_SENDER_NAME"] = _prompt_line(
        _t("smtp_sender_name_prompt"),
        default=existing.get("SMTP_SENDER_NAME", "myapp"),
    )
    data.setdefault("MAILER_URLPATHS_CONFIRMATION", "/auth/v1/verify")
    data.setdefault("MAILER_URLPATHS_EMAIL_CHANGE", "/auth/v1/verify")
    data.setdefault("MAILER_URLPATHS_INVITE", "/auth/v1/verify")
    data.setdefault("MAILER_URLPATHS_RECOVERY", "/auth/v1/verify")
    _write_env(path, data)
    print(_t("smtp_config_updated"))
    return 0


def _run_setup_wizard(
    *,
    host: str | None = None,
    force: bool = False,
    include_ai: bool = True,
    include_asr: bool = True,
    include_email: bool = True,
    include_push: bool = True,
) -> int:
    rc = _init_stack_secrets(host=host, force=False, quiet=True)
    if rc != 0:
        return rc
    if include_ai:
        rc = _setup_ai_providers(force=force)
        if rc != 0:
            return rc
    if include_asr:
        rc = _setup_asr_provider(force=force)
        if rc != 0:
            return rc
    if include_email:
        rc = _setup_email_provider(force=force)
        if rc != 0:
            return rc
    if include_push:
        rc = _setup_push_providers(force=force)
        if rc != 0:
            return rc
    return 0


def _deploy_requires_ai_config(names: list[str]) -> bool:
    if any(name in {"backend", "ai-worker"} for name in names):
        return True
    if "agent-node" not in names:
        return False
    mode = (
        _parse_env(_secret_path("agent"))
        .get("AGENT_NODE_PROVIDER_MODE", "master")
        .strip()
        .lower()
        .replace("_", "-")
    )
    return mode in {"local", "node", "self", "agent-local"}


def _deploy_can_seed_test_user(names: list[str]) -> bool:
    return "supabase-auth" in names


def _ensure_human_config_for_deploy(args, names: list[str]) -> int:
    if args.dry_run:
        return 0
    rc = _init_stack_secrets(host=getattr(args, "host", None), quiet=True)
    if rc != 0:
        return rc
    if not _deploy_requires_ai_config(names) or _ai_providers_configured():
        return 0
    if getattr(args, "no_setup", False):
        print("AI provider config is missing; run: myapp-ctl setup", file=sys.stderr)
        return 1
    if not sys.stdin.isatty():
        print("AI provider config is missing and stdin is not interactive; run: myapp-ctl setup", file=sys.stderr)
        return 1
    print("AI provider config is missing; starting first-run setup.")
    return _run_setup_wizard(host=getattr(args, "host", None), include_ai=True, include_push=True)


def _prompt_secret(prompt: str) -> str:
    label = f"{prompt}: "
    if sys.stdin.isatty():
        return getpass.getpass(label).strip()
    return input(label).strip()


def _prompt_password_twice(prompt: str, confirm_prompt: str, *, min_len: int = 6) -> str:
    while True:
        password = _prompt_secret(prompt)
        if len(password) < min_len:
            print(_t("password_too_short", min_len=min_len), file=sys.stderr)
            continue
        confirm = _prompt_secret(confirm_prompt)
        if password != confirm:
            print(_t("password_mismatch"), file=sys.stderr)
            continue
        return password


def _supabase_admin_base_url(supabase_env: dict[str, str]) -> str:
    port = supabase_env.get("KONG_HTTP_PORT") or "18000"
    return f"http://127.0.0.1:{port}".rstrip("/")


def _supabase_admin_request(
    *,
    method: str,
    base_url: str,
    service_key: str,
    path: str,
    body: dict | None = None,
    timeout: float = 15.0,
) -> tuple[int, dict | list | None, str]:
    raw: bytes | None = None
    if body is not None:
        raw = json.dumps(body).encode("utf-8")
    req = Request(
        base_url.rstrip("/") + path,
        data=raw,
        method=method,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {service_key}",
            "apikey": service_key,
        },
    )
    try:
        with urlopen(req, timeout=timeout) as resp:
            text = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(text) if text.strip() else None, text
    except HTTPError as exc:
        text = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(text) if text.strip() else None
        except json.JSONDecodeError:
            parsed = None
        return exc.code, parsed, text


def _wait_supabase_auth(base_url: str, *, api_key: str = "", timeout_s: float = 90.0) -> bool:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            headers = {"User-Agent": "myapp-ctl/1"}
            if api_key:
                headers["apikey"] = api_key
                headers["Authorization"] = f"Bearer {api_key}"
            req = Request(base_url.rstrip("/") + "/auth/v1/health", headers=headers)
            with urlopen(req, timeout=3) as resp:
                if 200 <= resp.status < 500:
                    return True
        except HTTPError as exc:
            if 400 <= exc.code < 500:
                return True
        except (URLError, OSError):
            pass
        time.sleep(2)
    return False


def _find_supabase_user_by_email(base_url: str, service_key: str, email: str) -> dict | None:
    wanted = email.strip().lower()
    page = 1
    while page <= 20:
        status, data, text = _supabase_admin_request(
            method="GET",
            base_url=base_url,
            service_key=service_key,
            path=f"/auth/v1/admin/users?page={page}&per_page=1000",
            timeout=20,
        )
        if status >= 400:
            raise RuntimeError(f"list users HTTP {status}: {text[:300]}")
        users = data.get("users", []) if isinstance(data, dict) else []
        for user in users:
            if str(user.get("email") or "").strip().lower() == wanted:
                return user
        if len(users) < 1000:
            return None
        page += 1
    return None


def _create_or_update_supabase_test_user(*, email: str, username: str, password: str) -> tuple[str, dict]:
    supabase_env = _parse_env(_secret_path("supabase"))
    service_key = supabase_env.get("SERVICE_ROLE_KEY")
    if not service_key:
        raise RuntimeError(_t("test_user_missing_supabase"))
    base_url = _supabase_admin_base_url(supabase_env)
    _wait_supabase_auth(base_url, api_key=service_key)
    existing = _find_supabase_user_by_email(base_url, service_key, email)
    if existing:
        user_metadata = dict(existing.get("user_metadata") or {})
        user_metadata["username"] = username
        app_metadata = dict(existing.get("app_metadata") or {})
        app_metadata.setdefault("role", "user")
        status, data, text = _supabase_admin_request(
            method="PUT",
            base_url=base_url,
            service_key=service_key,
            path=f"/auth/v1/admin/users/{existing.get('id')}",
            body={
                "password": password,
                "email_confirm": True,
                "user_metadata": user_metadata,
                "app_metadata": app_metadata,
            },
        )
        if status >= 400:
            raise RuntimeError(f"update user HTTP {status}: {text[:300]}")
        return "updated", data if isinstance(data, dict) else {}
    status, data, text = _supabase_admin_request(
        method="POST",
        base_url=base_url,
        service_key=service_key,
        path="/auth/v1/admin/users",
        body={
            "email": email,
            "password": password,
            "email_confirm": True,
            "user_metadata": {"username": username},
            "app_metadata": {"role": "user"},
        },
    )
    if status >= 400:
        raise RuntimeError(f"create user HTTP {status}: {text[:300]}")
    return "created", data if isinstance(data, dict) else {}


def _maybe_seed_test_user(args) -> int:
    password = ""
    password_file = getattr(args, "test_user_password_file", "") or ""
    password_env = getattr(args, "test_user_password_env", "") or ""
    if password_file:
        try:
            password = Path(password_file).expanduser().read_text(encoding="utf-8").strip()
        except OSError as exc:
            print(f"test user password file read failed: {exc}", file=sys.stderr)
            return 1
    if not password and password_env:
        password = os.environ.get(password_env, "").strip()
    if not sys.stdin.isatty() and not password:
        print(_t("test_user_skipped_noninteractive"))
        return 0
    email = getattr(args, "test_user_email", None) or "test@example.com"
    username = getattr(args, "test_user_username", None) or "test"
    if sys.stdin.isatty() and not _prompt_bool(_t("create_test_user_prompt"), default=True):
        print(_t("test_user_skipped"))
        return 0
    if not password:
        password = _prompt_password_twice(
            _t("test_user_password_prompt"),
            _t("test_user_password_confirm_prompt"),
            min_len=6,
        )
    if len(password) < 6:
        print(_t("password_too_short", min_len=6), file=sys.stderr)
        return 1
    try:
        action, _ = _create_or_update_supabase_test_user(email=email, username=username, password=password)
    except Exception as exc:
        print(f"test user setup failed: {exc}", file=sys.stderr)
        return 1
    if action == "created":
        print(_t("test_user_created", email=email))
    else:
        print(_t("test_user_updated", email=email))
    return 0


def _rand_hex(bytes_len: int) -> str:
    return py_secrets.token_hex(bytes_len)


def _rand_token(length: int = 32) -> str:
    token = py_secrets.token_urlsafe(length)
    return token.replace("-", "").replace("_", "")[:length]


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _mint_supabase_jwt(secret: str, role: str) -> str:
    now = int(time.time())
    payload = {
        "role": role,
        "iss": "supabase",
        "iat": now,
        "exp": now + 5 * 365 * 24 * 3600,
    }
    header_b64 = _b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload_b64 = _b64url(json.dumps(payload, separators=(",", ":")).encode())
    signing_input = f"{header_b64}.{payload_b64}".encode()
    sig = hmac.new(secret.encode(), signing_input, hashlib.sha256).digest()
    return f"{header_b64}.{payload_b64}.{_b64url(sig)}"


def _public_host(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    cfg = _cfg()
    node_ip = cfg.get("node", {}).get("public_ip")
    if node_ip:
        return str(node_ip)
    backend = str(cfg.get("domains", {}).get("backend") or "")
    parsed = urlparse(backend)
    if parsed.hostname:
        return parsed.hostname
    return "127.0.0.1"


def _agent_node_default_display_host(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    backend_public_host = _parse_env(_secret_path("backend")).get("PUBLIC_HOST", "").strip()
    if backend_public_host and backend_public_host not in {"127.0.0.1", "localhost"}:
        return backend_public_host
    return _public_host(None)


def _is_replaceable_default_url(value: object, *, previous_host: str = "") -> bool:
    text = str(value or "").strip()
    if not text:
        return True
    parsed = urlparse(text)
    hostname = (parsed.hostname or "").lower()
    if hostname in {"127.0.0.1", "localhost"}:
        return True
    return bool(previous_host and hostname == previous_host.lower())


def _persist_public_host_if_explicit(host: str | None, public_host: str) -> None:
    if not host:
        return
    cfg = _cfg()
    node = cfg.setdefault("node", {})
    previous_host = str(node.get("public_ip") or "").strip()
    node["public_ip"] = public_host
    domains = cfg.setdefault("domains", {})
    default_domains = {
        "backend": f"http://{public_host}:5566",
        "registry": f"http://{public_host}:3254",
        "oss": f"http://{public_host}:9000",
        "config_center": f"http://{public_host}:5000",
    }
    for key, value in default_domains.items():
        if _is_replaceable_default_url(domains.get(key), previous_host=previous_host):
            domains[key] = value
    domains.setdefault("agent_node", "http://agent-node:5590")
    _save_json(CONFIG_PATH, cfg, mode=0o644)


def _merge_env_group(group: str, values: dict[str, str], *, force: bool = False) -> list[str]:
    path = _secret_path(group)
    data = _parse_env(path)
    changed: list[str] = []
    for key, value in values.items():
        if force or not data.get(key):
            data[key] = value
            changed.append(key)
    if changed:
        _write_env(path, data)
    return changed


def _init_stack_secrets(*, host: str | None = None, force: bool = False, quiet: bool = False) -> int:
    public_host = _public_host(host)
    _persist_public_host_if_explicit(host, public_host)
    data_root = _ensure_data_root_layout(_data_root_from_cfg())
    secret_dir = _secret_dir()
    secret_dir.mkdir(parents=True, exist_ok=True)

    existing_backend = _parse_env(_secret_path("backend"))
    existing_supabase = _parse_env(_secret_path("supabase"))
    existing_openim = _parse_env(_secret_path("openim"))

    jwt_secret = existing_supabase.get("JWT_SECRET") if not force else ""
    jwt_secret = jwt_secret or _rand_hex(32)
    anon_key = existing_supabase.get("ANON_KEY") if not force else ""
    service_role_key = existing_supabase.get("SERVICE_ROLE_KEY") if not force else ""
    anon_key = anon_key or _mint_supabase_jwt(jwt_secret, "anon")
    service_role_key = service_role_key or _mint_supabase_jwt(jwt_secret, "service_role")

    openim_secret = existing_openim.get("OPENIM_SECRET") if not force else ""
    openim_secret = openim_secret or _rand_hex(32)
    openim_webhook_secret = existing_backend.get("OPENIM_WEBHOOK_SECRET") if not force else ""
    openim_webhook_secret = openim_webhook_secret or existing_openim.get("OPENIM_WEBHOOK_SECRET", "")
    openim_webhook_secret = openim_webhook_secret or _rand_hex(32)

    backend_defaults = {
        "MYAPP_BACKEND_IMAGE": _configured_image("backend"),
        "MYAPP_AGENT_NODE_IMAGE": _configured_image("agent-node"),
        "MYAPP_AGENT_RUNTIME_IMAGE": _configured_image("agent-runtime"),
        "MYAPP_DATA_ROOT": str(data_root),
        "PUBLIC_HOST": public_host,
        "BACKEND_PORT": "5566",
        "REGISTRY_PORT": "3254",
        "CONFIG_CENTER_PORT": "5000",
        "USER_CENTER_PORT": "5567",
        "JSONAPP_DB_USER": "jsonapp",
        "JSONAPP_DB_NAME": "jsonapp",
        "JSONAPP_DB_PASSWORD": _rand_token(32),
        "BACKEND_REDIS_PASSWORD": _rand_token(32),
        "APP_MINIO_ACCESS_KEY": "app" + _rand_hex(8),
        "APP_MINIO_SECRET_KEY": _rand_token(40),
        "APP_MINIO_PORT": "9000",
        "APP_MINIO_CONSOLE_PORT": "9090",
        "SUPABASE_URL": f"http://{public_host}:18000",
        "SUPABASE_ANON_KEY": anon_key,
        "SUPABASE_SERVICE_KEY": service_role_key,
        "OPENIM_API_URL": f"http://{public_host}:10002",
        "OPENIM_WS_URL": f"ws://{public_host}:10001",
        "OPENIM_SECRET": openim_secret,
        "OPENIM_WEBHOOK_SECRET": openim_webhook_secret,
        "FLASK_SECRET_KEY": _rand_hex(32),
        "REGISTRY_ADMIN_TOKEN": _rand_hex(32),
        "REGISTRY_ADMIN_AUTHOR_EMAIL": "2501808198@qq.com",
        "REGISTRY_ADMIN_AUTHOR_NAME": "fish",
        "REGISTRY_ADMIN_AUTHOR_ID": "2501808198@qq.com",
        "AI_WORKER_MAX_CONCURRENCY": "20",
        "AI_WORKER_QUEUE_MAX": "100",
        "DEEPSEEK_AI_WORKER_MAX_CONCURRENCY": "20",
        "DEEPSEEK_AI_WORKER_QUEUE_MAX": "100",
        "MINIMAX_AI_WORKER_MAX_CONCURRENCY": "5",
        "MINIMAX_AI_WORKER_QUEUE_MAX": "20",
    }
    supabase_defaults = {
        "MYAPP_DATA_ROOT": str(data_root),
        "HOST_IP": public_host,
        "POSTGRES_PASSWORD": _rand_token(32),
        "JWT_SECRET": jwt_secret,
        "ANON_KEY": anon_key,
        "SERVICE_ROLE_KEY": service_role_key,
        "SUPABASE_PUBLISHABLE_KEY": anon_key,
        "SUPABASE_SECRET_KEY": service_role_key,
        "DASHBOARD_USERNAME": "admin",
        "DASHBOARD_PASSWORD": _rand_token(24),
        "SECRET_KEY_BASE": _rand_hex(32),
        "VAULT_ENC_KEY": _rand_hex(16),
        "PG_META_CRYPTO_KEY": _rand_hex(32),
        "LOGFLARE_PUBLIC_ACCESS_TOKEN": _rand_hex(24),
        "LOGFLARE_PRIVATE_ACCESS_TOKEN": _rand_hex(24),
        "ANON_KEY_ASYMMETRIC": "",
        "SERVICE_ROLE_KEY_ASYMMETRIC": "",
        "JWT_KEYS": "[]",
        "JWT_JWKS": "{\"keys\":[]}",
        "POSTGRES_HOST": "db",
        "POSTGRES_DB": "postgres",
        "POSTGRES_PORT": "15432",
        "POOLER_TENANT_ID": "myapp" + _rand_hex(4),
        "POOLER_PROXY_PORT_TRANSACTION": "6543",
        "POOLER_DEFAULT_POOL_SIZE": "20",
        "POOLER_MAX_CLIENT_CONN": "100",
        "POOLER_DB_POOL_SIZE": "5",
        "KONG_HTTP_PORT": "18000",
        "KONG_HTTPS_PORT": "18443",
        "API_EXTERNAL_URL": f"http://{public_host}:18000",
        "SUPABASE_PUBLIC_URL": f"http://{public_host}:18000",
        "SITE_URL": f"http://{public_host}:18000",
        "SAML_EXTERNAL_URL": "",
        "ADDITIONAL_REDIRECT_URLS": "",
        "DISABLE_SIGNUP": "false",
        "ENABLE_EMAIL_SIGNUP": "true",
        "ENABLE_EMAIL_AUTOCONFIRM": "true",
        "ENABLE_PHONE_SIGNUP": "false",
        "ENABLE_PHONE_AUTOCONFIRM": "false",
        "ENABLE_ANONYMOUS_USERS": "false",
        "JWT_EXPIRY": "3600",
        "MAILER_URLPATHS_CONFIRMATION": "/auth/v1/verify",
        "MAILER_URLPATHS_EMAIL_CHANGE": "/auth/v1/verify",
        "MAILER_URLPATHS_INVITE": "/auth/v1/verify",
        "MAILER_URLPATHS_RECOVERY": "/auth/v1/verify",
        "SMTP_ADMIN_EMAIL": "noreply@example.local",
        "SMTP_HOST": "localhost",
        "SMTP_PORT": "587",
        "SMTP_USER": "",
        "SMTP_PASS": "",
        "SMTP_SENDER_NAME": "myapp",
        "GITHUB_ENABLED": "false",
        "GITHUB_CLIENT_ID": "",
        "GITHUB_SECRET": "",
        "GOOGLE_ENABLED": "false",
        "GOOGLE_CLIENT_ID": "",
        "GOOGLE_SECRET": "",
        "GOOGLE_PROJECT_ID": "",
        "GOOGLE_PROJECT_NUMBER": "",
        "AZURE_ENABLED": "false",
        "AZURE_CLIENT_ID": "",
        "AZURE_SECRET": "",
        "MFA_PHONE_ENROLL_ENABLED": "false",
        "MFA_PHONE_VERIFY_ENABLED": "false",
        "MFA_TOTP_ENROLL_ENABLED": "false",
        "MFA_TOTP_VERIFY_ENABLED": "false",
        "MFA_MAX_ENROLLED_FACTORS": "10",
        "SAML_ENABLED": "false",
        "SAML_PRIVATE_KEY": "",
        "SAML_ALLOW_ENCRYPTED_ASSERTIONS": "false",
        "SAML_RELAY_STATE_VALIDITY_PERIOD": "300",
        "SAML_RATE_LIMIT_ASSERTION": "",
        "SMS_PROVIDER": "",
        "SMS_OTP_EXP": "60",
        "SMS_OTP_LENGTH": "6",
        "SMS_MAX_FREQUENCY": "",
        "SMS_TWILIO_ACCOUNT_SID": "",
        "SMS_TWILIO_AUTH_TOKEN": "",
        "SMS_TWILIO_MESSAGE_SERVICE_SID": "",
        "SMS_TEMPLATE": "",
        "SMS_TEST_OTP": "",
        "PGRST_DB_SCHEMAS": "public,storage,graphql_public",
        "PGRST_DB_EXTRA_SEARCH_PATH": "public,extensions",
        "PGRST_DB_MAX_ROWS": "1000",
        "FUNCTIONS_VERIFY_JWT": "false",
        "STUDIO_DEFAULT_ORGANIZATION": "Default Organization",
        "STUDIO_DEFAULT_PROJECT": "Default Project",
        "OPENAI_API_KEY": "",
        "STORAGE_TENANT_ID": "stub",
        "GLOBAL_S3_BUCKET": "stub",
        "IMGPROXY_AUTO_WEBP": "true",
        "S3_PROTOCOL_ACCESS_KEY_ID": "s3" + _rand_hex(8),
        "S3_PROTOCOL_ACCESS_KEY_SECRET": _rand_token(32),
        "REGION": "local",
        "DOCKER_SOCKET_LOCATION": "/var/run/docker.sock",
    }
    openim_defaults = {
        "MYAPP_DATA_ROOT": str(data_root),
        "HOST_IP": public_host,
        "OPENIM_MYSQL_ROOT_PASSWORD": _rand_token(32),
        "OPENIM_MYSQL_PASSWORD": _rand_token(32),
        "OPENIM_MONGO_PASSWORD": _rand_token(32),
        "OPENIM_REDIS_PASSWORD": _rand_token(32),
        "OPENIM_MINIO_ACCESS_KEY": "openim" + _rand_hex(4),
        "OPENIM_MINIO_SECRET_KEY": _rand_token(32),
        "OPENIM_SECRET": openim_secret,
        "OPENIM_WEBHOOK_SECRET": openim_webhook_secret,
        "OPENIM_MYSQL_PORT": "13306",
        "OPENIM_MONGO_PORT": "37017",
        "OPENIM_REDIS_PORT": "16379",
        "OPENIM_MINIO_PORT": "10005",
        "OPENIM_MINIO_CONSOLE_PORT": "10006",
        "OPENIM_WS_PORT": "10001",
        "OPENIM_API_PORT": "10002",
        "OPENIM_ADMIN_PORT": "10009",
    }
    agent_defaults = {
        "AGENT_NODE_TOKEN": _rand_hex(24),
        "AGENT_NODE_REGISTRATION_TOKEN": _rand_hex(24),
        "AGENT_NODE_ID": _cfg().get("node", {}).get("id", os.uname().nodename),
        "AGENT_NODE_PROVIDER_MODE": "master",
        "AGENT_NODE_PULL_ENABLED": "1",
    }
    config_center_defaults = {
        "CONFIG_CENTER_ADMIN_USERNAME": "admin",
        "CONFIG_CENTER_ADMIN_PASSWORD": _rand_token(24),
        "CONFIG_CENTER_SESSION_SECRET": _rand_hex(32),
    }
    user_center_defaults = {
        "USER_CENTER_ADMIN_USERNAME": "admin",
        "USER_CENTER_ADMIN_PASSWORD": _rand_token(24),
        "USER_CENTER_SESSION_SECRET": _rand_hex(32),
        "USER_CENTER_COOKIE_SECURE": "false",
    }

    changed = {
        "backend": _merge_env_group("backend", backend_defaults, force=force),
        "supabase": _merge_env_group("supabase", supabase_defaults, force=force),
        "openim": _merge_env_group("openim", openim_defaults, force=force),
        "agent": _merge_env_group("agent", agent_defaults, force=force),
        "config-center": _merge_env_group("config-center", config_center_defaults, force=force),
        "user-center": _merge_env_group("user-center", user_center_defaults, force=force),
    }
    image_changed = _merge_env_group(
        "backend",
        {
            "MYAPP_BACKEND_IMAGE": _configured_image("backend"),
            "MYAPP_AGENT_NODE_IMAGE": _configured_image("agent-node"),
            "MYAPP_AGENT_RUNTIME_IMAGE": _configured_image("agent-runtime"),
        },
        force=True,
    )
    if image_changed:
        changed["backend"].extend(key for key in image_changed if key not in changed["backend"])
    if not quiet:
        rows = [{"group": group, "keys": len(keys)} for group, keys in changed.items()]
        _print_table(rows, [("group", "GROUP"), ("keys", "CHANGED_KEYS")])
    _safe_write_default_config_snapshot()
    return 0


def _redact(value: str) -> str:
    digest = hashlib.sha256(value.encode()).hexdigest()[:8]
    return f"<redacted len={len(value)} sha256:{digest}>"


def _bundle_secret_files(*, redacted: bool) -> list[dict]:
    root = _setup_secret_host_root()
    if not root.exists():
        return []
    rows = []
    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue
        rel = str(path.relative_to(_secret_dir()))
        stat = path.stat()
        if redacted:
            content_b64 = _redact(path.read_bytes().hex())
        else:
            content_b64 = base64.b64encode(path.read_bytes()).decode("ascii")
        rows.append({"path": rel, "mode": oct(stat.st_mode & 0o777), "content_b64": content_b64})
    return rows


def _config_bundle(*, redacted: bool = True) -> dict:
    secrets: dict[str, dict[str, str]] = {}
    secret_dir = _secret_dir()
    if secret_dir.exists():
        for path in sorted(secret_dir.glob("*.env")):
            data = _parse_env(path)
            secrets[path.stem] = {key: (_redact(value) if redacted else value) for key, value in sorted(data.items())}
    return {
        "type": "myapp.config.bundle",
        "version": 1,
        "exported_at": int(time.time()),
        "host": socket.gethostname(),
        "language": _LANG,
        "config_path": str(CONFIG_PATH),
        "services_path": str(SERVICES_PATH),
        "config": _load_json(CONFIG_PATH, {}),
        "services": _load_json(SERVICES_PATH, {}),
        "secrets": secrets,
        "secret_files": _bundle_secret_files(redacted=redacted),
    }


def _serialize_config_bundle(bundle: dict, *, fmt: str = "json") -> str:
    if fmt == "yaml":
        try:
            import yaml  # type: ignore
        except ImportError as exc:
            raise RuntimeError("YAML export requires PyYAML; use --format json") from exc
        return yaml.safe_dump(bundle, allow_unicode=True, sort_keys=False)
    return json.dumps(bundle, indent=2, ensure_ascii=False) + "\n"


def _config_bundle_format(path: Path, requested: str = "auto") -> str:
    if requested != "auto":
        return requested
    if str(path) != "-" and path.suffix.lower() in {".yaml", ".yml"}:
        return "yaml"
    return "json"


def _write_config_bundle(path: Path, bundle: dict, *, fmt: str = "json") -> None:
    body = _serialize_config_bundle(bundle, fmt=fmt)
    if str(path) == "-":
        print(body, end="")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(body, encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)
    os.chmod(path, 0o600)


def _write_default_config_snapshot() -> None:
    path = _default_config_bundle_path()
    _write_config_bundle(path, _config_bundle(redacted=False))


def _load_config_bundle(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        if path.suffix.lower() not in {".yaml", ".yml"}:
            raise
        try:
            import yaml  # type: ignore
        except ImportError as exc:
            raise ValueError("YAML import requires PyYAML") from exc
        data = yaml.safe_load(text)
    if not isinstance(data, dict):
        raise ValueError("config bundle must be a mapping")
    if data.get("type") != "myapp.config.bundle":
        raise ValueError("not a myapp config bundle")
    return data


def _import_config_bundle_data(bundle: dict) -> None:
    if isinstance(bundle.get("config"), dict):
        _save_json(CONFIG_PATH, bundle["config"], mode=0o644)
    if isinstance(bundle.get("services"), dict):
        _save_json(SERVICES_PATH, bundle["services"], mode=0o644)
    secret_dir = _secret_dir()
    secret_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(secret_dir, 0o700)
    for group, data in (bundle.get("secrets") or {}).items():
        if not isinstance(data, dict):
            continue
        if any(str(value).startswith("<redacted") for value in data.values()):
            print(f"skip redacted secret group: {group}", file=sys.stderr)
            continue
        _write_env(_secret_path(str(group)), {str(key): str(value) for key, value in data.items()})
    for item in bundle.get("secret_files") or []:
        rel = str(item.get("path") or "")
        if not rel or rel.startswith("/") or ".." in Path(rel).parts:
            continue
        content = str(item.get("content_b64") or "")
        if content.startswith("<redacted"):
            print(f"skip redacted secret file: {rel}", file=sys.stderr)
            continue
        try:
            raw = base64.b64decode(content.encode("ascii"))
        except Exception as exc:
            print(f"skip invalid secret file {rel}: {exc}", file=sys.stderr)
            continue
        target = secret_dir / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_suffix(target.suffix + ".tmp")
        tmp.write_bytes(raw)
        mode_text = str(item.get("mode") or "0o600")
        try:
            mode = int(mode_text, 8)
        except ValueError:
            mode = 0o600
        os.chmod(tmp, mode)
        tmp.replace(target)
        os.chmod(target, mode)


def _restore_data_root_config_if_needed(data_root: Path, *, force: bool = False) -> bool:
    bundle_path = data_root / "myapp-config.json"
    if not bundle_path.exists():
        return False
    if not force and CONFIG_PATH.exists() and any(_secret_dir().glob("*.env")):
        return False
    bundle = _load_config_bundle(bundle_path)
    _import_config_bundle_data(bundle)
    cfg = _cfg()
    _apply_data_root_to_cfg(cfg, data_root)
    _save_json(CONFIG_PATH, cfg, mode=0o644)
    _ensure_data_root_layout(data_root)
    print(_t("config_imported", path=str(bundle_path)))
    return True


def _safe_write_default_config_snapshot() -> None:
    try:
        _write_default_config_snapshot()
    except Exception as exc:
        print(f"warning: myapp-config.json snapshot not written: {exc}", file=sys.stderr)


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
            print("language must be one of: zh, en, de, es", file=sys.stderr)
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


def _strip_trailing_slash(value: str) -> str:
    return value.rstrip("/")


def _host_port_url(scheme: str, host: str, port: str | int) -> str:
    return f"{scheme}://{host}:{port}"


def _client_env_payload(*, host: str | None = None, name: str | None = None) -> dict:
    cfg = _cfg()
    domains = cfg.get("domains", {}) or {}
    backend_env = _parse_env(_secret_path("backend"))
    supabase_env = _parse_env(_secret_path("supabase"))
    openim_env = _parse_env(_secret_path("openim"))
    public_host = _public_host(host)
    host_was_explicit = bool(host)

    def from_domain_or_port(domain_key: str, port_key: str, default_port: str, *, scheme: str = "http") -> str:
        if not host_was_explicit:
            domain_value = str(domains.get(domain_key) or "").strip()
            if domain_value:
                return _strip_trailing_slash(domain_value)
        return _host_port_url(scheme, public_host, backend_env.get(port_key) or default_port)

    backend_url = from_domain_or_port("backend", "BACKEND_PORT", "5566")
    registry_url = from_domain_or_port("registry", "REGISTRY_PORT", "3254")
    minio_url = from_domain_or_port("oss", "APP_MINIO_PORT", "9000")
    config_center_url = from_domain_or_port("config_center", "CONFIG_CENTER_PORT", "5000")

    if host_was_explicit:
        supabase_url = _host_port_url("http", public_host, supabase_env.get("KONG_HTTP_PORT") or "18000")
        im_api_url = _host_port_url("http", public_host, openim_env.get("OPENIM_API_PORT") or "10002")
        im_ws_url = _host_port_url("ws", public_host, openim_env.get("OPENIM_WS_PORT") or "10001")
    else:
        supabase_url = backend_env.get("SUPABASE_URL") or _host_port_url("http", public_host, supabase_env.get("KONG_HTTP_PORT") or "18000")
        im_api_url = backend_env.get("OPENIM_API_URL") or _host_port_url("http", public_host, openim_env.get("OPENIM_API_PORT") or "10002")
        im_ws_url = backend_env.get("OPENIM_WS_URL") or _host_port_url("ws", public_host, openim_env.get("OPENIM_WS_PORT") or "10001")

    env_name = name or f"MyApp {public_host}"
    return {
        "type": "myapp.environment",
        "version": 1,
        "name": env_name,
        "backendUrl": _strip_trailing_slash(backend_url),
        "supabaseUrl": _strip_trailing_slash(supabase_url),
        "minioUrl": _strip_trailing_slash(minio_url),
        "registryUrl": _strip_trailing_slash(registry_url),
        "imApiUrl": _strip_trailing_slash(im_api_url),
        "imWsUrl": _strip_trailing_slash(im_ws_url),
        "configCenterUrl": _strip_trailing_slash(config_center_url),
    }


def _default_client_env_path() -> Path:
    return Path(_cfg().get("paths", {}).get("state", "/var/lib/myapp")) / "client-environment.json"


def _write_qr_png(data: str, path: Path) -> tuple[bool, str]:
    qrencode = shutil.which("qrencode")
    if not qrencode:
        return False, "qrencode not found; install qrencode or rerun with --no-qr"
    path.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run([qrencode, "-o", str(path)], input=data, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        return False, proc.stderr.strip() or f"qrencode exited {proc.returncode}"
    return True, str(path)


def _print_terminal_qr(data: str) -> int:
    qrencode = shutil.which("qrencode")
    if not qrencode:
        print("qrencode not found; cannot print terminal QR", file=sys.stderr)
        return 1
    return subprocess.run([qrencode, "-t", "ANSIUTF8"], input=data, text=True).returncode


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


def _emit_client_env_summary(*, host: str | None = None, name: str | None = None, terminal_qr: bool = True) -> None:
    payload = _client_env_payload(host=host, name=name)
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    out_path = _default_client_env_path()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(body + "\n", encoding="utf-8")
    os.chmod(out_path, 0o644)

    print("")
    print("== " + _t("client_env_summary") + " ==")
    print(_t("client_env_json", path=str(out_path)))
    qr_path = out_path.with_suffix(".png")
    ok, detail = _write_qr_png(body, qr_path)
    if ok:
        print(_t("client_env_qr", path=detail))
    else:
        print(f"warning: QR PNG not generated: {detail}", file=sys.stderr)
    print(_t("copy_json"))
    print(body)
    if terminal_qr and sys.stdout.isatty():
        _print_terminal_qr(body)


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
            rows.append({
                "target": target,
                "image": image,
                "state": "present" if _image_exists(image) else "missing",
            })
        _print_table(rows, [("target", "TARGET"), ("state", "STATE"), ("image", "IMAGE")])
        return 0
    try:
        targets = _image_targets_for_arg(args.target)
    except KeyError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return _deploy_images(targets, action=args.image_cmd, dry_run=args.dry_run)


def _run_log_summary(path: Path) -> dict:
    row = {
        "run_id": path.stem,
        "session_id": "-",
        "agent_id": "-",
        "provider_id": "-",
        "status": "unknown",
        "returncode": "-",
        "duration": "-",
        "lines": 0,
    }
    started = None
    stopped = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        row["lines"] += 1
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "start":
            started = event.get("ts")
            row["run_id"] = event.get("run_id") or row["run_id"]
            row["session_id"] = event.get("session_id") or "-"
            row["agent_id"] = event.get("agent_id") or "-"
            row["provider_id"] = event.get("provider_id") or "-"
            row["status"] = "started"
        elif event.get("type") == "stop":
            stopped = event.get("ts")
            row["status"] = event.get("status") or "stopped"
            row["returncode"] = event.get("returncode", "-")
    if started and stopped:
        row["duration"] = f"{max(0, int((stopped - started) / 1000))}s"
    return row


def _duration_ms(started, finished=None) -> str:
    try:
        start = int(started)
        end = int(finished) if finished else int(time.time() * 1000)
        return f"{max(0, int((end - start) / 1000))}s"
    except (TypeError, ValueError):
        return "-"


def _agent_add_node_id(host: str) -> str:
    text = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(host or "").strip()).strip("-._")
    return f"myapp-agent-{text or os.uname().nodename}"


def _print_agent_add_script(args) -> int:
    cfg = _cfg()
    backend_url = (args.backend or cfg.get("domains", {}).get("backend") or "").rstrip("/")
    mode = (getattr(args, "mode", "pull") or "pull").strip().lower().replace("_", "-")
    host = (args.host or "").strip()
    node_url = (args.url or "").rstrip("/")
    if getattr(args, "build", False) and args.pull:
        print("--build and --pull cannot be used together", file=sys.stderr)
        return 2
    if not backend_url:
        print("backend url is required; pass --backend or set domains.backend", file=sys.stderr)
        return 2
    if mode not in {"pull", "direct"}:
        print("--mode must be pull or direct", file=sys.stderr)
        return 2
    if mode == "direct" and not node_url and not host:
        print("agent host is required in direct mode; pass --host or --url", file=sys.stderr)
        return 2
    if mode == "direct" and not node_url:
        node_url = f"http://{host}:{args.public_port}".rstrip("/")
    if not host:
        parsed = urlparse(node_url) if node_url else None
        host = (parsed.hostname if parsed else "") or (node_url.split(":", 1)[0] if node_url else "")
    if not host and not args.node_id:
        print("--node-id is required when --host/--url is omitted", file=sys.stderr)
        return 2
    node_id = args.node_id or _agent_add_node_id(host)
    node_name = (getattr(args, "name", None) or node_id).strip()[:128] or node_id
    if mode == "pull" and not node_url:
        node_url = f"pull://{node_id}"
    display_host = host or node_id
    provider_mode = args.provider_mode.strip().lower().replace("_", "-")
    if provider_mode not in {"master", "local"}:
        print("--provider-mode must be master or local", file=sys.stderr)
        return 2

    agent_env = _parse_env(_secret_path("agent"))
    agent_token = agent_env.get("AGENT_NODE_TOKEN", "")
    registration_token = agent_env.get("AGENT_NODE_REGISTRATION_TOKEN", "")
    if not agent_token or not registration_token:
        print("missing agent tokens on master; run myapp-ctl secret init-stack first", file=sys.stderr)
        return 1

    labels = list(args.label or [])
    if not any(label.startswith("host=") for label in labels):
        labels.append(f"host={display_host}")
    if not any(str(label).replace("_", "-").startswith("provider-mode=") for label in labels):
        labels.append(f"provider_mode={provider_mode}")
    if not any(str(label).replace("_", "-").startswith("mode=") for label in labels):
        labels.append(f"mode={mode}")
    if not any(str(label).replace("_", "-").startswith("name=") for label in labels):
        labels.append(f"name={node_name}")
    join_cmd = [
        "myapp-ctl",
        "agent-node",
        "join",
        "--backend",
        backend_url,
        "--node-id",
        node_id,
        "--name",
        node_name,
        "--url",
        node_url,
        "--host",
        display_host,
        "--data-root",
        str(args.data_root),
        "--local-port",
        str(args.local_port),
        "--capacity",
        str(args.capacity),
        "--queue-max",
        str(args.queue_max if args.queue_max is not None else args.capacity),
        "--ttl",
        str(args.ttl),
        "--mode",
        mode,
        "--provider-mode",
        provider_mode,
        "--agent-token",
        agent_token,
        "--registration-token",
        registration_token,
    ]
    if args.pull:
        join_cmd.append("--pull")
    if getattr(args, "build", False):
        join_cmd.append("--build")
    if mode == "direct":
        join_cmd.extend(["--public-port", str(args.public_port)])
        if args.no_nginx:
            join_cmd.append("--no-nginx")
        if args.allow_from:
            join_cmd.extend(["--allow-from", args.allow_from])
    if args.no_timer:
        join_cmd.append("--no-timer")
    for label in labels:
        join_cmd.extend(["--label", label])

    print("# Run this on the new agent host after installing myapp-ctl from this branch.")
    print("# It contains agent registration tokens. Treat it as a secret.")
    print(" ".join(shlex.quote(part) for part in join_cmd))
    return 0


def _join_agent_node(args) -> int:
    if args.build and args.pull:
        print("--build and --pull cannot be used together", file=sys.stderr)
        return 2
    backend_url = (args.backend or "").rstrip("/")
    mode = (args.mode or "pull").strip().lower().replace("_", "-")
    provider_mode = (args.provider_mode or "master").strip().lower().replace("_", "-")
    node_id = str(args.node_id or "").strip()
    node_name = (getattr(args, "name", None) or node_id).strip()[:128] or node_id
    node_url = (args.url or "").rstrip("/")
    host = (args.host or "").strip()
    if not backend_url:
        print("--backend is required", file=sys.stderr)
        return 2
    if mode not in {"pull", "direct"}:
        print("--mode must be pull or direct", file=sys.stderr)
        return 2
    if provider_mode not in {"master", "local"}:
        print("--provider-mode must be master or local", file=sys.stderr)
        return 2
    if not node_id:
        print("--node-id is required", file=sys.stderr)
        return 2
    if mode == "pull" and not node_url:
        node_url = f"pull://{node_id}"
    if mode == "direct" and not node_url:
        if not host:
            print("--host or --url is required in direct mode", file=sys.stderr)
            return 2
        node_url = f"http://{host}:{args.public_port}".rstrip("/")
    if not node_url:
        print("--url is required", file=sys.stderr)
        return 2
    if not host:
        parsed = urlparse(node_url)
        host = parsed.hostname or node_id
    if not args.agent_token or not args.registration_token:
        print("--agent-token and --registration-token are required", file=sys.stderr)
        return 2

    try:
        data_root = _ensure_data_root_config(args.data_root, interactive=False)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    _ensure_data_root_layout(data_root)
    rc = _init_stack_secrets(host=host or node_id, quiet=True)
    if rc != 0:
        return rc

    labels = list(args.label or [])
    if not any(str(label).startswith("host=") for label in labels):
        labels.append(f"host={host or node_id}")
    if not any(str(label).replace("_", "-").startswith("provider-mode=") for label in labels):
        labels.append(f"provider_mode={provider_mode}")
    if not any(str(label).replace("_", "-").startswith("mode=") for label in labels):
        labels.append(f"mode={mode}")
    if not any(str(label).replace("_", "-").startswith("name=") for label in labels):
        labels.append(f"name={node_name}")

    agent_env = _parse_env(_secret_path("agent"))
    current_node_id = str(agent_env.get("AGENT_NODE_ID") or "").strip()
    has_running_agent_node = _docker_container_running("myapp-agent-node")
    use_instance = bool(
        mode == "pull"
        and has_running_agent_node
        and current_node_id != node_id
        and not getattr(args, "replace_existing_agent_node", False)
    )
    agent_root = _agent_node_instance_root(data_root, node_id) if use_instance else data_root / "agent-node"
    provider_env_path = _agent_node_provider_env_path(agent_root) if provider_mode == "local" else None
    if provider_env_path and not _ai_providers_configured(provider_env_path):
        if not sys.stdin.isatty():
            print(
                f"local provider config is missing at {provider_env_path} and stdin is not interactive",
                file=sys.stderr,
            )
            return 1
        rc = _setup_ai_providers(
            force=False,
            path=provider_env_path,
            title=f"Local provider setup for agent node {node_name}",
        )
        if rc != 0:
            return rc
    if mode == "direct" and has_running_agent_node and current_node_id != node_id and not getattr(args, "replace_existing_agent_node", False):
        print(
            "refusing to replace the running agent-node in direct mode; "
            "use pull mode for an additional local instance, or pass --replace-existing-agent-node",
            file=sys.stderr,
        )
        return 2
    if not use_instance:
        backend_env = _parse_env(_secret_path("backend"))
        backend_env["PUBLIC_HOST"] = host or node_id
        _write_env(_secret_path("backend"), backend_env)
    new_agent_env = dict(agent_env)
    new_agent_env.update(
        {
            "AGENT_NODE_ID": node_id,
            "AGENT_NODE_NAME": node_name,
            "AGENT_NODE_AUTH_MODE": "shared",
            "AGENT_NODE_PORT": str(args.local_port),
            "AGENT_NODE_PROVIDER_MODE": provider_mode,
            "AGENT_NODE_PULL_ENABLED": "1" if mode == "pull" else "0",
            "AGENT_NODE_BACKEND_URL": backend_url,
            "AGENT_NODE_SELF_REGISTER_URL": node_url,
            "AGENT_NODE_CAPACITY": str(args.capacity),
            "AGENT_NODE_QUEUE_MAX": str(args.queue_max if args.queue_max is not None else args.capacity),
            "AGENT_NODE_REGISTRATION_TTL_SECONDS": str(args.ttl),
            "AGENT_NODE_LABELS": ",".join(labels),
            "AGENT_NODE_TOKEN": args.agent_token,
            "AGENT_NODE_REGISTRATION_TOKEN": args.registration_token,
        }
    )
    if provider_env_path:
        new_agent_env["AGENT_NODE_AI_PROVIDERS_ENV_FILE"] = str(provider_env_path)
    if use_instance:
        env_path = agent_root / "agent.env"
        instance_env = _filtered_agent_node_instance_env(
            new_agent_env,
            [
                "AGENT_NODE_ID",
                "AGENT_NODE_NAME",
                "AGENT_NODE_AUTH_MODE",
                "AGENT_NODE_PORT",
                "AGENT_NODE_PROVIDER_MODE",
                "AGENT_NODE_AI_PROVIDERS_ENV_FILE",
                "AGENT_NODE_PULL_ENABLED",
                "AGENT_NODE_BACKEND_URL",
                "AGENT_NODE_SELF_REGISTER_URL",
                "AGENT_NODE_CAPACITY",
                "AGENT_NODE_QUEUE_MAX",
                "AGENT_NODE_REGISTRATION_TTL_SECONDS",
                "AGENT_NODE_LABELS",
                "AGENT_NODE_TOKEN",
                "AGENT_NODE_REGISTRATION_TOKEN",
            ],
        )
        instance_env["AGENT_NODE_BACKEND_URL"] = _agent_node_container_backend_url(backend_url)
        instance_env["PUBLIC_HOST"] = host or node_id
        _write_agent_node_instance_env(env_path, instance_env)
        _safe_write_default_config_snapshot()
        print(
            f"starting additional agent-node instance without replacing myapp-agent-node: "
            f"{node_name} ({node_id}) -> {node_url}",
            flush=True,
        )
        rc = _run_agent_node_instance(
            node_id=node_id,
            env_path=env_path,
            data_root=data_root,
            provider_env_path=provider_env_path,
            build=bool(args.build),
            pull=bool(args.pull),
        )
        if rc != 0:
            return rc
        _run(["myapp-ctl", "agent", "ls"], capture=False)
        return 0

    _write_env(_secret_path("agent"), new_agent_env)
    _safe_write_default_config_snapshot()
    print(f"updated agent join config: {node_name} ({node_id}) -> {node_url}", flush=True)

    if mode == "direct" and not args.no_nginx:
        if shutil.which("apt-get"):
            rc = _run(["apt-get", "update"], capture=False).returncode
            if rc != 0:
                return rc
            rc = _run(["apt-get", "install", "-y", "nginx"], capture=False).returncode
            if rc != 0:
                return rc
        conf = Path("/etc/nginx/conf.d/myapp-agent-node.conf")
        conf.parent.mkdir(parents=True, exist_ok=True)
        conf.write_text(
            "\n".join(
                [
                    "server {",
                    f"  listen {int(args.public_port)};",
                    "  server_name _;",
                    "  location / {",
                    f"    proxy_pass http://127.0.0.1:{int(args.local_port)};",
                    "    proxy_http_version 1.1;",
                    "    proxy_read_timeout 7200s;",
                    "    proxy_send_timeout 7200s;",
                    "  }",
                    "}",
                    "",
                ]
            ),
            encoding="utf-8",
        )
        _run(["systemctl", "reload", "nginx"], capture=False)
        if args.allow_from and shutil.which("ufw"):
            _run(
                [
                    "ufw",
                    "allow",
                    "from",
                    args.allow_from,
                    "to",
                    "any",
                    "port",
                    str(int(args.public_port)),
                    "proto",
                    "tcp",
                ],
                capture=False,
            )

    deploy_args = [
        "myapp-ctl",
        "deploy",
        "agent-node",
        "agent-runtime",
        "--data-root",
        str(data_root),
        "--no-setup",
        "--no-test-user",
    ]
    if args.pull:
        deploy_args.append("--pull")
    elif args.build:
        deploy_args.append("--build")
    rc = _run(deploy_args, capture=False).returncode
    if rc != 0:
        return rc

    if args.no_timer:
        _remove_agent_register_timer()
        register_args = argparse.Namespace(
            backend=backend_url,
            url=node_url,
            node_id=node_id,
            name=node_name,
            capacity=args.capacity,
            queue_max=args.queue_max if args.queue_max is not None else args.capacity,
            ttl=args.ttl,
            token=args.registration_token,
            label=labels,
        )
        return _register_agent_node(register_args)

    _run(["myapp-ctl", "status", "agent-node"], capture=False)
    _run(["myapp-ctl", "agent", "ls"], capture=False)
    return 0


def _private_agent_key_paths(agent_root: Path, node_id: str) -> tuple[Path, Path]:
    key_dir = agent_root / "private"
    safe_node = re.sub(r"[^A-Za-z0-9_.-]+", "_", node_id).strip("._") or "private-agent"
    return key_dir / f"{safe_node}.key.pem", key_dir / f"{safe_node}.public.pem"


def _ensure_private_agent_keypair(private_key: Path, public_key: Path) -> int:
    if private_key.exists() and public_key.exists():
        return 0
    if not shutil.which("openssl"):
        print("openssl is required to generate a private agent keypair", file=sys.stderr)
        return 1
    private_key.parent.mkdir(parents=True, exist_ok=True)
    rc = _run(
        [
            "openssl",
            "genpkey",
            "-algorithm",
            "RSA",
            "-pkeyopt",
            "rsa_keygen_bits:3072",
            "-out",
            str(private_key),
        ]
    ).returncode
    if rc != 0:
        return rc
    os.chmod(private_key, 0o600)
    rc = _run(["openssl", "rsa", "-pubout", "-in", str(private_key), "-out", str(public_key)]).returncode
    if rc != 0:
        return rc
    os.chmod(public_key, 0o644)
    return 0


def _private_agent_auth_token(args, *, prompt: bool = True) -> str:
    token = (
        getattr(args, "auth_token", None)
        or os.environ.get("MYAPP_AUTH_TOKEN")
        or os.environ.get("SUPABASE_ACCESS_TOKEN")
        or ""
    ).strip()
    if token:
        return token
    if prompt and sys.stdin.isatty():
        return _prompt_secret("user access token for private agent registration")
    return ""


def _private_agent_join_token(args) -> str:
    return (
        getattr(args, "join_token", None)
        or os.environ.get("MYAPP_PRIVATE_AGENT_JOIN_TOKEN")
        or ""
    ).strip()


def _local_agent_node_is_private() -> bool:
    value = (_parse_env(_secret_path("agent")).get("AGENT_NODE_AUTH_MODE", "") or "").strip().lower()
    return value in {"private", "user-private"}


def _local_private_agent_jwt() -> str:
    agent_env = _parse_env(_secret_path("agent"))
    if (agent_env.get("AGENT_NODE_AUTH_MODE", "") or "").strip().lower() not in {"private", "user-private"}:
        return ""
    token = os.environ.get("AGENT_NODE_TOKEN") or agent_env.get("AGENT_NODE_TOKEN", "")
    if not token:
        return ""
    try:
        port = int(agent_env.get("AGENT_NODE_PORT") or 5590)
    except (TypeError, ValueError):
        port = 5590
    data, _status, _error = _agent_node_request_json(
        f"http://127.0.0.1:{port}",
        "/private_auth",
        token=token,
        timeout=3,
    )
    if not data:
        return ""
    return str(data.get("token") or "").strip()


def _private_agent_nodes_payload(args, *, probe: bool = True) -> tuple[dict | None, int, str]:
    backend_url = _agent_node_backend_url(args)
    if not backend_url:
        return None, 2, "backend url is required; pass --backend or set AGENT_NODE_BACKEND_URL"
    auth_token = _private_agent_auth_token(args, prompt=False)
    probe_value = "1" if probe else "0"
    if auth_token:
        return _agent_node_request_json(
            backend_url,
            f"/api/ai/private_agent/nodes?probe={probe_value}",
            token=auth_token,
        )
    private_jwt = _local_private_agent_jwt()
    if private_jwt:
        return _agent_node_request_json(
            backend_url,
            f"/api/ai/private_agent/nodes/self?probe={probe_value}",
            extra_headers={"X-MyApp-Agent-JWT": private_jwt},
        )
    return None, 2, "--auth-token/MYAPP_AUTH_TOKEN is required, or start the local private agent-node"


def _list_private_agent_nodes(args) -> int:
    data, status, error = _private_agent_nodes_payload(args, probe=not getattr(args, "no_probe", False))
    if not data:
        print(f"private agent-node ls failed: {status or '-'} {error}", file=sys.stderr)
        return 1 if status != 2 else 2
    return _print_agent_node_rows(data, as_json=getattr(args, "json", False))


def _status_private_agent_node(args) -> int:
    data, status, error = _private_agent_nodes_payload(args, probe=not getattr(args, "no_probe", False))
    if not data:
        print(f"private agent-node status failed: {status or '-'} {error}", file=sys.stderr)
        return 1 if status != 2 else 2
    node_id = getattr(args, "node_id", None)
    if not node_id:
        return _print_agent_node_rows(data, as_json=getattr(args, "json", False))
    for node in data.get("nodes") or []:
        if node.get("node_id") == node_id:
            return _print_agent_node_status({"node": node}, as_json=getattr(args, "json", False))
    print(f"private agent-node not found: {node_id}", file=sys.stderr)
    return 1


def _join_private_agent_node(args) -> int:
    if args.build and args.pull:
        print("--build and --pull cannot be used together", file=sys.stderr)
        return 2
    backend_url = (args.backend or "").rstrip("/")
    if not backend_url:
        print("--backend is required", file=sys.stderr)
        return 2
    join_token = _private_agent_join_token(args)
    auth_token = "" if join_token else _private_agent_auth_token(args)
    if not join_token and not auth_token:
        print("--join-token, MYAPP_PRIVATE_AGENT_JOIN_TOKEN, --auth-token, or MYAPP_AUTH_TOKEN is required for private agent registration", file=sys.stderr)
        return 2
    node_id = str(args.node_id or f"private-{socket.gethostname()}").strip()
    node_id = re.sub(r"[^A-Za-z0-9_.-]+", "_", node_id).strip("._") or "private-agent"
    try:
        data_root = _ensure_data_root_config(args.data_root, interactive=False)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    _ensure_data_root_layout(data_root)
    agent_env = _parse_env(_secret_path("agent"))
    current_node_id = str(agent_env.get("AGENT_NODE_ID") or "").strip()
    has_running_agent_node = _docker_container_running("myapp-agent-node")
    use_instance = bool(
        has_running_agent_node
        and current_node_id != node_id
        and not getattr(args, "replace_existing_agent_node", False)
    )
    agent_root = _agent_node_instance_root(data_root, node_id) if use_instance else data_root / "agent-node"
    provider_env_path = _agent_node_provider_env_path(agent_root)
    private_key, public_key = _private_agent_key_paths(agent_root, node_id)
    private_key_container = f"/var/lib/myapp/agent-node/private/{private_key.name}"
    rc = _ensure_private_agent_keypair(private_key, public_key)
    if rc != 0:
        return rc
    public_key_text = public_key.read_text(encoding="utf-8")
    provider_filter = [item.strip().lower().replace("_", "-") for item in (args.provider or []) if item.strip()]
    agent_filter = [item.strip().lower().replace("_", "-") for item in (args.agent or []) if item.strip()]
    node_name = (args.name or node_id).strip()[:128] or node_id
    if not _ai_providers_configured(provider_env_path):
        if getattr(args, "no_provider_setup", False):
            print(
                f"private agent provider config is missing at {provider_env_path}; "
                "rerun without --no-provider-setup and enter this node's provider keys",
                file=sys.stderr,
            )
            return 1
        if not sys.stdin.isatty():
            print(
                f"private agent provider config is missing at {provider_env_path} and stdin is not interactive",
                file=sys.stderr,
            )
            return 1
        rc = _setup_ai_providers(
            force=False,
            path=provider_env_path,
            title=f"Private agent provider setup for {node_name}",
        )
        if rc != 0:
            return rc
    provider_env = _parse_env(provider_env_path)
    configured_provider_ids = _ai_provider_ids_from_env(provider_env)
    if provider_filter:
        missing = [provider_id for provider_id in provider_filter if provider_id not in configured_provider_ids]
        if missing:
            print(
                f"private agent provider config at {provider_env_path} is missing: {', '.join(missing)}",
                file=sys.stderr,
            )
            return 1
    capabilities = _ai_provider_capabilities_from_env(
        provider_env,
        provider_filter=provider_filter,
        agent_filter=agent_filter,
    )
    explicit_caps = []
    for raw in getattr(args, "capability", None) or []:
        parts = [part.strip().lower().replace("_", "-") for part in str(raw or "").split(":") if part.strip()]
        if len(parts) not in {2, 3}:
            print("--capability must be provider:agent or provider:agent:adapter", file=sys.stderr)
            return 2
        provider_id, agent_id = parts[0], parts[1]
        explicit_caps.append(
            {
                "provider_id": provider_id,
                "agent_id": agent_id,
                "adapter_kind": parts[2] if len(parts) == 3 else _default_adapter_kind(agent_id),
                "status": "configured",
                "enabled": True,
            }
        )
    if explicit_caps:
        available = {(cap["provider_id"], cap["agent_id"]) for cap in capabilities}
        missing_caps = [cap for cap in explicit_caps if (cap["provider_id"], cap["agent_id"]) not in available]
        if missing_caps:
            text = ", ".join(f"{cap['provider_id']}:{cap['agent_id']}" for cap in missing_caps)
            print(f"private agent provider config does not support capability: {text}", file=sys.stderr)
            return 1
        capabilities = explicit_caps
    if not capabilities:
        print(
            f"private agent provider config at {provider_env_path} has no enabled Claude/Codex/OpenCode adapter",
            file=sys.stderr,
        )
        return 1
    provider_ids = sorted({str(cap["provider_id"]) for cap in capabilities})
    agent_ids = sorted({str(cap["agent_id"]) for cap in capabilities})
    payload = {
        "node_id": node_id,
        "name": node_name,
        "public_key": public_key_text,
        "provider_ids": provider_ids,
        "agent_ids": agent_ids,
        "capabilities": capabilities,
        "capacity": args.capacity,
        "queue_max": args.queue_max if args.queue_max is not None else args.capacity,
        "ttl_seconds": args.ttl,
    }
    data, status, error = _agent_node_request_json(
        backend_url,
        "/api/ai/private_agent/nodes",
        method="POST",
        token=join_token or auth_token,
        payload=payload,
        timeout=15,
    )
    if not data:
        print(f"private agent registration failed: {status or '-'} {error}", file=sys.stderr)
        return 1
    owner_user_id = str(data.get("owner_user_id") or "").strip()
    display_host = _agent_node_default_display_host(args.host)
    rc = _init_stack_secrets(host=display_host, quiet=True)
    if rc != 0:
        return rc
    agent_env = _parse_env(_secret_path("agent"))
    labels = list(args.label or [])
    if not any(str(label).startswith("host=") for label in labels):
        labels.append(f"host={display_host}")
    if not any(str(label).replace("_", "-").startswith("name=") for label in labels):
        labels.append(f"name={node_name}")
    for required_label in ("visibility=private", "provider_mode=local", "mode=pull"):
        key = required_label.split("=", 1)[0].replace("_", "-")
        if not any(str(label).replace("_", "-").startswith(f"{key}=") for label in labels):
            labels.append(required_label)
    new_agent_env = dict(agent_env)
    new_agent_env.update(
        {
            "AGENT_NODE_ID": node_id,
            "AGENT_NODE_NAME": node_name,
            "AGENT_NODE_PORT": str(args.local_port),
            "AGENT_NODE_AUTH_MODE": "private",
            "AGENT_NODE_OWNER_USER_ID": owner_user_id,
            "AGENT_NODE_PRIVATE_KEY_PATH": private_key_container,
            "AGENT_NODE_AI_PROVIDERS_ENV_FILE": str(provider_env_path),
            "AGENT_NODE_PROVIDER_MODE": "local",
            "AGENT_NODE_PULL_ENABLED": "1",
            "AGENT_NODE_BACKEND_URL": backend_url,
            "AGENT_NODE_SELF_REGISTER_URL": f"pull://{node_id}",
            "AGENT_NODE_CAPACITY": str(args.capacity),
            "AGENT_NODE_QUEUE_MAX": str(args.queue_max if args.queue_max is not None else args.capacity),
            "AGENT_NODE_REGISTRATION_TTL_SECONDS": str(args.ttl),
            "AGENT_NODE_PROVIDER_IDS": ",".join(provider_ids),
            "AGENT_NODE_AGENT_IDS": ",".join(agent_ids),
            "AGENT_NODE_CAPABILITIES": json.dumps(capabilities, separators=(",", ":")),
            "AGENT_NODE_LABELS": ",".join(labels),
            "AGENT_NODE_TOKEN": agent_env.get("AGENT_NODE_TOKEN") or _rand_hex(24),
            "AGENT_NODE_REGISTRATION_TOKEN": "",
        }
    )
    if use_instance:
        env_path = agent_root / "agent.env"
        instance_env = _filtered_agent_node_instance_env(
            new_agent_env,
            [
                "AGENT_NODE_ID",
                "AGENT_NODE_NAME",
                "AGENT_NODE_PORT",
                "AGENT_NODE_AUTH_MODE",
                "AGENT_NODE_OWNER_USER_ID",
                "AGENT_NODE_PRIVATE_KEY_PATH",
                "AGENT_NODE_AI_PROVIDERS_ENV_FILE",
                "AGENT_NODE_PROVIDER_MODE",
                "AGENT_NODE_PULL_ENABLED",
                "AGENT_NODE_BACKEND_URL",
                "AGENT_NODE_SELF_REGISTER_URL",
                "AGENT_NODE_CAPACITY",
                "AGENT_NODE_QUEUE_MAX",
                "AGENT_NODE_REGISTRATION_TTL_SECONDS",
                "AGENT_NODE_PROVIDER_IDS",
                "AGENT_NODE_AGENT_IDS",
                "AGENT_NODE_CAPABILITIES",
                "AGENT_NODE_LABELS",
                "AGENT_NODE_TOKEN",
            ],
        )
        instance_env["AGENT_NODE_BACKEND_URL"] = _agent_node_container_backend_url(backend_url)
        instance_env["PUBLIC_HOST"] = display_host
        _write_agent_node_instance_env(env_path, instance_env)
        _safe_write_default_config_snapshot()
        print(
            f"starting private agent-node instance without replacing myapp-agent-node: "
            f"{node_name} ({node_id})",
            flush=True,
        )
        rc = _run_agent_node_instance(
            node_id=node_id,
            env_path=env_path,
            data_root=data_root,
            provider_env_path=provider_env_path,
            build=bool(args.build),
            pull=bool(args.pull),
        )
    else:
        _write_env(_secret_path("agent"), new_agent_env)
        _safe_write_default_config_snapshot()
        deploy_cmd = ["myapp-ctl", "deploy", "agent-node", "agent-runtime", "--no-setup", "--no-test-user"]
        if args.build:
            deploy_cmd.append("--build")
        elif args.pull:
            deploy_cmd.append("--pull")
        rc = _run(deploy_cmd, capture=False).returncode
    if rc != 0:
        return rc
    print(json.dumps(data, ensure_ascii=False))
    if use_instance:
        _run(["myapp-ctl", "agent", "ls"], capture=False)
    else:
        _run(["myapp-ctl", "status", "agent-node"], capture=False)
    return 0

def _agent_node_backend_url(args) -> str:
    explicit = getattr(args, "backend", None)
    if explicit:
        return explicit.rstrip("/")
    agent_backend = (_parse_env(_secret_path("agent")).get("AGENT_NODE_BACKEND_URL", "") or "").rstrip("/")
    agent_backend_host = urlparse(agent_backend).hostname or ""
    if agent_backend and agent_backend_host not in {"backend", "myapp-backend", "agent-node"}:
        return agent_backend
    return (
        _cfg().get("domains", {}).get("backend")
        or _parse_env(_secret_path("backend")).get("BACKEND_PUBLIC_URL", "")
        or agent_backend
        or ""
    ).rstrip("/")


def _agent_node_registry_token(args) -> str:
    return (
        getattr(args, "token", None)
        or os.environ.get("AGENT_NODE_REGISTRATION_TOKEN")
        or _parse_env(_secret_path("agent")).get("AGENT_NODE_REGISTRATION_TOKEN", "")
        or _parse_env(_secret_path("backend")).get("AGENT_NODE_REGISTRATION_TOKEN", "")
    )


def _agent_node_request_json(
    backend_url: str,
    path: str,
    *,
    method: str = "GET",
    token: str = "",
    extra_headers: dict[str, str] | None = None,
    payload: dict | None = None,
    timeout: float = 8.0,
) -> tuple[dict | None, int, str]:
    headers = {"User-Agent": "myapp-ctl/1"}
    if extra_headers:
        headers.update({str(k): str(v) for k, v in extra_headers.items() if str(k) and str(v)})
    data = None
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = Request(backend_url.rstrip("/") + path, data=data, headers=headers, method=method)
    try:
        with urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return json.loads(body) if body else {}, int(getattr(resp, "status", 200)), ""
    except HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(detail)
            detail = parsed.get("error") or detail
        except (TypeError, ValueError, json.JSONDecodeError):
            pass
        return None, int(exc.code), detail
    except (URLError, OSError, ValueError, json.JSONDecodeError) as exc:
        return None, 0, str(exc)


def _register_agent_node(args) -> int:
    backend_url = _agent_node_backend_url(args)
    node_url = (args.url or _cfg().get("domains", {}).get("agent_node") or "").rstrip("/")
    node_id = args.node_id or _cfg().get("node", {}).get("id") or os.uname().nodename
    node_name = (getattr(args, "name", None) or node_id).strip()[:128] or node_id
    if not backend_url:
        print("backend url is required; pass --backend or set domains.backend", file=sys.stderr)
        return 2
    if not node_url:
        print("agent node url is required; pass --url or set domains.agent_node", file=sys.stderr)
        return 2
    payload = {
        "node_id": node_id,
        "name": node_name,
        "url": node_url,
        "capacity": args.capacity,
        "queue_max": getattr(args, "queue_max", None) if getattr(args, "queue_max", None) is not None else args.capacity,
        "ttl_seconds": args.ttl,
        "labels": args.label or [],
    }
    data, status, error = _agent_node_request_json(
        backend_url,
        "/api/ai/agent_nodes/register",
        method="POST",
        token=_agent_node_registry_token(args),
        payload=payload,
    )
    if not data:
        print(f"register failed: {status or '-'} {error}", file=sys.stderr)
        return 1
    print(json.dumps(data, ensure_ascii=False))
    return 0


def _local_agent_node_register_command() -> list[str]:
    cfg = _cfg()
    agent_env = _parse_env(_secret_path("agent"))
    backend_env = _parse_env(_secret_path("backend"))
    backend_port = backend_env.get("BACKEND_PORT") or "5566"
    backend_url = (agent_env.get("AGENT_NODE_BACKEND_URL") or f"http://127.0.0.1:{backend_port}").rstrip("/")
    node_id = (
        agent_env.get("AGENT_NODE_ID")
        or cfg.get("node", {}).get("id")
        or os.uname().nodename
    )
    node_name = (agent_env.get("AGENT_NODE_NAME") or node_id).strip()[:128] or node_id
    pull_enabled = str(agent_env.get("AGENT_NODE_PULL_ENABLED", "1")).strip().lower() in {"1", "true", "yes", "on"}
    default_node_url = (
        f"pull://{node_id}"
        if pull_enabled
        else (cfg.get("domains", {}).get("agent_node") or "http://agent-node:5590")
    )
    node_url = (agent_env.get("AGENT_NODE_SELF_REGISTER_URL") or default_node_url).rstrip("/")
    public_host = _public_host()
    provider_mode = (
        agent_env.get("AGENT_NODE_PROVIDER_MODE", "master")
        .strip()
        .lower()
        .replace("_", "-")
        or "master"
    )
    capacity = agent_env.get("AGENT_NODE_CAPACITY") or "1"
    queue_max = agent_env.get("AGENT_NODE_QUEUE_MAX") or capacity
    ttl = agent_env.get("AGENT_NODE_REGISTRATION_TTL_SECONDS") or "180"
    return [
        "/usr/local/bin/myapp-ctl",
        "agent-node",
        "register",
        "--backend",
        backend_url,
        "--url",
        node_url,
        "--node-id",
        node_id,
        "--name",
        node_name,
        "--capacity",
        str(capacity),
        "--queue-max",
        str(queue_max),
        "--ttl",
        str(ttl),
        "--label",
        f"host={public_host}",
        "--label",
        f"provider_mode={provider_mode}",
        "--label",
        "role=all-in-one",
    ]


def _remove_agent_register_timer() -> None:
    if shutil.which("systemctl"):
        _run(["systemctl", "disable", "--now", "myapp-agent-register.timer"], capture=True)
    for path in (
        Path("/etc/myapp/agent-node-register.sh"),
        Path("/etc/systemd/system/myapp-agent-register.service"),
        Path("/etc/systemd/system/myapp-agent-register.timer"),
    ):
        path.unlink(missing_ok=True)
    if shutil.which("systemctl"):
        _run(["systemctl", "daemon-reload"], capture=True)


def _ensure_local_agent_node_registration_timer(*, dry_run: bool) -> int:
    agent_env = _parse_env(_secret_path("agent"))
    pull_enabled = str(agent_env.get("AGENT_NODE_PULL_ENABLED", "1")).strip().lower() in {"1", "true", "yes", "on"}
    cmd = _local_agent_node_register_command()
    script_path = Path("/etc/myapp/agent-node-register.sh")
    service_path = Path("/etc/systemd/system/myapp-agent-register.service")
    timer_path = Path("/etc/systemd/system/myapp-agent-register.timer")
    if pull_enabled:
        print("+ pull-mode agent-node registers itself through backend acquire; disable host register timer")
        if dry_run:
            return 0
        _remove_agent_register_timer()
        return 0
    script = "#!/usr/bin/env bash\nset -euo pipefail\n" + " ".join(shlex.quote(part) for part in cmd) + "\n"
    service = """[Unit]
Description=Register local MyApp agent node

[Service]
Type=oneshot
ExecStart=/bin/bash /etc/myapp/agent-node-register.sh
"""
    timer = """[Unit]
Description=Register local MyApp agent node periodically

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
Unit=myapp-agent-register.service

[Install]
WantedBy=timers.target
"""
    print("+ install local agent-node registration timer")
    if dry_run:
        print(script.rstrip())
        return 0
    script_path.parent.mkdir(parents=True, exist_ok=True)
    script_path.write_text(script, encoding="utf-8")
    os.chmod(script_path, 0o755)
    service_path.write_text(service, encoding="utf-8")
    timer_path.write_text(timer, encoding="utf-8")
    rc = _run(["systemctl", "daemon-reload"], capture=False).returncode
    if rc != 0:
        return rc
    rc = _run(["systemctl", "enable", "--now", "myapp-agent-register.timer"], capture=False).returncode
    if rc != 0:
        return rc
    rc = _run(["systemctl", "start", "myapp-agent-register.service"], capture=False).returncode
    if rc != 0:
        print("warning: local agent-node immediate registration failed; systemd timer will retry", file=sys.stderr)
    return 0


def _expires_label(value) -> str:
    try:
        seconds = int(value)
    except (TypeError, ValueError):
        return "-"
    if seconds <= 0:
        return "expired"
    return f"{seconds}s"


def _version_label(item: dict) -> str:
    value = str(item.get("build_version") or item.get("version") or item.get("build_commit") or "").strip()
    if not value or value.lower() == "unknown":
        return "-"
    if len(value) >= 12 and all(ch in "0123456789abcdefABCDEF" for ch in value):
        return value[:12]
    return value[:24]


def _print_agent_node_rows(data: dict, *, as_json: bool = False) -> int:
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0
    summary = data.get("summary") if isinstance(data.get("summary"), dict) else {}
    print(
        "agent nodes: "
        f"total={summary.get('total', 0)} "
        f"online={summary.get('online', 0)} "
        f"paused={summary.get('paused', 0)} "
        f"pending={summary.get('registered', 0)} "
        f"down={summary.get('down', 0)} "
        f"stale={summary.get('stale', 0)} "
        f"active_runs={summary.get('active_runs', 0)} "
        f"capacity={summary.get('capacity', 0)} "
        f"available={summary.get('available_capacity', summary.get('capacity', 0))} "
        f"queued={summary.get('queued', 0)} "
        f"qmax={summary.get('available_queue_max', summary.get('queue_max', 0))}/{summary.get('queue_max', 0)}"
    )
    rows = []
    for item in data.get("nodes") or []:
        rows.append(
            {
                "name": item.get("name") or item.get("display_name") or item.get("node_id", "-"),
                "node_id": item.get("node_id", "-"),
                "namespace": item.get("namespace") or ("public" if item.get("visibility", "public") == "public" else item.get("owner_user_id") or "-"),
                "host": item.get("host") or "-",
                "status": item.get("status", "-"),
                "version": _version_label(item),
                "active_runs": item.get("active_runs", "-"),
                "capacity": item.get("capacity", "-"),
                "queue_depth": item.get("queue_depth", "-"),
                "queue_max": item.get("queue_max", "-"),
                "provider_mode": item.get("provider_mode", "-"),
                "expires": _expires_label(item.get("expires_in_seconds")),
                "url": item.get("url", "-"),
            }
        )
    _print_table(
        rows,
        [
            ("name", "NAME"),
            ("node_id", "NODE"),
            ("namespace", "NS"),
            ("host", "HOST"),
            ("status", "STATUS"),
            ("version", "VERSION"),
            ("active_runs", "RUNS"),
            ("capacity", "CAP"),
            ("queue_depth", "QUEUE"),
            ("queue_max", "QMAX"),
            ("provider_mode", "KEY_SRC"),
            ("expires", "EXPIRES"),
            ("url", "URL"),
        ],
    )
    return 0


def _print_agent_node_status(data: dict, *, as_json: bool = False) -> int:
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0
    node = data.get("node") if isinstance(data.get("node"), dict) else {}
    if not node:
        print("(empty)")
        return 0
    _print_table(
        [
            {
                "name": node.get("name") or node.get("display_name") or node.get("node_id", "-"),
                "node_id": node.get("node_id", "-"),
                "namespace": node.get("namespace") or ("public" if node.get("visibility", "public") == "public" else node.get("owner_user_id") or "-"),
                "host": node.get("host") or "-",
                "status": node.get("status", "-"),
                "health": node.get("health", "-"),
                "version": _version_label(node),
                "active_runs": node.get("active_runs", "-"),
                "capacity": node.get("capacity", "-"),
                "queue_depth": node.get("queue_depth", "-"),
                "queue_max": node.get("queue_max", "-"),
                "provider_mode": node.get("provider_mode", "-"),
                "expires": _expires_label(node.get("expires_in_seconds")),
                "url": node.get("url", "-"),
            }
        ],
        [
            ("name", "NAME"),
            ("node_id", "NODE"),
            ("namespace", "NS"),
            ("host", "HOST"),
            ("status", "STATUS"),
            ("health", "HEALTH"),
            ("version", "VERSION"),
            ("active_runs", "RUNS"),
            ("capacity", "CAP"),
            ("queue_depth", "QUEUE"),
            ("queue_max", "QMAX"),
            ("provider_mode", "KEY_SRC"),
            ("expires", "EXPIRES"),
            ("url", "URL"),
        ],
    )
    detail = node.get("detail")
    if detail:
        print(f"detail: {detail}")
    pause_reason = node.get("pause_reason")
    if pause_reason:
        print(f"pause_reason: {pause_reason}")
    runs = node.get("runs") if isinstance(node.get("runs"), list) else []
    if runs:
        run_rows = []
        for item in runs:
            started = item.get("created_at") or item.get("started_at")
            finished = item.get("finished_at")
            run_rows.append(
                {
                    "run_id": item.get("run_id", "-"),
                    "session_id": item.get("session_id", "-"),
                    "agent_id": item.get("agent_id", "-"),
                    "provider_id": item.get("provider_id", "-"),
                    "status": item.get("status", "-"),
                    "duration": _duration_ms(started, finished),
                }
            )
        print("")
        print(f"active runs: {len(run_rows)}")
        _print_table(
            run_rows,
            [
                ("run_id", "RUN"),
                ("session_id", "SESSION"),
                ("agent_id", "AGENT"),
                ("provider_id", "PROVIDER"),
                ("status", "STATUS"),
                ("duration", "DURATION"),
            ],
        )
    return 0


def _redis_cli(args: list[str]) -> subprocess.CompletedProcess:
    redis_cmd = ["redis-cli", "--no-auth-warning", "--raw", *args]
    password = _parse_env(_secret_path("backend")).get("BACKEND_REDIS_PASSWORD", "")
    if password:
        return _run(["docker", "exec", "-e", f"REDISCLI_AUTH={password}", "myapp-ai-session-redis", *redis_cmd])
    return _run(["docker", "exec", "myapp-ai-session-redis", *redis_cmd])


def _redis_int(args: list[str]) -> int:
    proc = _redis_cli(args)
    if proc.returncode != 0:
        return 0
    try:
        return int((proc.stdout or "0").strip() or "0")
    except ValueError:
        return 0


def _redis_lines(args: list[str]) -> list[str]:
    proc = _redis_cli(args)
    if proc.returncode != 0:
        return []
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def _active_ai_run_summary() -> dict:
    now_ms = str(int(time.time() * 1000))
    worker_leases = _redis_int(["ZCOUNT", "ai:queue:running:leases", now_ms, "+inf"])
    pull_pending = _redis_int(["LLEN", "ai:agent_pull:pending"])
    pull_running = 0
    for key in _redis_lines(["KEYS", "ai:agent_pull:node_running:*"]):
        pull_running += _redis_int(["SCARD", key])
    local_agent_containers = len(_active_local_agent_container_names())
    active_total = max(worker_leases, pull_running, local_agent_containers)
    return {
        "active_total": active_total,
        "worker_leases": worker_leases,
        "pull_running": pull_running,
        "pull_pending": pull_pending,
        "local_agent_containers": local_agent_containers,
    }


def _deploy_may_interrupt_ai_runs(names: list[str]) -> bool:
    return any(name in {"ai-worker", "agent-node"} for name in names)


def _guard_active_ai_runs_for_deploy(args, names: list[str]) -> int:
    if getattr(args, "dry_run", False) or getattr(args, "force", False):
        return 0
    if not _deploy_may_interrupt_ai_runs(names):
        return 0
    summary = _active_ai_run_summary()
    if int(summary.get("active_total") or 0) <= 0:
        return 0
    print(
        "refusing to deploy services that can interrupt active AI generation; "
        "wait for runs to finish or pass --force",
        file=sys.stderr,
    )
    print(
        "active summary: "
        f"worker_leases={summary['worker_leases']} "
        f"pull_running={summary['pull_running']} "
        f"local_agent_containers={summary['local_agent_containers']} "
        f"pull_pending={summary['pull_pending']}",
        file=sys.stderr,
    )
    return 1


def _active_local_agent_container_names() -> list[str]:
    proc = _run(["docker", "ps", "--filter", "name=myapp-agent-", "--format", "{{.Names}}"])
    if proc.returncode != 0:
        return []
    return [
        line.strip()
        for line in proc.stdout.splitlines()
        if line.strip() and not line.strip().startswith("myapp-agent-node")
    ]


def _local_agent_node_url(agent_env: dict[str, str]) -> str:
    port = str(agent_env.get("AGENT_NODE_PORT") or "5590").strip() or "5590"
    return f"http://127.0.0.1:{port}"


def _local_agent_node_token(agent_env: dict[str, str]) -> str:
    return os.environ.get("AGENT_NODE_TOKEN") or agent_env.get("AGENT_NODE_TOKEN", "")


def _set_local_agent_node_limits(args) -> int:
    agent_env = _parse_env(_secret_path("agent"))
    current_capacity = agent_env.get("AGENT_NODE_CAPACITY", "1")
    current_queue_max = agent_env.get("AGENT_NODE_QUEUE_MAX", current_capacity)
    capacity_value = getattr(args, "capacity", None)
    queue_max_value = getattr(args, "queue_max", None)
    if capacity_value is None and queue_max_value is None:
        print("pass --capacity and/or --queue-max", file=sys.stderr)
        return 2
    try:
        capacity = max(1, min(100, int(capacity_value if capacity_value is not None else current_capacity)))
    except (TypeError, ValueError):
        print("capacity must be an integer from 1 to 100", file=sys.stderr)
        return 2
    try:
        queue_max = max(0, min(10000, int(queue_max_value if queue_max_value is not None else current_queue_max)))
    except (TypeError, ValueError):
        print("queue max must be an integer from 0 to 10000", file=sys.stderr)
        return 2
    agent_env["AGENT_NODE_CAPACITY"] = str(capacity)
    agent_env["AGENT_NODE_QUEUE_MAX"] = str(queue_max)
    _write_env(_secret_path("agent"), agent_env)
    _safe_write_default_config_snapshot()
    node_url = _local_agent_node_url(agent_env)
    data, status, error = _agent_node_request_json(
        node_url,
        "/admin/limits",
        method="POST",
        payload={"capacity": capacity, "queue_max": queue_max},
        token=_local_agent_node_token(agent_env),
        timeout=5.0,
    )
    if not data:
        print(
            "agent-node limits were saved, but live hot update failed: "
            f"{status or '-'} {error}. Start or update agent-node and retry.",
            file=sys.stderr,
        )
        return 1
    previous = data.get("previous") or {}
    limits = data.get("limits") or {}
    running = data.get("running", "-")
    print(
        "updated live agent-node limits: "
        f"capacity {previous.get('capacity', current_capacity)} -> {limits.get('capacity', capacity)}, "
        f"queue_max {previous.get('queue_max', current_queue_max)} -> {limits.get('queue_max', queue_max)}, "
        f"active_runs={running}",
        flush=True,
    )
    backend_url = (args.backend or "").rstrip("/")
    if backend_url:
        time.sleep(1)
        data, status, error = _agent_node_request_json(
            backend_url,
            "/api/ai/agent_nodes?probe=1",
            token=_agent_node_registry_token(args),
        )
        if data:
            return _print_agent_node_rows(data, as_json=args.json)
        print(f"agent-node capacity updated, but status fetch failed: {status or '-'} {error}", file=sys.stderr)
    return 0


def cmd_agent_node(args) -> int:
    if args.agent_node_cmd == "add":
        return _print_agent_add_script(args)
    if args.agent_node_cmd == "join":
        return _join_agent_node(args)
    if args.agent_node_cmd == "private":
        if getattr(args, "private_cmd", "") == "ls":
            return _list_private_agent_nodes(args)
        if getattr(args, "private_cmd", "") == "status":
            return _status_private_agent_node(args)
        if getattr(args, "private_cmd", "") == "join":
            return _join_private_agent_node(args)
        print("private command is required", file=sys.stderr)
        return 2
    if args.agent_node_cmd == "register":
        return _register_agent_node(args)
    if args.agent_node_cmd in {"capacity", "limits"}:
        return _set_local_agent_node_limits(args)

    backend_url = _agent_node_backend_url(args)
    if not backend_url:
        print("backend url is required; pass --backend or set domains.backend", file=sys.stderr)
        return 2
    token = _agent_node_registry_token(args)

    if args.agent_node_cmd == "ls":
        probe = "0" if args.no_probe else "1"
        namespace = quote(str(getattr(args, "namespace", None) or "public"), safe="")
        data, status, error = _agent_node_request_json(
            backend_url,
            f"/api/ai/agent_nodes?probe={probe}&namespace={namespace}",
            token=token,
        )
        if not data:
            print(f"agent-node ls failed: {status or '-'} {error}", file=sys.stderr)
            return 1
        return _print_agent_node_rows(data, as_json=args.json)

    if args.agent_node_cmd == "status":
        if not args.node_id:
            probe = "0" if args.no_probe else "1"
            namespace = quote(str(getattr(args, "namespace", None) or "public"), safe="")
            data, status, error = _agent_node_request_json(
                backend_url,
                f"/api/ai/agent_nodes?probe={probe}&namespace={namespace}",
                token=token,
            )
            if not data:
                print(f"agent-node status failed: {status or '-'} {error}", file=sys.stderr)
                return 1
            return _print_agent_node_rows(data, as_json=args.json)
        data, status, error = _agent_node_request_json(
            backend_url,
            f"/api/ai/agent_nodes/{quote(args.node_id, safe='')}?runs=1",
            token=token,
        )
        if not data:
            print(f"agent-node status failed: {status or '-'} {error}", file=sys.stderr)
            return 1
        return _print_agent_node_status(data, as_json=args.json)

    if args.agent_node_cmd == "rm":
        data, status, error = _agent_node_request_json(
            backend_url,
            f"/api/ai/agent_nodes/{quote(args.node_id, safe='')}",
            method="DELETE",
            token=token,
        )
        if not data:
            print(f"agent-node rm failed: {status or '-'} {error}", file=sys.stderr)
            return 1
        print(json.dumps(data, ensure_ascii=False))
        return 0

    if args.agent_node_cmd in {"pause", "resume"}:
        node_id = args.node_id or _parse_env(_secret_path("agent")).get("AGENT_NODE_ID") or ""
        if not node_id:
            print("node_id is required, or configure AGENT_NODE_ID in agent.env", file=sys.stderr)
            return 2
        body = {}
        if args.agent_node_cmd == "pause" and args.reason:
            body["reason"] = args.reason
        data, status, error = _agent_node_request_json(
            backend_url,
            f"/api/ai/agent_nodes/{quote(node_id, safe='')}/{args.agent_node_cmd}",
            method="POST",
            payload=body,
            token=token,
        )
        if not data:
            print(f"agent-node {args.agent_node_cmd} failed: {status or '-'} {error}", file=sys.stderr)
            return 1
        return _print_agent_node_status(data, as_json=args.json)

    return 2


def cmd_agent(args) -> int:
    if args.agent_cmd == "add":
        return _print_agent_add_script(args)
    if args.agent_cmd == "register":
        return _register_agent_node(args)
    if args.agent_cmd == "ls":
        agent_env = _parse_env(_secret_path("agent"))
        default_node_url = f"http://127.0.0.1:{agent_env.get('AGENT_NODE_PORT', '5590') or '5590'}"
        node_url = (args.url or default_node_url).rstrip("/")
        token = os.environ.get("AGENT_NODE_TOKEN") or _parse_env(_secret_path("agent")).get("AGENT_NODE_TOKEN", "")
        data = _http_json(f"{node_url}/v1/runs?history=0", token=token)
        if data and isinstance(data.get("runs"), list):
            rows = []
            for item in data["runs"]:
                started = item.get("created_at") or item.get("started_at")
                finished = item.get("finished_at")
                rows.append({
                    "run_id": item.get("run_id", "-"),
                    "session_id": item.get("session_id", "-"),
                    "agent_id": item.get("agent_id", "-"),
                    "provider_id": item.get("provider_id", "-"),
                    "status": item.get("status", "-"),
                    "returncode": item.get("returncode", "-"),
                    "duration": _duration_ms(started, finished),
                })
            active = [row for row in rows if row["status"] in {"starting", "running"}]
            print(f"active agent runs: {len(active)}")
            if active:
                _print_table(
                    active,
                    [
                        ("run_id", "RUN"),
                        ("session_id", "SESSION"),
                        ("agent_id", "AGENT"),
                        ("provider_id", "PROVIDER"),
                        ("status", "STATUS"),
                        ("duration", "DURATION"),
                    ],
                )
            return 0
    rows = []
    proc = _run(["docker", "ps", "--filter", "name=myapp-agent-", "--format", "{{json .}}"])
    if proc.returncode == 0:
        for line in proc.stdout.splitlines():
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            name = item.get("Names", "-")
            if str(name).startswith("myapp-agent-node"):
                continue
            rows.append({"container": name, "status": item.get("Status", "-")})
    print(f"running agent containers: {sum('Up ' in row['status'] for row in rows)}")
    if rows:
        _print_table(rows, [("container", "CONTAINER"), ("status", "STATUS")])
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = _new_parser(
        prog="myapp-ctl",
        usage=_tx(
            "myapp-ctl [--lang LANG] <command> [args]",
            zh="myapp-ctl [--lang LANG] <命令> [参数]",
            de="myapp-ctl [--lang LANG] <Befehl> [Argumente]",
            es="myapp-ctl [--lang LANG] <comando> [args]",
        ),
        description=_tx(
            "MyApp backend control CLI. Run `myapp-ctl <command> --help` for command details.",
            zh="MyApp 后端控制 CLI。运行 `myapp-ctl <命令> --help` 查看命令详情。",
            de="MyApp Backend-Kontroll-CLI. Details mit `myapp-ctl <Befehl> --help`.",
            es="CLI de control backend de MyApp. Usa `myapp-ctl <comando> --help` para detalles.",
        ),
    )
    parser.add_argument(
        "--lang",
        choices=["zh", "en", "de", "es"],
        metavar="LANG",
        help=_tx(
            "override CLI language for this command: zh, en, de, es",
            zh="覆盖本次命令语言: zh, en, de, es",
            de="CLI-Sprache fuer diesen Befehl setzen: zh, en, de, es",
            es="cambiar el idioma de este comando: zh, en, de, es",
        ),
    )
    sub = _add_subcommands(parser, "cmd", required=False)
    status = sub.add_parser(
        "status",
        help=_tx("show service status", zh="查看服务状态", de="Dienststatus anzeigen", es="mostrar estado de servicios"),
        usage=_tx("myapp-ctl status [service ...] [--json]", zh="myapp-ctl status [服务 ...] [--json]", de="myapp-ctl status [Dienst ...] [--json]", es="myapp-ctl status [servicio ...] [--json]"),
    )
    status.add_argument(
        "services",
        nargs="*",
        help=_tx("optional service names; omitted means all services", zh="可选服务名；省略表示所有服务", de="optionale Dienstnamen; ohne Angabe alle Dienste", es="nombres de servicio opcionales; omitido significa todos"),
    )
    status.add_argument("--json", action="store_true")
    status.set_defaults(func=cmd_status)
    log = sub.add_parser(
        "log",
        help=_tx("show service logs", zh="查看服务日志", de="Dienstlogs anzeigen", es="mostrar logs de servicio"),
        usage=_tx("myapp-ctl log <service> [options]", zh="myapp-ctl log <服务> [选项]", de="myapp-ctl log <Dienst> [Optionen]", es="myapp-ctl log <servicio> [opciones]"),
    )
    log.add_argument("service")
    log.add_argument("-n", "--lines", type=int, default=80)
    log.add_argument("-f", "--follow", action="store_true")
    log.set_defaults(func=cmd_log)
    image = sub.add_parser(
        "image",
        help=_tx("manage Docker images", zh="管理 Docker 镜像", de="Docker-Images verwalten", es="gestionar imagenes Docker"),
        usage=_tx("myapp-ctl image <command> [args]", zh="myapp-ctl image <命令> [参数]", de="myapp-ctl image <Befehl> [Argumente]", es="myapp-ctl image <comando> [args]"),
    )
    image_sub = _add_subcommands(image, "image_cmd")
    image_sub.add_parser(
        "ls",
        help=_tx("list configured images", zh="列出已配置镜像", de="konfigurierte Images auflisten", es="listar imagenes configuradas"),
    ).set_defaults(func=cmd_image)
    for action in ("build", "pull", "push"):
        image_action = image_sub.add_parser(
            action,
            help=_tx(f"{action} one image target or all targets", zh=f"{action} 单个镜像目标或全部目标", de=f"{action} ein Image-Ziel oder alle Ziele", es=f"{action} un destino de imagen o todos"),
            usage=_tx(f"myapp-ctl image {action} [target] [--dry-run]", zh=f"myapp-ctl image {action} [目标] [--dry-run]", de=f"myapp-ctl image {action} [Ziel] [--dry-run]", es=f"myapp-ctl image {action} [destino] [--dry-run]"),
        )
        image_action.add_argument(
            "target",
            nargs="?",
            default="all",
            choices=["all", *IMAGE_TARGETS.keys()],
            metavar="TARGET",
            help=_tx("image target: all, agent-runtime, agent-node, backend", zh="镜像目标: all, agent-runtime, agent-node, backend", de="Image-Ziel: all, agent-runtime, agent-node, backend", es="destino de imagen: all, agent-runtime, agent-node, backend"),
        )
        image_action.add_argument("--dry-run", action="store_true")
        image_action.set_defaults(func=cmd_image)
    deploy = sub.add_parser(
        "deploy",
        help=_tx("deploy services", zh="部署服务", de="Dienste deployen", es="desplegar servicios"),
        usage=_tx("myapp-ctl deploy [options] [targets ...]", zh="myapp-ctl deploy [选项] [目标 ...]", de="myapp-ctl deploy [Optionen] [Ziele ...]", es="myapp-ctl deploy [opciones] [destinos ...]"),
    )
    deploy.add_argument("targets", nargs="*", help=_tx("service/group names; omitted means all", zh="服务或分组名；省略表示全部", de="Dienst- oder Gruppennamen; ohne Angabe alle", es="nombres de servicio o grupo; omitido significa todos"))
    deploy.add_argument(
        "--group",
        choices=["infra", "agent", "core", "openim", "supabase"],
        metavar="GROUP",
        help=_tx("service group: infra, agent, core, openim, supabase", zh="服务分组: infra, agent, core, openim, supabase", de="Dienstgruppe: infra, agent, core, openim, supabase", es="grupo de servicios: infra, agent, core, openim, supabase"),
    )
    deploy.add_argument("--build", action="store_true", help=_tx("build required images from the local source tree before deploy", zh="部署前从本地源码构建所需镜像", de="benoetigte Images vor dem Deploy aus lokalem Quellcode bauen", es="construir imagenes necesarias desde el codigo local antes de desplegar"))
    deploy.add_argument("--pull", action="store_true", help=_tx("pull required images before deploy", zh="部署前拉取所需镜像", de="benoetigte Images vor dem Deploy laden", es="descargar imagenes necesarias antes de desplegar"))
    deploy.add_argument("--plan", action="store_true", help=_tx("print deployment plan only", zh="仅打印部署计划", de="nur den Deployment-Plan ausgeben", es="solo imprimir el plan de despliegue"))
    deploy.add_argument("--dry-run", action="store_true")
    deploy.add_argument("--force", action="store_true", help=_tx("deploy even when active AI runs may be interrupted", zh="即使可能打断活跃 AI 任务也继续部署", de="auch deployen, wenn aktive KI-Laeufe unterbrochen werden koennen", es="desplegar aunque pueda interrumpir tareas activas de IA"))
    deploy.add_argument("--host", help=_tx("public host/IP used when first-run stack secrets must be generated", zh="首次生成栈密钥时使用的公网域名或 IP", de="oeffentlicher Host/IP fuer erstmalige Stack-Secrets", es="host/IP publico usado al generar secretos iniciales"))
    deploy.add_argument("--data-root", help=_tx("local persistent data root, for example /mnt/myapp", zh="本地持久化数据根目录，例如 /mnt/myapp", de="lokales persistentes Datenverzeichnis, z.B. /mnt/myapp", es="raiz de datos persistentes local, por ejemplo /mnt/myapp"))
    deploy.add_argument("--no-setup", action="store_true", help=_tx("fail instead of launching first-run interactive setup", zh="缺少配置时直接失败，不启动首次交互配置", de="bei fehlender Konfiguration fehlschlagen statt Setup zu starten", es="fallar si falta configuracion, sin iniciar setup interactivo"))
    deploy.add_argument("--no-client-env", action="store_true", help=_tx("do not print client environment JSON/QR after a full deploy", zh="完整部署后不打印客户端环境 JSON/二维码", de="nach vollem Deploy kein Client-Environment JSON/QR ausgeben", es="no imprimir JSON/QR de entorno de cliente tras despliegue completo"))
    deploy.add_argument("--client-env-host", help=_tx("host/IP to use in the post-deploy client environment JSON", zh="部署后客户端环境 JSON 使用的域名或 IP", de="Host/IP fuer das Client-Environment JSON nach dem Deploy", es="host/IP para el JSON de entorno de cliente tras desplegar"))
    deploy.add_argument("--client-env-name", help=_tx("name shown in the post-deploy client environment JSON", zh="部署后客户端环境 JSON 展示的名称", de="Name im Client-Environment JSON nach dem Deploy", es="nombre mostrado en el JSON de entorno tras desplegar"))
    deploy.add_argument("--no-terminal-qr", action="store_true", help=_tx("do not print an ANSI QR code after a full deploy", zh="完整部署后不在终端打印 ANSI 二维码", de="nach vollem Deploy keinen ANSI-QR im Terminal ausgeben", es="no imprimir QR ANSI en terminal tras despliegue completo"))
    deploy.add_argument("--no-test-user", action="store_true", help=_tx("skip the interactive test@example.com user prompt", zh="跳过交互式 test@example.com 测试用户创建", de="interaktive Abfrage fuer test@example.com ueberspringen", es="omitir pregunta interactiva para usuario test@example.com"))
    deploy.add_argument("--test-user-email", default="test@example.com", help=_tx("email for the optional deploy-time test user", zh="部署时可选测试用户邮箱", de="E-Mail fuer optionalen Testbenutzer beim Deploy", es="email del usuario de prueba opcional"))
    deploy.add_argument("--test-user-username", default="test", help=_tx("username for the optional deploy-time test user", zh="部署时可选测试用户用户名", de="Benutzername fuer optionalen Testbenutzer beim Deploy", es="nombre del usuario de prueba opcional"))
    deploy.add_argument("--test-user-password-env", default="MYAPP_TEST_USER_PASSWORD", help=_tx("environment variable used for non-interactive test user password", zh="非交互测试用户密码的环境变量名", de="Umgebungsvariable fuer nichtinteraktives Testbenutzer-Passwort", es="variable de entorno para la contrasena no interactiva del usuario de prueba"))
    deploy.add_argument("--test-user-password-file", help=_tx("file containing the non-interactive test user password", zh="包含非交互测试用户密码的文件", de="Datei mit nichtinteraktivem Testbenutzer-Passwort", es="archivo con la contrasena no interactiva del usuario de prueba"))
    deploy.set_defaults(func=cmd_deploy)
    setup = sub.add_parser("setup", help=_tx("interactive first-run setup for AI providers and optional channels", zh="首次交互配置 AI 供应商和可选通道", de="interaktives Erst-Setup fuer KI-Anbieter und optionale Kanaele", es="setup inicial interactivo para proveedores de IA y canales opcionales"), usage=_tx("myapp-ctl setup [options]", zh="myapp-ctl setup [选项]", de="myapp-ctl setup [Optionen]", es="myapp-ctl setup [opciones]"))
    setup.add_argument("--host", help=_tx("public host/IP used in generated local service URLs", zh="生成本地服务 URL 时使用的公网域名或 IP", de="oeffentlicher Host/IP fuer generierte lokale Dienst-URLs", es="host/IP publico usado en URLs locales generadas"))
    setup.add_argument("--data-root", help=_tx("local persistent data root, for example /mnt/myapp", zh="本地持久化数据根目录，例如 /mnt/myapp", de="lokales persistentes Datenverzeichnis, z.B. /mnt/myapp", es="raiz local persistente, por ejemplo /mnt/myapp"))
    setup.add_argument("--force", action="store_true", help=_tx("replace existing setup config instead of offering to keep it", zh="替换现有配置，不再询问是否保留", de="bestehende Setup-Konfiguration ersetzen", es="reemplazar configuracion existente sin preguntar"))
    setup.add_argument("--no-ai", action="store_true", help=_tx("skip AI provider setup", zh="跳过 AI 供应商配置", de="KI-Anbieter-Setup ueberspringen", es="omitir setup de proveedor de IA"))
    setup.add_argument("--no-asr", action="store_true", help=_tx("skip optional ByteDance ASR setup", zh="跳过可选 ByteDance ASR 配置", de="optionales ByteDance-ASR-Setup ueberspringen", es="omitir setup opcional de ByteDance ASR"))
    setup.add_argument("--no-email", action="store_true", help=_tx("skip optional Supabase SMTP email setup", zh="跳过可选 Supabase SMTP 邮件配置", de="optionales Supabase-SMTP-Mail-Setup ueberspringen", es="omitir setup opcional de correo SMTP Supabase"))
    setup.add_argument("--no-push", action="store_true", help=_tx("skip optional APNs/FCM/GeTui setup", zh="跳过可选 APNs/FCM/个推配置", de="optionales APNs/FCM/GeTui-Setup ueberspringen", es="omitir setup opcional de APNs/FCM/GeTui"))
    setup.set_defaults(func=cmd_setup)
    update = sub.add_parser("update", help=_tx("pull the source repository and refresh myapp-ctl", zh="拉取源码仓库并刷新 myapp-ctl", de="Quellrepository aktualisieren und myapp-ctl erneuern", es="actualizar repositorio fuente y refrescar myapp-ctl"), usage=_tx("myapp-ctl update [options]", zh="myapp-ctl update [选项]", de="myapp-ctl update [Optionen]", es="myapp-ctl update [opciones]"))
    update.add_argument("--source", help=_tx("source checkout path; default reads ctl config or /opt/myapp/current", zh="源码检出路径；默认读取 ctl 配置或 /opt/myapp/current", de="Pfad zum Source-Checkout; Standard aus ctl-Konfiguration oder /opt/myapp/current", es="ruta del checkout fuente; por defecto lee config ctl o /opt/myapp/current"))
    update.add_argument("--no-pull", action="store_true", help=_tx("skip git pull and only reinstall from the local checkout", zh="跳过 git pull，仅从本地检出重新安装", de="git pull ueberspringen und nur lokal neu installieren", es="omitir git pull y reinstalar solo desde checkout local"))
    update.set_defaults(func=cmd_update)
    uninstall = sub.add_parser("uninstall", help=_tx("stop and remove deployed services", zh="停止并移除已部署服务", de="deployte Dienste stoppen und entfernen", es="detener y eliminar servicios desplegados"), usage=_tx("myapp-ctl uninstall --yes [options]", zh="myapp-ctl uninstall --yes [选项]", de="myapp-ctl uninstall --yes [Optionen]", es="myapp-ctl uninstall --yes [opciones]"))
    uninstall.add_argument("--yes", action="store_true", help=_tx("required confirmation for destructive cleanup", zh="破坏性清理所需确认", de="erforderliche Bestaetigung fuer destruktive Bereinigung", es="confirmacion requerida para limpieza destructiva"))
    uninstall.add_argument("--purge", action="store_true", help=_tx("remove containers, legacy compose volumes, secrets, install config, and app images; preserve data root", zh="移除容器、旧 compose volume、密钥、安装配置和应用镜像；保留 data root", de="Container, alte Compose-Volumes, Secrets, Install-Konfiguration und Images entfernen; data root behalten", es="eliminar contenedores, volumenes compose legados, secretos, config e imagenes; conservar data root"))
    uninstall.add_argument("--volumes", action="store_true", help=_tx("remove legacy compose named volumes while stopping services; bind-path data is preserved", zh="停止服务时移除旧 compose 命名 volume；保留 bind-path 数据", de="alte benannte Compose-Volumes beim Stoppen entfernen; Bind-Pfad-Daten bleiben", es="eliminar volumenes compose legados al detener; datos bind-path se conservan"))
    uninstall.add_argument("--state", action="store_true", help=_tx("deprecated; data-root state is always preserved", zh="已废弃；data-root state 始终保留", de="veraltet; data-root state bleibt immer erhalten", es="obsoleto; data-root state siempre se conserva"))
    uninstall.add_argument("--logs", action="store_true", help=_tx("deprecated; data-root logs are always preserved", zh="已废弃；data-root logs 始终保留", de="veraltet; data-root logs bleiben immer erhalten", es="obsoleto; data-root logs siempre se conservan"))
    uninstall.add_argument("--secrets", action="store_true", help=_tx("remove /etc/myapp/secrets.d", zh="移除 /etc/myapp/secrets.d", de="/etc/myapp/secrets.d entfernen", es="eliminar /etc/myapp/secrets.d"))
    uninstall.add_argument("--install-files", action="store_true", help=_tx("remove installed compose/config files", zh="移除已安装的 compose/config 文件", de="installierte Compose-/Config-Dateien entfernen", es="eliminar archivos compose/config instalados"))
    uninstall.add_argument("--images", action="store_true", help=_tx("remove configured MyApp Docker images", zh="移除已配置 MyApp Docker 镜像", de="konfigurierte MyApp Docker-Images entfernen", es="eliminar imagenes Docker MyApp configuradas"))
    uninstall.add_argument("--remove-ctl", action="store_true", help=_tx("remove the myapp-ctl executable after cleanup", zh="清理后移除 myapp-ctl 可执行文件", de="myapp-ctl nach der Bereinigung entfernen", es="eliminar ejecutable myapp-ctl tras la limpieza"))
    uninstall.add_argument("--dry-run", action="store_true")
    uninstall.set_defaults(func=cmd_uninstall)
    restart = sub.add_parser("restart", help=_tx("restart services", zh="重启服务", de="Dienste neu starten", es="reiniciar servicios"), usage=_tx("myapp-ctl restart [options] [targets ...]", zh="myapp-ctl restart [选项] [目标 ...]", de="myapp-ctl restart [Optionen] [Ziele ...]", es="myapp-ctl restart [opciones] [destinos ...]"))
    restart.add_argument("targets", nargs="*", help=_tx("service/group names; omitted means all", zh="服务或分组名；省略表示全部", de="Dienst- oder Gruppennamen; ohne Angabe alle", es="nombres de servicio o grupo; omitido significa todos"))
    restart.add_argument(
        "--group",
        choices=["infra", "agent", "core", "openim", "supabase"],
        metavar="GROUP",
        help=_tx("service group: infra, agent, core, openim, supabase", zh="服务分组: infra, agent, core, openim, supabase", de="Dienstgruppe: infra, agent, core, openim, supabase", es="grupo de servicios: infra, agent, core, openim, supabase"),
    )
    restart.set_defaults(func=cmd_restart)
    secret = sub.add_parser("secret", help=_tx("manage host-local secrets", zh="管理本机密钥", de="host-lokale Secrets verwalten", es="gestionar secretos locales del host"), usage=_tx("myapp-ctl secret <command> [args]", zh="myapp-ctl secret <命令> [参数]", de="myapp-ctl secret <Befehl> [Argumente]", es="myapp-ctl secret <comando> [args]"))
    secret_sub = _add_subcommands(secret, "secret_cmd")
    secret_sub.add_parser("ls", help=_tx("list secret groups", zh="列出密钥分组", de="Secret-Gruppen auflisten", es="listar grupos de secretos"), usage="myapp-ctl secret ls").set_defaults(func=cmd_secret)
    secret_init = secret_sub.add_parser("init-stack", help=_tx("initialize stack secrets", zh="初始化栈密钥", de="Stack-Secrets initialisieren", es="inicializar secretos del stack"), usage=_tx("myapp-ctl secret init-stack [options]", zh="myapp-ctl secret init-stack [选项]", de="myapp-ctl secret init-stack [Optionen]", es="myapp-ctl secret init-stack [opciones]"))
    secret_init.add_argument("--host", help=_tx("public host/IP used in generated local service URLs", zh="生成本地服务 URL 时使用的公网域名或 IP", de="oeffentlicher Host/IP fuer generierte lokale Dienst-URLs", es="host/IP publico usado en URLs locales generadas"))
    secret_init.add_argument("--data-root", help=_tx("local persistent data root, for example /mnt/myapp", zh="本地持久化数据根目录，例如 /mnt/myapp", de="lokales persistentes Datenverzeichnis, z.B. /mnt/myapp", es="raiz local persistente, por ejemplo /mnt/myapp"))
    secret_init.add_argument("--force", action="store_true", help=_tx("regenerate stack secrets managed by myapp-ctl", zh="重新生成 myapp-ctl 管理的栈密钥", de="von myapp-ctl verwaltete Stack-Secrets neu erzeugen", es="regenerar secretos del stack gestionados por myapp-ctl"))
    secret_init.set_defaults(func=cmd_secret)
    secret_set = secret_sub.add_parser("set", help=_tx("set one or more secret values", zh="设置一个或多个密钥值", de="einen oder mehrere Secret-Werte setzen", es="definir uno o mas valores secretos"), usage=_tx("myapp-ctl secret set <group> <KEY=VALUE ...>", zh="myapp-ctl secret set <分组> <KEY=VALUE ...>", de="myapp-ctl secret set <Gruppe> <KEY=VALUE ...>", es="myapp-ctl secret set <grupo> <KEY=VALUE ...>"))
    secret_set.add_argument("group")
    secret_set.add_argument("items", nargs="+")
    secret_set.set_defaults(func=cmd_secret)
    secret_generate = secret_sub.add_parser("generate", help=_tx("generate random secret values", zh="生成随机密钥值", de="zufaellige Secret-Werte erzeugen", es="generar valores secretos aleatorios"), usage=_tx("myapp-ctl secret generate <group> <key ...> [options]", zh="myapp-ctl secret generate <分组> <key ...> [选项]", de="myapp-ctl secret generate <Gruppe> <Key ...> [Optionen]", es="myapp-ctl secret generate <grupo> <key ...> [opciones]"))
    secret_generate.add_argument("group")
    secret_generate.add_argument("keys", nargs="+")
    secret_generate.add_argument("--bytes", type=int, default=32)
    secret_generate.set_defaults(func=cmd_secret)
    secret_get = secret_sub.add_parser("get", help=_tx("read one secret value", zh="读取一个密钥值", de="einen Secret-Wert lesen", es="leer un valor secreto"), usage=_tx("myapp-ctl secret get <group> <key> [--show]", zh="myapp-ctl secret get <分组> <key> [--show]", de="myapp-ctl secret get <Gruppe> <Key> [--show]", es="myapp-ctl secret get <grupo> <key> [--show]"))
    secret_get.add_argument("group")
    secret_get.add_argument("key")
    secret_get.add_argument("--show", action="store_true")
    secret_get.set_defaults(func=cmd_secret)
    secret_rm = secret_sub.add_parser("rm", help=_tx("remove one or more secret values", zh="移除一个或多个密钥值", de="einen oder mehrere Secret-Werte entfernen", es="eliminar uno o mas valores secretos"), usage=_tx("myapp-ctl secret rm <group> <key ...>", zh="myapp-ctl secret rm <分组> <key ...>", de="myapp-ctl secret rm <Gruppe> <Key ...>", es="myapp-ctl secret rm <grupo> <key ...>"))
    secret_rm.add_argument("group")
    secret_rm.add_argument("keys", nargs="+")
    secret_rm.set_defaults(func=cmd_secret)
    config = sub.add_parser("config", help=_tx("view, export, import, or set myapp-ctl host configuration", zh="查看、导出、导入或设置 myapp-ctl 主机配置", de="myapp-ctl Host-Konfiguration anzeigen, exportieren, importieren oder setzen", es="ver, exportar, importar o configurar el host myapp-ctl"), usage=_tx("myapp-ctl config <command> [args]", zh="myapp-ctl config <命令> [参数]", de="myapp-ctl config <Befehl> [Argumente]", es="myapp-ctl config <comando> [args]"))
    config_sub = _add_subcommands(config, "config_cmd")
    config_view = config_sub.add_parser("view", help=_tx("print current ctl configuration", zh="打印当前 ctl 配置", de="aktuelle ctl-Konfiguration ausgeben", es="imprimir configuracion ctl actual"), usage=_tx("myapp-ctl config view [--show-secrets]", zh="myapp-ctl config view [--show-secrets]", de="myapp-ctl config view [--show-secrets]", es="myapp-ctl config view [--show-secrets]"))
    config_view.add_argument("--show-secrets", action="store_true", help=_tx("print real secret values instead of redacted values", zh="打印真实密钥值而不是脱敏值", de="echte Secret-Werte statt redigierter Werte ausgeben", es="imprimir secretos reales en lugar de valores ocultos"))
    config_view.set_defaults(func=cmd_config)
    config_export = config_sub.add_parser("export", help=_tx("export ctl config and secrets", zh="导出 ctl 配置和密钥", de="ctl-Konfiguration und Secrets exportieren", es="exportar config ctl y secretos"), usage=_tx("myapp-ctl config export --out <path> [options]", zh="myapp-ctl config export --out <路径> [选项]", de="myapp-ctl config export --out <Pfad> [Optionen]", es="myapp-ctl config export --out <ruta> [opciones]"))
    config_export.add_argument("--out", required=True, help=_tx("output file path; use .json or .yaml extension as preferred", zh="输出文件路径；可使用 .json 或 .yaml 扩展名", de="Ausgabepfad; .json- oder .yaml-Endung moeglich", es="ruta de salida; usa extension .json o .yaml"))
    config_export.add_argument(
        "--format",
        choices=["auto", "json", "yaml"],
        default="auto",
        metavar="FORMAT",
        help=_tx("serialization format: auto, json, yaml", zh="序列化格式: auto, json, yaml", de="Serialisierungsformat: auto, json, yaml", es="formato de serializacion: auto, json, yaml"),
    )
    config_export.add_argument("--redacted", action="store_true", help=_tx("export a non-restorable redacted bundle", zh="导出不可恢复的脱敏包", de="nicht wiederherstellbares redigiertes Bundle exportieren", es="exportar paquete oculto no restaurable"))
    config_export.set_defaults(func=cmd_config)
    config_import = config_sub.add_parser("import", help=_tx("import a ctl config bundle", zh="导入 ctl 配置包", de="ctl-Konfigurationsbundle importieren", es="importar paquete de configuracion ctl"), usage=_tx("myapp-ctl config import <path> --yes", zh="myapp-ctl config import <路径> --yes", de="myapp-ctl config import <Pfad> --yes", es="myapp-ctl config import <ruta> --yes"))
    config_import.add_argument("path", help=_tx("bundle created by myapp-ctl config export", zh="由 myapp-ctl config export 创建的配置包", de="Bundle von myapp-ctl config export", es="paquete creado por myapp-ctl config export"))
    config_import.add_argument("--yes", action="store_true", help=_tx("confirm overwriting local config and secrets", zh="确认覆盖本地配置和密钥", de="Ueberschreiben lokaler Konfiguration und Secrets bestaetigen", es="confirmar sobrescritura de config y secretos locales"))
    config_import.set_defaults(func=cmd_config)
    config_lang = config_sub.add_parser("lang", help=_tx("view or set CLI language", zh="查看或设置 CLI 语言", de="CLI-Sprache anzeigen oder setzen", es="ver o establecer idioma del CLI"), usage=_tx("myapp-ctl config lang [zh|en|de|es]", zh="myapp-ctl config lang [zh|en|de|es]", de="myapp-ctl config lang [zh|en|de|es]", es="myapp-ctl config lang [zh|en|de|es]"))
    config_lang.add_argument("language", nargs="?", help=_tx("zh, en, de, or es", zh="zh、en、de 或 es", de="zh, en, de oder es", es="zh, en, de o es"))
    config_lang.set_defaults(func=cmd_config)
    domain = sub.add_parser("domain", help=_tx("manage service domain overrides", zh="管理服务域名覆盖", de="Dienst-Domain-Overrides verwalten", es="gestionar overrides de dominio de servicios"), usage=_tx("myapp-ctl domain <command> [args]", zh="myapp-ctl domain <命令> [参数]", de="myapp-ctl domain <Befehl> [Argumente]", es="myapp-ctl domain <comando> [args]"))
    domain_sub = _add_subcommands(domain, "domain_cmd")
    domain_sub.add_parser("ls", help=_tx("list domain overrides", zh="列出域名覆盖", de="Domain-Overrides auflisten", es="listar overrides de dominio"), usage="myapp-ctl domain ls").set_defaults(func=cmd_domain)
    domain_set = domain_sub.add_parser("set", help=_tx("set a domain override", zh="设置域名覆盖", de="Domain-Override setzen", es="definir override de dominio"), usage=_tx("myapp-ctl domain set <name> <value>", zh="myapp-ctl domain set <名称> <值>", de="myapp-ctl domain set <Name> <Wert>", es="myapp-ctl domain set <nombre> <valor>"))
    domain_set.add_argument("name")
    domain_set.add_argument("value")
    domain_set.set_defaults(func=cmd_domain)
    domain_rm = domain_sub.add_parser("rm", help=_tx("remove a domain override", zh="移除域名覆盖", de="Domain-Override entfernen", es="eliminar override de dominio"), usage=_tx("myapp-ctl domain rm <name>", zh="myapp-ctl domain rm <名称>", de="myapp-ctl domain rm <Name>", es="myapp-ctl domain rm <nombre>"))
    domain_rm.add_argument("name")
    domain_rm.set_defaults(func=cmd_domain)
    client_env = sub.add_parser("client-env", help=_tx("generate client Service Environment import JSON and QR", zh="生成客户端服务环境导入 JSON 和二维码", de="Client-Service-Environment JSON und QR erzeugen", es="generar JSON y QR de entorno de servicio del cliente"), usage=_tx("myapp-ctl client-env [options]", zh="myapp-ctl client-env [选项]", de="myapp-ctl client-env [Optionen]", es="myapp-ctl client-env [opciones]"))
    client_env.add_argument("--host", help=_tx("public host/IP to use in generated URLs", zh="生成 URL 使用的公网域名或 IP", de="oeffentlicher Host/IP fuer generierte URLs", es="host/IP publico para URLs generadas"))
    client_env.add_argument("--name", help=_tx("environment name shown in the client", zh="客户端显示的环境名称", de="im Client angezeigter Umgebungsname", es="nombre de entorno mostrado en el cliente"))
    client_env.add_argument("--out", help=_tx("JSON output path; default is <data-root>/state/client-environment.json", zh="JSON 输出路径；默认 <data-root>/state/client-environment.json", de="JSON-Ausgabepfad; Standard <data-root>/state/client-environment.json", es="ruta JSON de salida; por defecto <data-root>/state/client-environment.json"))
    client_env.add_argument("--qr", help=_tx("QR PNG output path; default follows --out with .png", zh="QR PNG 输出路径；默认跟随 --out 并使用 .png", de="QR-PNG-Ausgabepfad; Standard folgt --out mit .png", es="ruta PNG del QR; por defecto sigue --out con .png"))
    client_env.add_argument("--no-qr", action="store_true", help=_tx("do not generate QR PNG", zh="不生成 QR PNG", de="kein QR-PNG erzeugen", es="no generar QR PNG"))
    client_env.add_argument("--terminal-qr", action="store_true", help=_tx("also print an ANSI QR code in the terminal", zh="同时在终端打印 ANSI 二维码", de="zusaetzlich ANSI-QR im Terminal ausgeben", es="tambien imprimir QR ANSI en terminal"))
    client_env.add_argument("--json", action="store_true", help=_tx("print raw JSON only", zh="仅打印原始 JSON", de="nur rohes JSON ausgeben", es="imprimir solo JSON bruto"))
    client_env.set_defaults(func=cmd_client_env)
    agent_node = sub.add_parser("agent-node", help=_tx("manage cluster agent hosts", zh="管理集群 Agent 物理节点", de="Cluster-Agent-Hosts verwalten", es="gestionar hosts agent del cluster"), usage=_tx("myapp-ctl agent-node <command> [args]", zh="myapp-ctl agent-node <命令> [参数]", de="myapp-ctl agent-node <Befehl> [Argumente]", es="myapp-ctl agent-node <comando> [args]"))
    agent_node_sub = _add_subcommands(agent_node, "agent_node_cmd")
    agent_node_ls = agent_node_sub.add_parser("ls", help=_tx("list registered cluster agent hosts", zh="列出已注册集群 Agent 节点", de="registrierte Cluster-Agent-Hosts auflisten", es="listar hosts agent registrados"), usage=_tx("myapp-ctl agent-node ls [options]", zh="myapp-ctl agent-node ls [选项]", de="myapp-ctl agent-node ls [Optionen]", es="myapp-ctl agent-node ls [opciones]"))
    agent_node_ls.add_argument("--backend")
    agent_node_ls.add_argument("--token")
    agent_node_ls.add_argument("--namespace", default="public", help=_tx("node namespace to list: public, all, or a user id", zh="要列出的节点 namespace：public、all 或用户 ID", de="Node-Namespace: public, all oder Benutzer-ID", es="namespace de nodos: public, all o id de usuario"))
    agent_node_ls.add_argument("--auth-token", help=_tx("logged-in user access token for private-node view; alternatively MYAPP_AUTH_TOKEN", zh="私有节点视角使用的已登录用户 access token；也可用 MYAPP_AUTH_TOKEN", de="Access-Token des angemeldeten Benutzers fuer Private-Node-Ansicht; alternativ MYAPP_AUTH_TOKEN", es="access token del usuario para vista privada; alternativamente MYAPP_AUTH_TOKEN"))
    agent_node_ls.add_argument("--no-probe", action="store_true", help=_tx("do not call each agent-node /health", zh="不调用每个 agent-node 的 /health", de="/health der einzelnen agent-nodes nicht abfragen", es="no llamar /health de cada agent-node"))
    agent_node_ls.add_argument("--json", action="store_true")
    agent_node_ls.set_defaults(func=cmd_agent_node)
    agent_node_status = agent_node_sub.add_parser("status", help=_tx("show cluster agent host status", zh="查看集群 Agent 节点状态", de="Status eines Cluster-Agent-Hosts anzeigen", es="mostrar estado del host agent"), usage=_tx("myapp-ctl agent-node status [node-id] [options]", zh="myapp-ctl agent-node status [节点ID] [选项]", de="myapp-ctl agent-node status [Node-ID] [Optionen]", es="myapp-ctl agent-node status [node-id] [opciones]"))
    agent_node_status.add_argument("node_id", nargs="?")
    agent_node_status.add_argument("--backend")
    agent_node_status.add_argument("--token")
    agent_node_status.add_argument("--namespace", default="public", help=_tx("node namespace to list when node-id is omitted: public, all, or a user id", zh="省略节点 ID 时列出的 namespace：public、all 或用户 ID", de="Namespace beim Auflisten ohne Node-ID: public, all oder Benutzer-ID", es="namespace al listar sin node-id: public, all o id de usuario"))
    agent_node_status.add_argument("--auth-token", help=_tx("logged-in user access token for private-node view; alternatively MYAPP_AUTH_TOKEN", zh="私有节点视角使用的已登录用户 access token；也可用 MYAPP_AUTH_TOKEN", de="Access-Token des angemeldeten Benutzers fuer Private-Node-Ansicht; alternativ MYAPP_AUTH_TOKEN", es="access token del usuario para vista privada; alternativamente MYAPP_AUTH_TOKEN"))
    agent_node_status.add_argument("--no-probe", action="store_true", help=_tx("only used when node_id is omitted", zh="仅在省略 node_id 时使用", de="nur verwendet, wenn node_id fehlt", es="solo se usa cuando se omite node_id"))
    agent_node_status.add_argument("--json", action="store_true")
    agent_node_status.set_defaults(func=cmd_agent_node)
    agent_node_register = agent_node_sub.add_parser("register", help=_tx("register this agent host to the master backend", zh="将本 Agent 节点注册到主后端", de="diesen Agent-Host beim Master-Backend registrieren", es="registrar este host agent en el backend maestro"), usage=_tx("myapp-ctl agent-node register [options]", zh="myapp-ctl agent-node register [选项]", de="myapp-ctl agent-node register [Optionen]", es="myapp-ctl agent-node register [opciones]"))
    agent_node_register.add_argument("--backend")
    agent_node_register.add_argument("--url")
    agent_node_register.add_argument("--node-id")
    agent_node_register.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    agent_node_register.add_argument("--capacity", type=int, default=1)
    agent_node_register.add_argument("--queue-max", type=int)
    agent_node_register.add_argument("--ttl", type=int, default=120)
    agent_node_register.add_argument("--token")
    agent_node_register.add_argument("--label", action="append")
    agent_node_register.set_defaults(func=cmd_agent_node)
    agent_node_rm = agent_node_sub.add_parser("rm", help=_tx("remove a registered agent host from the master registry", zh="从主注册表移除已注册 Agent 节点", de="registrierten Agent-Host aus Master-Registry entfernen", es="eliminar host agent registrado del registro maestro"), usage=_tx("myapp-ctl agent-node rm <node-id> [options]", zh="myapp-ctl agent-node rm <节点ID> [选项]", de="myapp-ctl agent-node rm <Node-ID> [Optionen]", es="myapp-ctl agent-node rm <node-id> [opciones]"))
    agent_node_rm.add_argument("node_id")
    agent_node_rm.add_argument("--backend")
    agent_node_rm.add_argument("--token")
    agent_node_rm.set_defaults(func=cmd_agent_node)
    agent_node_pause = agent_node_sub.add_parser("pause", help=_tx("pause scheduling for an agent host without stopping current runs", zh="暂停 Agent 节点调度，不停止当前任务", de="Scheduling fuer Agent-Host pausieren, laufende Jobs nicht stoppen", es="pausar planificacion del host agent sin detener tareas actuales"), usage=_tx("myapp-ctl agent-node pause [node-id] [options]", zh="myapp-ctl agent-node pause [节点ID] [选项]", de="myapp-ctl agent-node pause [Node-ID] [Optionen]", es="myapp-ctl agent-node pause [node-id] [opciones]"))
    agent_node_pause.add_argument("node_id", nargs="?", help=_tx("defaults to local AGENT_NODE_ID", zh="默认使用本机 AGENT_NODE_ID", de="Standard ist lokale AGENT_NODE_ID", es="por defecto usa AGENT_NODE_ID local"))
    agent_node_pause.add_argument("--backend")
    agent_node_pause.add_argument("--token")
    agent_node_pause.add_argument("--reason", default="")
    agent_node_pause.add_argument("--json", action="store_true")
    agent_node_pause.set_defaults(func=cmd_agent_node)
    agent_node_resume = agent_node_sub.add_parser("resume", help=_tx("resume scheduling for an agent host", zh="恢复 Agent 节点调度", de="Scheduling fuer Agent-Host fortsetzen", es="reanudar planificacion del host agent"), usage=_tx("myapp-ctl agent-node resume [node-id] [options]", zh="myapp-ctl agent-node resume [节点ID] [选项]", de="myapp-ctl agent-node resume [Node-ID] [Optionen]", es="myapp-ctl agent-node resume [node-id] [opciones]"))
    agent_node_resume.add_argument("node_id", nargs="?", help=_tx("defaults to local AGENT_NODE_ID", zh="默认使用本机 AGENT_NODE_ID", de="Standard ist lokale AGENT_NODE_ID", es="por defecto usa AGENT_NODE_ID local"))
    agent_node_resume.add_argument("--backend")
    agent_node_resume.add_argument("--token")
    agent_node_resume.add_argument("--json", action="store_true")
    agent_node_resume.set_defaults(func=cmd_agent_node)
    agent_node_capacity = agent_node_sub.add_parser("capacity", help=_tx("hot-update local pull agent capacity", zh="热更新本机 pull Agent 并发", de="lokale Pull-Agent-Kapazitaet live aktualisieren", es="actualizar en caliente la capacidad local del agent pull"), usage=_tx("myapp-ctl agent-node capacity <n> [options]", zh="myapp-ctl agent-node capacity <n> [选项]", de="myapp-ctl agent-node capacity <n> [Optionen]", es="myapp-ctl agent-node capacity <n> [opciones]"))
    agent_node_capacity.add_argument("capacity", type=int)
    agent_node_capacity.add_argument("--queue-max", type=int, help=_tx("local pull queue max reported by this agent node", zh="本 Agent 节点上报的本地 pull 队列上限", de="lokales Pull-Queue-Maximum, das dieser Agent meldet", es="maximo de cola pull local reportado por este agent"))
    agent_node_capacity.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    agent_node_capacity.add_argument("--token")
    agent_node_capacity.add_argument("--no-restart", action="store_true", help=_tx("deprecated; limits are hot-updated without restart", zh="已废弃；限制现在会无重启热更新", de="veraltet; Limits werden ohne Neustart live aktualisiert", es="obsoleto; los limites se actualizan sin reinicio"))
    agent_node_capacity.add_argument("--force", action="store_true", help=_tx("deprecated; active runs are never interrupted by limits updates", zh="已废弃；更新限制不会中断活跃任务", de="veraltet; aktive Laeufe werden durch Limit-Updates nie unterbrochen", es="obsoleto; las tareas activas no se interrumpen por cambios de limites"))
    agent_node_capacity.add_argument("--json", action="store_true")
    agent_node_capacity.set_defaults(func=cmd_agent_node)
    agent_node_limits = agent_node_sub.add_parser("limits", help=_tx("hot-update local pull agent capacity/queue limits", zh="热更新本机 pull Agent 并发/队列限制", de="lokale Pull-Agent-Kapazitaet/Queue-Limits live aktualisieren", es="actualizar en caliente capacidad/cola local del agent pull"), usage=_tx("myapp-ctl agent-node limits [options]", zh="myapp-ctl agent-node limits [选项]", de="myapp-ctl agent-node limits [Optionen]", es="myapp-ctl agent-node limits [opciones]"))
    agent_node_limits.add_argument("--capacity", type=int)
    agent_node_limits.add_argument("--queue-max", type=int)
    agent_node_limits.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    agent_node_limits.add_argument("--token")
    agent_node_limits.add_argument("--no-restart", action="store_true", help=_tx("deprecated; limits are hot-updated without restart", zh="已废弃；限制现在会无重启热更新", de="veraltet; Limits werden ohne Neustart live aktualisiert", es="obsoleto; los limites se actualizan sin reinicio"))
    agent_node_limits.add_argument("--force", action="store_true", help=_tx("deprecated; active runs are never interrupted by limits updates", zh="已废弃；更新限制不会中断活跃任务", de="veraltet; aktive Laeufe werden durch Limit-Updates nie unterbrochen", es="obsoleto; las tareas activas no se interrumpen por cambios de limites"))
    agent_node_limits.add_argument("--json", action="store_true")
    agent_node_limits.set_defaults(func=cmd_agent_node)
    agent_node_private = agent_node_sub.add_parser("private", help=_tx("manage a user-private agent node", zh="管理用户私有 Agent 节点", de="privaten Benutzer-Agent-Node verwalten", es="gestionar agent node privado de usuario"), usage=_tx("myapp-ctl agent-node private <command> [args]", zh="myapp-ctl agent-node private <命令> [参数]", de="myapp-ctl agent-node private <Befehl> [Argumente]", es="myapp-ctl agent-node private <comando> [args]"))
    agent_node_private_sub = _add_subcommands(agent_node_private, "private_cmd")
    private_ls = agent_node_private_sub.add_parser("ls", help=_tx("list only the current user's private agent nodes", zh="仅列出当前用户自己的私有 Agent 节点", de="nur private Agent-Nodes des aktuellen Benutzers auflisten", es="listar solo los agent nodes privados del usuario actual"), usage=_tx("myapp-ctl agent-node private ls [options]", zh="myapp-ctl agent-node private ls [选项]", de="myapp-ctl agent-node private ls [Optionen]", es="myapp-ctl agent-node private ls [opciones]"))
    private_ls.add_argument("--backend")
    private_ls.add_argument("--auth-token", help=_tx("logged-in user access token; alternatively MYAPP_AUTH_TOKEN", zh="已登录用户 access token；也可用 MYAPP_AUTH_TOKEN", de="Access-Token des angemeldeten Benutzers; alternativ MYAPP_AUTH_TOKEN", es="access token del usuario autenticado; alternativamente MYAPP_AUTH_TOKEN"))
    private_ls.add_argument("--no-probe", action="store_true", help=_tx("do not call each private agent-node /health", zh="不调用每个私有 agent-node 的 /health", de="/health der privaten agent-nodes nicht abfragen", es="no llamar /health de cada agent-node privado"))
    private_ls.add_argument("--json", action="store_true")
    private_ls.set_defaults(func=cmd_agent_node)
    private_status = agent_node_private_sub.add_parser("status", help=_tx("show only the current user's private agent-node status", zh="仅查看当前用户自己的私有 Agent 节点状态", de="Status eines privaten Agent-Nodes des aktuellen Benutzers anzeigen", es="mostrar estado del agent node privado del usuario actual"), usage=_tx("myapp-ctl agent-node private status [node-id] [options]", zh="myapp-ctl agent-node private status [节点ID] [选项]", de="myapp-ctl agent-node private status [Node-ID] [Optionen]", es="myapp-ctl agent-node private status [node-id] [opciones]"))
    private_status.add_argument("node_id", nargs="?")
    private_status.add_argument("--backend")
    private_status.add_argument("--auth-token", help=_tx("logged-in user access token; alternatively MYAPP_AUTH_TOKEN", zh="已登录用户 access token；也可用 MYAPP_AUTH_TOKEN", de="Access-Token des angemeldeten Benutzers; alternativ MYAPP_AUTH_TOKEN", es="access token del usuario autenticado; alternativamente MYAPP_AUTH_TOKEN"))
    private_status.add_argument("--no-probe", action="store_true", help=_tx("do not call each private agent-node /health", zh="不调用每个私有 agent-node 的 /health", de="/health der privaten agent-nodes nicht abfragen", es="no llamar /health de cada agent-node privado"))
    private_status.add_argument("--json", action="store_true")
    private_status.set_defaults(func=cmd_agent_node)
    private_join = agent_node_private_sub.add_parser("join", help=_tx("register and deploy a private pull agent node", zh="注册并部署私有 pull Agent 节点", de="privaten Pull-Agent-Node registrieren und deployen", es="registrar y desplegar agent node pull privado"), usage=_tx("myapp-ctl agent-node private join [options]", zh="myapp-ctl agent-node private join [选项]", de="myapp-ctl agent-node private join [Optionen]", es="myapp-ctl agent-node private join [opciones]"))
    private_join.add_argument("--backend", required=True, help=_tx("backend URL, for example https://myapp-backend.example.com", zh="后端 URL，例如 https://myapp-backend.example.com", de="Backend-URL, z.B. https://myapp-backend.example.com", es="URL del backend, por ejemplo https://myapp-backend.example.com"))
    private_join.add_argument("--join-token", help=_tx("short-lived private agent join token from app settings; alternatively MYAPP_PRIVATE_AGENT_JOIN_TOKEN", zh="从 App 设置页获取的短期私有 Agent 加入令牌；也可用 MYAPP_PRIVATE_AGENT_JOIN_TOKEN", de="kurzlebiges Private-Agent-Join-Token aus App-Einstellungen; alternativ MYAPP_PRIVATE_AGENT_JOIN_TOKEN", es="token corto de union de agent privado desde ajustes; alternativamente MYAPP_PRIVATE_AGENT_JOIN_TOKEN"))
    private_join.add_argument("--auth-token", help=_tx("logged-in user access token; alternatively MYAPP_AUTH_TOKEN", zh="已登录用户 access token；也可用 MYAPP_AUTH_TOKEN", de="Access-Token des angemeldeten Benutzers; alternativ MYAPP_AUTH_TOKEN", es="access token del usuario autenticado; alternativamente MYAPP_AUTH_TOKEN"))
    private_join.add_argument("--node-id")
    private_join.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    private_join.add_argument("--host")
    private_join.add_argument("--data-root", default=DEFAULT_DATA_ROOT)
    private_join.add_argument("--local-port", type=int, default=5590)
    private_join.add_argument("--capacity", type=int, default=1)
    private_join.add_argument("--queue-max", type=int)
    private_join.add_argument("--ttl", type=int, default=120)
    private_join.add_argument("--provider", action="append", default=[], help=_tx("local provider id supported by this node; repeatable", zh="本节点支持的本地供应商 ID；可重复", de="lokale Provider-ID dieses Nodes; wiederholbar", es="id de proveedor local soportado; repetible"))
    private_join.add_argument("--agent", action="append", default=[], help=_tx("filter local adapters by agent id; repeatable", zh="按 Agent ID 过滤本地 adapter；可重复", de="lokale Adapter nach Agent-ID filtern; wiederholbar", es="filtrar adaptadores locales por id de agent; repetible"))
    private_join.add_argument("--capability", action="append", default=[], help=_tx("explicit local capability provider:agent[:adapter]; repeatable", zh="显式本地能力 provider:agent[:adapter]；可重复", de="explizite lokale Faehigkeit provider:agent[:adapter]; wiederholbar", es="capacidad local explicita provider:agent[:adapter]; repetible"))
    private_join.add_argument("--label", action="append")
    private_join.add_argument("--pull", action="store_true", help=_tx("pull configured images before deploy", zh="部署前拉取已配置镜像", de="konfigurierte Images vor Deploy laden", es="descargar imagenes configuradas antes de desplegar"))
    private_join.add_argument("--build", action="store_true", help=_tx("build images from local source before deploy", zh="部署前从本地源码构建镜像", de="Images vor Deploy aus lokalem Quellcode bauen", es="construir imagenes desde codigo local antes de desplegar"))
    private_join.add_argument("--no-provider-setup", action="store_true", help=_tx("do not prompt for local AI provider config", zh="不交互配置本地 AI 供应商", de="nicht nach lokaler KI-Provider-Konfiguration fragen", es="no pedir configuracion local de proveedor IA"))
    private_join.add_argument("--replace-existing-agent-node", action="store_true", help=_tx("allow replacing the singleton myapp-agent-node on this host", zh="允许替换本机 singleton myapp-agent-node", de="Singleton myapp-agent-node auf diesem Host ersetzen", es="permitir reemplazar el singleton myapp-agent-node de este host"))
    private_join.set_defaults(func=cmd_agent_node)
    agent_node_add = agent_node_sub.add_parser("add", help=_tx("print a join command for a new agent host", zh="打印新 Agent 节点的一键加入命令", de="Join-Befehl fuer neuen Agent-Host ausgeben", es="imprimir comando join para nuevo host agent"), usage=_tx("myapp-ctl agent-node add [options]", zh="myapp-ctl agent-node add [选项]", de="myapp-ctl agent-node add [Optionen]", es="myapp-ctl agent-node add [opciones]"))
    agent_node_add.add_argument("--backend", help=_tx("master backend URL, for example http://<master-host>:5566", zh="主后端 URL，例如 http://<master-host>:5566", de="Master-Backend-URL, z.B. http://<master-host>:5566", es="URL del backend maestro, por ejemplo http://<master-host>:5566"))
    agent_node_add.add_argument("--host", help=_tx("new agent host public IP or domain", zh="新 Agent 节点公网 IP 或域名", de="oeffentliche IP oder Domain des neuen Agent-Hosts", es="IP publica o dominio del nuevo host agent"))
    agent_node_add.add_argument("--url", help=_tx("full public agent-node URL; defaults to http://<host>:<public-port>", zh="完整公网 agent-node URL；默认 http://<host>:<public-port>", de="vollstaendige oeffentliche agent-node URL; Standard http://<host>:<public-port>", es="URL publica completa de agent-node; por defecto http://<host>:<public-port>"))
    agent_node_add.add_argument("--node-id")
    agent_node_add.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    agent_node_add.add_argument("--data-root", default=DEFAULT_DATA_ROOT)
    agent_node_add.add_argument("--local-port", type=int, default=5590)
    agent_node_add.add_argument("--public-port", type=int, default=5591)
    agent_node_add.add_argument("--capacity", type=int, default=1)
    agent_node_add.add_argument("--queue-max", type=int)
    agent_node_add.add_argument("--ttl", type=int, default=180)
    agent_node_add.add_argument("--label", action="append")
    agent_node_add.add_argument("--mode", choices=["pull", "direct"], default="pull", metavar="MODE", help=_tx("agent connection mode: pull, direct", zh="Agent 连接模式: pull, direct", de="Agent-Verbindungsmodus: pull, direct", es="modo de conexion agent: pull, direct"))
    agent_node_add.add_argument("--provider-mode", choices=["master", "local"], default="master", metavar="MODE", help=_tx("provider key source: master, local", zh="供应商密钥来源: master, local", de="Provider-Key-Quelle: master, local", es="origen de claves del proveedor: master, local"))
    agent_node_add.add_argument("--pull", action="store_true", help=_tx("make the join command pull required images", zh="生成的加入命令会拉取所需镜像", de="Join-Befehl laedt benoetigte Images", es="el comando join descargara imagenes necesarias"))
    agent_node_add.add_argument("--build", action="store_true", help=_tx("make the join command build required images locally", zh="生成的加入命令会在本地构建所需镜像", de="Join-Befehl baut benoetigte Images lokal", es="el comando join construira imagenes localmente"))
    agent_node_add.add_argument("--no-nginx", action="store_true")
    agent_node_add.add_argument("--allow-from", help=_tx("optional source IP allowed through ufw for the public agent port", zh="可选：允许通过 ufw 访问公网 Agent 端口的来源 IP", de="optionale Quell-IP, die ufw fuer den oeffentlichen Agent-Port erlaubt", es="IP origen opcional permitida por ufw para el puerto agent publico"))
    agent_node_add.add_argument("--no-timer", action="store_true")
    agent_node_add.set_defaults(func=cmd_agent_node)
    agent_node_join = agent_node_sub.add_parser("join", help=_tx("join this host to a master backend as an agent node", zh="将本机作为 Agent 节点加入主后端", de="diesen Host als Agent-Node an Master-Backend anbinden", es="unir este host al backend maestro como agent node"), usage=_tx("myapp-ctl agent-node join --backend <url> --node-id <id> [options]", zh="myapp-ctl agent-node join --backend <url> --node-id <id> [选项]", de="myapp-ctl agent-node join --backend <url> --node-id <id> [Optionen]", es="myapp-ctl agent-node join --backend <url> --node-id <id> [opciones]"))
    agent_node_join.add_argument("--backend", required=True, help=_tx("master backend URL", zh="主后端 URL", de="Master-Backend-URL", es="URL del backend maestro"))
    agent_node_join.add_argument("--host", help=_tx("this agent host display IP or domain", zh="本 Agent 节点展示 IP 或域名", de="Anzeige-IP oder Domain dieses Agent-Hosts", es="IP o dominio mostrado de este host agent"))
    agent_node_join.add_argument("--url", help=_tx("agent-node URL; pull mode defaults to pull://<node-id>", zh="agent-node URL；pull 模式默认 pull://<node-id>", de="agent-node URL; Pull-Modus nutzt standardmaessig pull://<node-id>", es="URL de agent-node; modo pull usa por defecto pull://<node-id>"))
    agent_node_join.add_argument("--node-id", required=True)
    agent_node_join.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    agent_node_join.add_argument("--data-root", default=DEFAULT_DATA_ROOT)
    agent_node_join.add_argument("--local-port", type=int, default=5590)
    agent_node_join.add_argument("--public-port", type=int, default=5591)
    agent_node_join.add_argument("--capacity", type=int, default=1)
    agent_node_join.add_argument("--queue-max", type=int)
    agent_node_join.add_argument("--ttl", type=int, default=180)
    agent_node_join.add_argument("--label", action="append")
    agent_node_join.add_argument("--mode", choices=["pull", "direct"], default="pull", metavar="MODE", help=_tx("agent connection mode: pull, direct", zh="Agent 连接模式: pull, direct", de="Agent-Verbindungsmodus: pull, direct", es="modo de conexion agent: pull, direct"))
    agent_node_join.add_argument("--provider-mode", choices=["master", "local"], default="master", metavar="MODE", help=_tx("provider key source: master, local", zh="供应商密钥来源: master, local", de="Provider-Key-Quelle: master, local", es="origen de claves del proveedor: master, local"))
    agent_node_join.add_argument("--agent-token", required=True)
    agent_node_join.add_argument("--registration-token", required=True)
    agent_node_join.add_argument("--pull", action="store_true", help=_tx("pull required images before deploy", zh="部署前拉取所需镜像", de="benoetigte Images vor dem Deploy laden", es="descargar imagenes necesarias antes de desplegar"))
    agent_node_join.add_argument("--build", action="store_true", help=_tx("build required images locally before deploy", zh="部署前在本地构建所需镜像", de="benoetigte Images lokal vor dem Deploy bauen", es="construir imagenes localmente antes de desplegar"))
    agent_node_join.add_argument("--no-nginx", action="store_true")
    agent_node_join.add_argument("--allow-from", help=_tx("optional source IP allowed through ufw for the public agent port", zh="可选：允许通过 ufw 访问公网 Agent 端口的来源 IP", de="optionale Quell-IP, die ufw fuer den oeffentlichen Agent-Port erlaubt", es="IP origen opcional permitida por ufw para el puerto agent publico"))
    agent_node_join.add_argument("--no-timer", action="store_true")
    agent_node_join.add_argument("--replace-existing-agent-node", action="store_true", help=_tx("allow replacing the singleton myapp-agent-node on this host", zh="允许替换本机 singleton myapp-agent-node", de="Singleton myapp-agent-node auf diesem Host ersetzen", es="permitir reemplazar el singleton myapp-agent-node de este host"))
    agent_node_join.set_defaults(func=cmd_agent_node)
    agent = sub.add_parser("agent", help=_tx("inspect local agent runs", zh="查看本机 Agent 运行任务", de="lokale Agent-Laeufe anzeigen", es="inspeccionar tareas agent locales"), usage=_tx("myapp-ctl agent <command> [args]", zh="myapp-ctl agent <命令> [参数]", de="myapp-ctl agent <Befehl> [Argumente]", es="myapp-ctl agent <comando> [args]"))
    agent_sub = _add_subcommands(agent, "agent_cmd")
    agent_add = agent_sub.add_parser("add", help=_tx("deprecated alias for agent-node add", zh="已废弃：agent-node add 的别名", de="veraltet: Alias fuer agent-node add", es="obsoleto: alias de agent-node add"), usage=_tx("myapp-ctl agent add [options]", zh="myapp-ctl agent add [选项]", de="myapp-ctl agent add [Optionen]", es="myapp-ctl agent add [opciones]"))
    agent_add.add_argument("--backend", help=_tx("master backend URL, for example http://<master-host>:5566", zh="主后端 URL，例如 http://<master-host>:5566", de="Master-Backend-URL, z.B. http://<master-host>:5566", es="URL del backend maestro, por ejemplo http://<master-host>:5566"))
    agent_add.add_argument("--host", help=_tx("new agent host public IP or domain", zh="新 Agent 节点公网 IP 或域名", de="oeffentliche IP oder Domain des neuen Agent-Hosts", es="IP publica o dominio del nuevo host agent"))
    agent_add.add_argument("--url", help=_tx("full public agent-node URL; defaults to http://<host>:<public-port>", zh="完整公网 agent-node URL；默认 http://<host>:<public-port>", de="vollstaendige oeffentliche agent-node URL; Standard http://<host>:<public-port>", es="URL publica completa de agent-node; por defecto http://<host>:<public-port>"))
    agent_add.add_argument("--node-id")
    agent_add.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    agent_add.add_argument("--data-root", default=DEFAULT_DATA_ROOT)
    agent_add.add_argument("--local-port", type=int, default=5590)
    agent_add.add_argument("--public-port", type=int, default=5591)
    agent_add.add_argument("--capacity", type=int, default=1)
    agent_add.add_argument("--queue-max", type=int)
    agent_add.add_argument("--ttl", type=int, default=180)
    agent_add.add_argument("--label", action="append")
    agent_add.add_argument("--mode", choices=["pull", "direct"], default="pull", metavar="MODE", help=_tx("agent connection mode: pull, direct", zh="Agent 连接模式: pull, direct", de="Agent-Verbindungsmodus: pull, direct", es="modo de conexion agent: pull, direct"))
    agent_add.add_argument("--provider-mode", choices=["master", "local"], default="master", metavar="MODE", help=_tx("provider key source: master, local", zh="供应商密钥来源: master, local", de="Provider-Key-Quelle: master, local", es="origen de claves del proveedor: master, local"))
    agent_add.add_argument("--pull", action="store_true", help=_tx("generate a pull-based deploy command instead of build", zh="生成基于 pull 的部署命令，而不是 build", de="Pull-basierten Deploy-Befehl statt Build erzeugen", es="generar comando de despliegue pull en lugar de build"))
    agent_add.add_argument("--build", action="store_true", help=_tx("make the join command build required images locally", zh="生成的加入命令会在本地构建所需镜像", de="Join-Befehl baut benoetigte Images lokal", es="el comando join construira imagenes localmente"))
    agent_add.add_argument("--no-nginx", action="store_true")
    agent_add.add_argument("--allow-from", help=_tx("optional source IP allowed through ufw for the public agent port", zh="可选：允许通过 ufw 访问公网 Agent 端口的来源 IP", de="optionale Quell-IP, die ufw fuer den oeffentlichen Agent-Port erlaubt", es="IP origen opcional permitida por ufw para el puerto agent publico"))
    agent_add.add_argument("--no-timer", action="store_true")
    agent_add.set_defaults(func=cmd_agent)
    agent_ls = agent_sub.add_parser("ls", help=_tx("list current local agent runs", zh="列出本机当前 Agent 任务", de="aktuelle lokale Agent-Laeufe auflisten", es="listar tareas agent locales actuales"), usage=_tx("myapp-ctl agent ls [options]", zh="myapp-ctl agent ls [选项]", de="myapp-ctl agent ls [Optionen]", es="myapp-ctl agent ls [opciones]"))
    agent_ls.add_argument("--url")
    # Deprecated no-op flags kept so older shell snippets do not fail, but
    # agent ls is intentionally current-local-runs only.
    agent_ls.add_argument("--history", action="store_true", help=argparse.SUPPRESS)
    agent_ls.add_argument("--limit", type=int, default=20, help=argparse.SUPPRESS)
    agent_ls.set_defaults(func=cmd_agent)
    agent_register = agent_sub.add_parser("register", help=_tx("deprecated alias for agent-node register", zh="已废弃：agent-node register 的别名", de="veraltet: Alias fuer agent-node register", es="obsoleto: alias de agent-node register"), usage=_tx("myapp-ctl agent register [options]", zh="myapp-ctl agent register [选项]", de="myapp-ctl agent register [Optionen]", es="myapp-ctl agent register [opciones]"))
    agent_register.add_argument("--backend")
    agent_register.add_argument("--url")
    agent_register.add_argument("--node-id")
    agent_register.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    agent_register.add_argument("--capacity", type=int, default=1)
    agent_register.add_argument("--queue-max", type=int)
    agent_register.add_argument("--ttl", type=int, default=120)
    agent_register.add_argument("--token")
    agent_register.add_argument("--label", action="append")
    agent_register.set_defaults(func=cmd_agent)
    return parser


def _print_main_help() -> None:
    print(_t("main_help").rstrip())


def main(argv: list[str] | None = None) -> int:
    raw_args = list(sys.argv[1:] if argv is None else argv)
    _preinitialize_language(raw_args)
    if not raw_args:
        class _HelpArgs:
            lang = None
            cmd = "help"
            config_cmd = None

        _initialize_language(_HelpArgs())
        _print_main_help()
        return 0
    args = build_parser().parse_args(raw_args)
    _initialize_language(args)
    if not hasattr(args, "func"):
        _print_main_help()
        return 0
    return int(args.func(args) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
