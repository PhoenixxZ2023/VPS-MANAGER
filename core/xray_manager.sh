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
# Motor Unificado: HAProxy (80/8080/443) + Xray (WS / gRPC / XHTTP / SS) + SSH-WS
# Basado en el motor de VPS-MANAGER-V2 (rogellevi). Reescrito para este manager:
#  - backup completo y restauración (rollback) automática ante cualquier fallo
#  - migración de las cuentas VMess/VLESS/Trojan existentes (no se pierde ninguna)
#  - ruteo por contenido (payload) en modo tcp, validado con haproxy -c
#  - diagnóstico real de rutas (contadores de HAProxy) y renovación automática del certificado
# =========================================================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_WHITE='\033[1;37m'; C_NC='\033[0m'

VPS_DIR="${VPS_BASE:-/etc/vps-manager}"
XRAY_DIR="${XRAY_DIR:-/usr/local/etc/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-${XRAY_DIR}/config.json}"
HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"
CERT_DIR="${CERT_DIR:-/etc/haproxy/certs}"
LE_DIR="${LE_DIR:-/etc/letsencrypt}"
HOOK_DIR="${HOOK_DIR:-${LE_DIR}/renewal-hooks/deploy}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
ENGINE_DIR="${VPS_DIR}/engine"
BACKUP_ROOT="${VPS_DIR}/backup"
MARKER="${VPS_DIR}/engine_haproxy"
FLAG_FILE="${VPS_DIR}/xray_dual_ok"
DOMAIN_FILE="${VPS_DIR}/dominio"
CORE_COPY="${VPS_DIR}/core/xray_manager.sh"
SSHWS_PORT=10015
XRAY_NEW="${XRAY_CONFIG%.json}.engine.new.json"   # Xray exige extensión .json en el archivo que se le pasa
LINE="${C_CYAN}================================================${C_NC}"
export VPS_BASE="$VPS_DIR" XRAY_DIR XRAY_CONFIG

