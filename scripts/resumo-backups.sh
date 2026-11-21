#!/bin/bash
# Resumo semanal dos backups: o ultimo pacote de cada site e de cada banco no Drive, com
# tamanho e data, mais os erros da semana. Serve para bater o olho e ver site que parou de
# ser copiado ou pacote que encolheu.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONF="${BACKUP_CONF:-/etc/backup-drive.conf}"
[ -r "$CONF" ] || { echo "resumo-backups: nao consigo ler $CONF" >&2; exit 1; }
. "$CONF"

AVISAR="$(dirname "$(readlink -f "$0")")/avisar-backup.sh"
REMOTE="${DESTINO_DRIVE%%:*}:"
DIAS=7

# datas dos ultimos 7 dias, no formato que os logs usam: [YYYY-MM-DD_
PADRAO=$(for i in $(seq 0 $((DIAS-1))); do date -d "-$i day" +"\[%Y-%m-%d_"; done | paste -sd'|')

resumir_log() {
    local arquivo="$1" rotulo="$2"
    echo "── $rotulo ($arquivo)"
    if [ ! -f "$arquivo" ]; then
        echo "   arquivo de log nao existe"
        return
    fi
    local linhas ok erro
    linhas=$(grep -Ec "$PADRAO" "$arquivo")
    ok=$(grep -E "$PADRAO" "$arquivo" | grep -c "✔")
    erro=$(grep -E "$PADRAO" "$arquivo" | grep -c "✗")
    echo "   linhas nos ultimos $DIAS dias: $linhas | sucessos: $ok | erros: $erro"
    if [ "$erro" -gt 0 ]; then
        echo "   erros registrados:"
        grep -E "$PADRAO" "$arquivo" | grep "✗" | tail -10 | sed 's/^/     /'
    fi
}

ultimo_de_cada() {
    local base="$1" d linha bytes data hora
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        linha=$(rclone lsl "$base/$d" 2>/dev/null | sort -k2,3 | tail -1)
        if [ -n "$linha" ]; then
            bytes=$(echo "$linha" | awk '{print $1}')
            data=$(echo "$linha" | awk '{print $2}')
            hora=$(echo "$linha" | awk '{print $3}' | cut -d. -f1)
            printf "   %-34s %8s  %s %s\n" "${d%/}" "$(numfmt --to=iec --suffix=B "$bytes")" "$data" "$hora"
        else
            printf "   %-34s  SEM ARQUIVO\n" "${d%/}"
        fi
    done < <(rclone lsf "$base" --dirs-only 2>/dev/null)
}

{
    echo "Resumo semanal dos backups de $ROTULO"
    echo "Gerado em $(date +'%d/%m/%Y %H:%M') (horário do servidor)"
    echo
    echo "=== ESPACO NO GOOGLE DRIVE ==="
    rclone about "$REMOTE" 2>&1
    echo
    echo "=== ULTIMO BACKUP DE ARQUIVOS DE CADA SITE ==="
    ultimo_de_cada "$DESTINO_DRIVE/Files"
    echo
    echo "=== ULTIMO DUMP DE CADA BANCO ==="
    ultimo_de_cada "$DESTINO_DRIVE/MySQL"
    echo
    echo "=== LOGS DOS ULTIMOS $DIAS DIAS ==="
    resumir_log "${DIR_LOG:-/var/log}/files-backup.log" "Arquivos"
    echo
    resumir_log "${DIR_LOG:-/var/log}/mysql-backup.log" "Banco de dados"
    echo
    echo "=== BACKUP LOCAL (${DIR_LOCAL_BANCO:-/var/backups/mysql}) ==="
    du -sh "${DIR_LOCAL_BANCO:-/var/backups/mysql}" 2>/dev/null
    df -h / | tail -1
} | bash "$AVISAR" "[$ROTULO] Resumo semanal dos backups" >/dev/null 2>&1

exit 0
