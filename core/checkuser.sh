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
# Módulo: CheckUser Multi-App API (Puerto 5432)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
CHK_DIR="/etc/vps-manager/checkuser"
CHK_SVC="checkuser-multi"
CHK_PORT_FILE="/etc/vps-manager/checkuser_multi_port"
# Conserva el puerto configurado si ya existía una instalación previa
CHK_PORT=$(cat "$CHK_PORT_FILE" 2>/dev/null)
[[ "$CHK_PORT" =~ ^[0-9]+$ ]] || CHK_PORT=5432

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}      ${T[INSTALANDO CHECKUSER MULTI-APP (API]:-INSTALANDO CHECKUSER MULTI-APP (API})      ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

apt update -y >/dev/null 2>&1
apt install python3 jq iptables ufw -y >/dev/null 2>&1
mkdir -p $CHK_DIR

# Migración: versiones anteriores de Multi-App usaban "checkuser.service" (choca con CheckUser Avanzado)
if [ -f /etc/systemd/system/checkuser.service ] && grep -q "Multi-App" /etc/systemd/system/checkuser.service 2>/dev/null; then
    echo -e "${C_YELLOW}[+] ${T[Migrando servicio antiguo checkuser]:-Migrando servicio antiguo checkuser} -> $CHK_SVC...${C_NC}"
    systemctl stop checkuser 2>/dev/null
    systemctl disable checkuser 2>/dev/null
    rm -f /etc/systemd/system/checkuser.service
fi

echo -e "${C_YELLOW}[+] ${T[Creando API de CheckUser en Python]:-Creando API de CheckUser en Python}...${C_NC}"
cat << 'EOF' > $CHK_DIR/check.py
import socket, sys, os, subprocess, json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

class CheckUser(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        
        path = urlparse(self.path).path.strip('/')
        if not path:
            self.wfile.write(b'{"error": "No user provided"}')
            return
            
        user = path.split('/')[0]
        
        # Validar si el usuario SSH existe
        try:
            with open('/etc/passwd', 'r') as f:
                users = f.read()
            if f"{user}:" not in users:
                self.wfile.write(b'{"error": "User not found"}')
                return
        except:
            pass

        # Obtener Límite
        limite = "1"
        if os.path.exists(f"/etc/vps-manager/limite_{user}"):
            with open(f"/etc/vps-manager/limite_{user}", 'r') as f:
                limite = f.read().strip()
                
        # Obtener Expiración
        exp = "Ilimitado"
        try:
            chage = subprocess.check_output(f"chage -l {user}", shell=True).decode()
            for line in chage.split('\n'):
                if "Account expires" in line:
                    val = line.split(':')[1].strip()
                    if val != "never": exp = val
        except:
            pass

        # Conteo de conexiones
        count = 0
        try:
            ps = subprocess.check_output(f"ps -ef | grep sshd | grep {user} | grep -v grep | wc -l", shell=True).decode().strip()
            count = int(ps)
        except:
            pass

        data = {
            "username": user,
            "count_connection": count,
            "limit_connection": int(limite),
            "expiration_date": exp,
            "status": "online" if count > 0 else "offline"
        }
        
        self.wfile.write(json.dumps(data).encode('utf-8'))

def run(port=5432):
    server_address = ('', port)
    print(f"CheckUser activo en puerto {port}")
    httpd = HTTPServer(server_address, CheckUser)
    httpd.serve_forever()

if __name__ == '__main__':
    run()
EOF
# Aplicar el puerto elegido (por defecto 5432)
sed -i -E "s/def run\(port=[0-9]+\)/def run(port=${CHK_PORT})/" $CHK_DIR/check.py
echo "$CHK_PORT" > "$CHK_PORT_FILE"

# Reglas de Firewall para el puerto 5432
iptables -D INPUT -p tcp --dport $CHK_PORT -j ACCEPT 2>/dev/null
iptables -I INPUT -p tcp --dport $CHK_PORT -j ACCEPT
iptables-save > /etc/iptables.up.rules 2>/dev/null
ufw allow $CHK_PORT/tcp >/dev/null 2>&1

echo -e "${C_YELLOW}[+] ${T[Activando servicio Systemd]:-Activando servicio Systemd}...${C_NC}"
cat << EOF > /etc/systemd/system/$CHK_SVC.service
[Unit]
Description=CheckUser Multi-App API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$CHK_DIR
ExecStart=/usr/bin/python3 $CHK_DIR/check.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $CHK_SVC >/dev/null 2>&1
systemctl restart $CHK_SVC

IP_VPS=$(curl -s ipv4.icanhazip.com)
clear
echo -e "${C_GREEN}[✔] ${T[¡CheckUser Multi-App Instalado Correctamente]:-¡CheckUser Multi-App Instalado Correctamente}!${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
echo -e " 🌐 URL API   : ${C_YELLOW}http://$IP_VPS:$CHK_PORT/${T[USUARIO]:-USUARIO}${C_NC}"
echo -e " 🎯 ${T[Puerto]:-Puerto}    : ${C_YELLOW}$CHK_PORT${C_NC}"
echo -e " ⚙️ ${T[Soporte]:-Soporte}   : ${C_YELLOW}${T[HTTP Custom, HTTP Injector, Paneles Web]:-HTTP Custom, HTTP Injector, Paneles Web}${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
read -p "${T[Presione Enter para regresar al menú]:-Presione Enter para regresar al menú}..."
