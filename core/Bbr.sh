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
# Módulo: Optimizador y Activador TCP BBR
# ==========================================

clear
echo -e "\033[1;36m[+] ${T[Verificando e instalando TCP BBR]:-Verificando e instalando TCP BBR}...\033[0m"

# Comprobar si ya está activo
if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf && grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo -e "\n\033[1;32m[✔] ${T[¡TCP BBR ya se encuentra activo en este VPS]:-¡TCP BBR ya se encuentra activo en este VPS}!\033[0m"
    sleep 2
    return 2>/dev/null || exit 0
fi

# Aplicar configuraciones al kernel
cat << 'EOF' >> /etc/sysctl.conf

# --- Optimización TCP BBR Golbert VPS ---
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl -p > /dev/null 2>&1

if grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo -e "\n\033[1;32m[✔] ${T[¡TCP BBR activado y configurado con éxito]:-¡TCP BBR activado y configurado con éxito}!\033[0m"
else
    echo -e "\n\033[1;31m[!] ${T[No se pudo aplicar BBR automáticamente en este kernel]:-No se pudo aplicar BBR automáticamente en este kernel}.\033[0m"
fi
sleep 2
