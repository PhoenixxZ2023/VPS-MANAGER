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
# Módulo Independiente: TROJAN (XRAY)
# Puertos: 80 (NTLS) y 443 (TLS)
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
XRAY_DIR="/usr/local/etc/xray"
CONF_FILE="$XRAY_DIR/config.json"
DOM_FILE="/etc/vps-manager/dominio"

instalar_xray_trojan() {
    if [ -f /etc/vps-manager/engine_haproxy ]; then
        echo -e "${C_RED}[!] ${T[El motor unificado HAProxy está activo: Trojan ya viene incluido en él]:-El motor unificado HAProxy está activo: Trojan ya viene incluido en él}.${C_NC}"
        sleep 3
        return
    fi
    clear
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e "${C_GREEN}   ${T[INSTALACIÓN DE XRAY (TROJAN) Y CERTIFICADO]:-INSTALACIÓN DE XRAY (TROJAN) Y CERTIFICADO}   ${C_NC}"
    echo -e "${C_CYAN}================================================${C_NC}"
    
    read -p "${T[Ingresa tu dominio (Ej: centrix.golbertvps.online]:-Ingresa tu dominio (Ej: centrix.golbertvps.online}): " DOMINIO
    if [ -z "$DOMINIO" ]; then echo -e "${C_RED}[!] ${T[Dominio inválido]:-Dominio inválido}.${C_NC}"; sleep 2; return; fi
    echo "$DOMINIO" > $DOM_FILE

    echo -e "${C_YELLOW}[+] ${T[Instalando dependencias]:-Instalando dependencias}...${C_NC}"
    apt update -y >/dev/null 2>&1
    apt install -y certbot jq uuid-runtime curl iptables ufw >/dev/null 2>&1

    echo -e "${C_YELLOW}[+] ${T[Liberando puertos 80 y]:-Liberando puertos 80 y} 443...${C_NC}"
    systemctl stop nginx apache2 haproxy xray 2>/dev/null
    fuser -k 80/tcp 2>/dev/null
    fuser -k 443/tcp 2>/dev/null

    echo -e "${C_YELLOW}[+] ${T[Generando Certificado SSL]:-Generando Certificado SSL}...${C_NC}"
    certbot certonly --standalone -d "$DOMINIO" --non-interactive --agree-tos -m "admin@$DOMINIO"
    
    if [ ! -f "/etc/letsencrypt/live/$DOMINIO/fullchain.pem" ]; then
        echo -e "${C_RED}[!] ${T[Error SSL. Revisa que tu IP apunte al dominio en Cloudflare]:-Error SSL. Revisa que tu IP apunte al dominio en Cloudflare}.${C_NC}"
        read -p "${T[Presiona Enter]:-Presiona Enter}..."
        exit 1
    fi

    echo -e "${C_YELLOW}[+] ${T[Instalando núcleo Xray]:-Instalando núcleo Xray}...${C_NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    
    # IMPORTANTE: ¡Abrir el Firewall!
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT
    iptables-save > /etc/iptables.up.rules 2>/dev/null
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1

    mkdir -p $XRAY_DIR
    cp /etc/letsencrypt/live/$DOMINIO/fullchain.pem $XRAY_DIR/server.crt
    cp /etc/letsencrypt/live/$DOMINIO/privkey.pem $XRAY_DIR/server.key

    # Configuración Avanzada Xray para Trojan
    cat << EOF > $CONF_FILE
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 443, "protocol": "trojan",
      "settings": { "clients": [],
        "fallbacks": [
          {"path": "/trojan", "dest": 10001},
          {"path": "/trojan-grpc", "dest": 10002},
          {"path": "/xhttp", "dest": 10003}
        ]
      },
      "streamSettings": { "network": "tcp", "security": "tls", "tlsSettings": { "alpn": ["h2", "http/1.1"], "certificates": [ { "certificateFile": "$XRAY_DIR/server.crt", "keyFile": "$XRAY_DIR/server.key" } ] } }
    },
    {
      "port": 80, "protocol": "trojan",
      "settings": { "clients": [],
        "fallbacks": [
          {"path": "/trojan", "dest": 10001},
          {"path": "/xhttp", "dest": 10003}
        ]
      },
      "streamSettings": { "network": "tcp", "security": "none" }
    },
    { "port": 10001, "listen": "127.0.0.1", "protocol": "trojan", "settings": {"clients": []}, "streamSettings": {"network": "ws", "security": "none", "wsSettings": {"path": "/trojan"}} },
    { "port": 10002, "listen": "127.0.0.1", "protocol": "trojan", "settings": {"clients": []}, "streamSettings": {"network": "grpc", "security": "none", "grpcSettings": {"serviceName": "trojan-grpc"}} },
    { "port": 10003, "listen": "127.0.0.1", "protocol": "trojan", "settings": {"clients": []}, "streamSettings": {"network": "xhttp", "security": "none", "xhttpSettings": {"path": "/xhttp", "mode": "auto"}} }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF
    systemctl restart xray
    echo -e "${C_GREEN}[✔] ${T[¡Instalación TROJAN completada]:-¡Instalación TROJAN completada}!${C_NC}"; sleep 2
}

