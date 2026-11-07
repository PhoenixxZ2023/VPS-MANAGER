#!/bin/bash
# VPS-MANAGER-MODULE: wsproxy
# Modulo cargado con "source" por menu.sh (usar_modulo). No ejecutar directamente.

menu_wsproxy() {
while true; do
clear
local is_running=0
systemctl is-active --quiet wsproxy.service 2>/dev/null && is_running=1
[ "$is_running" -eq 0 ] && [ "$(screen -ls 2>/dev/null | grep -c '\.ws')" -gt 0 ] && is_running=1
[ "$is_running" -eq 0 ] && ps x 2>/dev/null | grep -w "wsproxy.py" | grep -v grep >/dev/null 2>&1 && is_running=1

local WS_PORT=""
[ -f /etc/vps-manager/wsproxy_port ] && WS_PORT=$(cat /etc/vps-manager/wsproxy_port)
[ -z "$WS_PORT" ] && WS_PORT=$(grep -oE "wsproxy\.py [0-9]+" /etc/autostart 2>/dev/null | awk '{print $2}' | head -1)
[ -z "$WS_PORT" ] && WS_PORT="No configurado"

local WS_MSG=""
[ -f /etc/vps-manager/wsproxy_msg ] && WS_MSG=$(cat /etc/vps-manager/wsproxy_msg)
[ -z "$WS_MSG" ] && WS_MSG=$(grep -oP "HTTP/1.1 101 \K[^\r]+" /etc/vps-manager/wsproxy.py 2>/dev/null | head -1)
[ -z "$WS_MSG" ] && WS_MSG="internet premium"

local IP=$(curl -s --max-time 3 ipv4.icanhazip.com || hostname -I | awk '{print $1}')

echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🌐 GESTIÓN DE WSPROXY (WebSocket)      ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"

if [ "$is_running" -gt 0 ]; then
    echo -e "  Estado: ${C_GREEN}✅ ACTIVO${C_RST}"
    echo -e "  Puerto: ${C_NEON_YELLOW}$WS_PORT${C_RST}"
    echo -e "  Mensaje: ${C_NEON_YELLOW}$WS_MSG${C_RST}"
#    echo -e "  URL: ${C_NEON_YELLOW}ws://$IP:$WS_PORT${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} ⏹️ Detener y Desactivar WebSocket"
    echo -e "  ${C_NEON_YELLOW}2.${C_RST} 🔄 Reiniciar Servicio"
    echo -e "  ${C_NEON_YELLOW}3.${C_RST} 🔌 Cambiar Puerto de Escucha"
    echo -e "  ${C_NEON_YELLOW}4.${C_RST} 💬 Cambiar Mensaje HTTP"
else
    echo -e "  Estado: ${C_RED}❌ INACTIVO${C_RST}"
    echo -e "  Puerto: ${C_NEON_YELLOW}$WS_PORT${C_RST}"
    echo -e "  Mensaje: ${C_NEON_YELLOW}$WS_MSG${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar e Iniciar WebSocket"
fi

echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Anterior"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
read -p "Seleccione una opción: " ws_opt

case $ws_opt in
1)
    if [ "$is_running" -gt 0 ]; then
        echo -e "${C_YELLOW}[+] Desactivando WebSocket...${C_RST}"
        systemctl stop wsproxy.service 2>/dev/null
        systemctl disable wsproxy.service 2>/dev/null
        rm -f /etc/systemd/system/wsproxy.service
        systemctl daemon-reload 2>/dev/null
        for pidproxy in $(screen -ls 2>/dev/null | grep "\.ws" | awk '{print $1}'); do
            screen -r -S "$pidproxy" -X quit 2>/dev/null
        done
        screen -wipe >/dev/null 2>&1
        sed -i '/wsproxy.py/d' /etc/autostart 2>/dev/null
        echo -e "${C_GREEN}[✔] WebSocket desactivado correctamente.${C_RST}"
    else
        clear
        echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         INICIANDO WEBSOCKET PROXY            ${C_NEON_BLUE} ${C_RST}"
        echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
        
        echo -ne "${C_YELLOW}¿Qué puerto quieres usar? (1-65535): ${C_RST}"
        read porta
        
        if [[ ! "$porta" =~ ^[0-9]+$ ]] || [ "$porta" -lt 1 ] || [ "$porta" -gt 65535 ]; then
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
        
        echo -e "${C_YELLOW}[+] Instalando dependencias (Python3)...${C_RST}"
        apt-get update -y >/dev/null 2>&1
        apt-get install python3 screen -y >/dev/null 2>&1
        
        echo -e "${C_YELLOW}[+] Descargando wsproxy.py...${C_RST}"
        mkdir -p /etc/vps-manager
        wget -qO /etc/vps-manager/wsproxy.py ${REPO_RAW}/core/wsproxy.py
        
        if [ ! -f /etc/vps-manager/wsproxy.py ]; then
            echo -e "${C_RED}[!] Error al descargar wsproxy.py.${C_RST}"
            sleep 3
            continue
        fi
        
        echo "$porta" > /etc/vps-manager/wsproxy_port
        
        cat > /etc/systemd/system/wsproxy.service << EOF
