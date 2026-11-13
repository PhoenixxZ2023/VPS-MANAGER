#!/bin/bash
# ==========================================
# Módulo Unificado: SSL / TLS Proxy 
# Suporte para Stunnel4 (Apt) e Stunnel5 (Compilado/Turbo)
# ==========================================
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[1;36m'
C_WHITE='\033[1;37m'
C_NC='\033[0m'

# ==========================================
# FUNÇÕES GERAIS
# ==========================================
verificar_porta() {
    local port=$1
    if ss -lntp 2>/dev/null | grep -q ":$port " || netstat -nltp 2>/dev/null | grep -q ":$port "; then
        echo -e "\n${C_RED}[!] Erro: A porta $port já está em uso por outro serviço!${C_NC}"
        sleep 3
        return 1
    fi
    return 0
}

# ==========================================
# MÓDULO STUNNEL 4
# ==========================================
s4_install() {
    clear
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e "${C_GREEN}       INSTALADOR SSL / TLS (STUNNEL4)          ${C_NC}"
    echo -e "${C_CYAN}================================================${C_NC}"

    read -p "Digite a porta para o SSL/TLS [Padrão 444]: " INPUT_PORT
    SSL_PORT=${INPUT_PORT:-444}

    verificar_porta "$SSL_PORT" || return

    mkdir -p /etc/vps-manager
    echo "$SSL_PORT" > /etc/vps-manager/ssl_port
    SSL_DIR="/etc/stunnel"

    echo -e "${C_YELLOW}[+] Instalando Stunnel4 e utilitários...${C_NC}"
    apt update -y >/dev/null 2>&1
    apt install -y stunnel4 iptables ufw openssl >/dev/null 2>&1

    echo -e "${C_YELLOW}[+] Configurando Regras de Roteamento (Stunnel4)...${C_NC}"
    cat << EOF > $SSL_DIR/stunnel.conf
pid = /var/run/stunnel.pid
cert = $SSL_DIR/stunnel.pem
client = no
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-tls]
accept = $SSL_PORT
connect = 127.0.0.1:22
EOF

    sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4

    if [ ! -f "$SSL_DIR/stunnel.pem" ]; then
        echo -e "${C_YELLOW}[+] Gerando Certificado SSL Local Provisório...${C_NC}"
        openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
            -subj "/C=BR/ST=SP/L=SaoPaulo/O=VPS/CN=localhost" \
            -keyout $SSL_DIR/stunnel.pem -out $SSL_DIR/stunnel.pem >/dev/null 2>&1
        chmod 600 $SSL_DIR/stunnel.pem
    fi

    echo -e "${C_YELLOW}[+] Abrindo porta $SSL_PORT no Firewall...${C_NC}"
    iptables -D INPUT -p tcp --dport $SSL_PORT -j ACCEPT 2>/dev/null
    iptables -I INPUT -p tcp --dport $SSL_PORT -j ACCEPT
    iptables-save > /etc/iptables.up.rules 2>/dev/null
    ufw allow ${SSL_PORT}/tcp >/dev/null 2>&1

    echo -e "${C_YELLOW}[+] Iniciando Serviço SSL/TLS...${C_NC}"
    systemctl restart stunnel4
    systemctl enable stunnel4 >/dev/null 2>&1

    IP_VPS=$(curl -s ipv4.icanhazip.com)
    DOM=$( [ -f /etc/vps-manager/dominio ] && cat /etc/vps-manager/dominio || echo "$IP_VPS" )

    clear
    echo -e "${C_GREEN}[✔] Stunnel4 instalado e configurado com sucesso!${C_NC}"
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e " 🌐 Host / Domínio : ${C_YELLOW}$DOM${C_NC}"
    echo -e " 🎯 Porta SSL/TLS  : ${C_YELLOW}$SSL_PORT${C_NC}"
    echo -e " ⚡ Destino Proxy  : ${C_YELLOW}SSH Local (127.0.0.1:22)${C_NC}"
    echo -e "${C_CYAN}================================================${C_NC}"
    read -p "Pressione Enter para voltar ao menu..."
}