generar_link() {
    local alias=$1 dom=$2 uuid=$3 port=$4 net=$5 tls=$6 path=$7
    if [ "$net" == "grpc" ]; then
        echo "trojan://${uuid}@${dom}:${port}?type=${net}&security=${tls}&serviceName=${path}&sni=${dom}#${alias}"
    else
        echo "trojan://${uuid}@${dom}:${port}?type=${net}&security=${tls}&path=${path}&sni=${dom}#${alias}"
    fi
}

# ── Modo motor unificado (HAProxy): las cuentas Trojan viven en los inbounds trojan-ws y trojan-grpc ──
trojan_motor_aplicar() {
    local filtro="$1"; shift
    local nuevo="${CONF_FILE%.json}.motor.new.json" respaldo="${CONF_FILE}.bak-trojan" xb
    xb=$(command -v xray || echo /usr/local/bin/xray)
    jq "$@" "$filtro" "$CONF_FILE" > "$nuevo" 2>/dev/null || { rm -f "$nuevo"; return 1; }
    "$xb" run -test -format json -config "$nuevo" >/dev/null 2>&1 || { rm -f "$nuevo"; return 2; }
    cp -f "$CONF_FILE" "$respaldo"; mv -f "$nuevo" "$CONF_FILE"; chmod 644 "$CONF_FILE"
    systemctl restart xray; sleep 1
    if ! systemctl is-active --quiet xray; then cp -f "$respaldo" "$CONF_FILE"; systemctl restart xray; return 3; fi
    return 0
}

