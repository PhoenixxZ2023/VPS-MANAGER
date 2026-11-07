#!/bin/bash
# VPS-MANAGER-MODULE: torrents
# Modulo cargado con "source" por menu.sh (usar_modulo). No ejecutar directamente.

# ==========================================
# SUBMENÚ: BLOQUEO DE TORRENTS (iptables)
# ==========================================
TORRENT_BIN="/usr/local/bin/vps-torrent-block"
TORRENT_SVC="/etc/systemd/system/vps-torrent-block.service"

torrent_activo() { command -v iptables >/dev/null 2>&1 && iptables -C OUTPUT -j VPS_BLOCK_TORRENT 2>/dev/null; }

torrent_activar() {
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🚫 ACTIVAR BLOQUEO DE TORRENTS       ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${C_YELLOW}[+] Instalando iptables...${C_RST}"
        apt-get update -y >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables >/dev/null 2>&1
        if ! command -v iptables >/dev/null 2>&1; then
            echo -e "${C_RED}[!] No se pudo instalar iptables.${C_RST}"
            read -p "Presione Enter para continuar..."; return
        fi
    fi

    # Script que aplica/quita las reglas (lo usa también el servicio al arrancar el VPS)
    cat > "$TORRENT_BIN" << 'EOF'
#!/bin/bash
# VPS-Manager: bloqueo de torrents por inspección de contenido (iptables -m string)
CHAIN=VPS_BLOCK_TORRENT
STRINGS=("BitTorrent protocol" "peer_id=" ".torrent" "announce.php?passkey=" "info_hash" "get_peers" "announce_peer" "find_node" "BT-SEARCH")

quitar() {
    local IPT="$1" h
    command -v "$IPT" >/dev/null 2>&1 || return 0
    for h in OUTPUT FORWARD; do
        while "$IPT" -C "$h" -j "$CHAIN" 2>/dev/null; do "$IPT" -D "$h" -j "$CHAIN"; done
    done
    "$IPT" -F "$CHAIN" 2>/dev/null
    "$IPT" -X "$CHAIN" 2>/dev/null
    return 0
}

aplicar() {
    local IPT="$1" s h
    command -v "$IPT" >/dev/null 2>&1 || return 0
    "$IPT" -N "$CHAIN" 2>/dev/null
    "$IPT" -F "$CHAIN" || return 1
    "$IPT" -A "$CHAIN" -o lo -j RETURN || return 1          # el tráfico local no se inspecciona
    for s in "${STRINGS[@]}"; do
        "$IPT" -A "$CHAIN" -m string --algo bm --string "$s" -j DROP || return 1
    done
    for h in OUTPUT FORWARD; do
        "$IPT" -C "$h" -j "$CHAIN" 2>/dev/null || "$IPT" -I "$h" 1 -j "$CHAIN" || return 1
    done
}

case "$1" in
    on)  modprobe xt_string 2>/dev/null
         aplicar iptables || { quitar iptables; exit 1; }
         aplicar ip6tables || quitar ip6tables ;;      # IPv6 es opcional
    off) quitar iptables; quitar ip6tables ;;
    *)   echo "Uso: $0 {on|off}"; exit 1 ;;
esac
EOF
    chmod 755 "$TORRENT_BIN"

    cat > "$TORRENT_SVC" << EOF
[Unit]
Description=VPS-Manager bloqueo de torrents
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$TORRENT_BIN on
ExecStop=$TORRENT_BIN off

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    echo -e "${C_YELLOW}[+] Aplicando reglas...${C_RST}"
    systemctl enable vps-torrent-block.service >/dev/null 2>&1
    systemctl restart vps-torrent-block.service >/dev/null 2>&1

    if torrent_activo; then
        echo -e "${C_GREEN}[✔] Bloqueo de torrents activado (se mantiene tras reiniciar).${C_RST}"
    else
        echo -e "${C_RED}[!] No se pudieron aplicar las reglas.${C_RST}"
        echo -e "    Este VPS probablemente no soporta el módulo ${C_NEON_YELLOW}string${C_RST} de iptables"
        echo -e "    (es común en virtualización OpenVZ/LXC)."
        systemctl disable --now vps-torrent-block.service >/dev/null 2>&1
        "$TORRENT_BIN" off 2>/dev/null
        rm -f "$TORRENT_SVC" "$TORRENT_BIN"; systemctl daemon-reload >/dev/null 2>&1
    fi
    read -p "Presione Enter para continuar..."
}

torrent_desactivar() {
    clear
    if ! torrent_activo && [ ! -f "$TORRENT_SVC" ]; then
        echo -e "${C_YELLOW}[!] El bloqueo de torrents no está activo.${C_RST}"
        read -p "Presione Enter para continuar..."; return
    fi
    echo -e "${C_YELLOW}[+] Desactivando bloqueo de torrents...${C_RST}"
    systemctl disable --now vps-torrent-block.service >/dev/null 2>&1
    [ -x "$TORRENT_BIN" ] && "$TORRENT_BIN" off
    rm -f "$TORRENT_SVC" "$TORRENT_BIN"
    systemctl daemon-reload >/dev/null 2>&1
    echo -e "${C_GREEN}[✔] Bloqueo de torrents desactivado.${C_RST}"
    read -p "Presione Enter para continuar..."
}

menu_torrents() {
    while true; do
        clear
        local estado="🔴 DESACTIVADO" bloq=""
        if torrent_activo; then
            estado="🟢 ACTIVO"
            bloq=$(iptables -nvxL VPS_BLOCK_TORRENT 2>/dev/null | awk '$3=="DROP"{s+=$1} END{print s+0}')
        fi
        echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🚫 BLOQUEO DE TORRENTS               ${C_NEON_BLUE} ${C_RST}"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_NEON_GREEN}Estado             :${C_RST} $estado"
        [ -n "$bloq" ] && echo -e "  ${C_NEON_GREEN}Paquetes bloqueados:${C_RST} $bloq"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚫 Activar bloqueo de torrents"
        echo -e "  ${C_NEON_YELLOW}2.${C_RST} ✅ Desactivar bloqueo de torrents"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Anterior"
        echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
        read -p "Seleccione una opción: " tor_opt
        case $tor_opt in
            1) torrent_activar ;;
            2) torrent_desactivar ;;
            0) break ;;
            *) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
        esac
    done
}
