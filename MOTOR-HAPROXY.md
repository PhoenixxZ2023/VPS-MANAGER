# Motor unificado HAProxy + Xray + SSH-WS

Menu > 2 (Gerenciador de instalações) > **19. Motor unificado HAProxy + Xray (avançado)**.

## O que ele faz
- HAProxy assume as portas **80, 8080 e 443** (TLS com o seu certificado) e distribui o tráfego **por conteúdo**:
  WS (`/vless` `/vmess` `/trojan` `/ss`), XHTTP (`/xhttp`), gRPC (ALPN h2), SSH por TLS (banner `SSH-`) e SSH-WS (padrão).
- Xray passa a escutar **só em 127.0.0.1** (10001-10014). SSH-WS interno em 127.0.0.1:10015 (`vps-ssh-ws.service`).
- As contas VMess/VLESS/Trojan/XHTTP existentes são **migradas** (mesmo domínio, porta 443 e rotas: o cliente não muda nada).

## Segurança da instalação
1. Antes de mexer em qualquer coisa: backup completo em `/etc/vps-manager/backup/engine-AAAAMMDD-HHMMSS/`.
2. Não mata processos desconhecidos nas portas 80/8080/443: lista e cancela. Só para serviços do manager (e pergunta sobre nginx/apache2).
3. `xray run -test` e `haproxy -c` antes de aplicar. Qualquer falha restaura o estado anterior sozinho.
4. Depois de subir, testa **cada rota com tráfego real** (contadores do HAProxy). Se alguma falhar, oferece restaurar.
5. Restaurar manualmente: menu do motor > 5. (As contas criadas depois da instalação não existem no backup.)

## Depois de instalado
- `vmess.sh`/`vless.sh`/`trojan.sh` continuam criando contas; a reinstalação do Xray clássico fica bloqueada para não derrubar o HAProxy.
- Certificado: renovado pelo certbot; o hook em `/etc/letsencrypt/renewal-hooks/deploy/` regrava o PEM e recarrega o HAProxy.
  Troca de domínio pelo Gestor de Domínio também sincroniza o PEM.
- `Instalar SSHWS / Websocket` (autoconfig) fica bloqueado enquanto o motor estiver ativo.
- Recomendado: **tirar um snapshot da VPS** antes da primeira instalação.
