#!/bin/bash
# VPS-MANAGER-MODULE: onlineapp
# Modulo cargado con "source" por menu.sh (usar_modulo). No ejecutar directamente.

_oa_preparar_web() {
local ports=/etc/apache2/ports.conf site=/etc/apache2/sites-available/000-default.conf
grep -q "^Listen 8888" "$ports" 2>/dev/null || sed -i 's/^Listen 80[[:space:]]*$/Listen 8888/' "$ports" 2>/dev/null
grep -q '<VirtualHost \*:8888>' "$site" 2>/dev/null || sed -i 's/<VirtualHost \*:80>/<VirtualHost *:8888>/' "$site" 2>/dev/null
mkdir -p /var/www/html/server
systemctl enable apache2 >/dev/null 2>&1
systemctl restart apache2 2>/dev/null
# Firewall local: abrir TCP 8888
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
ufw allow 8888/tcp >/dev/null 2>&1
fi
if command -v iptables >/dev/null 2>&1 && ! iptables -C INPUT -p tcp --dport 8888 -j ACCEPT >/dev/null 2>&1; then
iptables -I INPUT -p tcp --dport 8888 -j ACCEPT >/dev/null 2>&1
command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1
fi
}

_oa_diagnostico() {
local ok=1 code owner
echo -e "${C_NEON_YELLOW}── Diagnóstico ──${C_RST}"
if systemctl is-active --quiet onlineapp.service 2>/dev/null; then
echo -e "  ${C_GREEN}✅ Servicio onlineapp activo${C_RST}"
else echo -e "  ${C_RED}❌ Servicio onlineapp detenido${C_RST}"; ok=0; fi
if systemctl is-active --quiet apache2 2>/dev/null; then
echo -e "  ${C_GREEN}✅ Apache activo${C_RST}"
else
echo -e "  ${C_RED}❌ Apache detenido${C_RST}"; ok=0
journalctl -u apache2 -n 4 --no-pager 2>/dev/null | tail -4 | sed 's/^/     /'
fi
owner=$(ss -ltnp 2>/dev/null | awk '$4 ~ /:8888$/ {print $NF; exit}')
if [ -z "$owner" ]; then
echo -e "  ${C_RED}❌ Nada escucha en el puerto 8888${C_RST}"; ok=0
elif [[ "$owner" == *apache2* ]]; then
echo -e "  ${C_GREEN}✅ Puerto 8888 escuchando (Apache)${C_RST}"
else
echo -e "  ${C_RED}❌ El puerto 8888 lo usa otro programa: $owner${C_RST}"; ok=0
fi
if [ -s /var/www/html/server/online ]; then
echo -e "  ${C_GREEN}✅ Archivo de usuarios online generado${C_RST}"
else echo -e "  ${C_RED}❌ Falta /var/www/html/server/online${C_RST}"; ok=0; fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8888/server/online 2>/dev/null)
if [ "$code" = "200" ]; then
echo -e "  ${C_GREEN}✅ Respuesta local HTTP 200${C_RST}"
else echo -e "  ${C_RED}❌ Respuesta local HTTP ${code:-000}${C_RST}"; ok=0; fi
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
if ufw status 2>/dev/null | grep -Eq '(^|[[:space:]])8888(/tcp)?[[:space:]].*ALLOW'; then
echo -e "  ${C_GREEN}✅ ufw permite el 8888${C_RST}"
else echo -e "  ${C_RED}❌ ufw está activo y no permite el 8888${C_RST}"; ok=0; fi
fi
if command -v iptables >/dev/null 2>&1; then
if iptables -C INPUT -p tcp --dport 8888 -j ACCEPT >/dev/null 2>&1; then
echo -e "  ${C_GREEN}✅ iptables permite el 8888${C_RST}"
elif [ "$(iptables -S INPUT 2>/dev/null | awk '$1=="-P"{print $3}')" != "ACCEPT" ] || iptables -S INPUT 2>/dev/null | grep -Eq -- '-j (DROP|REJECT)'; then
echo -e "  ${C_RED}❌ iptables puede estar bloqueando el 8888${C_RST}"; ok=0
else echo -e "  ${C_GREEN}✅ iptables sin bloqueos${C_RST}"; fi
fi
if [ "$ok" -eq 1 ]; then
echo -e "${C_GREEN}[✔] El VPS está correcto.${C_RST}"
echo -e "${C_YELLOW}Si desde fuera sigue sin abrir, habilita el puerto TCP 8888 en el firewall de tu proveedor (Security List / Security Group / reglas de entrada).${C_RST}"
else
echo -e "${C_RED}[!] Hay problemas (arriba). Use la opción 3 para reparar.${C_RST}"
fi
}