# ---------------------------------------------------------------------------
# Ayudante en Python: migración de config de Xray, plantilla de HAProxy y diagnóstico.
# Sin texto para el usuario salvo las líneas del diagnóstico (formato: ESTADO|etiqueta|esperado|obtenido).
# ---------------------------------------------------------------------------
eng() {
python3 - "$@" <<'PYEOF'
import csv, io, json, os, socket, ssl, sys, time

LOCAL = ("127.0.0.1", "::1", "localhost")
SNIFF = {"enabled": True, "destOverride": ["http", "tls", "quic"]}


def spec(with_ss, with_xhttp=True):
    s = [("vless-ws", 10001, "vless", "ws", "/vless"),
         ("vmess-ws", 10002, "vmess", "ws", "/vmess"),
         ("trojan-ws", 10003, "trojan", "ws", "/trojan")]
    if with_ss:
        s.append(("ss-ws", 10005, "shadowsocks", "ws", "/ss"))
    if with_xhttp:
        s.append(("vless-xhttp", 10006, "vless", "xhttp", "/xhttp"))
    s += [("vless-grpc", 10011, "vless", "grpc", "vless-grpc"),
          ("vmess-grpc", 10012, "vmess", "grpc", "vmess-grpc"),
          ("trojan-grpc", 10013, "trojan", "grpc", "trojan-grpc")]
    if with_ss:
        s.append(("ss-grpc", 10014, "shadowsocks", "grpc", "ss-grpc"))
    return s


def make_inbound(tag, port, proto, net, path):
    st = {"clients": []}
    if proto == "vless":
        st["decryption"] = "none"
    if proto == "shadowsocks":
        st["network"] = "tcp,udp"
    ss = {"network": net, "security": "none"}
    if net == "ws":
        ss["wsSettings"] = {"path": path}
    elif net == "xhttp":
        ss["xhttpSettings"] = {"path": path, "mode": "auto"}
    elif net == "grpc":
        ss["grpcSettings"] = {"serviceName": path, "multiMode": True}
    return {"tag": tag, "listen": "127.0.0.1", "port": port, "protocol": proto,
            "settings": st, "streamSettings": ss, "sniffing": dict(SNIFF)}


def net_of(ib):
    return (ib.get("streamSettings") or {}).get("network", "tcp")


def clients_of(ib):
    c = (ib.get("settings") or {}).get("clients")
    return [x for x in c if isinstance(x, dict)] if isinstance(c, list) else []


def ckey(c):
    return c.get("id") or c.get("password") or c.get("email")


def build(old, with_ss, with_xhttp=True):
    olds = [ib for ib in old.get("inbounds", []) if isinstance(ib, dict)]
    used, new_ibs = set(), []
    rep = {"migrated": {}, "dropped": [], "kept": []}
    ports = {p for _, p, _, _, _ in spec(True, True)}

    def source(tag, proto, net):
        for i, ib in enumerate(olds):
            if i not in used and ib.get("tag") == tag:
                return i
        for i, ib in enumerate(olds):
            if i not in used and ib.get("protocol") == proto and net_of(ib) == net and ib.get("listen") in LOCAL:
                return i
        return None

    got = {}
    for tag, port, proto, net, path in spec(with_ss, with_xhttp):
        ib = make_inbound(tag, port, proto, net, path)
        i = source(tag, proto, net)
        cl = []
        if i is not None:
            used.add(i)
            cl = clients_of(olds[i])
        got[tag] = cl
        new_ibs.append(ib)
    # gRPC sin origen propio: mismas cuentas que su WS (igual que hace el controlador V2Ray)
    for tag, src in (("vmess-grpc", "vmess-ws"), ("trojan-grpc", "trojan-ws")):
        if not got.get(tag) and got.get(src):
            got[tag] = list(got[src])
    for ib in new_ibs:
        seen, out = set(), []
        for c in got.get(ib["tag"], []):
            k = ckey(c)
            if k and k not in seen:
                seen.add(k)
                out.append(c)
        ib["settings"]["clients"] = out
        rep["migrated"][ib["tag"]] = len(out)
    kept = []
    for i, ib in enumerate(olds):
        if i in used:
            continue
        desc = "%s/%s:%s" % (ib.get("protocol"), net_of(ib), ib.get("port"))
        if ib.get("listen") in LOCAL and ib.get("port") not in ports and ib.get("port") not in (80, 8080, 443):
            kept.append(ib)
            rep["kept"].append(desc)
        else:
            rep["dropped"].append(desc + " (%d)" % len(clients_of(ib)))
    cfg = dict(old)
    cfg["log"] = old.get("log") or {"access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log", "loglevel": "warning"}
    cfg["dns"] = old.get("dns") or {"servers": ["1.1.1.1", "8.8.8.8", "localhost"]}
    cfg["inbounds"] = new_ibs + kept
    cfg["outbounds"] = old.get("outbounds") or [{"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
                                                {"tag": "blocked", "protocol": "blackhole", "settings": {}}]
    cfg["routing"] = old.get("routing") or {"domainStrategy": "IPIfNonMatch", "rules": [
        {"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"},
        {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}]}
    cfg["api"] = {"tag": "api", "services": ["HandlerService", "StatsService"]}
    cfg["stats"] = {}
    levels = cfg.setdefault("policy", {}).setdefault("levels", {}).setdefault("0", {})
    levels.update(statsUserUplink=True, statsUserDownlink=True)
    cfg["inbounds"] = [i for i in cfg["inbounds"] if i.get("tag") != "api"]
    cfg["inbounds"].append({"tag":"api", "listen":"127.0.0.1", "port":10085,
                            "protocol":"dokodemo-door", "settings":{"address":"127.0.0.1"}})
    rules = cfg["routing"].setdefault("rules", [])
    rules[:] = [r for r in rules if r.get("inboundTag") != ["api"]]
    rules.insert(0, {"type":"field", "inboundTag":["api"], "outboundTag":"api"})
    return cfg, rep


def haproxy_cfg(cert_dir, with_ss, with_xhttp=True):
    def rx(p):
        return r"^[a-z]+[[:space:]]+%s([?/]|[[:space:]])" % p
    acls = [("is_vless", "/vless", "vless_ws"), ("is_vmess", "/vmess", "vmess_ws"), ("is_trojan", "/trojan", "trojan_ws")]
    if with_ss:
        acls.append(("is_ss", "/ss", "ss_ws"))
    if with_xhttp:
        acls.append(("is_xhttp", "/xhttp", "vless_xhttp"))
    L = ["global",
         "    log /dev/log local0",
         "    log /dev/log local1 notice",
         "    stats socket /run/haproxy/admin.sock mode 660 level admin",
         "    stats timeout 30s",
         "    user haproxy",
         "    group haproxy",
         "    daemon",
         "    maxconn 20000",
         "",
         "defaults",
         "    log global",
         "    mode tcp",
         "    option dontlognull",
         "    timeout connect 5s",
         "    timeout client  24h",
         "    timeout server  24h",
         "",
         "frontend multi_front",
         "    bind *:80",
         "    bind *:8080",
         "    bind *:443 ssl crt %s alpn h2,http/1.1" % cert_dir.rstrip("/"),
         "    mode tcp",
         "    tcp-request inspect-delay 3s",
         "    tcp-request content accept if { req.len gt 0 }",
         "    tcp-request content accept if { ssl_fc_alpn -i h2 }",
         "",
         "    acl is_h2 ssl_fc_alpn -i h2",
         "    acl is_ssh req.payload(0,4) -m str SSH-"]
    for name, path, _ in acls:
        L.append("    acl %s req.payload(0,0) -m reg -i %s" % (name, rx(path)))
    L += ["",
          "    use_backend grpc_router if is_h2",
          "    use_backend ssh_direct if is_ssh"]
    for name, _, be in acls:
        L.append("    use_backend %s if %s" % (be, name))
    L += ["    default_backend ssh_ws",
          "",
          "backend grpc_router",
          "    mode tcp",
          "    server loopback_h2 127.0.0.1:10020 send-proxy-v2",
          "",
          "frontend grpc_front",
          "    bind 127.0.0.1:10020 accept-proxy proto h2",
          "    mode http",
          "    acl is_vmess_grpc path_beg /vmess-grpc",
          "    acl is_trojan_grpc path_beg /trojan-grpc"]
    if with_ss:
        L.append("    acl is_ss_grpc path_beg /ss-grpc")
    L += ["    use_backend vmess_grpc_b if is_vmess_grpc",
          "    use_backend trojan_grpc_b if is_trojan_grpc"]
    if with_ss:
        L.append("    use_backend ss_grpc_b if is_ss_grpc")
    if with_xhttp:
        L.append("    use_backend xhttp_h2 if { path_beg /xhttp }")
    L += ["    default_backend vless_grpc_b", ""]
    grpc = [("vless_grpc_b", 10011), ("vmess_grpc_b", 10012), ("trojan_grpc_b", 10013)]
    if with_ss:
        grpc.append(("ss_grpc_b", 10014))
    if with_xhttp:
        grpc.append(("xhttp_h2", 10006))
    for be, port in grpc:
        L += ["backend %s" % be, "    mode http", "    server s1 127.0.0.1:%d proto h2 check" % port, ""]
    tcp = [("ssh_ws", SSHWS), ("ssh_direct", 22), ("vless_ws", 10001), ("vmess_ws", 10002), ("trojan_ws", 10003)]
    if with_ss:
        tcp.append(("ss_ws", 10005))
    if with_xhttp:
        tcp.append(("vless_xhttp", 10006))
    for be, port in tcp:
        L += ["backend %s" % be, "    mode tcp", "    server s1 127.0.0.1:%d check" % port, ""]
    return "\n".join(L)


SSHWS = int(os.environ.get("SSHWS_PORT", "10015"))


def haproxy_stats(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(path)
    s.sendall(b"show stat\n")
    data = b""
    while True:
        ch = s.recv(65536)
        if not ch:
            break
        data += ch
    s.close()
    rows = list(csv.reader(io.StringIO(data.decode("utf-8", "replace").lstrip("# "))))
    ix = {n: i for i, n in enumerate(rows[0])}
    out = {}
    for r in rows[1:]:
        if len(r) > ix["stot"] and r[1] == "BACKEND":
            out[r[0]] = {"stot": int(r[ix["stot"]] or 0), "status": r[ix["status"]]}
    return out


def probe(host, port, tls, alpn, payload, dom):
    s = socket.create_connection((host, port), timeout=3)
    try:
        if tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            ctx.set_alpn_protocols([alpn])
            s = ctx.wrap_socket(s, server_hostname=dom)
        s.sendall(payload)
        s.settimeout(1.5)
        try:
            s.recv(256)
        except Exception:
            pass
    finally:
        try:
            s.close()
        except Exception:
            pass


def cmd_diag(dom, with_ss, with_xhttp=True):
    sock = os.environ.get("HAPROXY_SOCK", "/run/haproxy/admin.sock")
    host = os.environ.get("ENGINE_HOST", "127.0.0.1")
    p_tls, p_80, p_8080 = [int(x) for x in os.environ.get("ENGINE_PORTS", "443:80:8080").split(":")]

    def ws(path):
        return ("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, dom)).encode()

    h2 = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + b"\x00\x00\x00\x04\x00\x00\x00\x00\x00"
    T = [("VLESS WS 443", p_tls, True, "http/1.1", ws("/vless"), "vless_ws"),
         ("VMESS WS 443", p_tls, True, "http/1.1", ws("/vmess"), "vmess_ws"),
         ("TROJAN WS 443", p_tls, True, "http/1.1", ws("/trojan"), "trojan_ws")]
    if with_ss:
        T.append(("SS WS 443", p_tls, True, "http/1.1", ws("/ss"), "ss_ws"))
    if with_xhttp:
        T.append(("XHTTP 443", p_tls, True, "http/1.1", ws("/xhttp"), "vless_xhttp"))
    T += [("GRPC 443 (h2)", p_tls, True, "h2", h2, "grpc_router"),
          ("SSH-WS 443", p_tls, True, "http/1.1", ws("/"), "ssh_ws"),
          ("SSH directo 443", p_tls, True, "http/1.1", b"SSH-2.0-diag\r\n", "ssh_direct"),
          ("VLESS WS 80", p_80, False, "", ws("/vless"), "vless_ws"),
          ("SSH-WS 80", p_80, False, "", ws("/"), "ssh_ws"),
          ("VLESS WS 8080", p_8080, False, "", ws("/vless"), "vless_ws"),
          ("SSH-WS 8080", p_8080, False, "", ws("/"), "ssh_ws")]
    bad = 0
    for label, port, tls, alpn, payload, exp in T:
        try:
            before = haproxy_stats(sock)
            probe(host, port, tls, alpn, payload, dom)
            time.sleep(0.4)
            after = haproxy_stats(sock)
        except Exception as e:
            print("FALLA|%s|%s|%s" % (label, exp, "sin conexion (%s)" % type(e).__name__))
            bad += 1
            continue
        delta = {k: after[k]["stot"] - before.get(k, {"stot": 0})["stot"] for k in after}
        ok = delta.get(exp, 0) >= 1
        got = exp if ok else (",".join(k for k, v in delta.items() if v >= 1) or "ninguno")
        print("%s|%s|%s|%s" % ("OK" if ok else "FALLA", label, exp, got))
        bad += 0 if ok else 1
    try:
        st = haproxy_stats(sock)
        for be in sorted(st):
            if st[be]["status"] not in ("UP", "no check"):
                print("AVISO|backend %s|UP|%s" % (be, st[be]["status"]))
    except Exception:
        pass
    return bad


def probe_xhttp():
    """0 = el Xray instalado acepta XHTTP; 14 = no (imprime la versión)."""
    import shutil, subprocess, tempfile
    xb = shutil.which("xray") or ("/usr/local/bin/xray" if os.access("/usr/local/bin/xray", os.X_OK) else None)
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
    return 0 if r.returncode == 0 else 14


def main():
    a = sys.argv[1:]
    c = a[0] if a else ""
    if c == "probe-xhttp":
        return probe_xhttp()
    if c == "build":
        try:
            with open(a[1], encoding="utf-8") as f:
                old = json.load(f)
        except FileNotFoundError:
            old = {}
        except Exception:
            return 11
        cfg, rep = build(old, a[3] == "1", (a[4] == "1") if len(a) > 4 else True)
        with open(a[2], "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2, ensure_ascii=False)
        print(json.dumps(rep, ensure_ascii=False))
        return 0
    if c == "haproxy-cfg":
        print(haproxy_cfg(a[1], a[2] == "1", (a[3] == "1") if len(a) > 3 else True))
        return 0
    if c == "tags":
        with open(a[1], encoding="utf-8") as f:
            cfg = json.load(f)
        for ib in cfg.get("inbounds", []):
            if isinstance(ib, dict):
                print("%s\t%s\t%s" % (ib.get("tag") or ("%s:%s" % (ib.get("protocol"), ib.get("port"))), ib.get("port"), len(clients_of(ib))))
        return 0
    if c == "diag":
        return min(cmd_diag(a[1], a[2] == "1", (a[3] == "1") if len(a) > 3 else True), 99)
    return 64


sys.exit(main())
PYEOF
}

pausa() { read -r -p "${T[Presiona Enter para continuar]:-Presiona Enter para continuar}..." _; }

cabecera() {
    clear
    echo -e "$LINE"
    echo -e " 🧩 $1"
    echo -e "$LINE"
}

xray_bin() { command -v xray 2>/dev/null || { [ -x /usr/local/bin/xray ] && echo /usr/local/bin/xray; }; }

dominio_actual() {
    local d
    [ -r "$DOMAIN_FILE" ] || return 1
    d=$(tr -d ' \r\n' < "$DOMAIN_FILE")
    case "$d" in ""|Noconfigurado) return 1 ;; esac
    echo "$d"
}

motor_activo() { [ -f "$MARKER" ]; }

# ---------------------------------------------------------------------------
# Puertos 80 / 8080 / 443: qué los usa hoy
# ---------------------------------------------------------------------------
proceso_en_puerto() {   # imprime "nombre pid" del primer proceso que escucha en el puerto $1
    local l
    l=$(ss -ltnpH "sport = :$1" 2>/dev/null | head -1)
    [ -z "$l" ] && return 1
    printf '%s %s\n' "$(echo "$l" | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2)" "$(echo "$l" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)"
}

analizar_puertos() {
    # Llena UNIDADES_PROPIAS (se paran y se vuelven a usar/habilitar al restaurar), UNIDADES_OTRAS (piden confirmación)
    # y AJENOS (bloquean la instalación).
    UNIDADES_PROPIAS=""; UNIDADES_OTRAS=""; AJENOS=""
    local p np proc pid mp
    for p in 80 8080 443; do
        np=$(proceso_en_puerto "$p") || continue
        proc=${np%% *}; pid=${np##* }
        case "$proc" in
            xray|haproxy) ;;
            stunnel|stunnel4) UNIDADES_PROPIAS="$UNIDADES_PROPIAS stunnel4" ;;
            python3|python)
                mp=$(systemctl show -p MainPID --value ws-python 2>/dev/null)
                if [ -n "$mp" ] && [ "$mp" = "$pid" ]; then UNIDADES_PROPIAS="$UNIDADES_PROPIAS ws-python"; else AJENOS="$AJENOS $p:$proc"; fi ;;
            nginx|apache2) UNIDADES_OTRAS="$UNIDADES_OTRAS $proc" ;;
            *) AJENOS="$AJENOS $p:$proc" ;;
        esac
    done
    UNIDADES_PROPIAS=$(echo "$UNIDADES_PROPIAS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    UNIDADES_OTRAS=$(echo "$UNIDADES_OTRAS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    UNIDADES_PROPIAS=$(echo $UNIDADES_PROPIAS)
    UNIDADES_OTRAS=$(echo $UNIDADES_OTRAS)
}

