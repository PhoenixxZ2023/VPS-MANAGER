#!/bin/bash
# VPS-MANAGER-MODULE: dropbear
# Modulo cargado con "source" por menu.sh (usar_modulo). No ejecutar directamente.

# ==========================================
# SUBMENÚ: GESTIÓN DE DROPBEAR (Corregido para Ubuntu 22.04)
# ==========================================
menu_dropbear() {
while true; do
clear
local is_running=0
systemctl is-active --quiet dropbear 2>/dev/null && is_running=1
[ "$is_running" -eq 0 ] && [ "$(netstat -tlpn 2>/dev/null | grep -c 'dropbear')" -gt 0 ] && is_running=1

local DROPBEAR_PORT_MAIN="No configurado"
local DROPBEAR_PORT_EXTRA="Ninguno"
if [ -f /etc/default/dropbear ]; then
    DROPBEAR_PORT_MAIN=$(grep "^DROPBEAR_PORT=" /etc/default/dropbear 2>/dev/null | cut -d'=' -f2 | tr -d ' ')
    DROPBEAR_PORT_EXTRA=$(grep "^DROPBEAR_EXTRA_ARGS=" /etc/default/dropbear 2>/dev/null | grep -oE '\-p [0-9]+' | awk '{print $2}' | tr '\n' ' ')
fi
[ -z "$DROPBEAR_PORT_MAIN" ] && DROPBEAR_PORT_MAIN="No configurado"
[ -z "$DROPBEAR_PORT_EXTRA" ] && DROPBEAR_PORT_EXTRA="Ninguno"

local limiter_running=0
ps x 2>/dev/null | grep -w "droplimiter" | grep -v grep >/dev/null 2>&1 && limiter_running=1
[ "$limiter_running" -eq 0 ] && [ "$(screen -ls 2>/dev/null | grep -c '\.limiter')" -gt 0 ] && limiter_running=1
local limiter_status="🔴 OFF"
local limiter_color="$C_RED"
[ "$limiter_running" -gt 0 ] && { limiter_status="🟢 ON"; limiter_color="$C_GREEN"; }

local IP=$(curl -s --max-time 3 ipv4.icanhazip.com || hostname -I | awk '{print $1}')

echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🐻 GESTIÓN DE DROPBEAR SSH           ${C_NEON_BLUE} ${C_RST}"
echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"

if [ "$is_running" -gt 0 ]; then
    echo -e "  Estado: ${C_GREEN}✅ ACTIVO${C_RST}"
    echo -e "  Puerto Principal: ${C_NEON_YELLOW}${DROPBEAR_PORT_MAIN}${C_RST}"
    echo -e "  Puerto Extra: ${C_NEON_YELLOW}${DROPBEAR_PORT_EXTRA}${C_RST}"
    echo -e "  Droplimiter: ${limiter_color}${limiter_status}${C_RST}"
#    echo -e "  URL: ${C_NEON_YELLOW}ssh://$IP:${DROPBEAR_PORT_MAIN}${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} ⏹️ Detener y Desinstalar Dropbear"
    echo -e "  ${C_NEON_YELLOW}2.${C_RST} 🔌 Modificar Puerto Principal"
    echo -e "  ${C_NEON_YELLOW}3.${C_RST} 🔌 Modificar Puerto Extra"
    echo -e "  ${C_NEON_YELLOW}4.${C_RST} 🛡️ Activar/Desactivar Droplimiter"
    echo -e "  ${C_NEON_YELLOW}5.${C_RST} 🔄 Reiniciar Servicio"
else
    echo -e "  Estado: ${C_RED}❌ INACTIVO${C_RST}"
    echo -e "  Puerto Principal: ${C_NEON_YELLOW}${DROPBEAR_PORT_MAIN}${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar Dropbear"
fi

echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Anterior"
echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
read -p "Seleccione una opción: " db_opt

case $db_opt in
1)
    if [ "$is_running" -gt 0 ]; then
        echo -e "${C_YELLOW}[+] Deteniendo y desinstalando Dropbear...${C_RST}"
        systemctl stop dropbear 2>/dev/null
        systemctl disable dropbear 2>/dev/null
        
        for pidlim in $(screen -ls 2>/dev/null | grep "\.limiter" | awk '{print $1}'); do
            screen -r -S "$pidlim" -X quit 2>/dev/null
        done
        screen -wipe >/dev/null 2>&1
        pkill -f droplimiter 2>/dev/null
        pkill -9 dropbear 2>/dev/null
        
        apt-get remove dropbear -y >/dev/null 2>&1
        apt-get purge dropbear -y >/dev/null 2>&1
        apt-get autoremove -y >/dev/null 2>&1
        
        rm -rf /etc/default/dropbear
        rm -rf /etc/dropbear
        
        echo -e "${C_GREEN}[✔] Dropbear desinstalado correctamente.${C_RST}"
    else
        clear
        echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         INSTALADOR DROPBEAR SSH              ${C_NEON_BLUE} ${C_RST}"
        echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
        
        echo -ne "${C_YELLOW}¿Qué puerto principal quieres usar? (1-65535): ${C_RST}"
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
        
        echo -e "${C_YELLOW}[+] Instalando Dropbear...${C_RST}"
        apt-get update -y >/dev/null 2>&1
        apt-get install dropbear -y >/dev/null 2>&1
        
        if ! grep -q "/bin/false" /etc/shells; then
            echo "/bin/false" >> /etc/shells
        fi
        
        sed -i '/^PasswordAuthentication/d' /etc/ssh/sshd_config
        echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
        sed -i '/^PermitTunnel/d' /etc/ssh/sshd_config
        echo "PermitTunnel yes" >> /etc/ssh/sshd_config
        
        mkdir -p /etc/dropbear
        touch /etc/dropbear/banner
        
        # 🚨 SOLUCIÓN: Eliminar líneas viejas y agregar nuevas al final
        sed -i '/^DROPBEAR_PORT=/d' /etc/default/dropbear
        sed -i '/^DROPBEAR_EXTRA_ARGS=/d' /etc/default/dropbear
        sed -i '/^NO_START=/d' /etc/default/dropbear
        
        echo "NO_START=0" >> /etc/default/dropbear
        echo "DROPBEAR_PORT=$porta" >> /etc/default/dropbear
        echo "DROPBEAR_EXTRA_ARGS=\"-p 110\"" >> /etc/default/dropbear
        echo "DROPBEAR_BANNER=\"/etc/dropbear/banner\"" >> /etc/default/dropbear
        echo "DROPBEAR_RECEIVE_WINDOW=65536" >> /etc/default/dropbear
        
        systemctl stop dropbear 2>/dev/null
        pkill -9 dropbear 2>/dev/null
        sleep 1
        
        systemctl daemon-reload
        systemctl enable dropbear >/dev/null 2>&1
        systemctl restart dropbear
        
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
            ufw allow "$porta/tcp" >/dev/null 2>&1
            ufw allow "110/tcp" >/dev/null 2>&1
        fi
        
        systemctl restart ssh >/dev/null 2>&1
        
        sleep 2
        if systemctl is-active --quiet dropbear 2>/dev/null; then
            echo -e "${C_GREEN}[✔] Dropbear instalado y activo.${C_RST}"
            echo -e "${C_CYAN}Puertos: ${C_YELLOW}$porta${C_RST} (principal) y ${C_YELLOW}110${C_RST} (extra)${C_RST}"
        else
            echo -e "${C_RED}[!] Dropbear NO pudo iniciar.${C_RST}"
            echo -e "${C_YELLOW}Verifica con: systemctl status dropbear${C_RST}"
        fi
    fi
    read -p "Presione Enter para continuar..."
    ;;