menu_trojan_motor() {
    local opc user dias UUID EXP_DATE DOM rc LINK_TLS LINK_NTLS LINK_GRPC
    while true; do
        clear
        echo -e "${C_YELLOW}        ${T[GESTION DE TROJAN (XRAY]:-GESTION DE TROJAN (XRAY})        ${C_NC}"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        echo -e "${C_CYAN}[1] >${C_NC} ${T[Crear Cuenta Trojan]:-Crear Cuenta Trojan}"
        echo -e "${C_CYAN}[2] >${C_NC} ${T[Eliminar Cuenta Trojan]:-Eliminar Cuenta Trojan}"
        echo -e "${C_CYAN}[3] >${C_NC} ${T[Ver cuentas activas]:-Ver cuentas activas}"
        echo -e "${C_CYAN}[x] >${C_NC} ${T[Salir del Gestor]:-Salir del Gestor}"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        read -p "${T[Digite su opción]:-Digite su opción}: " opc
        case $opc in
            1)
                clear
                echo -e "${C_YELLOW}      ${T[CREAR USUARIO XRAY TROJAN]:-CREAR USUARIO XRAY TROJAN}      ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "${T[Nombre de usuario]:-Nombre de usuario}: " user
                [ -z "$user" ] && continue
                if ! [[ "$user" =~ ^[A-Za-z0-9._-]{1,40}$ ]]; then
                    echo -e "${C_RED}[!] ${T[Usuario inválido: usa 1 a 40 caracteres (letras, números, punto, guion]:-Usuario inválido: usa 1 a 40 caracteres (letras, números, punto, guion}).${C_NC}"; sleep 3; continue
                fi
                if jq -e --arg u "$user" '[.inbounds[] | select(.tag=="trojan-ws") | .settings.clients[]? | select(.email==$u)] | length > 0' "$CONF_FILE" >/dev/null 2>&1; then
                    echo -e "${C_RED}[!] ${T[El usuario ya existe]:-El usuario ya existe}.${C_NC}"; sleep 3; continue
                fi
                read -p "${T[Duración (días]:-Duración (días}): " dias
                if ! [[ "$dias" =~ ^[0-9]+$ ]] || [ "$dias" -lt 1 ] || [ "$dias" -gt 3650 ]; then
                    echo -e "${C_RED}[!] ${T[Los días deben ser un número entre 1 y]:-Los días deben ser un número entre 1 y} 3650.${C_NC}"; sleep 3; continue
                fi
                UUID=$(cat /proc/sys/kernel/random/uuid)
                EXP_DATE=$(date -d "+$dias days" +"%Y-%m-%d")
                DOM=$(tr -d ' \r\n' < "$DOM_FILE")
                trojan_motor_aplicar '(.inbounds[] | select(.tag=="trojan-ws" or .tag=="trojan-grpc") | .settings.clients) += [{"password": $p, "email": $u}]' --arg u "$user" --arg p "$UUID"; rc=$?
                if [ "$rc" -ne 0 ]; then
                    echo -e "${C_RED}[!] ${T[No se pudo crear la cuenta: Xray rechazó el cambio y se mantuvo la configuración anterior]:-No se pudo crear la cuenta: Xray rechazó el cambio y se mantuvo la configuración anterior}.${C_NC}"; sleep 4; continue
                fi
                LINK_TLS=$(generar_link "$user" "$DOM" "$UUID" "443" "ws" "tls" "/trojan")
                LINK_NTLS=$(generar_link "$user" "$DOM" "$UUID" "80" "ws" "" "/trojan")
                LINK_GRPC=$(generar_link "$user-GRPC" "$DOM" "$UUID" "443" "grpc" "tls" "trojan-grpc")
                clear
                echo -e "${C_YELLOW}    ${T[CUENTA TROJAN CREADA EXITOSAMENTE]:-CUENTA TROJAN CREADA EXITOSAMENTE}    ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                echo -e " Alias       : ${C_CYAN}$user${C_NC}"
                echo -e " ${T[Dominio]:-Dominio}     : ${C_CYAN}$DOM${C_NC}"
                echo -e " ${T[Password]:-Password}    : ${C_CYAN}$UUID${C_NC}"
                echo -e " ${T[Red]:-Red}         : ${C_CYAN}WS / GRPC${C_NC}"
                echo -e " ${T[Expira]:-Expira}      : ${C_CYAN}$EXP_DATE${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                echo -e "\n ${C_GREEN}LINK TLS (443) :${C_NC}\n$LINK_TLS\n"
                echo -e " ${C_GREEN}LINK NTLS (80) :${C_NC}\n$LINK_NTLS\n"
                echo -e " ${C_GREEN}LINK GRPC      :${C_NC}\n$LINK_GRPC\n"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "${T[Presiona ENTER para volver al menú]:-Presiona ENTER para volver al menú} " foo
                ;;
            2)
                read -p "${T[Usuario a eliminar]:-Usuario a eliminar}: " user
                [ -z "$user" ] && continue
                trojan_motor_aplicar '(.inbounds[] | select(.tag=="trojan-ws" or .tag=="trojan-grpc") | .settings.clients) |= map(select(.email != $u))' --arg u "$user"; rc=$?
                if [ "$rc" -eq 0 ]; then echo -e "${C_GREEN}[✔] ${T[Eliminado]:-Eliminado}.${C_NC}"; else echo -e "${C_RED}[!] ${T[No se pudo eliminar: se mantuvo la configuración anterior]:-No se pudo eliminar: se mantuvo la configuración anterior}.${C_NC}"; fi
                sleep 2
                ;;
            3)
                clear
                echo -e "${C_YELLOW}        ${T[CUENTAS TROJAN ACTIVAS]:-CUENTAS TROJAN ACTIVAS}        ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                jq -r '[.inbounds[] | select(.tag=="trojan-ws") | .settings.clients[]?.email] | .[]' "$CONF_FILE" 2>/dev/null
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "${T[Presiona ENTER para volver al menú]:-Presiona ENTER para volver al menú} " foo
                ;;
            x|X|"") break ;;
        esac
    done
}

