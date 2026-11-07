#!/bin/bash
# VPS-MANAGER-MODULE: checkuser_multi
# Modulo cargado con "source" por menu.sh (usar_modulo). No ejecutar directamente.

menu_checkuser_multi() {
local CHKM_DIR="/etc/vps-manager/checkuser"
local CHKM_UNIT="/etc/systemd/system/checkuser-multi.service"
local CHKM_OLD="/etc/systemd/system/checkuser.service"
local CHKM_PORT_FILE="/etc/vps-manager/checkuser_multi_port"
# Migrar instalación antigua (checkuser.service -> checkuser-multi.service)
if [ -f "$CHKM_OLD" ] && grep -q "Multi-App" "$CHKM_OLD" 2>/dev/null; then
    systemctl stop checkuser 2>/dev/null
    systemctl disable checkuser 2>/dev/null
    mv "$CHKM_OLD" "$CHKM_UNIT"
    systemctl daemon-reload
    systemctl enable checkuser-multi >/dev/null 2>&1
    systemctl restart checkuser-multi 2>/dev/null
fi
while true; do
clear
local is_installed=0 is_running=0 CHKM_PORT="No configurado"
if [ -f "$CHKM_DIR/check.py" ] && [ -f "$CHKM_UNIT" ]; then
    is_installed=1
    CHKM_PORT=$(grep -m1 -oE 'def run\(port=[0-9]+' "$CHKM_DIR/check.py" | grep -oE '[0-9]+')
    [ -z "$CHKM_PORT" ] && CHKM_PORT=$(cat "$CHKM_PORT_FILE" 2>/dev/null || echo "5432")
    systemctl is-active --quiet checkuser-multi 2>/dev/null && is_running=1
fi

echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}       👥 GESTIÓN CHECKUSER MULTI-APP         ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
if [ "$is_installed" -eq 1 ]; then
    if [ "$is_running" -eq 1 ]; then
        echo -e "  Estado: ${C_GREEN}✅ ACTIVO${C_RST}"
    else
        echo -e "  Estado: ${C_RED}⏹️ DETENIDO${C_RST}"
    fi
    echo -e "  Puerto: ${C_NEON_YELLOW}${CHKM_PORT}${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🔌 Cambiar Puerto"
    if [ "$is_running" -eq 1 ]; then
        echo -e "  ${C_NEON_YELLOW}2.${C_RST} ⏹️ Detener Servicio"
    else
        echo -e "  ${C_NEON_YELLOW}2.${C_RST} ▶️ Iniciar Servicio"
    fi
    echo -e "  ${C_NEON_YELLOW}3.${C_RST} 🔄 Reiniciar Servicio"
    echo -e "  ${C_NEON_YELLOW}4.${C_RST} 🗑️ Desinstalar CheckUser Multi-App"
else
    echo -e "  Estado: ${C_RED}❌ NO INSTALADO${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar CheckUser Multi-App"
fi
echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Principal"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
read -p "Seleccione una opción: " chkm_opt

if [ "$is_installed" -eq 0 ]; then
    case $chkm_opt in
    1)
        clear
        echo -e "${C_YELLOW}[+] Descargando CheckUser (Multi-App)...${C_RST}"
        if wget -qO /tmp/checkuser.sh ${REPO_RAW}/core/checkuser.sh && [ -s /tmp/checkuser.sh ]; then
            chmod +x /tmp/checkuser.sh && bash /tmp/checkuser.sh
        else
            echo -e "${C_RED}[!] No se pudo descargar checkuser.sh. Revisa tu conexión o la ruta en GitHub.${C_RST}"
            sleep 3
        fi ;;
    0) break ;;
    *) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
    esac
    continue
fi

