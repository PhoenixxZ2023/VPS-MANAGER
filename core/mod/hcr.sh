#!/bin/bash
# VPS-MANAGER-MODULE: hcr
# Modulo cargado con "source" por menu.sh (usar_modulo). No ejecutar directamente.

# ==========================================
# SUBMENÚ: HCR (v1.0 Y v2.0)
# ==========================================
menu_hcr() {
    while true; do
        clear
        local hcr2_ind=" 🔴 "
        systemctl is-active --quiet hcr-server.service 2>/dev/null && hcr2_ind=" 🟢 "
        echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🚀 INSTALAR HCR NATIVO               ${C_NEON_BLUE} ${C_RST}"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar HCR (v1.0)"
        echo -e "  ${C_NEON_YELLOW}2.${C_RST} 🚀 Instalar HCR (v2.0)  ${C_GREEN}${hcr2_ind}${C_RST}"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Anterior"
        echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
        read -p "Seleccione una opción: " hcr_opt
        case $hcr_opt in
            1) clear; run_remote hcr.sh ;;
            2) menu_hcr_v2 ;;
            0) break ;;
            *) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
        esac
    done
}

# Carpeta de HCR v2 (install.sh + hcr-server). Debe ser de root y sin espacios.
HCR2_DIR="/etc/vps-manager/hcr-v2"
HCR2_BASE="${REPO_RAW}/core"
HCR2_INSTALLER_URL="$HCR2_BASE/hcrv2"
HCR2_BIN_URL="$HCR2_BASE/hcr-server-v2"

hcr2_instalado() {
    [ -f "$HCR2_DIR/hcr-server" ] || [ -e /etc/systemd/system/hcr-server.service ]
}

menu_hcr_v2() {
    while true; do
        clear
        local estado port
        if ! hcr2_instalado; then estado="⚪ No instalado"
        elif systemctl is-active --quiet hcr-server.service 2>/dev/null; then estado="🟢 ACTIVO"
        else estado="🔴 DETENIDO"; fi
        port=$(cat /etc/vps-manager/hcr_port 2>/dev/null)
        echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
        echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🚀 HCR v2.0 - GESTIÓN                ${C_NEON_BLUE} ${C_RST}"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  Estado : $estado"
        hcr2_instalado && echo -e "  Puerto : ${C_NEON_YELLOW}${port:-N/D}${C_RST}"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar HCR v2.0"
        echo -e "  ${C_NEON_YELLOW}2.${C_RST} 🔧 Cambiar puerto"
        echo -e "  ${C_NEON_YELLOW}3.${C_RST} 🔄 Reiniciar"
        echo -e "  ${C_NEON_YELLOW}4.${C_RST} ⏹️ Detener"
        echo -e "  ${C_NEON_YELLOW}5.${C_RST} 🗑️ Desinstalar"
        echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
        echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Anterior"
        echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
        read -p "Seleccione una opción: " hcr2_opt
        case $hcr2_opt in
            1) hcr2_instalar ;;
            2) hcr2_cambiar_puerto ;;
            3) hcr2_reiniciar ;;
            4) hcr2_detener ;;
            5) hcr2_desinstalar ;;
            0) break ;;
            *) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
        esac
    done
}

