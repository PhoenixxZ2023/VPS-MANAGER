"""Contas Xray do VPS-MANAGER. Formato de banco e operações derivados do XRAY2026."""

from __future__ import annotations

import grp
import json
import logging
import os
import re
import subprocess
import tempfile
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta
from typing import Optional, Tuple

CONFIG_PATH        = "/usr/local/etc/xray/config.json"
PRESET_PATH        = "/usr/local/etc/xray/preset.json"
USER_DB            = "/opt/XrayTools/users.db"
USAGE_DB           = "/opt/XrayTools/usage.db"
LIMITS_DB          = "/opt/XrayTools/limits.db"
ACTIVE_DOMAIN_FILE = "/etc/vps-manager/dominio"
def managed_tag():
    try:
        with open("/etc/vps-manager/xray_profile") as profile:
            tag = profile.read().strip()
        if tag in {"vless-ws", "vless-grpc", "vless-xhttp"}:
            return tag
    except FileNotFoundError:
        pass
    return "vless-ws"

XRAY_SERVICE       = "xray"

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger(__name__)

def _is_valid_nick(nick: str, strict_create: bool = False) -> bool:
    if not nick or nick == "root":
        return False
    if strict_create:
        return bool(re.fullmatch(r"[a-z][a-z0-9_-]{1,31}", nick))
    return bool(re.match(r"^[a-z0-9_-]{2,32}$", nick))


def _ensure_private_file(path: str, mode: int = 0o640) -> None:
    if not os.path.exists(path):
        fd = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY, mode)
        os.close(fd)
    try:
        os.chmod(path, mode)
    except OSError:
        pass


def _append_user_db_line(entry: str) -> None:
    _ensure_private_file(USER_DB, 0o640)
    needs_newline = False
    try:
        if os.path.getsize(USER_DB) > 0:
            with open(USER_DB, "rb") as fb:
                fb.seek(-1, os.SEEK_END)
                if fb.read(1) != b"\n":
                    needs_newline = True
    except OSError:
        pass

    with open(USER_DB, "a", encoding="utf-8") as f:
        if needs_newline:
            f.write("\n")
        f.write(entry)
        f.flush()
        os.fsync(f.fileno())


def _write_user_db_atomic(lines: list[str]) -> None:
    db_dir = os.path.dirname(USER_DB)
    os.makedirs(db_dir, exist_ok=True)
    tmp_db = None
    try:
        fd, tmp_db = tempfile.mkstemp(prefix=".users.db.", suffix=".tmp", dir=db_dir)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.writelines(lines)
            f.flush()
            os.fsync(f.fileno())

        os.chmod(tmp_db, 0o640)
        try:
            bot_gid = grp.getgrnam("botxray").gr_gid
            if os.stat(tmp_db).st_gid != bot_gid:
                os.chown(tmp_db, -1, bot_gid)
        except (KeyError, OSError):
            pass

        os.replace(tmp_db, USER_DB)
        tmp_db = None
    finally:
        if tmp_db and os.path.exists(tmp_db):
            try:
                os.remove(tmp_db)
            except OSError:
                pass


def _get_inbound_profile(data: dict) -> Tuple[str, str]:
    """Retorna (protocol, network) do vless-ws."""
    inbound = next(
        (i for i in data.get("inbounds", []) if i.get("tag") == managed_tag()),
        None,
    )
    if not inbound:
        return "vless", "xhttp"
    proto = inbound.get("protocol", "vless")
    net = inbound.get("streamSettings", {}).get("network", "tcp")
    return proto, net


def _build_client_obj(nick: str, cred: str, proto: str, net: str, data: Optional[dict] = None) -> dict:
    if proto == "trojan":
        return {"password": cred, "email": nick, "level": 0}
    if net == "tcp":
        cfg = data if data is not None else load_config()
        if cfg:
            inb = next((i for i in cfg.get("inbounds", []) if i.get("tag") == managed_tag()), {})
            existing = inb.get("settings", {}).get("clients", [])
            if any(c.get("flow") == "xtls-rprx-vision" for c in existing):
                return {"id": cred, "email": nick, "level": 0, "flow": "xtls-rprx-vision"}
    return {"id": cred, "email": nick, "level": 0}


