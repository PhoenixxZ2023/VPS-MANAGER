#!/bin/bash
# ── i18n (es / en / pt-BR): os textos usam T/TP; com idioma "pt" mostram a tradução, senão o texto original ──
declare -A T=() TP=()
PT_B=$'\033[1m'; PT_N=$'\033[22m'
load_lang() {
    SYS_LANG=$(cat /etc/vps-manager/lang 2>/dev/null || echo "pt")
    [ "$SYS_LANG" = "${_T_LOADED:-}" ] && return 0
    T=(); TP=(); _T_LOADED="$SYS_LANG"
    [ "$SYS_LANG" = "pt" ] && [ -r /etc/vps-manager/i18n/pt-BR.tsv ] || return 0
    local k v
    while IFS=$'\t' read -r k v; do
        [ -n "$k" ] || continue
        T["$k"]="${PT_B}${v}${PT_N}"; TP["$k"]="$v"
    done < /etc/vps-manager/i18n/pt-BR.tsv
}
load_lang
# ==========================================
# Módulo: Bot de Telegram (Vendedores + SSH + VLESS/VMess)
# Versión final con validaciones y rollback
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'

BOT_DIR="/etc/vps-manager/telegram_bot"
LOG_FILE="/var/log/vps-bot.log"
CTL="/etc/vps-manager/v2ray_ctl.py"
mkdir -p "$BOT_DIR"
touch "$BOT_DIR/resellers.txt" "$LOG_FILE"
chmod 600 "$BOT_DIR/resellers.txt" "$LOG_FILE"

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}   ${T[BOT TELEGRAM (VENDEDORES + SSH + V2RAY]:-BOT TELEGRAM (VENDEDORES + SSH + V2RAY})     ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

# ---------- Configuración ----------
if [ -f "$BOT_DIR/config.env" ]; then
    echo -e "${C_YELLOW}[+] ${T[Bot ya configurado]:-Bot ya configurado}.${C_NC}"
    read -p "${T[¿Deseas reconfigurar Token y Admin ID? (s/n]:-¿Deseas reconfigurar Token y Admin ID? (s/n}): " reconf
    if [[ "$reconf" =~ ^[sS]$ ]]; then
        rm -f "$BOT_DIR/config.env"
    else
        echo -e "${C_GREEN}${T[Manteniendo configuración actual]:-Manteniendo configuración actual}.${C_NC}"
    fi
fi

if [ ! -f "$BOT_DIR/config.env" ]; then
    while true; do
        read -p "${T[Ingresa el Token del Bot]:-Ingresa el Token del Bot}: " TELEGRAM_TOKEN
        TELEGRAM_TOKEN=$(echo "$TELEGRAM_TOKEN" | tr -d ' "'"'"'')
        if [[ "$TELEGRAM_TOKEN" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}$ ]]; then
            break
        fi
        echo -e "${C_RED}[!] ${T[Token inválido. Formato: 123456789:AAxxxx]:-Token inválido. Formato: 123456789:AAxxxx}...${C_NC}"
    done
    while true; do
        read -p "${T[Ingresa tu Admin ID de Telegram (solo números]:-Ingresa tu Admin ID de Telegram (solo números}): " ADMIN_ID
        ADMIN_ID=$(echo "$ADMIN_ID" | tr -d ' "')
        if [[ "$ADMIN_ID" =~ ^[0-9]{5,20}$ ]]; then
            break
        fi
        echo -e "${C_RED}[!] ${T[Admin ID inválido]:-Admin ID inválido}.${C_NC}"
    done
    {
        echo "TOKEN=\"$TELEGRAM_TOKEN\""
        echo "ADMIN=\"$ADMIN_ID\""
    } > "$BOT_DIR/config.env"
    chmod 600 "$BOT_DIR/config.env"
fi

# ---------- Dependencias ----------
apt update -y && apt install -y python3 python3-venv python3-pip jq uuid-runtime curl >/dev/null 2>&1

cd "$BOT_DIR" || exit 1
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
# shellcheck disable=SC1091
source venv/bin/activate
pip install --upgrade pip >/dev/null 2>&1
pip install --upgrade pyTelegramBotAPI >/dev/null 2>&1

