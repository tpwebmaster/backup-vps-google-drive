#!/bin/bash
# Backup de arquivos: um tar.gz de cada site e de cada app para o Google Drive, com repeticao,
# checagem dos dois lados do pipe, poda no Drive e aviso por e-mail quando falha.
#
# A lista de pastas e montada na hora, entao site novo entra sozinho:
#   - cada subpasta de RAIZ_SITES inteira (codigo, uploads, .env, repositorio de deploy);
#   - cada app que o PM2 roda fora de RAIZ_SITES e cada /opt/<app> com ecosystem.config;
#   - o que estiver em PASTAS_EXTRAS.
# O pacote vai direto para o Drive (tar | rclone rcat), sem ocupar disco no servidor.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

CONF="${BACKUP_CONF:-/etc/backup-drive.conf}"
[ -r "$CONF" ] || { echo "files-backup: nao consigo ler $CONF" >&2; exit 1; }
. "$CONF"

GDRIVE_FOLDER="$DESTINO_DRIVE/Files"
REMOTE="${DESTINO_DRIVE%%:*}:"
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="${DIR_LOG:-/var/log}/files-backup.log"
AVISAR="$(dirname "$(readlink -f "$0")")/avisar-backup.sh"
MAX_RETRIES=5
# Espera antes de cada nova tentativa: 1, 3, 10 e 15 minutos. O erro mais comum do Drive e o
# 403 de limite de requisicoes, que dura minutos; tentativas coladas caem todas no mesmo pico.
ESPERAS=(60 180 600 900)

# Reconstruivel por build ou instalacao, ou copia de outra copia: nao vai para o Drive.
# Se o servidor tem WordPress, NAO exclua 'dist': plugin traz essa pasta pronta.
EXCLUI=(--exclude="${RAIZ_SITES#/}/*/logs" --exclude=node_modules --exclude='.next*' --exclude=.git
        --exclude=.cache --exclude=venv --exclude=__pycache__ --exclude='*.log'
        --exclude=wp-content/cache --exclude=wp-content/litespeed --exclude=wp-content/updraft
        --exclude=wp-content/ai1wm-backups --exclude=wp-content/upgrade)

# BACKUP_SO_ESTAS="/caminho1 /caminho2" limita a lista (para testar sem subir tudo).
if [ -n "${BACKUP_SO_ESTAS:-}" ]; then
    read -r -a FOLDERS <<< "$BACKUP_SO_ESTAS"
else
mapfile -t FOLDERS < <(
    {
        # pastas ocultas da raiz sao de ferramenta (antivirus, cache), nao de site
        find "$RAIZ_SITES" -mindepth 1 -maxdepth 1 -type d -not -name '.*' 2>/dev/null \
          | grep -Ev "^$RAIZ_SITES/(${IGNORAR_SITES:-_nada_}|$(hostname -f 2>/dev/null))$"
        # apps fora da raiz: o que o PM2 roda e o que tem ecosystem em /opt
        # Trava: um app do PM2 iniciado em / ou em /root poria o disco inteiro, ou as
        # credenciais do root (rclone.conf, .my.cnf), dentro de um pacote. Essas pastas nunca
        # entram sozinhas; app que mora em /root vai por PASTAS_EXTRAS, de caso pensado.
        jq -r '.[].pm_cwd // empty' /root/.pm2/dump.pm2 2>/dev/null \
          | sed 's|/$||' | grep -Ev "^$RAIZ_SITES(/|$)|/\.pm2(/|$)|^/root(/|$)|^$"
        find /opt -mindepth 2 -maxdepth 2 -name 'ecosystem.config.*' -printf '%h\n' 2>/dev/null
        for P in ${PASTAS_EXTRAS:-}; do echo "$P"; done
    } | sed 's|/$||' | grep -v '^$' | sort -u
)
fi

umask 077
touch "$LOG_FILE"; chmod 640 "$LOG_FILE"

echo "[$DATE] Iniciando backup de arquivos (${#FOLDERS[@]} pastas)..." >> "$LOG_FILE"

# GUARDA: lista vazia significa disco montado errado ou find quebrado. Sem isto o script
# "terminaria com sucesso" sem copiar nada e ninguem perceberia.
if [ "${#FOLDERS[@]}" -eq 0 ]; then
    echo "[$DATE] ✗ ERRO FATAL: nenhuma pasta encontrada para copiar." >> "$LOG_FILE"
    echo "─────────────────────────────────────" >> "$LOG_FILE"
    echo "O backup de ARQUIVOS nem comecou: a lista de pastas veio vazia." | \
      bash "$AVISAR" "[$ROTULO] FALHA GRAVE no backup de arquivos (lista vazia)" >/dev/null 2>&1
    exit 1
fi

FALHAS=0
FALHOU=""