s4_change_port() {
    clear
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e "${C_GREEN}            ALTERAR PORTA STUNNEL 4             ${C_NC}"
    echo -e "${C_CYAN}================================================${C_NC}"
    
    if [ ! -f "/etc/vps-manager/ssl_port" ] || [ ! -f "/etc/stunnel/stunnel.conf" ]; then
        echo -e "${C_RED}[!] O serviço Stunnel4 não parece estar instalado.${C_NC}"
        read -p "Pressione Enter para voltar..."
        return
    fi

    OLD_PORT=$(cat /etc/vps-manager/ssl_port)
    echo -e "Porta atual: ${C_YELLOW}$OLD_PORT${C_NC}"
    read -p "Digite a nova porta: " NEW_PORT

    if [[ -z "$NEW_PORT" || "$NEW_PORT" == "$OLD_PORT" ]]; then
        echo -e "${C_RED}[!] Porta inválida ou igual a atual.${C_NC}"
        sleep 2; return
    fi

    verificar_porta "$NEW_PORT" || return

    echo -e "${C_YELLOW}[+] Atualizando configuração...${C_NC}"
    sed -i "s/accept = $OLD_PORT/accept = $NEW_PORT/g" /etc/stunnel/stunnel.conf
    echo "$NEW_PORT" > /etc/vps-manager/ssl_port

    iptables -D INPUT -p tcp --dport $OLD_PORT -j ACCEPT 2>/dev/null
    ufw delete allow ${OLD_PORT}/tcp >/dev/null 2>&1
    iptables -I INPUT -p tcp --dport $NEW_PORT -j ACCEPT
    iptables-save > /etc/iptables.up.rules 2>/dev/null
    ufw allow ${NEW_PORT}/tcp >/dev/null 2>&1

    systemctl restart stunnel4
    echo -e "${C_GREEN}[✔] Porta alterada com sucesso de $OLD_PORT para $NEW_PORT.${C_NC}"
    read -p "Pressione Enter para voltar..."
}

s4_uninstall() {
    clear
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e "${C_RED}              DESINSTALAR STUNNEL 4             ${C_NC}"
    echo -e "${C_CYAN}================================================${C_NC}"
    
    read -p "Tem certeza que deseja remover o Stunnel4? (s/n): " CONFIRM
    if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
        echo -e "${C_YELLOW}Operação cancelada.${C_NC}"
        sleep 2; return
    fi

    if [ -f "/etc/vps-manager/ssl_port" ]; then
        OLD_PORT=$(cat /etc/vps-manager/ssl_port)
        iptables -D INPUT -p tcp --dport $OLD_PORT -j ACCEPT 2>/dev/null
        ufw delete allow ${OLD_PORT}/tcp >/dev/null 2>&1
    fi

    systemctl stop stunnel4 >/dev/null 2>&1
    systemctl disable stunnel4 >/dev/null 2>&1
    apt-get purge stunnel4 -y >/dev/null 2>&1
    
    rm -rf /etc/stunnel
    rm -f /etc/vps-manager/ssl_port

    echo -e "${C_GREEN}[✔] Stunnel4 removido com sucesso.${C_NC}"
    read -p "Pressione Enter para voltar..."
}

# ==========================================
# MÓDULO STUNNEL 5 (TURBO / COMPILADO)
# ==========================================
s5_install() {
    clear
    echo -e "\E[44;1;37m          INSTALADOR SSL STUNNEL5 (TURBO)         \E[0m"
    echo ""
    echo -e "${C_RED}[${C_CYAN}1${C_RED}] ${C_WHITE}• ${C_YELLOW}SSL PADRÃO (Direto SSH)${C_NC}"
    echo -e "${C_RED}[${C_CYAN}2${C_RED}] ${C_WHITE}• ${C_YELLOW}SSL WEBSOCKET (Cloudflare)${C_NC}"
    echo -e "${C_RED}[${C_CYAN}0${C_RED}] ${C_WHITE}• ${C_YELLOW}VOLTAR${C_NC}"
    echo ""
    echo -ne "${C_GREEN}QUAL O MODO DE CONEXÃO DESEJADO${C_YELLOW}? ${C_WHITE}"
    read -r resposta

    case "$resposta" in
        '1') portssl='22'; ws_mod="false" ;;
        '2') portssl='80'; ws_mod="true" ;;
        '0') return ;;
        *) echo -e "\n${C_RED}Opção inválida!${C_NC}"; sleep 2; return ;;
    esac

    echo -e "\n${C_YELLOW}DEFINA UMA PORTA PARA O STUNNEL5 ESCUTAR${C_NC}"
    read -p "$(echo -e '${C_GREEN}Qual porta deseja utilizar? (Padrão 443) ${C_WHITE}')" -e -i 443 porta
    
    if [[ -z "$porta" || ! "$porta" =~ ^[0-9]+$ ]]; then
        echo -e "\n${C_RED}Porta inválida!${C_NC}"; sleep 2; return
    fi
    verificar_porta "$porta" || return
    
    echo -e "\n${C_GREEN}Atualizando pacotes e instalando dependências...${C_NC}"
    apt-get update -y > /dev/null 2>&1
    apt-get install -y git build-essential libssl-dev autoconf automake libtool m4 autoconf-archive pkg-config python3 net-tools > /dev/null 2>&1
    
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
    fi

    echo -e "${C_GREEN}Buscando, clonando e compilando a versão MAIS RECENTE do stunnel...${C_NC}"
    rm -rf /tmp/stunnel
    git clone https://github.com/mtrojnar/stunnel.git /tmp/stunnel > /dev/null 2>&1
    cd /tmp/stunnel || exit 1
    
    LATEST_TAG=$(git tag | grep '^stunnel-' | sort -V | tail -n 1)
    git checkout "tags/$LATEST_TAG" > /dev/null 2>&1
    
    aclocal > /dev/null 2>&1
    autoreconf -fi > /dev/null 2>&1
    ./configure > /dev/null 2>&1
    make > /dev/null 2>&1
    make install > /dev/null 2>&1
    mv /usr/local/bin/stunnel /usr/local/bin/stunnel5
    cd / && rm -rf /tmp/stunnel

    mkdir -p /usr/local/etc/stunnel
    cat > /usr/local/etc/stunnel/stunnel.conf <<EOF