# ---------------------------------------------------------------------------
# Backup y restauración
# ---------------------------------------------------------------------------
crear_backup() {
    local ts dir f
    ts=$(date +%Y%m%d-%H%M%S)
    dir="${BACKUP_ROOT}/engine-${ts}"
    mkdir -p "$dir" || return 1
    chmod 700 "$BACKUP_ROOT" "$dir"
    [ -f "$XRAY_CONFIG" ] && cp -p "$XRAY_CONFIG" "$dir/xray-config.json"
    [ -f "$HAPROXY_CFG" ] && cp -p "$HAPROXY_CFG" "$dir/haproxy.cfg"
    for f in v2ray_users.json xhttp_users.json dominio limites_vmess; do
        [ -f "${VPS_DIR}/$f" ] && cp -p "${VPS_DIR}/$f" "$dir/$f"
    done
    {
        echo "FLAG_EXISTIA=$([ -f "$FLAG_FILE" ] && echo 1 || echo 0)"
        echo "HAPROXY_ACTIVO=$(systemctl is-active --quiet haproxy 2>/dev/null && echo 1 || echo 0)"
        echo "HAPROXY_CFG_EXISTIA=$([ -f "$HAPROXY_CFG" ] && echo 1 || echo 0)"
        echo "XRAY_CFG_EXISTIA=$([ -f "$XRAY_CONFIG" ] && echo 1 || echo 0)"
        echo "UNIDADES_PARADAS=\"\""
        echo "UNIDADES_DESHABILITADAS=\"\""
    } > "$dir/estado.env"
    ss -ltnpH 2>/dev/null > "$dir/escuchas.txt"
    BACKUP_DIR="$dir"
    return 0
}

