#!/bin/bash
# ==========================================
# Script de Instalación - VPS MANAGER V5.1 (Sin Key)
# ==========================================
set -o pipefail
export DEBIAN_FRONTEND=noninteractive

REPO_BASE="https://raw.githubusercontent.com/rogellevi/VPS-MANAGER/main"

clear
echo -e "\033[1;36m================================================\033[0m"
echo -e "\033[1;32m       INSTALADOR VPS MANAGER V5.1 SECURE       \033[0m"
echo -e "\033[1;36m================================================\033[0m"

# ==========================================
# 0. VERIFICACIÓN DE ROOT
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[1;31m[!] Error: Este script debe ejecutarse como root.\033[0m"
    echo -e "\033[1;33m    Usa: sudo bash install.sh\033[0m"
    exit 1
fi

# ==========================================
# 1. INSTALAR DEPENDENCIAS CRÍTICAS PRIMERO
# ==========================================
echo -e "\n\033[1;36m[+] Instalando dependencias críticas...\033[0m"
apt-get update -y > /dev/null 2>&1
if ! apt-get install -y curl jq wget > /dev/null 2>&1; then
    echo -e "\033[1;31m[!] Falló la instalación de dependencias críticas.\033[0m"
    exit 1
fi
echo -e "\033[1;32m[✔] Dependencias críticas instaladas.\033[0m"

# ==========================================
# 2. ESPERAR LIBERACIÓN DEL LOCK DE APT
# ==========================================
echo -e "\n\033[1;36m[+] Verificando disponibilidad de apt...\033[0m"
for i in $(seq 1 60); do
    if ! fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then
        echo -e "\033[1;32m[✔] Apt disponible.\033[0m"
        break
    fi
    echo -e "\033[1;33m    Esperando lock de apt... ($i/60)\033[0m"
    sleep 5
done

# ==========================================
# 3. ACTUALIZACIÓN DEL SISTEMA
# ==========================================
echo -e "\n\033[1;36m[+] Actualizando índices del sistema...\033[0m"
if ! apt-get update -y > /dev/null 2>&1; then
    echo -e "\033[1;31m[!] Falló 'apt-get update'. Revisa tu conexión.\033[0m"
    sleep 2
else
    echo -e "\033[1;32m[✔] Índices actualizados correctamente.\033[0m"
fi

# ==========================================
# 4. INSTALACIÓN DE PAQUETES NECESARIOS
# ==========================================
echo -e "\n\033[1;36m[+] Instalando paquetes necesarios...\033[0m"
if ! apt-get install -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    bc screen nano unzip lsof net-tools dos2unix nload figlet \
    python3 python3-pip at ca-certificates gnupg lsb-release > /dev/null 2>&1; then
    echo -e "\033[1;31m[!] Falló la instalación de paquetes base. Abortando.\033[0m"
    exit 1
fi
echo -e "\033[1;32m[✔] Paquetes base instalados correctamente.\033[0m"

apt-get install -y python > /dev/null 2>&1 || true

# ==========================================
# 5. CREACIÓN DE DIRECTORIOS
# ==========================================
echo -e "\n\033[1;36m[+] Preparando sistema...\033[0m"
mkdir -p /etc/vps-manager/core
mkdir -p /usr/local/bin

# ==========================================
# 6. FUNCIÓN DE DESCARGA CON REINTENTOS
# ==========================================
descargar() {
    local url="$1" dest="$2"
    for i in 1 2 3; do
        if wget -q --timeout=20 --tries=2 -O "$dest" "$url" \
        && [ -s "$dest" ] && ! grep -qi "<html" "$dest"; then
            return 0
        fi
        echo -e "\033[1;33m    Reintento $i/3 para descargar...\033[0m"
        sleep 3
    done
    echo -e "\033[1;31m[!] No se pudo descargar: $url\033[0m"
    return 1
}

# ==========================================
# 7. DESCARGA DE MÓDULOS
# ==========================================
echo -e "\n\033[1;36m[+] Descargando componentes y módulos core...\033[0m"
descargar "${REPO_BASE}/core/proxy.py" /etc/vps-manager/proxy.py || exit 1
descargar "${REPO_BASE}/core/limiter.sh" /etc/vps-manager/limiter.sh || exit 1
descargar "${REPO_BASE}/core/setup_dns.sh" /etc/vps-manager/core/setup_dns.sh || exit 1
chmod +x /etc/vps-manager/limiter.sh
chmod +x /etc/vps-manager/core/setup_dns.sh
echo -e "\033[1;32m[✔] Módulos core descargados correctamente.\033[0m"

# ==========================================
# 8. DESCARGA DEL MENÚ PRINCIPAL
# ==========================================
echo -e "\n\033[1;36m[+] Instalando el Panel Principal...\033[0m"
rm -f /usr/local/bin/menu
rm -f /usr/local/bin/me
descargar "${REPO_BASE}/menu.sh" /usr/local/bin/menu || exit 1
chmod +x /usr/local/bin/menu
echo -e "\033[1;32m[✔] Panel Principal instalado correctamente.\033[0m"

# ==========================================
# 9. VERIFICACIÓN FINAL Y APERTURA AUTOMÁTICA
# ==========================================
echo -e "\n\033[1;32m================================================\033[0m"
echo -e "\033[1;32m  [✔] ¡Instalación completada con éxito!          \033[0m"
echo -e "\033[1;32m================================================\033[0m"
sleep 2

if [ -x /usr/local/bin/menu ]; then
    clear
    /usr/local/bin/menu
else
    echo -e "\033[1;31m[!] El menú no se instaló correctamente. Revisa tu conexión.\033[0m"
    exit 1
fi
