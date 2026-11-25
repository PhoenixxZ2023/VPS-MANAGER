#!/usr/bin/env bash
set -u
manager=/etc/vps-manager
dest=$manager/dtunnel
unit=bhttp-dtunnel.service
unit_path=/etc/systemd/system/$unit
router=$manager/core/hcr3/haproxy_route.py
cfg=/etc/haproxy/haproxy.cfg
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }

install_dtunnel() (
    set -e
    exec 9>/run/bhttp-dtunnel-install.lock
    flock -n 9 || { echo 'Outra instalação em andamento.'; exit 1; }
    if [[ -e $dest || -e $unit_path || $(systemctl show -p LoadState --value "$unit") != not-found ]]; then
        echo 'BHTTP DTunnel já instalado.'; exit 1
    fi
    read -rp 'Porta TCP pública do BHTTP DTunnel: ' port
    valid_port "$port" || { echo 'Porta inválida.'; exit 1; }
    read -rp 'Porta do SSH em 127.0.0.1 [22]: ' ssh
    ssh=${ssh:-22}
    valid_port "$ssh" && [[ $port != "$ssh" ]] || { echo 'Porta SSH inválida ou igual à porta pública.'; exit 1; }
    occupied=$(ss -Hltn "sport = :$port")
    [[ -z $occupied ]] || { echo "Porta $port já ocupada. Escolha outra porta livre."; exit 1; }
    mkdir "$dest"
    rollback() {
        rc=$?
        if (( rc )); then
            systemctl disable --now "$unit" >/dev/null 2>&1 || true
            rm -f "$unit_path" "$dest/port" "$dest/shared-port"
            rmdir "$dest" || true
            systemctl daemon-reload
        fi
    }
    trap rollback EXIT
    printf '%s\n' "$port" > "$dest/port"
    cat > "$unit_path" <<UNIT
[Unit]
Description=BHTTP DTunnel para SSH
After=network.target
[Service]
ExecStart=/usr/bin/python3 -B $manager/core/dtunnel/server.py 0.0.0.0 $port --ssh-port $ssh
DynamicUser=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now "$unit"
    sleep 1
    systemctl is-active --quiet "$unit"
    echo "BHTTP DTunnel ativo na porta $port."
)

while true; do
    printf '\nBHTTP DTunnel • %s\n' "$(systemctl is-active "$unit" 2>/dev/null)"
    [[ ! -r $dest/port ]] || printf 'Porta pública: %s\n' "$(<"$dest/port")"
    printf '%s\n' '1. Instalar' '2. Iniciar ou reiniciar' '3. Parar' '4. Ver logs' '5. Desinstalar' '0. Voltar'
    read -rp 'Opção: ' choice || exit
    case $choice in
        1) install_dtunnel ;;
        2) systemctl restart "$unit" ;;
        3) systemctl stop "$unit" ;;
        4) journalctl -u "$unit" -n 40 --no-pager ;;
        5)
            [[ -f $unit_path && -f $dest/port ]] || { echo 'Serviço não instalado.'; continue; }
            read -rp 'Remover BHTTP DTunnel? [s/N] ' answer || exit
            [[ $answer =~ ^[sS]$ ]] || continue
            if [[ -f $dest/shared-port ]]; then python3 "$router" "$cfg" remove --live --protocol dtunnel || continue; fi
            systemctl disable --now "$unit" && rm -f "$unit_path" "$dest/port" "$dest/shared-port" && rmdir "$dest" && systemctl daemon-reload ;;
        0) exit 0 ;;
        *) echo 'Opção inválida.' ;;
    esac
done