# ==========================================
# SCRIPT DE PYTHON (EL CEREBRO DEL BOT)
# ==========================================
cat << 'PYEOF' > "$BOT_DIR/bot.py"
import os
import re
import sys
import time
import uuid
import base64
import logging
import subprocess
import threading
import pwd
from typing import Optional

import telebot
from telebot import types

# ---------- Rutas ----------
BOT_DIR = "/etc/vps-manager/telegram_bot"
RESELLERS_FILE = os.path.join(BOT_DIR, "resellers.txt")
CONFIG_FILE = os.path.join(BOT_DIR, "config.env")
DOMAIN_FILE = "/etc/vps-manager/dominio"
SSHD_CONFIG = "/etc/ssh/sshd_config"
LOG_FILE = "/var/log/vps-bot.log"
CTL = "/etc/vps-manager/v2ray_ctl.py"
XRAY_CONF = "/usr/local/etc/xray/config.json"

# ---------- Logging ----------
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("vps-bot")

# ---------- Lock ----------
_lock = threading.RLock()

# ---------- Validaciones ----------
RE_USER = re.compile(r"^[a-z_][a-z0-9_-]{2,31}$")
RE_PASS = re.compile(r"^[A-Za-z0-9._@#$%&*+=!?-]{6,64}$")
RE_TG_ID = re.compile(r"^[0-9]{5,20}$")
RE_V2NAME = re.compile(r"^[A-Za-z0-9 ._-]{1,40}$")

def valid_username(u: str) -> bool:
    return bool(RE_USER.match(u)) and u not in ("root", "admin", "sshd", "nobody")

def valid_password(p: str) -> bool:
    return bool(RE_PASS.match(p))

def valid_days(d: str) -> bool:
    return d.isdigit() and 1 <= int(d) <= 3650

def valid_v2name(n: str) -> bool:
    return bool(RE_V2NAME.match(n))

# ---------- Config ----------
def load_config() -> tuple[str, str]:
    token, admin = "", ""
    if not os.path.exists(CONFIG_FILE):
        log.error("config.env no existe")
        sys.exit(1)
    with open(CONFIG_FILE, "r") as f:
        for line in f:
            line = line.strip()
            if line.startswith("TOKEN="):
                token = line.split("=", 1)[1].strip().strip('"')
            elif line.startswith("ADMIN="):
                admin = line.split("=", 1)[1].strip().strip('"')
    if not token or not admin:
        log.error("TOKEN o ADMIN vacíos")
        sys.exit(1)
    return token, admin

TOKEN, ADMIN_ID = load_config()
# ── i18n pt-BR (somente exibição; catálogo: /etc/vps-manager/i18n/pt-BR.py.tsv) ──
import re as _pt_re, os as _pt_os
_PT_STATE = {'k': None, 'd': {}, 'rx': None}
def _pt_ready():
    try:
        lm = _pt_os.stat('/etc/vps-manager/lang').st_mtime
        tm = _pt_os.stat('/etc/vps-manager/i18n/pt-BR.py.tsv').st_mtime
    except OSError:
        _PT_STATE.update(k=None, d={}, rx=None)
        return False
    if _PT_STATE['k'] != (lm, tm):
        d = {}
        try:
            if open('/etc/vps-manager/lang').read().strip() == 'pt':
                for ln in open('/etc/vps-manager/i18n/pt-BR.py.tsv', encoding='utf-8'):
                    k, _, v = ln.rstrip('\n').partition('\t')
                    if k and v:
                        d[k] = v
        except Exception:
            d = {}
        pats = [(r'(?<!\w)' if k[0].isalnum() else '') + _pt_re.escape(k) + (r'(?!\w)' if k[-1].isalnum() else '')
                for k in sorted(d, key=len, reverse=True)]
        _PT_STATE.update(k=(lm, tm), d=d, rx=(_pt_re.compile('|'.join(pats)) if pats else None))
    return bool(_PT_STATE['rx'])
def pt_text(s, mode='plain'):
    if not isinstance(s, str) or not _pt_ready():
        return s
    d = _PT_STATE['d']
    if mode == 'ansi':
        f = lambda m: '\033[1m' + d[m.group(0)] + '\033[22m'
    elif mode == 'bold':
        f = lambda m: '<b>' + d[m.group(0)] + '</b>'
    else:
        f = lambda m: d[m.group(0)]
    return _PT_STATE['rx'].sub(f, s)