cert = /usr/local/etc/stunnel/stunnel.pem
client = no
pid = 
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
TIMEOUTclose = 0

[stunnel5]
accept = ${porta}
connect = 127.0.0.1:${portssl}
options = NO_SSLv2
options = NO_SSLv3
EOF

    openssl req -new -x509 -days 3650 -nodes \
        -out /usr/local/etc/stunnel/stunnel.pem \
        -keyout /usr/local/etc/stunnel/stunnel.pem \
        -subj "/C=BR/ST=SP/L=SaoPaulo/O=Private/OU=IT/CN=localhost" > /dev/null 2>&1
    chmod 600 /usr/local/etc/stunnel/stunnel.pem

    if [[ "$ws_mod" == "true" ]]; then
        echo -e "${C_GREEN}Configurando Proxy WebSocket Systemd...${C_NC}"
        cat <<EOF > /usr/local/etc/stunnel/proxy_ws.py
import socket, threading
def forward(src, dst):
    try:
        while True:
            data = src.recv(8192)
            if not data: break
            dst.sendall(data)
    except: pass
    finally: src.close(); dst.close()
def handler(cl_sock):
    s_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s_sock.connect(('127.0.0.1', 22))
        threading.Thread(target=forward, args=(cl_sock, s_sock)).start()
        forward(s_sock, cl_sock)
    except: cl_sock.close()
server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(('0.0.0.0', 80))
server.listen(500)
while True:
    cl, addr = server.accept()
    threading.Thread(target=handler, args=(cl,)).start()
EOF
        cat <<EOF > /etc/systemd/system/proxy_ws.service
[Unit]
Description=Turbo Proxy WS
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/etc/stunnel/proxy_ws.py
Restart=always
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable proxy_ws > /dev/null 2>&1
        systemctl start proxy_ws
    fi

    cat > /etc/systemd/system/stunnel5.service <<EOF
[Unit]
Description=stunnel5 TLS Tunneling Service
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/stunnel5 /usr/local/etc/stunnel/stunnel.conf
Restart=always
TimeoutStartSec=300
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable stunnel5 > /dev/null 2>&1
    systemctl restart stunnel5

    echo -e "\n${C_GREEN}[✔] Stunnel5 instalado com sucesso na porta ${C_YELLOW}$porta${C_NC}"
    read -p "Pressione Enter para voltar ao menu..."
}

