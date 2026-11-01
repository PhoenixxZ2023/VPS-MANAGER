#!/bin/bash
# ==========================================
# Script de Instalación - VPS MANAGER V5.1
# Validación Segura vía API (Sin Tokens)
# ==========================================
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
# ══════════════════════════════════════════
# ⚙️  CONFIGURACIÓN SEGURA (EDITA ESTO)
# ══════════════════════════════════════════
API_URL="http://129.159.164.232/api/validar.php"
API_SECRETO="75c1edcd24934cb50d2983b6877aded3bc7a8de87ca3615188b375e14df0aba9"
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
# 2. GENERAR HWID Y VALIDAR KEY VÍA API
# ==========================================
generar_hwid() {
    local machine=$(cat /etc/machine-id 2>/dev/null || echo "unknown")
    local mac=$(ip link show 2>/dev/null | grep "link/ether" | head -1 | awk '{print $2}' || echo "unknown")
    echo -n "${machine}${mac}" | sha256sum | awk '{print $1}'
}

# ==========================================
# VERIFICAR SI YA HAY LICENCIA INSTALADA
# ==========================================
verificar_licencia_existente() {
    local hwid_actual=$(generar_hwid)
    
    if [ -f /etc/vps-manager/.license ] && [ -f /etc/vps-manager/.hwid ]; then
        local hwid_guardado=$(cat /etc/vps-manager/.hwid)
        local key_guardada=$(cat /etc/vps-manager/.license)
        
        if [ "$hwid_actual" = "$hwid_guardado" ]; then
            echo -e "\033[1;32m[✔] Licencia permanente detectada en este equipo.\033[0m"
            echo -e "\033[1;36m    Key: ${key_guardada:0:8}...\033[0m"
            echo -e "\033[1;36m    HWID coincide. Permitiendo reinstalación...\033[0m"
            return 0
        else
            echo -e "\033[1;31m[!] Este equipo ya tiene una licencia vinculada a otro HWID.\033[0m"
            return 1
        fi
    fi
    return 2  # No hay licencia previa
}

validar_key_api() {
    local key="$1"
    local hwid=$(generar_hwid)
    local ip_cliente=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "UNKNOWN")
    local timestamp=$(date +%s)
    local firma=$(echo -n "${key}${hwid}${ip_cliente}${timestamp}${API_SECRETO}" | sha256sum | awk '{print $1}')
    
    echo -e "\033[1;36m    Verificando licencia de forma segura...\033[0m"
    
    local respuesta
    respuesta=$(curl -s --max-time 10 \
    "${API_URL}?key=$(printf '%s' "$key" | jq -sRr @uri)&hwid=${hwid}&ip=${ip_cliente}&t=${timestamp}&sig=${firma}" 2>/dev/null)
    
    case "$respuesta" in
        "✅ ACTIVA"*)
            local dias=$(echo "$respuesta" | cut -d'|' -f2)
            echo -e "\033[1;32m[✔] Key validada correctamente.\033[0m"
            echo -e "\033[1;36m    Ventana de instalación: ${dias}\033[0m"
            echo -e "\033[1;36m    Una vez instalada, será PERMANENTE en este equipo.\033[0m"
            
            # Guardar datos de licencia localmente
            mkdir -p /etc/vps-manager
            echo "$key" > /etc/vps-manager/.license
            echo "$hwid" > /etc/vps-manager/.hwid
            echo "$ip_cliente" > /etc/vps-manager/.ip_vps
            echo "$dias" > /etc/vps-manager/.dias_validez
            echo "$(date -d "+${dias} days" +%Y-%m-%d 2>/dev/null || date -v+${dias}d +%Y-%m-%d 2>/dev/null)" > /etc/vps-manager/.fecha_expiracion
            echo "$API_SECRETO" > /etc/vps-manager/.api_secret
            
            chmod 600 /etc/vps-manager/.license /etc/vps-manager/.hwid /etc/vps-manager/.ip_vps /etc/vps-manager/.dias_validez /etc/vps-manager/.fecha_expiracion /etc/vps-manager/.api_secret
            return 0
            ;;
        "❌ YA_USADA")
            echo -e "\033[1;31m[!] Key ya fue utilizada en otro equipo.\033[0m"
            echo -e "\033[1;33m    Esta key es de un solo uso por equipo.\033[0m"
            return 1
            ;;
        "❌ EXPIRADA")
            echo -e "\033[1;31m[!] La ventana de instalación de esta key expiró.\033[0m"
            echo -e "\033[1;33m    Solicita una nueva key al administrador.\033[0m"
            return 1
            ;;
        "❌ BANEADA")
            echo -e "\033[1;31m[!] Key bloqueada por el administrador.\033[0m"
            return 1
            ;;
        *)
            echo -e "\033[1;31m[!] Key Inválida o error de conexión con el servidor.\033[0m"
            echo -e "\033[1;33m    Contacta al administrador.\033[0m"
            return 1
            ;;
    esac
}