def pt_tg(s):
    """Telegram (HTML): traduz só o texto fora de <code>/<pre>/<a>; negrito sem aninhar <b>."""
    if not isinstance(s, str) or not _pt_ready():
        return s
    out, skip, bold = [], 0, 0
    for p in _pt_re.split(r'(<[^>]+>)', s):
        if p.startswith('<'):
            m = _pt_re.match(r'<(/?)(code|pre|a)\b', p, _pt_re.I)
            if m:
                skip += -1 if m.group(1) else 1
            m = _pt_re.match(r'<(/?)(b|strong)\b', p, _pt_re.I)
            if m:
                bold += -1 if m.group(1) else 1
            out.append(p)
        elif skip > 0 or not p:
            out.append(p)
        else:
            out.append(pt_text(p, 'plain' if bold > 0 else 'bold'))
    return ''.join(out)
def pt_html(s):
    """Painel web: texto, atributos (placeholder/title/alt/aria-label/onclick) e literais de string do JS; negrito via CSS."""
    if not isinstance(s, str) or not _pt_ready():
        return s
    js = lambda t: _pt_re.sub(r"'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\"|`[^`]*`", lambda m: pt_text(m.group(0)), t)
    attrs = lambda t: _pt_re.sub(r'\b(placeholder|title|alt|aria-label|onclick)=("[^"]*"|\'[^\']*\')', lambda m: m.group(1) + '=' + pt_text(m.group(2)), t)
    out = []
    for p in _pt_re.split(r'(<script\b[^>]*>.*?</script>|<style\b[^>]*>.*?</style>|<[^>]+>)', s, flags=_pt_re.S | _pt_re.I):
        if not p:
            continue
        if p[0] == '<':
            m = _pt_re.match(r'(<script\b[^>]*>)(.*?)(</script>)$', p, _pt_re.S | _pt_re.I)
            if m:
                out.append(m.group(1) + js(m.group(2)) + m.group(3))
            elif p[:6].lower() == '<style':
                out.append(p)
            else:
                out.append(attrs(p))
        else:
            out.append(pt_text(p))
    r = ''.join(out)
    return r.replace('</head>', '<style>body,input,button,select,textarea{font-weight:700}</style></head>', 1)
bot = telebot.TeleBot(TOKEN, parse_mode="HTML")
_pt_reply_to = bot.reply_to
def _pt_reply(message, text, *a, **k):
    return _pt_reply_to(message, pt_tg(text), *a, **k)
bot.reply_to = _pt_reply
_PT_BTNS = ["👤 Crear SSH", "❌ Eliminar SSH", "🛡️ Crear VLESS", "🛡️ Crear VMess", "📋 Lista SSH", "👥 Panel Vendedores", "📊 Info Servidor", "💰 Mis Créditos"]
def _btn(s):
    return pt_text(s, 'plain')
def _btn_rev(s):
    for b in _PT_BTNS:
        if pt_text(b, 'plain') == s:
            return b
    return s

# ---------- Resellers ----------
def load_resellers() -> dict:
    data = {}
    with _lock:
        if not os.path.exists(RESELLERS_FILE):
            return data
        with open(RESELLERS_FILE, "r") as f:
            for i, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                if ":" not in line:
                    log.warning("Línea malformada resellers.txt (%d): %r", i, line)
                    continue
                uid, creds = line.split(":", 1)
                if not RE_TG_ID.match(uid.strip()):
                    log.warning("ID inválido resellers.txt (%d): %r", i, uid)
                    continue
                try:
                    data[uid.strip()] = int(creds.strip())
                except ValueError:
                    log.warning("Créditos inválidos resellers.txt (%d): %r", i, creds)
    return data

def save_resellers(resellers: dict) -> None:
    with _lock:
        tmp = RESELLERS_FILE + ".tmp"
        with open(tmp, "w") as f:
            for uid, creds in resellers.items():
                f.write(f"{uid}:{creds}\n")
        os.replace(tmp, RESELLERS_FILE)
        os.chmod(RESELLERS_FILE, 0o600)

def is_admin(user_id) -> bool:
    return str(user_id) == str(ADMIN_ID)

def is_reseller(user_id) -> bool:
    return str(user_id) in load_resellers()