2)
    if [ "$is_running" -gt 0 ]; then
        echo -ne "${C_YELLOW}Nuevo puerto principal (1-65535): ${C_RST}"
        read new_port
        
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
            if ss -lntp 2>/dev/null | grep -q ":$new_port "; then
                echo -e "${C_RED}[!] El puerto $new_port ya está en uso.${C_RST}"
            else
                sed -i '/^DROPBEAR_PORT=/d' /etc/default/dropbear
                echo "DROPBEAR_PORT=$new_port" >> /etc/default/dropbear
                
                if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
                    ufw delete allow "$DROPBEAR_PORT_MAIN/tcp" >/dev/null 2>&1
                    ufw allow "$new_port/tcp" >/dev/null 2>&1
                fi
                
                systemctl restart dropbear
                echo -e "${C_GREEN}[✔] Puerto principal cambiado a $new_port.${C_RST}"
            fi
        else
            echo -e "${C_RED}[!] Puerto inválido.${C_RST}"
        fi
    else
        echo -e "${C_RED}[!] Dropbear no está activo. Instálalo primero.${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
    ;;
3)
    if [ "$is_running" -gt 0 ]; then
        echo -ne "${C_YELLOW}Nuevo puerto extra (1-65535): ${C_RST}"
        read new_extra
        
        if [[ "$new_extra" =~ ^[0-9]+$ ]] && [ "$new_extra" -ge 1 ] && [ "$new_extra" -le 65535 ]; then
            if ss -lntp 2>/dev/null | grep -q ":$new_extra "; then
                echo -e "${C_RED}[!] El puerto $new_extra ya está en uso.${C_RST}"
            else
                sed -i '/^DROPBEAR_EXTRA_ARGS=/d' /etc/default/dropbear
                echo "DROPBEAR_EXTRA_ARGS=\"-p $new_extra\"" >> /etc/default/dropbear
                
                if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
                    ufw delete allow "$DROPBEAR_PORT_EXTRA/tcp" >/dev/null 2>&1
                    ufw allow "$new_extra/tcp" >/dev/null 2>&1
                fi
                
                systemctl restart dropbear
                echo -e "${C_GREEN}[✔] Puerto extra cambiado a $new_extra.${C_RST}"
            fi
        else
            echo -e "${C_RED}[!] Puerto inválido.${C_RST}"
        fi
    else
        echo -e "${C_RED}[!] Dropbear no está activo. Instálalo primero.${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
    ;;
