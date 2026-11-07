#!/bin/bash
# ==========================================
# AutoConfig: SSL + ( Payload / Directo )
# ==========================================
C_RED='\033[1;31m'; C_GREEN='\033[1;32m'; C_YELLOW='\033[1;33m'; C_CYAN='\033[1;36m'; C_NC='\033[0m'
C_ORANGE='\033[38;5;214m' # Naranja similar a la imagen

activar_autoconfig() {
    clear
    echo -e "${C_YELLOW}Verificando puertos 80 y 443...${C_NC}"
    
    # Liberar puertos si están ocupados por servicios viejos
    systemctl stop ws-python stunnel4 apache2 nginx > /dev/null 2>&1
    fuser -k 80/tcp > /dev/null 2>&1
    fuser -k 443/tcp > /dev/null 2>&1
    
    echo -e "${C_GREEN}Generando Proxy Python Dual en puerto 80...${C_NC}"
    mkdir -p /etc/vps-manager/proxy
    
    cat << 'EOF' > /etc/vps-manager/proxy/proxy.py
import socket
import threading
import subprocess

def get_user_expiration(username):
    try:
        chage_out = subprocess.check_output(f"chage -l {username}", shell=True, stderr=subprocess.STDOUT).decode('utf-8')
        for line in chage_out.split('\n'):
            if "Account expires" in line or "La cuenta caduca" in line:
                date_str = line.split(':')[1].strip()
                return date_str if date_str != "never" else "Ilimitado"
        return "Desconocido"
    except:
        return "No encontrado"

def handle_client(client_socket):
    try:
        raw_request = client_socket.recv(4096)
        if not raw_request:
            client_socket.close()
            return
        request_text = raw_request.decode('utf-8', errors='ignore')
        request_lower = request_text.lower()

        ssh_user = None
        for line in request_text.split('\r\n'):
            if line.lower().startswith('x-user:') or line.lower().startswith('ssh-user:'):
                ssh_user = line.split(':')[1].strip()
                break

        ssh_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ssh_socket.connect(('127.0.0.1', 22))

        if "upgrade: websocket" in request_lower:
            response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
            if ssh_user:
                exp_date = get_user_expiration(ssh_user)
                banner_html = (
                    f"<br><b><font color='#00FF00'>👤 Usuario : {ssh_user}</font></b><br>"
                    f"<b><font color='#FFFF00'>⏳ Expira  : {exp_date}</font></b><br>"
                    f"<b><font color='#00FFFF'>🛡️ Golbert VPS Premium</font></b><br><br>"
                )
                response += banner_html
        else:
            response = "HTTP/2.0 1299\r\nHost: survey.tigo.com\nContent-Length: 55555555\n\r\n"

        client_socket.sendall(response.encode('utf-8'))

        def transfer(src, dst):
            try:
                while True:
                    data = src.recv(8192)
                    if not data: break
                    dst.sendall(data)
            except:
                pass
            finally:
                try: src.close()
                except: pass
                try: dst.close()
                except: pass

        t1 = threading.Thread(target=transfer, args=(client_socket, ssh_socket))
        t2 = threading.Thread(target=transfer, args=(ssh_socket, client_socket))
        t1.daemon = True
        t2.daemon = True
        t1.start()
        t2.start()
    except:
        try: client_socket.close()
        except: pass

def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(('0.0.0.0', 80))
    server.listen(500) 
    while True:
        try:
            client, addr = server.accept()
            t = threading.Thread(target=handle_client, args=(client,))
            t.daemon = True
            t.start()
        except:
            continue

if __name__ == '__main__':
    main()
EOF

    cat << 'EOF' > /etc/systemd/system/ws-python.service
[Unit]
Description=Python Proxy Dual
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/vps-manager/proxy
ExecStart=/usr/bin/python3 /etc/vps-manager/proxy/proxy.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${C_GREEN}Configurando Certificado y Stunnel4 en puerto 443...${C_NC}"
    apt-get install stunnel4 -y > /dev/null 2>&1
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 -subj "/C=PE/ST=Lima/L=Lima/O=GolbertVPS/CN=golbertvps.net.pe" -keyout /etc/stunnel/stunnel.pem -out /etc/stunnel/stunnel.pem > /dev/null 2>&1
    
    cat << 'EOF' > /etc/stunnel/stunnel.conf
cert = /etc/stunnel/stunnel.pem
client = no
socket = a:SO_REUSEADDR=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[stunnel]
accept = 443
connect = 127.0.0.1:80
EOF

    sed -i 's/ENABLED=0/ENABLED=1/g' /etc/default/stunnel4

    systemctl daemon-reload
    systemctl enable ws-python stunnel4 >/dev/null 2>&1
    systemctl restart ws-python stunnel4

    echo -e "\n${C_GREEN}✅ AUTOCONFIGURACIÓN COMPLETADA.${C_NC}"
    echo -e " ${C_CYAN}▶️ Puerto SSL     : 443${C_NC}"
    echo -e " ${C_CYAN}▶️ Puerto Payload : 80${C_NC}"
    sleep 3
}

desactivar_autoconfig() {
    clear
    echo -e "${C_RED}Desactivando servicios SSL y Proxy...${C_NC}"
    systemctl stop ws-python stunnel4 > /dev/null 2>&1
    systemctl disable ws-python stunnel4 > /dev/null 2>&1
    echo -e "${C_GREEN}✅ Servicios desactivados correctamente.${C_NC}"
    sleep 2
}

while true; do
    clear
    # Verificación de estado para el menú
    if netstat -tuln | grep -qE ":443\b" && netstat -tuln | grep -qE ":80\b"; then
        estado_servicio="${C_GREEN}ACTIVO${C_NC}"
    else
        estado_servicio="${C_RED}INACTIVO${C_NC}"
    fi

    echo -e "${C_ORANGE}======================================================${C_NC}"
    echo -e "    ${C_CYAN}SSL + ( Payload / Directo )  |  $estado_servicio${C_NC}"
    echo -e "${C_ORANGE}======================================================${C_NC}"
    echo -e "      ${C_CYAN}SCRIPT REESTRUCTURA y AUTOCONFIGURACION${C_NC}"
    echo -e "${C_ORANGE}======================================================${C_NC}"
    echo -e "       ${C_NC}Requiere tener el puerto libre 443 y el 80${C_NC}"
    echo -e "${C_ORANGE}======================================================${C_NC}"
    echo -e ""
    echo -e " ${C_YELLOW}[1]${C_NC} ${C_NC}Activar AUTOCONFIG (Python + SSL)${C_NC}"
    echo -e " ${C_YELLOW}[2]${C_NC} ${C_NC}Desactivar (Payload+SSL)   |  ${C_YELLOW}[0]${C_NC} ${C_RED}Regresar${C_NC}"
    echo -e ""
    echo -e "${C_ORANGE}======================================================${C_NC}"
    read -p " Seleccione una opción [0-2]: " op_ssl

    case $op_ssl in
        1) activar_autoconfig ;;
        2) desactivar_autoconfig ;;
        0) break ;;
        *) echo -e "${C_RED}Opción inválida.${C_NC}" ; sleep 1 ;;
    esac
done