def get_credits(user_id) -> int:
    return load_resellers().get(str(user_id), 0)

def deduct_credit(user_id) -> bool:
    if is_admin(user_id):
        return True
    with _lock:
        res = load_resellers()
        uid = str(user_id)
        if uid in res and res[uid] > 0:
            res[uid] -= 1
            save_resellers(res)
            return True
    return False

def refund_credit(user_id) -> None:
    if is_admin(user_id):
        return
    with _lock:
        res = load_resellers()
        uid = str(user_id)
        if uid in res:
            res[uid] += 1
            save_resellers(res)

# ---------- Helpers sistema ----------
def user_exists(name: str) -> bool:
    try:
        pwd.getpwnam(name)
        return True
    except KeyError:
        return False

def get_ip() -> str:
    try:
        out = subprocess.run(
            ["curl", "-s", "--max-time", "10", "ipv4.icanhazip.com"],
            capture_output=True, text=True, timeout=15,
        )
        return out.stdout.strip() or "N/D"
    except Exception:
        return "N/D"

def get_domain() -> str:
    if os.path.exists(DOMAIN_FILE):
        try:
            with open(DOMAIN_FILE) as f:
                d = f.read().strip()
            if d:
                return d
        except Exception:
            pass
    return get_ip()

def restart_ssh() -> bool:
    for svc in ("ssh", "sshd"):
        r = subprocess.run(["systemctl", "restart", svc],
                           capture_output=True, text=True)
        if r.returncode == 0:
            return True
    log.error("No se pudo reiniciar ssh/sshd")
    return False

def add_match_rule(user: str, banner_path: str) -> bool:
    try:
        if not os.path.exists(banner_path):
            log.error("Banner no existe: %s", banner_path)
            return False
        with open(SSHD_CONFIG, "r") as f:
            content = f.read()
        if re.search(rf"^\s*Match User {re.escape(user)}\b", content, re.M):
            return True
        with open(SSHD_CONFIG + ".bak", "w") as f:
            f.write(content)
        block = f"\nMatch User {user}\n    Banner {banner_path}\n"
        with open(SSHD_CONFIG, "a") as f:
            f.write(block)
        chk = subprocess.run(["sshd", "-t"], capture_output=True, text=True)
        if chk.returncode != 0:
            log.error("sshd -t falló: %s", chk.stderr)
            with open(SSHD_CONFIG, "w") as f:
                f.write(content)
            return False
        return True
    except Exception as e:
        log.exception("add_match_rule: %s", e)
        return False

def remove_match_rule(user: str) -> None:
    try:
        with open(SSHD_CONFIG, "r") as f:
            lines = f.readlines()
        out = []
        skip_next = False
        for line in lines:
            if skip_next:
                skip_next = False
                if line.lstrip().startswith("Banner"):
                    continue
            if re.match(rf"^\s*Match User {re.escape(user)}\s*$", line):
                skip_next = True
                continue
            out.append(line)
        with open(SSHD_CONFIG, "w") as f:
            f.writelines(out)
    except Exception as e:
        log.exception("remove_match_rule: %s", e)

# ---------- V2Ray (delegado a v2ray_ctl.py) ----------
def ctl_path() -> Optional[str]:
    return CTL if os.path.isfile(CTL) else None

def ctl_run(*args, timeout: int = 40) -> tuple:
    exe = ctl_path()
    if not exe:
        return 127, "v2ray_ctl.py no existe (ejecuta vless.sh una vez en el VPS)"
    try:
        r = subprocess.run(
            ["python3", exe, *args],
            capture_output=True, text=True, timeout=timeout,
        )
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "Timeout ejecutando v2ray_ctl.py"
    except Exception as e:
        return 1, f"Error invocando v2ray_ctl.py: {e}"

def v2ray_ready() -> bool:
    return ctl_path() is not None and os.path.exists(XRAY_CONF)

def _short_err(out: str) -> str:
    if not out:
        return "Error desconocido"
    lines = [l for l in out.splitlines() if l.strip()]
    return lines[-1] if lines else out[-200:]