def reload_xray_user(action: str, nick: str, user_cred: str, inbound_tag: Optional[str] = None) -> bool:
    data = load_config() or {}
    inbounds = data.get("inbounds", [])
    api = next((i for i in inbounds if i.get("tag") == "api"), None)
    tag = inbound_tag or managed_tag()
    target = next((i for i in inbounds if i.get("tag") == tag), None)
    if not api or not target:
        raise RuntimeError("Configuração da API ou do perfil Xray ausente.")
    server = f"--server=127.0.0.1:{api['port']}"
    payload = None
    if action == "add":
        client = next(c for c in target["settings"]["clients"] if c.get("email") == nick)
        inbound = dict(target, settings=dict(target["settings"], clients=[client]))
        payload = json.dumps({"inbounds": [inbound]})
        args = ["adu", server, "stdin:"]
        expected = "Added 1 user(s)"
    else:
        args = ["rmu", server, f"-tag={tag}", nick]
        expected = "Removed 1 user(s)"
    try:
        result = subprocess.run(["/usr/local/bin/xray", "api", *args], input=payload,
                                text=True, capture_output=True, timeout=8)
        if result.returncode == 0 and expected in result.stdout:
            return True
    except subprocess.TimeoutExpired:
        pass
    subprocess.run(["systemctl", "restart", "xray"], check=True, timeout=30)
    return True


def load_config() -> Optional[dict]:
    if not os.path.exists(CONFIG_PATH):
        return None
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        logger.error("JSON corrompido em %s: %s", CONFIG_PATH, e)
        return None
    except OSError as e:
        logger.error("Erro de leitura em %s: %s", CONFIG_PATH, e)
        return None


def save_config(data: dict) -> bool:
    cfg_dir = os.path.dirname(CONFIG_PATH)
    tmp_path = None

    target_gid = -1
    try:
        target_gid = os.stat(CONFIG_PATH).st_gid
    except OSError:
        try:
            target_gid = grp.getgrnam("nogroup").gr_gid
        except KeyError:
            target_gid = -1

    try:
        fd, tmp_path = tempfile.mkstemp(prefix=".config.json.", suffix=".tmp", dir=cfg_dir)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())

        os.chmod(tmp_path, 0o640)
        if target_gid != -1:
            try:
                if os.stat(tmp_path).st_gid != target_gid:
                    os.chown(tmp_path, -1, target_gid)
            except OSError as e:
                logger.warning("save_config: não foi possível ajustar grupo %s: %s", target_gid, e)

        os.replace(tmp_path, CONFIG_PATH)
        tmp_path = None
        return True
    except PermissionError as e:
        logger.error("save_config: sem permissão em %s: %s", cfg_dir, e)
        return False
    except Exception as e:
        logger.error("Erro ao salvar config: %s", e)
        return False
    finally:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass


def get_ip() -> str:
    for url in ("https://icanhazip.com", "https://api.ipify.org"):
        try:
            with urllib.request.urlopen(url, timeout=8) as resp:
                return resp.read().decode("utf-8").strip()
        except Exception as e:
            logger.warning("get_ip falhou em %s: %s", url, e)
    return "127.0.0.1"


def _get_active_domain() -> str:
    if os.path.exists(ACTIVE_DOMAIN_FILE):
        try:
            with open(ACTIVE_DOMAIN_FILE, "r", encoding="utf-8") as f:
                dom = f.read().strip()
                if dom:
                    return dom
        except OSError:
            pass

    if os.path.exists(PRESET_PATH):
        try:
            with open(PRESET_PATH, "r", encoding="utf-8") as f:
                preset = json.load(f)
                dom = (preset.get("domain") or "").strip()
                if dom:
                    return dom
        except Exception:
            pass

    return get_ip()


def bytes_to_human(b: int) -> str:
    if b >= 1073741824:
        return f"{b / 1073741824:.2f} GB"
    if b >= 1048576:
        return f"{b / 1048576:.2f} MB"
    return f"{b / 1024:.2f} KB"


# =============================================================
# GERADOR DE LINKS E RELATÓRIOS
# =============================================================

