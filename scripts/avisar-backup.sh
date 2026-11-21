#!/bin/bash
# Manda um e-mail sobre os backups pelo Postfix local. Usado pelos outros scripts.
#
# Uso:  avisar-backup.sh "Assunto"  < corpo.txt
#       avisar-backup.sh --teste
set -uo pipefail
# O cron roda com PATH=/usr/bin:/bin, sem /usr/sbin, onde fica o sendmail. Sem esta linha o
# aviso funciona no teste manual e falha toda noite com "sendmail: command not found".
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONF="${BACKUP_CONF:-/etc/backup-drive.conf}"
[ -r "$CONF" ] || { echo "avisar-backup: nao consigo ler $CONF" >&2; exit 1; }
. "$CONF"

LOG="${DIR_LOG:-/var/log}/backup-avisos.log"

umask 077
touch "$LOG"; chmod 640 "$LOG"
registrar() { echo "[$(date +'%F %T')] $*" >> "$LOG"; }

if [ "${1:-}" = "--teste" ]; then
    ASSUNTO="[$ROTULO] Teste do aviso de backup"
    CORPO="Teste manual do avisador de backup. Se este e-mail chegou, os alertas de falha chegam."
else
    ASSUNTO="${1:-[$ROTULO] Aviso de backup}"
    CORPO=$(cat)
fi

# BACKUP_TESTE=1 marca o aviso como simulacao, para um teste de falha nao assustar quem recebe.
if [ -n "${BACKUP_TESTE:-}" ]; then
    ASSUNTO="[TESTE, simulacao, ignore] $ASSUNTO"
    CORPO="*** ESTE E UM TESTE. Nenhum backup falhou de verdade. ***

$CORPO"
fi

# Assunto com acento precisa ir codificado (RFC 2047), senao alguns leitores mostram lixo.
ASSUNTO_MIME="=?UTF-8?B?$(printf '%s' "$ASSUNTO" | base64 -w0)?="

if ! ENVIO=$(printf 'From: %s\nTo: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n%s\n' \
        "$EMAIL_REMETENTE" "$EMAIL_DESTINO" "$ASSUNTO_MIME" "$CORPO" | sendmail -f "$EMAIL_REMETENTE" "$EMAIL_DESTINO" 2>&1); then
    registrar "FALHA | $ASSUNTO | -> $EMAIL_DESTINO | sendmail: $ENVIO"
    exit 1
fi

# O sendmail so enfileira. A recusa do destino aparece no log do Postfix segundos depois,
# entao conferimos antes de registrar que deu certo.
sleep 20
MAILLOG=/var/log/maillog; [ -f "$MAILLOG" ] || MAILLOG=/var/log/mail.log
if tail -200 "$MAILLOG" 2>/dev/null | grep -F "to=<$EMAIL_DESTINO>" | tail -1 | grep -q "status=bounced"; then
    registrar "BOUNCE | $ASSUNTO | -> $EMAIL_DESTINO | veja $MAILLOG"
    exit 2
fi
registrar "OK | $ASSUNTO | -> $EMAIL_DESTINO"
