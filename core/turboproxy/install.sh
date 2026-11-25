#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
die() { echo "$*" >&2; exit 1; }
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
(( EUID == 0 )) || die "Execute com sudo."
(( $# <= 2 )) || die "Uso: bash install.sh [porta-bhttp [porta-ssh]]"
[[ -d /run/systemd/system ]] || die "Este instalador requer systemd ativo."
for command in ss flock sha256sum systemctl; do
  command -v "$command" >/dev/null || die "Comando necessário: $command"
done
exec 9>/run/turboproxy-install.lock
flock -n 9 || die "Outra instalação está em andamento."
unit=/etc/systemd/system/turboproxy.service
binary=/usr/local/bin/turboproxy
config=/etc/turboproxy/portas.conf
for path in "$unit" "$binary" "$config"; do
  [[ ! -e $path && ! -L $path ]] || die "Já existe $path. Para alterar portas, consulte o README."
done
case $(uname -m) in
  x86_64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "Arquitetura sem binário neste pacote." ;;
esac
(cd bin && sha256sum -c SHA256SUMS)
source_bin="bin/turboproxy-linux-$arch"
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
install -m 755 "$source_bin" "$temp/turboproxy"
"$temp/turboproxy" -self-test
port=${1:-}
ssh_port=${2:-}
if [[ -z $port ]]; then read -rp "Porta pública do BHTTP (ex. 80 ou 8080): " port; fi
if [[ -z $ssh_port && -t 0 ]]; then read -rp "Porta do SSH local [22]: " ssh_port; fi
ssh_port=${ssh_port:-22}
valid_port "$port" && valid_port "$ssh_port" || die "Use portas entre 1 e 65535."
[[ $port != "$ssh_port" ]] || die "Escolha portas diferentes para BHTTP e SSH."
listeners=$(ss -H -ltn "sport = :$port")
[[ -z $listeners ]] || die "A porta TCP $port está ocupada."
printf 'BHTTP_PORT=%s\nSSH_PORT=%s\n' "$port" "$ssh_port" > "$temp/portas.conf"
rollback() {
  systemctl disable --now turboproxy.service >/dev/null 2>&1 || true
  rm -f -- "$unit" "$binary" "$config"
  systemctl daemon-reload || true
}
trap 'rollback' ERR
install -D -m 755 "$temp/turboproxy" "$binary"
install -D -m 644 "$temp/portas.conf" "$config"
install -m 644 turboproxy.service "$unit"
systemctl daemon-reload
systemctl enable --now turboproxy.service
ready=false
for attempt in {1..20}; do
  pid=$(systemctl show -p MainPID --value turboproxy.service)
  sockets=$(ss -H -ltnp "sport = :$port")
  if [[ $pid =~ ^[1-9][0-9]*$ && $sockets == *"pid=$pid,"* ]]; then ready=true; break; fi
  sleep 0.25
done
if [[ $ready != true ]]; then
  journalctl -u turboproxy.service -n 10 --no-pager >&2 || true
  echo "Falha ao abrir a porta. Revertendo instalação." >&2
  false
fi
trap - ERR
echo "TURBOProxy VPN ativo na porta TCP $port, usando SSH local na porta $ssh_port."