# ================= HANDLERS =================
@bot.message_handler(commands=["start", "help"])
def send_welcome(message):
    uid = str(message.from_user.id)
    if is_admin(uid):
        markup = types.ReplyKeyboardMarkup(row_width=2, resize_keyboard=True)
        markup.add(*map(_btn, ("👤 Crear SSH", "❌ Eliminar SSH",)))
        markup.add(*map(_btn, ("🛡️ Crear VLESS", "🛡️ Crear VMess",)))
        markup.add(*map(_btn, ("📋 Lista SSH", "👥 Panel Vendedores",)))
        markup.add(*map(_btn, ("📊 Info Servidor",)))
        bot.reply_to(message, "👑 <b>Panel ADMIN VPS Activo</b>", reply_markup=markup)
    elif is_reseller(uid):
        markup = types.ReplyKeyboardMarkup(row_width=2, resize_keyboard=True)
        markup.add(*map(_btn, ("👤 Crear SSH", "🛡️ Crear VLESS",)))
        markup.add(*map(_btn, ("💰 Mis Créditos",)))
        bot.reply_to(
            message,
            f"🤝 <b>Panel VENDEDOR Activo</b>\nCréditos: {get_credits(uid)}",
            reply_markup=markup,
        )
    else:
        bot.reply_to(
            message,
            f"⚠️ <b>Acceso Denegado.</b>\nNo estás registrado.\nTu ID: <code>{uid}</code>",
        )

