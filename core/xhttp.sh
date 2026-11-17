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
# =========================================================================
# Gestor de Cuentas VLESS-XHTTP (Xray) - integrado al Xray actual
# Inbound propio con TLS en un puerto dedicado: NO toca el inbound 443 ni las cuentas VMess/VLESS existentes.
# Basado en el gestor XHTTP de VPS-MANAGER-V2 (rogellevi); adaptado: vencimiento real, validaciones y rollback.
# =========================================================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_WHITE='\033[1;37m'; C_NC='\033[0m'

VPS_DIR="${VPS_BASE:-/etc/vps-manager}"
XRAY_DIR="${XRAY_DIR:-/usr/local/etc/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-${XRAY_DIR}/config.json}"
DEFAULT_PORT=8443
CORE_COPY="${VPS_DIR}/core/xhttp.sh"
CRON_FILE="${CRON_FILE:-/etc/cron.d/vps-manager-xhttp}"
LOCK_FILE="${LOCK_FILE:-/var/lock/vps-xhttp.lock}"
LINE="${C_CYAN}================================================${C_NC}"
export VPS_BASE="$VPS_DIR" XRAY_DIR XRAY_CONFIG

# Con el motor unificado HAProxy activo, el inbound XHTTP (127.0.0.1:10006, ruta /xhttp) lo crea el motor.
modo_motor() { [ -f "${VPS_DIR}/engine_haproxy" ]; }

