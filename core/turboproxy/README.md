# TURBOProxy VPN

Servidor BHTTP independente para Linux com systemd. Recebe conexões na porta TCP escolhida e encaminha as sessões para o SSH em 127.0.0.1. A autenticação utiliza as contas do SSH da VPS. Pode rodar diretamente, sem HAProxy.

## Publicar e instalar

Extraia o ZIP e envie todos os arquivos para a raiz do seu repositório, incluindo a pasta `bin/`. Ela contém os executáveis Linux AMD64 e ARM64 e suas somas SHA-256. O instalador usa esses arquivos locais. Você pode escolher qualquer nome de repositório.

Na VPS, com o SSH já funcionando, clone o seu repositório e execute:

```sh
git clone https://github.com/SEU-USUARIO/SEU-REPOSITORIO.git turboproxy-vpn
cd turboproxy-vpn
sudo bash install.sh
```

Substitua o endereço pelo do seu repositório. Informe a porta pública do BHTTP e a porta do SSH local. Para instalação sem perguntas, por exemplo na porta 8080 com SSH na 22:

```sh
sudo bash install.sh 8080 22
```

Libere a porta BHTTP TCP escolhida no firewall da VPS e no painel do provedor, caso use filtragem de entrada. No aplicativo, selecione o modo BHTTP, use o endereço público da VPS, a porta BHTTP e as credenciais SSH.

## Administrar

```sh
systemctl status turboproxy.service
sudo journalctl -u turboproxy.service -f
sudo systemctl restart turboproxy.service
```

Para trocar portas, confira a disponibilidade da nova porta com `ss -ltn`, edite `/etc/turboproxy/portas.conf` e reinicie o serviço. Ajuste as regras de firewall correspondentes. A reinicialização encerra as sessões em andamento.

## Recompilar

Com o compilador Go 1.19 ou superior, execute `bash build.sh`. O script compila `server.go` para as duas arquiteturas e atualiza `bin/SHA256SUMS`. Envie os artefatos atualizados junto com o fonte. O instalador verifica as somas e roda o autoteste do motor antes de instalar.

## Origem e compatibilidade

Motor derivado de SuperFlash BHTTP 2.4.1-btun-compat-keepalive, revisão `a02aa119da5c232f543378a5e504747faa82cf7c` de [apksdemons/BHTTP](https://github.com/apksdemons/BHTTP). A negociação BHP1 e o encaminhamento de dados seguem o fonte dessa revisão.

Na VPS de teste, valide separadamente o Bilola Tunnel e o DTunnel original com login SSH, tráfego nos dois sentidos e reconexão após queda. A integração planejada no VPS-MANAGER é a quarta opção do menu BHTTP. Este pacote é instalado separadamente.
