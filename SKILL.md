---
name: backup-vps-google-drive
description: Use quando um VPS Linux (sites em /home, MySQL ou MariaDB, com ou sem CyberPanel) precisa de backup diário no Google Drive pelo rclone, ou quando um backup assim já existe e falha em silêncio. Gatilhos: "configurar backup no servidor", "backup no Google Drive", "rclone", "o backup parou e ninguém viu", "backup sem aviso", "Drive lotado de backup antigo", aviso do rclone "shared Google Drive client_id is being retired", erro 403 rateLimitExceeded, token do Drive que expira em 7 dias, "illegal base64 data" no rclone authorize, servidor de cliente que não pode enxergar o Drive inteiro.
---

# Backup de VPS no Google Drive (rclone)

Cinco scripts de shell e um arquivo de configuração. Copiam todo dia cada site e cada banco do
servidor para uma pasta do Google Drive, conferem se a cópia saiu inteira, apagam o que venceu e
mandam e-mail: na falha, todo dia ("Backup OK") e um resumo por semana.

**Princípio: backup que ninguém confere não existe.** Todo passo abaixo termina numa prova
(arquivo listado no Drive, pacote aberto, e-mail recebido). Não diga que o backup está
configurado sem ter visto as três.

## O que tem aqui

| Arquivo | O que faz |
|---|---|
| `scripts/backup-drive.conf.exemplo` | Toda a configuração: destino, prazos, pastas, e-mails |
| `scripts/mysql-backup.sh` | Dump de todos os bancos, envio, poda local e no Drive |
| `scripts/files-backup.sh` | Um `tar.gz` por site direto para o Drive, com 5 tentativas e poda |
| `scripts/avisar-backup.sh` | Envia o e-mail pelo Postfix local |
| `scripts/relatorio-diario-backup.sh` | E-mail diário: "Backup OK" ou "ATENÇÃO" |
| `scripts/resumo-backups.sh` | E-mail semanal com o último pacote de cada site e banco |
| `referencias/google-drive.md` | Criar a chave própria do Google e autorizar o rclone num servidor sem navegador |

## Antes de começar

Confira no servidor, como root:

```bash
command -v rclone mysqldump sendmail jq numfmt   # os cinco precisam aparecer
ls -l /root/.my.cnf                              # precisa existir, modo 600
mysql --defaults-file=/root/.my.cnf -e "show databases"
ls /home                                         # onde estao os sites
df -h /                                          # o dump do banco fica 7 dias no disco
```

- Sem `rclone`: `curl https://rclone.org/install.sh | sudo bash` (leia o script antes) ou o pacote
  da distribuição.
- Sem `/root/.my.cnf`: crie com `[client]`, `user=` e `password=`, modo 600. Não ponha a senha
  no script.
- Sem `sendmail`/Postfix funcionando, os backups rodam, mas ninguém é avisado. Resolva o envio
  antes de dar o trabalho por pronto.

Pergunte a quem pediu, e não invente: o e-mail que recebe os avisos, o remetente, a conta Google
de destino e quantos dias guardar.

## Passo a passo

### 1. Ligar o rclone ao Google Drive

Siga `referencias/google-drive.md`. Duas decisões ficam lá e não são opcionais:

- **Chave própria (client_id).** O `client_id` embutido no rclone é compartilhado com o mundo
  todo: dá erro 403 de limite nos horários de pico e o rclone avisa que ele será desligado.
- **Escopo `drive.file` em servidor que não é só seu.** Com `drive`, quem tiver root no servidor
  lê o Drive inteiro da conta. Com `drive.file`, o servidor só enxerga o que ele mesmo gravou.

Prova: `rclone lsd gdrive:` responde sem o aviso de "shared client_id" e, com `drive.file`, não
lista nenhuma pasta antiga da conta.

### 2. Instalar os scripts

