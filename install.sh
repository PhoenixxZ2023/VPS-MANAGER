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
# Script de Instalación - VPS MANAGER V5.1 (Sin Key)
# ==========================================
set -o pipefail
export DEBIAN_FRONTEND=noninteractive

REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/PhoenixxZ2023/VPS-MANAGER/main}"

# i18n: catálogo de português do Brasil (somente dados, nunca executado)
_i18n_fetch() {
    mkdir -p /etc/vps-manager/i18n 2>/dev/null || return 1
    local f tmp ok=1
    for f in pt-BR.tsv pt-BR.py.tsv; do
        tmp=$(mktemp 2>/dev/null) || return 1
        if { wget -qO "$tmp" "$REPO_BASE/i18n/$f" 2>/dev/null || curl -fsSL -o "$tmp" "$REPO_BASE/i18n/$f" 2>/dev/null; } && [ -s "$tmp" ] && awk -F'\t' 'NF!=2{bad=1} END{exit bad}' "$tmp"; then
            mv -f "$tmp" "/etc/vps-manager/i18n/$f"; chmod 644 "/etc/vps-manager/i18n/$f"
        else
            rm -f "$tmp"; ok=0
        fi
    done
    [ "$ok" -eq 1 ]
}
_i18n_fetch 2>/dev/null; _T_LOADED=""; load_lang

clear
echo -e "\033[1;36m================================================\033[0m"
echo -e "\033[1;32m       INSTALADOR VPS MANAGER V5.1 SECURE       \033[0m"
echo -e "\033[1;36m================================================\033[0m"

