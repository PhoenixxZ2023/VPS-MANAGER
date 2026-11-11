# Idiomas do VPS MANAGER (pt-BR / es / en)

- **Português (Brasil) é o idioma principal e o padrão** em instalações novas.
- O idioma fica em `/etc/vps-manager/lang` (`pt`, `es` ou `en`). Troque em: menu > 8 > 9
  (1 = Português, 2 = Español, 3 = English). Instalações antigas que já estavam em `es` continuam em `es` até a troca.
- Texto em português: sempre em MAIÚSCULAS e em NEGRITO (terminal: negrito ANSI; painel web: CSS; bot: `<b>`).

## Arquivos (publique a pasta `i18n/` no GitHub, ao lado de `menu.sh`)
- `pt-BR.tsv`    – catálogo dos scripts shell. Formato: `TEXTO EM ESPANHOL<TAB>TRADUÇÃO EM MAIÚSCULAS`.
- `pt-BR.py.tsv` – catálogo dos programas Python (controlador v2ray, bot do Telegram, painel web): trechos de frase
  traduzidos na hora de exibir. Somente dados: nunca são executados. Instalados em `/etc/vps-manager/i18n/`.

## Como funciona
- Nos scripts shell cada texto aparece como `${T[Texto]:-Texto}` (negrito) ou `${TP[Texto]:-Texto}` (sem negrito, para
  colunas alinhadas do `printf`). Sem catálogo (es/en) o resultado é exatamente o texto original.
- Python: `pt_text` (terminal; só traduz quando a saída é um TTY, então bot/painel que leem a saída não são afetados),
  `pt_tg` (Telegram; não mexe em `<code>`/`<pre>`) e `pt_html` (painel; texto, placeholder/title/onclick e strings do JS).
- No bot, os botões são traduzidos e a resposta do usuário é convertida de volta antes de comparar.

## Como traduzir um texto novo
1. Shell: troque `echo "Texto novo"` por `echo "${T[Texto novo]:-Texto novo}"` e adicione a linha em `pt-BR.tsv`.
   A chave NÃO pode conter `[ ] { } " ' $ \` nem crases (aspas simples quebram a busca): separe o texto nesses pontos.
2. Python: adicione `Trecho em espanhol<TAB>TRADUÇÃO` em `pt-BR.py.tsv` (casa por palavra inteira, o mais longo primeiro).
3. Comandos e nomes de arquivo ficam em minúsculas dentro das frases.
