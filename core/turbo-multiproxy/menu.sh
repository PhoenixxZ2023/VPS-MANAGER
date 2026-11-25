#!/usr/bin/env bash
cd -- "$(dirname -- "$0")" || exit 1
case "${1:-multi}" in
    multi) name="TURBO MULTIPROXY"; unit=turbo-multiproxy; config=/etc/turbo-multiproxy.conf; installer=./install.sh ;;
    vpn) name="TURBOProxy-VPN"; unit=turboproxy; config=/etc/turboproxy/portas.conf; installer=../turboproxy/install.sh ;;
    *) exit 1 ;;
esac
while true; do
    printf '\n%s | %s\n' "$name" "$(systemctl is-active "$unit" 2>/dev/null)"
    [[ ! -f $config ]] || cat "$config"
    printf '1. Instalar\n2. Iniciar ou reiniciar\n3. Parar\n4. Ver log\n0. Voltar\n'
    read -rp "Opção: " choice || exit 0
    case $choice in
        1) bash "$installer" ;;
        2) systemctl restart "$unit" ;;
        3) systemctl stop "$unit" ;;
        4) journalctl -u "$unit" -n 30 --no-pager ;;
        0) exit 0 ;;
        *) echo "Opção inválida." ;;
    esac
done