registrar_unidades() {   # $1 = paradas, $2 = deshabilitadas
    sed -i "s|^UNIDADES_PARADAS=.*|UNIDADES_PARADAS=\"$1\"|; s|^UNIDADES_DESHABILITADAS=.*|UNIDADES_DESHABILITADAS=\"$2\"|" "${BACKUP_DIR}/estado.env"
}

restaurar_backup() {
    local dir="${1:-}" u
    if [ -z "$dir" ]; then
        dir=$(ls -1d "${BACKUP_ROOT}"/engine-* 2>/dev/null | sort | tail -1)
    fi
    if [ -z "$dir" ] || [ ! -f "$dir/estado.env" ]; then
        echo -e "${C_RED}[!] ${T[No hay ningún backup del motor para restaurar]:-No hay ningún backup del motor para restaurar}.${C_NC}"; return 1
    fi
    # shellcheck disable=SC1090,SC1091
    . "$dir/estado.env"
    echo -e "${C_YELLOW}[+] ${T[Restaurando desde]:-Restaurando desde}${C_NC} $dir"
    systemctl stop haproxy vps-ssh-ws 2>/dev/null
    systemctl disable vps-ssh-ws 2>/dev/null
    if [ "${HAPROXY_CFG_EXISTIA:-0}" = "1" ] && [ -f "$dir/haproxy.cfg" ]; then cp -p "$dir/haproxy.cfg" "$HAPROXY_CFG"; else rm -f "$HAPROXY_CFG"; fi
    if [ "${XRAY_CFG_EXISTIA:-0}" = "1" ] && [ -f "$dir/xray-config.json" ]; then
        cp -p "$dir/xray-config.json" "$XRAY_CONFIG"; chmod 644 "$XRAY_CONFIG"
    fi
    rm -f "$MARKER"
    [ "${FLAG_EXISTIA:-0}" = "1" ] || rm -f "$FLAG_FILE"
    for u in $UNIDADES_DESHABILITADAS; do systemctl enable "$u" 2>/dev/null; done
    for u in $UNIDADES_PARADAS; do systemctl start "$u" 2>/dev/null; done
    systemctl restart xray 2>/dev/null
    if [ "${HAPROXY_ACTIVO:-0}" = "1" ]; then systemctl start haproxy 2>/dev/null; else systemctl disable haproxy 2>/dev/null; fi
    echo -e "${C_GREEN}[✔] ${T[Restauración completada. Xray volvió a su configuración anterior]:-Restauración completada. Xray volvió a su configuración anterior}.${C_NC}"
    return 0
}

# ---------------------------------------------------------------------------
# Certificado (HAProxy necesita un único .pem con cadena + llave)
# ---------------------------------------------------------------------------
cert_cubre_dominio() {   # $1 = crt, $2 = dominio
    local rx="${2//./\\.}"
    [ -s "$1" ] || return 1
    openssl x509 -in "$1" -noout -checkend 86400 >/dev/null 2>&1 || return 1
    openssl x509 -in "$1" -noout -text 2>/dev/null | grep -qiE "DNS:${rx}|CN ?= ?${rx}"
}

escribir_pem() {   # $1 crt, $2 key, $3 dominio
    mkdir -p "$CERT_DIR" || return 1
    cat "$1" "$2" > "${CERT_DIR}/$3.pem.new" || return 1
    chmod 600 "${CERT_DIR}/$3.pem.new"
    mv -f "${CERT_DIR}/$3.pem.new" "${CERT_DIR}/$3.pem"
    find "$CERT_DIR" -maxdepth 1 -name '*.pem' ! -name "$3.pem" -delete 2>/dev/null
    return 0
}

certificado_existente() {   # $1 = dominio. Usa Let's Encrypt o el certificado que Xray ya tenía.
    local dom="$1" le="${LE_DIR}/live/$1"
    if [ -s "$le/fullchain.pem" ] && [ -s "$le/privkey.pem" ]; then
        escribir_pem "$le/fullchain.pem" "$le/privkey.pem" "$dom"; return $?
    fi
    if cert_cubre_dominio "${XRAY_DIR}/server.crt" "$dom" && [ -s "${XRAY_DIR}/server.key" ]; then
        escribir_pem "${XRAY_DIR}/server.crt" "${XRAY_DIR}/server.key" "$dom"; return $?
    fi
    return 1
}