menu_onlineapp() {
clear
local is_running=0
systemctl is-active --quiet onlineapp.service 2>/dev/null && is_running=1
# Fallback a screen antiguo
[ "$is_running" -eq 0 ] && [ "$(screen -ls 2>/dev/null | grep -c 'onlineapp')" -gt 0 ] && is_running=1

local IP=$(curl -s --max-time 3 ipv4.icanhazip.com 2>/dev/null)
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || IP=$(hostname -I | awk '{print $1}')
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         📱 GESTIÓN DE ONLINE APP             ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
if [ "$is_running" -gt 0 ]; then
echo -e "  Estado: ${C_GREEN}✅ ACTIVO (systemd)${C_RST}"
echo -e "  URL: ${C_NEON_YELLOW}http://$IP:8888/server/online${C_RST}"
local code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8888/server/online 2>/dev/null)
if [ "$code" = "200" ]; then echo -e "  Enlace: ${C_GREEN}✅ responde (HTTP 200)${C_RST}"
else echo -e "  Enlace: ${C_RED}❌ NO responde (HTTP ${code:-000}) - use la opción 3${C_RST}"; fi
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  ${C_NEON_YELLOW}1.${C_RST} ⏹️ Detener y Desinstalar Online App"
echo -e "  ${C_NEON_YELLOW}2.${C_RST} 🔄 Reiniciar Servicio"
echo -e "  ${C_NEON_YELLOW}3.${C_RST} 🔍 Diagnosticar y reparar enlace"
else
echo -e "  Estado: ${C_RED}❌ INACTIVO${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar e Iniciar Online App"
fi
echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Anterior"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
read -p "Seleccione una opción: " opt_app
case $opt_app in
1)
if [ "$is_running" -gt 0 ]; then
echo -e "${C_YELLOW}[+] Deteniendo Online App...${C_RST}"
systemctl stop onlineapp.service 2>/dev/null
systemctl disable onlineapp.service 2>/dev/null
rm -f /etc/systemd/system/onlineapp.service
systemctl daemon-reload 2>/dev/null
screen -S onlineapp -X quit 2>/dev/null
screen -wipe >/dev/null 2>&1
sed -i '/onlineapp/d' /etc/autostart 2>/dev/null
rm -rf /var/www/html/server
echo -e "${C_GREEN}[✔] Online App detenido y archivos eliminados.${C_RST}"
else
echo -e "${C_YELLOW}[+] Instalando e Iniciando Online App (systemd)...${C_RST}"
apt update -y >/dev/null 2>&1
apt install apache2 -y >/dev/null 2>&1
if ! command -v apache2 >/dev/null 2>&1; then
echo -e "${C_RED}[!] No se pudo instalar Apache (apt falló). Revise la conexión/apt e inténtelo de nuevo.${C_RST}"
read -p "Presione Enter para continuar..."
return
fi
_oa_preparar_web
mkdir -p /etc/vps-manager
cat > /etc/vps-manager/onlineapp.sh << 'EOF'
#!/bin/bash
OUT_DIR="/var/www/html/server"
mkdir -p "$OUT_DIR"
fun_online() {
local ssh_count=0 vpn_count=0 drp_count=0
ssh_count=$(pgrep -f "sshd:.*priv" 2>/dev/null | wc -l)
if [[ -r /etc/openvpn/openvpn-status.log ]]; then
vpn_count=$(grep -c "10.8.0" /etc/openvpn/openvpn-status.log 2>/dev/null || echo 0)
fi
if [[ -e /etc/default/dropbear ]]; then
local drp=$(pgrep -f "dropbear" 2>/dev/null | wc -l)
drp_count=$(( drp > 0 ? drp - 1 : 0 ))
fi
local online=$(( ssh_count + vpn_count + drp_count ))
printf '{"onlines":"%s","limite":"2500"}
' "$online" > "$OUT_DIR/online_app"
printf '%s
' "$online" > "$OUT_DIR/online"
}
while true; do
fun_online
sleep 15
done
EOF
chmod +x /etc/vps-manager/onlineapp.sh

# Servicio systemd
cat > /etc/systemd/system/onlineapp.service << EOF
[Unit]
Description=VPS-Manager Online App (usuarios online)
After=network-online.target apache2.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash /etc/vps-manager/onlineapp.sh
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable onlineapp.service >/dev/null 2>&1
systemctl restart onlineapp.service

# Limpiar restos antiguos
sed -i '/onlineapp/d' /etc/autostart 2>/dev/null
screen -S onlineapp -X quit 2>/dev/null

echo -e "${C_GREEN}[✔] Online App activado con systemd (se reinicia al arrancar el VPS).${C_RST}"
echo -e "${C_NEON_YELLOW}URL de usuarios online para la App:${C_RST}"
echo -e "${C_CYAN}http://$IP:8888/server/online${C_RST}"
sleep 2
_oa_diagnostico
fi
read -p "Presione Enter para continuar..."
;;
2)
if [ "$is_running" -gt 0 ]; then
echo -e "${C_YELLOW}[+] Reiniciando Online App...${C_RST}"
systemctl restart onlineapp.service
echo -e "${C_GREEN}[✔] Servicio reiniciado.${C_RST}"
else
echo -e "${C_RED}[!] Online App no está activo.${C_RST}"
fi
read -p "Presione Enter para continuar..."
;;
3)
if [ "$is_running" -gt 0 ]; then
echo -e "${C_YELLOW}[+] Reparando Apache y firewall...${C_RST}"
_oa_preparar_web
systemctl restart onlineapp.service
sleep 2
_oa_diagnostico
else
echo -e "${C_RED}[!] Online App no está activo.${C_RST}"
fi
read -p "Presione Enter para continuar..."
;;
0) return ;;
*) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
esac
}