hcr2_instalar() {
    local DIR="$HCR2_DIR"
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🚀 Instalar HCR (v2.0)        ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"

    # 1) Arquitectura del servidor
    local arq
    case "$(uname -m)" in
        x86_64|amd64)        arq="amd64" ;;
        i386|i486|i586|i686) arq="386" ;;
        armv7*)              arq="arm" ;;
        aarch64|arm64)       arq="arm64" ;;
        *) echo -e "${C_RED}[!] Arquitectura no soportada: $(uname -m)${C_RST}"; read -p "Presione Enter para continuar..."; return ;;
    esac

    # 2) Descarga (a archivos temporales: no se pisa el binario si el servicio está corriendo)
    echo -e "${C_YELLOW}[+] Descargando HCR v2.0 ($arq)...${C_RST}"
    mkdir -p "$DIR"; chown root:root "$DIR"; chmod 755 "$DIR"
    local tmp_sh tmp_bin ok=0
    tmp_sh=$(mktemp "$DIR/.install.XXXXXX"); tmp_bin=$(mktemp "$DIR/.bin.XXXXXX")

    if ! wget -q -O "$tmp_sh" "$HCR2_INSTALLER_URL" || [ "$(head -c2 "$tmp_sh" 2>/dev/null)" != "#!" ]; then
        echo -e "${C_RED}[!] No se pudo descargar el instalador desde:${C_RST}\n    $HCR2_INSTALLER_URL"
        rm -f "$tmp_sh" "$tmp_bin"; read -p "Presione Enter para continuar..."; return
    fi
    if wget -q -O "$tmp_bin" "$HCR2_BIN_URL" && [ "$(head -c4 "$tmp_bin" 2>/dev/null | tail -c3)" = "ELF" ]; then ok=1; fi
    if [ "$ok" -ne 1 ]; then
        echo -e "${C_RED}[!] No se pudo descargar el binario desde:${C_RST}\n    $HCR2_BIN_URL"
        rm -f "$tmp_sh" "$tmp_bin"; read -p "Presione Enter para continuar..."; return
    fi
    chmod 755 "$tmp_bin"
    if ! "$tmp_bin" -version >/dev/null 2>&1; then
        echo -e "${C_RED}[!] El binario descargado no se puede ejecutar en esta arquitectura ($(uname -m)).${C_RST}"
        rm -f "$tmp_sh" "$tmp_bin"; read -p "Presione Enter para continuar..."; return
    fi
    mv -f "$tmp_sh" "$DIR/install.sh"; mv -f "$tmp_bin" "$DIR/hcr-server"
    chown -R root:root "$DIR"; chmod 755 "$DIR" "$DIR/install.sh" "$DIR/hcr-server"
    echo -e "${C_GREEN}[✔] Descargado: $("$DIR/hcr-server" -version 2>&1 | head -1)${C_RST}"
    echo ""

    # 3) Puerto
    local port
    echo -ne "${C_NEON_YELLOW}Ingrese el puerto para HCR v2.0 (1-65535) [8880]: ${C_RST}"
    read port; port=${port:-8880}
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${C_RED}[!] Puerto no válido.${C_RST}"; read -p "Presione Enter para continuar..."; return
    fi
    # Ocupado por otro servicio (si es el propio hcr-server, se permite reconfigurar)
    if ss -lntp 2>/dev/null | grep ":$port " | grep -qv "hcr-server"; then
        local svc; svc=$(ss -lntp 2>/dev/null | grep ":$port " | grep -v "hcr-server" | head -1 | grep -o '"[^"]*"' | head -1 | tr -d '"')
        echo -e "${C_RED}[!] El puerto $port ya está en uso por: ${svc:-otro servicio}${C_RST}"
        read -p "Presione Enter para continuar..."; return
    fi

    # 4) Transporte
    local transport
    echo -e "${C_NEON_YELLOW}Seleccione el transporte:${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} auto  (TLS y sin TLS en el mismo puerto) ${C_GREEN}[recomendado]${C_RST}"
    echo -e "  ${C_NEON_YELLOW}2.${C_RST} tls   (solo TLS)"
    echo -e "  ${C_NEON_YELLOW}3.${C_RST} plain (sin TLS)"
    read -p "Opción [1]: " t_opt
    case "${t_opt:-1}" in
        1) transport="auto" ;;
        2) transport="tls" ;;
        3) transport="plain" ;;
        *) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; read -p "Presione Enter para continuar..."; return ;;
    esac

    # 5) Certificados (solo auto/tls): se enlazan al certificado Let's Encrypt del dominio configurado
    if [ "$transport" != "plain" ]; then
        local dom le
        dom=$(cat /etc/vps-manager/dominio 2>/dev/null)
        le="/etc/letsencrypt/live/$dom"
        if [ -n "$dom" ] && [ -f "$le/fullchain.pem" ] && [ -f "$le/privkey.pem" ]; then
            [ -e "$DIR/fullchain.pem" ] && [ ! -L "$DIR/fullchain.pem" ] || ln -sfn "$le/fullchain.pem" "$DIR/fullchain.pem"
            [ -e "$DIR/privkey.pem" ]   && [ ! -L "$DIR/privkey.pem" ]   || ln -sfn "$le/privkey.pem"   "$DIR/privkey.pem"
            echo -e "${C_GREEN}[✔] Certificado TLS de $dom enlazado.${C_RST}"
        elif [ -f "$DIR/fullchain.pem" ] && [ -f "$DIR/privkey.pem" ]; then
            echo -e "${C_GREEN}[✔] Se usarán los certificados que ya hay en $DIR.${C_RST}"
        else
            echo -e "${C_RED}[!] No hay certificado TLS disponible.${C_RST} Configura tu dominio en"
            echo -e "    ${C_NEON_YELLOW}Herramientas y Sistema > Gestor de Dominio y Certificados SSL${C_RST}."
            read -p "¿Instalar en modo plain (sin TLS)? (s/n): " r_plain
            if [[ "$r_plain" == "s" || "$r_plain" == "S" ]]; then transport="plain"; else return; fi
        fi
    fi

    # 6) Destino SSH
    local target
    echo -ne "${C_NEON_YELLOW}Destino SSH (HOST:PUERTO) [127.0.0.1:22]: ${C_RST}"
    read target; target=${target:-127.0.0.1:22}
    if [[ ! "$target" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] || [ "${target##*:}" -lt 1 ] || [ "${target##*:}" -gt 65535 ]; then
        echo -e "${C_RED}[!] Destino no válido. Formato: HOST:PUERTO${C_RST}"; read -p "Presione Enter para continuar..."; return
    fi

    # 7) Instalar el servicio con el install.sh oficial
    echo ""
    echo -e "${C_YELLOW}[+] Instalando servicio HCR v2.0 en el puerto $port ($transport)...${C_RST}"
    if bash "$DIR/install.sh" --port "$port" --transport "$transport" --target "$target"; then
        echo "$port" > /etc/vps-manager/hcr_port
        echo "$transport" > /etc/vps-manager/hcr_transport
        echo "$target" > /etc/vps-manager/hcr_target
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
            ufw allow "$port/tcp" >/dev/null 2>&1
        fi
        echo -e "${C_NEON_BLUE}════════════════════════════════════════════════${C_RST}"
        echo -e "  ${C_NEON_GREEN}Puerto     :${C_RST} $port"
        echo -e "  ${C_NEON_GREEN}Transporte :${C_RST} $transport"
        echo -e "  ${C_NEON_GREEN}Destino    :${C_RST} $target"
        echo -e "${C_NEON_BLUE}════════════════════════════════════════════════${C_RST}"
        echo -e "${C_GREEN}[✔] HCR v2.0 instalado y activo en el puerto $port.${C_RST}"
    else
        echo -e "${C_RED}[!] La instalación falló. Últimas líneas del registro:${C_RST}"
        journalctl -u hcr-server -n 15 --no-pager 2>/dev/null
    fi
    read -p "Presione Enter para continuar..."
}

