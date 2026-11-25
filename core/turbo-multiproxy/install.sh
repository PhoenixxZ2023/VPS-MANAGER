#!/usr/bin/env bash
set -eu
cd -- "$(dirname -- "$0")"
unit=/etc/systemd/system/turbo-multiproxy.service
config=/etc/turbo-multiproxy.conf
exec 9>/run/turbo-multiproxy-install.lock
flock -n 9 || exit 1
[[ ! -e $unit && ! -e $config ]] || { echo "Já instalado."; exit 1; }
echo "Ative antes os destinos BHTTP e WebSocket em portas próprias."
read -rp "Porta pública do TURBO MULTIPROXY: " port
read -rp "Porta local do servidor BHTTP: " bhttp
read -rp "Porta local do servidor WebSocket: " ws
read -rp "Caminho WebSocket [/ws]: " path
path=${path:-/ws}
for p in "$port" "$bhttp" "$ws"; do
    [[ $p =~ ^[1-9][0-9]{0,4}$ ]] && ((p <= 65535)) || { echo "Porta inválida."; exit 1; }
done
[[ $port != "$bhttp" && $port != "$ws" && $bhttp != "$ws" ]] || { echo "Escolha três portas distintas."; exit 1; }
[[ $path =~ ^/[a-zA-Z0-9._~/-]*$ ]] || { echo "Caminho WebSocket inválido."; exit 1; }
listeners=$(ss -H -ltn "sport = :$port")
[[ -z $listeners ]] || { echo "Porta pública ocupada."; exit 1; }
for p in "$bhttp" "$ws"; do
    if ! (echo -n > "/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
        echo "O destino local na porta $p precisa estar ativo."; exit 1
    fi
done
rollback() {
    systemctl disable --now turbo-multiproxy.service 2>/dev/null || true
    rm -f "$config" "$unit"
    systemctl daemon-reload || true
}
trap rollback ERR
printf 'PORT=%s\nBHTTP=%s\nWS=%s\nWS_PATH=%s\n' "$port" "$bhttp" "$ws" "$path" > "$config"
install -m 0644 turbo-multiproxy.service "$unit"
systemctl daemon-reload
systemctl enable --now turbo-multiproxy.service
for attempt in {1..25}; do
    pid=$(systemctl show -p MainPID --value turbo-multiproxy.service)
    sockets=$(ss -H -ltnp "sport = :$port")
    if [[ $pid =~ ^[1-9][0-9]*$ && $sockets == *"pid=$pid,"* ]]; then
        echo "TURBO MULTIPROXY ativo na porta TCP $port."; exit 0
    fi
    sleep 0.2
done
echo "Falha ao iniciar o serviço."; false