case $chkm_opt in
1)
    echo -ne "${C_YELLOW}Nuevo puerto (1-65535): ${C_RST}"
    read nuevo
    if [[ ! "$nuevo" =~ ^[0-9]+$ ]] || [ "$nuevo" -lt 1 ] || [ "$nuevo" -gt 65535 ]; then
        echo -e "${C_RED}[!] Puerto no válido.${C_RST}"; sleep 2; continue
    fi
    if [ "$nuevo" = "$CHKM_PORT" ]; then
        echo -e "${C_YELLOW}[!] Ya está usando el puerto $nuevo.${C_RST}"; sleep 2; continue
    fi
    if ss -lntp 2>/dev/null | grep -q ":$nuevo "; then
        local svc=$(ss -lntp 2>/dev/null | grep ":$nuevo " | awk '{print $NF}' | cut -d'"' -f2 | head -n1)
        echo -e "${C_RED}[!] El puerto $nuevo ya está en uso por: $svc${C_RST}"; sleep 3; continue
    fi
    cp "$CHKM_DIR/check.py" "$CHKM_DIR/check.py.bak"
    sed -i -E "s/def run\(port=[0-9]+\)/def run(port=${nuevo})/" "$CHKM_DIR/check.py"
    # Firewall: abrir el nuevo y cerrar el anterior
    iptables -D INPUT -p tcp --dport "$CHKM_PORT" -j ACCEPT 2>/dev/null
    iptables -D INPUT -p tcp --dport "$nuevo" -j ACCEPT 2>/dev/null
    iptables -I INPUT -p tcp --dport "$nuevo" -j ACCEPT 2>/dev/null
    iptables-save > /etc/iptables.up.rules 2>/dev/null
    ufw allow "$nuevo"/tcp >/dev/null 2>&1
    ufw delete allow "$CHKM_PORT"/tcp >/dev/null 2>&1
    systemctl restart checkuser-multi 2>/dev/null
    sleep 1
    if systemctl is-active --quiet checkuser-multi 2>/dev/null; then
        echo "$nuevo" > "$CHKM_PORT_FILE"
        rm -f "$CHKM_DIR/check.py.bak"
        echo -e "${C_GREEN}[✔] Puerto cambiado a $nuevo y servicio reiniciado.${C_RST}"
    else
        mv "$CHKM_DIR/check.py.bak" "$CHKM_DIR/check.py"
        iptables -D INPUT -p tcp --dport "$nuevo" -j ACCEPT 2>/dev/null
        iptables -I INPUT -p tcp --dport "$CHKM_PORT" -j ACCEPT 2>/dev/null
        systemctl restart checkuser-multi 2>/dev/null
        echo -e "${C_RED}[!] No arrancó con el nuevo puerto. Se restauró el puerto $CHKM_PORT.${C_RST}"
    fi
    read -p "Presione Enter para continuar..." ;;
2)
    if [ "$is_running" -eq 1 ]; then
        systemctl stop checkuser-multi 2>/dev/null
        echo -e "${C_GREEN}[✔] CheckUser Multi-App detenido.${C_RST}"
    else
        systemctl start checkuser-multi 2>/dev/null
        sleep 1
        systemctl is-active --quiet checkuser-multi 2>/dev/null \
            && echo -e "${C_GREEN}[✔] CheckUser Multi-App iniciado.${C_RST}" \
            || echo -e "${C_RED}[!] No se pudo iniciar. Revisa: journalctl -u checkuser-multi${C_RST}"
    fi
    sleep 2 ;;
3)
    systemctl restart checkuser-multi 2>/dev/null
    sleep 1
    systemctl is-active --quiet checkuser-multi 2>/dev/null \
        && echo -e "${C_GREEN}[✔] CheckUser Multi-App reiniciado.${C_RST}" \
        || echo -e "${C_RED}[!] No se pudo reiniciar. Revisa: journalctl -u checkuser-multi${C_RST}"
    sleep 2 ;;
4)
    read -p "⚠️ ¿Desinstalar CheckUser Multi-App (puerto $CHKM_PORT)? (s/n): " conf_chkm
    if [[ "$conf_chkm" == "s" || "$conf_chkm" == "S" ]]; then
        echo -e "${C_YELLOW}[+] Desinstalando CheckUser Multi-App...${C_RST}"
        systemctl stop checkuser-multi 2>/dev/null
        systemctl disable checkuser-multi 2>/dev/null
        rm -f "$CHKM_UNIT"
        systemctl daemon-reload
        rm -rf "$CHKM_DIR"
        rm -f "$CHKM_PORT_FILE"
        iptables -D INPUT -p tcp --dport "$CHKM_PORT" -j ACCEPT 2>/dev/null
        iptables-save > /etc/iptables.up.rules 2>/dev/null
        ufw delete allow "$CHKM_PORT"/tcp >/dev/null 2>&1
        echo -e "${C_GREEN}[✔] CheckUser Multi-App desinstalado correctamente.${C_RST}"
    else
        echo -e "${C_YELLOW}[!] Cancelado.${C_RST}"
    fi
    sleep 2 ;;
0) break ;;
*) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
esac
done
}