```bash
install -m 700 -o root -g root scripts/*.sh /usr/local/bin/
# so na primeira vez: nao sobrescreve uma configuracao ja ajustada
[ -e /etc/backup-drive.conf ] || install -m 600 -o root -g root scripts/backup-drive.conf.exemplo /etc/backup-drive.conf
```

Para atualizar os scripts depois, repita só a primeira linha.

Edite `/etc/backup-drive.conf`. Cada campo está explicado no próprio arquivo. Atenção a três:

- `DESTINO_DRIVE`: com `drive.file`, use uma pasta nova. A chave não enxerga pasta criada por
  outra autorização, e criaria uma segunda com o mesmo nome ao lado.
- `IGNORAR_SITES`: pastas de `/home` que não são site. Liste `/home` e decida uma a uma.
- `SO_ESTRUTURA`: tabela de log grande (`banco.tabela`) que vai sem as linhas.

### 3. Testar o e-mail

```bash
/usr/local/bin/avisar-backup.sh --teste
tail -1 /var/log/backup-avisos.log
```

`OK` no log só diz que o Postfix aceitou. Confirme com quem recebe que chegou, e fora do spam. Se
veio `BOUNCE`, o remetente não é de um domínio cujo SPF e DKIM autorizem este servidor.

### 4. Rodar os dois backups à mão

```bash
/usr/local/bin/mysql-backup.sh;  echo "rc=$?"
/usr/local/bin/files-backup.sh;  echo "rc=$?"
tail -20 /var/log/mysql-backup.log /var/log/files-backup.log
rclone lsl "gdrive:<pasta de destino>" | sort -k2,3
```

Para testar arquivos sem subir tudo: `BACKUP_SO_ESTAS="/home/um-site-pequeno" files-backup.sh`.

Prova, as duas:

```bash
# o dump termina inteiro
zcat /var/backups/mysql/<banco>_*.sql.gz | tail -1        # "-- Dump completed on ..."
# o pacote baixado do Drive abre e tem o que importa (.env, uploads)
rclone cat "gdrive:<pasta>/Files/<site>/<pacote>.tar.gz" | tar -tzf - | grep -cE '\.env|uploads/'
```

### 5. Agendar

`crontab -e` do root. Horários no relógio do servidor (`date` mostra o fuso):

```cron
0 2 * * * /usr/local/bin/mysql-backup.sh
0 3 * * * /usr/local/bin/files-backup.sh
0 10 * * * /usr/local/bin/relatorio-diario-backup.sh
0 7 * * 0 /usr/local/bin/resumo-backups.sh
```

O relatório diário roda horas depois dos backups de propósito: as tentativas do `files-backup.sh`
podem levar 30 minutos por pasta.

### 6. Testar uma falha

```bash
umask 077; mkdir -p /root/teste-falha
sed 's|^DESTINO_DRIVE=.*|DESTINO_DRIVE="remotoinexistente:x"|; s|^DIR_LOG=.*|DIR_LOG="/root/teste-falha"|;
     s|^DIR_LOCAL_BANCO=.*|DIR_LOCAL_BANCO="/root/teste-falha/dumps"|' \
    /etc/backup-drive.conf > /root/teste-falha/conf
BACKUP_CONF=/root/teste-falha/conf BACKUP_TESTE=1 /usr/local/bin/mysql-backup.sh; echo "rc=$?"
rm -rf /root/teste-falha
```

Tem que sair `rc=1` e chegar um e-mail "[TESTE, simulacao, ignore] ... FALHA no backup do banco".
`BACKUP_TESTE=1` marca o e-mail como simulação: use em todo comando desse teste. As pastas
separadas de log e de dump evitam que a falha simulada apareça no relatório diário de verdade e
que o teste mexa nos dumps reais. O teste faz um dump de todos os bancos nessa pasta: confira
antes se cabe no disco.

### 7. Registrar

Anote na documentação do servidor: a pasta do Drive, a conta Google, os prazos, quem recebe os
e-mails e onde está a chave (projeto do Google Cloud). Nunca o conteúdo do `rclone.conf`.

