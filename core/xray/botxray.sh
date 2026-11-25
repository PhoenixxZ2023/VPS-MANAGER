#!/bin/bash
# Gerenciador do bot XRAY2026 integrado ao VPS-MANAGER.
set -Eeuo pipefail
trap 'echo -e "\n\033[1;31m[ERRO]\033[0m Falha na linha $LINENO (codigo: $?)"; read -rp "Enter...";' ERR

LOG_FILE="/var/log/vps-manager-bot-install.log"

VERMELHO='\033[1;31m'
VERDE='\033[1;32m'
AMARELO='\033[1;33m'
AZUL='\033[1;34m'
RESET='\033[0m'

export DEBIAN_FRONTEND=noninteractive

_PKG_MANAGER=""
_APT_UPDATED=0
_detect_pkg_manager() {
    [ -n "$_PKG_MANAGER" ] && return
    if   command -v apt-get &>/dev/null; then _PKG_MANAGER="apt"
    elif command -v dnf     &>/dev/null; then _PKG_MANAGER="dnf"
    elif command -v yum     &>/dev/null; then _PKG_MANAGER="yum"
    elif command -v pacman  &>/dev/null; then _PKG_MANAGER="pacman"
    else echo -e "${VERMELHO}Gerenciador de pacotes nao detectado.${RESET}"; exit 1; fi
}

ensure_pkg() {
    local bin="$1" pkg="$2"
    command -v "$bin" &>/dev/null && return 0
    _detect_pkg_manager
    case "$_PKG_MANAGER" in
        apt)
            [ "$_APT_UPDATED" -eq 0 ] && { apt-get update -y >>"$LOG_FILE" 2>&1 || true; _APT_UPDATED=1; }
            apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        dnf|yum) "$_PKG_MANAGER" install -y "$pkg" >>"$LOG_FILE" 2>&1 ;;
        pacman)  pacman -Sy --noconfirm "$pkg"      >>"$LOG_FILE" 2>&1 ;;
    esac
}

[ "${EUID:-$(id -u)}" -ne 0 ] && { echo -e "${VERMELHO}Execute como root!${RESET}"; exit 1; }

_wait_service_active() {
    local svc="$1" tries=5
    while [ "$tries" -gt 0 ]; do
        systemctl is-active --quiet "$svc" 2>/dev/null && return 0
        sleep 1
        tries=$(( tries - 1 ))
    done
    return 1
}

# ==========================================
# FUNÇÃO DE INSTALAÇÃO
# ==========================================
func_install_bot() {
    : > "$LOG_FILE"
    clear
    echo -e "${AZUL}==================================================${RESET}"
    echo -e "${AMARELO}     INSTALADOR BOT TELEGRAM - V1.3.5 (PRO)      ${RESET}"
    echo -e "${AZUL}==================================================${RESET}"
    echo ""

    echo "Preparando ambiente..."
    ensure_pkg python3    python3
    ensure_pkg curl       curl
    ensure_pkg jq         jq
    ensure_pkg sudo       sudo
    ensure_pkg tar        tar

    if ! python3 -c "import ensurepip, venv" >/dev/null 2>&1; then
        _detect_pkg_manager
        local py_ver
        py_ver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "")
        case "$_PKG_MANAGER" in
            apt)
                if [ "$_APT_UPDATED" -eq 0 ]; then
                    apt-get update -y >>"$LOG_FILE" 2>&1 || true
                    _APT_UPDATED=1
                fi
                apt-get install -y python3-venv ${py_ver:+"python${py_ver}-venv"} >>"$LOG_FILE" 2>&1 || true
                ;;
            dnf|yum) "$_PKG_MANAGER" install -y python3-virtualenv >>"$LOG_FILE" 2>&1 || true ;;
            pacman)  pacman -Sy --noconfirm python-virtualenv >>"$LOG_FILE" 2>&1 || true ;;
        esac
    fi

    if ! python3 -c "import ensurepip, venv" >/dev/null 2>&1; then
        echo -e "${VERMELHO}Falha ao instalar python3-venv (ensurepip indisponivel). Veja: ${LOG_FILE}${RESET}"
        sleep 2
        return 1
    fi

    mkdir -p /opt/XrayTools

    echo ""
    echo -e "${AMARELO}1. Token do BotFather (formato: 123456789:ABCdef...):${RESET}"
    echo -e "${AMARELO}   Cole o token e pressione Enter:${RESET}"
    read -rs bot_token || true
    bot_token="$(echo "${bot_token:-}" | tr -d '[:space:][:cntrl:]')"

    echo ""
    echo -e "${AMARELO}2. Seu ID numerico do Telegram (Admin):${RESET}"
    read -r -p "ID Admin: " admin_id || true
    admin_id="$(echo "${admin_id:-}" | tr -d '[:space:][:cntrl:]')"

    if [ -z "${bot_token:-}" ] || ! [[ "$bot_token" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{35,}$ ]]; then
        echo -e "${VERMELHO}Token invalido.${RESET}"; sleep 2; return 1
    fi
    if [ -z "${admin_id:-}" ] || ! [[ "$admin_id" =~ ^[0-9]+$ ]]; then
        echo -e "${VERMELHO}ID Admin invalido.${RESET}"; sleep 2; return 1
    fi

    if ! id -u botxray >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin botxray
    fi

    install -d -m 0750 -o root -g botxray /opt/XrayTools
    touch /opt/XrayTools/users.db
    chown root:botxray /opt/XrayTools/users.db
    chmod 0640 /opt/XrayTools/users.db
    local policy
    policy=$(mktemp)
    printf '%s\n' 'botxray ALL=(root) NOPASSWD: /etc/vps-manager/core/xray/provision ""' > "$policy"
    visudo -cf "$policy"
    install -m 0440 "$policy" /etc/sudoers.d/vps-manager-bot
    rm "$policy"
    umask 077

    # --- ENVIRONMENTFILE ---
    ENV_FILE="/opt/XrayTools/.bot_env"
    printf 'BOT_TOKEN=%s\nADMIN_ID=%s\n' "$bot_token" "$admin_id" > "$ENV_FILE"
    chmod 0640 "$ENV_FILE"
    chown root:botxray "$ENV_FILE"
    echo -e "${VERDE}Credenciais salvas em ${ENV_FILE}${RESET}"

    # --- VENV COM VERSÕES FIXADAS (RECRIA SE INCOMPLETO) ---
    if ! /opt/XrayTools/venv/bin/python -m pip --version >/dev/null 2>&1; then
        rm -rf /opt/XrayTools/venv
        python3 -m venv /opt/XrayTools/venv
    fi
    echo "Instalando dependencias Python..."
    /opt/XrayTools/venv/bin/python -m pip install --quiet --no-cache-dir \
        "python-telegram-bot==20.7" \
        "requests==2.31.0" >>"$LOG_FILE" 2>&1

    # A conta do serviço pode ler a aplicação e executar o interpretador.
    chmod -R g+rX /opt/XrayTools/venv
    chgrp -R botxray /opt/XrayTools/venv
    # --- SYSTEMD SERVICE ---
    cat > /etc/systemd/system/botxray.service << SVCEOF