# ---------------------------------------------------------------------------
# Motor de datos (Python): config de Xray + registro de cuentas. Sin texto para el usuario.
# Códigos de salida: 0 ok | 2 no existe | 3 ya existe | 11 JSON inválido | 12 Xray rechazó la config
#                    13 Xray no arrancó (config restaurada) | 20 puerto en uso por otro inbound | 21 faltan certificados
# ---------------------------------------------------------------------------
xh() {
python3 - "$@" <<'PYEOF'
import json, os, sys, shutil, subprocess, datetime, tempfile

VPS = os.environ.get("VPS_BASE", "/etc/vps-manager")
XDIR = os.environ.get("XRAY_DIR", "/usr/local/etc/xray")
XCONF = os.environ.get("XRAY_CONFIG", XDIR + "/config.json")
REG = os.path.join(VPS, "xhttp_users.json")
CERT, KEY = XDIR + "/server.crt", XDIR + "/server.key"
TAG, XPATH = "vless-xhttp", "/xhttp"
ERRFILE = os.path.join(VPS, "xhttp_error.txt")


def today():
    return datetime.date.today().isoformat()


def load(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        if default is not None:
            return default
        raise
    except Exception:
        sys.exit(11)


def save_atomic(path, data, mode=0o600):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", prefix=".xh-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def reg():
    r = load(REG, {"users": []})
    if not isinstance(r.get("users"), list):
        sys.exit(11)
    return r


def active_clients(r):
    return [{"id": u["uuid"], "email": u["name"]} for u in r["users"] if u.get("exp", "") >= today()]


def find_inbound(cfg):
    for ib in cfg.get("inbounds", []):
        if isinstance(ib, dict) and ib.get("tag") == TAG:
            return ib
    return None


def xray_bin():
    return shutil.which("xray") or ("/usr/local/bin/xray" if os.access("/usr/local/bin/xray", os.X_OK) else None)


def save_error(proc):
    try:
        with open(ERRFILE, "w", encoding="utf-8") as f:
            f.write((proc.stdout + proc.stderr).decode("utf-8", "replace")[-2000:])
    except Exception:
        pass


def cmd_check():
    """0 = este Xray acepta XHTTP; 14 = no lo soporta (imprime la versión)."""
    xb = xray_bin()
    if not xb:
        return 12
    probe = {"inbounds": [{"port": 65001, "listen": "127.0.0.1", "protocol": "vless",
                           "settings": {"clients": [], "decryption": "none"},
                           "streamSettings": {"network": "xhttp", "security": "none",
                                              "xhttpSettings": {"path": "/x", "mode": "auto"}}}],
             "outbounds": [{"protocol": "freedom"}]}
    fd, path = tempfile.mkstemp(suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(probe, f)
    r = subprocess.run([xb, "run", "-test", "-format", "json", "-config", path], capture_output=True)
    os.remove(path)
    v = subprocess.run([xb, "version"], capture_output=True, text=True).stdout.splitlines()
    print(v[0].split("(")[0].strip() if v else "")
    if r.returncode != 0:
        save_error(r)
        return 14
    return 0


def apply_config(cfg):
    """Valida con xray -test, aplica, reinicia y restaura si no arranca."""
    xb = xray_bin()
    if not xb:
        return 12
    # Xray exige que el archivo termine en .json (con "config.json.new" responde: unsupported config file extension)
    tmp = os.path.join(os.path.dirname(XCONF), ".xhttp-new-%d.json" % os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    t = subprocess.run([xb, "run", "-test", "-format", "json", "-config", tmp], capture_output=True)
    if t.returncode != 0:
        save_error(t)
        os.remove(tmp)
        return 12
    bak = XCONF + ".bak-xhttp"
    shutil.copy2(XCONF, bak)
    os.chmod(tmp, 0o644)
    os.replace(tmp, XCONF)
    subprocess.run(["systemctl", "restart", "xray"], capture_output=True)
    ok = subprocess.run(["systemctl", "is-active", "--quiet", "xray"]).returncode == 0
    if not ok:
        shutil.copy2(bak, XCONF)
        subprocess.run(["systemctl", "restart", "xray"], capture_output=True)
        return 13
    return 0


def cmd_inbound_info():
    ib = find_inbound(load(XCONF))
    if not ib:
        sys.exit(1)
    print(ib.get("port", ""))


def cmd_sync():
    cfg, r = load(XCONF), reg()
    ib = find_inbound(cfg)
    if not ib:
        return 0
    want = sorted(active_clients(r), key=lambda c: c["id"])
    have = sorted([{"id": c.get("id"), "email": c.get("email")} for c in ib.get("settings", {}).get("clients", [])], key=lambda c: c["id"] or "")
    if want == have:
        return 0
    ib.setdefault("settings", {})["clients"] = want
    return apply_config(cfg)


def cmd_install(port):
    port = int(port)
    cfg, r = load(XCONF), reg()
    if not (os.path.isfile(CERT) and os.path.isfile(KEY)):
        return 21
    for ib in cfg.get("inbounds", []):
        if isinstance(ib, dict) and ib.get("tag") != TAG and ib.get("port") == port:
            return 20
    new_ib = {
        "tag": TAG, "listen": "0.0.0.0", "port": port, "protocol": "vless",
        "settings": {"clients": active_clients(r), "decryption": "none"},
        "streamSettings": {
            "network": "xhttp", "security": "tls",
            "tlsSettings": {"alpn": ["h2", "http/1.1"], "certificates": [{"certificateFile": CERT, "keyFile": KEY}]},
            "xhttpSettings": {"path": XPATH, "mode": "auto"},
        },
    }
    cfg["inbounds"] = [ib for ib in cfg.get("inbounds", []) if not (isinstance(ib, dict) and ib.get("tag") == TAG)] + [new_ib]
    return apply_config(cfg)


def cmd_uninstall():
    cfg = load(XCONF)
    if not find_inbound(cfg):
        return 0
    cfg["inbounds"] = [ib for ib in cfg.get("inbounds", []) if not (isinstance(ib, dict) and ib.get("tag") == TAG)]
    return apply_config(cfg)


def cmd_add(name, uuid, exp):
    r = reg()
    if any(u["name"].lower() == name.lower() for u in r["users"]):
        return 3
    r["users"].append({"name": name, "uuid": uuid, "exp": exp})
    save_atomic(REG, r)
    return 0


def cmd_del(name):
    r = reg()
    n = len(r["users"])
    r["users"] = [u for u in r["users"] if u["name"] != name]
    if len(r["users"]) == n:
        return 2
    save_atomic(REG, r)
    return 0


def cmd_renew(name, days):
    r = reg()
    for u in r["users"]:
        if u["name"] == name:
            base = max(datetime.date.today(), datetime.date.fromisoformat(u["exp"]))
            u["exp"] = (base + datetime.timedelta(days=int(days))).isoformat()
            save_atomic(REG, r)
            print(u["exp"])
            return 0
    return 2


def cmd_list():
    t = datetime.date.today()
    for u in reg()["users"]:
        d = (datetime.date.fromisoformat(u["exp"]) - t).days
        print("\t".join([u["name"], u["uuid"], u["exp"], "A" if d >= 0 else "V", str(d)]))


def cmd_get(name):
    for u in reg()["users"]:
        if u["name"] == name:
            print("\t".join([u["name"], u["uuid"], u["exp"]]))
            return 0
    return 2


def main():
    a = sys.argv[1:]
    c = a[0] if a else ""
    if c == "inbound-info": cmd_inbound_info(); return 0
    if c == "check": return cmd_check()
    if c in ("sync", "purge"): return cmd_sync()
    if c == "install": return cmd_install(a[1])
    if c == "uninstall": return cmd_uninstall()
    if c == "add": return cmd_add(a[1], a[2], a[3])
    if c == "del": return cmd_del(a[1])
    if c == "renew": return cmd_renew(a[1], a[2])
    if c == "list": cmd_list(); return 0
    if c == "get": return cmd_get(a[1])
    return 64


sys.exit(main())
PYEOF
}

pausa() { read -r -p "${T[Presiona Enter para continuar]:-Presiona Enter para continuar}..." _; }

cabecera() {
    clear
    echo -e "$LINE"
    echo -e " 🚀 $1"
    echo -e "$LINE"
}

con_lock() { ( flock -w 60 9 || exit 99; "$@" ) 9>"$LOCK_FILE"; }

verificar_requisitos() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${C_RED}[!] ${T[Este script debe ejecutarse como root]:-Este script debe ejecutarse como root}.${C_NC}"; return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${C_YELLOW}[+] ${T[Instalando dependencias (python]:-Instalando dependencias (python}3)...${C_NC}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3 >/dev/null 2>&1
        command -v python3 >/dev/null 2>&1 || { echo -e "${C_RED}[!] ${T[No se pudo instalar python]:-No se pudo instalar python}3.${C_NC}"; return 1; }
    fi
    if { ! command -v xray >/dev/null 2>&1 && [ ! -x /usr/local/bin/xray ]; } || [ ! -s "$XRAY_CONFIG" ]; then
        echo -e "${C_RED}[!] ${T[Xray no está instalado. Instala primero el Menú Xray (VLESS o VMess]:-Xray no está instalado. Instala primero el Menú Xray (VLESS o VMess}).${C_NC}"; return 1
    fi
    if [ ! -s "${XRAY_DIR}/server.crt" ] || [ ! -s "${XRAY_DIR}/server.key" ]; then
        echo -e "${C_RED}[!] ${T[No hay certificado TLS de Xray. Instala primero el Menú Xray (VLESS o VMess]:-No hay certificado TLS de Xray. Instala primero el Menú Xray (VLESS o VMess}).${C_NC}"; return 1
    fi
    mkdir -p "$VPS_DIR"
    [ -s "${VPS_DIR}/xhttp_users.json" ] || echo '{"users":[]}' > "${VPS_DIR}/xhttp_users.json"
    chmod 600 "${VPS_DIR}/xhttp_users.json"
    xh list >/dev/null 2>&1; local rc=$?
    if [ "$rc" -eq 11 ]; then
        echo -e "${C_RED}[!] ${T[El config.json de Xray o el registro de cuentas XHTTP está dañado]:-El config.json de Xray o el registro de cuentas XHTTP está dañado}.${C_NC}"; return 1
    fi
    return 0
}

get_domain() {
    local d f
    for f in "${VPS_DIR}/dominio" "${VPS_DIR}/domain.txt"; do
        [ -r "$f" ] || continue
        d=$(tr -d ' \r\n' < "$f")
        case "$d" in ""|Noconfigurado) d="" ;; esac
        [ -n "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

puerto_en_uso() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

abrir_puerto() {
    local p="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${p}/tcp" >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1 && ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
    fi
}

cerrar_puerto() {
    local p="$1"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "${p}/tcp" >/dev/null 2>&1
    fi
    command -v iptables >/dev/null 2>&1 && iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null
    return 0
}

instalar_cron() {
    mkdir -p "${VPS_DIR}/core"
    if [ -f "$0" ] && [ "$(readlink -f "$0")" != "$(readlink -f "$CORE_COPY")" ]; then
        cp -f "$0" "$CORE_COPY" && chmod 755 "$CORE_COPY"
    fi
    [ -x "$CORE_COPY" ] || return 1
    printf '%s\n' "SHELL=/bin/bash" "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        "5 0 * * * root ${CORE_COPY} purge >/dev/null 2>&1" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
}

# Traduce el código de salida del motor a un mensaje. Devuelve el mismo código.
mensaje_rc() {
    case "$1" in
        0) ;;
        2) echo -e "${C_RED}[!] ${T[La cuenta no existe]:-La cuenta no existe}.${C_NC}" ;;
        3) echo -e "${C_RED}[!] ${T[El usuario ya existe]:-El usuario ya existe}.${C_NC}" ;;
        11) echo -e "${C_RED}[!] ${T[El config.json de Xray o el registro de cuentas XHTTP está dañado. No se cambió nada]:-El config.json de Xray o el registro de cuentas XHTTP está dañado. No se cambió nada}.${C_NC}" ;;
        12) echo -e "${C_RED}[!] ${T[Xray rechazó la configuración. No se cambió nada]:-Xray rechazó la configuración. No se cambió nada}.${C_NC}"
            if [ -s "${VPS_DIR}/xhttp_error.txt" ]; then
                echo -e "${C_YELLOW}    ${T[Detalle de Xray]:-Detalle de Xray}:${C_NC}"
                tail -n 4 "${VPS_DIR}/xhttp_error.txt" | sed 's/^/    /'
            fi ;;
        14) echo -e "${C_RED}[!] ${T[Tu versión de Xray no soporta XHTTP]:-Tu versión de Xray no soporta XHTTP}.${C_NC}" ;;
        13) echo -e "${C_RED}[!] ${T[Xray no arrancó con el cambio. Se restauró la configuración anterior]:-Xray no arrancó con el cambio. Se restauró la configuración anterior}.${C_NC}" ;;
        20) echo -e "${C_RED}[!] ${T[Ese puerto ya lo usa otro inbound de Xray]:-Ese puerto ya lo usa otro inbound de Xray}.${C_NC}" ;;
        21) echo -e "${C_RED}[!] ${T[No hay certificado TLS de Xray. Instala primero el Menú Xray (VLESS o VMess]:-No hay certificado TLS de Xray. Instala primero el Menú Xray (VLESS o VMess}).${C_NC}" ;;
        *) echo -e "${C_RED}[!] ${T[Error inesperado en el motor XHTTP (código]:-Error inesperado en el motor XHTTP (código} $1).${C_NC}" ;;
    esac
    return "$1"
}

