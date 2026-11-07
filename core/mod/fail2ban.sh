#!/bin/bash
# VPS-MANAGER-MODULE: fail2ban
# Modulo cargado con "source" por menu.sh (usar_modulo). No ejecutar directamente.

# ==========================================
# SUBMENÚ: FAIL2BAN (PROTECCIÓN CONTRA FUERZA BRUTA)
# ==========================================
F2B_CONF="/etc/fail2ban/jail.d/vps-manager.local"

# Puertos en los que escucha un proceso (sshd, dropbear) -> "22,2222"
puertos_servicio() {
    ss -lntp 2>/dev/null | grep "\"$1\"" | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | paste -sd,
}

fail2ban_estado_texto() {
    if ! command -v fail2ban-client >/dev/null 2>&1; then echo -e "⚪ No instalado"
    elif systemctl is-active --quiet fail2ban 2>/dev/null; then echo -e "🟢 ACTIVO"
    else echo -e "🔴 INACTIVO"; fi
}

fail2ban_instalar() {
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🛡️ INSTALAR / CONFIGURAR FAIL2BAN    ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${C_YELLOW}[+] Instalando Fail2ban...${C_RST}"
        apt-get update -y >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null 2>&1
        if ! command -v fail2ban-client >/dev/null 2>&1; then
            echo -e "${C_RED}[!] No se pudo instalar Fail2ban.${C_RST}"
            read -p "Presione Enter para continuar..."; return
        fi
    fi

    local maxretry bantime
    echo -ne "${C_NEON_YELLOW}Intentos fallidos antes de bloquear (1-20) [5]: ${C_RST}"
    read maxretry; maxretry=${maxretry:-5}
    if [[ ! "$maxretry" =~ ^[0-9]+$ ]] || [ "$maxretry" -lt 1 ] || [ "$maxretry" -gt 20 ]; then
        echo -e "${C_RED}[!] Valor no válido.${C_RST}"; read -p "Presione Enter para continuar..."; return
    fi
    echo -ne "${C_NEON_YELLOW}Minutos de bloqueo (1-10080) [60]: ${C_RST}"
    read bantime; bantime=${bantime:-60}
    if [[ ! "$bantime" =~ ^[0-9]+$ ]] || [ "$bantime" -lt 1 ] || [ "$bantime" -gt 10080 ]; then
        echo -e "${C_RED}[!] Valor no válido.${C_RST}"; read -p "Presione Enter para continuar..."; return
    fi

    # Nunca bloquear: loopback (los túneles SSHWS/HCR/SSL llegan al SSH desde 127.0.0.1) ni tu IP actual
    local ignorar="127.0.0.1/8 ::1" mi_ip="${SSH_CLIENT%% *}"
    [[ "$mi_ip" =~ ^[0-9a-fA-F:.]+$ ]] && ignorar="$ignorar $mi_ip"

    local p_ssh p_db
    p_ssh=$(puertos_servicio sshd); p_ssh=${p_ssh:-22}
    p_db=$(puertos_servicio dropbear)

    mkdir -p /etc/fail2ban/jail.d
    cat > "$F2B_CONF" << EOF
# Generado por VPS-Manager
[DEFAULT]
ignoreip = $ignorar
bantime  = $((bantime * 60))
findtime = 600
maxretry = $maxretry

[sshd]
enabled = true
port    = $p_ssh
EOF
    # Dropbear solo si existe el log de autenticación (si no, Fail2ban no arrancaría)
    if [ -n "$p_db" ] && [ -f /var/log/auth.log ]; then
        cat >> "$F2B_CONF" << EOF

[dropbear]
enabled = true
port    = $p_db
EOF
    fi

    echo -e "${C_YELLOW}[+] Aplicando configuración...${C_RST}"
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    sleep 2
    if fail2ban-client status sshd >/dev/null 2>&1; then
        echo -e "${C_NEON_BLUE}════════════════════════════════════════════════${C_RST}"
        echo -e "  ${C_NEON_GREEN}Protege      :${C_RST} SSH (puerto $p_ssh)$([ -n "$p_db" ] && [ -f /var/log/auth.log ] && echo ", Dropbear ($p_db)")"
        echo -e "  ${C_NEON_GREEN}Intentos     :${C_RST} $maxretry en 10 min"
        echo -e "  ${C_NEON_GREEN}Bloqueo      :${C_RST} $bantime min"
        echo -e "  ${C_NEON_GREEN}IPs ignoradas:${C_RST} $ignorar"
        echo -e "${C_NEON_BLUE}════════════════════════════════════════════════${C_RST}"
        echo -e "${C_GREEN}[✔] Fail2ban activo.${C_RST}"
    else
        echo -e "${C_RED}[!] Fail2ban no pudo iniciar. Últimas líneas del registro:${C_RST}"
        journalctl -u fail2ban -n 15 --no-pager 2>/dev/null
    fi
    read -p "Presione Enter para continuar..."
}