4)
    if [ "$is_running" -gt 0 ]; then
        if [ "$limiter_running" -gt 0 ]; then
            echo -e "${C_YELLOW}[+] Deteniendo Droplimiter...${C_RST}"
            for pidlim in $(screen -ls 2>/dev/null | grep "\.limiter" | awk '{print $1}'); do
                screen -r -S "$pidlim" -X quit 2>/dev/null
            done
            screen -wipe >/dev/null 2>&1
            pkill -f droplimiter 2>/dev/null
            echo -e "${C_GREEN}[✔] Droplimiter desactivado.${C_RST}"
        else
            if ! command -v droplimiter >/dev/null 2>&1; then
                echo -e "${C_YELLOW}[+] Descargando Droplimiter desde GitHub...${C_RST}"
                wget -qO /usr/local/bin/droplimiter ${REPO_RAW}/core/droplimiter
                chmod +x /usr/local/bin/droplimiter 2>/dev/null
            fi
            
            if command -v droplimiter >/dev/null 2>&1; then
                echo -e "${C_YELLOW}[+] Activando Droplimiter en background...${C_RST}"
                screen -dmS limiter droplimiter
                sleep 1
                echo -e "${C_GREEN}[✔] Droplimiter activado.${C_RST}"
            else
                echo -e "${C_RED}[!] No se pudo descargar droplimiter.${C_RST}"
            fi
        fi
    else
        echo -e "${C_RED}[!] Dropbear no está activo. Instálalo primero.${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
    ;;
5)
    if [ "$is_running" -gt 0 ]; then
        echo -e "${C_YELLOW}[+] Reiniciando Dropbear...${C_RST}"
        systemctl restart dropbear
        echo -e "${C_GREEN}[✔] Servicio reiniciado.${C_RST}"
    else
        echo -e "${C_RED}[!] Dropbear no está activo.${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
    ;;
0) break ;;
*) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
esac
done
}