# ==========================================
# 0. VERIFICACIÓN DE ROOT
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[1;31m[!] ${T[Error: Este script debe ejecutarse como root]:-Error: Este script debe ejecutarse como root}.\033[0m"
    echo -e "\033[1;33m    ${T[Usa: sudo bash install.sh]:-Usa: sudo bash install.sh}\033[0m"
    exit 1
fi

# ==========================================
# 1. INSTALAR DEPENDENCIAS CRÍTICAS PRIMERO
# ==========================================
echo -e "\n\033[1;36m[+] ${T[Instalando dependencias críticas]:-Instalando dependencias críticas}...\033[0m"
apt-get update -y > /dev/null 2>&1
if ! apt-get install -y curl jq wget > /dev/null 2>&1; then
    echo -e "\033[1;31m[!] ${T[Falló la instalación de dependencias críticas]:-Falló la instalación de dependencias críticas}.\033[0m"
    exit 1
fi
echo -e "\033[1;32m[✔] ${T[Dependencias críticas instaladas]:-Dependencias críticas instaladas}.\033[0m"

_i18n_fetch 2>/dev/null; _T_LOADED=""; load_lang

# ==========================================
# 2. ESPERAR LIBERACIÓN DEL LOCK DE APT
# ==========================================
echo -e "\n\033[1;36m[+] ${T[Verificando disponibilidad de apt]:-Verificando disponibilidad de apt}...\033[0m"
for i in $(seq 1 60); do
    if ! fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
        echo -e "\033[1;32m[✔] ${T[Apt disponible]:-Apt disponible}.\033[0m"
        break
    fi
    echo -e "\033[1;33m    ${T[Esperando lock de apt]:-Esperando lock de apt}... ($i/60)\033[0m"
    sleep 5
done

# ==========================================
# 3. ACTUALIZACIÓN DEL SISTEMA
# ==========================================
echo -e "\n\033[1;36m[+] ${T[Actualizando índices del sistema]:-Actualizando índices del sistema}...\033[0m"
if ! apt-get update -y > /dev/null 2>&1; then
    echo -e "\033[1;31m[!] ${T[Falló]:-Falló} 'apt-get update'. ${T[Revisa tu conexión]:-Revisa tu conexión}.\033[0m"
    sleep 2
else
    echo -e "\033[1;32m[✔] ${T[Índices actualizados correctamente]:-Índices actualizados correctamente}.\033[0m"
fi

# ==========================================
# 4. INSTALACIÓN DE PAQUETES NECESARIOS
# ==========================================
echo -e "\n\033[1;36m[+] ${T[Instalando paquetes necesarios]:-Instalando paquetes necesarios}...\033[0m"
if ! apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    cron bc screen nano unzip lsof net-tools dos2unix nload figlet \
    python3 python3-pip at ca-certificates gnupg lsb-release > /dev/null 2>&1; then
    echo -e "\033[1;31m[!] ${T[Falló la instalación de paquetes base. Abortando]:-Falló la instalación de paquetes base. Abortando}.\033[0m"
    exit 1
fi
echo -e "\033[1;32m[✔] ${T[Paquetes base instalados correctamente]:-Paquetes base instalados correctamente}.\033[0m"

apt-get install -y python > /dev/null 2>&1 || true

# ==========================================
# 5. CREACIÓN DE DIRECTORIOS
# ==========================================
echo -e "\n\033[1;36m[+] ${T[Preparando sistema]:-Preparando sistema}...\033[0m"
mkdir -p /etc/vps-manager/core
mkdir -p /usr/local/bin

# ==========================================
# 6. FUNCIÓN DE DESCARGA CON REINTENTOS
# ==========================================
LOCAL_SOURCE=""
if [[ -f "${BASH_SOURCE[0]}" ]]; then
    candidate=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
    [[ -f "$candidate/core/xray/provision" ]] && LOCAL_SOURCE="$candidate"
fi
descargar() {
    local url="$1" dest="$2" rel
    rel=${url#"$REPO_BASE/"}
    if [[ -n "$LOCAL_SOURCE" && -f "$LOCAL_SOURCE/$rel" ]]; then
        install -m 0644 "$LOCAL_SOURCE/$rel" "$dest"
        return
    fi
    for i in 1 2 3; do
        if wget -q --timeout=20 --tries=2 -O "$dest" "$url" \
        && [ -s "$dest" ] && ! grep -qi "<html" "$dest"; then
            return 0
        fi
        echo -e "\033[1;33m    ${T[Reintento]:-Reintento} $i/3 ${T[para descargar]:-para descargar}...\033[0m"
        sleep 3
    done
    echo -e "\033[1;31m[!] ${T[No se pudo descargar]:-No se pudo descargar}: $url\033[0m"
    return 1
}

# ==========================================
# 7. DESCARGA DE MÓDULOS
# ==========================================
echo -e "\n\033[1;36m[+] ${T[Descargando componentes y módulos core]:-Descargando componentes y módulos core}...\033[0m"
descargar "${REPO_BASE}/core/proxy.py" /etc/vps-manager/proxy.py || exit 1
descargar "${REPO_BASE}/core/update.sh" /etc/vps-manager/core/update.sh || exit 1
descargar "${REPO_BASE}/core/limiter.sh" /etc/vps-manager/limiter.sh || exit 1
descargar "${REPO_BASE}/core/setup_dns.sh" /etc/vps-manager/core/setup_dns.sh || exit 1
if [[ -n "$LOCAL_SOURCE" ]]; then
    for component in hcrv2 hcr-server-v2; do
        install -m 0644 "$LOCAL_SOURCE/core/$component" "/etc/vps-manager/core/$component" || exit 1
    done
fi
mkdir -p /etc/vps-manager/core/{turboproxy/bin,turbo-multiproxy}
for component in turboproxy/{install.sh,turboproxy.service,bin/SHA256SUMS,bin/turboproxy-linux-{amd64,arm64}} \
                 turbo-multiproxy/{install.sh,menu.sh,proxy.py,turbo-multiproxy.service}; do
    descargar "$REPO_BASE/core/$component" "/etc/vps-manager/core/$component" || exit 1
done
mkdir -p /etc/vps-manager/core/dtunnel
for component in BHTTP.py dtunnel/menu.sh dtunnel/server.py; do
    descargar "$REPO_BASE/core/$component" "/etc/vps-manager/core/$component" || exit 1
done
mkdir -p /etc/vps-manager/core/hcr3/bin
for component in menu.sh hcr.sh servico.sh haproxy_route.py bin/hcr-server-{amd64,arm64}.sha256; do
    descargar "$REPO_BASE/core/hcr3/$component" "/etc/vps-manager/core/hcr3/$component" || exit 1
done
printf '%s\n' "$REPO_BASE" > /etc/vps-manager/core/hcr3/repo-url
case $(uname -m) in
    amd64|x86_64) hcr_arch=amd64 ;;
    aarch64|arm64) hcr_arch=arm64 ;;
    *) hcr_arch="" ;;
