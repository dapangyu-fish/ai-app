"""myapp-ctl: argument parser + main entry (split from myapp_ctl.py; logic unchanged)."""
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
from .deploy import *  # noqa: F401,F403
from .agent import *  # noqa: F401,F403
from .faas import *  # noqa: F401,F403
from .commands import *  # noqa: F401,F403


def _cli_version() -> str:
    """Platform version from the VERSION file (single source of truth)."""
    import json as _json
    import os as _os
    candidates: list[str] = []
    try:
        cfg = _json.loads(open(_os.environ.get("MYAPP_CTL_CONFIG", "/etc/myapp/ctl.json")).read())
        src = (cfg.get("paths") or {}).get("source")
        if src:
            candidates.append(_os.path.join(src, "VERSION"))
    except Exception:
        pass
    # source-checkout fallback: scripts/myapp_ctl/cli.py -> repo root
    candidates.append(_os.path.join(_os.path.dirname(_os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))), "VERSION"))
    for cand in candidates:
        try:
            ver = open(cand).read().strip()
            if ver:
                return f"myapp-ctl {ver}"
        except Exception:
            pass
    return "myapp-ctl (version unknown)"


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
            "override CLI language for this command: zh, en, de, es, fr, pt, ca, hi, ko, ja, it",
            zh="覆盖本次命令语言: zh, en, de, es, fr, pt, ca, hi, ko, ja, it",
            de="CLI-Sprache fuer diesen Befehl setzen: zh, en, de, es, fr, pt, ca, hi, ko, ja, it",
            es="cambiar el idioma de este comando: zh, en, de, es, fr, pt, ca, hi, ko, ja, it",
        ),
    )
    parser.add_argument(
        "--version",
        action="version",
        version=_cli_version(),
        help=_tx("print version and exit", zh="打印版本并退出", de="Version ausgeben und beenden", es="imprimir version y salir"),
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
    status.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    status.set_defaults(func=cmd_status)
    log = sub.add_parser(
        "log",
        help=_tx("show service logs", zh="查看服务日志", de="Dienstlogs anzeigen", es="mostrar logs de servicio"),
        usage=_tx("myapp-ctl log <service> [options]", zh="myapp-ctl log <服务> [选项]", de="myapp-ctl log <Dienst> [Optionen]", es="myapp-ctl log <servicio> [opciones]"),
    )
    log.add_argument("service", help=_tx("service name", zh="服务名", de="Dienstname", es="nombre del servicio"))
    log.add_argument("-n", "--lines", type=int, default=80, help=_tx("number of log lines to show (default 80)", zh="显示的日志行数（默认 80）", de="Anzahl der Logzeilen (Standard 80)", es="numero de lineas de log (por defecto 80)"))
    log.add_argument("-f", "--follow", action="store_true", help=_tx("stream new log lines", zh="持续输出新日志", de="neue Logzeilen streamen", es="transmitir nuevas lineas de log"))
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
        usage=_tx("myapp-ctl image ls", zh="myapp-ctl image ls", de="myapp-ctl image ls", es="myapp-ctl image ls"),
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
            help=_tx(
                "image target: all, agent-runtime, faas-runtime, agent-node, backend",
                zh="镜像目标: all, agent-runtime, faas-runtime, agent-node, backend",
                de="Image-Ziel: all, agent-runtime, faas-runtime, agent-node, backend",
                es="destino de imagen: all, agent-runtime, faas-runtime, agent-node, backend",
            ),
        )
        image_action.add_argument("--dry-run", action="store_true", help=_tx("print actions without executing them", zh="只打印将执行的操作，不实际执行", de="Aktionen nur anzeigen, nicht ausfuehren", es="mostrar acciones sin ejecutarlas"))
        image_action.add_argument(
            "--base",
            action="store_true",
            help=_tx(
                "also process base images; use when apt/pip/npm/agent runtime dependencies changed",
                zh="同时处理 base 镜像；apt/pip/npm/agent 运行时依赖变化时使用",
                de="auch Base-Images verarbeiten; nutzen, wenn apt/pip/npm/Agent-Laufzeitabhaengigkeiten geaendert wurden",
                es="procesar tambien imagenes base; usar cuando cambien dependencias apt/pip/npm/runtime de agentes",
            ),
        )
        image_action.set_defaults(func=cmd_image)
    deploy = sub.add_parser(
        "deploy",
        help=_tx("deploy services", zh="部署服务", de="Dienste deployen", es="desplegar servicios"),
        usage=_tx("myapp-ctl deploy [options] [targets ...]", zh="myapp-ctl deploy [选项] [目标 ...]", de="myapp-ctl deploy [Optionen] [Ziele ...]", es="myapp-ctl deploy [opciones] [destinos ...]"),
    )
    deploy.add_argument("targets", nargs="*", help=_tx("service/group names; omitted means all", zh="服务或分组名；省略表示全部", de="Dienst- oder Gruppennamen; ohne Angabe alle", es="nombres de servicio o grupo; omitido significa todos"))
    deploy.add_argument(
        "--group",
        choices=["infra", "agent", "core", "openim", "supabase", "edge", "faas"],
        metavar="GROUP",
        help=_tx(
            "service group: infra, agent, core, openim, supabase, edge, faas",
            zh="服务分组: infra, agent, core, openim, supabase, edge, faas",
            de="Dienstgruppe: infra, agent, core, openim, supabase, edge, faas",
            es="grupo de servicios: infra, agent, core, openim, supabase, edge, faas",
        ),
    )
    deploy.add_argument("--build", action="store_true", help=_tx("build required images from the local source tree before deploy", zh="部署前从本地源码构建所需镜像", de="benoetigte Images vor dem Deploy aus lokalem Quellcode bauen", es="construir imagenes necesarias desde el codigo local antes de desplegar"))
    deploy.add_argument("--pull", action="store_true", help=_tx("pull required images before deploy", zh="部署前拉取所需镜像", de="benoetigte Images vor dem Deploy laden", es="descargar imagenes necesarias antes de desplegar"))
    deploy.add_argument(
        "--base",
        action="store_true",
        help=_tx(
            "with --build/--pull, also build or pull base images",
            zh="配合 --build/--pull，同时构建或拉取 base 镜像",
            de="mit --build/--pull auch Base-Images bauen oder laden",
            es="con --build/--pull, construir o descargar tambien imagenes base",
        ),
    )
    deploy.add_argument("--mirror", help=_tx("Docker image mirror prefix used with --pull, for example mirror.houlang.cloud/dh", zh="配合 --pull 使用的 Docker 镜像站前缀，例如 mirror.houlang.cloud/dh", de="Docker-Image-Mirror-Prefix fuer --pull, z.B. mirror.houlang.cloud/dh", es="prefijo mirror de imagenes Docker para --pull, por ejemplo mirror.houlang.cloud/dh"))
    deploy.add_argument("--image-version", dest="image_version", metavar="TAG", help=_tx("pin app images to an immutable tag (e.g. 1.2.0-<sha>): write ctl.json + backend.env and pull-deploy that exact image; rollback = re-run with the previous tag", zh="把 app 镜像钉到不可变 tag（如 1.2.0-<sha>）：写入 ctl.json + backend.env 并 pull 部署该精确镜像；回滚=用上一个 tag 再跑一次", de="App-Images auf einen unveraenderlichen Tag pinnen (z.B. 1.2.0-<sha>)", es="fijar imagenes de app a un tag inmutable (p.ej. 1.2.0-<sha>)"))
    deploy.add_argument("--plan", action="store_true", help=_tx("print deployment plan only", zh="仅打印部署计划", de="nur den Deployment-Plan ausgeben", es="solo imprimir el plan de despliegue"))
    deploy.add_argument("--dry-run", action="store_true", help=_tx("print actions without executing them", zh="只打印将执行的操作，不实际执行", de="Aktionen nur anzeigen, nicht ausfuehren", es="mostrar acciones sin ejecutarlas"))
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
    setup.add_argument("--no-ingress", action="store_true", help=_tx("skip managed edge-nginx ingress setup", zh="跳过托管 edge-nginx 入口配置", de="Managed edge-nginx Ingress ueberspringen", es="omitir ingress edge-nginx gestionado"))
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
    uninstall.add_argument("--volumes", action="store_true", help=_tx("remove legacy compose named volumes while stopping services; bind-path data is preserved", zh="停止服务时移除旧 compose 命名 volume；保留 bind-path 数据", de="alte benannte Compose-Volumes beim Stoppen entfernen; Bind-Pfad-Daten bleiben", es="eliminar volumenes compose legados al detener; datos bind-path se conservan"))
    uninstall.add_argument("--state", action="store_true", help=_tx("deprecated; data-root state is always preserved", zh="已废弃；data-root state 始终保留", de="veraltet; data-root state bleibt immer erhalten", es="obsoleto; data-root state siempre se conserva"))
    uninstall.add_argument("--logs", action="store_true", help=_tx("deprecated; data-root logs are always preserved", zh="已废弃；data-root logs 始终保留", de="veraltet; data-root logs bleiben immer erhalten", es="obsoleto; data-root logs siempre se conservan"))
    uninstall.add_argument("--secrets", action="store_true", help=_tx("deprecated no-op; /etc/myapp is always preserved", zh="已废弃且不执行删除；/etc/myapp 始终保留", de="veraltet und ohne Wirkung; /etc/myapp bleibt immer erhalten", es="obsoleto y sin efecto; /etc/myapp siempre se conserva"))
    uninstall.add_argument("--install-files", action="store_true", help=_tx("deprecated no-op; installed files are preserved", zh="已废弃且不执行删除；保留已安装文件", de="veraltet und ohne Wirkung; installierte Dateien bleiben erhalten", es="obsoleto y sin efecto; archivos instalados se conservan"))
    uninstall.add_argument("--images", action="store_true", help=_tx("deprecated no-op; Docker images are always preserved", zh="已废弃且不执行删除；Docker 镜像始终保留", de="veraltet und ohne Wirkung; Docker-Images bleiben immer erhalten", es="obsoleto y sin efecto; las imagenes Docker siempre se conservan"))
    uninstall.add_argument("--remove-ctl", action="store_true", help=_tx("remove the myapp-ctl executable after cleanup", zh="清理后移除 myapp-ctl 可执行文件", de="myapp-ctl nach der Bereinigung entfernen", es="eliminar ejecutable myapp-ctl tras la limpieza"))
    uninstall.add_argument("--dry-run", action="store_true", help=_tx("print actions without executing them", zh="只打印将执行的操作，不实际执行", de="Aktionen nur anzeigen, nicht ausfuehren", es="mostrar acciones sin ejecutarlas"))
    uninstall.set_defaults(func=cmd_uninstall)
    restart = sub.add_parser("restart", help=_tx("restart services", zh="重启服务", de="Dienste neu starten", es="reiniciar servicios"), usage=_tx("myapp-ctl restart [options] [targets ...]", zh="myapp-ctl restart [选项] [目标 ...]", de="myapp-ctl restart [Optionen] [Ziele ...]", es="myapp-ctl restart [opciones] [destinos ...]"))
    restart.add_argument("targets", nargs="*", help=_tx("service/group names; omitted means all", zh="服务或分组名；省略表示全部", de="Dienst- oder Gruppennamen; ohne Angabe alle", es="nombres de servicio o grupo; omitido significa todos"))
    restart.add_argument(
        "--group",
        choices=["infra", "agent", "core", "openim", "supabase", "edge"],
        metavar="GROUP",
        help=_tx("service group: infra, agent, core, openim, supabase, edge", zh="服务分组: infra, agent, core, openim, supabase, edge", de="Dienstgruppe: infra, agent, core, openim, supabase, edge", es="grupo de servicios: infra, agent, core, openim, supabase, edge"),
    )
    restart.set_defaults(func=cmd_restart)
    secret = sub.add_parser("secret", help=_tx("manage host-local secrets", zh="管理本机密钥", de="host-lokale Secrets verwalten", es="gestionar secretos locales del host"), usage=_tx("myapp-ctl secret <command> [args]", zh="myapp-ctl secret <命令> [参数]", de="myapp-ctl secret <Befehl> [Argumente]", es="myapp-ctl secret <comando> [args]"))
    secret_sub = _add_subcommands(secret, "secret_cmd")
    secret_sub.add_parser("ls", help=_tx("list secret groups", zh="列出密钥分组", de="Secret-Gruppen auflisten", es="listar grupos de secretos"), usage=_tx("myapp-ctl secret ls", zh="myapp-ctl secret ls", de="myapp-ctl secret ls", es="myapp-ctl secret ls")).set_defaults(func=cmd_secret)
    secret_init = secret_sub.add_parser("init-stack", help=_tx("initialize stack secrets", zh="初始化栈密钥", de="Stack-Secrets initialisieren", es="inicializar secretos del stack"), usage=_tx("myapp-ctl secret init-stack [options]", zh="myapp-ctl secret init-stack [选项]", de="myapp-ctl secret init-stack [Optionen]", es="myapp-ctl secret init-stack [opciones]"))
    secret_init.add_argument("--host", help=_tx("public host/IP used in generated local service URLs", zh="生成本地服务 URL 时使用的公网域名或 IP", de="oeffentlicher Host/IP fuer generierte lokale Dienst-URLs", es="host/IP publico usado en URLs locales generadas"))
    secret_init.add_argument("--data-root", help=_tx("local persistent data root, for example /mnt/myapp", zh="本地持久化数据根目录，例如 /mnt/myapp", de="lokales persistentes Datenverzeichnis, z.B. /mnt/myapp", es="raiz local persistente, por ejemplo /mnt/myapp"))
    secret_init.add_argument("--force", action="store_true", help=_tx("regenerate stack secrets managed by myapp-ctl", zh="重新生成 myapp-ctl 管理的栈密钥", de="von myapp-ctl verwaltete Stack-Secrets neu erzeugen", es="regenerar secretos del stack gestionados por myapp-ctl"))
    secret_init.set_defaults(func=cmd_secret)
    secret_set = secret_sub.add_parser("set", help=_tx("set one or more secret values", zh="设置一个或多个密钥值", de="einen oder mehrere Secret-Werte setzen", es="definir uno o mas valores secretos"), usage=_tx("myapp-ctl secret set <group> <KEY=VALUE ...>", zh="myapp-ctl secret set <分组> <KEY=VALUE ...>", de="myapp-ctl secret set <Gruppe> <KEY=VALUE ...>", es="myapp-ctl secret set <grupo> <KEY=VALUE ...>"))
    secret_set.add_argument("group", help=_tx("secret group, for example backend", zh="密钥分组，例如 backend", de="Secret-Gruppe, z.B. backend", es="grupo de secretos, por ejemplo backend"))
    secret_set.add_argument("items", nargs="+", help=_tx("KEY=VALUE pairs (or KEY to be prompted)", zh="KEY=VALUE 键值对（或仅 KEY 交互输入）", de="KEY=VALUE-Paare (oder KEY zur Eingabe)", es="pares KEY=VALUE (o KEY para pedirlo)"))
    secret_set.set_defaults(func=cmd_secret)
    secret_generate = secret_sub.add_parser("generate", help=_tx("generate random secret values", zh="生成随机密钥值", de="zufaellige Secret-Werte erzeugen", es="generar valores secretos aleatorios"), usage=_tx("myapp-ctl secret generate <group> <key ...> [options]", zh="myapp-ctl secret generate <分组> <key ...> [选项]", de="myapp-ctl secret generate <Gruppe> <Key ...> [Optionen]", es="myapp-ctl secret generate <grupo> <key ...> [opciones]"))
    secret_generate.add_argument("group", help=_tx("secret group, for example backend", zh="密钥分组，例如 backend", de="Secret-Gruppe, z.B. backend", es="grupo de secretos, por ejemplo backend"))
    secret_generate.add_argument("keys", nargs="+", help=_tx("one or more secret key names", zh="一个或多个密钥名", de="ein oder mehrere Secret-Schluesselnamen", es="uno o mas nombres de clave"))
    secret_generate.add_argument("--bytes", type=int, default=32, help=_tx("random byte length per generated value", zh="每个生成值的随机字节长度", de="Zufalls-Byte-Laenge je Wert", es="longitud de bytes aleatorios por valor"))
    secret_generate.set_defaults(func=cmd_secret)
    secret_get = secret_sub.add_parser("get", help=_tx("read one secret value", zh="读取一个密钥值", de="einen Secret-Wert lesen", es="leer un valor secreto"), usage=_tx("myapp-ctl secret get <group> <key> [--show]", zh="myapp-ctl secret get <分组> <key> [--show]", de="myapp-ctl secret get <Gruppe> <Key> [--show]", es="myapp-ctl secret get <grupo> <key> [--show]"))
    secret_get.add_argument("group", help=_tx("secret group, for example backend", zh="密钥分组，例如 backend", de="Secret-Gruppe, z.B. backend", es="grupo de secretos, por ejemplo backend"))
    secret_get.add_argument("key", help=_tx("secret key name", zh="密钥名", de="Secret-Schluesselname", es="nombre de la clave"))
    secret_get.add_argument("--show", action="store_true", help=_tx("print the raw secret value instead of redacted", zh="打印明文密钥而非脱敏值", de="Klartext-Secret statt Maskierung ausgeben", es="mostrar el secreto en claro en vez de oculto"))
    secret_get.set_defaults(func=cmd_secret)
    secret_rm = secret_sub.add_parser("rm", help=_tx("remove one or more secret values", zh="移除一个或多个密钥值", de="einen oder mehrere Secret-Werte entfernen", es="eliminar uno o mas valores secretos"), usage=_tx("myapp-ctl secret rm <group> <key ...>", zh="myapp-ctl secret rm <分组> <key ...>", de="myapp-ctl secret rm <Gruppe> <Key ...>", es="myapp-ctl secret rm <grupo> <key ...>"))
    secret_rm.add_argument("group", help=_tx("secret group, for example backend", zh="密钥分组，例如 backend", de="Secret-Gruppe, z.B. backend", es="grupo de secretos, por ejemplo backend"))
    secret_rm.add_argument("keys", nargs="+", help=_tx("one or more secret key names", zh="一个或多个密钥名", de="ein oder mehrere Secret-Schluesselnamen", es="uno o mas nombres de clave"))
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
    config_lang = config_sub.add_parser("lang", help=_tx("view or set CLI language", zh="查看或设置 CLI 语言", de="CLI-Sprache anzeigen oder setzen", es="ver o establecer idioma del CLI"), usage=_tx("myapp-ctl config lang [zh|en|de|es|fr|pt|ca|hi|ko|ja|it]", zh="myapp-ctl config lang [zh|en|de|es|fr|pt|ca|hi|ko|ja|it]", de="myapp-ctl config lang [zh|en|de|es|fr|pt|ca|hi|ko|ja|it]", es="myapp-ctl config lang [zh|en|de|es|fr|pt|ca|hi|ko|ja|it]"))
    config_lang.add_argument("language", nargs="?", help=_tx("zh, en, de, or es", zh="zh、en、de 或 es", de="zh, en, de oder es", es="zh, en, de o es"))
    config_lang.set_defaults(func=cmd_config)
    domain = sub.add_parser("domain", help=_tx("manage service domain overrides", zh="管理服务域名覆盖", de="Dienst-Domain-Overrides verwalten", es="gestionar overrides de dominio de servicios"), usage=_tx("myapp-ctl domain <command> [args]", zh="myapp-ctl domain <命令> [参数]", de="myapp-ctl domain <Befehl> [Argumente]", es="myapp-ctl domain <comando> [args]"))
    domain_sub = _add_subcommands(domain, "domain_cmd")
    domain_sub.add_parser("ls", help=_tx("list domain overrides", zh="列出域名覆盖", de="Domain-Overrides auflisten", es="listar overrides de dominio"), usage=_tx("myapp-ctl domain ls", zh="myapp-ctl domain ls", de="myapp-ctl domain ls", es="myapp-ctl domain ls")).set_defaults(func=cmd_domain)
    domain_set = domain_sub.add_parser("set", help=_tx("set a domain override", zh="设置域名覆盖", de="Domain-Override setzen", es="definir override de dominio"), usage=_tx("myapp-ctl domain set <name> <value>", zh="myapp-ctl domain set <名称> <值>", de="myapp-ctl domain set <Name> <Wert>", es="myapp-ctl domain set <nombre> <valor>"))
    domain_set.add_argument("name", help=_tx("domain override name", zh="域名覆盖名称", de="Domain-Override-Name", es="nombre del override de dominio"))
    domain_set.add_argument("value", help=_tx("domain override value", zh="域名覆盖值", de="Domain-Override-Wert", es="valor del override de dominio"))
    domain_set.set_defaults(func=cmd_domain)
    domain_rm = domain_sub.add_parser("rm", help=_tx("remove a domain override", zh="移除域名覆盖", de="Domain-Override entfernen", es="eliminar override de dominio"), usage=_tx("myapp-ctl domain rm <name>", zh="myapp-ctl domain rm <名称>", de="myapp-ctl domain rm <Name>", es="myapp-ctl domain rm <nombre>"))
    domain_rm.add_argument("name", help=_tx("domain override name", zh="域名覆盖名称", de="Domain-Override-Name", es="nombre del override de dominio"))
    domain_rm.set_defaults(func=cmd_domain)
    registry = sub.add_parser("registry", help=_tx("manage the App Registry service (upstream mirror)", zh="管理 App Registry 服务（上游回源）", de="App-Registry-Dienst verwalten (Upstream-Mirror)", es="gestionar el servicio App Registry (mirror upstream)"), usage=_tx("myapp-ctl registry <command> [args]", zh="myapp-ctl registry <命令> [参数]", de="myapp-ctl registry <Befehl> [Argumente]", es="myapp-ctl registry <comando> [args]"))
    registry_sub = _add_subcommands(registry, "registry_cmd")
    registry_upstream = registry_sub.add_parser("upstream", help=_tx("configure the upstream mirror registry", zh="配置上游回源仓库", de="Upstream-Mirror-Registry konfigurieren", es="configurar registry mirror upstream"), usage=_tx("myapp-ctl registry upstream [<url>] [--sync-interval N] [--show] [--clear]", zh="myapp-ctl registry upstream [<url>] [--sync-interval N] [--show] [--clear]", de="myapp-ctl registry upstream [<url>] [--sync-interval N] [--show] [--clear]", es="myapp-ctl registry upstream [<url>] [--sync-interval N] [--show] [--clear]"))
    registry_upstream.add_argument("url", nargs="?", help=_tx("upstream registry base URL, e.g. https://myapp-registry.dapangyu.work", zh="上游 registry 基础 URL，例如 https://myapp-registry.dapangyu.work", de="Upstream-Registry-Basis-URL, z.B. https://myapp-registry.dapangyu.work", es="URL base del registry upstream, p.ej. https://myapp-registry.dapangyu.work"))
    registry_upstream.add_argument("--sync-interval", type=int, help=_tx("index sync interval seconds (default 600)", zh="索引同步间隔秒数（默认 600）", de="Index-Sync-Intervall in Sekunden (Standard 600)", es="intervalo de sync de indice en segundos (def. 600)"))
    registry_upstream.add_argument("--show", action="store_true", help=_tx("show current upstream config", zh="显示当前上游配置", de="aktuelle Upstream-Konfiguration anzeigen", es="mostrar config upstream actual"))
    registry_upstream.add_argument("--clear", action="store_true", help=_tx("remove upstream config (run standalone)", zh="移除上游配置（独立运行）", de="Upstream-Konfiguration entfernen (eigenstaendig)", es="eliminar config upstream (independiente)"))
    registry_upstream.set_defaults(func=cmd_registry)
    ingress = sub.add_parser("ingress", help=_tx("manage Docker-based edge-nginx ingress", zh="管理 Docker 化 edge-nginx 入口", de="Docker-basiertes edge-nginx Ingress verwalten", es="gestionar ingress edge-nginx basado en Docker"), usage=_tx("myapp-ctl ingress <command> [args]", zh="myapp-ctl ingress <命令> [参数]", de="myapp-ctl ingress <Befehl> [Argumente]", es="myapp-ctl ingress <comando> [args]"))
    ingress_sub = _add_subcommands(ingress, "ingress_cmd")
    ingress_setup = ingress_sub.add_parser("setup", help=_tx("configure domains, ports, and certificates", zh="配置域名、端口和证书", de="Domains, Ports und Zertifikate konfigurieren", es="configurar dominios, puertos y certificados"), usage=_tx("myapp-ctl ingress setup [options]", zh="myapp-ctl ingress setup [选项]", de="myapp-ctl ingress setup [Optionen]", es="myapp-ctl ingress setup [opciones]"))
    ingress_setup.add_argument("--host", help=_tx("default IPv4/domain for all ingress prompts", zh="所有入口提示的默认 IPv4/域名", de="Standard IPv4/Domain fuer alle Ingress-Abfragen", es="IPv4/dominio por defecto para ingress"))
    for spec in EDGE_ROUTE_SPECS:
        key = str(spec["key"])
        ingress_setup.add_argument(
            f"--{key.replace('_', '-')}-domain",
            dest=key,
            help=_tx(f"{spec['label']} domain", zh=f"{spec['label']} 域名", de=f"{spec['label']} Domain", es=f"dominio de {spec['label']}"),
        )
    ingress_setup.add_argument("--crt", help=_tx("SSL certificate crt/fullchain path on this host", zh="本机 SSL 证书 crt/fullchain 路径", de="SSL-Zertifikat crt/fullchain auf diesem Host", es="ruta del certificado SSL crt/fullchain en este host"))
    ingress_setup.add_argument("--key", help=_tx("SSL certificate key path on this host", zh="本机 SSL 证书 key 路径", de="SSL-Zertifikat-Key auf diesem Host", es="ruta de la clave SSL en este host"))
    ingress_setup.add_argument("--http-port", default=None, help=_tx("host HTTP port mapped to edge-nginx :80", zh="映射到 edge-nginx :80 的宿主机 HTTP 端口", de="Host-HTTP-Port fuer edge-nginx :80", es="puerto HTTP host para edge-nginx :80"))
    ingress_setup.add_argument("--https-port", default=None, help=_tx("host HTTPS port mapped to edge-nginx :443", zh="映射到 edge-nginx :443 的宿主机 HTTPS 端口", de="Host-HTTPS-Port fuer edge-nginx :443", es="puerto HTTPS host para edge-nginx :443"))
    ingress_setup.add_argument("--client-max-body-size", default=None, help=_tx("nginx client_max_body_size, default 2g", zh="nginx client_max_body_size，默认 2g", de="nginx client_max_body_size, Standard 2g", es="nginx client_max_body_size, por defecto 2g"))
    ingress_setup.add_argument("--http-only", action="store_true", help=_tx("render HTTP-only ingress even if cert paths are configured", zh="即使已配置证书路径也渲染 HTTP-only 入口", de="HTTP-only Ingress rendern, auch wenn Zertifikate konfiguriert sind", es="renderizar ingress solo HTTP aunque haya certificados"))
    ingress_setup.add_argument("--public-scheme", choices=["auto", "https", "http"], default=None, help=_tx("scheme for public service URLs: auto=follow edge TLS (direct access on a non-standard port appends :port); https/http=TLS terminated upstream (host nginx/CDN), URLs without port", zh="公网服务 URL 的 scheme：auto=跟随 edge 自身 TLS（非标准端口直连自动补 :port，适配无证书裸 IP+端口访问）；https/http=TLS 在上游终止（前置 nginx/CDN），URL 不带端口", de="Schema oeffentlicher URLs: auto=folgt edge TLS (Nicht-Standard-Port wird angehaengt); https/http=TLS upstream terminiert, ohne Port", es="esquema de URLs publicas: auto=segun TLS de edge (puerto no estandar se anade); https/http=TLS terminado upstream, sin puerto"))
    ingress_setup.add_argument("--yes", action="store_true", help=_tx("non-interactive setup using defaults/options", zh="使用默认值/参数进行非交互配置", de="nichtinteraktives Setup mit Defaults/Optionen", es="setup no interactivo con valores por defecto/opciones"))
    ingress_setup.set_defaults(func=cmd_ingress)
    ingress_render = ingress_sub.add_parser("render", help=_tx("render nginx config into the data root", zh="将 nginx 配置渲染到 data root", de="nginx-Konfiguration ins Datenverzeichnis rendern", es="renderizar config nginx en data root"), usage=_tx("myapp-ctl ingress render [--dry-run]", zh="myapp-ctl ingress render [--dry-run]", de="myapp-ctl ingress render [--dry-run]", es="myapp-ctl ingress render [--dry-run]"))
    ingress_render.add_argument("--dry-run", action="store_true", help=_tx("print actions without executing them", zh="只打印将执行的操作，不实际执行", de="Aktionen nur anzeigen, nicht ausfuehren", es="mostrar acciones sin ejecutarlas"))
    ingress_render.set_defaults(func=cmd_ingress)
    ingress_sub.add_parser("reload", help=_tx("render and reload the running edge-nginx container", zh="渲染并重载运行中的 edge-nginx 容器", de="rendern und laufenden edge-nginx Container neu laden", es="renderizar y recargar contenedor edge-nginx"), usage=_tx("myapp-ctl ingress reload", zh="myapp-ctl ingress reload", de="myapp-ctl ingress reload", es="myapp-ctl ingress reload")).set_defaults(func=cmd_ingress)
    ingress_sub.add_parser("status", help=_tx("show effective ingress config", zh="查看当前入口配置", de="effektive Ingress-Konfiguration anzeigen", es="mostrar config efectiva de ingress"), usage=_tx("myapp-ctl ingress status", zh="myapp-ctl ingress status", de="myapp-ctl ingress status", es="myapp-ctl ingress status")).set_defaults(func=cmd_ingress)
    faas = sub.add_parser("faas", help=_tx("manage generated FaaS backends", zh="管理 AI 生成的 FaaS 后端", de="generierte FaaS-Backends verwalten", es="gestionar backends FaaS generados"), usage=_tx("myapp-ctl faas <command> [args]", zh="myapp-ctl faas <命令> [参数]", de="myapp-ctl faas <Befehl> [Argumente]", es="myapp-ctl faas <comando> [args]"))
    faas_sub = _add_subcommands(faas, "faas_cmd")
    faas_parent = argparse.ArgumentParser(add_help=False)
    faas_parent.add_argument("--base-url", help=_tx("backend base URL; defaults to configured backend", zh="后端基础 URL；默认使用已配置 backend", de="Backend-Basis-URL; Standard aus Konfiguration", es="URL base backend; por defecto configurado"))
    faas_parent.add_argument("--token", help=_tx("optional backend bearer token", zh="可选后端 Bearer token", de="optionales Backend-Bearer-Token", es="token bearer backend opcional"))
    faas_parent.add_argument("--token-env", default="MYAPP_AUTH_TOKEN", help=_tx("environment variable containing the backend bearer token", zh="包含后端 Bearer token 的环境变量", de="Umgebungsvariable mit Backend-Bearer-Token", es="variable de entorno con token bearer backend"))
    faas_health = faas_sub.add_parser("health", parents=[faas_parent], help=_tx("check FaaS control-plane health", zh="检查 FaaS 控制面健康", de="FaaS-Control-Plane Health pruefen", es="comprobar salud del control-plane FaaS"), usage=_tx("myapp-ctl faas health [options]", zh="myapp-ctl faas health [选项]", de="myapp-ctl faas health [Optionen]", es="myapp-ctl faas health [opciones]"))
    faas_health.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    faas_health.set_defaults(func=cmd_faas)
    faas_ls = faas_sub.add_parser("ls", parents=[faas_parent], help=_tx("list generated FaaS services", zh="列出生成的 FaaS 服务", de="generierte FaaS-Dienste auflisten", es="listar servicios FaaS generados"), usage=_tx("myapp-ctl faas ls [options]", zh="myapp-ctl faas ls [选项]", de="myapp-ctl faas ls [Optionen]", es="myapp-ctl faas ls [opciones]"))
    faas_ls.add_argument("--user-id", help=_tx("test-mode owner user id when auth is disabled", zh="鉴权关闭时使用的测试 owner user id", de="Test-Owner-User-ID wenn Auth deaktiviert ist", es="user id owner de prueba cuando auth esta desactivada"))
    faas_ls.add_argument("--all", action="store_true", help=_tx("include disabled services", zh="包含已禁用服务", de="deaktivierte Dienste einschliessen", es="incluir servicios desactivados"))
    faas_ls.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    faas_ls.set_defaults(func=cmd_faas)
    faas_disable = faas_sub.add_parser("disable", parents=[faas_parent], help=_tx("disable one generated FaaS service", zh="禁用一个生成的 FaaS 服务", de="einen generierten FaaS-Dienst deaktivieren", es="desactivar un servicio FaaS generado"), usage=_tx("myapp-ctl faas disable <service-id> [options]", zh="myapp-ctl faas disable <服务ID> [选项]", de="myapp-ctl faas disable <Service-ID> [Optionen]", es="myapp-ctl faas disable <service-id> [opciones]"))
    faas_disable.add_argument("service_id", help=_tx("FaaS service id to disable", zh="要禁用的 FaaS 服务 ID", de="zu deaktivierende FaaS-Service-ID", es="id del servicio FaaS a deshabilitar"))
    faas_disable.add_argument("--user-id", help=_tx("test-mode owner user id when auth is disabled", zh="鉴权关闭时使用的测试 owner user id", de="Test-Owner-User-ID wenn Auth deaktiviert ist", es="user id owner de prueba cuando auth esta desactivada"))
    faas_disable.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    faas_disable.set_defaults(func=cmd_faas)
    faas_rm = faas_sub.add_parser("rm", parents=[faas_parent], help=_tx("permanently delete a FaaS service (incl. disabled): containers + record + code", zh="彻底删除一个 FaaS 服务(含已禁用): 容器+记录+代码", de="einen FaaS-Dienst endgueltig loeschen (auch deaktivierte): Container+Eintrag+Code", es="eliminar permanentemente un servicio FaaS (incl. deshabilitado): contenedores+registro+codigo"), usage=_tx("myapp-ctl faas rm <service-id> [options]", zh="myapp-ctl faas rm <服务ID> [选项]", de="myapp-ctl faas rm <Service-ID> [Optionen]", es="myapp-ctl faas rm <service-id> [opciones]"))
    faas_rm.add_argument("service_id", help=_tx("FaaS service id to delete", zh="要删除的 FaaS 服务 ID", de="zu loeschende FaaS-Service-ID", es="id del servicio FaaS a eliminar"))
    faas_rm.add_argument("--user-id", help=_tx("owner user id (auto-resolved if omitted)", zh="owner user id(省略则自动解析)", de="Owner-User-ID (wird sonst automatisch ermittelt)", es="user id owner (se resuelve solo si se omite)"))
    faas_rm.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    faas_rm.set_defaults(func=cmd_faas)
    faas_smoke = faas_sub.add_parser("smoke", parents=[faas_parent], help=_tx("deploy, invoke, and clean up a generated FaaS smoke service", zh="部署、调用并清理一个 FaaS 冒烟服务", de="FaaS-Smoke-Dienst deployen, aufrufen und bereinigen", es="desplegar, invocar y limpiar servicio FaaS smoke"), usage=_tx("myapp-ctl faas smoke [options]", zh="myapp-ctl faas smoke [选项]", de="myapp-ctl faas smoke [Optionen]", es="myapp-ctl faas smoke [opciones]"))
    faas_smoke.add_argument("--user-id", help=_tx("test-mode owner user id when auth is disabled", zh="鉴权关闭时使用的测试 owner user id", de="Test-Owner-User-ID wenn Auth deaktiviert ist", es="user id owner de prueba cuando auth esta desactivada"))
    faas_smoke.add_argument("--service-id", help=_tx("explicit smoke service id", zh="指定冒烟服务 ID", de="explizite Smoke-Service-ID", es="service id smoke explicito"))
    faas_smoke.add_argument("--no-cleanup", action="store_true", help=_tx("leave the smoke service in place", zh="保留冒烟服务不清理", de="Smoke-Dienst nicht bereinigen", es="no limpiar servicio smoke"))
    faas_smoke.set_defaults(func=cmd_faas)
    faas_ai_action_smoke = faas_sub.add_parser("ai-action-smoke", help=_tx("simulate Agent FaaS artifacts and resolve them through the deployed backend", zh="模拟 Agent FaaS 产物并通过已部署后端解析部署", de="Agent-FaaS-Artefakte simulieren und im deployten Backend aufloesen", es="simular artefactos FaaS de Agent y resolverlos en backend desplegado"), usage=_tx("myapp-ctl faas ai-action-smoke [options]", zh="myapp-ctl faas ai-action-smoke [选项]", de="myapp-ctl faas ai-action-smoke [Optionen]", es="myapp-ctl faas ai-action-smoke [opciones]"))
    faas_ai_action_smoke.add_argument("--base-url", default="http://127.0.0.1:5566", help=_tx("backend base URL used for invocation", zh="调用生成服务使用的后端 base URL", de="Backend-Basis-URL fuer Invocation", es="URL base backend para invocacion"))
    faas_ai_action_smoke.add_argument("--user-id", default="ai-action-smoke-user", help=_tx("test owner user id", zh="测试 owner user id", de="Test-Owner-User-ID", es="user id owner de prueba"))
    faas_ai_action_smoke.add_argument("--session-id", default="ai-action-smoke-session", help=_tx("test AI session id", zh="测试 AI session id", de="Test-AI-Session-ID", es="id de sesion AI de prueba"))
    faas_ai_action_smoke.add_argument("--service-id", default=f"ai-action-smoke-{int(time.time())}", help=_tx("test service id", zh="测试服务 ID", de="Test-Service-ID", es="service id de prueba"))
    faas_ai_action_smoke.add_argument("--no-cleanup", action="store_true", help=_tx("leave generated service in place", zh="保留生成服务不清理", de="generierten Dienst nicht bereinigen", es="no limpiar servicio generado"))
    faas_ai_action_smoke.add_argument("--include-invalid", action="store_true", help=_tx("also verify invalid generated FaaS bundles fail", zh="同时验证非法生成 FaaS bundle 会失败", de="auch pruefen, dass ungueltige generierte FaaS-Bundles fehlschlagen", es="tambien verificar que bundles FaaS invalidos fallen"))
    faas_ai_action_smoke.set_defaults(func=cmd_faas)
    faas_e2e = faas_sub.add_parser("e2e", help=_tx("simulated end-to-end test: real AI generation -> deploy -> invoke", zh="模拟端到端测试：真实 AI 生成 -> 部署 -> 调用", de="simulierter End-to-End-Test: echte KI-Generierung -> Deploy -> Aufruf", es="prueba end-to-end simulada: generacion IA real -> deploy -> invocacion"), usage=_tx("myapp-ctl faas e2e [options]", zh="myapp-ctl faas e2e [选项]", de="myapp-ctl faas e2e [Optionen]", es="myapp-ctl faas e2e [opciones]"))
    faas_e2e.add_argument("--base-url", default=None, help=_tx("backend base URL (default in-container 127.0.0.1:5566)", zh="后端 base URL（默认容器内 127.0.0.1:5566）", de="Backend-Basis-URL (Standard im Container 127.0.0.1:5566)", es="URL base backend (por defecto en contenedor 127.0.0.1:5566)"))
    faas_e2e.add_argument("--provider", default="minimax", help=_tx("AI provider id used for generation", zh="生成使用的 AI 供应商 id", de="KI-Anbieter-ID fuer die Generierung", es="id del proveedor IA para la generacion"))
    faas_e2e.add_argument("--agent", default="claude", help=_tx("agent id used for generation", zh="生成使用的 agent id", de="Agent-ID fuer die Generierung", es="id del agente para la generacion"))
    faas_e2e.add_argument("--timeout", type=int, default=900, help=_tx("max seconds to wait per generation", zh="每次生成等待的最大秒数", de="maximale Wartezeit pro Generierung in Sekunden", es="segundos maximos de espera por generacion"))
    faas_e2e.add_argument("--with-update", action="store_true", help=_tx("also run the update path (second generation)", zh="同时跑更新路径（第二次生成）", de="auch den Update-Pfad ausfuehren (zweite Generierung)", es="ejecutar tambien la ruta de actualizacion (segunda generacion)"))
    faas_e2e.add_argument("--email", default="", help=_tx("test user email (default fixed faas-e2e@e2e.local)", zh="测试用户邮箱（默认固定 faas-e2e@e2e.local）", de="Test-Benutzer-E-Mail (Standard faas-e2e@e2e.local)", es="email de usuario de prueba (por defecto faas-e2e@e2e.local)"))
    faas_e2e.add_argument("--password", default="", help=_tx("test user password (default fixed)", zh="测试用户密码（默认固定）", de="Test-Benutzer-Passwort (Standard fest)", es="password de usuario de prueba (fijo por defecto)"))
    faas_e2e.add_argument("--keep", action="store_true", help=_tx("do not delete the generated service", zh="不删除生成的服务", de="generierten Dienst nicht loeschen", es="no eliminar el servicio generado"))
    faas_e2e.set_defaults(func=cmd_faas)
    faas_mode = faas_sub.add_parser("mode", help=_tx("configure generated FaaS deploy mode", zh="配置生成后端的 FaaS 部署模式", de="Deploy-Modus fuer generierte FaaS konfigurieren", es="configurar modo deploy FaaS generado"), usage=_tx("myapp-ctl faas mode <mode> [options]", zh="myapp-ctl faas mode <模式> [选项]", de="myapp-ctl faas mode <Modus> [Optionen]", es="myapp-ctl faas mode <modo> [opciones]"))
    faas_mode.add_argument("mode", choices=["local-docker", "metadata", "script"], help=_tx("deploy mode: local-docker, metadata, script", zh="部署模式: local-docker, metadata, script", de="Deploy-Modus: local-docker, metadata, script", es="modo de deploy: local-docker, metadata, script"))
    faas_mode.add_argument("--runtime-image", help=_tx("runtime image used by the Docker FaaS", zh="Docker FaaS 使用的 runtime 镜像", de="Runtime-Image fuer die Docker-FaaS", es="imagen runtime usada por la Docker FaaS"))
    faas_mode.add_argument("--bundle-base-url", help=_tx("backend base URL used to fetch runtime bundles", zh="拉取 runtime bundle 的后端 base URL", de="Backend-Basis-URL fuer Bundle-Fetch", es="URL base backend para descargar bundles runtime"))
    faas_mode.add_argument("--public-base-url", help=_tx("public base URL returned for generated FaaS invoke paths", zh="生成 FaaS 调用路径返回的 public base URL", de="oeffentliche Basis-URL fuer generierte FaaS-Aufrufe", es="URL base publica para invocaciones FaaS"))
    faas_mode.add_argument("--deploy-script", help=_tx("deploy script path for script mode", zh="script 模式部署脚本路径", de="Deploy-Script-Pfad fuer script-Modus", es="ruta script deploy para modo script"))
    faas_mode.add_argument("--max-services", type=int, help=_tx("per-user active service limit", zh="每用户活跃服务数量上限", de="aktive Dienste pro Benutzer", es="limite de servicios activos por usuario"))
    faas_mode.set_defaults(func=cmd_faas)
    faas_git = faas_sub.add_parser("git", help=_tx("configure backend-owned FaaS Git storage", zh="配置后端托管的 FaaS Git 存储", de="Backend-eigenen FaaS-Git-Speicher konfigurieren", es="configurar almacenamiento Git FaaS del backend"), usage=_tx("myapp-ctl faas git [options]", zh="myapp-ctl faas git [选项]", de="myapp-ctl faas git [Optionen]", es="myapp-ctl faas git [opciones]"))
    git_enable = faas_git.add_mutually_exclusive_group()
    git_enable.add_argument("--enable", action="store_true", help=_tx("enable Git commits for generated services", zh="启用生成服务的 Git commit", de="Git-Commits fuer generierte Dienste aktivieren", es="activar commits Git para servicios generados"))
    git_enable.add_argument("--disable", action="store_true", help=_tx("disable Git commits for generated services", zh="禁用生成服务的 Git commit", de="Git-Commits fuer generierte Dienste deaktivieren", es="desactivar commits Git para servicios generados"))
    git_push = faas_git.add_mutually_exclusive_group()
    git_push.add_argument("--push", action="store_true", help=_tx("push commits to the configured remote", zh="将 commit 推送到已配置 remote", de="Commits zum konfigurierten Remote pushen", es="enviar commits al remote configurado"))
    git_push.add_argument("--no-push", action="store_true", help=_tx("commit locally but do not push", zh="只本地 commit，不推送", de="lokal committen, nicht pushen", es="commit local sin push"))
    faas_git.add_argument("--remote", help=_tx("Git remote URL; may be SSH or HTTPS token URL", zh="Git remote URL；可用 SSH 或 HTTPS token URL", de="Git-Remote-URL; SSH oder HTTPS-Token-URL", es="URL remote Git; SSH o URL HTTPS con token"))
    faas_git.add_argument("--clear-remote", action="store_true", help=_tx("clear Git remote and disable push", zh="清空 Git remote 并禁用 push", de="Git-Remote leeren und Push deaktivieren", es="limpiar remote Git y desactivar push"))
    faas_git.add_argument("--branch", help=_tx("Git branch for backend-owned commits", zh="后端托管 commit 使用的 Git 分支", de="Git-Branch fuer Backend-Commits", es="rama Git para commits del backend"))
    faas_git.add_argument("--author-name", help=_tx("Git author/committer name", zh="Git 作者/提交者名称", de="Git Autor/Committer Name", es="nombre autor/committer Git"))
    faas_git.add_argument("--author-email", help=_tx("Git author/committer email", zh="Git 作者/提交者邮箱", de="Git Autor/Committer E-Mail", es="email autor/committer Git"))
    faas_git.add_argument("--ssh-key-file", help=_tx("host private key file to copy into MyApp secret-files", zh="复制到 MyApp secret-files 的宿主机私钥文件", de="Host-Private-Key-Datei in MyApp secret-files kopieren", es="archivo de clave privada del host para copiar a secret-files"))
    faas_git.add_argument("--known-hosts-file", help=_tx("host known_hosts file to copy into MyApp secret-files", zh="复制到 MyApp secret-files 的宿主机 known_hosts 文件", de="Host-known_hosts-Datei in MyApp secret-files kopieren", es="archivo known_hosts del host para copiar a secret-files"))
    faas_git.add_argument("--ssh-key-path", help=_tx("container path of the Git SSH key", zh="Git SSH key 的容器内路径", de="Container-Pfad des Git-SSH-Keys", es="ruta de contenedor de la clave SSH Git"))
    faas_git.add_argument("--known-hosts-path", help=_tx("container path of Git known_hosts", zh="Git known_hosts 的容器内路径", de="Container-Pfad fuer Git known_hosts", es="ruta de contenedor de Git known_hosts"))
    faas_git.add_argument("--clear-ssh", action="store_true", help=_tx("clear configured Git SSH key paths", zh="清空已配置的 Git SSH key 路径", de="konfigurierte Git-SSH-Key-Pfade leeren", es="limpiar rutas de clave SSH Git configuradas"))
    faas_git.set_defaults(func=cmd_faas)
    faas_config = faas_sub.add_parser("config", help=_tx("show generated FaaS host config", zh="查看生成 FaaS 主机配置", de="generierte FaaS-Host-Konfiguration anzeigen", es="mostrar config host FaaS generada"), usage=_tx("myapp-ctl faas config [options]", zh="myapp-ctl faas config [选项]", de="myapp-ctl faas config [Optionen]", es="myapp-ctl faas config [opciones]"))
    faas_config.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    faas_config.add_argument("--show-secrets", action="store_true", help=_tx("show raw secret values", zh="显示原始密钥值", de="echte Secret-Werte anzeigen", es="mostrar valores secretos reales"))
    faas_config.set_defaults(func=cmd_faas)
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
    agent_node_ls.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    agent_node_ls.add_argument("--token", help=_tx("admin token for the master backend API", zh="主后端 API 的管理 token", de="Admin-Token fuer die Master-Backend-API", es="token admin para la API del backend maestro"))
    agent_node_ls.add_argument("--namespace", default="public", help=_tx("node namespace to list: public, all, or a user id", zh="要列出的节点 namespace：public、all 或用户 ID", de="Node-Namespace: public, all oder Benutzer-ID", es="namespace de nodos: public, all o id de usuario"))
    agent_node_ls.add_argument("--auth-token", help=_tx("logged-in user access token for private-node view; alternatively MYAPP_AUTH_TOKEN", zh="私有节点视角使用的已登录用户 access token；也可用 MYAPP_AUTH_TOKEN", de="Access-Token des angemeldeten Benutzers fuer Private-Node-Ansicht; alternativ MYAPP_AUTH_TOKEN", es="access token del usuario para vista privada; alternativamente MYAPP_AUTH_TOKEN"))
    agent_node_ls.add_argument("--no-probe", action="store_true", help=_tx("do not call each agent-node /health", zh="不调用每个 agent-node 的 /health", de="/health der einzelnen agent-nodes nicht abfragen", es="no llamar /health de cada agent-node"))
    agent_node_ls.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    agent_node_ls.set_defaults(func=cmd_agent_node)
    agent_node_status = agent_node_sub.add_parser("status", help=_tx("show cluster agent host status", zh="查看集群 Agent 节点状态", de="Status eines Cluster-Agent-Hosts anzeigen", es="mostrar estado del host agent"), usage=_tx("myapp-ctl agent-node status [node-id] [options]", zh="myapp-ctl agent-node status [节点ID] [选项]", de="myapp-ctl agent-node status [Node-ID] [Optionen]", es="myapp-ctl agent-node status [node-id] [opciones]"))
    agent_node_status.add_argument("node_id", nargs="?", help=_tx("agent node id", zh="Agent 节点 ID", de="Agent-Node-ID", es="id de agent node"))
    agent_node_status.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    agent_node_status.add_argument("--token", help=_tx("admin token for the master backend API", zh="主后端 API 的管理 token", de="Admin-Token fuer die Master-Backend-API", es="token admin para la API del backend maestro"))
    agent_node_status.add_argument("--namespace", default="public", help=_tx("node namespace to list when node-id is omitted: public, all, or a user id", zh="省略节点 ID 时列出的 namespace：public、all 或用户 ID", de="Namespace beim Auflisten ohne Node-ID: public, all oder Benutzer-ID", es="namespace al listar sin node-id: public, all o id de usuario"))
    agent_node_status.add_argument("--auth-token", help=_tx("logged-in user access token for private-node view; alternatively MYAPP_AUTH_TOKEN", zh="私有节点视角使用的已登录用户 access token；也可用 MYAPP_AUTH_TOKEN", de="Access-Token des angemeldeten Benutzers fuer Private-Node-Ansicht; alternativ MYAPP_AUTH_TOKEN", es="access token del usuario para vista privada; alternativamente MYAPP_AUTH_TOKEN"))
    agent_node_status.add_argument("--no-probe", action="store_true", help=_tx("only used when node_id is omitted", zh="仅在省略 node_id 时使用", de="nur verwendet, wenn node_id fehlt", es="solo se usa cuando se omite node_id"))
    agent_node_status.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    agent_node_status.set_defaults(func=cmd_agent_node)
    agent_node_register = agent_node_sub.add_parser("register", help=_tx("register this agent host to the master backend", zh="将本 Agent 节点注册到主后端", de="diesen Agent-Host beim Master-Backend registrieren", es="registrar este host agent en el backend maestro"), usage=_tx("myapp-ctl agent-node register [options]", zh="myapp-ctl agent-node register [选项]", de="myapp-ctl agent-node register [Optionen]", es="myapp-ctl agent-node register [opciones]"))
    agent_node_register.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    agent_node_register.add_argument("--url", help=_tx("public agent-node URL advertised to the backend", zh="上报给后端的公网 agent-node URL", de="oeffentliche agent-node URL fuer das Backend", es="URL publica de agent-node anunciada al backend"))
    agent_node_register.add_argument("--node-id", help=_tx("node identifier; defaults to AGENT_NODE_ID", zh="节点 ID；默认 AGENT_NODE_ID", de="Node-ID; Standard AGENT_NODE_ID", es="id de nodo; por defecto AGENT_NODE_ID"))
    agent_node_register.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    agent_node_register.add_argument("--capacity", type=int, default=10, help=_tx("max concurrent agent runs on this node", zh="本节点最大并发 Agent 任务数", de="max. gleichzeitige Agent-Laeufe auf diesem Node", es="maximo de tareas agent concurrentes en este nodo"))
    agent_node_register.add_argument("--queue-max", type=int, default=100, help=_tx("max queued jobs on this node", zh="本节点最大排队任务数", de="max. wartende Jobs auf diesem Node", es="maximo de trabajos en cola en este nodo"))
    agent_node_register.add_argument("--ttl", type=int, default=120, help=_tx("node heartbeat lease TTL in seconds", zh="节点心跳租约 TTL（秒）", de="Node-Heartbeat-Lease-TTL in Sekunden", es="TTL del lease de heartbeat del nodo en segundos"))
    agent_node_register.add_argument("--token", help=_tx("admin token for the master backend API", zh="主后端 API 的管理 token", de="Admin-Token fuer die Master-Backend-API", es="token admin para la API del backend maestro"))
    agent_node_register.add_argument("--label", action="append", help=_tx("node label tag; repeatable", zh="节点标签；可重复", de="Node-Label; wiederholbar", es="etiqueta de nodo; repetible"))
    agent_node_register.set_defaults(func=cmd_agent_node)
    agent_node_rm = agent_node_sub.add_parser("rm", help=_tx("remove a registered agent host from the master registry", zh="从主注册表移除已注册 Agent 节点", de="registrierten Agent-Host aus Master-Registry entfernen", es="eliminar host agent registrado del registro maestro"), usage=_tx("myapp-ctl agent-node rm <node-id> [options]", zh="myapp-ctl agent-node rm <节点ID> [选项]", de="myapp-ctl agent-node rm <Node-ID> [Optionen]", es="myapp-ctl agent-node rm <node-id> [opciones]"))
    agent_node_rm.add_argument("node_id", help=_tx("agent node id", zh="Agent 节点 ID", de="Agent-Node-ID", es="id de agent node"))
    agent_node_rm.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    agent_node_rm.add_argument("--token", help=_tx("admin token for the master backend API", zh="主后端 API 的管理 token", de="Admin-Token fuer die Master-Backend-API", es="token admin para la API del backend maestro"))
    agent_node_rm.set_defaults(func=cmd_agent_node)
    agent_node_pause = agent_node_sub.add_parser("pause", help=_tx("pause scheduling for an agent host without stopping current runs", zh="暂停 Agent 节点调度，不停止当前任务", de="Scheduling fuer Agent-Host pausieren, laufende Jobs nicht stoppen", es="pausar planificacion del host agent sin detener tareas actuales"), usage=_tx("myapp-ctl agent-node pause [node-id] [options]", zh="myapp-ctl agent-node pause [节点ID] [选项]", de="myapp-ctl agent-node pause [Node-ID] [Optionen]", es="myapp-ctl agent-node pause [node-id] [opciones]"))
    agent_node_pause.add_argument("node_id", nargs="?", help=_tx("defaults to local AGENT_NODE_ID", zh="默认使用本机 AGENT_NODE_ID", de="Standard ist lokale AGENT_NODE_ID", es="por defecto usa AGENT_NODE_ID local"))
    agent_node_pause.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    agent_node_pause.add_argument("--token", help=_tx("admin token for the master backend API", zh="主后端 API 的管理 token", de="Admin-Token fuer die Master-Backend-API", es="token admin para la API del backend maestro"))
    agent_node_pause.add_argument("--reason", default="", help=_tx("optional pause reason note", zh="可选的暂停原因备注", de="optionale Pausengrund-Notiz", es="nota opcional del motivo de pausa"))
    agent_node_pause.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    agent_node_pause.set_defaults(func=cmd_agent_node)
    agent_node_resume = agent_node_sub.add_parser("resume", help=_tx("resume scheduling for an agent host", zh="恢复 Agent 节点调度", de="Scheduling fuer Agent-Host fortsetzen", es="reanudar planificacion del host agent"), usage=_tx("myapp-ctl agent-node resume [node-id] [options]", zh="myapp-ctl agent-node resume [节点ID] [选项]", de="myapp-ctl agent-node resume [Node-ID] [Optionen]", es="myapp-ctl agent-node resume [node-id] [opciones]"))
    agent_node_resume.add_argument("node_id", nargs="?", help=_tx("defaults to local AGENT_NODE_ID", zh="默认使用本机 AGENT_NODE_ID", de="Standard ist lokale AGENT_NODE_ID", es="por defecto usa AGENT_NODE_ID local"))
    agent_node_resume.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    agent_node_resume.add_argument("--token", help=_tx("admin token for the master backend API", zh="主后端 API 的管理 token", de="Admin-Token fuer die Master-Backend-API", es="token admin para la API del backend maestro"))
    agent_node_resume.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    agent_node_resume.set_defaults(func=cmd_agent_node)
    agent_node_capacity = agent_node_sub.add_parser("capacity", help=_tx("hot-update local pull agent capacity", zh="热更新本机 pull Agent 并发", de="lokale Pull-Agent-Kapazitaet live aktualisieren", es="actualizar en caliente la capacidad local del agent pull"), usage=_tx("myapp-ctl agent-node capacity <n> [options]", zh="myapp-ctl agent-node capacity <n> [选项]", de="myapp-ctl agent-node capacity <n> [Optionen]", es="myapp-ctl agent-node capacity <n> [opciones]"))
    agent_node_capacity.add_argument("capacity", type=int, help=_tx("new max concurrent agent runs", zh="新的最大并发 Agent 任务数", de="neue max. gleichzeitige Agent-Laeufe", es="nuevo maximo de tareas agent concurrentes"))
    agent_node_capacity.add_argument("--queue-max", type=int, help=_tx("local pull queue max reported by this agent node", zh="本 Agent 节点上报的本地 pull 队列上限", de="lokales Pull-Queue-Maximum, das dieser Agent meldet", es="maximo de cola pull local reportado por este agent"))
    agent_node_capacity.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    agent_node_capacity.add_argument("--token", help=_tx("admin token for the master backend API", zh="主后端 API 的管理 token", de="Admin-Token fuer die Master-Backend-API", es="token admin para la API del backend maestro"))
    agent_node_capacity.add_argument("--no-restart", action="store_true", help=_tx("deprecated; limits are hot-updated without restart", zh="已废弃；限制现在会无重启热更新", de="veraltet; Limits werden ohne Neustart live aktualisiert", es="obsoleto; los limites se actualizan sin reinicio"))
    agent_node_capacity.add_argument("--force", action="store_true", help=_tx("deprecated; active runs are never interrupted by limits updates", zh="已废弃；更新限制不会中断活跃任务", de="veraltet; aktive Laeufe werden durch Limit-Updates nie unterbrochen", es="obsoleto; las tareas activas no se interrumpen por cambios de limites"))
    agent_node_capacity.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    agent_node_capacity.set_defaults(func=cmd_agent_node)
    agent_node_limits = agent_node_sub.add_parser("limits", help=_tx("hot-update local pull agent capacity/queue limits", zh="热更新本机 pull Agent 并发/队列限制", de="lokale Pull-Agent-Kapazitaet/Queue-Limits live aktualisieren", es="actualizar en caliente capacidad/cola local del agent pull"), usage=_tx("myapp-ctl agent-node limits [options]", zh="myapp-ctl agent-node limits [选项]", de="myapp-ctl agent-node limits [Optionen]", es="myapp-ctl agent-node limits [opciones]"))
    agent_node_limits.add_argument("--capacity", type=int, help=_tx("max concurrent agent runs on this node", zh="本节点最大并发 Agent 任务数", de="max. gleichzeitige Agent-Laeufe auf diesem Node", es="maximo de tareas agent concurrentes en este nodo"))
    agent_node_limits.add_argument("--queue-max", type=int, help=_tx("max queued jobs on this node", zh="本节点最大排队任务数", de="max. wartende Jobs auf diesem Node", es="maximo de trabajos en cola en este nodo"))
    agent_node_limits.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    agent_node_limits.add_argument("--token", help=_tx("admin token for the master backend API", zh="主后端 API 的管理 token", de="Admin-Token fuer die Master-Backend-API", es="token admin para la API del backend maestro"))
    agent_node_limits.add_argument("--no-restart", action="store_true", help=_tx("deprecated; limits are hot-updated without restart", zh="已废弃；限制现在会无重启热更新", de="veraltet; Limits werden ohne Neustart live aktualisiert", es="obsoleto; los limites se actualizan sin reinicio"))
    agent_node_limits.add_argument("--force", action="store_true", help=_tx("deprecated; active runs are never interrupted by limits updates", zh="已废弃；更新限制不会中断活跃任务", de="veraltet; aktive Laeufe werden durch Limit-Updates nie unterbrochen", es="obsoleto; las tareas activas no se interrumpen por cambios de limites"))
    agent_node_limits.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    agent_node_limits.set_defaults(func=cmd_agent_node)
    agent_node_private = agent_node_sub.add_parser("private", help=_tx("manage a user-private agent node", zh="管理用户私有 Agent 节点", de="privaten Benutzer-Agent-Node verwalten", es="gestionar agent node privado de usuario"), usage=_tx("myapp-ctl agent-node private <command> [args]", zh="myapp-ctl agent-node private <命令> [参数]", de="myapp-ctl agent-node private <Befehl> [Argumente]", es="myapp-ctl agent-node private <comando> [args]"))
    agent_node_private_sub = _add_subcommands(agent_node_private, "private_cmd")
    private_ls = agent_node_private_sub.add_parser("ls", help=_tx("list only the current user's private agent nodes", zh="仅列出当前用户自己的私有 Agent 节点", de="nur private Agent-Nodes des aktuellen Benutzers auflisten", es="listar solo los agent nodes privados del usuario actual"), usage=_tx("myapp-ctl agent-node private ls [options]", zh="myapp-ctl agent-node private ls [选项]", de="myapp-ctl agent-node private ls [Optionen]", es="myapp-ctl agent-node private ls [opciones]"))
    private_ls.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    private_ls.add_argument("--auth-token", help=_tx("logged-in user access token; alternatively MYAPP_AUTH_TOKEN", zh="已登录用户 access token；也可用 MYAPP_AUTH_TOKEN", de="Access-Token des angemeldeten Benutzers; alternativ MYAPP_AUTH_TOKEN", es="access token del usuario autenticado; alternativamente MYAPP_AUTH_TOKEN"))
    private_ls.add_argument("--no-probe", action="store_true", help=_tx("do not call each private agent-node /health", zh="不调用每个私有 agent-node 的 /health", de="/health der privaten agent-nodes nicht abfragen", es="no llamar /health de cada agent-node privado"))
    private_ls.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    private_ls.set_defaults(func=cmd_agent_node)
    private_status = agent_node_private_sub.add_parser("status", help=_tx("show only the current user's private agent-node status", zh="仅查看当前用户自己的私有 Agent 节点状态", de="Status eines privaten Agent-Nodes des aktuellen Benutzers anzeigen", es="mostrar estado del agent node privado del usuario actual"), usage=_tx("myapp-ctl agent-node private status [node-id] [options]", zh="myapp-ctl agent-node private status [节点ID] [选项]", de="myapp-ctl agent-node private status [Node-ID] [Optionen]", es="myapp-ctl agent-node private status [node-id] [opciones]"))
    private_status.add_argument("node_id", nargs="?", help=_tx("agent node id", zh="Agent 节点 ID", de="Agent-Node-ID", es="id de agent node"))
    private_status.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    private_status.add_argument("--auth-token", help=_tx("logged-in user access token; alternatively MYAPP_AUTH_TOKEN", zh="已登录用户 access token；也可用 MYAPP_AUTH_TOKEN", de="Access-Token des angemeldeten Benutzers; alternativ MYAPP_AUTH_TOKEN", es="access token del usuario autenticado; alternativamente MYAPP_AUTH_TOKEN"))
    private_status.add_argument("--no-probe", action="store_true", help=_tx("do not call each private agent-node /health", zh="不调用每个私有 agent-node 的 /health", de="/health der privaten agent-nodes nicht abfragen", es="no llamar /health de cada agent-node privado"))
    private_status.add_argument("--json", action="store_true", help=_tx("output machine-readable JSON", zh="输出机器可读 JSON", de="maschinenlesbares JSON ausgeben", es="mostrar JSON legible por maquina"))
    private_status.set_defaults(func=cmd_agent_node)
    private_join = agent_node_private_sub.add_parser("join", help=_tx("register and deploy a private pull agent node", zh="注册并部署私有 pull Agent 节点", de="privaten Pull-Agent-Node registrieren und deployen", es="registrar y desplegar agent node pull privado"), usage=_tx("myapp-ctl agent-node private join [options]", zh="myapp-ctl agent-node private join [选项]", de="myapp-ctl agent-node private join [Optionen]", es="myapp-ctl agent-node private join [opciones]"))
    private_join.add_argument("--backend", required=True, help=_tx("backend URL, for example https://myapp-backend.example.com", zh="后端 URL，例如 https://myapp-backend.example.com", de="Backend-URL, z.B. https://myapp-backend.example.com", es="URL del backend, por ejemplo https://myapp-backend.example.com"))
    private_join.add_argument("--join-token", help=_tx("short-lived private agent join token from app settings; alternatively MYAPP_PRIVATE_AGENT_JOIN_TOKEN", zh="从 App 设置页获取的短期私有 Agent 加入令牌；也可用 MYAPP_PRIVATE_AGENT_JOIN_TOKEN", de="kurzlebiges Private-Agent-Join-Token aus App-Einstellungen; alternativ MYAPP_PRIVATE_AGENT_JOIN_TOKEN", es="token corto de union de agent privado desde ajustes; alternativamente MYAPP_PRIVATE_AGENT_JOIN_TOKEN"))
    private_join.add_argument("--auth-token", help=_tx("logged-in user access token; alternatively MYAPP_AUTH_TOKEN", zh="已登录用户 access token；也可用 MYAPP_AUTH_TOKEN", de="Access-Token des angemeldeten Benutzers; alternativ MYAPP_AUTH_TOKEN", es="access token del usuario autenticado; alternativamente MYAPP_AUTH_TOKEN"))
    private_join.add_argument("--node-id", help=_tx("node identifier; defaults to AGENT_NODE_ID", zh="节点 ID；默认 AGENT_NODE_ID", de="Node-ID; Standard AGENT_NODE_ID", es="id de nodo; por defecto AGENT_NODE_ID"))
    private_join.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    private_join.add_argument("--host", help=_tx("this agent host public IP or domain", zh="本 Agent 节点公网 IP 或域名", de="oeffentliche IP oder Domain dieses Agent-Hosts", es="IP publica o dominio de este host agent"))
    private_join.add_argument("--data-root", default=DEFAULT_DATA_ROOT, help=_tx("node persistent data root directory", zh="节点持久化数据根目录", de="persistentes Datenverzeichnis des Nodes", es="directorio raiz de datos persistentes del nodo"))
    private_join.add_argument("--local-port", type=int, default=5590, help=_tx("local agent-node service port", zh="本机 agent-node 服务端口", de="lokaler agent-node Dienstport", es="puerto local del servicio agent-node"))
    private_join.add_argument("--capacity", type=int, default=10, help=_tx("max concurrent agent runs on this node", zh="本节点最大并发 Agent 任务数", de="max. gleichzeitige Agent-Laeufe auf diesem Node", es="maximo de tareas agent concurrentes en este nodo"))
    private_join.add_argument("--queue-max", type=int, default=100, help=_tx("max queued jobs on this node", zh="本节点最大排队任务数", de="max. wartende Jobs auf diesem Node", es="maximo de trabajos en cola en este nodo"))
    private_join.add_argument("--ttl", type=int, default=120, help=_tx("node heartbeat lease TTL in seconds", zh="节点心跳租约 TTL（秒）", de="Node-Heartbeat-Lease-TTL in Sekunden", es="TTL del lease de heartbeat del nodo en segundos"))
    private_join.add_argument("--provider", action="append", default=[], help=_tx("local provider id supported by this node; repeatable", zh="本节点支持的本地供应商 ID；可重复", de="lokale Provider-ID dieses Nodes; wiederholbar", es="id de proveedor local soportado; repetible"))
    private_join.add_argument("--agent", action="append", default=[], help=_tx("filter local adapters by agent id; repeatable", zh="按 Agent ID 过滤本地 adapter；可重复", de="lokale Adapter nach Agent-ID filtern; wiederholbar", es="filtrar adaptadores locales por id de agent; repetible"))
    private_join.add_argument("--capability", action="append", default=[], help=_tx("explicit local capability provider:agent[:adapter]; repeatable", zh="显式本地能力 provider:agent[:adapter]；可重复", de="explizite lokale Faehigkeit provider:agent[:adapter]; wiederholbar", es="capacidad local explicita provider:agent[:adapter]; repetible"))
    private_join.add_argument("--label", action="append", help=_tx("node label tag; repeatable", zh="节点标签；可重复", de="Node-Label; wiederholbar", es="etiqueta de nodo; repetible"))
    private_join.add_argument("--pull", action="store_true", help=_tx("pull configured images before deploy", zh="部署前拉取已配置镜像", de="konfigurierte Images vor Deploy laden", es="descargar imagenes configuradas antes de desplegar"))
    private_join.add_argument("--build", action="store_true", help=_tx("build images from local source before deploy", zh="部署前从本地源码构建镜像", de="Images vor Deploy aus lokalem Quellcode bauen", es="construir imagenes desde codigo local antes de desplegar"))
    private_join.add_argument("--base", action="store_true", help=_tx("also build or pull base images", zh="同时构建或拉取 base 镜像", de="auch Base-Images bauen oder laden", es="construir o descargar tambien imagenes base"))
    private_join.add_argument("--no-provider-setup", action="store_true", help=_tx("do not prompt for local AI provider config", zh="不交互配置本地 AI 供应商", de="nicht nach lokaler KI-Provider-Konfiguration fragen", es="no pedir configuracion local de proveedor IA"))
    private_join.add_argument("--replace-existing-agent-node", action="store_true", help=_tx("allow replacing the singleton myapp-agent-node on this host", zh="允许替换本机 singleton myapp-agent-node", de="Singleton myapp-agent-node auf diesem Host ersetzen", es="permitir reemplazar el singleton myapp-agent-node de este host"))
    private_join.set_defaults(func=cmd_agent_node)
    agent_node_add = agent_node_sub.add_parser("add", help=_tx("print a join command for a new agent host", zh="打印新 Agent 节点的一键加入命令", de="Join-Befehl fuer neuen Agent-Host ausgeben", es="imprimir comando join para nuevo host agent"), usage=_tx("myapp-ctl agent-node add [options]", zh="myapp-ctl agent-node add [选项]", de="myapp-ctl agent-node add [Optionen]", es="myapp-ctl agent-node add [opciones]"))
    agent_node_add.add_argument("--backend", help=_tx("master backend URL, for example http://<master-host>:5566", zh="主后端 URL，例如 http://<master-host>:5566", de="Master-Backend-URL, z.B. http://<master-host>:5566", es="URL del backend maestro, por ejemplo http://<master-host>:5566"))
    agent_node_add.add_argument("--host", help=_tx("new agent host public IP or domain", zh="新 Agent 节点公网 IP 或域名", de="oeffentliche IP oder Domain des neuen Agent-Hosts", es="IP publica o dominio del nuevo host agent"))
    agent_node_add.add_argument("--url", help=_tx("full public agent-node URL; defaults to http://<host>:<public-port>", zh="完整公网 agent-node URL；默认 http://<host>:<public-port>", de="vollstaendige oeffentliche agent-node URL; Standard http://<host>:<public-port>", es="URL publica completa de agent-node; por defecto http://<host>:<public-port>"))
    agent_node_add.add_argument("--node-id", help=_tx("node identifier; defaults to AGENT_NODE_ID", zh="节点 ID；默认 AGENT_NODE_ID", de="Node-ID; Standard AGENT_NODE_ID", es="id de nodo; por defecto AGENT_NODE_ID"))
    agent_node_add.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    agent_node_add.add_argument("--data-root", default=DEFAULT_DATA_ROOT, help=_tx("node persistent data root directory", zh="节点持久化数据根目录", de="persistentes Datenverzeichnis des Nodes", es="directorio raiz de datos persistentes del nodo"))
    agent_node_add.add_argument("--local-port", type=int, default=5590, help=_tx("local agent-node service port", zh="本机 agent-node 服务端口", de="lokaler agent-node Dienstport", es="puerto local del servicio agent-node"))
    agent_node_add.add_argument("--public-port", type=int, default=5591, help=_tx("public agent-node service port", zh="公网 agent-node 服务端口", de="oeffentlicher agent-node Dienstport", es="puerto publico del servicio agent-node"))
    agent_node_add.add_argument("--capacity", type=int, default=10, help=_tx("max concurrent agent runs on this node", zh="本节点最大并发 Agent 任务数", de="max. gleichzeitige Agent-Laeufe auf diesem Node", es="maximo de tareas agent concurrentes en este nodo"))
    agent_node_add.add_argument("--queue-max", type=int, default=100, help=_tx("max queued jobs on this node", zh="本节点最大排队任务数", de="max. wartende Jobs auf diesem Node", es="maximo de trabajos en cola en este nodo"))
    agent_node_add.add_argument("--ttl", type=int, default=180, help=_tx("node heartbeat lease TTL in seconds", zh="节点心跳租约 TTL（秒）", de="Node-Heartbeat-Lease-TTL in Sekunden", es="TTL del lease de heartbeat del nodo en segundos"))
    agent_node_add.add_argument("--label", action="append", help=_tx("node label tag; repeatable", zh="节点标签；可重复", de="Node-Label; wiederholbar", es="etiqueta de nodo; repetible"))
    agent_node_add.add_argument("--mode", choices=["pull", "direct"], default="pull", metavar="MODE", help=_tx("agent connection mode: pull, direct", zh="Agent 连接模式: pull, direct", de="Agent-Verbindungsmodus: pull, direct", es="modo de conexion agent: pull, direct"))
    agent_node_add.add_argument("--provider-mode", choices=["master", "local"], default="master", metavar="MODE", help=_tx("provider key source: master, local", zh="供应商密钥来源: master, local", de="Provider-Key-Quelle: master, local", es="origen de claves del proveedor: master, local"))
    agent_node_add.add_argument("--pull", action="store_true", help=_tx("make the join command pull required images", zh="生成的加入命令会拉取所需镜像", de="Join-Befehl laedt benoetigte Images", es="el comando join descargara imagenes necesarias"))
    agent_node_add.add_argument("--build", action="store_true", help=_tx("make the join command build required images locally", zh="生成的加入命令会在本地构建所需镜像", de="Join-Befehl baut benoetigte Images lokal", es="el comando join construira imagenes localmente"))
    agent_node_add.add_argument("--base", action="store_true", help=_tx("make the join command also process base images", zh="生成的加入命令也处理 base 镜像", de="Join-Befehl verarbeitet auch Base-Images", es="el comando join tambien procesara imagenes base"))
    agent_node_add.add_argument("--no-nginx", action="store_true", help=_tx("skip nginx reverse-proxy setup on the node", zh="跳过节点 nginx 反向代理配置", de="nginx-Reverse-Proxy-Setup ueberspringen", es="omitir configuracion de nginx en el nodo"))
    agent_node_add.add_argument("--allow-from", help=_tx("optional source IP allowed through ufw for the public agent port", zh="可选：允许通过 ufw 访问公网 Agent 端口的来源 IP", de="optionale Quell-IP, die ufw fuer den oeffentlichen Agent-Port erlaubt", es="IP origen opcional permitida por ufw para el puerto agent publico"))
    agent_node_add.add_argument("--no-timer", action="store_true", help=_tx("skip the systemd heartbeat timer setup", zh="跳过 systemd 心跳定时器配置", de="systemd-Heartbeat-Timer-Setup ueberspringen", es="omitir configuracion del timer systemd"))
    agent_node_add.set_defaults(func=cmd_agent_node)
    agent_node_join = agent_node_sub.add_parser("join", help=_tx("join this host to a master backend as an agent node", zh="将本机作为 Agent 节点加入主后端", de="diesen Host als Agent-Node an Master-Backend anbinden", es="unir este host al backend maestro como agent node"), usage=_tx("myapp-ctl agent-node join --backend <url> --node-id <id> [options]", zh="myapp-ctl agent-node join --backend <url> --node-id <id> [选项]", de="myapp-ctl agent-node join --backend <url> --node-id <id> [Optionen]", es="myapp-ctl agent-node join --backend <url> --node-id <id> [opciones]"))
    agent_node_join.add_argument("--backend", required=True, help=_tx("master backend URL", zh="主后端 URL", de="Master-Backend-URL", es="URL del backend maestro"))
    agent_node_join.add_argument("--host", help=_tx("this agent host display IP or domain", zh="本 Agent 节点展示 IP 或域名", de="Anzeige-IP oder Domain dieses Agent-Hosts", es="IP o dominio mostrado de este host agent"))
    agent_node_join.add_argument("--url", help=_tx("agent-node URL; pull mode defaults to pull://<node-id>", zh="agent-node URL；pull 模式默认 pull://<node-id>", de="agent-node URL; Pull-Modus nutzt standardmaessig pull://<node-id>", es="URL de agent-node; modo pull usa por defecto pull://<node-id>"))
    agent_node_join.add_argument("--node-id", required=True, help=_tx("node identifier; defaults to AGENT_NODE_ID", zh="节点 ID；默认 AGENT_NODE_ID", de="Node-ID; Standard AGENT_NODE_ID", es="id de nodo; por defecto AGENT_NODE_ID"))
    agent_node_join.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    agent_node_join.add_argument("--data-root", default=DEFAULT_DATA_ROOT, help=_tx("node persistent data root directory", zh="节点持久化数据根目录", de="persistentes Datenverzeichnis des Nodes", es="directorio raiz de datos persistentes del nodo"))
    agent_node_join.add_argument("--local-port", type=int, default=5590, help=_tx("local agent-node service port", zh="本机 agent-node 服务端口", de="lokaler agent-node Dienstport", es="puerto local del servicio agent-node"))
    agent_node_join.add_argument("--public-port", type=int, default=5591, help=_tx("public agent-node service port", zh="公网 agent-node 服务端口", de="oeffentlicher agent-node Dienstport", es="puerto publico del servicio agent-node"))
    agent_node_join.add_argument("--capacity", type=int, default=10, help=_tx("max concurrent agent runs on this node", zh="本节点最大并发 Agent 任务数", de="max. gleichzeitige Agent-Laeufe auf diesem Node", es="maximo de tareas agent concurrentes en este nodo"))
    agent_node_join.add_argument("--queue-max", type=int, default=100, help=_tx("max queued jobs on this node", zh="本节点最大排队任务数", de="max. wartende Jobs auf diesem Node", es="maximo de trabajos en cola en este nodo"))
    agent_node_join.add_argument("--ttl", type=int, default=180, help=_tx("node heartbeat lease TTL in seconds", zh="节点心跳租约 TTL（秒）", de="Node-Heartbeat-Lease-TTL in Sekunden", es="TTL del lease de heartbeat del nodo en segundos"))
    agent_node_join.add_argument("--label", action="append", help=_tx("node label tag; repeatable", zh="节点标签；可重复", de="Node-Label; wiederholbar", es="etiqueta de nodo; repetible"))
    agent_node_join.add_argument("--mode", choices=["pull", "direct"], default="pull", metavar="MODE", help=_tx("agent connection mode: pull, direct", zh="Agent 连接模式: pull, direct", de="Agent-Verbindungsmodus: pull, direct", es="modo de conexion agent: pull, direct"))
    agent_node_join.add_argument("--provider-mode", choices=["master", "local"], default="master", metavar="MODE", help=_tx("provider key source: master, local", zh="供应商密钥来源: master, local", de="Provider-Key-Quelle: master, local", es="origen de claves del proveedor: master, local"))
    agent_node_join.add_argument("--agent-token", required=True, help=_tx("agent runtime auth token from agent-node add", zh="来自 agent-node add 的 Agent 运行时 token", de="Agent-Runtime-Token aus agent-node add", es="token de runtime agent de agent-node add"))
    agent_node_join.add_argument("--registration-token", required=True, help=_tx("node registration token from agent-node add", zh="来自 agent-node add 的节点注册 token", de="Node-Registrierungstoken aus agent-node add", es="token de registro de nodo de agent-node add"))
    agent_node_join.add_argument("--pull", action="store_true", help=_tx("pull required images before deploy", zh="部署前拉取所需镜像", de="benoetigte Images vor dem Deploy laden", es="descargar imagenes necesarias antes de desplegar"))
    agent_node_join.add_argument("--build", action="store_true", help=_tx("build required images locally before deploy", zh="部署前在本地构建所需镜像", de="benoetigte Images lokal vor dem Deploy bauen", es="construir imagenes localmente antes de desplegar"))
    agent_node_join.add_argument("--base", action="store_true", help=_tx("also build or pull base images", zh="同时构建或拉取 base 镜像", de="auch Base-Images bauen oder laden", es="construir o descargar tambien imagenes base"))
    agent_node_join.add_argument("--no-nginx", action="store_true", help=_tx("skip nginx reverse-proxy setup on the node", zh="跳过节点 nginx 反向代理配置", de="nginx-Reverse-Proxy-Setup ueberspringen", es="omitir configuracion de nginx en el nodo"))
    agent_node_join.add_argument("--allow-from", help=_tx("optional source IP allowed through ufw for the public agent port", zh="可选：允许通过 ufw 访问公网 Agent 端口的来源 IP", de="optionale Quell-IP, die ufw fuer den oeffentlichen Agent-Port erlaubt", es="IP origen opcional permitida por ufw para el puerto agent publico"))
    agent_node_join.add_argument("--no-timer", action="store_true", help=_tx("skip the systemd heartbeat timer setup", zh="跳过 systemd 心跳定时器配置", de="systemd-Heartbeat-Timer-Setup ueberspringen", es="omitir configuracion del timer systemd"))
    agent_node_join.add_argument("--replace-existing-agent-node", action="store_true", help=_tx("allow replacing the singleton myapp-agent-node on this host", zh="允许替换本机 singleton myapp-agent-node", de="Singleton myapp-agent-node auf diesem Host ersetzen", es="permitir reemplazar el singleton myapp-agent-node de este host"))
    agent_node_join.set_defaults(func=cmd_agent_node)
    agent = sub.add_parser("agent", help=_tx("inspect local agent runs", zh="查看本机 Agent 运行任务", de="lokale Agent-Laeufe anzeigen", es="inspeccionar tareas agent locales"), usage=_tx("myapp-ctl agent <command> [args]", zh="myapp-ctl agent <命令> [参数]", de="myapp-ctl agent <Befehl> [Argumente]", es="myapp-ctl agent <comando> [args]"))
    agent_sub = _add_subcommands(agent, "agent_cmd")
    agent_add = agent_sub.add_parser("add", help=_tx("deprecated alias for agent-node add", zh="已废弃：agent-node add 的别名", de="veraltet: Alias fuer agent-node add", es="obsoleto: alias de agent-node add"), usage=_tx("myapp-ctl agent add [options]", zh="myapp-ctl agent add [选项]", de="myapp-ctl agent add [Optionen]", es="myapp-ctl agent add [opciones]"))
    agent_add.add_argument("--backend", help=_tx("master backend URL, for example http://<master-host>:5566", zh="主后端 URL，例如 http://<master-host>:5566", de="Master-Backend-URL, z.B. http://<master-host>:5566", es="URL del backend maestro, por ejemplo http://<master-host>:5566"))
    agent_add.add_argument("--host", help=_tx("new agent host public IP or domain", zh="新 Agent 节点公网 IP 或域名", de="oeffentliche IP oder Domain des neuen Agent-Hosts", es="IP publica o dominio del nuevo host agent"))
    agent_add.add_argument("--url", help=_tx("full public agent-node URL; defaults to http://<host>:<public-port>", zh="完整公网 agent-node URL；默认 http://<host>:<public-port>", de="vollstaendige oeffentliche agent-node URL; Standard http://<host>:<public-port>", es="URL publica completa de agent-node; por defecto http://<host>:<public-port>"))
    agent_add.add_argument("--node-id", help=_tx("node identifier; defaults to AGENT_NODE_ID", zh="节点 ID；默认 AGENT_NODE_ID", de="Node-ID; Standard AGENT_NODE_ID", es="id de nodo; por defecto AGENT_NODE_ID"))
    agent_add.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    agent_add.add_argument("--data-root", default=DEFAULT_DATA_ROOT, help=_tx("node persistent data root directory", zh="节点持久化数据根目录", de="persistentes Datenverzeichnis des Nodes", es="directorio raiz de datos persistentes del nodo"))
    agent_add.add_argument("--local-port", type=int, default=5590, help=_tx("local agent-node service port", zh="本机 agent-node 服务端口", de="lokaler agent-node Dienstport", es="puerto local del servicio agent-node"))
    agent_add.add_argument("--public-port", type=int, default=5591, help=_tx("public agent-node service port", zh="公网 agent-node 服务端口", de="oeffentlicher agent-node Dienstport", es="puerto publico del servicio agent-node"))
    agent_add.add_argument("--capacity", type=int, default=10, help=_tx("max concurrent agent runs on this node", zh="本节点最大并发 Agent 任务数", de="max. gleichzeitige Agent-Laeufe auf diesem Node", es="maximo de tareas agent concurrentes en este nodo"))
    agent_add.add_argument("--queue-max", type=int, default=100, help=_tx("max queued jobs on this node", zh="本节点最大排队任务数", de="max. wartende Jobs auf diesem Node", es="maximo de trabajos en cola en este nodo"))
    agent_add.add_argument("--ttl", type=int, default=180, help=_tx("node heartbeat lease TTL in seconds", zh="节点心跳租约 TTL（秒）", de="Node-Heartbeat-Lease-TTL in Sekunden", es="TTL del lease de heartbeat del nodo en segundos"))
    agent_add.add_argument("--label", action="append", help=_tx("node label tag; repeatable", zh="节点标签；可重复", de="Node-Label; wiederholbar", es="etiqueta de nodo; repetible"))
    agent_add.add_argument("--mode", choices=["pull", "direct"], default="pull", metavar="MODE", help=_tx("agent connection mode: pull, direct", zh="Agent 连接模式: pull, direct", de="Agent-Verbindungsmodus: pull, direct", es="modo de conexion agent: pull, direct"))
    agent_add.add_argument("--provider-mode", choices=["master", "local"], default="master", metavar="MODE", help=_tx("provider key source: master, local", zh="供应商密钥来源: master, local", de="Provider-Key-Quelle: master, local", es="origen de claves del proveedor: master, local"))
    agent_add.add_argument("--pull", action="store_true", help=_tx("generate a pull-based deploy command instead of build", zh="生成基于 pull 的部署命令，而不是 build", de="Pull-basierten Deploy-Befehl statt Build erzeugen", es="generar comando de despliegue pull en lugar de build"))
    agent_add.add_argument("--build", action="store_true", help=_tx("make the join command build required images locally", zh="生成的加入命令会在本地构建所需镜像", de="Join-Befehl baut benoetigte Images lokal", es="el comando join construira imagenes localmente"))
    agent_add.add_argument("--base", action="store_true", help=_tx("make the join command also process base images", zh="生成的加入命令也处理 base 镜像", de="Join-Befehl verarbeitet auch Base-Images", es="el comando join tambien procesara imagenes base"))
    agent_add.add_argument("--no-nginx", action="store_true", help=_tx("skip nginx reverse-proxy setup on the node", zh="跳过节点 nginx 反向代理配置", de="nginx-Reverse-Proxy-Setup ueberspringen", es="omitir configuracion de nginx en el nodo"))
    agent_add.add_argument("--allow-from", help=_tx("optional source IP allowed through ufw for the public agent port", zh="可选：允许通过 ufw 访问公网 Agent 端口的来源 IP", de="optionale Quell-IP, die ufw fuer den oeffentlichen Agent-Port erlaubt", es="IP origen opcional permitida por ufw para el puerto agent publico"))
    agent_add.add_argument("--no-timer", action="store_true", help=_tx("skip the systemd heartbeat timer setup", zh="跳过 systemd 心跳定时器配置", de="systemd-Heartbeat-Timer-Setup ueberspringen", es="omitir configuracion del timer systemd"))
    agent_add.set_defaults(func=cmd_agent)
    agent_ls = agent_sub.add_parser("ls", help=_tx("list current local agent runs", zh="列出本机当前 Agent 任务", de="aktuelle lokale Agent-Laeufe auflisten", es="listar tareas agent locales actuales"), usage=_tx("myapp-ctl agent ls [options]", zh="myapp-ctl agent ls [选项]", de="myapp-ctl agent ls [Optionen]", es="myapp-ctl agent ls [opciones]"))
    agent_ls.add_argument("--url", help=_tx("agent-node URL to query; defaults to local", zh="要查询的 agent-node URL；默认本机", de="abzufragende agent-node URL; Standard lokal", es="URL de agent-node a consultar; por defecto local"))
    # Deprecated no-op flags kept so older shell snippets do not fail, but
    # agent ls is intentionally current-local-runs only.
    agent_ls.add_argument("--history", action="store_true", help=argparse.SUPPRESS)
    agent_ls.add_argument("--limit", type=int, default=20, help=argparse.SUPPRESS)
    agent_ls.set_defaults(func=cmd_agent)
    agent_register = agent_sub.add_parser("register", help=_tx("deprecated alias for agent-node register", zh="已废弃：agent-node register 的别名", de="veraltet: Alias fuer agent-node register", es="obsoleto: alias de agent-node register"), usage=_tx("myapp-ctl agent register [options]", zh="myapp-ctl agent register [选项]", de="myapp-ctl agent register [Optionen]", es="myapp-ctl agent register [opciones]"))
    agent_register.add_argument("--backend", help=_tx("master backend URL; defaults to AGENT_NODE_BACKEND_URL", zh="主后端 URL；默认 AGENT_NODE_BACKEND_URL", de="Master-Backend-URL; Standard AGENT_NODE_BACKEND_URL", es="URL del backend maestro; por defecto AGENT_NODE_BACKEND_URL"))
    agent_register.add_argument("--url", help=_tx("public agent-node URL advertised to the backend", zh="上报给后端的公网 agent-node URL", de="oeffentliche agent-node URL fuer das Backend", es="URL publica de agent-node anunciada al backend"))
    agent_register.add_argument("--node-id", help=_tx("node identifier; defaults to AGENT_NODE_ID", zh="节点 ID；默认 AGENT_NODE_ID", de="Node-ID; Standard AGENT_NODE_ID", es="id de nodo; por defecto AGENT_NODE_ID"))
    agent_register.add_argument("--name", help=_tx("human-readable node name shown in dashboards", zh="控制面板展示的人类可读节点名称", de="lesbarer Node-Name fuer Dashboards", es="nombre legible del nodo para paneles"))
    agent_register.add_argument("--capacity", type=int, default=10, help=_tx("max concurrent agent runs on this node", zh="本节点最大并发 Agent 任务数", de="max. gleichzeitige Agent-Laeufe auf diesem Node", es="maximo de tareas agent concurrentes en este nodo"))
    agent_register.add_argument("--queue-max", type=int, default=100, help=_tx("max queued jobs on this node", zh="本节点最大排队任务数", de="max. wartende Jobs auf diesem Node", es="maximo de trabajos en cola en este nodo"))
    agent_register.add_argument("--ttl", type=int, default=120, help=_tx("node heartbeat lease TTL in seconds", zh="节点心跳租约 TTL（秒）", de="Node-Heartbeat-Lease-TTL in Sekunden", es="TTL del lease de heartbeat del nodo en segundos"))
    agent_register.add_argument("--token", help=_tx("admin token for the master backend API", zh="主后端 API 的管理 token", de="Admin-Token fuer die Master-Backend-API", es="token admin para la API del backend maestro"))
    agent_register.add_argument("--label", action="append", help=_tx("node label tag; repeatable", zh="节点标签；可重复", de="Node-Label; wiederholbar", es="etiqueta de nodo; repetible"))
    agent_register.set_defaults(func=cmd_agent)
    return parser


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


__all__ = ["build_parser", "main"]