actualizar_xray() {
    local xb unit antes bak
    xb=$(command -v xray || echo /usr/local/bin/xray)
    unit="${SYSTEMD_DIR:-/etc/systemd/system}/xray.service"
    antes=$(grep -E '^User=' "$unit" 2>/dev/null | head -1)
    bak=$(mktemp) || return 1
    cp -f "$xb" "$bak"
    echo -e "${C_YELLOW}[+] ${T[Actualizando Xray (se guarda una copia del binario actual]:-Actualizando Xray (se guarda una copia del binario actual})...${C_NC}"
    bash -c "$(curl -4 -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    if [ -n "$antes" ] && [ -f "$unit" ]; then sed -i "s|^User=.*|${antes}|" "$unit"; systemctl daemon-reload; fi
    if ! "$xb" run -test -format json -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        cp -f "$bak" "$xb"; chmod 755 "$xb"; rm -f "$bak"; systemctl restart xray
        echo -e "${C_RED}[!] ${T[La versión nueva no acepta tu configuración actual. Se restauró el Xray anterior]:-La versión nueva no acepta tu configuración actual. Se restauró el Xray anterior}.${C_NC}"; return 1
    fi
    systemctl restart xray; sleep 1
    if ! systemctl is-active --quiet xray; then
        cp -f "$bak" "$xb"; chmod 755 "$xb"; rm -f "$bak"; systemctl restart xray
        echo -e "${C_RED}[!] ${T[Xray no arrancó tras actualizar. Se restauró el Xray anterior]:-Xray no arrancó tras actualizar. Se restauró el Xray anterior}.${C_NC}"; return 1
    fi
    rm -f "$bak"
    echo -e "${C_GREEN}[✔] ${T[Xray actualizado]:-Xray actualizado}.${C_NC}"
    return 0
}