for FOLDER in "${FOLDERS[@]}"; do
    [ -d "$FOLDER" ] || { echo "[$DATE] ⚠ Pasta sumiu, pulando: '$FOLDER'" >> "$LOG_FILE"; continue; }

    # /home/site.com -> site.com ; /opt/app -> opt_app
    NAME=$(echo "$FOLDER" | sed "s|^$RAIZ_SITES/||; s|^/||; s|/|_|g")
    FILENAME="${NAME}_${DATE}.tar.gz"
    SUCCESS=0

    for ((i=1; i<=MAX_RETRIES; i++)); do
        echo "[$DATE] Tentativa $i de $MAX_RETRIES para '$NAME'..." >> "$LOG_FILE"

        RCLONE_ERR=$(mktemp)
        tar -czf - "${EXCLUI[@]}" "$FOLDER" 2>/dev/null | rclone rcat "$GDRIVE_FOLDER/$NAME/$FILENAME" 2>"$RCLONE_ERR"
        # PIPESTATUS e zerado pelo comando seguinte, inclusive por uma atribuicao. Ler [1]
        # depois de ja ter atribuido [0] devolve vazio. Por isso o array e copiado de uma vez.
        RCS=("${PIPESTATUS[@]}")
        TAR_RC=${RCS[0]}
        RCLONE_RC=${RCS[1]}

        # Os dois lados precisam ter dado certo: 'if [ $? -eq 0 ]' so veria o rclone, e um tar
        # cortado subiria como sucesso. tar rc=1 e "arquivo mudou enquanto eu lia", normal em
        # pasta viva; so rc>=2 e falha de verdade.
        if [ "$TAR_RC" -le 1 ] && [ "$RCLONE_RC" -eq 0 ]; then
            TAM=$(rclone size --json "$GDRIVE_FOLDER/$NAME/$FILENAME" 2>/dev/null | grep -oE '"bytes":[0-9]+' | cut -d: -f2 | numfmt --to=iec 2>/dev/null)
            echo "[$DATE] ✔ '$NAME' enviado com sucesso ($TAM)" >> "$LOG_FILE"
            SUCCESS=1
            rm -f "$RCLONE_ERR"
            break
        else
            echo "[$DATE] ✗ Tentativa $i falhou para '$NAME' (tar rc=$TAR_RC, rclone rc=$RCLONE_RC)" >> "$LOG_FILE"
            grep -m1 -E "ERROR|CRITICAL" "$RCLONE_ERR" | cut -c1-300 | sed "s/^/[$DATE]     rclone: /" >> "$LOG_FILE"
            rm -f "$RCLONE_ERR"
            # Apaga o pacote incompleto antes de tentar de novo. Sem --drive-use-trash=false
            # ele vai para a lixeira do Drive e continua consumindo a cota.
            rclone deletefile --drive-use-trash=false "$GDRIVE_FOLDER/$NAME/$FILENAME" 2>/dev/null
            [ $i -lt $MAX_RETRIES ] && sleep "${ESPERAS[$((i-1))]}"
        fi
    done

    if [ $SUCCESS -eq 0 ]; then
        echo "[$DATE] ✗ FALHA TOTAL no backup de '$NAME' após $MAX_RETRIES tentativas" >> "$LOG_FILE"
        FALHAS=$((FALHAS+1))
        FALHOU="$FALHOU $NAME"
    else
        # Poda no Drive so quando o envio de hoje deu certo: nunca apagar historico no dia
        # em que o backup novo falhou.
        rclone delete --drive-use-trash=false --min-age "${DIAS_ARQUIVOS}d" "$GDRIVE_FOLDER/$NAME/" >> "$LOG_FILE" 2>&1 || \
          echo "[$DATE] ✗ poda no Drive falhou para '$NAME'" >> "$LOG_FILE"
    fi
done

echo "[$DATE] Backup concluído (falhas: $FALHAS de ${#FOLDERS[@]})" >> "$LOG_FILE"

if [ "$FALHAS" -gt 0 ]; then
    {
        echo "O backup de ARQUIVOS falhou em $FALHAS de ${#FOLDERS[@]} pasta(s)."
        echo "Pastas com falha:$FALHOU"
        echo
        echo "Espaco no Google Drive:"
        rclone about "$REMOTE" 2>&1
        echo
        echo "Log desta execucao:"
        grep -F "[$DATE]" "$LOG_FILE"
    } | bash "$AVISAR" "[$ROTULO] FALHA no backup de arquivos ($FALHAS pasta(s))" >/dev/null 2>&1 || \
      echo "[$DATE] ✗ nao consegui enviar o e-mail de aviso" >> "$LOG_FILE"
fi
echo "─────────────────────────────────────" >> "$LOG_FILE"
[ "$FALHAS" -eq 0 ]