def generate_link(client_cred: str, client_email: str) -> str:
    try:
        data = load_config()
        if not data:
            return "❌ Erro ao ler config."

        inbound = next(
            (i for i in data.get("inbounds", []) if i.get("tag") == managed_tag()),
            None,
        )
        if not inbound:
            return "❌ vless-ws não encontrado no config."

        port     = 443
        protocol = inbound.get("protocol", "vless")
        stream   = inbound["streamSettings"]
        network  = stream["network"]
        security = "tls"

        sni  = ""
        host = ""
        if security == "tls":
            tls = stream.get("tlsSettings", {})
            sni = (tls.get("serverName") or "").strip()
            if not sni:
                sni = _get_active_domain()
            host = sni
            if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", host):
                sni = ""
        else:
            host = _get_active_domain()
            sni  = ""

        sec_param = "security=tls" if security == "tls" else "security=none"

        if protocol == "trojan":
            return (
                f"trojan://{client_cred}@{host}:{port}"
                f"?{sec_param}&sni={sni}&type=tcp#{client_email}"
            )

        if network == "tcp":
            clients = inbound.get("settings", {}).get("clients", [])
            client  = next((c for c in clients if c.get("id") == client_cred), {})
            flow    = client.get("flow", "")
            if flow == "xtls-rprx-vision":
                return (
                    f"vless://{client_cred}@{host}:{port}"
                    f"?security=tls&encryption=none&type=tcp"
                    f"&headerType=none&flow={flow}&sni={sni}#{client_email}"
                )
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?{sec_param}&encryption=none&type=tcp&headerType=none&sni={sni}#{client_email}"
            )

        if network == "ws":
            raw_path = stream.get("wsSettings", {}).get("path", "/")
            enc_path = urllib.parse.quote(raw_path, safe="")
            ws_host  = sni if sni else host
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?{sec_param}&encryption=none&type=ws"
                f"&alpn=http%2F1.1&host={ws_host}&path={enc_path}&sni={sni}#{client_email}"
            )

        if network == "grpc":
            service = stream.get("grpcSettings", {}).get("serviceName", "gRPC")
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?{sec_param}&encryption=none&type=grpc"
                f"&mode=multi&alpn=h2&serviceName={service}&sni={sni}#{client_email}"
            )

        if network == "xhttp":
            xhttp_cfg  = stream.get("xhttpSettings", {})
            raw_path   = xhttp_cfg.get("path", "/")
            enc_path   = urllib.parse.quote(raw_path, safe="")
            xhttp_host = (xhttp_cfg.get("host") or "").strip() or host
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?mode=auto&{sec_param}&encryption=none&type=xhttp"
                f"&host={xhttp_host}&path={enc_path}&sni={sni}#{client_email}"
            )

        if network == "httpupgrade":
            raw_path = stream.get("httpupgradeSettings", {}).get("path", "/")
            enc_path = urllib.parse.quote(raw_path, safe="")
            hu_host  = sni if sni else host
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?{sec_param}&encryption=none&type=httpupgrade"
                f"&host={hu_host}&path={enc_path}&sni={sni}#{client_email}"
            )

        if network == "h2":
            raw_path = stream.get("httpSettings", {}).get("path", "/")
            enc_path = urllib.parse.quote(raw_path, safe="")
            h2_host  = sni if sni else host
            return (
                f"vless://{client_cred}@{host}:{port}"
                f"?security=tls&encryption=none&type=h2"
                f"&host={h2_host}&path={enc_path}&sni={sni}#{client_email}"
            )

        return "❌ Protocolo não suportado para geração de link."

    except Exception as e:
        return f"Erro Link: {e}"