asegurar_xray_xhttp() {
    local ver rc resp
    ver=$(xh check 2>/dev/null); rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -ne 14 ]; then mensaje_rc "$rc"; return 1; fi
    echo -e "${C_YELLOW}[!] ${T[Tu Xray]:-Tu Xray} (${ver:-desconocido}) ${T[no soporta XHTTP. Hace falta la versión 24.11.21 o superior]:-no soporta XHTTP. Hace falta la versión 24.11.21 o superior}.${C_NC}"
    read -r -p "${T[¿Actualizar Xray ahora? (s/n]:-¿Actualizar Xray ahora? (s/n}): " resp
    [[ "$resp" =~ ^[sSyY]$ ]] || return 1
    actualizar_xray || return 1
    ver=$(xh check 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then echo -e "${C_RED}[!] ${T[Xray sigue sin soportar XHTTP]:-Xray sigue sin soportar XHTTP}.${C_NC}"; return 1; fi
    return 0
}

instalar_inbound() {
    local act puerto rc
    act=$(xh inbound-info 2>/dev/null)
    if modo_motor; then
        if [ -n "$act" ]; then
            echo -e "${C_YELLOW}[i] ${T[El inbound XHTTP lo gestiona el motor unificado HAProxy (ruta /xhttp en los puertos 443, 80 y]:-El inbound XHTTP lo gestiona el motor unificado HAProxy (ruta /xhttp en los puertos 443, 80 y} 8080).${C_NC}"
        else
            echo -e "${C_RED}[!] ${T[El motor unificado está activo pero no tiene el inbound XHTTP. Reinstálalo desde Menú de Instaladores > Motor unificado]:-El motor unificado está activo pero no tiene el inbound XHTTP. Reinstálalo desde Menú de Instaladores > Motor unificado}.${C_NC}"
        fi
        sleep 4; return 1
    fi
    asegurar_xray_xhttp || { sleep 3; return 1; }
    read -r -p "🔌 ${T[Puerto TLS para XHTTP]:-Puerto TLS para XHTTP} [Enter = ${act:-$DEFAULT_PORT}]: " puerto
    puerto=${puerto:-${act:-$DEFAULT_PORT}}
    if ! [[ "$puerto" =~ ^[0-9]+$ ]] || [ "$puerto" -lt 1 ] || [ "$puerto" -gt 65535 ]; then
        echo -e "${C_RED}[!] ${T[Puerto inválido]:-Puerto inválido}.${C_NC}"; sleep 2; return 1
    fi
    case "$puerto" in
        22|80|443) echo -e "${C_RED}[!] ${T[Ese puerto está reservado. Usa otro (por ejemplo]:-Ese puerto está reservado. Usa otro (por ejemplo} 8443).${C_NC}"; sleep 2; return 1 ;;
    esac
    if [ "$puerto" != "$act" ] && puerto_en_uso "$puerto"; then
        echo -e "${C_RED}[!] ${T[El puerto]:-El puerto} $puerto ${T[ya está en uso por otro servicio]:-ya está en uso por otro servicio}.${C_NC}"; sleep 2; return 1
    fi
    echo -e "${C_YELLOW}[+] ${T[Configurando inbound XHTTP en el puerto]:-Configurando inbound XHTTP en el puerto} $puerto...${C_NC}"
    con_lock xh install "$puerto"; rc=$?
    mensaje_rc "$rc" || { sleep 2; return 1; }
    abrir_puerto "$puerto"
    [ -n "$act" ] && [ "$act" != "$puerto" ] && cerrar_puerto "$act"
    instalar_cron
    echo -e "${C_GREEN}[✔] ${T[XHTTP activo en el puerto]:-XHTTP activo en el puerto} $puerto (TLS).${C_NC}"
    sleep 2
    return 0
}

