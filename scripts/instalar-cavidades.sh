#!/usr/bin/env bash
set -euo pipefail
umask 077

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/app"
WAR_SOURCE="$BASE/CustomFusionWeb.war"
SESSION_SETUP="$BASE/configurar-sessao-fusion.sh"

CATALINA_BASE="${CATALINA_BASE:-}"
FUSION_HOME="${FUSION_HOME:-}"
FUSION_DOCBASE="${FUSION_DOCBASE:-}"
FUSION_BASE_URL="${FUSION_BASE_URL:-}"
FUSION_LOGIN_URL="${FUSION_LOGIN_URL:-}"
CAVIDADES_PUBLIC_URL="${CAVIDADES_PUBLIC_URL:-}"
CAVIDADES_HEALTH_URL="${CAVIDADES_HEALTH_URL:-}"
DB_FILE="${DB_FILE:-}"
TOMCAT_USER="${TOMCAT_USER:-}"
FUSION_FOLDER_BASE="${FUSION_FOLDER_BASE:-}"
PACKAGE_TMP_DIR=""
STAGE_DIR=""
HEADERS=""

ask_value() {
  local variable="$1"
  local label="$2"
  local default="$3"
  local answer
  read -r -p "$label [$default]: " answer
  printf -v "$variable" '%s' "${answer:-$default}"
}

ask_required() {
  local variable="$1"
  local label="$2"
  local default="${!variable}"
  local answer
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$label [$default]: " answer
      answer="${answer:-$default}"
    else
      read -r -p "$label: " answer
    fi
    if [[ -n "$answer" ]]; then
      printf -v "$variable" '%s' "$answer"
      return
    fi
    echo "Este valor é obrigatório."
  done
}

