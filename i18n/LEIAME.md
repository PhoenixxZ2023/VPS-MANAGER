# Idiomas do VPS MANAGER (pt-BR / es / en)

- **Português (Brasil) é o idioma principal e o padrão** em instalações novas.
- O idioma fica em `/etc/vps-manager/lang` (`pt`, `es` ou `en`). Troque em: menu > 8 > 9
  (1 = Português, 2 = Español, 3 = English). Instalações antigas que já estavam em `es` continuam em `es` até a troca.
- O catálogo de português é `i18n/pt-BR.tsv` (instalado em `/etc/vps-manager/i18n/pt-BR.tsv`).
  Formato: `TEXTO EM ESPANHOL<TAB>TRADUÇÃO EM MAIÚSCULAS`. É só dados: nunca é executado.
  O `install.sh` baixa esse arquivo; publique a pasta `i18n/` no GitHub, ao lado de `menu.sh`.
- Nos scripts, cada texto aparece como `${T[Texto]:-Texto}` (com negrito) ou `${TP[Texto]:-Texto}` (sem negrito,
  usado em colunas alinhadas do `printf`). Sem catálogo (es/en) o resultado é exatamente o texto original.

## Como traduzir um texto novo
1. No script: troque `echo "Texto novo"` por `echo "${T[Texto novo]:-Texto novo}"`.
2. Em `i18n/pt-BR.tsv`: adicione uma linha `Texto novo<TAB>TEXTO NOVO` (a chave precisa ser idêntica).
3. Chaves não podem conter `[ ] { } " $ \` e crases. Comandos e nomes de arquivo ficam em minúsculas.
