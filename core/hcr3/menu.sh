#!/usr/bin/env bash
set -u
base=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
manager=/etc/vps-manager
unit=hcr-server-v3.service
dest=$manager/hcr-v3

prepare_binary() (
    local arch repo tmp
    case $(uname -m) in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) echo 'Os binários incluídos são para Linux AMD64 e ARM64.'; exit 1 ;;
    esac
    cd "$base/bin" || exit 1
    if sha256sum -c "hcr-server-$arch.sha256" >/dev/null 2>&1; then exit 0; fi
    repo=$(cat "$base/repo-url") || exit 1
    tmp=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$tmp"' EXIT
    curl -fLsS --retry 2 -o "$tmp/hcr-server-$arch" "$repo/core/hcr3/bin/hcr-server-$arch" &&
        (cd "$tmp" && sha256sum -c "$base/bin/hcr-server-$arch.sha256") &&
        install -m 0755 "$tmp/hcr-server-$arch" "hcr-server-$arch"
)

while true; do
    estado=$(systemctl is-active "$unit" 2>/dev/null)
    [[ -f "$dest/hcr-server" ]] || estado="não instalado"
    printf '\nHCR 3.0 • %s\n' "$estado"
    if [[ -r "$manager/hcr3_port" ]]; then
        printf 'Porta %s • %s • SSH %s\n' "$(<"$manager/hcr3_port")" "$(<"$manager/hcr3_transport")" "$(<"$manager/hcr3_target")"
    fi
    printf '%s\n' '1. Instalar' '2. Iniciar ou reiniciar' '3. Parar' '4. Ver logs' '5. Desinstalar' '0. Voltar'
    read -rp 'Opção: ' choice || exit
    case $choice in
        1)
            while true; do
                read -rp 'Escolha a porta TCP do HCR (1–65535, ex. 80 ou 8080): ' port || exit
                [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$port <= 65535 )) && break
                echo 'Informe uma porta válida.'
            done
            read -rp 'Transporte plain/tls/auto [plain]: ' transport || exit
            read -rp 'Destino SSH [127.0.0.1:22]: ' target || exit
            prepare_binary && bash "$base/hcr.sh" instalar --port "$port" --transport "${transport:-plain}" --target "${target:-127.0.0.1:22}"
            ;;
        2) systemctl restart "$unit" ;;
        3) systemctl stop "$unit" ;;
        4) journalctl -u "$unit" -n 40 --no-pager ;;
        5)
            [[ -x "$dest/install.sh" ]] || { echo 'HCR 3.0 ainda não foi instalado.'; continue; }
            read -rp 'Remover o serviço HCR 3.0? [s/N] ' confirm || exit
            if [[ $confirm =~ ^[sS]$ ]]; then
                if [[ -f "$dest/shared-port" ]]; then
                    python3 "$base/haproxy_route.py" /etc/haproxy/haproxy.cfg remove --live || continue
                fi
                bash "$dest/install.sh" --uninstall &&
                    rm -rf -- "$dest" &&
                    rm -f -- "$manager/hcr3_port" "$manager/hcr3_transport" "$manager/hcr3_target"
            fi
            ;;
        0) exit 0 ;;
        *) echo 'Opção inválida.' ;;
    esac
done