crear_cuenta() {
    local user dias exp uuid dom puerto rc link
    cabecera "${T[CREAR CUENTA VLESS XHTTP]:-CREAR CUENTA VLESS XHTTP}"
    if ! xh inbound-info >/dev/null 2>&1; then
        echo -e "${C_YELLOW}[!] ${T[XHTTP aún no está instalado. Configurándolo primero]:-XHTTP aún no está instalado. Configurándolo primero}...${C_NC}"
        instalar_inbound || { pausa; return; }
        cabecera "${T[CREAR CUENTA VLESS XHTTP]:-CREAR CUENTA VLESS XHTTP}"
    fi
    dom=$(get_domain) || { echo -e "${C_RED}[!] ${T[No hay dominio configurado. Configúralo en Herramientas y Sistema > Gestor de Dominio y Certificados SSL]:-No hay dominio configurado. Configúralo en Herramientas y Sistema > Gestor de Dominio y Certificados SSL}.${C_NC}"; pausa; return; }
    read -r -p "👤 ${T[Nombre de usuario]:-Nombre de usuario}: " user
    if ! [[ "$user" =~ ^[A-Za-z0-9._-]{1,40}$ ]]; then
        echo -e "${C_RED}[!] ${T[Usuario inválido: usa 1 a 40 caracteres (letras, números, punto, guion]:-Usuario inválido: usa 1 a 40 caracteres (letras, números, punto, guion}).${C_NC}"; sleep 3; return
    fi
    read -r -p "⏳ ${T[Días de duración]:-Días de duración} [Enter = 30]: " dias
    dias=${dias:-30}
    if ! [[ "$dias" =~ ^[0-9]+$ ]] || [ "$dias" -lt 1 ] || [ "$dias" -gt 3650 ]; then
        echo -e "${C_RED}[!] ${T[Los días deben ser un número entre 1 y]:-Los días deben ser un número entre 1 y} 3650.${C_NC}"; sleep 3; return
    fi
    exp=$(date -d "+${dias} days" +%F)
    uuid=$(cat /proc/sys/kernel/random/uuid)
    xh add "$user" "$uuid" "$exp"; rc=$?
    mensaje_rc "$rc" || { sleep 3; return; }
    con_lock xh sync; rc=$?
    if ! mensaje_rc "$rc"; then
        xh del "$user" >/dev/null 2>&1
        sleep 3; return
    fi
    puerto=$(xh inbound-info 2>/dev/null)
    link="vless://${uuid}@${dom}:${puerto}?encryption=none&security=tls&sni=${dom}&alpn=h2&fp=chrome&type=xhttp&host=${dom}&path=%2Fxhttp&mode=auto#${user}_XHTTP"
    link80=""
    if modo_motor; then
        puerto=443
        link="vless://${uuid}@${dom}:443?encryption=none&security=tls&sni=${dom}&alpn=http%2F1.1&fp=chrome&type=xhttp&host=${dom}&path=%2Fxhttp&mode=auto#${user}_XHTTP_TLS"
        link80="vless://${uuid}@${dom}:80?encryption=none&security=none&type=xhttp&host=${dom}&path=%2Fxhttp&mode=auto#${user}_XHTTP_80"
        instalar_cron
    fi
    cabecera "${T[CUENTA VLESS-XHTTP CREADA EXITOSAMENTE]:-CUENTA VLESS-XHTTP CREADA EXITOSAMENTE}"
    echo -e " 👤 ${C_WHITE}${T[Usuario]:-Usuario}    :${C_NC} $user"
    echo -e " 🌐 ${C_WHITE}${T[Dominio]:-Dominio}    :${C_NC} $dom"
    echo -e " 🔑 ${C_WHITE}UUID       :${C_NC} $uuid"
    echo -e " 🔌 ${C_WHITE}${T[Puerto TLS]:-Puerto TLS} :${C_NC} $puerto"
    echo -e " 📡 ${C_WHITE}${T[Red (Type]:-Red (Type}) :${C_NC} xhttp"
    echo -e " ⚙️ ${C_WHITE}${T[Modo]:-Modo}       :${C_NC} auto"
    echo -e " 🛣️ ${C_WHITE}${T[Path]:-Path}       :${C_NC} /xhttp"
    echo -e " 📅 ${C_WHITE}${T[Expira]:-Expira}     :${C_NC} $exp"
    echo -e "$LINE"
    echo -e " 🔗 ${C_YELLOW}${T[LINK XHTTP TLS (Puerto]:-LINK XHTTP TLS (Puerto} $puerto):${C_NC}"
    echo -e "$link"
    if [ -n "$link80" ]; then
        echo -e " 🔗 ${C_YELLOW}${T[LINK XHTTP SIN TLS (Puerto]:-LINK XHTTP SIN TLS (Puerto} 80):${C_NC}"
        echo -e "$link80"
    fi
    echo -e "$LINE"
    pausa
}

