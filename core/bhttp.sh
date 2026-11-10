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
# Gestor BHTTP Proxy - Instalación y Desinstalación
# ==========================================
C_ORANGE='\033[38;5;214m'; C_BLUE='\033[1;34m'; C_CYAN='\033[1;36m'; C_GREEN='\033[1;32m'; C_RED='\033[1;31m'; C_NC='\033[0m'
DEFAULT_PORT=8180
clear
echo -e "${C_ORANGE}------------------------------------------------------${C_NC}"
echo -e "               ${C_BLUE}${T[GESTOR DE BHTTP PROXY]:-GESTOR DE BHTTP PROXY}${C_NC}"
echo -e "${C_ORANGE}------------------------------------------------------${C_NC}"
echo -e " ${C_CYAN}1.${C_NC} ${T[Instalar / Cambiar Puerto BHTTP]:-Instalar / Cambiar Puerto BHTTP}"
echo -e " ${C_RED}2.${C_NC} ${T[Desinstalar y Liberar Puerto]:-Desinstalar y Liberar Puerto}"
echo -e " ${C_CYAN}0.${C_NC} ${T[Volver al Menú Principal]:-Volver al Menú Principal}"
echo -e "${C_ORANGE}------------------------------------------------------${C_NC}"
read -p " ${T[Selecciona una opción]:-Selecciona una opción}: " opcion

case $opcion in
    2)
        echo -e "\n${C_ORANGE}${T[Desinstalando BHTTP y liberando puerto]:-Desinstalando BHTTP y liberando puerto}...${C_NC}"
        systemctl stop bhttp > /dev/null 2>&1
        systemctl disable bhttp > /dev/null 2>&1
        rm -f /etc/systemd/system/bhttp.service
        rm -rf /etc/vps-manager/bhttp
        systemctl daemon-reload
        echo -e " ${C_GREEN}✅ ${T[BHTTP desinstalado correctamente]:-BHTTP desinstalado correctamente}.${C_NC}"
        read -p " ${T[Presiona Enter para volver]:-Presiona Enter para volver}..."
        exit 0
        ;;
    0)
        exit 0
        ;;
    1)
        echo -e "\n${C_CYAN}${T[Iniciando instalación]:-Iniciando instalación}...${C_NC}"
        ;;
    *)
        echo -e " ${C_RED}[!] ${T[Opción inválida]:-Opción inválida}.${C_NC}"
        sleep 2
        exit 1
        ;;
esac

mkdir -p /etc/vps-manager/bhttp
systemctl stop bhttp > /dev/null 2>&1

apt-get install -y python3-pam > /dev/null 2>&1
wget -qO /etc/vps-manager/bhttp/BHTTP.py "https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main/core/BHTTP.py"

if [ ! -s /etc/vps-manager/bhttp/BHTTP.py ]; then
    echo -e " ${C_RED}[!] ${T[Error: no se pudo descargar BHTTP.py]:-Error: no se pudo descargar BHTTP.py}${C_NC}"
    exit 1
fi

while true; do
    read -p "$(echo -e "${C_ORANGE}${T[Puerto de escucha]:-Puerto de escucha} [Default $DEFAULT_PORT]: ${C_NC}")" INPUT_PORT
    FINAL_PORT=${INPUT_PORT:-$DEFAULT_PORT}
    if ! [[ "$FINAL_PORT" =~ ^[0-9]+$ ]]; then echo -e " ${C_RED}[!] ${T[Número inválido]:-Número inválido}.${C_NC}"; continue; fi
    if netstat -tuln | grep -qE ":$FINAL_PORT\b"; then echo -e " ${C_RED}[!] ${T[Puerto en uso]:-Puerto en uso}.${C_NC}"; else break; fi
done

echo -e "\n${C_GREEN}[OK] ${T[Configurando puerto]:-Configurando puerto} $FINAL_PORT...${C_NC}"

sed -i "s/\"port\": 80/\"port\": $FINAL_PORT/g" /etc/vps-manager/bhttp/BHTTP.py
sed -i 's/"ssl": True/"ssl": False/g' /etc/vps-manager/bhttp/BHTTP.py

cat << EOF > /etc/systemd/system/bhttp.service
[Unit]
Description=BHTTP Proxy Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/vps-manager/bhttp
ExecStart=/usr/bin/python3 /etc/vps-manager/bhttp/BHTTP.py
LimitNOFILE=65535
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bhttp >/dev/null 2>&1
systemctl restart bhttp
sleep 2

if systemctl is-active --quiet bhttp; then
    echo -e "${C_ORANGE}------------------------------------------------------${C_NC}"
    echo -e " ${C_GREEN}✅ ${T[BHTTP operando en el puerto]:-BHTTP operando en el puerto} $FINAL_PORT ${T[con éxito]:-con éxito}${C_NC}"
    echo -e "${C_ORANGE}------------------------------------------------------${C_NC}"
else
    echo -e "\n${C_RED}[!] ${T[Error crítico: El servicio BHTTP colapsó al iniciar]:-Error crítico: El servicio BHTTP colapsó al iniciar}.${C_NC}"
    journalctl -u bhttp -n 10 --no-pager
fi
read -p " ${T[Presiona Enter para volver]:-Presiona Enter para volver}..."
