# VPS-MANAGER

Painel de terminal para administrar contas SSH, conexões Xray e serviços de túnel em uma VPS Linux. Esta edição reúne o Core Manager do XRAY2026, o bot do Telegram, HCR 3.0, BHTTP DTunnel, TURBOProxy-VPN e TURBO MULTIPROXY. O comando de acesso ao painel é `menussh`.

## Instalação na VPS

Use uma VPS nova baseada em Debian ou Ubuntu, com Bash, apt, systemd e acesso à internet. Entre como root e execute **uma** das opções abaixo no terminal da VPS. Os componentes são baixados diretamente do repositório.

**Opção 1 — Instalação principal com wget**

```bash
wget -O install.sh https://raw.githubusercontent.com/PhoenixxZ2023/VPS-MANAGER/main/install.sh && bash install.sh
```

**Opção 2 — Instalação alternativa com curl**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/PhoenixxZ2023/VPS-MANAGER/main/install.sh)
```

O segundo comando usa Bash e chama o mesmo instalador principal. Após a instalação, para abrir o painel em uma nova sessão administrativa, digite:

```bash
menussh
```

## Guia do menu

A opção **2** do menu principal abre o gerenciador de instalações e protocolos.

| Caminho | Recurso | Uso |
|---|---|---|
| 2 → 1 | Core Manager do XRAY2026 | Configurar Xray e os transportes para os perfis VLESS. |
| 2 → 5 | HCR | Selecionar HCR v1, v2 ou v3. Na v3, escolher a porta para o HTTP Custom. |
| 2 → 8 → 1 ou 2 | BHTTP v1 ou v2 | Acessar as versões anteriores do BHTTP. |
| 2 → 8 → 3 | BHTTP DTunnel | Ativar o servidor BHTTP com encaminhamento ao SSH local. |
| 2 → 8 → 4 | TURBOProxy-VPN | Instalar o motor BHTTP 2.4.1 e escolher as portas de entrada e do SSH local. |
| 2 → 18 | TURBO MULTIPROXY | Compartilhar uma porta TCP entre BHTTP e WebSocket HTTP/1.1. |
| 2 → 19 | HAProxy + Xray | Administrar o encaminhamento avançado e consultar as rotas. |

## Contas SSH, Xray e Telegram

Ao criar uma conta SSH, informe nome, senha, validade em dias e limite de conexões. Com Xray habilitado, o painel permite criar também o acesso Xray e apresenta o UUID no resumo. O limite informado nesse fluxo se aplica ao SSH. Serviços HCR e BHTTP que encaminham ao SSH local usam a conta SSH da VPS. Um destino HCR remoto usa as credenciais desse destino.

Para configurar Xray e o bot:

1. Em **Ferramentas e Sistema → Gestor de Domínio**, informe o domínio que aponta para a VPS.
2. Abra **2 → 1 → Instalar/Configurar** e configure o transporte desejado, como WebSocket, gRPC ou XHTTP.
3. Em **Ferramentas e Sistema → Bot Telegram**, informe o token do BotFather e o ID numérico do administrador.
4. Em uma conversa privada com o bot, envie `/start`. Escolha **Criar SSH / conexões da VPS** ou **Criar somente Xray**.

## HCR e BHTTP em portas diretas

Para testar HCR 3.0 no HTTP Custom, abra **2 → 5 → 3**, selecione **Instalar** e escolha uma porta TCP livre. O destino padrão é o SSH local em `127.0.0.1:22`. No aplicativo, selecione SSH HCR, informe a porta pública e use as credenciais do destino. HCR v2 e v3 podem funcionar lado a lado em portas distintas, sem HAProxy.

Para BHTTP, abra **2 → 8 → 3** (DTunnel) ou **2 → 8 → 4** (TURBOProxy-VPN). Informe separadamente a porta pública BHTTP e a porta local do SSH. Por exemplo, se o BHTTP escuta na 8080 e o SSH na 22, o cliente BHTTP deve usar a **8080**. O pacote TURBOProxy-VPN inclui binários para Linux AMD64 e ARM64.

## TURBO MULTIPROXY

Ative primeiro um servidor BHTTP e um servidor WebSocket HTTP/1.1 na VPS. Em **2 → 18**, configure uma porta pública livre e os dois destinos locais. O exemplo abaixo permite que os dois aplicativos usem o mesmo endereço e a mesma porta pública.

| Parâmetro | Exemplo |
|---|---|
| Porta pública TCP do multiplexador | 8080 |
| Servidor BHTTP local | 127.0.0.1:18080 |
| Servidor WebSocket local | 127.0.0.1:18081 |
| Caminho configurado no cliente e no servidor WebSocket | /ws |

Libere a porta pública no firewall da VPS e do provedor. Restrinja o acesso externo às portas internas quando forem exclusivas do multiplexador. O módulo atende **BHTTP e WebSocket sem TLS**. Usar a porta 443 por si só não ativa WSS. HCR e XHTTP são configurados separadamente no painel.

## Diagnóstico e testes

| Sintoma | Como verificar |
|---|---|
| O comando menussh não abre o painel | Verifique se a instalação terminou e execute `command -v menussh`. |
| Porta ocupada ou conexão recusada | Execute `ss -ltnp`, confira qual serviço escuta na porta e revise o firewall. |
| A conexão abre, mas o SSH recusa o login | Confira a validade da conta, as credenciais e a porta SSH usada pelo serviço. |
| O BHTTP direto funciona, mas a porta compartilhada falha | Confira o destino local configurado em **2 → 18** e consulte o log do multiplexador. |
| WebSocket não conecta | Confira a porta pública, o caminho do cliente e se o servidor de destino aceita WS sem TLS. |

Para consultar as últimas mensagens dos serviços TURBO:

```bash
journalctl -u turboproxy.service -n 50 --no-pager
journalctl -u turbo-multiproxy.service -n 50 --no-pager
```

O motor BHTTP passou pelo autoteste BHP1. O encaminhamento simultâneo de BHTTP e WebSocket foi testado localmente. Para validar Bilola Tunnel, DTunnel ou HTTP Custom, registre a versão do aplicativo e teste login, transferência nos dois sentidos e reconexão na VPS. Ao compartilhar logs, oculte senhas, tokens e UUIDs.

## Projetos de origem

O VPS-MANAGER integra o gerenciamento Xray e o bot do XRAY2026, a integração BHTTP DTunnel e o motor SuperFlash BHTTP 2.4.1 utilizado pelo TURBOProxy-VPN. A licença do componente Xray está em `core/xray/LICENSE`.

- [VPS-MANAGER](https://github.com/PhoenixxZ2023/VPS-MANAGER)
- [XRAY2026](https://github.com/PhoenixxZ2023/XRAY2026)
- [BHTTP-DTUNNEL](https://github.com/PhoenixxZ2023/BHTTP-DTUNNEL)
- [SuperFlash BHTTP](https://github.com/apksdemons/BHTTP)