emitir_certificado() {   # $1 = dominio (puerto 80 libre)
    local dom="$1" tmp
    if command -v certbot >/dev/null 2>&1; then
        certbot certonly --standalone --preferred-challenges http --non-interactive --agree-tos \
            --keep-until-expiring --cert-name "$dom" -m "admin@${dom}" -d "$dom" >/dev/null 2>&1
        certificado_existente "$dom" && return 0
    fi
    echo -e "${C_YELLOW}[!] ${T[No se pudo emitir el certificado Let Encrypt. Se genera uno autofirmado (los clientes con verificación TLS estricta fallarán]:-No se pudo emitir el certificado Let Encrypt. Se genera uno autofirmado (los clientes con verificación TLS estricta fallarán}).${C_NC}"
    tmp=$(mktemp -d) || return 1
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "$tmp/k.pem" -out "$tmp/c.pem" -subj "/CN=${dom}" >/dev/null 2>&1 \
        && escribir_pem "$tmp/c.pem" "$tmp/k.pem" "$dom"
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

sincronizar_cert() {   # modo silencioso para hooks de certbot y domain.sh
    local dom le
    dom=$(dominio_actual) || return 1
    le="${LE_DIR}/live/${dom}"
    if [ -s "$le/fullchain.pem" ] && [ -s "$le/privkey.pem" ]; then
        escribir_pem "$le/fullchain.pem" "$le/privkey.pem" "$dom" || return 1
    elif cert_cubre_dominio "${XRAY_DIR}/server.crt" "$dom" && [ -s "${XRAY_DIR}/server.key" ]; then
        escribir_pem "${XRAY_DIR}/server.crt" "${XRAY_DIR}/server.key" "$dom" || return 1
    else
        return 1
    fi
    if command -v haproxy >/dev/null 2>&1 && ! haproxy -c -f "$HAPROXY_CFG" >/dev/null 2>&1; then return 2; fi
    systemctl reload haproxy 2>/dev/null || systemctl restart haproxy 2>/dev/null
    return 0
}

instalar_hook_y_copia() {
    local hooks_base="${HOOK_DIR%/deploy}"
    mkdir -p "${VPS_DIR}/core" "$HOOK_DIR" "${hooks_base}/pre" "${hooks_base}/post"
    local self="${BASH_SOURCE[0]:-$0}"
    if [ -f "$self" ] && [ "$(readlink -f "$self")" != "$(readlink -f "$CORE_COPY")" ]; then
        cp -f "$self" "$CORE_COPY" && chmod 755 "$CORE_COPY"
    fi
    printf '%s\n' '#!/bin/bash' "bash ${CORE_COPY} cert-sync >/dev/null 2>&1" > "${HOOK_DIR}/vps-manager-haproxy.sh"
    # La renovación usa certbot --standalone, que necesita el puerto 80: HAProxy lo libera solo durante la renovación.
    printf '%s\n' '#!/bin/bash' 'systemctl stop haproxy' > "${hooks_base}/pre/vps-manager-haproxy.sh"
    printf '%s\n' '#!/bin/bash' 'systemctl start haproxy' > "${hooks_base}/post/vps-manager-haproxy.sh"
    chmod 755 "${HOOK_DIR}/vps-manager-haproxy.sh" "${hooks_base}/pre/vps-manager-haproxy.sh" "${hooks_base}/post/vps-manager-haproxy.sh"
}

# ---------------------------------------------------------------------------
# Piezas del motor
# ---------------------------------------------------------------------------
escribir_proxy_sshws() {
    mkdir -p "$ENGINE_DIR"
    cat > "${ENGINE_DIR}/ssh_ws_proxy.py" <<'PYEOF'
#!/usr/bin/env python3
# Proxy SSH-WS interno del motor (solo escucha en 127.0.0.1). HAProxy le entrega el tráfico ya descifrado.
import select
import socket
import sys
import threading

LISTENING_ADDR = sys.argv[2] if len(sys.argv) > 2 else '127.0.0.1'
LISTENING_PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 10015
SSH_TARGET = ('127.0.0.1', 22)
BUFLEN = 4096 * 4
TIMEOUT = 60


class ClientThread(threading.Thread):
    def __init__(self, client_socket):
        threading.Thread.__init__(self)
        self.client = client_socket
        self.target = None

    def run(self):
        try:
            payload = self.client.recv(BUFLEN).decode('utf-8', errors='ignore')
            if not payload:
                return
            self.target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.target.connect(SSH_TARGET)
            low = payload.lower()
            if 'upgrade: websocket' in low or 'connection: upgrade' in low:
                response = ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                            "Connection: Upgrade\r\n\r\n")
            else:
                response = "HTTP/1.1 200 Connection established\r\nConnection: keep-alive\r\n\r\n"
            self.client.sendall(response.encode('utf-8'))
            self.forward()
        except Exception:
            pass
        finally:
            for s in (self.client, self.target):
                if s:
                    try:
                        s.close()
                    except Exception:
                        pass

    def forward(self):
        socks = [self.client, self.target]
        while True:
            r, _, e = select.select(socks, [], socks, TIMEOUT)
            if e or not r:
                break
            for s in r:
                data = s.recv(BUFLEN)
                if not data:
                    return
                (self.target if s is self.client else self.client).sendall(data)


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((LISTENING_ADDR, LISTENING_PORT))
    srv.listen(128)
    while True:
        c, _ = srv.accept()
        t = ClientThread(c)
        t.daemon = True
        t.start()


if __name__ == '__main__':
    main()
PYEOF
    chmod 755 "${ENGINE_DIR}/ssh_ws_proxy.py"
    cat > "${SYSTEMD_DIR}/vps-ssh-ws.service" <<EOF
[Unit]
Description=VPS-Manager SSH-WS interno (127.0.0.1:${SSHWS_PORT})
After=network.target

[Service]
ExecStart=/usr/bin/python3 ${ENGINE_DIR}/ssh_ws_proxy.py ${SSHWS_PORT} 127.0.0.1
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

generar_xray() {   # deja WITH_SS y ${XRAY_NEW} listos (usa WITH_XHTTP)
    local nuevo="${XRAY_NEW}" xb err="${ENGINE_DIR}/xray_error.txt"
    xb=$(xray_bin)
    mkdir -p "$ENGINE_DIR"
    WITH_SS=1
    eng build "$XRAY_CONFIG" "$nuevo" 1 "${WITH_XHTTP:-1}" > "${ENGINE_DIR}/migracion.json" || return 1
    if ! "$xb" run -test -format json -config "$nuevo" >"$err" 2>&1; then
        WITH_SS=0
        eng build "$XRAY_CONFIG" "$nuevo" 0 "${WITH_XHTTP:-1}" > "${ENGINE_DIR}/migracion.json" || return 1
        if ! "$xb" run -test -format json -config "$nuevo" >"$err" 2>&1; then
            echo -e "${C_YELLOW}    ${T[Detalle de Xray]:-Detalle de Xray}:${C_NC}"
            tail -n 4 "$err" | sed 's/^/    /'
            return 1
        fi
        echo -e "${C_YELLOW}[!] ${T[Esta versión de Xray no acepta los inbounds Shadowsocks de la plantilla: se omiten]:-Esta versión de Xray no acepta los inbounds Shadowsocks de la plantilla: se omiten}.${C_NC}"
    fi
    return 0
}

actualizar_xray_motor() {
    local xb unit antes bak
    xb=$(xray_bin)
    unit="${SYSTEMD_DIR}/xray.service"
    antes=$(grep -E '^User=' "$unit" 2>/dev/null | head -1)
    bak=$(mktemp) || return 1
    cp -f "$xb" "$bak"
    echo -e "${C_YELLOW}[+] ${T[Actualizando Xray (se guarda una copia del binario actual]:-Actualizando Xray (se guarda una copia del binario actual})...${C_NC}"
    bash -c "$(curl -4 -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    if [ -n "$antes" ] && [ -f "$unit" ]; then sed -i "s|^User=.*|${antes}|" "$unit"; systemctl daemon-reload; fi
    if [ -s "$XRAY_CONFIG" ] && ! "$xb" run -test -format json -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        cp -f "$bak" "$xb"; chmod 755 "$xb"; rm -f "$bak"
        echo -e "${C_RED}[!] ${T[La versión nueva no acepta tu configuración actual. Se restauró el Xray anterior]:-La versión nueva no acepta tu configuración actual. Se restauró el Xray anterior}.${C_NC}"; return 1
    fi
    rm -f "$bak"
    echo -e "${C_GREEN}[✔] ${T[Xray actualizado]:-Xray actualizado}.${C_NC}"
    return 0
}

verificar_xhttp() {   # fija WITH_XHTTP según lo que soporte el Xray instalado; ofrece actualizarlo
    local ver rc resp
    WITH_XHTTP=1
    ver=$(eng probe-xhttp 2>/dev/null); rc=$?
    [ "$rc" -eq 0 ] && return 0
    echo -e "${C_YELLOW}[!] ${T[Tu Xray]:-Tu Xray} (${ver:-desconocido}) ${T[no soporta XHTTP. Hace falta la versión 24.11.21 o superior]:-no soporta XHTTP. Hace falta la versión 24.11.21 o superior}.${C_NC}"
    read -r -p "${T[¿Actualizar Xray ahora? (s/n]:-¿Actualizar Xray ahora? (s/n}): " resp
    if [[ "$resp" =~ ^[sSyY]$ ]] && actualizar_xray_motor; then
        ver=$(eng probe-xhttp 2>/dev/null); rc=$?
        [ "$rc" -eq 0 ] && return 0
        echo -e "${C_RED}[!] ${T[Xray sigue sin soportar XHTTP]:-Xray sigue sin soportar XHTTP}.${C_NC}"
    fi
    WITH_XHTTP=0
    echo -e "${C_YELLOW}[!] ${T[El motor se instalará SIN XHTTP (WS, gRPC y SSH funcionan igual). Puedes actualizar Xray y reinstalar el motor después]:-El motor se instalará SIN XHTTP (WS, gRPC y SSH funcionan igual). Puedes actualizar Xray y reinstalar el motor después}.${C_NC}"
    return 0
}

generar_haproxy() {
    local nuevo="${HAPROXY_CFG}.engine.new" out
    mkdir -p "$(dirname "$HAPROXY_CFG")" /run/haproxy 2>/dev/null
    eng haproxy-cfg "$CERT_DIR" "$WITH_SS" "${WITH_XHTTP:-1}" > "$nuevo" || return 1
    if [[ -f "$VPS_DIR/hcr-v3/shared-port" ]]; then
        python3 "$VPS_DIR/core/hcr3/haproxy_route.py" "$nuevo" "$(<"$VPS_DIR/hcr-v3/shared-port")" || return 1
    fi
    if [[ -f "$VPS_DIR/dtunnel/shared-port" ]]; then
        python3 "$VPS_DIR/core/hcr3/haproxy_route.py" "$nuevo" "$(<"$VPS_DIR/dtunnel/shared-port")" --protocol dtunnel || return 1
    fi
    if ! out=$(haproxy -c -f "$nuevo" 2>&1); then
        echo -e "${C_RED}$(echo "$out" | tail -5)${C_NC}"
        rm -f "$nuevo"
        return 1
    fi
    return 0
}

abrir_puertos() {
    local p
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in 80 8080 443; do ufw allow "${p}/tcp" >/dev/null 2>&1; done
    fi
    return 0
}

diagnostico() {
    local dom="$1" ws="$2" wx="${3:-1}" linea est lbl esp got bad=0
    echo -e "${C_YELLOW}[+] ${T[Probando cada ruta con tráfico real (contadores de HAProxy]:-Probando cada ruta con tráfico real (contadores de HAProxy})...${C_NC}"
    while IFS='|' read -r est lbl esp got; do
        case "$est" in
            OK) echo -e "  ${C_GREEN}[✔]${C_NC} $lbl -> $got" ;;
            FALLA) echo -e "  ${C_RED}[✘]${C_NC} $lbl: ${T[esperado]:-esperado} $esp, ${T[obtenido]:-obtenido} $got"; bad=$((bad+1)) ;;
            AVISO) echo -e "  ${C_YELLOW}[!]${C_NC} $lbl: $got" ;;
        esac
    done < <(eng diag "$dom" "$ws" "$wx")
    return "$bad"
}