menu_trojan() {
    if [ -f /etc/vps-manager/engine_haproxy ]; then menu_trojan_motor; return; fi
    if [ ! -f "$CONF_FILE" ]; then instalar_xray_trojan; fi
    
    while true; do
        clear
        echo -e "${C_YELLOW}        ${T[GESTION DE TROJAN (XRAY]:-GESTION DE TROJAN (XRAY})        ${C_NC}"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        echo -e "${C_CYAN}[1] >${C_NC} ${T[Crear Cuenta Trojan]:-Crear Cuenta Trojan}"
        echo -e "${C_CYAN}[2] >${C_NC} ${T[Eliminar Cuenta Trojan]:-Eliminar Cuenta Trojan}"
        echo -e "${C_CYAN}[x] >${C_NC} ${T[Salir del Gestor]:-Salir del Gestor}"
        echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
        read -p "${T[Digite su opción]:-Digite su opción}: " opc

        case $opc in
            1)
                clear
                echo -e "${C_YELLOW}      ${T[CREAR USUARIO XRAY TROJAN]:-CREAR USUARIO XRAY TROJAN}      ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "${T[Nombre de usuario]:-Nombre de usuario}: " user
                [ -z "$user" ] && continue
                read -p "${T[Duración (días]:-Duración (días}): " dias
                
                UUID=$(uuidgen)
                EXP_DATE=$(date -d "+$dias days" +"%Y-%m-%d")
                DOM=$(cat $DOM_FILE)

                # Inyectar usuario en todos los nodos Trojan (Note que usa "password" en vez de "id")
                jq ".inbounds[0].settings.clients += [{\"password\": \"$UUID\", \"email\": \"$user\"}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[1].settings.clients += [{\"password\": \"$UUID\", \"email\": \"$user\"}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[2].settings.clients += [{\"password\": \"$UUID\", \"email\": \"$user\"}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[3].settings.clients += [{\"password\": \"$UUID\", \"email\": \"$user\"}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[4].settings.clients += [{\"password\": \"$UUID\", \"email\": \"$user\"}]" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                systemctl restart xray

                LINK_TLS=$(generar_link "$user" "$DOM" "$UUID" "443" "ws" "tls" "/trojan")
                LINK_NTLS=$(generar_link "$user" "$DOM" "$UUID" "80" "ws" "" "/trojan")
                LINK_GRPC=$(generar_link "$user-GRPC" "$DOM" "$UUID" "443" "grpc" "tls" "trojan-grpc")
                LINK_XHTTP=$(generar_link "$user-XHTTP" "$DOM" "$UUID" "443" "xhttp" "tls" "/xhttp")
                LINK_XHTTP80=$(generar_link "$user-XHTTP80" "$DOM" "$UUID" "80" "xhttp" "" "/xhttp")

                clear
                echo -e "${C_YELLOW}    ${T[CUENTA TROJAN CREADA EXITOSAMENTE]:-CUENTA TROJAN CREADA EXITOSAMENTE}    ${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                echo -e " Alias       : ${C_CYAN}$user${C_NC}"
                echo -e " ${T[Dominio]:-Dominio}     : ${C_CYAN}$DOM${C_NC}"
                echo -e " ${T[Password]:-Password}    : ${C_CYAN}$UUID${C_NC}"
                echo -e " ${T[Red]:-Red}         : ${C_CYAN}WS / GRPC / XHTTP${C_NC}"
                echo -e " ${T[Expira]:-Expira}      : ${C_CYAN}$EXP_DATE${C_NC}"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                echo -e "\n ${C_GREEN}LINK TLS (443) :${C_NC}\n$LINK_TLS\n"
                echo -e " ${C_GREEN}LINK NTLS (80) :${C_NC}\n$LINK_NTLS\n"
                echo -e " ${C_GREEN}LINK GRPC      :${C_NC}\n$LINK_GRPC\n"
                echo -e " ${C_GREEN}LINK XHTTP     :${C_NC}\n$LINK_XHTTP\n"
                echo -e " ${C_GREEN}LINK XHTTP80   :${C_NC}\n$LINK_XHTTP80\n"
                echo -e "${C_YELLOW}───────────────────────────────────────────────${C_NC}"
                read -p "${T[Presiona ENTER para volver al menú]:-Presiona ENTER para volver al menú} " foo
                ;;
            2)
                read -p "${T[Usuario a eliminar]:-Usuario a eliminar}: " user
                jq ".inbounds[0].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[1].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[2].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[3].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                jq ".inbounds[4].settings.clients |= map(select(.email != \"$user\"))" $CONF_FILE > tmp.json && mv tmp.json $CONF_FILE
                systemctl restart xray
                echo -e "${C_GREEN}[✔] ${T[Eliminado]:-Eliminado}.${C_NC}"; sleep 2
                ;;
            x|X|"") break ;;
        esac
    done
}

menu_trojan
