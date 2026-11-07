#!/bin/bash
# VPS-MANAGER-MODULE: ssl
# Modulo cargado con "source" por menu.sh (usar_modulo). No ejecutar directamente.

menu_ssl() {
while true; do
clear
local SSL_CONF="" SSL_PORT="No configurado" is_installed=0 is_running=0
SSL_CONF=$(grep -l -E '^[[:space:]]*accept[[:space:]]*=' /etc/stunnel/*.conf 2>/dev/null | head -n1)
if command -v stunnel4 >/dev/null 2>&1 && [ -n "$SSL_CONF" ]; then
    is_installed=1
    SSL_PORT=$(grep -m1 -E '^[[:space:]]*accept[[:space:]]*=' "$SSL_CONF" | sed -E 's/.*=[[:space:]]*//; s/.*://; s/[[:space:]]//g')
    [ -z "$SSL_PORT" ] && SSL_PORT=$(cat /etc/vps-manager/ssl_port 2>/dev/null || echo "No configurado")
    systemctl is-active --quiet stunnel4 2>/dev/null && is_running=1
fi

echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🔒 GESTIÓN SSL / TLS (STUNNEL)       ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"

if [ "$is_installed" -eq 1 ]; then
    if [ "$is_running" -eq 1 ]; then
        echo -e "  Estado: ${C_GREEN}✅ ACTIVO${C_RST}"
    else
        echo -e "  Estado: ${C_RED}⏹️ DETENIDO${C_RST}"
    fi
    echo -e "  Puerto: ${C_NEON_YELLOW}${SSL_PORT}${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🔌 Cambiar Puerto"
    if [ "$is_running" -eq 1 ]; then
        echo -e "  ${C_NEON_YELLOW}2.${C_RST} ⏹️ Detener Servicio"
    else
        echo -e "  ${C_NEON_YELLOW}2.${C_RST} ▶️ Iniciar Servicio"
    fi
    echo -e "  ${C_NEON_YELLOW}3.${C_RST} 🔄 Reiniciar Servicio"
    echo -e "  ${C_NEON_YELLOW}4.${C_RST} 🗑️ Desinstalar SSL / TLS"
else
    echo -e "  Estado: ${C_RED}❌ NO INSTALADO${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar SSL / TLS"
fi
echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Anterior"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
read -p "Seleccione una opción: " ssl_opt

if [ "$is_installed" -eq 0 ]; then
    case $ssl_opt in
    1)
        clear
        run_remote ssl.sh
        read -p "Presione Enter para continuar..." ;;
    0) break ;;
    *) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1; continue ;;
    esac
    continue
fi

case $ssl_opt in
1)
    echo -ne "${C_YELLOW}Nuevo puerto SSL (1-65535): ${C_RST}"
    read nuevo
    if [[ ! "$nuevo" =~ ^[0-9]+$ ]] || [ "$nuevo" -lt 1 ] || [ "$nuevo" -gt 65535 ]; then
        echo -e "${C_RED}[!] Puerto no válido.${C_RST}"; sleep 2; continue
    fi
    if [ "$nuevo" = "$SSL_PORT" ]; then
        echo -e "${C_YELLOW}[!] Ya está usando el puerto $nuevo.${C_RST}"; sleep 2; continue
    fi
    if ss -lntp 2>/dev/null | grep -q ":$nuevo "; then
        local svc=$(ss -lntp 2>/dev/null | grep ":$nuevo " | awk '{print $NF}' | cut -d'"' -f2 | head -n1)
        echo -e "${C_RED}[!] El puerto $nuevo ya está en uso por: $svc${C_RST}"; sleep 3; continue
    fi
    local ln=$(grep -n -m1 -E '^[[:space:]]*accept[[:space:]]*=' "$SSL_CONF" | cut -d: -f1)
    cp "$SSL_CONF" "${SSL_CONF}.bak"
    sed -i -E "${ln}s/^([[:space:]]*accept[[:space:]]*=[[:space:]]*)(.*:)?[0-9]+/\1\2${nuevo}/" "$SSL_CONF"
    mkdir -p /etc/vps-manager
    echo "$nuevo" > /etc/vps-manager/ssl_port
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" && ufw allow "$nuevo"/tcp >/dev/null 2>&1
    systemctl restart stunnel4 2>/dev/null
    sleep 1
    if systemctl is-active --quiet stunnel4 2>/dev/null; then
        echo -e "${C_GREEN}[✔] Puerto cambiado a $nuevo y servicio reiniciado.${C_RST}"
    else
        mv "${SSL_CONF}.bak" "$SSL_CONF"
        echo "$SSL_PORT" > /etc/vps-manager/ssl_port
        systemctl restart stunnel4 2>/dev/null
        echo -e "${C_RED}[!] No arrancó con el nuevo puerto. Se restauró el puerto $SSL_PORT.${C_RST}"
    fi
    read -p "Presione Enter para continuar..." ;;
2)
    if [ "$is_running" -eq 1 ]; then
        systemctl stop stunnel4 2>/dev/null
        echo -e "${C_GREEN}[✔] Servicio SSL detenido.${C_RST}"
    else
        systemctl start stunnel4 2>/dev/null
        sleep 1
        systemctl is-active --quiet stunnel4 2>/dev/null \
            && echo -e "${C_GREEN}[✔] Servicio SSL iniciado.${C_RST}" \
            || echo -e "${C_RED}[!] No se pudo iniciar. Revisa: journalctl -u stunnel4${C_RST}"
    fi
    sleep 2 ;;
3)
    systemctl restart stunnel4 2>/dev/null
    sleep 1
    systemctl is-active --quiet stunnel4 2>/dev/null \
        && echo -e "${C_GREEN}[✔] Servicio SSL reiniciado.${C_RST}" \
        || echo -e "${C_RED}[!] No se pudo reiniciar. Revisa: journalctl -u stunnel4${C_RST}"
    sleep 2 ;;
4)
    read -p "⚠️ ¿Desinstalar SSL / TLS (puerto $SSL_PORT)? (s/n): " conf_ssl
    if [[ "$conf_ssl" == "s" || "$conf_ssl" == "S" ]]; then
        echo -e "${C_YELLOW}[+] Desinstalando SSL / TLS...${C_RST}"
        systemctl stop stunnel4 2>/dev/null
        systemctl disable stunnel4 2>/dev/null
        pkill -9 stunnel4 2>/dev/null
        apt-get remove --purge stunnel4 -y >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
        rm -rf /etc/stunnel
        rm -f /etc/default/stunnel4
        rm -f /etc/vps-manager/ssl_port
        command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" && ufw delete allow "$SSL_PORT"/tcp >/dev/null 2>&1
        echo -e "${C_GREEN}[✔] SSL / TLS desinstalado correctamente.${C_RST}"
    else
        echo -e "${C_YELLOW}[!] Cancelado.${C_RST}"
    fi
    sleep 2 ;;
0) break ;;
*) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
esac
done
}