## Restaurar

```bash
# banco
rclone copy "gdrive:<pasta>/MySQL/<banco>/<arquivo>.sql.gz" /root/restore/
# o dump nao cria o banco: crie antes (aqui, um banco de teste)
mysql --defaults-file=/root/.my.cnf -e "CREATE DATABASE restore_teste"
zcat /root/restore/<arquivo>.sql.gz | mysql --defaults-file=/root/.my.cnf restore_teste

# arquivos (o pacote guarda o caminho completo, sem a barra inicial)
rclone copy "gdrive:<pasta>/Files/<site>/<pacote>.tar.gz" /root/restore/
tar -xzf /root/restore/<pacote>.tar.gz -C /root/restore/   # confira antes de mover para /home
```

Restaure primeiro numa pasta e num banco de teste. O pacote não tem `node_modules` nem o build:
depois de restaurar um app Node, instale as dependências e compile.

## Erros comuns

| Sintoma | Causa | O que fazer |
|---|---|---|
| Aviso "shared Google Drive client_id ... being retired" | `rclone.conf` sem `client_id` | Criar a chave própria (`referencias/google-drive.md`) |
| `403 rateLimitExceeded` de madrugada | Mesmo motivo: cota disputada com todo mundo | Chave própria. As esperas longas do script só amenizam |
| Backup para 7 dias depois de configurado | App do Google em modo "Testando" | Publicar o app ("Em produção") e autorizar de novo |
| `illegal base64 data` no `rclone authorize` | Blob em base64 comum | Tem que ser base64 de URL e sem `=` no fim |
| Botão "Publicar app" cinza | Faltam página inicial e política de privacidade | Preencher em Branding com URLs reais de quem é dono do app |
| Pasta antiga "sumiu" do `rclone lsd` | Escopo `drive.file` só vê o que a chave criou | Esperado. Usar pasta nova; a antiga se apaga à mão |
| E-mail funciona à mão e falha no cron | `PATH` do cron sem `/usr/sbin` | Os scripts já exportam o `PATH`. Não remova a linha |
| `BOUNCE` no `backup-avisos.log` | Remetente sem SPF/DKIM para este servidor | Trocar `EMAIL_REMETENTE` por um domínio que o servidor envia |
| Drive enchendo mesmo com poda | Apagados indo para a lixeira | Os scripts usam `--drive-use-trash=false`. Esvaziar a lixeira uma vez |
| Log diz "enviado" e o arquivo não está no Drive | Script antigo que não checa o retorno do rclone | Trocar pelos daqui |
| Todo envio marcado como falha, com `integer expression expected` | `PIPESTATUS` lido em duas atribuições | Copiar o array inteiro de uma vez, como no script |
| `tar` com código 1 toda noite | Arquivo mudou durante a leitura | Normal. Só código 2 ou mais é falha |
| Relatório diz "NAO RODOU hoje" | Cron não disparou, ou relógio em outro fuso | `grep CRON /var/log/cron`; conferir `date` |

## Segurança

- `rclone.conf`, `/root/.my.cnf` e `/etc/backup-drive.conf` com modo 600; scripts com 700.
- Nunca copie o `rclone.conf` de um servidor para outro: leva junto o acesso que aquele tinha.
- Um servidor, uma autorização. Para cortar o acesso de um servidor, revogue a autorização dele na
  conta Google (Segurança, apps com acesso à conta) e apague o `rclone.conf` de lá.
- Não cole token, `client_secret` nem senha em conversa, ticket ou documentação.
- O pacote de arquivos leva os `.env` dos sites. A pasta do Drive é tão sensível quanto o servidor:
  não compartilhe por link.

## Limites

- Só MySQL/MariaDB. PostgreSQL e MongoDB precisam de script próprio, na mesma estrutura.
- Cópia completa todo dia, sem incremental. Serve para sites de alguns GB; para dezenas de GB,
  avalie restic ou borg.
- Não substitui o snapshot do provedor: use os dois.