elegir_cuenta() {
    # Muestra la lista numerada y deja la cuenta elegida en $CUENTA_ELEGIDA (vacío si se cancela).
    local -a nombres
    local i num
    CUENTA_ELEGIDA=""
    mapfile -t nombres < <(xh list | cut -f1)
    if [ "${#nombres[@]}" -eq 0 ]; then
        echo -e " ${C_YELLOW}${T[No hay cuentas XHTTP registradas]:-No hay cuentas XHTTP registradas}.${C_NC}"; sleep 2; return 1
    fi
    for i in "${!nombres[@]}"; do
        echo -e " $((i+1)). ${nombres[$i]}"
    done
    echo -e " 0. ${T[Cancelar]:-Cancelar}"
    echo -e "$LINE"
    read -r -p "${T[Selecciona el número de la cuenta]:-Selecciona el número de la cuenta}: " num
    [ -z "$num" ] || [ "$num" = "0" ] && return 1
    if ! [[ "$num" =~ ^[0-9]+$ ]] || [ "$num" -lt 1 ] || [ "$num" -gt "${#nombres[@]}" ]; then
        echo -e "${C_RED}[!] ${T[Selección inválida]:-Selección inválida}.${C_NC}"; sleep 2; return 1
    fi
    CUENTA_ELEGIDA="${nombres[$((num-1))]}"
    return 0
}