@bot.message_handler(func=lambda m: True, content_types=["text"])
def handle_message(message):
    uid = str(message.from_user.id)
    if not (is_admin(uid) or is_reseller(uid)):
        return
    text = _btn_rev(message.text.strip())

    # ========== ADMIN ==========
    if is_admin(uid):

        if text == "📊 Info Servidor":
            ram = subprocess.getoutput("free -m | awk 'NR==2{printf \"%s / %s MB\", $3,$2}'")
            bot.reply_to(message, f"🌐 <b>IP:</b> {get_ip()}\n⚡ <b>RAM:</b> {ram}")
            return

        if text == "📋 Lista SSH":
            try:
                users = [
                    f"<code>{u.pw_name}</code>"
                    for u in pwd.getpwall()
                    if u.pw_uid >= 1000 and u.pw_shell == "/bin/false"
                ]
                bot.reply_to(message, "👥 <b>Usuarios SSH:</b>\n" + ("\n".join(users) if users else "(ninguno)"))
            except Exception as e:
                bot.reply_to(message, f"❌ Error: {e}")
            return

        if text == "❌ Eliminar SSH":
            bot.reply_to(message, "Formato:\n<code>/deluser usuario</code>")
            return

        if text.startswith("/deluser"):
            parts = text.split()
            if len(parts) != 2 or not valid_username(parts[1]):
                bot.reply_to(message, "❌ Formato: /deluser usuario (válido)")
                return
            user = parts[1]
            if not user_exists(user):
                bot.reply_to(message, f"❌ El usuario <code>{user}</code> no existe.")
                return
            subprocess.run(["userdel", "-f", user], capture_output=True)
            banner = f"/etc/vps-manager/banner_{user}.net"
            if os.path.exists(banner):
                os.remove(banner)
            remove_match_rule(user)
            restart_ssh()
            bot.reply_to(message, f"✅ <b>{user}</b> eliminado.")
            return

        if text == "👥 Panel Vendedores":
            msg = (
                "👥 <b>GESTIÓN DE REVENDEDORES</b>\n\n"
                "Añadir: <code>/addvend ID CREDITOS</code>\n"
                "Eliminar: <code>/delvend ID</code>\n\n<b>Actuales:</b>\n"
            )
            res = load_resellers()
            if not res:
                msg += "(ninguno)"
            else:
                for r_id, cred in res.items():
                    msg += f"ID: <code>{r_id}</code> — Créditos: {cred}\n"
            bot.reply_to(message, msg)
            return

        if text.startswith("/addvend"):
            parts = text.split()
            if len(parts) != 3:
                bot.reply_to(message, "❌ Formato: /addvend ID CREDITOS")
                return
            r_id, creds_s = parts[1], parts[2]
            if not RE_TG_ID.match(r_id):
                bot.reply_to(message, "❌ ID de Telegram inválido.")
                return
            if not creds_s.isdigit() or not (1 <= int(creds_s) <= 10000):
                bot.reply_to(message, "❌ Créditos deben ser 1–10000.")
                return
            with _lock:
                res = load_resellers()
                res[r_id] = int(creds_s)
                save_resellers(res)
            bot.reply_to(message, f"✅ Vendedor <code>{r_id}</code> con {creds_s} créditos.")
            return

        if text.startswith("/delvend"):
            parts = text.split()
            if len(parts) != 2 or not RE_TG_ID.match(parts[1]):
                bot.reply_to(message, "❌ Formato: /delvend ID")
                return
            with _lock:
                res = load_resellers()
                if parts[1] not in res:
                    bot.reply_to(message, "❌ Ese ID no es vendedor.")
                    return
                del res[parts[1]]
                save_resellers(res)
            bot.reply_to(message, "✅ Vendedor eliminado.")
            return

        # ---- Listar VLESS / VMess ----
        if text == "/listvless":
            rc, out = ctl_run("list", "vless")
            bot.reply_to(message, f"<pre>{out or '(sin cuentas)'}</pre>")
            return
        if text == "/listvmess":
            rc, out = ctl_run("list", "vmess")
            bot.reply_to(message, f"<pre>{out or '(sin cuentas)'}</pre>")
            return

        # ---- Eliminar / renovar / bloquear VLESS ----
        if text.startswith("/delvless"):
            parts = text.split()
            if len(parts) != 2 or not valid_v2name(parts[1]):
                bot.reply_to(message, "❌ Formato: /delvless usuario")
                return
            rc, out = ctl_run("del", "vless", parts[1])
            bot.reply_to(message, f"<pre>{out}</pre>" if rc == 0 else f"❌ <code>{_short_err(out)}</code>")
            return

        if text.startswith("/renewvless"):
            parts = text.split()
            if len(parts) != 3 or not valid_v2name(parts[1]) or not parts[2].isdigit():
                bot.reply_to(message, "❌ Formato: /renewvless usuario dias")
                return
            rc, out = ctl_run("renew", "vless", parts[1], parts[2])
            bot.reply_to(message, f"<pre>{out}</pre>" if rc == 0 else f"❌ <code>{_short_err(out)}</code>")
            return

        if text.startswith("/blockvless"):
            parts = text.split()
            if len(parts) != 2 or not valid_v2name(parts[1]):
                bot.reply_to(message, "❌ Formato: /blockvless usuario")
                return
            rc, out = ctl_run("block", "vless", parts[1])
            bot.reply_to(message, f"<pre>{out}</pre>" if rc == 0 else f"❌ <code>{_short_err(out)}</code>")
            return

        # ---- Eliminar VMess ----
        if text.startswith("/delvmess"):
            parts = text.split()
            if len(parts) != 2 or not valid_v2name(parts[1]):
                bot.reply_to(message, "❌ Formato: /delvmess usuario")
                return
            rc, out = ctl_run("del", "vmess", parts[1])
            bot.reply_to(message, f"<pre>{out}</pre>" if rc == 0 else f"❌ <code>{_short_err(out)}</code>")
            return

    # ========== COMÚN (admin + vendedor) ==========

    if text == "💰 Mis Créditos":
        bot.reply_to(message, f"💰 <b>Créditos:</b> {get_credits(uid)}")
        return

    # ---- SSH ----
    if text == "👤 Crear SSH":
        bot.reply_to(message, "Formato:\n<code>/adduser usuario clave dias</code>")
        return

    if text.startswith("/adduser"):
        if not is_admin(uid) and get_credits(uid) <= 0:
            bot.reply_to(message, "❌ <b>Sin créditos.</b> Contacta al administrador.")
            return
        parts = text.split()
        if len(parts) != 4:
            bot.reply_to(message, "❌ Formato: /adduser usuario clave dias")
            return
        user, pwd_, days = parts[1], parts[2], parts[3]
        if not valid_username(user):
            bot.reply_to(message, "❌ Usuario inválido: 3–32 chars, minúsculas, [a-z0-9_-], sin 'root'.")
            return
        if not valid_password(pwd_):
            bot.reply_to(message, "❌ Clave inválida: 6–64 chars, sin espacios ni comillas.")
            return
        if not valid_days(days):
            bot.reply_to(message, "❌ Días inválidos: entero 1–3650.")
            return
        if user_exists(user):
            bot.reply_to(message, f"❌ El usuario <code>{user}</code> ya existe.")
            return
        if not deduct_credit(uid):
            bot.reply_to(message, "❌ No se pudo descontar el crédito.")
            return
        try:
            exp_date = subprocess.run(
                ["date", "-d", f"+{days} days", "+%Y-%m-%d"],
                capture_output=True, text=True, check=True
            ).stdout.strip()

            r1 = subprocess.run(
                ["useradd", "-e", exp_date, "-s", "/bin/false", "-M", user],
                capture_output=True, text=True
            )
            if r1.returncode != 0:
                raise RuntimeError(r1.stderr.strip() or "useradd falló")

            r2 = subprocess.run(
                ["chpasswd"], input=f"{user}:{pwd_}\n",
                capture_output=True, text=True
            )
            if r2.returncode != 0:
                subprocess.run(["userdel", "-f", user], capture_output=True)
                raise RuntimeError(r2.stderr.strip() or "chpasswd falló")

            banner_path = f"/etc/vps-manager/banner_{user}.net"
            with open(banner_path, "w") as bf:
                bf.write(
                    "<br><font color='cyan'>=======================</font><br>"
                    f"<font color='yellow'>👤 Usuario:</font> <font color='white'>{user}</font><br>"
                    f"<font color='yellow'>📅 Expira:</font> <font color='white'>{exp_date} ({days} días)</font><br>"
                    "<font color='cyan'>=======================</font><br>"
                )

            if not add_match_rule(user, banner_path):
                subprocess.run(["userdel", "-f", user], capture_output=True)
                if os.path.exists(banner_path):
                    os.remove(banner_path)
                raise RuntimeError("sshd_config inválido tras añadir regla")
            if not restart_ssh():
                raise RuntimeError("No se pudo reiniciar ssh")

            dom = get_domain()
            respuesta = (
                f"✅ <b>CUENTA SSH CREADA</b>\n\n"
                f"👤 <b>Usuario:</b> {user}\n"
                f"🔑 <b>Clave:</b> {pwd_}\n"
                f"📅 <b>Expira:</b> {exp_date} ({days} días)\n"
                f"🌐 <b>Host:</b> {dom}\n"
            )
            if not is_admin(uid):
                respuesta += f"\n💰 <i>Créditos restantes: {get_credits(uid)}</i>"
            bot.reply_to(message, respuesta)
            log.info("SSH creado: %s por %s (%s días)", user, uid, days)
        except Exception as e:
            refund_credit(uid)
            if user_exists(user):
                subprocess.run(["userdel", "-f", user], capture_output=True)
            bp = f"/etc/vps-manager/banner_{user}.net"
            if os.path.exists(bp):
                os.remove(bp)
            remove_match_rule(user)
            restart_ssh()
            log.exception("Error creando SSH %s: %s", user, e)
            bot.reply_to(message, f"❌ <b>Error al crear la cuenta.</b>\n<code>{e}</code>")
        return

    # ---- VLESS ----
    if text == "🛡️ Crear VLESS":
        if not v2ray_ready():
            bot.reply_to(message, "❌ <b>Motor Xray no instalado.</b>\nEjecuta <code>vless.sh</code> una vez desde el VPS.")
            return
        bot.reply_to(
            message,
            "Formato:\n<code>/addvless usuario dias</code>\n"
            "Ejemplo: <code>/addvless carlos 30</code>\n\n"
            "<i>Nombre: 1–40 chars (letras, números, espacio, . _ -)</i>",
        )
        return

    if text.startswith("/addvless"):
        if not v2ray_ready():
            bot.reply_to(message, "❌ Motor Xray no instalado.")
            return
        if not is_admin(uid) and get_credits(uid) <= 0:
            bot.reply_to(message, "❌ <b>Sin créditos.</b>")
            return
        parts = text.split()
        if len(parts) != 3:
            bot.reply_to(message, "❌ Formato: /addvless usuario dias")
            return
        name, days_s = parts[1], parts[2]
        if not valid_v2name(name):
            bot.reply_to(message, "❌ Nombre inválido: 1–40 chars [A-Za-z0-9 ._-]")
            return
        if not valid_days(days_s):
            bot.reply_to(message, "❌ Días inválidos: entero 1–3650.")
            return
        if not deduct_credit(uid):
            bot.reply_to(message, "❌ No se pudo descontar crédito.")
            return
        rc, out = ctl_run("add", "vless", name, days_s)
        if rc != 0:
            refund_credit(uid)
            bot.reply_to(message, f"❌ <b>Error creando VLESS.</b>\n<code>{_short_err(out)}</code>")
            log.error("addvless falló (%s): %s", name, out)
            return
        bot.reply_to(message, f"<pre>{out}</pre>")
        rc_qr, qr_out = ctl_run("qr", "vless", name, "tls")
        if rc_qr == 0 and qr_out:
            bot.reply_to(message, f"<pre>{qr_out}</pre>")
        if not is_admin(uid):
            bot.reply_to(message, f"💰 <i>Créditos restantes: {get_credits(uid)}</i>")
        log.info("VLESS creado: %s por %s (%s días)", name, uid, days_s)
        return

    # ---- VMess ----
    if text == "🛡️ Crear VMess":
        if not v2ray_ready():
            bot.reply_to(message, "❌ <b>Motor Xray no instalado.</b>\nEjecuta <code>vless.sh</code> una vez desde el VPS.")
            return
        bot.reply_to(
            message,
            "Formato:\n<code>/addvmess usuario dias</code>\n"
            "Ejemplo: <code>/addvmess carlos 30</code>",
        )
        return

    if text.startswith("/addvmess"):
        if not v2ray_ready():
            bot.reply_to(message, "❌ Motor Xray no instalado.")
            return
        if not is_admin(uid) and get_credits(uid) <= 0:
            bot.reply_to(message, "❌ <b>Sin créditos.</b>")
            return
        parts = text.split()
        if len(parts) != 3:
            bot.reply_to(message, "❌ Formato: /addvmess usuario dias")
            return
        name, days_s = parts[1], parts[2]
        if not valid_v2name(name):
            bot.reply_to(message, "❌ Nombre inválido: 1–40 chars [A-Za-z0-9 ._-]")
            return
        if not valid_days(days_s):
            bot.reply_to(message, "❌ Días inválidos: entero 1–3650.")
            return
        if not deduct_credit(uid):
            bot.reply_to(message, "❌ No se pudo descontar crédito.")
            return
        rc, out = ctl_run("add", "vmess", name, days_s)
        if rc != 0:
            refund_credit(uid)
            bot.reply_to(message, f"❌ <b>Error creando VMess.</b>\n<code>{_short_err(out)}</code>")
            log.error("addvmess falló (%s): %s", name, out)
            return
        bot.reply_to(message, f"<pre>{out}</pre>")
        rc_qr, qr_out = ctl_run("qr", "vmess", name, "tls")
        if rc_qr == 0 and qr_out:
            bot.reply_to(message, f"<pre>{qr_out}</pre>")
        if not is_admin(uid):
            bot.reply_to(message, f"💰 <i>Créditos restantes: {get_credits(uid)}</i>")
        log.info("VMess creado: %s por %s (%s días)", name, uid, days_s)
        return