esac
if [[ -n "$LOCAL_SOURCE" && -n "$hcr_arch" ]]; then
    hcr_bin="hcr-server-$hcr_arch"
    install -m 0755 "$LOCAL_SOURCE/core/hcr3/bin/$hcr_bin" "/etc/vps-manager/core/hcr3/bin/$hcr_bin" || exit 1
    (cd /etc/vps-manager/core/hcr3/bin && sha256sum -c "$hcr_bin.sha256") || exit 1
fi
mkdir -p /etc/vps-manager/core/xray
for component in xray_manager.sh xray/{core_manager.sh,botxray.sh,botxray.py,xray_accounts.py,provision,LICENSE}; do
    descargar "$REPO_BASE/core/$component" "/etc/vps-manager/core/$component" || exit 1
done
chmod 0755 /etc/vps-manager/core/xray/provision
printf '%s\n' '4 0 * * * root /etc/vps-manager/core/xray/provision --expire' > /etc/cron.d/vps-manager-xray
chmod 0644 /etc/cron.d/vps-manager-xray
chmod +x /etc/vps-manager/limiter.sh
chmod +x /etc/vps-manager/core/setup_dns.sh
echo -e "\033[1;32m[✔] ${T[Módulos core descargados correctamente]:-Módulos core descargados correctamente}.\033[0m"

# ==========================================
# 8. DESCARGA DEL MENÚ PRINCIPAL
# ==========================================
echo -e "\n\033[1;36m[+] ${T[Instalando el Panel Principal]:-Instalando el Panel Principal}...\033[0m"
descargar "${REPO_BASE}/menu.sh" /usr/local/bin/menussh || exit 1
chmod +x /usr/local/bin/menussh || exit 1
if [[ -f /usr/local/bin/menu ]] && grep -q '^menu_instaladores()' /usr/local/bin/menu; then
    if [[ -f /root/.bashrc ]]; then
        sed -i -E 's/^[[:space:]]*menu[[:space:]]*$/menussh/' /root/.bashrc || exit 1
    fi
    rm -f /usr/local/bin/menu
fi
echo "Para abrir o VPS-MANAGER, digite: menussh"
echo -e "\033[1;32m[✔] ${T[Panel Principal instalado correctamente]:-Panel Principal instalado correctamente}.\033[0m"

# ==========================================
# 9. VERIFICACIÓN FINAL Y APERTURA AUTOMÁTICA
# ==========================================
echo -e "\n\033[1;32m================================================\033[0m"
echo -e "\033[1;32m  [✔] ${T[¡Instalación completada con éxito]:-¡Instalación completada con éxito}!          \033[0m"
echo -e "\033[1;32m================================================\033[0m"
sleep 2

if [ -x /usr/local/bin/menussh ]; then
    clear
    /usr/local/bin/menussh
else
    echo -e "\033[1;31m[!] ${T[El menú no se instaló correctamente. Revisa tu conexión]:-El menú no se instaló correctamente. Revisa tu conexión}.\033[0m"
    exit 1
fi
