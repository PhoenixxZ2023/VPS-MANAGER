#!/usr/bin/env bash
set -euo pipefail
base=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
manager=/etc/vps-manager
dest=$manager/hcr-v3
unit=/etc/systemd/system/hcr-server-v3.service

fail() { printf 'Erro: %s\n' "$*" >&2; exit 1; }
help() {
    cat <<'HELP'
HCR a partir da source • Linux
  bash hcr.sh compilar [arquivo-de-saída]
  sudo bash hcr.sh instalar [--port PORTA] [--target 127.0.0.1:22]
                            [--transport plain|tls|auto] [--tls-cert arquivo --tls-key arquivo]
  bash hcr.sh status

Instalar prepara uma instalação nova. TLS/auto podem usar o certificado do domínio
do VPS-MANAGER. Escolha uma porta TCP livre para a conexão direta.
HELP
}

build() (
    output=$(realpath -m -- "$1")
    compiler=${GO_BIN:-go}
    "$compiler" version 2>/dev/null | grep -q '^go version go' || fail 'Instale Go 1.26.3 ou superior, ou indique GO_BIN.'
    temp=$(mktemp "${output}.XXXXXX")
    trap 'rm -f -- "$temp"' EXIT
    cd "$base/hcrcustom"
    CGO_ENABLED=0 GOWORK=off GOPROXY=off "$compiler" build -mod=readonly -buildvcs=false -trimpath -o "$temp" ./cmd/hcr-server
    chmod 0755 "$temp"
    mv -fT -- "$temp" "$output"
    echo "Compilado: $output"
)

case "${1:-ajuda}" in
    compilar) shift; (( $# <= 1 )) || fail 'Informe somente um destino.'; build "${1:-$base/hcr-server}"; exit ;;
    status) exec systemctl status hcr-server-v3.service --no-pager ;;
    instalar) shift ;;
    ajuda|-h|--help) help; exit ;;
    *) help; exit 2 ;;
esac

[[ $(uname -s) == Linux && $EUID == 0 ]] || fail 'Execute instalar como root no Linux.'
port="" target=127.0.0.1:22 transport=plain cert= key=
while (( $# )); do
    (( $# >= 2 )) || fail "Falta o valor de $1"
    case "$1" in
        --port) port=$2 ;; --target) target=$2 ;; --transport) transport=$2 ;;
        --tls-cert) cert=$2 ;; --tls-key) key=$2 ;; *) fail "Opção desconhecida: $1" ;;
    esac
    shift 2
done
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
if [[ -z $port ]]; then
    read -rp 'Escolha a porta TCP do HCR (1–65535): ' port || fail 'Informe --port PORTA.'
fi
valid_port "$port" || fail 'Porta HCR inválida.'
[[ $target =~ ^([A-Za-z0-9._-]+|\[[0-9a-fA-F:]+\]):([0-9]+)$ ]] && valid_port "${target##*:}" || fail 'Destino SSH inválido.'
[[ $transport =~ ^(plain|auto|tls)$ ]] || fail 'Transporte inválido.'
[[ -d /run/systemd/system ]] || fail 'systemd precisa estar ativo.'
exec 9>/run/hcr-source-install.lock
flock -n 9 || fail 'Outra instalação HCR está em andamento.'
[[ ! -e $dest && ! -L $dest && ! -e $unit && ! -L $unit ]] || fail 'Já existe uma instalação HCR v3. Consulte o serviço antes de substituí-la.'
[[ $(systemctl show -p LoadState --value hcr-server-v3.service) == not-found ]] || fail 'A unidade hcr-server-v3 já existe.'
command -v ss >/dev/null || fail 'Instale iproute2 para verificar a porta.'
listeners=$(ss -H -ltn "sport = :$port")
[[ -z $listeners ]] || fail "Porta $port já ocupada. Escolha outra porta livre."
if [[ $transport != plain ]]; then
    if [[ -z $cert && -z $key && -r $manager/dominio ]]; then
        domain=$(<"$manager/dominio")
        [[ $domain =~ ^[A-Za-z0-9.-]+$ ]] || fail 'Domínio inválido.'
        cert=/etc/letsencrypt/live/$domain/fullchain.pem
        key=/etc/letsencrypt/live/$domain/privkey.pem
    fi
    [[ -s $cert && -s $key ]] || fail 'Informe o certificado e a chave para TLS.'
elif [[ -n $cert || -n $key ]]; then
    fail 'Use --transport tls ou auto para configurar um certificado.'
fi
for name in hcr3_port hcr3_target hcr3_transport; do
    [[ ! -e $manager/$name && ! -L $manager/$name ]] || fail "Já existe configuração $name."
done
install -d -m 0755 "$manager"
stage=$(mktemp -d "$manager/.hcr-source.XXXXXX")
activated=false
cleanup() {
    rc=$?
    trap - EXIT
    if (( rc != 0 )) && [[ $activated == true ]]; then
        systemctl disable --now hcr-server-v3.service >/dev/null 2>&1 || true
        rm -f -- "$unit" "$manager/hcr3_port" "$manager/hcr3_transport" "$manager/hcr3_target"
        rm -rf -- "$dest"
        systemctl daemon-reload || true
    fi
    rm -rf -- "$stage"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
case $(uname -m) in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) arch=other ;; esac
if [[ -f $base/bin/hcr-server-$arch ]]; then
    (cd "$base/bin" && sha256sum -c "hcr-server-$arch.sha256")
    install -m 0755 "$base/bin/hcr-server-$arch" "$stage/hcr-server"
else
    build "$stage/hcr-server"
fi
"$stage/hcr-server" -version
install -m 0755 "$base/servico.sh" "$stage/install.sh"
if [[ $transport != plain ]]; then
    ln -s -- "$(realpath -s -- "$cert")" "$stage/fullchain.pem"
    ln -s -- "$(realpath -s -- "$key")" "$stage/privkey.pem"
fi
chmod 0755 "$stage"
mv -T -- "$stage" "$dest"
activated=true
bash "$dest/install.sh" --port "$port" --transport "$transport" --target "$target"
printf '%s\n' "$port" > "$manager/hcr3_port"
printf '%s\n' "$transport" > "$manager/hcr3_transport"
printf '%s\n' "$target" > "$manager/hcr3_target"
echo "HCR ativo na porta $port ($transport), destino SSH $target."
