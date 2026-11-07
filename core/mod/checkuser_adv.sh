#!/bin/bash
# VPS-MANAGER-MODULE: checkuser_adv
# Modulo cargado con "source" por menu.sh (usar_modulo). No ejecutar directamente.

# ==========================================
# FUNCIÓN CHECKUSER AVANZADO
# ==========================================
menu_checkuser() {
mkdir -p /etc/vps-manager
local check_file_exists=$( [ -f /etc/vps-manager/check.py ] && echo "1" || echo "0" )
local check4g_file_exists=$( [ -f /etc/vps-manager/4gcheck.py ] && echo "1" || echo "0" )
if [ "$check_file_exists" == "0" ] || [ "$check4g_file_exists" == "0" ]; then
clear
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🛡️ INSTALAR CHECKUSER AVANZADO        ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  Se descargarán los siguientes archivos:"
echo -e "  - ${C_NEON_YELLOW}/etc/vps-manager/check.py${C_RST}"
echo -e "  - ${C_NEON_YELLOW}/etc/vps-manager/4gcheck.py${C_RST}"
echo -e "  - ${C_NEON_YELLOW}/bin/check${C_RST}"
echo -e "  Además se instalarán: ${C_NEON_YELLOW}python3-pip, flask${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar archivos de CheckUser"
echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Principal"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
read -p "Seleccione una opción: " inst_opt
case $inst_opt in
1)
echo -e "${C_YELLOW}[+] Instalando dependencias (python3-pip, flask)...${C_RST}"
apt update -y >/dev/null 2>&1
apt install python3-pip flask -y >/dev/null 2>&1
pip3 install flask >/dev/null 2>&1
echo -e "${C_YELLOW}[+] Descargando archivos de CheckUser...${C_RST}"
wget -qO /etc/vps-manager/check.py https://raw.githubusercontent.com/rogellevi/SSHPLUS-fixed/master/Modulos/check.py
wget -qO /etc/vps-manager/4gcheck.py https://raw.githubusercontent.com/rogellevi/SSHPLUS-fixed/master/Modulos/4gcheck.py
wget -qO /bin/check https://raw.githubusercontent.com/rogellevi/SSHPLUS-fixed/master/Modulos/check
chmod +x /bin/check /etc/vps-manager/check.py /etc/vps-manager/4gcheck.py
echo -e "${C_GREEN}[✔] Archivos instalados correctamente.${C_RST}"
sleep 2
;;
0) return ;;
*) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1; return ;;
esac
fi
while true; do
clear
# Estado vía systemd (más fiable)
local is_std_running=0
local is_4g_running=0
systemctl is-active --quiet checkuser.service 2>/dev/null && is_std_running=1
systemctl is-active --quiet checkuser-4g.service 2>/dev/null && is_4g_running=1
# Fallback a screen por si aún queda sesión antigua
[ "$is_std_running" -eq 0 ] && [ "$(screen -ls 2>/dev/null | grep -c '\.checkuser')" -gt 0 ] && is_std_running=1
[ "$is_4g_running" -eq 0 ] && [ "$(screen -ls 2>/dev/null | grep -c '\.4gcheck')" -gt 0 ] && is_4g_running=1

local std_status="❌ INACTIVO"
local std_color="$C_RED"
[ "$is_std_running" -gt 0 ] && { std_status="✅ ACTIVO"; std_color="$C_GREEN"; }
local status_4g="❌ INACTIVO"
local color_4g="$C_RED"
[ "$is_4g_running" -gt 0 ] && { status_4g="✅ ACTIVO"; color_4g="$C_GREEN"; }
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🛡️ GESTIÓN DE CHECKUSER AVANZADO       ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  ${C_NEON_YELLOW}1.${C_RST} 👤 CheckUser (Estándar) ......... [ ${std_color}${std_status}${C_RST} ]"
echo -e "  ${C_NEON_YELLOW}2.${C_RST} 📱 CheckUser (Conecta4G) ........ [ ${color_4g}${status_4g}${C_RST} ]"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Principal"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
read -p "Seleccione una opción: " cu_opt
case $cu_opt in
1)
if [ "$is_std_running" -gt 0 ]; then
echo -e "${C_YELLOW}[+] Desactivando CheckUser (Estándar)...${C_RST}"
systemctl stop checkuser.service 2>/dev/null
systemctl disable checkuser.service 2>/dev/null
rm -f /etc/systemd/system/checkuser.service
systemctl daemon-reload 2>/dev/null
# Limpiar restos de screen y autostart antiguos
screen -S checkuser -X quit 2>/dev/null
screen -wipe >/dev/null 2>&1
sed -i '/check\.py/d' /etc/autostart 2>/dev/null
echo -e "${C_GREEN}[✔] CheckUser (Estándar) desactivado.${C_RST}"
read -p "Presione Enter para continuar..."
else
clear
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         ACTIVAR CHECKUSER (ESTÁNDAR)         ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
echo -ne "${C_YELLOW}Ingrese el puerto para CheckUser (1024-65535): ${C_RST}"
read porta
if [[ ! "$porta" =~ ^[0-9]+$ ]] || [ "$porta" -lt 1024 ] || [ "$porta" -gt 65535 ]; then
echo -e "${C_RED}[!] Puerto no válido.${C_RST}"
sleep 2
continue
fi
if ss -lntp 2>/dev/null | grep -q ":$porta "; then
local svc=$(ss -lntp 2>/dev/null | grep ":$porta " | awk '{print $NF}' | cut -d'"' -f2)
echo -e "${C_RED}[!] El puerto $porta ya está en uso por: $svc${C_RST}"
sleep 3
continue
fi
echo -e "${C_NEON_YELLOW}Seleccione el formato de fecha:${C_RST}"
echo -e "  ${C_NEON_YELLOW}1.${C_RST} YYYY/MM/DD (Más común)"
echo -e "  ${C_NEON_YELLOW}2.${C_RST} DD/MM/YYYY"
read -p "Opción: " fmt_opt
local format=1
[ "$fmt_opt" == "2" ] && format=2
echo -e "${C_YELLOW}[+] Configurando servicio systemd CheckUser (Estándar) en puerto $porta...${C_RST}"