def core_list_usage_text() -> str:
    """Lê os bancos de dados do limiterxray.sh e formata o consumo."""
    usages = {}
    if os.path.exists(USAGE_DB):
        with open(USAGE_DB, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split("|")
                if len(parts) >= 2 and parts[1].isdigit():
                    usages[parts[0]] = int(parts[1])

    limits = {}
    if os.path.exists(LIMITS_DB):
        with open(LIMITS_DB, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split("|")
                if len(parts) >= 2 and parts[1].isdigit():
                    limits[parts[0]] = int(parts[1])

    all_nicks = set(usages.keys()).union(set(limits.keys()))
    if os.path.exists(USER_DB):
        with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.strip().split("|")
                if parts[0]:
                    all_nicks.add(parts[0])

    if not all_nicks:
        return "Nenhum dado de consumo ou usuário registrado."

    sep = "-" * 60
    header = (
        "📊 RELATÓRIO DE CONSUMO DE DADOS\n"
        + sep + "\n"
        + f"{'USUÁRIO':<14} | {'USADO':<12} | {'LIMITE':<12} | STATUS\n"
        + sep + "\n"
    )
    rows = []

    for nick in sorted(all_nicks):
        use_bytes = usages.get(nick, 0)
        lim_bytes = limits.get(nick, None)

        use_str = bytes_to_human(use_bytes)

        if lim_bytes is None or lim_bytes <= 0:
            lim_str = "Sem limite"
            status  = "Livre"
        else:
            lim_str = bytes_to_human(lim_bytes)
            if use_bytes >= lim_bytes:
                status = "EXCEDIDO"
            else:
                pct    = int((use_bytes * 100) / lim_bytes)
                status = f"{pct}%"

        rows.append(f"{nick:<14} | {use_str:<12} | {lim_str:<12} | {status}")

    return header + "\n".join(rows) + "\n" + sep


def core_list_users_text() -> str:
    if not os.path.exists(USER_DB):
        return "Nenhum usuário cadastrado."

    data         = load_config()
    locked_users = set()
    if data:
        for inbound in data.get("inbounds", []):
            if inbound.get("tag") == managed_tag():
                for c in inbound.get("settings", {}).get("clients", []):
                    email = c.get("email", "")
                    if email.startswith("LOCKED_"):
                        locked_users.add(email.replace("LOCKED_", "", 1))

    sep = "-" * 65
    header = (
        "📋 LISTA DE USUÁRIOS - TURBONET XRAY\n"
        + sep + "\n"
        + f"{'NOME':<12} | {'VENCIMENTO':<11} | {'CREDENCIAL':<20} | STATUS\n"
        + sep + "\n"
    )
    rows = []
    with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.strip().split("|")
            if len(parts) >= 3:
                nick_r, cred_r, expiry_r = parts[0], parts[1], parts[2]
                status     = "⛔" if nick_r in locked_users else "✅"
                cred_short = cred_r[:8] + "..." + cred_r[-4:] if len(cred_r) >= 12 else cred_r
                rows.append(f"{nick_r:<12} | {expiry_r:<11} | {cred_short:<20} | {status}")

    footer = "\n" + sep + f"\nTotal: {len(rows)} usuário(s)"
    return header + "\n".join(rows) + footer if rows else header + "(vazio)"


# =============================================================
# FUNÇÕES CORE DE GERENCIAMENTO (CRIAR, BLOQUEAR, RESTAURAR)
# =============================================================

def core_create_user(nick: str, days: str) -> Tuple[bool, str]:
    if not _is_valid_nick(nick, strict_create=True):
        return False, "❌ Nome de usuário inválido."

    _ensure_private_file(USER_DB, 0o640)
    with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
        if any(line.startswith(f"{nick}|") for line in f):
            return False, "❌ Usuário já existe!"

    data = load_config()
    if not data:
        return False, "❌ Erro ao ler config.json"

    inbound = next(
        (i for i in data.get("inbounds", []) if i.get("tag") == managed_tag()),
        None,
    )
    if not inbound:
        return False, "❌ vless-ws não encontrado."

    existing_emails = {
        c.get("email", "") for c in inbound.get("settings", {}).get("clients", [])
    }
    if nick in existing_emails or f"LOCKED_{nick}" in existing_emails:
        return False, "❌ Usuário já cadastrado no config.json."

    proto, net  = _get_inbound_profile(data)
    user_cred   = uuid.uuid4().hex if proto == "trojan" else str(uuid.uuid4())
    expiry_date = (datetime.now() + timedelta(days=int(days))).strftime("%Y-%m-%d")

    inbound["settings"]["clients"].append(_build_client_obj(nick, user_cred, proto, net, data))

    if not save_config(data):
        return False, "❌ Falha ao salvar config.json."

    _append_user_db_line(f"{nick}|{user_cred}|{expiry_date}|{nick}|0\n")

    if not reload_xray_user("add", nick, user_cred):
        raise RuntimeError("API do Xray indisponível")
    link = generate_link(user_cred, nick)

    cred_label = "Senha Trojan" if proto == "trojan" else "UUID"
    return True, (
        f"✅ Acesso Xray criado\n\n"
        f"Nome: {nick}\nValidade: {expiry_date}\nLink: {link}\n{cred_label}: {user_cred}"
    )


def core_delete_user(nick: str) -> str:
    if not _is_valid_nick(nick):
        return "❌ Nome de usuário inválido."

    data        = load_config()
    found       = False
    cfg_changed = False

    if data:
        for inbound in data.get("inbounds", []):
            if inbound.get("tag") == managed_tag():
                clients     = inbound["settings"]["clients"]
                emails = [c["email"] for c in clients if c.get("email") in (nick, f"LOCKED_{nick}")]
                new_clients = [
                    c for c in clients
                    if c.get("email") not in (nick, f"LOCKED_{nick}")
                ]
                if len(clients) != len(new_clients):
                    found       = True
                    cfg_changed = True
                    inbound["settings"]["clients"] = new_clients
        if cfg_changed and not save_config(data):
            return "❌ Falha ao salvar config.json."

    if os.path.exists(USER_DB):
        with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        new_lines = []
        for line in lines:
            if line.startswith(f"{nick}|"):
                found = True
            else:
                new_lines.append(line)
        _write_user_db_atomic(new_lines)

    if not found:
        return "❌ Usuário não encontrado no sistema."

    if cfg_changed:
        for email in emails:
            reload_xray_user("remove", email, "")
    return "✅ Usuário removido do sistema."


def core_block_user(nick: str) -> str:
    if not _is_valid_nick(nick):
        return "❌ Nome de usuário inválido."

    data = load_config()
    if not data:
        return "❌ Erro config."

    proto, _ = _get_inbound_profile(data)
    found = False
    for inbound in data.get("inbounds", []):
        if inbound.get("tag") == managed_tag():
            for client in inbound["settings"]["clients"]:
                if client.get("email") == f"LOCKED_{nick}":
                    return "⚠️ Usuário já está bloqueado."
                if client.get("email") == nick:
                    client["email"] = f"LOCKED_{nick}"
                    if proto == "trojan":
                        client["password"] = uuid.uuid4().hex
                    else:
                        client["id"] = str(uuid.uuid4())
                    found = True
                    break

    if not found:
        return "❌ Usuário não encontrado no Config."

    if not save_config(data):
        return "❌ Falha ao salvar config.json."

    reload_xray_user("remove", nick, "")
    locked_nick   = f"LOCKED_{nick}"
    fake_cred_str = uuid.uuid4().hex if proto == "trojan" else str(uuid.uuid4())
    reload_xray_user("add", locked_nick, fake_cred_str)
    return f"⛔ Usuário `{nick}` foi SUSPENSO e desconectado."


def core_unblock_user(nick: str) -> str:
    if not _is_valid_nick(nick):
        return "❌ Nome de usuário inválido."

    real_cred = None
    if os.path.exists(USER_DB):
        with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith(f"{nick}|"):
                    parts = line.strip().split("|")
                    if len(parts) >= 2:
                        real_cred = parts[1]
                    break

    if not real_cred:
        return "❌ Erro: Credencial original não encontrada no DB."

    data = load_config()
    if not data:
        return "❌ Erro ao ler config."

    proto, _ = _get_inbound_profile(data)
    found = False
    for inbound in data.get("inbounds", []):
        if inbound.get("tag") == managed_tag():
            for client in inbound["settings"]["clients"]:
                if client.get("email") == f"LOCKED_{nick}":
                    client["email"] = nick
                    if proto == "trojan":
                        client["password"] = real_cred
                    else:
                        client["id"] = real_cred
                    found = True
                    break

    if not found:
        return "❌ Usuário não estava bloqueado no sistema."

    if not save_config(data):
        return "❌ Falha ao salvar config.json."

    reload_xray_user("remove", f"LOCKED_{nick}", "")
    reload_xray_user("add", nick, real_cred)
    return f"✅ Usuário `{nick}` REATIVADO com sucesso."


def core_renew_user(nick: str, days_to_add: str) -> str:
    if not _is_valid_nick(nick):
        return "❌ Nome de usuário inválido."

    real_cred      = None
    current_expiry = None
    new_expiry     = ""
    found          = False
    lines          = []

    if os.path.exists(USER_DB):
        with open(USER_DB, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()

    for i, line in enumerate(lines):
        if line.startswith(f"{nick}|"):
            parts = line.strip().split("|")
            if len(parts) >= 3:
                real_cred      = parts[1]
                current_expiry = parts[2]
                try:
                    exp_date = datetime.strptime(current_expiry, "%Y-%m-%d")
                    if exp_date < datetime.now():
                        exp_date = datetime.now()
                    new_expiry = (exp_date + timedelta(days=int(days_to_add))).strftime("%Y-%m-%d")
                except ValueError:
                    new_expiry = (datetime.now() + timedelta(days=int(days_to_add))).strftime("%Y-%m-%d")

                parts[2] = new_expiry
                lines[i] = "|".join(parts) + "\n"
                found    = True
            break

    if not found:
        return "❌ Usuário não encontrado no banco de dados."

    _write_user_db_atomic(lines)

    data = load_config()
    was_locked = False
    if data and real_cred:
        proto, _ = _get_inbound_profile(data)
        for inbound in data.get("inbounds", []):
            if inbound.get("tag") == managed_tag():
                for client in inbound["settings"]["clients"]:
                    if client.get("email") == f"LOCKED_{nick}":
                        client["email"] = nick
                        if proto == "trojan":
                            client["password"] = real_cred
                        else:
                            client["id"] = real_cred
                        was_locked = True
                        break
    if was_locked and data and real_cred:
        if save_config(data):
            reload_xray_user("remove", f"LOCKED_{nick}", "")
            reload_xray_user("add", nick, real_cred)
        else:
            raise RuntimeError("Falha ao reativar o acesso Xray.")

    return f"🔄 Usuário `{nick}` RENOVADO com sucesso!\nNova data: {new_expiry}"


# =============================================================
