#!/bin/bash
# VPS-MANAGER-MODULE: bhttp
# Modulo cargado con "source" por menu.sh (usar_modulo). No ejecutar directamente.

# ==========================================
# SUBMENÚ: BHTTP v2.2 (Instalar / Puerto / Reiniciar / Detener / Desinstalar)
# ==========================================
BHTTP2_SVC="superflash-bhttp"
BHTTP2_CONF1="/etc/superflash-bhttp.conf"
BHTTP2_CONF2="/etc/superflash-bhttp/config"
BHTTP2_BIN="/usr/local/bin/superflash-bhttp-server"

bhttp2_instalado() {
    [ -f "/etc/systemd/system/${BHTTP2_SVC}.service" ] || [ -x "$BHTTP2_BIN" ]
}

bhttp2_puerto() {
    local p
    p=$(grep -E "^BHTTP_PORT=" "$BHTTP2_CONF2" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"')
    [ -z "$p" ] && p=$(grep -E "^BHTTP_PORT=" "$BHTTP2_CONF1" 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"')
    echo "$p"
}

bhttp2_estado_texto() {
    if ! bhttp2_instalado; then echo -e "⚪ No instalado"
    elif systemctl is-active --quiet "$BHTTP2_SVC" 2>/dev/null; then echo -e "🟢 ACTIVO"
    else echo -e "🔴 DETENIDO"; fi
}

bhttp2_instalar() {
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}      🌐 INSTALAR BHTTP (v2.0)   ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
    
    echo -e "${C_YELLOW}[+] Descargando e instalando motor BHTTP v2.0...${C_RST}"
    wget -qO /tmp/bhttpv2.sh https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/master/core/bhttpv2.sh
    chmod +x /tmp/bhttpv2.sh
    
    bash /tmp/bhttpv2.sh install
    
    echo -e "${C_YELLOW}[+] Configuración de puerto...${C_RST}"
    local current_port=$(grep -E "^BHTTP_PORT=" /etc/superflash-bhttp.conf 2>/dev/null | cut -d'=' -f2 | tr -d '"')
    
    if [ -z "$current_port" ]; then
        echo -ne "${C_NEON_YELLOW}Ingrese el puerto para BHTTP v2.0 (1-65535): ${C_RST}"
        read bhttp_port
        if [[ ! "$bhttp_port" =~ ^[0-9]+$ ]] || [ "$bhttp_port" -lt 1 ] || [ "$bhttp_port" -gt 65535 ]; then
            echo -e "${C_RED}[!] Puerto no válido. Se cancela la configuración de puerto.${C_RST}"
        else
            mkdir -p /etc/superflash-bhttp
            cat > /etc/superflash-bhttp.conf << EOF
BHTTP_PORT=$bhttp_port
BACKEND_PORT=22
SESSION_TTL=180
MAX_SESSIONS=2048
EOF
            cat > /etc/superflash-bhttp/config << EOF
BHTTP_PORT=$bhttp_port
BACKEND_PORT=22
SESSION_TTL=180
MAX_SESSIONS=2048
PROFILE=performance
UFW_RULE_ADDED=0
UFW_RULE_PORT=
FIREWALLD_RULE_ADDED=0
FIREWALLD_RULE_PORT=
EXTRA_PORTS=
EXTRA_UFW_PORTS=
EXTRA_FIREWALLD_PORTS=
EOF
            chmod 600 /etc/superflash-bhttp.conf /etc/superflash-bhttp/config
            
            cat > /etc/systemd/system/superflash-bhttp.service << EOF
[Unit]
Description=SuperFlash BHTTP NEW GOLDEN
After=network-online.target ssh.service sshd.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/superflash-bhttp/config
ExecStart=/usr/local/bin/superflash-bhttp-server --listen 0.0.0.0 --port \${BHTTP_PORT} --backend-host 127.0.0.1 --backend-port \${BACKEND_PORT} --session-ttl \${SESSION_TTL} --max-sessions \${MAX_SESSIONS} --request-timeout 30 --read-wait-ms 2 --sequence-wait 6 --max-requests-per-conn 2048
Restart=always
RestartSec=1
TimeoutStopSec=15
KillSignal=SIGTERM
LimitNOFILE=524288
LimitNPROC=131072
TasksMax=infinity
OOMScoreAdjust=-300

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable superflash-bhttp.service >/dev/null 2>&1
            systemctl restart superflash-bhttp.service
            
            if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
                ufw allow "$bhttp_port/tcp" >/dev/null 2>&1
            fi
            
            echo "$bhttp_port" > /etc/vps-manager/bhttp_port
            echo -e "${C_GREEN}[✔] BHTTP v2.0 instalado y activo en el puerto $bhttp_port.${C_RST}"
        fi
    else
        echo -e "${C_GREEN}[✔] BHTTP v2.0 ya está instalado y configurado en el puerto $current_port.${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
}

bhttp2_requiere_instalado() {
    if ! bhttp2_instalado; then
        echo -e "${C_RED}[!] BHTTP v2.0 no está instalado. Use la opción 1 primero.${C_RST}"
        read -p "Presione Enter para continuar..."
        return 1
    fi
    return 0
}

bhttp2_cambiar_puerto() {
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🔧 CAMBIAR PUERTO BHTTP v2.0         ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
    bhttp2_requiere_instalado || return

    local old_port new_port
    old_port=$(bhttp2_puerto)
    echo -e "  Puerto actual: ${C_NEON_YELLOW}${old_port:-N/D}${C_RST}"
    echo -ne "${C_NEON_YELLOW}Nuevo puerto (1-65535, 0 para cancelar): ${C_RST}"
    read new_port

    [ "$new_port" = "0" ] && return
    if [[ ! "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "${C_RED}[!] Puerto no válido.${C_RST}"; read -p "Presione Enter para continuar..."; return
    fi
    if [ "$new_port" = "$old_port" ]; then
        echo -e "${C_YELLOW}[!] Ya está usando ese puerto.${C_RST}"; read -p "Presione Enter para continuar..."; return
    fi
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${new_port}$"; then
        echo -e "${C_RED}[!] El puerto $new_port ya está en uso por otro servicio.${C_RST}"
        read -p "Presione Enter para continuar..."; return
    fi

    echo -e "${C_YELLOW}[+] Aplicando nuevo puerto...${C_RST}"
    local f
    for f in "$BHTTP2_CONF1" "$BHTTP2_CONF2"; do
        if [ -f "$f" ]; then
            if grep -q "^BHTTP_PORT=" "$f"; then
                sed -i "s/^BHTTP_PORT=.*/BHTTP_PORT=${new_port}/" "$f"
            else
                echo "BHTTP_PORT=${new_port}" >> "$f"
            fi
        fi
    done
    echo "$new_port" > /etc/vps-manager/bhttp_port

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
        [ -n "$old_port" ] && ufw delete allow "${old_port}/tcp" >/dev/null 2>&1
        ufw allow "${new_port}/tcp" >/dev/null 2>&1
    fi

    systemctl restart "$BHTTP2_SVC" >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet "$BHTTP2_SVC" 2>/dev/null; then
        echo -e "${C_GREEN}[✔] Puerto cambiado: ${old_port:-?} → ${new_port}. Servicio activo.${C_RST}"
    else
        echo -e "${C_RED}[!] El servicio no arrancó con el nuevo puerto. Revise: journalctl -u ${BHTTP2_SVC} -n 20${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
}

bhttp2_reiniciar() {
    clear
    bhttp2_requiere_instalado || return
    echo -e "${C_YELLOW}[+] Reiniciando BHTTP v2.0...${C_RST}"
    systemctl restart "$BHTTP2_SVC" >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet "$BHTTP2_SVC" 2>/dev/null; then
        echo -e "${C_GREEN}[✔] BHTTP v2.0 reiniciado (puerto $(bhttp2_puerto)).${C_RST}"
    else
        echo -e "${C_RED}[!] No se pudo iniciar. Revise: journalctl -u ${BHTTP2_SVC} -n 20${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
}

bhttp2_detener() {
    clear
    bhttp2_requiere_instalado || return
    echo -e "${C_YELLOW}[+] Deteniendo BHTTP v2.0...${C_RST}"
    systemctl stop "$BHTTP2_SVC" >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet "$BHTTP2_SVC" 2>/dev/null; then
        echo -e "${C_RED}[!] No se pudo detener el servicio.${C_RST}"
    else
        echo -e "${C_GREEN}[✔] BHTTP v2.0 detenido.${C_RST}"
        echo -e "${C_YELLOW}    (Para volver a activarlo use la opción Reiniciar.)${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
}

bhttp2_desinstalar() {
    clear
    bhttp2_requiere_instalado || return
    local port; port=$(bhttp2_puerto)
    echo -e "${C_RED}⚠️  Se eliminará BHTTP v2.0 (servicio, binario y configuración).${C_RST}"
    read -p "¿Desinstalar BHTTP v2.0? (s/n): " conf
    [[ "$conf" == "s" || "$conf" == "S" ]] || return

    echo -e "${C_YELLOW}[+] Desinstalando BHTTP v2.0...${C_RST}"
    systemctl stop "$BHTTP2_SVC" >/dev/null 2>&1
    systemctl disable "$BHTTP2_SVC" >/dev/null 2>&1
    rm -f "/etc/systemd/system/${BHTTP2_SVC}.service"
    systemctl daemon-reload
    systemctl reset-failed "$BHTTP2_SVC" >/dev/null 2>&1

    rm -f "$BHTTP2_BIN" "$BHTTP2_CONF1" /tmp/bhttpv2.sh
    rm -rf /etc/superflash-bhttp

    if [ -n "$port" ]; then
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
            ufw delete allow "${port}/tcp" >/dev/null 2>&1
        fi
        [ "$(cat /etc/vps-manager/bhttp_port 2>/dev/null)" = "$port" ] && rm -f /etc/vps-manager/bhttp_port
    fi
    echo -e "${C_GREEN}[✔] BHTTP v2.0 desinstalado.${C_RST}"
    read -p "Presione Enter para continuar..."
}

menu_bhttp_v2() {
    while true; do
        clear
        local port; port=$(bhttp2_puerto)
        echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🌐 BHTTP v2.0 - GESTIÓN              ${C_NEON_BLUE} ${C_RST}"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  Estado : $(bhttp2_estado_texto)"
        echo -e "  Puerto : ${C_NEON_YELLOW}${port:-N/D}${C_RST}"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar BHTTP v2.0"
        echo -e "  ${C_NEON_YELLOW}2.${C_RST} 🔧 Cambiar puerto"
        echo -e "  ${C_NEON_YELLOW}3.${C_RST} 🔄 Reiniciar"
        echo -e "  ${C_NEON_YELLOW}4.${C_RST} ⏹️ Detener"
        echo -e "  ${C_NEON_YELLOW}5.${C_RST} 🗑️ Desinstalar"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Anterior"
        echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
        read -p "Seleccione una opción: " b2_opt
        case $b2_opt in
            1) bhttp2_instalar ;;
            2) bhttp2_cambiar_puerto ;;
            3) bhttp2_reiniciar ;;
            4) bhttp2_detener ;;
            5) bhttp2_desinstalar ;;
            0) break ;;
            *) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
        esac
    done
}


# ==========================================
# SUBMENÚ: BHTTP PROXY (v1.0 Y v2.0)
# ==========================================
menu_bhttp() {
    while true; do
        clear
        echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🌐 INSTALAR BHTTP PROXY              ${C_NEON_BLUE} ${C_RST}"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar BHTTP  (v1.0)"
        echo -e "  ${C_NEON_YELLOW}2.${C_RST} 🚀 Instalar BHTTP  (v2.0 Nuevo)"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Anterior"
        echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
        read -p "Seleccione una opción: " bhttp_opt
        case $bhttp_opt in
            1)
                clear
                echo -e "${C_YELLOW}[+] Descargando e instalando BHTTP Proxy (Normal)...${C_RST}"
                wget -qO /tmp/bhttp.sh ${REPO_RAW}/core/bhttp.sh
                chmod +x /tmp/bhttp.sh
                bash /tmp/bhttp.sh
                read -p "Presione Enter para continuar..."
                ;;
            2) menu_bhttp_v2 ;;
            0) break ;;
            *) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
        esac
    done
}
