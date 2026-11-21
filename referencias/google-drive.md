# Google Drive: chave própria e autorização do rclone

Dois trabalhos: criar a chave no Google Cloud (uma vez por conta, pelo navegador) e autorizar o
rclone do servidor (uma vez por servidor). O dono da conta Google faz os cliques de consentimento.
Não faça por ele nem peça a senha dele.

## 1. Escolher o escopo

| Escopo | O servidor enxerga | Quando usar |
|---|---|---|
| `drive.file` | Só os arquivos que esta chave criou | Padrão. Obrigatório em servidor de cliente ou com mais gente com acesso root |
| `drive` | O Drive inteiro da conta | Só em servidor seu, quando precisa ler pastas que já existiam |

Com `drive.file`, a tela de consentimento do Google mostra "Ver, editar, criar e excluir apenas os
arquivos do Google Drive que você usa com este app". Se mostrar acesso a todos os arquivos, o
escopo saiu errado: cancele.

## 2. Criar a chave no Google Cloud

No <https://console.cloud.google.com>, logado na conta dona do Drive:

1. **Projeto novo.** Um nome que diga para que serve, por exemplo "Backup rclone".
2. **Ativar a API.** APIs e serviços, Biblioteca, "Google Drive API", Ativar.
3. **Tela de consentimento** (Google Auth Platform, "Vamos começar"): nome do app, e-mail de
   suporte, público **Externo**, e-mail de contato. Aceitar a política de dados é ato do dono da
   conta.
4. **Cliente OAuth.** Clientes, Criar cliente, tipo **App para computador**. Anote o ID do cliente
   e a chave secreta na hora: a chave secreta não aparece de novo depois de fechar a janela.
5. **Branding.** Preencha a página inicial e o link da política de privacidade com URLs reais de
   quem é dono do app, e o domínio delas em "Domínios autorizados". Sem isso o botão de publicar
   fica desligado.
6. **Publicar.** Público-alvo, "Publicar app", confirmar. O status tem que ficar **Em produção**.

Por que publicar: em "Testando", a autorização vence em 7 dias e o backup para sem erro visível
no dia da configuração. Com `drive.file` não é preciso enviar o app para verificação do Google.

Um projeto pode ter um cliente OAuth por servidor. Assim cada servidor tem a sua chave e dá para
saber, e cortar, quem é quem.

## 3. Autorizar o rclone no servidor (sem navegador)

O rclone do servidor abre uma porta local (53682) e espera o Google devolver o código. Um túnel
SSH leva essa porta até o seu computador, onde está o navegador.

No seu computador, abra o túnel e deixe a sessão aberta:

```bash
ssh -L 53682:127.0.0.1:53682 root@SEU_SERVIDOR
```

Nessa sessão, no servidor. O `read -s` evita que a chave secreta fique no histórico:

```bash
read -r  -p "ID do cliente: " CID
read -rs -p "Chave secreta: " CSEC; echo
BLOB=$(printf '{"client_id":"%s","client_secret":"%s","scope":"drive.file"}' "$CID" "$CSEC" \
       | base64 -w0 | tr '+/' '-_' | tr -d '=')
rclone authorize drive "$BLOB" --auth-no-open-browser
```

O `tr` não é enfeite: o rclone espera base64 de URL sem preenchimento. Com base64 comum ele
responde `decode simple map: illegal base64 data`.

O rclone mostra um link `http://127.0.0.1:53682/auth?state=...`. Abra no navegador do seu
computador, escolha a conta, confira o escopo (seção 1) e permita. Se aparecer "O Google não
verificou este app", é o app que você acabou de criar: Avançado, Acessar. A página termina em
"Success!" e o terminal imprime um bloco entre `--->` e `<---`.

Esse bloco é o token, em base64. Não cole em lugar nenhum. Grave direto no `rclone.conf`:

```bash
# cole o bloco (uma linha) quando pedir, e de Enter
read -rs -p "Bloco do rclone: " RESP; echo
while [ $(( ${#RESP} % 4 )) -ne 0 ]; do RESP="$RESP="; done   # repoe o preenchimento do base64
TOKEN=$(printf '%s' "$RESP" | tr -- '-_' '+/' | base64 -d | jq -r .token)
if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "ERRO: bloco invalido, nada foi gravado"
elif rclone listremotes 2>/dev/null | grep -qx 'gdrive:'; then
    echo "ERRO: ja existe um remote gdrive. Faca antes o passo 1 da secao 5 e repita este bloco."
else
    umask 077; mkdir -p /root/.config/rclone
    cat >> /root/.config/rclone/rclone.conf <<EOF

[gdrive]
type = drive
client_id = $CID
client_secret = $CSEC
scope = drive.file
token = $TOKEN
EOF
    echo "gravado"
fi
unset BLOB RESP TOKEN        # CID e CSEC ficam ate dar "gravado"; depois: unset CID CSEC
```

Este bloco usa o `jq`. Instale antes (`dnf install jq` ou `apt install jq`).

Quem preferir o assistente: `rclone config`, remote novo do tipo `drive`, informar o ID e a chave,
escolher o escopo "drive.file" e responder **não** a "Use auto config?". Ele pede o mesmo
`rclone authorize`, que pode rodar em qualquer máquina com rclone e navegador.

## 4. Conferir

```bash
chmod 600 /root/.config/rclone/rclone.conf
rclone listremotes                 # gdrive:
rclone about gdrive:               # Total / Used / Free
rclone lsd gdrive:                 # com drive.file: vazio, ou so as pastas criadas por esta chave
rclone mkdir "gdrive:Backups MeuServidor" && rclone lsd gdrive:
```

Não pode aparecer `This remote uses rclone's shared Google Drive client_id`.

## 5. Trocar uma autorização antiga

Servidor que já tinha um `[gdrive]` sem chave própria ou com escopo `drive`:

1. Renomeie a seção antiga para `[gdrive-antigo]`
   (`sed -i 's/^\[gdrive\]$/[gdrive-antigo]/' /root/.config/rclone/rclone.conf`) e crie a nova
   como `[gdrive]`, pela seção 3.
2. Rode os backups com a nova e confira os arquivos no Drive.
3. Só então revogue a antiga e apague a seção:

```bash
RT=$(awk '/^\[gdrive-antigo\]/{s=1;next} /^\[/{s=0} s&&/^token/' /root/.config/rclone/rclone.conf \
     | grep -o '"refresh_token":"[^"]*"' | cut -d'"' -f4)
curl -s -o /dev/null -w '%{http_code}\n' -X POST --data-urlencode "token=$RT" https://oauth2.googleapis.com/revoke
unset RT
rclone config delete gdrive-antigo
```

Revogar derruba **todas** as máquinas que usam aquela mesma autorização. Antes, confira em cada
servidor se o `rclone.conf` é o mesmo (compare o hash da linha `token`, nunca o conteúdo):

```bash
grep '^token' /root/.config/rclone/rclone.conf | grep -o '"refresh_token":"[^"]*"' | sha256sum | cut -c1-12
```

Apague também as cópias de segurança do `rclone.conf` antigo: elas guardam o mesmo token.

Os backups antigos ficam na pasta antiga. A chave nova, com `drive.file`, não os enxerga nem os
apaga: o dono da conta apaga à mão quando quiser.
