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
# Módulo: Actualizador del Panel Principal
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}        ${T[ACTUALIZADOR DE PANEL VPS MANAGER]:-ACTUALIZADOR DE PANEL VPS MANAGER}       ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"

echo -e "${C_YELLOW}[+] ${T[Buscando actualizaciones en GitHub]:-Buscando actualizaciones en GitHub}...${C_NC}"
wget -qO /tmp/menu.sh "https://raw.githubusercontent.com/PhoenixxZ2023/VPS-MANAGER/main/update/menu"

if [ -s /tmp/menu.sh ]; then
    echo -e "${C_YELLOW}[+] ${T[Descarga Exitosa. Aplicando actualización]:-Descarga Exitosa. Aplicando actualización}...${C_NC}"
    mv /tmp/menu.sh /usr/local/bin/menu
    chmod +x /usr/local/bin/menu
    
    echo -e "${C_GREEN}[✔] ${T[¡Panel actualizado con éxito! Reiniciando]:-¡Panel actualizado con éxito! Reiniciando}...${C_NC}"
    sleep 2
    exec menu
else
    echo -e "${C_RED}[!] ${T[Error al descargar la actualización]:-Error al descargar la actualización}.${C_NC}"
    echo -e "${C_YELLOW}${T[Verifica tu conexión a internet o asegúrate de que el archivo menu existe en el repositorio]:-Verifica tu conexión a internet o asegúrate de que el archivo menu existe en el repositorio}.${C_NC}"
    sleep 3
fi