# ---------------------------------------------------------------------------
# Instalación
# ---------------------------------------------------------------------------
fallo_y_restaurar() {
    echo -e "\n${C_RED}[!] $1${C_NC}"
    echo -e "${C_YELLOW}[+] ${T[Restaurando el estado anterior]:-Restaurando el estado anterior}...${C_NC}"
    restaurar_backup "$BACKUP_DIR"
    rm -f "${XRAY_NEW}" "${HAPROXY_CFG}.engine.new"
    pausa
    return 1
}

instalar_motor() {
    local dom resp b ip_vps ip_dom p u parar deshab
    cabecera "${T[INSTALAR MOTOR UNIFICADO HAPROXY + XRAY]:-INSTALAR MOTOR UNIFICADO HAPROXY + XRAY}"
    if [ "$(id -u)" -ne 0 ]; then echo -e "${C_RED}[!] ${T[Este script debe ejecutarse como root]:-Este script debe ejecutarse como root}.${C_NC}"; pausa; return 1; fi
    if ! command -v apt-get >/dev/null 2>&1; then echo -e "${C_RED}[!] ${T[Se necesita un sistema basado en apt (Ubuntu o Debian]:-Se necesita un sistema basado en apt (Ubuntu o Debian}).${C_NC}"; pausa; return 1; fi
    dom=$(dominio_actual) || {
        echo -e "${C_RED}[!] ${T[No hay dominio configurado. Configúralo en Herramientas y Sistema > Gestor de Dominio y Certificados SSL]:-No hay dominio configurado. Configúralo en Herramientas y Sistema > Gestor de Dominio y Certificados SSL}.${C_NC}"
        pausa; return 1; }
    echo -e " ${T[Dominio]:-Dominio}: ${C_WHITE}$dom${C_NC}"
    analizar_puertos
    if [ -n "$AJENOS" ]; then
        echo -e "\n${C_RED}[!] ${T[Estos servicios usan los puertos 80/8080/443 y no son parte del manager]:-Estos servicios usan los puertos 80/8080/443 y no son parte del manager}:${C_NC} $AJENOS"
        echo -e "${C_YELLOW}    ${T[Cambia su puerto o detenlos y vuelve a ejecutar la instalación. No se detuvo nada]:-Cambia su puerto o detenlos y vuelve a ejecutar la instalación. No se detuvo nada}.${C_NC}"
        pausa; return 1
    fi
    echo -e "\n${C_WHITE}${T[Qué hará este instalador]:-Qué hará este instalador}:${C_NC}"
    echo -e " • ${T[HAProxy tomará los puertos 80, 8080 y 443 (TLS con tu certificado]:-HAProxy tomará los puertos 80, 8080 y 443 (TLS con tu certificado})."
    echo -e " • ${T[Xray pasará a escuchar solo en 127.0.0.1 (puertos 10001-10014); las cuentas VMess/VLESS/Trojan actuales se migran]:-Xray pasará a escuchar solo en 127.0.0.1 (puertos 10001-10014); las cuentas VMess/VLESS/Trojan actuales se migran}."
    echo -e " • ${T[SSH-WS, SSH por TLS y gRPC/XHTTP/WS se reparten por contenido en los mismos puertos]:-SSH-WS, SSH por TLS y gRPC/XHTTP/WS se reparten por contenido en los mismos puertos}."
    if [ -n "$UNIDADES_PROPIAS" ]; then echo -e " • ${T[Se detendrán y deshabilitarán]:-Se detendrán y deshabilitarán}: ${C_YELLOW}${UNIDADES_PROPIAS}${C_NC} (${T[su tráfico pasa a HAProxy]:-su tráfico pasa a HAProxy})."; fi
    if [ -n "$UNIDADES_OTRAS" ]; then echo -e " • ${T[Se te pedirá confirmación para detener]:-Se te pedirá confirmación para detener}: ${C_YELLOW}${UNIDADES_OTRAS}${C_NC}."; fi
    echo -e " • ${T[Antes de tocar nada se guarda un backup completo y se puede restaurar desde este menú]:-Antes de tocar nada se guarda un backup completo y se puede restaurar desde este menú}."
    read -r -p "${T[¿Continuar con la instalación? (s/n]:-¿Continuar con la instalación? (s/n}): " resp
    [[ "$resp" =~ ^[sSyY]$ ]] || return 0
    for u in $UNIDADES_OTRAS; do
        read -r -p "${T[¿Detener y deshabilitar]:-¿Detener y deshabilitar} $u ${T[para liberar los puertos? (s/n]:-para liberar los puertos? (s/n}): " resp
        if [[ "$resp" =~ ^[sSyY]$ ]]; then UNIDADES_PROPIAS="$UNIDADES_PROPIAS $u"; else echo -e "${C_YELLOW}[!] ${T[Instalación cancelada]:-Instalación cancelada}.${C_NC}"; pausa; return 1; fi
    done

    echo -e "\n${C_YELLOW}[1/8] ${T[Creando backup]:-Creando backup}...${C_NC}"
    crear_backup || { echo -e "${C_RED}[!] ${T[No se pudo crear el backup. No se cambió nada]:-No se pudo crear el backup. No se cambió nada}.${C_NC}"; pausa; return 1; }
    echo -e "    $BACKUP_DIR"

    echo -e "${C_YELLOW}[2/8] ${T[Instalando dependencias]:-Instalando dependencias}...${C_NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y haproxy certbot jq python3 openssl psmisc curl >/dev/null 2>&1
    command -v haproxy >/dev/null 2>&1 || { fallo_y_restaurar "No se pudo instalar HAProxy."; return 1; }
    if [ -z "$(xray_bin)" ]; then
        echo -e "${C_YELLOW}[+] ${T[Instalando Xray Core]:-Instalando Xray Core}...${C_NC}"
        bash -c "$(curl -4 -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    fi
    [ -n "$(xray_bin)" ] || { fallo_y_restaurar "Xray no está instalado y no se pudo instalar."; return 1; }
    verificar_xhttp
    if getent group nogroup >/dev/null 2>&1; then mkdir -p /var/log/xray && chown -R nobody:nogroup /var/log/xray 2>/dev/null; fi

    ip_vps=$(curl -4 -sS --max-time 5 ipv4.icanhazip.com 2>/dev/null | tr -d ' \r\n')
    ip_dom=$(getent ahostsv4 "$dom" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$ip_vps" ] && [ "$ip_vps" != "$ip_dom" ]; then
        echo -e "${C_YELLOW}[!] ${T[El dominio apunta a]:-El dominio apunta a} ${ip_dom:-nada} ${T[y la IP de este VPS es]:-y la IP de este VPS es} $ip_vps (${T[normal si usas Cloudflare con proxy naranja]:-normal si usas Cloudflare con proxy naranja}).${C_NC}"
        read -r -p "${T[¿Continuar de todos modos? (s/n]:-¿Continuar de todos modos? (s/n}): " resp
        [[ "$resp" =~ ^[sSyY]$ ]] || { fallo_y_restaurar "Instalación cancelada."; return 1; }
    fi

    echo -e "${C_YELLOW}[3/8] ${T[Liberando puertos]:-Liberando puertos}...${C_NC}"
    parar="xray $UNIDADES_PROPIAS"; deshab="$UNIDADES_PROPIAS"
    registrar_unidades "$UNIDADES_PROPIAS" "$deshab"
    for u in $parar haproxy; do systemctl stop "$u" 2>/dev/null; done
    for u in $deshab; do systemctl disable "$u" 2>/dev/null; done
    sleep 1

    echo -e "${C_YELLOW}[4/8] ${T[Preparando el certificado para]:-Preparando el certificado para} $dom...${C_NC}"
    certificado_existente "$dom" || emitir_certificado "$dom" || { fallo_y_restaurar "No se pudo preparar el certificado TLS."; return 1; }

    echo -e "${C_YELLOW}[5/8] ${T[Migrando la configuración de Xray]:-Migrando la configuración de Xray}...${C_NC}"
    generar_xray || { fallo_y_restaurar "No se pudo generar una configuración de Xray válida (xray -test rechazó el resultado)."; return 1; }
    echo -e "    $(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(", ".join("%s=%s" % kv for kv in r["migrated"].items()))' "${ENGINE_DIR}/migracion.json" 2>/dev/null)"
    b=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("; ".join(r["dropped"]))' "${ENGINE_DIR}/migracion.json" 2>/dev/null)
    [ -n "$b" ] && echo -e "${C_YELLOW}    ${T[Inbounds públicos antiguos reemplazados por HAProxy]:-Inbounds públicos antiguos reemplazados por HAProxy}: $b${C_NC}"

    echo -e "${C_YELLOW}[6/8] ${T[Configurando HAProxy y SSH-WS interno]:-Configurando HAProxy y SSH-WS interno}...${C_NC}"
    escribir_proxy_sshws
    generar_haproxy || { fallo_y_restaurar "haproxy -c rechazó la configuración generada."; return 1; }

    echo -e "${C_YELLOW}[7/8] ${T[Activando servicios]:-Activando servicios}...${C_NC}"
    local svc_user
    svc_user=$(systemctl show -p User --value xray)
    chgrp "$(id -gn "${svc_user:-root}")" "$XRAY_NEW" && chmod 0640 "$XRAY_NEW" || { fallo_y_restaurar "Permissões do Xray"; return 1; }
    mv -f "${XRAY_NEW}" "$XRAY_CONFIG"
    mv -f "${HAPROXY_CFG}.engine.new" "$HAPROXY_CFG"
    systemctl daemon-reload
    systemctl enable xray vps-ssh-ws haproxy >/dev/null 2>&1
    systemctl restart xray; sleep 1
    systemctl is-active --quiet xray || { fallo_y_restaurar "Xray no arrancó con la nueva configuración."; return 1; }
    systemctl restart vps-ssh-ws
    systemctl restart haproxy; sleep 1
    systemctl is-active --quiet haproxy || { fallo_y_restaurar "HAProxy no arrancó (revisa: journalctl -u haproxy)."; return 1; }
    abrir_puertos
    instalar_hook_y_copia

    echo -e "${C_YELLOW}[8/8] ${T[Diagnóstico de rutas]:-Diagnóstico de rutas}...${C_NC}"
    if diagnostico "$dom" "$WITH_SS" "${WITH_XHTTP:-1}"; then
        echo "$BACKUP_DIR" > "$MARKER"; touch "$FLAG_FILE"
        echo -e "\n${C_GREEN}[✔] ${T[¡MOTOR UNIFICADO ACTIVO! Todas las rutas responden]:-¡MOTOR UNIFICADO ACTIVO! Todas las rutas responden}.${C_NC}"
        echo -e "    ${T[Las cuentas VMess/VLESS siguen funcionando igual (mismo dominio, puerto 443 y rutas]:-Las cuentas VMess/VLESS siguen funcionando igual (mismo dominio, puerto 443 y rutas})."
    else
        echo -e "\n${C_RED}[!] ${T[Alguna ruta no llegó al backend esperado]:-Alguna ruta no llegó al backend esperado}.${C_NC}"
        read -r -p "${T[¿Restaurar el estado anterior? (s/n]:-¿Restaurar el estado anterior? (s/n}): " resp
        if [[ "$resp" =~ ^[sSyY]$ ]]; then restaurar_backup "$BACKUP_DIR"; else echo "$BACKUP_DIR" > "$MARKER"; touch "$FLAG_FILE"; echo -e "${C_YELLOW}[!] ${T[Se mantuvo el motor. Puedes restaurar desde el menú]:-Se mantuvo el motor. Puedes restaurar desde el menú}.${C_NC}"; fi
    fi
    pausa
}

# ---------------------------------------------------------------------------
# Estado y menú
# ---------------------------------------------------------------------------
mostrar_estado() {
    local dom t svc
    cabecera "${T[ESTADO DEL MOTOR UNIFICADO]:-ESTADO DEL MOTOR UNIFICADO}"
    if motor_activo; then echo -e " ${T[Motor]:-Motor}: ${C_GREEN}${T[Activo]:-Activo}${C_NC}"; else echo -e " ${T[Motor]:-Motor}: ${C_YELLOW}${T[No instalado]:-No instalado}${C_NC}"; fi
    for svc in haproxy xray vps-ssh-ws; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then echo -e " $svc: ${C_GREEN}${T[activo]:-activo}${C_NC}"; else echo -e " $svc: ${C_RED}${T[inactivo]:-inactivo}${C_NC}"; fi
    done
    for p in 80 8080 443; do
        t=$(proceso_en_puerto "$p") && echo -e " ${T[Puerto]:-Puerto} $p: ${t%% *}" || echo -e " ${T[Puerto]:-Puerto} $p: ${T[libre]:-libre}"
    done
    dom=$(dominio_actual) && [ -s "${CERT_DIR}/${dom}.pem" ] && echo -e " ${T[Certificado]:-Certificado}: $(openssl x509 -in "${CERT_DIR}/${dom}.pem" -noout -enddate 2>/dev/null | cut -d= -f2)"
    if [ -s "$XRAY_CONFIG" ]; then
        echo -e "${LINE}"
        printf " %-16s %-8s %s\n" "${TP[Inbound]:-Inbound}" "${TP[Puerto]:-Puerto}" "${TP[Cuentas]:-Cuentas}"
        eng tags "$XRAY_CONFIG" | while IFS=$'\t' read -r tg pt n; do printf " %-16s %-8s %s\n" "$tg" "$pt" "$n"; done
    fi
    echo -e "${LINE}"
    echo -e " ${T[Backups]:-Backups}: $(ls -1d "${BACKUP_ROOT}"/engine-* 2>/dev/null | wc -l)"
    pausa
}

diagnostico_menu() {
    local dom
    cabecera "${T[DIAGNÓSTICO DE RUTAS]:-DIAGNÓSTICO DE RUTAS}"
    motor_activo || { echo -e "${C_YELLOW}[!] ${T[El motor no está instalado]:-El motor no está instalado}.${C_NC}"; pausa; return; }
    dom=$(dominio_actual) || { echo -e "${C_RED}[!] ${T[No hay dominio configurado]:-No hay dominio configurado}.${C_NC}"; pausa; return; }
    local ws=1 wx=1
    grep -q "backend ss_ws" "$HAPROXY_CFG" 2>/dev/null || ws=0
    grep -q "backend vless_xhttp" "$HAPROXY_CFG" 2>/dev/null || wx=0
    if diagnostico "$dom" "$ws" "$wx"; then echo -e "\n${C_GREEN}[✔] ${T[Todas las rutas responden]:-Todas las rutas responden}.${C_NC}"; else echo -e "\n${C_RED}[!] ${T[Hay rutas con problemas]:-Hay rutas con problemas}.${C_NC}"; fi
    pausa
}

restaurar_menu() {
    local resp
    cabecera "${T[RESTAURAR BACKUP / DESACTIVAR MOTOR]:-RESTAURAR BACKUP / DESACTIVAR MOTOR}"
    ls -1d "${BACKUP_ROOT}"/engine-* >/dev/null 2>&1 || { echo -e "${C_YELLOW}[!] ${T[No hay backups del motor]:-No hay backups del motor}.${C_NC}"; pausa; return; }
    echo -e " ${T[Último backup]:-Último backup}: $(ls -1d "${BACKUP_ROOT}"/engine-* | sort | tail -1)"
    echo -e " ${T[Se devolverá Xray a su configuración anterior y se detendrá HAProxy]:-Se devolverá Xray a su configuración anterior y se detendrá HAProxy}."
    read -r -p "${T[¿Restaurar? (s/n]:-¿Restaurar? (s/n}): " resp
    [[ "$resp" =~ ^[sSyY]$ ]] || return
    restaurar_backup && echo -e "${C_YELLOW}[i] ${T[Las cuentas creadas DESPUÉS de instalar el motor no existen en el backup]:-Las cuentas creadas DESPUÉS de instalar el motor no existen en el backup}.${C_NC}"
    pausa
}

cert_menu() {
    cabecera "${T[SINCRONIZAR CERTIFICADO]:-SINCRONIZAR CERTIFICADO}"
    motor_activo || { echo -e "${C_YELLOW}[!] ${T[El motor no está instalado]:-El motor no está instalado}.${C_NC}"; pausa; return; }
    instalar_hook_y_copia
    echo -e "${C_GREEN}[✔] ${T[Hooks de renovación instalados: HAProxy se detiene unos segundos solo durante cada renovación]:-Hooks de renovación instalados: HAProxy se detiene unos segundos solo durante cada renovación}.${C_NC}"
    if sincronizar_cert; then echo -e "${C_GREEN}[✔] ${T[Certificado actualizado en HAProxy]:-Certificado actualizado en HAProxy}.${C_NC}"; else echo -e "${C_RED}[!] ${T[No se pudo sincronizar el certificado]:-No se pudo sincronizar el certificado}.${C_NC}"; fi
    pausa
}

menu_principal() {
    local op
    while true; do
        cabecera "${T[MOTOR UNIFICADO HAPROXY + XRAY + SSH-WS]:-MOTOR UNIFICADO HAPROXY + XRAY + SSH-WS}"
        if motor_activo; then echo -e " ${T[Estado]:-Estado}: ${C_GREEN}${T[Activo]:-Activo}${C_NC}"; else echo -e " ${T[Estado]:-Estado}: ${C_YELLOW}${T[No instalado]:-No instalado}${C_NC}"; fi
        echo -e "$LINE"
        echo -e " 1. 🚀 ${T[Instalar / Reinstalar motor unificado]:-Instalar / Reinstalar motor unificado}"
        echo -e " 2. 📊 ${T[Ver estado]:-Ver estado}"
        echo -e " 3. 🔍 ${T[Diagnóstico de rutas]:-Diagnóstico de rutas}"
        echo -e " 4. 🔐 ${T[Sincronizar certificado]:-Sincronizar certificado}"
        echo -e " 5. ⏪ ${T[Restaurar backup / Desactivar motor]:-Restaurar backup / Desactivar motor}"
        echo -e " 0. 🚪 ${T[VOLVER]:-VOLVER}"
        echo -e "$LINE"
        read -r -p "${T[Selecciona una opción]:-Selecciona una opción}: " op
        case $op in
            1) instalar_motor ;;
            2) mostrar_estado ;;
            3) diagnostico_menu ;;
            4) cert_menu ;;
            5) restaurar_menu ;;
            0) break ;;
        esac
    done
}

main() {
    case "${1:-menu}" in
        cert-sync) sincronizar_cert; exit $? ;;
        install) instalar_motor ;;
        menu) menu_principal ;;
        *) echo "uso: $0 [menu|cert-sync]"; exit 64 ;;
    esac
}

[ "${ENGINE_LIB:-0}" = "1" ] || main "$@"