hcr2_requiere_instalado() {
    if ! hcr2_instalado; then
        echo -e "${C_YELLOW}[!] HCR v2.0 no está instalado. Use la opción 1 primero.${C_RST}"
        read -p "Presione Enter para continuar..."
        return 1
    fi
    return 0
}

hcr2_cambiar_puerto() {
    local DIR="$HCR2_DIR"
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🔧 CAMBIAR PUERTO HCR v2.0           ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
    hcr2_requiere_instalado || return
    if [ ! -x "$DIR/install.sh" ]; then
        echo -e "${C_RED}[!] Falta $DIR/install.sh. Reinstale HCR v2.0 con la opción 1.${C_RST}"
        read -p "Presione Enter para continuar..."; return
    fi

    local old_port new_port transport target unit
    old_port=$(cat /etc/vps-manager/hcr_port 2>/dev/null)
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
    if ss -lntp 2>/dev/null | grep ":$new_port " | grep -qv "hcr-server"; then
        local svc; svc=$(ss -lntp 2>/dev/null | grep ":$new_port " | grep -v "hcr-server" | head -1 | grep -o '"[^"]*"' | head -1 | tr -d '"')
        echo -e "${C_RED}[!] El puerto $new_port ya está en uso por: ${svc:-otro servicio}${C_RST}"
        read -p "Presione Enter para continuar..."; return
    fi

    # Conservar transporte y destino actuales: archivos guardados -> unidad systemd -> preguntar
    transport=$(cat /etc/vps-manager/hcr_transport 2>/dev/null)
    target=$(cat /etc/vps-manager/hcr_target 2>/dev/null)
    unit=$(systemctl cat hcr-server.service 2>/dev/null | grep -E '^ExecStart=')
    [ -z "$transport" ] && transport=$(echo "$unit" | sed -nE 's/.*--transport[ =]+([a-z]+).*/\1/p' | head -1)
    [ -z "$target" ]    && target=$(echo "$unit" | sed -nE 's/.*--target[ =]+([A-Za-z0-9._-]+:[0-9]+).*/\1/p' | head -1)
    if [[ ! "$transport" =~ ^(auto|tls|plain)$ ]]; then
        read -p "No se detectó el transporte actual (auto/tls/plain) [auto]: " transport
        transport=${transport:-auto}
        [[ "$transport" =~ ^(auto|tls|plain)$ ]] || { echo -e "${C_RED}[!] Transporte no válido.${C_RST}"; read -p "Presione Enter para continuar..."; return; }
    fi
    if [[ ! "$target" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]]; then
        read -p "No se detectó el destino SSH actual (HOST:PUERTO) [127.0.0.1:22]: " target
        target=${target:-127.0.0.1:22}
        [[ "$target" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] || { echo -e "${C_RED}[!] Destino no válido.${C_RST}"; read -p "Presione Enter para continuar..."; return; }
    fi

    echo -e "${C_YELLOW}[+] Aplicando puerto $new_port ($transport → $target)...${C_RST}"
    if bash "$DIR/install.sh" --port "$new_port" --transport "$transport" --target "$target"; then
        echo "$new_port" > /etc/vps-manager/hcr_port
        echo "$transport" > /etc/vps-manager/hcr_transport
        echo "$target" > /etc/vps-manager/hcr_target
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "active"; then
            [ -n "$old_port" ] && ufw delete allow "${old_port}/tcp" >/dev/null 2>&1
            ufw allow "${new_port}/tcp" >/dev/null 2>&1
        fi
        echo -e "${C_GREEN}[✔] Puerto cambiado: ${old_port:-?} → ${new_port}.${C_RST}"
    else
        echo -e "${C_RED}[!] No se pudo cambiar el puerto. Últimas líneas del registro:${C_RST}"
        journalctl -u hcr-server -n 15 --no-pager 2>/dev/null
    fi
    read -p "Presione Enter para continuar..."
}

hcr2_reiniciar() {
    clear
    hcr2_requiere_instalado || return
    echo -e "${C_YELLOW}[+] Reiniciando HCR v2.0...${C_RST}"
    systemctl restart hcr-server.service >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet hcr-server.service 2>/dev/null; then
        echo -e "${C_GREEN}[✔] HCR v2.0 reiniciado.${C_RST}"
    else
        echo -e "${C_RED}[!] No se pudo iniciar. Últimas líneas del registro:${C_RST}"
        journalctl -u hcr-server -n 15 --no-pager 2>/dev/null
    fi
    read -p "Presione Enter para continuar..."
}

hcr2_detener() {
    clear
    hcr2_requiere_instalado || return
    echo -e "${C_YELLOW}[+] Deteniendo HCR v2.0...${C_RST}"
    systemctl stop hcr-server.service >/dev/null 2>&1
    sleep 1
    if systemctl is-active --quiet hcr-server.service 2>/dev/null; then
        echo -e "${C_RED}[!] No se pudo detener el servicio.${C_RST}"
    else
        echo -e "${C_GREEN}[✔] HCR v2.0 detenido.${C_RST}"
        echo -e "${C_YELLOW}    (Para volver a activarlo use la opción Reiniciar.)${C_RST}"
    fi
    read -p "Presione Enter para continuar..."
}

hcr2_desinstalar() {
    local DIR="$HCR2_DIR"
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}         🗑️ DESInstalar HCR (v2.0)      ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
    if [ ! -f "$DIR/hcr-server" ] && [ ! -e /etc/systemd/system/hcr-server.service ]; then
        echo -e "${C_YELLOW}[!] HCR v2.0 no está instalado.${C_RST}"
        read -p "Presione Enter para continuar..."; return
    fi
    read -p "¿Desinstalar HCR v2.0 y borrar sus archivos? (s/n): " conf
    if [[ "$conf" != "s" && "$conf" != "S" ]]; then return; fi
    echo -e "${C_YELLOW}[+] Desinstalando HCR v2.0...${C_RST}"
    if [ -x "$DIR/install.sh" ]; then
        bash "$DIR/install.sh" --uninstall >/dev/null 2>&1
    fi
    # Respaldo por si install.sh no estaba: quitar el servicio a mano
    systemctl disable --now hcr-server.service >/dev/null 2>&1
    rm -f /etc/systemd/system/hcr-server.service
    systemctl daemon-reload >/dev/null 2>&1
    # Borrar solo lo que instaló el menú (los certificados enlazados son solo enlaces, no se toca Let's Encrypt)
    rm -f "$DIR/install.sh" "$DIR/hcr-server" "$DIR/hcr-server.service"
    find "$DIR" -maxdepth 1 -type l -delete 2>/dev/null
    rmdir "$DIR" 2>/dev/null
    rm -f /etc/vps-manager/hcr_port /etc/vps-manager/hcr_transport /etc/vps-manager/hcr_target
    echo -e "${C_GREEN}[✔] HCR v2.0 desinstalado.${C_RST}"
    read -p "Presione Enter para continuar..."
}
