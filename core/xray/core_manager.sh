#!/bin/bash
# Core Manager XRAY2026 com TLS e roteamento público gerenciados pelo HAProxy.
set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (código: $?)"; read -rp "Enter para continuar...";' ERR

CONFIG_PATH="/usr/local/etc/xray/config.json"
USER_DB="/opt/XrayTools/users.db"
LOG_FILE="/var/log/vps-manager-core.log"

TITLE_BAR='\033[1;47;34m'
TXT_GREEN='\033[1;32m'
TXT_RED='\033[1;31m'
TXT_CYAN='\033[1;36m'
TXT_YELLOW='\033[1;33m'
TXT_BLUE='\033[1;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

_PKG_MANAGER=""
_detect_pkg_manager() {
    if [ -n "$_PKG_MANAGER" ]; then return 0; fi
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then _PKG_MANAGER="pacman"
    else echo -e "${TXT_RED}❌ Gerenciador de pacotes não detectado.${RESET}"; exit 1; fi
}

_APT_UPDATED=0
ensure_cmd() {
    local cmd="$1" pkg="$2"
    if command -v "$cmd" &>/dev/null; then return 0; fi
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            if [ "$_APT_UPDATED" -eq 0 ]; then
                apt-get update -y >>"$LOG_FILE" 2>&1 || true
                _APT_UPDATED=1
            fi
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >>"$LOG_FILE" 2>&1 ;;
    esac
}

header_blue() { clear; echo -e "${TITLE_BAR}   $1   ${RESET}"; echo ""; }

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo -e "${TXT_RED}❌ Execute como root!${RESET}"
        exit 1
    fi
}

_detect_xray_owner() {
    local svc_user=""
    if command -v systemctl &>/dev/null; then
        svc_user=$(systemctl show -p User --value xray 2>/dev/null || true)
    fi
    svc_user="${svc_user:-nobody}"
    if ! id "$svc_user" &>/dev/null; then
        svc_user="root"
    fi
    XRAY_USER="$svc_user"
    XRAY_GROUP="$(id -gn "$XRAY_USER")"
}

_apply_config_perms() {
    _detect_xray_owner
    if [[ -f "$CONFIG_PATH" ]]; then
        chown "root:$XRAY_GROUP" "$CONFIG_PATH"
        chmod 0640 "$CONFIG_PATH"
    fi
}

_check_shebang_bom_safe() {
    local file="$1"
    local first_line
    first_line=$(LC_ALL=C head -n 1 "$file" | sed 's/^\xEF\xBB\xBF//')
    [[ "$first_line" =~ ^#!.*(bash|sh|env[[:space:]]) ]]
}

_verify_sha256() {
    local file="$1" sha_url="$2" label="$3"
    local expected
    expected=$(curl -fLsS --max-time 10 --connect-timeout 5 "$sha_url" 2>/dev/null | awk '{print $1}' || true)
    if [ -z "$expected" ]; then
        echo -e "${TXT_YELLOW}⚠  Hash não encontrado para ${label} — verificação ignorada.${RESET}" >&2
        return 0
    fi
    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo -e "${TXT_RED}❌ Falha de integridade: ${label}${RESET}" >&2
        return 1
    fi
    return 0
}

func_install_official_core() {
    header_blue "INSTALANDO XRAY CORE"
    ensure_cmd unzip unzip
    ensure_cmd curl  curl
    ensure_cmd socat socat

    local install_script
    install_script=$(mktemp)
    local sha_url="https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh.sha256"

    echo "Baixando instalador oficial Xray..."
    if ! curl -fLsS --retry 3 --retry-delay 2 --max-time 120 --connect-timeout 15 \
        -o "$install_script" \
        "https://github.com/XTLS/Xray-install/raw/main/install-release.sh" 2>>"$LOG_FILE"; then
        echo -e "${TXT_RED}❌ Erro no download.${RESET}"; sleep 2; return 1
    fi

    if [ ! -s "$install_script" ]; then
        echo -e "${TXT_RED}❌ Arquivo vazio.${RESET}"; return 1
    fi

    if ! _verify_sha256 "$install_script" "$sha_url" "install-release.sh"; then
        rm -f "$install_script"; sleep 2; return 1
    fi

    if ! _check_shebang_bom_safe "$install_script"; then
        echo -e "${TXT_RED}❌ Script inválido.${RESET}"; rm -f "$install_script"; return 1
    fi

    chmod +x "$install_script"
    bash "$install_script" install || { rm -f "$install_script"; return 1; }
    rm -f "$install_script"

    local cpu_cores
    cpu_cores=$(nproc 2>/dev/null || echo 1)
    mkdir -p /etc/systemd/system/xray.service.d
    cat <<EOF > /etc/systemd/system/xray.service.d/override.conf
[Service]
LimitNOFILE=65536
LimitNPROC=65536
Restart=on-failure
RestartSec=3
Environment="GOMAXPROCS=${cpu_cores}"
EOF
    systemctl daemon-reload
    _apply_config_perms

    echo -e "${TXT_GREEN}Instalação e Tuning de CPU concluídos.${RESET}"
    sleep 1
}

func_wizard_install() {
    require_root
    : > "$LOG_FILE"

    header_blue "PASSO 1/5 — INSTALAÇÃO DO CORE"
    echo -e "${TXT_YELLOW}Deseja instalar/atualizar o Xray Core?${RESET}"
    read -rp "[s] Sim / [n] Não: " inst
    if [[ "${inst:-n}" =~ ^[Ss]$ ]]; then
        func_install_official_core || return 1
    fi

    # O motor valida e aplica Xray, HAProxy e certificado como uma única alteração.
    bash /etc/vps-manager/core/xray_manager.sh install || return 1
    if [[ -f /etc/vps-manager/engine_haproxy ]]; then
        choose_profile
    fi

}

choose_profile() {
    local tag opt
    if [[ -s "$USER_DB" ]]; then
        echo "O perfil atual tem usuários cadastrados."
        return
    fi
    read -rp "Perfil para novos usuários: 1) WebSocket  2) gRPC  3) XHTTP [1]: " opt
    case "${opt:-1}" in
        1) tag=vless-ws ;; 2) tag=vless-grpc ;; 3) tag=vless-xhttp ;;
        *) echo "Perfil inválido."; return 1 ;;
    esac
    jq -e --arg tag "$tag" 'any(.inbounds[]; .tag == $tag)' "$CONFIG_PATH" >/dev/null || {
        echo "O perfil escolhido não está ativo no motor."; return 1;
    }
    printf '%s\n' "$tag" > /etc/vps-manager/xray_profile
}