# Guardar puerto y formato para referencia
echo "$porta" > /etc/vps-manager/checkuser_port
echo "$format" > /etc/vps-manager/checkuser_format

# Crear unit systemd
cat > /etc/systemd/system/checkuser.service << EOF
[Unit]
Description=VPS-Manager CheckUser (Estándar)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vps-manager/check.py $porta $format
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable checkuser.service >/dev/null 2>&1
systemctl restart checkuser.service

# Limpiar restos antiguos
sed -i '/check\.py/d' /etc/autostart 2>/dev/null
screen -S checkuser -X quit 2>/dev/null

local IP=$(curl -s --max-time 3 ipv4.icanhazip.com || hostname -I | awk '{print $1}')
echo -e "${C_GREEN}[✔] CheckUser (Estándar) activado con systemd (se reinicia al arrancar el VPS).${C_RST}"
echo -e "${C_CYAN}URL: http://$IP:$porta/checkUser${C_RST}"
read -p "Presione Enter para continuar..."
fi
;;
2)
if [ "$is_4g_running" -gt 0 ]; then
echo -e "${C_YELLOW}[+] Desactivando CheckUser (Conecta4G)...${C_RST}"
systemctl stop checkuser-4g.service 2>/dev/null
systemctl disable checkuser-4g.service 2>/dev/null
rm -f /etc/systemd/system/checkuser-4g.service
systemctl daemon-reload 2>/dev/null
screen -S 4gcheck -X quit 2>/dev/null
screen -wipe >/dev/null 2>&1
sed -i '/4gcheck\.py/d' /etc/autostart 2>/dev/null
echo -e "${C_GREEN}[✔] CheckUser (Conecta4G) desactivado.${C_RST}"
read -p "Presione Enter para continuar..."
else
clear
echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         ACTIVAR CHECKUSER (CONECTA4G)        ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
echo -ne "${C_YELLOW}Ingrese el puerto para CheckUser 4G (1024-65535): ${C_RST}"
read porta
if [[ ! "$porta" =~ ^[0-9]+$ ]] || [ "$porta" -lt 1024 ] || [ "$porta" -gt 65535 ]; then
echo -e "${C_RED}[!] Puerto no válido.${C_RST}"
sleep 2
continue
fi
if ss -lntp 2>/dev/null | grep -q ":$porta "; then
local svc=$(ss -lntp 2>/dev/null | grep ":$porta " | awk '{print $NF}' | cut -d'"' -f2)
echo -e "${C_RED}[!] El puerto $porta ya está en uso por: $svc${C_RST}"
sleep 3
continue
fi
echo -e "${C_YELLOW}[+] Configurando servicio systemd CheckUser (Conecta4G) en puerto $porta...${C_RST}"

echo "$porta" > /etc/vps-manager/checkuser4g_port

cat > /etc/systemd/system/checkuser-4g.service << EOF
[Unit]
Description=VPS-Manager CheckUser (Conecta4G)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vps-manager/4gcheck.py $porta
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable checkuser-4g.service >/dev/null 2>&1
systemctl restart checkuser-4g.service

sed -i '/4gcheck\.py/d' /etc/autostart 2>/dev/null
screen -S 4gcheck -X quit 2>/dev/null

local IP=$(curl -s --max-time 3 ipv4.icanhazip.com || hostname -I | awk '{print $1}')
echo -e "${C_GREEN}[✔] CheckUser (Conecta4G) activado con systemd (se reinicia al arrancar el VPS).${C_RST}"
echo -e "${C_CYAN}URL: http://$IP:$porta/checkUser${C_RST}"
read -p "Presione Enter para continuar..."
fi
;;
0) break ;;
*) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
esac
done
}