# ==========================================
# FLUJO DE VALIDACIÓN
# ==========================================
echo -e "\n\033[1;33m[?] Ingresa tu Key de instalación:\033[0m"
echo -ne "\033[1;36m    > \033[0m"
read -r input_key

if [ -z "$input_key" ]; then
    input_key="FREE-KEY-GT"
    echo -e "\033[1;33m    Usando key por defecto: $input_key\033[0m"
fi

if [ "$API_URL" = "http://TU_IP_O_DOMINIO/api/validar.php" ]; then
    echo -e "\033[1;31m[!] Error: Debes configurar API_URL y API_SECRETO en el script.\033[0m"
    exit 1
fi

# Primero verificar si ya hay licencia instalada
verificar_licencia_existente
resultado=$?

if [ $resultado -eq 0 ]; then
    # Licencia existente válida, continuar con reinstalación
    echo -e "\033[1;32m[✔] Continuando con reinstalación...\033[0m"
    sleep 2
elif [ $resultado -eq 1 ]; then
    # Licencia existente pero HWID diferente
    echo -e "\033[1;31m[!] Instalación abortada.\033[0m"
    exit 1
else
    # No hay licencia previa, validar key con API
    if ! validar_key_api "$input_key"; then
        echo -e "\033[1;31m[!] Instalación abortada por validación fallida.\033[0m"
        exit 1
    fi
    sleep 1
fi

# ==========================================
# 3. ESPERAR LIBERACIÓN DEL LOCK DE APT
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
# 4. ACTUALIZACIÓN DEL SISTEMA
# ==========================================
echo -e "\n\033[1;36m[+] Actualizando índices del sistema...\033[0m"
if ! apt-get update -y > /dev/null 2>&1; then
    echo -e "\033[1;31m[!] Falló 'apt-get update'. Revisa tu conexión.\033[0m"
    sleep 2
else
    echo -e "\033[1;32m[✔] Índices actualizados correctamente.\033[0m"
fi

# ==========================================
# 5. INSTALACIÓN DE PAQUETES NECESARIOS
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
# 6. CREACIÓN DE DIRECTORIOS
# ==========================================
echo -e "\n\033[1;36m[+] Preparando sistema...\033[0m"
mkdir -p /etc/vps-manager/core
mkdir -p /usr/local/bin

# ==========================================
# 7. FUNCIÓN DE DESCARGA CON REINTENTOS
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
# 8. DESCARGA DE MÓDULOS
# ==========================================
echo -e "\n\033[1;36m[+] Descargando componentes y módulos core...\033[0m"
descargar "${REPO_BASE}/core/proxy.py" /etc/vps-manager/proxy.py || exit 1
descargar "${REPO_BASE}/core/limiter.sh" /etc/vps-manager/limiter.sh || exit 1
descargar "${REPO_BASE}/core/setup_dns.sh" /etc/vps-manager/core/setup_dns.sh || exit 1
chmod +x /etc/vps-manager/limiter.sh
chmod +x /etc/vps-manager/core/setup_dns.sh
echo -e "\033[1;32m[✔] Módulos core descargados correctamente.\033[0m"

# ==========================================
# 9. DESCARGA DEL MENÚ PRINCIPAL
# ==========================================
echo -e "\n\033[1;36m[+] Instalando el Panel Principal...\033[0m"
rm -f /usr/local/bin/menu
rm -f /usr/local/bin/me
descargar "${REPO_BASE}/menu.sh" /usr/local/bin/menu || exit 1
chmod +x /usr/local/bin/menu
echo -e "\033[1;32m[✔] Panel Principal instalado correctamente.\033[0m"

# ==========================================
# 10. VERIFICACIÓN FINAL Y APERTURA AUTOMÁTICA
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