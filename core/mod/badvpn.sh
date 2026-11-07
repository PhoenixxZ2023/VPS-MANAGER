#!/bin/bash
# VPS-MANAGER-MODULE: badvpn
# Modulo cargado con "source" por menu.sh (usar_modulo). No ejecutar directamente.

# ==========================================
# INSTALADOR BADVPN (3 PUERTOS)
# ==========================================
instalar_badvpn() {
    clear
    echo -e "${C_NEON_BLUE}╔══════════════════════════════════════════════╗${C_RST}"
    echo -e "${C_NEON_BLUE} ${C_NEON_GREEN}      🎮 INSTALADOR BADVPN (3 PUERTOS)        ${C_NEON_BLUE} ${C_RST}"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  Se instalará BadVPN UDP Gateway en los puertos:"
    echo -e "  ${C_NEON_YELLOW}• 7100${C_RST} - BadVPN Game 1"
    echo -e "  ${C_NEON_YELLOW}• 7200${C_RST} - BadVPN Game 2"
    echo -e "  ${C_NEON_YELLOW}• 7300${C_RST} - BadVPN Game 3"
    echo -e "${C_NEON_BLUE}╠══════════════════════════════════════════════╣${C_RST}"
    echo -e "  ${C_NEON_YELLOW}1.${C_RST} 🚀 Instalar / Reinstalar BadVPN"
    echo -e "  ${C_NEON_YELLOW}2.${C_RST} ⏹️ Detener y Desinstalar BadVPN"
    echo -e "  ${C_RED}0.${C_RST} 🔙 Volver al Menú Anterior"
    echo -e "${C_NEON_BLUE}╚══════════════════════════════════════════════╝${C_RST}"
    read -p "Seleccione una opción: " badvpn_opt

    case $badvpn_opt in
        1)
            echo -e "${C_YELLOW}[+] Instalando dependencias...${C_RST}"
            apt update -y >/dev/null 2>&1
            apt install -y cmake g++ make git screen >/dev/null 2>&1
            
            cd /tmp
            rm -rf badvpn badvpn-build
            git clone https://github.com/ambrop72/badvpn.git >/dev/null 2>&1
            mkdir -p badvpn-build
            cd badvpn-build
            cmake ../badvpn -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/dev/null 2>&1
            make install >/dev/null 2>&1

            echo -e "${C_YELLOW}[+] Configurando servicios para los 3 puertos...${C_RST}"
            
            for port in 7100 7200 7300; do
                cat > /etc/systemd/system/badvpn-${port}.service << EOF
[Unit]
Description=BadVPN UDPGW Port $port
After=network.target

[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:$port --max-clients 500 --max-connections-for-client 20
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
            done
            
            systemctl daemon-reload
            systemctl enable badvpn-7100 badvpn-7200 badvpn-7300 >/dev/null 2>&1
            systemctl restart badvpn-7100 badvpn-7200 badvpn-7300

            echo -e "${C_GREEN}[✔] ¡BadVPN configurado y activo en puertos 7100, 7200 y 7300!${C_RST}"
            read -p "Presione Enter para regresar..."
            ;;
        2)
            echo -e "${C_YELLOW}[+] Deteniendo y desinstalando BadVPN...${C_RST}"
            for port in 7100 7200 7300; do
                systemctl stop badvpn-${port}.service 2>/dev/null
                systemctl disable badvpn-${port}.service 2>/dev/null
                rm -f /etc/systemd/system/badvpn-${port}.service
            done
            systemctl daemon-reload
            echo -e "${C_GREEN}[✔] BadVPN desinstalado correctamente.${C_RST}"
            read -p "Presione Enter para continuar..."
            ;;
        0) return ;;
        *) echo -e "${C_RED}[!] Opción inválida.${C_RST}"; sleep 1 ;;
    esac
}