# ---------- Main ----------
if __name__ == "__main__":
    log.info("Bot iniciado")
    while True:
        try:
            bot.infinity_polling(timeout=10, long_polling_timeout=5)
        except Exception as e:
            log.exception("Polling error: %s", e)
            time.sleep(3)
PYEOF

chmod 700 "$BOT_DIR/bot.py"

# ---------- Servicio systemd ----------
cat << EOF > /etc/systemd/system/vps-bot.service
[Unit]
Description=Telegram Bot Golbert VPS
After=network.target

[Service]
User=root
WorkingDirectory=$BOT_DIR
ExecStart=$BOT_DIR/venv/bin/python $BOT_DIR/bot.py
Restart=always
RestartSec=3
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vps-bot >/dev/null 2>&1
systemctl restart vps-bot

echo -e "\n${C_GREEN}[✔] ${T[Bot instalado con SSH + VLESS + VMess y arrancado]:-Bot instalado con SSH + VLESS + VMess y arrancado}.${C_NC}"
echo -e "${C_YELLOW}Log:   ${LOG_FILE}${C_NC}"
echo -e "${C_YELLOW}${T[Estado: systemctl status vps-bot]:-Estado: systemctl status vps-bot}${C_NC}"
read -p "${T[Presione Enter para regresar]:-Presione Enter para regresar}..."