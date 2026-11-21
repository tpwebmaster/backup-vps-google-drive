#!/bin/bash
# Backup de todos os bancos MySQL/MariaDB para o Google Drive, com conferencia do dump e do
# envio, poda local e no Drive e aviso por e-mail quando falha.
#
# Credencial: /root/.my.cnf (modo 600). Nunca dentro deste script: arquivo em /usr/local/bin
# costuma nascer legivel por qualquer conta do servidor.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

CONF="${BACKUP_CONF:-/etc/backup-drive.conf}"
[ -r "$CONF" ] || { echo "mysql-backup: nao consigo ler $CONF" >&2; exit 1; }
. "$CONF"

BACKUP_DIR="${DIR_LOCAL_BANCO:-/var/backups/mysql}"
GDRIVE_FOLDER="$DESTINO_DRIVE/MySQL"
REMOTE="${DESTINO_DRIVE%%:*}:"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="${DIR_LOG:-/var/log}/mysql-backup.log"
AVISAR="$(dirname "$(readlink -f "$0")")/avisar-backup.sh"

mkdir -p "$BACKUP_DIR"
touch "$LOG_FILE"; chmod 640 "$LOG_FILE"

echo "[$DATE] Iniciando backup..." >> "$LOG_FILE"

DB_ERR=$(mktemp)
DATABASES=$(mysql --defaults-file=/root/.my.cnf \
  -e "SHOW DATABASES;" 2>"$DB_ERR" | grep -Ev "^(Database|information_schema|performance_schema|mysql|sys)$")

# GUARDA: com o banco fora do ar ou a credencial quebrada, a lista vem vazia. Sem isto o laco
# nao roda, nada e registrado como erro e a poda do fim apaga os backups que existiam. Em
# poucos dias nao sobra nenhum.
if [ -z "$DATABASES" ]; then
    echo "[$DATE] ✗ ERRO FATAL: nenhum banco listado (MySQL fora ou credencial invalida)." >> "$LOG_FILE"
    echo "[$DATE]   mysql disse: $(head -c 300 "$DB_ERR")" >> "$LOG_FILE"
    echo "[$DATE] ✗ Poda NAO executada, para nao destruir os backups existentes." >> "$LOG_FILE"
    echo "─────────────────────────────────────" >> "$LOG_FILE"
    {
        echo "O backup do BANCO nem comecou: nenhum banco foi listado."
        echo "Isso significa MySQL fora do ar ou credencial de /root/.my.cnf invalida."
        echo "A poda NAO foi executada, entao os backups antigos continuam la."
        echo
        grep -F "[$DATE]" "$LOG_FILE"
    } | bash "$AVISAR" "[$ROTULO] FALHA GRAVE no backup do banco (nenhum banco listado)" >/dev/null 2>&1
    rm -f "$DB_ERR"
    exit 1
fi
rm -f "$DB_ERR"

FALHAS=0
ENVIADOS=()
for DB in $DATABASES; do
    FILENAME="${BACKUP_DIR}/${DB}_${DATE}.sql.gz"
    DUMP_ERR=$(mktemp)

    # Tabelas de SO_ESTRUTURA deste banco: fora do dump principal, e depois so o CREATE TABLE.
    # Sem a estrutura, um restore deixaria o sistema sem a tabela.
    IGNORA=(); ESTRUTURA=()
    for T in ${SO_ESTRUTURA:-}; do
        if [ "${T%%.*}" = "$DB" ]; then
            IGNORA+=("--ignore-table=$T"); ESTRUTURA+=("${T#*.}")
        fi
    done

    {
        mysqldump --defaults-file=/root/.my.cnf \
            --single-transaction --routines --triggers \
            "${IGNORA[@]}" "$DB" || exit 1
        if [ "${#ESTRUTURA[@]}" -gt 0 ]; then
            mysqldump --defaults-file=/root/.my.cnf --no-data "$DB" "${ESTRUTURA[@]}" || exit 1
        fi
    } 2>"$DUMP_ERR" | gzip > "$FILENAME"
    DUMP_RC=${PIPESTATUS[0]}

    # Exige mysqldump OK e arquivo nao vazio. 'if [ $? -eq 0 ]' aqui checaria o gzip, e um
    # dump vazio passaria como sucesso.
    if [ "$DUMP_RC" -eq 0 ] && [ -s "$FILENAME" ]; then
        echo "[$DATE] ✔ Backup de '$DB' criado ($(du -h "$FILENAME" | cut -f1))" >> "$LOG_FILE"

        # O retorno do rclone e checado: sem isso o log diz "enviado" mesmo com o envio falho.
        if rclone copy "$FILENAME" "$GDRIVE_FOLDER/$DB/" >> "$LOG_FILE" 2>&1; then
            echo "[$DATE] ✔ '$DB' enviado para o Google Drive" >> "$LOG_FILE"
            ENVIADOS+=("$DB")
        else
            echo "[$DATE] ✗ ERRO ao enviar '$DB' para o Google Drive (backup local existe)" >> "$LOG_FILE"
            FALHAS=$((FALHAS+1))
        fi
    else
        echo "[$DATE] ✗ ERRO no backup de '$DB' (mysqldump rc=$DUMP_RC, tamanho=$(stat -c%s "$FILENAME" 2>/dev/null || echo 0))" >> "$LOG_FILE"
        echo "[$DATE]   mysqldump disse: $(head -c 300 "$DUMP_ERR")" >> "$LOG_FILE"
        FALHAS=$((FALHAS+1))
    fi
    rm -f "$DUMP_ERR"
done

# poda local
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +"${DIAS_LOCAL:-7}" -delete
# Poda no Drive so dos bancos enviados hoje: nunca apagar historico de um banco no dia em que
# o backup novo dele falhou.
for DB in "${ENVIADOS[@]}"; do
    rclone delete --drive-use-trash=false --min-age "${DIAS_BANCO}d" "$GDRIVE_FOLDER/$DB/" >> "$LOG_FILE" 2>&1 || \
      echo "[$DATE] ✗ poda no Drive falhou para '$DB'" >> "$LOG_FILE"
done

echo "[$DATE] Limpeza concluída (falhas nesta execucao: $FALHAS)" >> "$LOG_FILE"

if [ "$FALHAS" -gt 0 ]; then
    {
        echo "O backup do BANCO teve $FALHAS falha(s) nesta execucao."
        echo
        echo "Espaco no Google Drive:"
        rclone about "$REMOTE" 2>&1
        echo
        echo "Log desta execucao:"
        grep -F "[$DATE]" "$LOG_FILE"
    } | bash "$AVISAR" "[$ROTULO] FALHA no backup do banco ($FALHAS)" >/dev/null 2>&1 || \
      echo "[$DATE] ✗ nao consegui enviar o e-mail de aviso" >> "$LOG_FILE"
fi
echo "─────────────────────────────────────" >> "$LOG_FILE"
[ "$FALHAS" -eq 0 ]
