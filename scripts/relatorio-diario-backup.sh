#!/bin/bash
# Relatorio diario dos backups. Roda todo dia depois que os backups terminam e manda SEMPRE
# um e-mail: "Backup OK" ou "ATENCAO".
#
# Por que mandar tambem o sucesso: aviso so de falha fica mudo quando o proprio aviso quebra
# (cron parado, envio recusado), e o silencio passa por "esta tudo bem". Com este relatorio,
# o dia em que nao chega NENHUM e-mail ja e o alerta.
#
# Confere, no log de cada backup: se rodou hoje, se terminou e se teve falha.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONF="${BACKUP_CONF:-/etc/backup-drive.conf}"
[ -r "$CONF" ] || { echo "relatorio-diario-backup: nao consigo ler $CONF" >&2; exit 1; }
. "$CONF"

AVISAR="$(dirname "$(readlink -f "$0")")/avisar-backup.sh"
REMOTE="${DESTINO_DRIVE%%:*}:"
LOGS=("${DIR_LOG:-/var/log}/mysql-backup.log|Bancos de dados" "${DIR_LOG:-/var/log}/files-backup.log|Arquivos dos sites")   # "arquivo|Nome legivel"

HOJE=$(date +%Y-%m-%d)
PROBLEMAS=0
CORPO=""
linha() { CORPO+="$1"$'\n'; }

for item in "${LOGS[@]}"; do
    arquivo="${item%%|*}"; nome="${item#*|}"
    # a execucao de hoje = a ultima linha "Iniciando" com a data de hoje
    tag=$(grep -F "[$HOJE" "$arquivo" 2>/dev/null | grep "Iniciando" | tail -1 | grep -oE '^\[[^]]+\]')
    if [ -z "$tag" ]; then
        linha "✗ $nome: NAO RODOU hoje"; PROBLEMAS=$((PROBLEMAS+1)); continue
    fi
    trecho=$(grep -F "$tag" "$arquivo")
    enviados=$(echo "$trecho" | grep -cE "✔ .*(enviado com sucesso|enviado para o Google Drive)")
    falhas_totais=$(echo "$trecho" | grep -c "FALHA TOTAL")
    falhas_rel=$(echo "$trecho" | grep -oE "falhas( nesta execucao)?: [0-9]+" | tail -1 | grep -oE "[0-9]+$")
    if echo "$trecho" | grep -q "ERRO FATAL"; then
        linha "✗ $nome: FALHA GRAVE, o backup nem começou"
        linha "$(echo "$trecho" | grep "ERRO FATAL" | sed 's/^\[[^]]*\] /     /')"
        PROBLEMAS=$((PROBLEMAS+1))
    elif ! echo "$trecho" | grep -qE "Backup concluído|Limpeza concluída"; then
        linha "✗ $nome: começou e NAO TERMINOU (travou ou ainda está rodando), $enviados enviado(s) até agora"
        PROBLEMAS=$((PROBLEMAS+1))
    elif [ "$falhas_totais" -gt 0 ] || [ "${falhas_rel:-0}" -gt 0 ]; then
        n=$(( falhas_totais > ${falhas_rel:-0} ? falhas_totais : ${falhas_rel:-0} ))
        linha "✗ $nome: $n FALHA(S), $enviados enviado(s)"
        detalhe=$(echo "$trecho" | grep "FALHA TOTAL" | sed 's/^\[[^]]*\] /     /')
        [ -n "$detalhe" ] && linha "$detalhe"
        PROBLEMAS=$((PROBLEMAS+1))
    else
        linha "✔ $nome: $enviados enviado(s), nenhuma falha"
    fi
done

USO=$(df --output=pcent / | tail -1 | tr -dc '0-9')
LIVRE=$(df -h --output=avail / | tail -1 | tr -d ' ')
if [ "$USO" -ge "${DISCO_ALERTA:-85}" ]; then
    linha "✗ Disco do servidor em ${USO}% (livre: $LIVRE), acima de ${DISCO_ALERTA:-85}%"
    PROBLEMAS=$((PROBLEMAS+1))
else
    linha "✔ Disco do servidor em ${USO}% (livre: $LIVRE)"
fi

DATA_BR=$(date +%d/%m)
if [ "$PROBLEMAS" -eq 0 ]; then
    ASSUNTO="[$ROTULO] Backup OK, $DATA_BR"
else
    ASSUNTO="[$ROTULO] ATENÇÃO no backup, $DATA_BR ($PROBLEMAS problema(s))"
fi

{
    echo "Relatório diário dos backups de $ROTULO, $(date +'%d/%m/%Y %H:%M') (horário do servidor)"
    echo
    printf '%s' "$CORPO"
    echo
    echo "Espaço no Google Drive:"
    rclone about "$REMOTE" 2>&1 | head -3
    echo
    echo "Este e-mail chega todo dia. Se um dia não chegar, algo parou (servidor, agendamento ou envio)."
} | bash "$AVISAR" "$ASSUNTO" >/dev/null 2>&1