cleanup() {
  if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
    rm -rf -- "$STAGE_DIR"
  fi
  if [[ -n "$PACKAGE_TMP_DIR" && -d "$PACKAGE_TMP_DIR" ]]; then
    rm -rf -- "$PACKAGE_TMP_DIR"
  fi
  if [[ -n "$HEADERS" && -f "$HEADERS" ]]; then
    rm -f -- "$HEADERS"
  fi
  unset FUSION_API_TOKEN || true
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERRO: execute como root (por exemplo: sudo bash ./instalar-cavidades.sh)." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "ERRO: python3 e curl precisam estar instalados." >&2
  exit 1
fi

echo "Configuração da nova instalação da Cavidades."
echo "Informe os valores específicos deste servidor; não há endereços de ambiente predefinidos."
ask_required CATALINA_BASE "Diretório base do Tomcat do Fusion"
ask_required FUSION_HOME "Diretório do Fusion (contém stop.sh/start.sh)"
ask_required FUSION_DOCBASE "Caminho do Fusion usado em server.xml"
ask_required FUSION_BASE_URL "URL interna do Fusion usada pelo servidor"
ask_required FUSION_LOGIN_URL "URL pública do portal do Fusion"
ask_required CAVIDADES_PUBLIC_URL "URL pública da Cavidades"
ask_required CAVIDADES_HEALTH_URL "URL local da API para validação"
if [[ -z "$DB_FILE" ]]; then
  DB_FILE="$FUSION_HOME/config/cavidades/customfusion.db"
fi
ask_value DB_FILE "Caminho do novo banco SQLite" "$DB_FILE"

if [[ -z "$TOMCAT_USER" && -d "$CATALINA_BASE/webapps" ]]; then
  TOMCAT_USER="$(stat -c '%U' "$CATALINA_BASE/webapps")"
  [[ "$TOMCAT_USER" == "UNKNOWN" ]] && TOMCAT_USER=""
fi
ask_required TOMCAT_USER "Usuário que executa o Tomcat"
ask_required FUSION_FOLDER_BASE "Nome/caminho exato da pasta base de publicação no GED"

read -r -s -p "Token do GED (Enter para configurar depois): " FUSION_API_TOKEN
printf '\n'
trap cleanup EXIT

if [[ ! -d "$SRC" && ! -f "$WAR_SOURCE" ]]; then
  echo "ERRO: pacote incompleto; esperado app/ ou CustomFusionWeb.war ao lado deste script." >&2
  exit 1
fi
if [[ ! -f "$SESSION_SETUP" ]]; then
  echo "ERRO: configurar-sessao-fusion.sh precisa estar junto do instalador." >&2
  exit 1
fi
if [[ -d "$SRC" ]]; then
  if [[ ! -f "$SRC/index.jsp" || ! -f "$SRC/WEB-INF/classes/application.properties" ]]; then
    echo "ERRO: diretório app/ incompleto." >&2
    exit 1
  fi
elif [[ -f "$WAR_SOURCE" ]]; then
  PACKAGE_TMP_DIR="$(mktemp -d /tmp/cavidades-war-XXXXXX)"
  python3 - "$WAR_SOURCE" "$PACKAGE_TMP_DIR" <<'PY'
import shutil
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

war_path = Path(sys.argv[1])
destination = Path(sys.argv[2]).resolve()
with zipfile.ZipFile(war_path) as archive:
    for item in archive.infolist():
        name = item.filename
        path = PurePosixPath(name)
        if "\\" in name or path.is_absolute() or not path.parts or any(part in (".", "..") for part in path.parts):
            raise SystemExit(f"Entrada insegura no WAR: {name}")
        target = (destination.joinpath(*path.parts)).resolve()
        if target != destination and destination not in target.parents:
            raise SystemExit(f"Entrada fora do diretório de extração: {name}")
        mode = (item.external_attr >> 16) & 0o170000
        if mode == stat.S_IFLNK:
            raise SystemExit(f"Link simbólico não permitido no WAR: {name}")
        if item.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(item) as source, target.open("wb") as output:
            shutil.copyfileobj(source, output)
PY
  SRC="$PACKAGE_TMP_DIR"
fi
if [[ ! -f "$SRC/index.jsp" || ! -d "$SRC/WEB-INF/classes" \
  || ! -f "$SRC/WEB-INF/classes/application.properties" ]]; then
  echo "ERRO: pacote sem os arquivos web necessários." >&2
  exit 1
fi
if [[ ! -f "$SRC/WEB-INF/classes/fusion/developer/web/cavidades/seguranca/SessaoFusion.class" ]]; then
  echo "ERRO: o WAR não contém a classe de integração de sessão atualizada." >&2
  echo "Gere o WAR a partir do código atualizado antes de instalar." >&2
  exit 1
fi
if [[ -e "$SRC/WEB-INF/classes/application-local.properties" ]]; then
  echo "ERRO: o pacote inclui application-local.properties; remova configuração local antes de distribuir." >&2
  exit 1
fi
if [[ ! -d "$CATALINA_BASE/webapps" || ! -d "$CATALINA_BASE/conf" ]]; then
  echo "ERRO: Tomcat não encontrado em $CATALINA_BASE." >&2
  exit 1
fi
if [[ ! -e "$FUSION_DOCBASE" ]]; then
  echo "ERRO: docBase do Fusion não encontrado: $FUSION_DOCBASE." >&2
  exit 1
fi
if [[ ! -x "$FUSION_HOME/stop.sh" || ! -x "$FUSION_HOME/start.sh" ]]; then
  echo "ERRO: scripts do Fusion não encontrados em $FUSION_HOME." >&2
  exit 1
fi
if [[ ! "$FUSION_BASE_URL" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "ERRO: URL interna do Fusion inválida." >&2
  exit 1
fi
if [[ ! "$FUSION_LOGIN_URL" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "ERRO: URL pública de login do Fusion inválida." >&2
  exit 1
fi
if [[ "$FUSION_LOGIN_URL" =~ ^https?://(localhost|127\.0\.0\.1)(:|/) ]]; then
  echo "ERRO: a URL de login é usada pelo navegador e não pode apontar para localhost." >&2
  exit 1
fi
if [[ ! "$CAVIDADES_PUBLIC_URL" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "ERRO: URL pública da Cavidades inválida." >&2
  exit 1
fi
if [[ ! "$CAVIDADES_HEALTH_URL" =~ ^https?://[^[:space:]]+$ ]]; then
  echo "ERRO: URL local da API para validação inválida." >&2
  exit 1
fi
if [[ "$DB_FILE" != /* ]]; then
  echo "ERRO: DB_FILE deve ser um caminho absoluto no Linux." >&2
  exit 1
fi
if ! id "$TOMCAT_USER" >/dev/null 2>&1; then
  echo "ERRO: usuário do Tomcat não existe: $TOMCAT_USER." >&2
  exit 1
fi
if [[ -e "$DB_FILE" ]]; then
  echo "ERRO: o banco já existe: $DB_FILE" >&2
  echo "O instalador não reutiliza nem apaga um banco existente." >&2
  exit 1
fi

DB_DIR="$(dirname "$DB_FILE")"
if [[ -d "$DB_DIR" ]] && find "$DB_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  echo "ERRO: o diretório do banco já contém arquivos: $DB_DIR" >&2
  echo "Escolha um diretório novo em DB_FILE para preservar os dados existentes." >&2
  exit 1
fi

TOMCAT_GROUP="$(id -gn "$TOMCAT_USER")"
FUSION_PORTAL_URL="${FUSION_BASE_URL%/}/portal"
CATALINA_CONFIG="$CATALINA_BASE/conf/server.xml"
if [[ ! -f "$CATALINA_CONFIG" ]]; then
  echo "ERRO: configuração do Tomcat não encontrada: $CATALINA_CONFIG." >&2
  exit 1
fi

echo
echo "Resumo (o token não será exibido):"
echo "  Tomcat: $CATALINA_BASE"
echo "  Fusion: $FUSION_HOME"
echo "  Fusion docBase: $FUSION_DOCBASE"
echo "  Usuário Tomcat: $TOMCAT_USER:$TOMCAT_GROUP"
echo "  URL interna Fusion: $FUSION_BASE_URL"
echo "  URL pública de login: $FUSION_LOGIN_URL"
echo "  URL pública Cavidades: $CAVIDADES_PUBLIC_URL"
echo "  URL de validação da API: $CAVIDADES_HEALTH_URL"
echo "  Pasta GED: $FUSION_FOLDER_BASE"
echo "  Banco novo: $DB_FILE"
if [[ -n "$FUSION_API_TOKEN" ]]; then
  GED_TOKEN_CONFIGURED=true
  echo "  Token GED: informado (será gravado somente no servidor)"
else
  GED_TOKEN_CONFIGURED=false
  echo "  Token GED: não informado (publicação no GED ficará desabilitada até configurá-lo)"
fi
echo
echo "A instalação reiniciará os serviços Fusion e usará sessionCookiePath=/."
echo "O cookie do Fusion será enviado a todos os aplicativos no mesmo host e porta."
read -r -p "Confirma a instalação? Digite SIM: " confirmacao
if [[ "$confirmacao" != "SIM" ]]; then
  unset FUSION_API_TOKEN
  echo "Cancelado; nenhuma alteração foi feita."
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/tmp/cavidades-instalacao-backup-$STAMP-$$"
STAGE_DIR="$CATALINA_BASE/temp/cavidades-install-$STAMP-$$"
trap cleanup EXIT
mkdir -p "$CATALINA_BASE/temp" "$STAGE_DIR"

cp -a "$SRC/." "$STAGE_DIR/"
{
  printf 'app.sqlite.path=%s\n' "$DB_FILE"
  printf 'app.fusion.base-url=%s\n' "$FUSION_BASE_URL"
  printf 'app.fusion.login-url=%s\n' "$FUSION_LOGIN_URL"
  printf 'app.fusion.api-token=%s\n' "$FUSION_API_TOKEN"
  printf 'app.fusion.folder-base=%s\n' "$FUSION_FOLDER_BASE"
} > "$STAGE_DIR/WEB-INF/classes/application-local.properties"
unset FUSION_API_TOKEN

mkdir -p "$DB_DIR"
chown -R "$TOMCAT_USER:$TOMCAT_GROUP" "$STAGE_DIR"
chmod 0755 "$STAGE_DIR"
chown "$TOMCAT_USER:$TOMCAT_GROUP" "$DB_DIR"
chmod 0750 "$DB_DIR"
chmod 0640 "$STAGE_DIR/WEB-INF/classes/application-local.properties"

FUSION_CONFIG_ONLY=true \
CATALINA_BASE="$CATALINA_BASE" \
FUSION_HOME="$FUSION_HOME" \
FUSION_DOCBASE="$FUSION_DOCBASE" \
FUSION_PORTAL_URL="$FUSION_PORTAL_URL" \
bash "$SESSION_SETUP"

echo "Parando os serviços Fusion para instalar..."
bash "$FUSION_HOME/stop.sh"

APP_DIR="$CATALINA_BASE/webapps/cavidades"
WAR_FILE="$CATALINA_BASE/webapps/cavidades.war"
if [[ -e "$APP_DIR" || -e "$WAR_FILE" ]]; then
  mkdir -m 0700 "$BACKUP"
  if [[ -e "$APP_DIR" ]]; then
    mv "$APP_DIR" "$BACKUP/cavidades"
  fi
  if [[ -e "$WAR_FILE" ]]; then
    mv "$WAR_FILE" "$BACKUP/cavidades.war"
  fi
fi

mv "$STAGE_DIR" "$APP_DIR"
STAGE_DIR=""

echo "Aplicação: $APP_DIR"
echo "Banco novo será criado em: $DB_FILE"
if [[ -d "$BACKUP" ]]; then
  echo "Aplicação anterior preservada em: $BACKUP"
fi
echo "Iniciando os serviços Fusion..."
bash "$FUSION_HOME/start.sh"

HEADERS="$(mktemp)"
HTTP_CODE=""
COOKIE_PATH=""
for _ in $(seq 1 60); do
  HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
    "$CAVIDADES_HEALTH_URL" 2>/dev/null || true)"
  : > "$HEADERS"
  curl -sS -D "$HEADERS" -o /dev/null "$FUSION_PORTAL_URL" 2>/dev/null || true
  COOKIE_PATH="$(python3 - "$HEADERS" <<'PY'
import re
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(errors="replace").splitlines():
    if not line.lower().startswith("set-cookie:"):
        continue
    cookie = line.split(":", 1)[1].strip()
    if cookie.split("=", 1)[0].strip().lower() != "jsessionid":
        continue
    path = re.search(r"(?:^|;)\s*path=([^;]*)", cookie, re.IGNORECASE)
    print(path.group(1).strip() if path else "(Path não informado)")
    break
PY
)"
  if [[ "$HTTP_CODE" == "200" && "$COOKIE_PATH" == "/" ]]; then
    break
  fi
  sleep 2
done

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERRO: API não respondeu HTTP 200 (recebido: ${HTTP_CODE:-sem resposta})." >&2
  echo "Confira os logs em $CATALINA_BASE/logs/ e preserve o backup acima." >&2
  exit 1
fi
if [[ "$COOKIE_PATH" != "/" ]]; then
  echo "ERRO: Fusion não emitiu JSESSIONID com Path=/ (recebido: ${COOKIE_PATH:-nenhum})." >&2
  echo "Confira $CATALINA_CONFIG e preserve o backup do server.xml." >&2
  exit 1
fi

echo "API respondeu HTTP 200 e JSESSIONID está com Path=/."
echo "Acesse: $CAVIDADES_PUBLIC_URL"
echo "Entre no Fusion e confirme que /cavidades/api/usuario-atual retorna autenticado=true."
echo "application-local.properties foi gravado somente no servidor com permissão restrita."
if [[ "$GED_TOKEN_CONFIGURED" == "false" ]]; then
  echo "Configure app.fusion.api-token em $APP_DIR/WEB-INF/classes/application-local.properties para publicar no GED."
fi