eliminar_cuenta() {
    local rc
    cabecera "${T[ELIMINAR CUENTA VLESS XHTTP]:-ELIMINAR CUENTA VLESS XHTTP}"
    elegir_cuenta || return
    xh del "$CUENTA_ELEGIDA"; rc=$?
    mensaje_rc "$rc" || { sleep 2; return; }
    con_lock xh sync; rc=$?
    mensaje_rc "$rc" || { sleep 3; return; }
    echo -e "\n${C_GREEN}[✔] ${T[Usuario]:-Usuario} $CUENTA_ELEGIDA ${T[eliminado]:-eliminado}.${C_NC}"
    sleep 2
}

ver_cuentas() {
    local nombre uuid exp est dias
    cabecera "${T[LISTA DE CUENTAS VLESS XHTTP]:-LISTA DE CUENTAS VLESS XHTTP}"
    if [ "$(xh list | wc -l)" -eq 0 ]; then
        echo -e " ${C_YELLOW}${T[No hay cuentas XHTTP registradas]:-No hay cuentas XHTTP registradas}.${C_NC}"
    else
        printf " %-18s %-10s %-8s %s\n" "${TP[Usuario]:-Usuario}" "${TP[Vence]:-Vence}" "${TP[Estado]:-Estado}" "UUID"
        while IFS=$'\t' read -r nombre uuid exp est dias; do
            if [ "$est" = "A" ]; then est="${TP[ACTIVO]:-ACTIVO}"; else est="${TP[VENCIDO]:-VENCIDO}"; fi
            printf " %-18s %-10s %-8s %s\n" "$nombre" "$exp" "$est" "$uuid"
        done < <(xh list)
    fi
    echo -e "$LINE"
    pausa
}

renovar_cuenta() {
    local dias nueva rc
    cabecera "${T[RENOVAR CUENTA VLESS XHTTP]:-RENOVAR CUENTA VLESS XHTTP}"
    elegir_cuenta || return
    read -r -p "⏳ ${T[Días a sumar]:-Días a sumar} [Enter = 30]: " dias
    dias=${dias:-30}
    if ! [[ "$dias" =~ ^[0-9]+$ ]] || [ "$dias" -lt 1 ] || [ "$dias" -gt 3650 ]; then
        echo -e "${C_RED}[!] ${T[Los días deben ser un número entre 1 y]:-Los días deben ser un número entre 1 y} 3650.${C_NC}"; sleep 3; return
    fi
    nueva=$(xh renew "$CUENTA_ELEGIDA" "$dias"); rc=$?
    mensaje_rc "$rc" || { sleep 2; return; }
    con_lock xh sync; rc=$?
    mensaje_rc "$rc" || { sleep 3; return; }
    echo -e "\n${C_GREEN}[✔] ${T[Cuenta renovada hasta]:-Cuenta renovada hasta}${C_NC} $nueva"
    sleep 3
}