fail2ban_ver() {
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🛡️ ESTADO E IPs BLOQUEADAS           ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "${C_YELLOW}[!] Fail2ban no está activo.${C_RST}"
        read -p "Presione Enter para continuar..."; return
    fi
    local jails j out
    jails=$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ' ' | tr ',' ' ')
    for j in $jails; do
        out=$(fail2ban-client status "$j" 2>/dev/null)
        echo -e "  ${C_NEON_YELLOW}Jail: $j${C_RST}"
        echo -e "  ${C_NEON_GREEN}Fallos actuales   :${C_RST} $(echo "$out" | awk -F: '/Currently failed/{gsub(/[ \t]/,"",$2); print $2}')"
        echo -e "  ${C_NEON_GREEN}Bloqueadas ahora  :${C_RST} $(echo "$out" | awk -F: '/Currently banned/{gsub(/[ \t]/,"",$2); print $2}')"
        echo -e "  ${C_NEON_GREEN}Total bloqueadas  :${C_RST} $(echo "$out" | awk -F: '/Total banned/{gsub(/[ \t]/,"",$2); print $2}')"
        echo -e "  ${C_NEON_GREEN}IPs bloqueadas    :${C_RST} $(echo "$out" | awk -F: '/Banned IP list/{print $2}' | sed 's/^[[:space:]]*//')"
        echo -e "${C_NEON_BLUE}────────────────────────────────────────────────${C_RST}"
    done
    read -p "Presione Enter para continuar..."
}

fail2ban_desbloquear() {
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🔓 DESBLOQUEAR IP                    ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo -e "${C_YELLOW}[!] Fail2ban no está activo.${C_RST}"
        read -p "Presione Enter para continuar..."; return
    fi
    local ip res
    echo -ne "${C_NEON_YELLOW}IP a desbloquear (o escriba 'todas'): ${C_RST}"
    read ip
    if [ "$ip" = "todas" ]; then
        fail2ban-client unban --all >/dev/null 2>&1 && echo -e "${C_GREEN}[✔] Todas las IPs fueron desbloqueadas.${C_RST}" \
            || echo -e "${C_RED}[!] No se pudo completar la operación.${C_RST}"
    elif [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
        res=$(fail2ban-client unban "$ip" 2>/dev/null | tail -1)
        if [ -n "$res" ] && [ "$res" != "0" ]; then echo -e "${C_GREEN}[✔] IP $ip desbloqueada.${C_RST}"
        else echo -e "${C_YELLOW}[!] La IP $ip no estaba bloqueada.${C_RST}"; fi
    else
        echo -e "${C_RED}[!] IP no válida.${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
}

fail2ban_desinstalar() {
    clear
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo -e "${C_YELLOW}[!] Fail2ban no está instalado.${C_RST}"
        read -p "Presione Enter para continuar..."; return
    fi
    read -p "¿Desinstalar Fail2ban? (s/n): " conf
    if [[ "$conf" != "s" && "$conf" != "S" ]]; then return; fi
    echo -e "${C_YELLOW}[+] Desinstalando Fail2ban...${C_RST}"
    systemctl disable --now fail2ban >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y fail2ban >/dev/null 2>&1
    rm -f "$F2B_CONF"
    echo -e "${C_GREEN}[✔] Fail2ban desinstalado.${C_RST}"
    read -p "Presione Enter para continuar..."
}

menu_fail2ban() {
    while true; do
        clear
        echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🛡️ FAIL2BAN (ANTI FUERZA BRUTA)      ${C_NEON_BLUE} ${C_RST}"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_NEON_GREEN}Estado:${C_RST} $(fail2ban_estado_texto)"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🛡️ Instalar / Configurar Fail2ban"
        echo -e "  ${C_NEON_YELLOW}2.${C_RST} 📋 Ver estado e IPs bloqueadas"
        echo -e "  ${C_NEON_YELLOW}3.${C_RST} 🔓 Desbloquear una IP"
        echo -e "  ${C_NEON_YELLOW}4.${C_RST} 🗑️ Desinstalar Fail2ban"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Anterior"
        echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
        read -p "Seleccione una opción: " f2b_opt
        case $f2b_opt in
            1) fail2ban_instalar ;;
            2) fail2ban_ver ;;
            3) fail2ban_desbloquear ;;
            4) fail2ban_desinstalar ;;
            0) break ;;
            *) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
        esac
    done
}
