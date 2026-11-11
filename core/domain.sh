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
# Módulo: Gestor de Dominio y SSL (Actualizado)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
DOM_FILE="/etc/vps-manager/dominio"
mkdir -p /etc/vps-manager

tramitar_ssl() {
    local dom=$1
    echo -e "${C_YELLOW}[+] ${T[Deteniendo servicios para liberar el puerto]:-Deteniendo servicios para liberar el puerto} 80...${C_NC}"
    systemctl stop nginx apache2 haproxy xray ws-python stunnel4 bhttp 2>/dev/null
    fuser -k 80/tcp 2>/dev/null
    
    echo -e "${C_YELLOW}[+] ${T[Solicitando Certificado SSL Let]:-Solicitando Certificado SSL Let}'${T[s Encrypt para]:-s Encrypt para}: $dom${C_NC}"
    apt install -y certbot >/dev/null 2>&1
    certbot certonly --standalone -d "$dom" --non-interactive --agree-tos -m "admin@$dom"
    
    if [ -d "/etc/letsencrypt/live/$dom" ]; then
        echo -e "${C_GREEN}[✔] ${T[Certificado generado. Distribuyendo a Xray y Stunnel]:-Certificado generado. Distribuyendo a Xray y Stunnel}...${C_NC}"
        mkdir -p /usr/local/etc/xray /etc/stunnel
        cp /etc/letsencrypt/live/$dom/fullchain.pem /usr/local/etc/xray/server.crt 2>/dev/null
        cp /etc/letsencrypt/live/$dom/privkey.pem /usr/local/etc/xray/server.key 2>/dev/null
        chown nobody:nogroup /usr/local/etc/xray/server.crt /usr/local/etc/xray/server.key 2>/dev/null
        cat /etc/letsencrypt/live/$dom/fullchain.pem /etc/letsencrypt/live/$dom/privkey.pem > /etc/stunnel/stunnel.pem 2>/dev/null
        echo -e "${C_GREEN}[✔] ${T[¡Dominio y Certificado 100% operativos]:-¡Dominio y Certificado 100% operativos}!${C_NC}"
    else
        echo -e "${C_RED}[!] ${T[Error: No se pudo generar el SSL]:-Error: No se pudo generar el SSL}.${C_NC}"
        echo -e "${C_YELLOW}${T[Verifica que el dominio apunte a tu IP en Cloudflare (Nube gris]:-Verifica que el dominio apunte a tu IP en Cloudflare (Nube gris}).${C_NC}"
    fi
    echo -e "${C_YELLOW}[+] ${T[Reiniciando servicios]:-Reiniciando servicios}...${C_NC}"
    systemctl start xray ws-python stunnel4 bhttp 2>/dev/null
}

clear
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "${C_GREEN}     ${T[GESTOR DE DOMINIO Y CERTIFICADO SSL]:-GESTOR DE DOMINIO Y CERTIFICADO SSL}        ${C_NC}"
echo -e "${C_CYAN}================================================${C_NC}"
echo -e "  ${C_YELLOW}1.${C_NC} 🌐 ${T[Configurar Nuevo Subdominio y Certificar]:-Configurar Nuevo Subdominio y Certificar}"
echo -e "  ${C_YELLOW}2.${C_NC} 🔄 ${T[Re-certificar Subdominio Actual (Solución Errores]:-Re-certificar Subdominio Actual (Solución Errores})"
echo -e "  ${C_RED}0.${C_NC} 🚪 ${T[Salir]:-Salir}"
echo -e "${C_CYAN}================================================${C_NC}"
read -p "${T[Seleccione una opción]:-Seleccione una opción}: " optdom

case $optdom in
    1)
        read -p "${T[Ingresa tu nuevo Subdominio]:-Ingresa tu nuevo Subdominio}: " ndom
        if [ -n "$ndom" ]; then
            echo "$ndom" > $DOM_FILE
            tramitar_ssl "$ndom"
        fi
        ;;
    2)
        if [ -f "$DOM_FILE" ]; then
            adom=$(cat $DOM_FILE)
            echo -e "${C_YELLOW}[+] ${T[Re-certificando el dominio guardado]:-Re-certificando el dominio guardado}: $adom${C_NC}"
            tramitar_ssl "$adom"
        else
            echo -e "${C_RED}[!] ${T[No hay dominio guardado en el VPS. Usa la opción]:-No hay dominio guardado en el VPS. Usa la opción} 1.${C_NC}"
        fi
        ;;
esac
read -p "${T[Presione Enter para regresar]:-Presione Enter para regresar}..."