desinstalar_inbound() {
    local act rc resp
    if modo_motor; then
        echo -e "${C_YELLOW}[i] ${T[Con el motor unificado activo el inbound XHTTP forma parte del motor. Para quitarlo restaura el backup del motor]:-Con el motor unificado activo el inbound XHTTP forma parte del motor. Para quitarlo restaura el backup del motor}.${C_NC}"
        sleep 4; return
    fi
    cabecera "${T[DESINSTALAR XHTTP]:-DESINSTALAR XHTTP}"
    act=$(xh inbound-info 2>/dev/null)
    if [ -z "$act" ]; then
        echo -e " ${C_YELLOW}${T[XHTTP no está instalado]:-XHTTP no está instalado}.${C_NC}"; sleep 2; return
    fi
    echo -e " ${T[Se quitará el inbound XHTTP del Xray (puerto]:-Se quitará el inbound XHTTP del Xray (puerto} $act). ${T[Las cuentas VMess/VLESS no se tocan]:-Las cuentas VMess/VLESS no se tocan}."
    echo -e " ${T[El registro de cuentas XHTTP se conserva por si lo reinstalas]:-El registro de cuentas XHTTP se conserva por si lo reinstalas}."
    read -r -p "${T[¿Desinstalar XHTTP? (s/n]:-¿Desinstalar XHTTP? (s/n}): " resp
    [[ "$resp" =~ ^[sSyY]$ ]] || return
    con_lock xh uninstall; rc=$?
    mensaje_rc "$rc" || { sleep 3; return; }
    cerrar_puerto "$act"
    rm -f "$CRON_FILE"
    echo -e "\n${C_GREEN}[✔] ${T[XHTTP desinstalado]:-XHTTP desinstalado}.${C_NC}"
    sleep 2
}

menu_principal() {
    local op act est
    while true; do
        act=$(xh inbound-info 2>/dev/null)
        if modo_motor && [ -n "$act" ]; then est="${C_GREEN}Instalado (motor HAProxy: 443 / 80 / 8080)${C_NC}"
        elif [ -n "$act" ]; then est="${C_GREEN}${T[Instalado]:-Instalado} (${T[puerto]:-puerto} $act)${C_NC}"
        else est="${C_YELLOW}${T[No instalado]:-No instalado}${C_NC}"; fi
        cabecera "${T[GESTIÓN DE CUENTAS VLESS XHTTP]:-GESTIÓN DE CUENTAS VLESS XHTTP}"
        echo -e " ${T[Estado]:-Estado}: $est"
        echo -e "$LINE"
        echo -e " 1. ➕ ${T[Crear cuenta XHTTP]:-Crear cuenta XHTTP}"
        echo -e " 2. 🗑️ ${T[Eliminar cuenta XHTTP]:-Eliminar cuenta XHTTP}"
        echo -e " 3. 📋 ${T[Ver cuentas activas]:-Ver cuentas activas}"
        echo -e " 4. 🔄 ${T[Renovar cuenta XHTTP]:-Renovar cuenta XHTTP}"
        echo -e " 5. 🔌 ${T[Instalar / Cambiar puerto XHTTP]:-Instalar / Cambiar puerto XHTTP}"
        echo -e " 6. ❌ ${T[Desinstalar XHTTP]:-Desinstalar XHTTP}"
        echo -e " 0. 🚪 ${T[VOLVER]:-VOLVER}"
        echo -e "$LINE"
        read -r -p "${T[Selecciona una opción]:-Selecciona una opción}: " op
        case $op in
            1) crear_cuenta ;;
            2) eliminar_cuenta ;;
            3) ver_cuentas ;;
            4) renovar_cuenta ;;
            5) instalar_inbound ;;
            6) desinstalar_inbound ;;
            0) break ;;
        esac
    done
}

# Modo cron: retira de Xray las cuentas vencidas (solo reinicia Xray si algo cambia).
if [ "${1:-}" = "purge" ]; then
    verificar_requisitos >/dev/null 2>&1 || exit 1
    con_lock xh purge
    exit $?
fi

verificar_requisitos || { read -r -p "${T[Presiona Enter para volver]:-Presiona Enter para volver}..." _; exit 1; }
menu_principal