[Unit]
Description=VPS-Manager WSProxy (WebSocket Proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vps-manager/wsproxy.py -b 0.0.0.0 -p $porta
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        
        sed -i '/wsproxy.py/d' /etc/autostart 2>/dev/null
        
        systemctl daemon-reload
        systemctl enable wsproxy.service >/dev/null 2>&1
        systemctl restart wsproxy.service
        
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
            ufw allow "$porta/tcp" >/dev/null 2>&1
        fi
        
        echo -e "${C_GREEN}[✔] WebSocket activado con systemd (se reinicia al arrancar el VPS).${C_RST}"
        echo -e "${C_CYAN}URL: ws://$IP:$porta${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
    ;;
2)
    if [ "$is_running" -gt 0 ]; then
        echo -e "${C_YELLOW}[+] Reiniciando WebSocket...${C_RST}"
        systemctl restart wsproxy.service
        echo -e "${C_GREEN}[✔] Servicio reiniciado.${C_RST}"
    else
        echo -e "${C_RED}[!] WebSocket no está activo.${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
    ;;
3)
    if [ "$is_running" -gt 0 ]; then
        echo -ne "${C_YELLOW}Nuevo puerto (1-65535): ${C_RST}"
        read new_port
        
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
            if ss -lntp 2>/dev/null | grep -q ":$new_port "; then
                echo -e "${C_RED}[!] El puerto $new_port ya está en uso.${C_RST}"
            else
                sed -i "s|ExecStart=.*|ExecStart=/usr/bin/python3 /etc/vps-manager/wsproxy.py -b 0.0.0.0 -p $new_port|" /etc/systemd/system/wsproxy.service
                echo "$new_port" > /etc/vps-manager/wsproxy_port
                
                if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
                    ufw delete allow "$WS_PORT/tcp" >/dev/null 2>&1
                    ufw allow "$new_port/tcp" >/dev/null 2>&1
                fi
                
                systemctl daemon-reload
                systemctl restart wsproxy.service
                
                echo -e "${C_GREEN}[✔] Puerto cambiado a $new_port.${C_RST}"
            fi
        else
            echo -e "${C_RED}[!] Puerto inválido.${C_RST}"
        fi
    else
        echo -e "${C_RED}[!] WebSocket no está activo. Actívalo primero.${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
    ;;
4)
    if [ "$is_running" -gt 0 ]; then
        local current_msg=$(grep -oP "HTTP/1.1 101 \K[^\r]+" /etc/vps-manager/wsproxy.py 2>/dev/null | head -1)
        [ -z "$current_msg" ] && current_msg="Servidor Premium"
        
        echo -e "${C_CYAN}Mensaje actual: ${C_YELLOW}$current_msg${C_RST}"
        echo -ne "${C_YELLOW}Nuevo mensaje HTTP (sin espacios especiales): ${C_RST}"
        read new_msg
        
        if [ -z "$new_msg" ]; then
            echo -e "${C_RED}[!] Mensaje vacío. Cancelado.${C_RST}"
        else
            sed -i "s|HTTP/1.1 101 [^\r]*\\\\r|HTTP/1.1 101 $new_msg\\\\r|" /etc/vps-manager/wsproxy.py
            echo "$new_msg" > /etc/vps-manager/wsproxy_msg
            systemctl restart wsproxy.service
            
            echo -e "${C_GREEN}[✔] Mensaje HTTP cambiado a: $new_msg${C_RST}"
            echo -e "${C_CYAN}Nota: Algunas apps pueden requerir mensajes específicos como 'internet premium' o 'SSHPLUS'.${C_RST}"
        fi
    else
        echo -e "${C_RED}[!] WebSocket no está activo. Actívalo primero.${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
    ;;
0) break ;;
*) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
esac
done
}