s5_change_port() {
    clear
    echo -e "\E[44;1;37m          ALTERAR PORTA STUNNEL 5         \E[0m"
    if [[ ! -f /etc/systemd/system/stunnel5.service ]]; then
        echo -e "\n${C_RED}[!] Stunnel5 não está instalado.${C_NC}"
        read -p "Pressione Enter para voltar..."
        return
    fi
    
    OLD_PORT=$(grep "accept =" /usr/local/etc/stunnel/stunnel.conf | awk '{print $3}')
    echo -e "\nPorta atual: ${C_YELLOW}$OLD_PORT${C_NC}"
    read -p "$(echo -e '${C_GREEN}Qual a nova porta? ${C_WHITE}')" porta
    
    if [[ -z "$porta" || ! "$porta" =~ ^[0-9]+$ || "$porta" == "$OLD_PORT" ]]; then
        echo -e "\n${C_RED}Porta inválida ou igual a atual!${C_NC}"; sleep 2; return
    fi
    verificar_porta "$porta" || return

    echo -e "\n${C_GREEN}Alterando porta...${C_NC}"
    sed -i "s/accept = .*/accept = $porta/" /usr/local/etc/stunnel/stunnel.conf
    systemctl restart stunnel5
    echo -e "${C_GREEN}[✔] Porta alterada com sucesso para $porta!${C_NC}"
    read -p "Pressione Enter para voltar..."
}

s5_uninstall() {
    clear
    echo -e "\E[44;1;37m          DESINSTALAR STUNNEL 5         \E[0m"
    read -p "Tem certeza que deseja remover o Stunnel5? (s/n): " CONFIRM
    if [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]]; then
        echo -e "${C_YELLOW}Operação cancelada.${C_NC}"
        sleep 2; return
    fi

    echo -e "\n${C_GREEN}Parando e removendo serviços...${C_NC}"
    systemctl stop stunnel5 > /dev/null 2>&1
    systemctl disable stunnel5 > /dev/null 2>&1
    systemctl stop proxy_ws > /dev/null 2>&1
    systemctl disable proxy_ws > /dev/null 2>&1
    
    rm -f /etc/systemd/system/stunnel5.service
    rm -f /etc/systemd/system/proxy_ws.service
    systemctl daemon-reload
    systemctl reset-failed
    
    rm -f /usr/local/bin/stunnel5
    rm -rf /usr/local/etc/stunnel

    echo -e "${C_GREEN}[✔] SSL STUNNEL5 E PROXY REMOVIDOS COM SUCESSO!${C_NC}"
    read -p "Pressione Enter para voltar..."
}

# ==========================================
# MENÚ PRINCIPAL UNIFICADO
# ==========================================
while true; do
    clear
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e "${C_GREEN}      GERENCIADOR SSL / TLS (STUNNEL 4 & 5)     ${C_NC}"
    echo -e "${C_CYAN}================================================${C_NC}"
    
    # Verifica status dos serviços
    ST4_STAT="${C_RED}Desligado${C_NC}"; ST5_STAT="${C_RED}Desligado${C_NC}"
    if systemctl is-active --quiet stunnel4; then ST4_STAT="${C_GREEN}Rodando${C_NC}"; fi
    if systemctl is-active --quiet stunnel5; then ST5_STAT="${C_GREEN}Rodando${C_NC}"; fi
    
    echo -e "  [ Stunnel4: $ST4_STAT ]   |   [ Stunnel5: $ST5_STAT ]"
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e "${C_WHITE}--- STUNNEL 4 (Versão APT / Estável) ---${C_NC}"
    echo -e "${C_YELLOW}[1]${C_NC} Instalar SSL Stunnel 4"
    echo -e "${C_YELLOW}[2]${C_NC} Alterar Porta Stunnel 4"
    echo -e "${C_YELLOW}[3]${C_NC} Desinstalar Stunnel 4"
    echo -e ""
    echo -e "${C_WHITE}--- STUNNEL 5 (Versão Compilada / Turbo) ---${C_NC}"
    echo -e "${C_YELLOW}[4]${C_NC} Instalar SSL Stunnel 5 (SSH/WS)"
    echo -e "${C_YELLOW}[5]${C_NC} Alterar Porta Stunnel 5"
    echo -e "${C_YELLOW}[6]${C_NC} Desinstalar Stunnel 5"
    echo -e "${C_CYAN}================================================${C_NC}"
    echo -e "${C_YELLOW}[0]${C_NC} Sair do Script"
    echo -e "${C_CYAN}================================================${C_NC}"
    read -p "Selecione uma opção: " OPCION

    case $OPCION in
        1) s4_install ;;
        2) s4_change_port ;;
        3) s4_uninstall ;;
        4) s5_install ;;
        5) s5_change_port ;;
        6) s5_uninstall ;;
        0) clear; exit 0 ;;
        *) echo -e "${C_RED}[!] Opção inválida.${C_NC}"; sleep 2 ;;
    esac
done