[Unit]
Description=TURBONET XRAY Telegram Bot
After=network.target

[Service]
Type=simple
User=botxray
Group=botxray

WorkingDirectory=/opt/XrayTools
EnvironmentFile=/opt/XrayTools/.bot_env
ExecStart=/opt/XrayTools/venv/bin/python /etc/vps-manager/core/xray/botxray.py
Restart=always
RestartSec=10
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable  botxray >/dev/null 2>&1 || true
    systemctl restart botxray >/dev/null 2>&1 || true

    echo ""
    if _wait_service_active botxray; then
        echo -e "${VERDE}BOT ATIVADO COM SUCESSO!${RESET}"
    else
        echo -e "${AMARELO}Bot pode nao estar ativo. Verifique os logs.${RESET}"
    fi

    echo ""
    read -rp "Pressione ENTER para voltar ao Gerenciador..."
}

# ==========================================
# FUNÇÕES DE GERENCIAMENTO
# ==========================================
func_start_bot() {
    echo -e "\nIniciando o Bot..."
    systemctl enable botxray >/dev/null 2>&1 || true
    systemctl start  botxray >/dev/null 2>&1 || true
    if _wait_service_active botxray; then
        echo -e "${VERDE}✅ Bot iniciado e rodando!${RESET}"
    else
        echo -e "${VERMELHO}❌ Falha ao iniciar o Bot. Verifique os logs.${RESET}"
    fi
    sleep 2
}

func_stop_bot() {
    echo -e "\nParando o Bot..."
    systemctl stop    botxray >/dev/null 2>&1 || true
    systemctl disable botxray >/dev/null 2>&1 || true
    sleep 1
    echo -e "${AMARELO}⛔ Bot desligado e desativado da inicialização.${RESET}"
    sleep 2
}

func_view_logs() {
    clear
    echo -e "${AZUL}==================================================${RESET}"
    echo -e "${AMARELO}   LOGS DO BOT (AO VIVO) - Pressione CTRL+C    ${RESET}"
    echo -e "${AZUL}==================================================${RESET}"
    journalctl -u botxray -f || true
}

# ==========================================
# MENU PRINCIPAL DO GERENCIADOR
# ==========================================
while true; do
    clear
    echo -e "${AZUL}==================================================${RESET}"
    echo -e "${AMARELO}      GERENCIADOR DO BOT TELEGRAM V1.3.5      ${RESET}"
    echo -e "${AZUL}==================================================${RESET}"

    status_msg="${VERMELHO}NÃO INSTALADO${RESET}"
    if [ -f /etc/systemd/system/botxray.service ]; then
        if systemctl is-active --quiet botxray 2>/dev/null; then
            status_msg="${VERDE}ATIVO E RODANDO${RESET}"
        else
            status_msg="${VERMELHO}PARADO / DESATIVADO${RESET}"
        fi
    fi

    echo -e " STATUS DO BOT: ${status_msg}"
    echo -e "${AZUL}==================================================${RESET}"
    echo -e " ${VERDE}[1]${RESET} INSTALAR OU ATUALIZAR BOT"
    echo -e " ${VERDE}[2]${RESET} LIGAR BOT"
    echo -e " ${VERDE}[3]${RESET} DESLIGAR BOT"
    echo -e " ${VERDE}[4]${RESET} VER LOGS EM TEMPO REAL"
    echo -e " ${VERMELHO}[0]${RESET} VOLTAR AO MENU PRINCIPAL"
    echo -e "${AZUL}==================================================${RESET}"

    read -r -p "Escolha uma opção: " opt || true
    case "${opt:-}" in
        1) func_install_bot ;;
        2) func_start_bot ;;
        3) func_stop_bot ;;
        4) func_view_logs ;;
        0) exit 0 ;;
        *) echo -e "${VERMELHO}Opção inválida!${RESET}"; sleep 1 ;;
    esac
done