# --- MENU INTERATIVO ---
while true; do
    clear
    echo -e "${TITLE_BAR}   CORE MANAGER — TURBONET XRAY V1.2.6   ${RESET}"
    echo ""

    if systemctl is-active --quiet xray 2>/dev/null; then
        echo -e " STATUS DO SERVIÇO: ${TXT_GREEN}ATIVO E RODANDO${RESET}"
    else
        echo -e " STATUS DO SERVIÇO: ${TXT_RED}INATIVO${RESET}"
    fi
    echo ""
    echo -e "${TXT_CYAN}[1] Instalar/Configurar (Modo Assistente)${RESET}"
    echo -e "${TXT_CYAN}[2] Atualizar Binário Oficial do Xray${RESET}"
    echo -e "${TXT_RED}[3] Parar Xray Core${RESET}"
    echo -e "${TXT_GREEN}[4] Iniciar/Reiniciar Xray Core${RESET}"
    echo -e "${TXT_CYAN}[5] Ver Logs de Erro do Xray${RESET}"
    echo -e "${TXT_CYAN}[0] Voltar${RESET}"
    echo "-----------------------------------------"
    read -rp "Opção: " opt

    case "${opt:-0}" in
        1)
            func_wizard_install || true
            ;;
        2)
            func_install_official_core || true
            _apply_config_perms
            systemctl restart xray >/dev/null 2>&1 || true
            read -rp "Enter..."
            ;;
        3)
            systemctl stop xray >/dev/null 2>&1 || true
            echo -e "${TXT_RED}⛔ Xray Parado.${RESET}"
            read -rp "Enter..."
            ;;
        4)
            _apply_config_perms
            systemctl restart xray >/dev/null 2>&1 || true
            sleep 1
            if systemctl is-active --quiet xray; then
                echo -e "${TXT_GREEN}✅ Xray Rodando Perfeitamente!${RESET}"
            else
                echo -e "${TXT_RED}❌ Falha ao iniciar o Xray. Verifique os logs.${RESET}"
            fi
            read -rp "Enter..."
            ;;
        5)
            echo -e "${TXT_CYAN}=== Últimos 30 logs do Xray ===${RESET}"
            journalctl -u xray -n 30 --no-pager || true
            read -rp "Enter..."
            ;;
        0) exit 0 ;;
        *) echo -e "${TXT_RED}Inválido.${RESET}"; sleep 1 ;;
    esac
done
