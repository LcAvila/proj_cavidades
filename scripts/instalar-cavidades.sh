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
FUSION_DOCBASE_PATH="${FUSION_DOCBASE_PATH:-}"
SERVER_URL="${SERVER_URL:-}"
SERVER_ORIGIN="${SERVER_ORIGIN:-}"
FUSION_BASE_URL="${FUSION_BASE_URL:-}"
FUSION_LOGIN_URL="${FUSION_LOGIN_URL:-}"
FUSION_PORTAL_URL="${FUSION_PORTAL_URL:-}"
CAVIDADES_PUBLIC_URL="${CAVIDADES_PUBLIC_URL:-}"
CAVIDADES_HEALTH_URL="${CAVIDADES_HEALTH_URL:-}"
DB_FILE="${DB_FILE:-}"
TOMCAT_USER="${TOMCAT_USER:-}"
FUSION_FOLDER_BASE="${FUSION_FOLDER_BASE:-}"
PACKAGE_TMP_DIR=""
STAGE_DIR=""
HEADERS=""
FUSION_STOPPED=false
BACKUP=""
APP_DIR=""
WAR_FILE=""
LOCAL_CONFIG=""
PRESERVE_LOCAL_CONFIG=false
DB_EXISTS=false

ask_value() {
  local variable="$1"
  local label="$2"
  local default="$3"
  local answer
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " answer
  else
    read -r -p "$label (Enter para configurar depois): " answer
  fi
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
  local status=$?
  trap - EXIT
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
  if [[ "$FUSION_STOPPED" == true ]]; then
    if [[ -n "$BACKUP" && -d "$BACKUP" ]]; then
      if [[ ! -e "$APP_DIR" && -e "$BACKUP/cavidades" ]]; then
        if ! mv "$BACKUP/cavidades" "$APP_DIR"; then
          echo "ERRO: não foi possível restaurar a aplicação anterior de $BACKUP." >&2
          status=1
        fi
      fi
      if [[ ! -e "$WAR_FILE" && -e "$BACKUP/cavidades.war" ]]; then
        if ! mv "$BACKUP/cavidades.war" "$WAR_FILE"; then
          echo "ERRO: não foi possível restaurar o WAR anterior de $BACKUP." >&2
          status=1
        fi
      fi
    fi
    echo "A instalação foi interrompida; tentando iniciar os serviços Fusion..." >&2
    if bash "$FUSION_HOME/start.sh"; then
      FUSION_STOPPED=false
    else
      echo "ERRO: não foi possível iniciar os serviços Fusion automaticamente." >&2
      status=1
    fi
  fi
  exit "$status"
}

detect_fusion_layout() {
  local detected
  local -a values=()
  detected="$(python3 - <<'PY'
import glob
import os
import pwd
import xml.etree.ElementTree as ET
from pathlib import Path

def local_name(tag):
    return tag.rsplit("}", 1)[-1]

def context_for(base):
    config = base / "conf" / "server.xml"
    if not config.is_file() or not (base / "webapps").is_dir():
        return None
    try:
        root = ET.parse(config).getroot()
    except (OSError, ET.ParseError):
        return None

    matches = []
    for host in root.iter():
        if local_name(host.tag) != "Host":
            continue
        app_base = Path(host.get("appBase", "webapps"))
        if not app_base.is_absolute():
            app_base = base / app_base
        for context in host.iter():
            if local_name(context.tag) == "Context" and context.get("path") == "/fusion":
                docbase = context.get("docBase")
                if not docbase:
                    continue
                resolved = Path(docbase)
                if not resolved.is_absolute():
                    resolved = app_base / resolved
                matches.append((docbase, resolved))
    return matches

requested_base = os.environ.get("CATALINA_BASE", "").strip()
requested_home = os.environ.get("FUSION_HOME", "").strip()
requested_docbase = os.environ.get("FUSION_DOCBASE", "").strip()
candidates = []
if requested_base:
    candidates.append(Path(requested_base))
else:
    for procfile in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            args = Path(procfile).read_bytes().split(b"\0")
            args = [arg.decode(errors="replace") for arg in args if arg]
        except OSError:
            continue
        if not any("org.apache.catalina.startup.Bootstrap" in arg for arg in args):
            continue
        for arg in args:
            if arg.startswith("-Dcatalina.base="):
                candidates.append(Path(arg.split("=", 1)[1]))
                break

    for pattern in (
        "/opt/tomcat/*/conf/server.xml",
        "/opt/tomcat/conf/server.xml",
        "/opt/apache-tomcat*/conf/server.xml",
        "/opt/*/conf/server.xml",
        "/usr/local/tomcat/conf/server.xml",
        "/usr/share/tomcat*/conf/server.xml",
        "/var/lib/tomcat*/conf/server.xml",
    ):
        candidates.extend(Path(path).parent.parent for path in glob.glob(pattern))

unique_bases = list(dict.fromkeys(path.resolve() for path in candidates))
layouts = []
for base in unique_bases:
    contexts = context_for(base)
    if not contexts:
        continue
    for docbase, resolved_docbase in contexts:
        if requested_docbase and docbase != requested_docbase:
            continue
        home = Path(requested_home).resolve() if requested_home else None
        if home is None:
            probe = resolved_docbase if resolved_docbase.is_dir() else resolved_docbase.parent
            for candidate in (probe, *probe.parents):
                if (candidate / "stop.sh").is_file() and (candidate / "start.sh").is_file():
                    home = candidate
                    break
        if home is None:
            continue
        if not (home / "stop.sh").is_file() or not (home / "start.sh").is_file():
            continue
        try:
            owner = os.environ.get("TOMCAT_USER", "").strip()
            if not owner:
                owner = pwd.getpwuid(os.stat(base / "webapps").st_uid).pw_name
        except (OSError, KeyError):
            continue
        layouts.append((str(base), docbase, str(resolved_docbase), str(home), owner))

layouts = list(dict.fromkeys(layouts))
if len(layouts) != 1:
    if not layouts:
        raise SystemExit(
            "Não foi possível detectar um único Tomcat com o contexto /fusion e os scripts do Fusion. "
            "Confira o Tomcat em execução ou defina CATALINA_BASE, FUSION_HOME e FUSION_DOCBASE."
        )
    bases = ", ".join(item[0] for item in layouts)
    raise SystemExit(
        "Mais de uma instalação Fusion compatível foi detectada: "
        + bases
        + ". Defina CATALINA_BASE e FUSION_DOCBASE para escolher a correta."
    )
print("\n".join(layouts[0]))
PY
)" || return 1
  mapfile -t values <<< "$detected"
  if [[ "${#values[@]}" -ne 5 ]]; then
    echo "ERRO: não foi possível interpretar os caminhos detectados do Fusion." >&2
    return 1
  fi
  CATALINA_BASE="${CATALINA_BASE:-${values[0]}}"
  FUSION_DOCBASE="${FUSION_DOCBASE:-${values[1]}}"
  FUSION_DOCBASE_PATH="${FUSION_DOCBASE_PATH:-${values[2]}}"
  FUSION_HOME="${FUSION_HOME:-${values[3]}}"
  TOMCAT_USER="${TOMCAT_USER:-${values[4]}}"
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERRO: execute como root (por exemplo: sudo bash ./instalar-cavidades.sh)." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "ERRO: python3 e curl precisam estar instalados." >&2
  exit 1
fi

if ! detect_fusion_layout; then
  echo "ERRO: ajuste as variáveis CATALINA_BASE, FUSION_HOME e FUSION_DOCBASE e execute novamente." >&2
  exit 1
fi
APP_DIR="$CATALINA_BASE/webapps/cavidades"
WAR_FILE="$CATALINA_BASE/webapps/cavidades.war"
LOCAL_CONFIG="$APP_DIR/WEB-INF/classes/application-local.properties"
if [[ -L "$LOCAL_CONFIG" ]]; then
  echo "ERRO: a configuração local da instalação é um link simbólico: $LOCAL_CONFIG" >&2
  exit 1
fi
if [[ -L "$APP_DIR/assets" ]]; then
  echo "ERRO: a pasta assets da instalação é um link simbólico: $APP_DIR/assets" >&2
  exit 1
fi
if [[ -e "$APP_DIR/assets" && ! -d "$APP_DIR/assets" ]]; then
  echo "ERRO: o caminho de assets da instalação não é uma pasta: $APP_DIR/assets" >&2
  exit 1
fi
if [[ -z "$DB_FILE" ]]; then
  DB_FILE="$FUSION_HOME/config/cavidades/customfusion.db"
  if [[ -f "$LOCAL_CONFIG" ]]; then
    CONFIGURED_DB="$(python3 - "$LOCAL_CONFIG" <<'PY'
import sys
from pathlib import Path

def unescape(value):
    result = []
    index = 0
    escapes = {"t": "\t", "n": "\n", "r": "\r", "f": "\f"}
    while index < len(value):
        char = value[index]
        index += 1
        if char != "\\" or index == len(value):
            result.append(char)
            continue
        escaped = value[index]
        index += 1
        if escaped == "u" and index + 4 <= len(value):
            digits = value[index:index + 4]
            try:
                result.append(chr(int(digits, 16)))
                index += 4
                continue
            except ValueError:
                pass
        result.append(escapes.get(escaped, escaped))
    return "".join(result)

def properties(path):
    text = Path(path).read_text(encoding="utf-8")
    logical_lines = []
    pending = ""
    for physical in text.splitlines():
        line = pending + (physical.lstrip(" \t\f") if pending else physical)
        slashes = len(line) - len(line.rstrip("\\"))
        if slashes % 2:
            pending = line[:-1]
            continue
        logical_lines.append(line)
        pending = ""
    if pending:
        logical_lines.append(pending)

    result = {}
    for line in logical_lines:
        line = line.lstrip(" \t\f")
        if not line or line[0] in "#!":
            continue
        escaped = False
        split_at = len(line)
        for index, char in enumerate(line):
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char in "=:" or char.isspace():
                split_at = index
                break
        key = line[:split_at]
        index = split_at
        if index < len(line) and line[index].isspace():
            while index < len(line) and line[index].isspace():
                index += 1
            if index < len(line) and line[index] in "=:":
                index += 1
        elif index < len(line):
            index += 1
        while index < len(line) and line[index].isspace():
            index += 1
        result[unescape(key)] = unescape(line[index:])
    return result

print(properties(sys.argv[1]).get("app.sqlite.path", ""))
PY
)" || exit 1
    if [[ -n "$CONFIGURED_DB" ]]; then
      DB_FILE="$CONFIGURED_DB"
    fi
  fi
fi

if [[ -z "$SERVER_URL" ]]; then
  ask_required SERVER_URL "URL do servidor/Fusion (ex.: https://servidor ou https://servidor/fusion)"
fi
SERVER_ORIGIN="$(python3 - "$SERVER_URL" <<'PY'
import sys
from urllib.parse import urlsplit

value = sys.argv[1].strip()
try:
    url = urlsplit(value)
    _ = url.port
except ValueError as error:
    raise SystemExit(f"URL inválida: {error}")
if (url.scheme not in ("http", "https") or not url.netloc or not url.hostname
        or url.username or url.password or url.query or url.fragment
        or url.path.rstrip("/") not in ("", "/fusion")):
    raise SystemExit(
        "Informe apenas a URL base do servidor ou a URL terminada em /fusion, "
        "sem parâmetros."
    )
print(f"{url.scheme}://{url.netloc}")
PY
)" || exit 1
FUSION_BASE_URL="${FUSION_BASE_URL:-$SERVER_ORIGIN/fusion}"
FUSION_LOGIN_URL="${FUSION_LOGIN_URL:-$FUSION_BASE_URL}"
CAVIDADES_PUBLIC_URL="${CAVIDADES_PUBLIC_URL:-$SERVER_ORIGIN/cavidades}"
CAVIDADES_HEALTH_URL="${CAVIDADES_HEALTH_URL:-$SERVER_ORIGIN/cavidades/api/usuario-atual}"
FUSION_PORTAL_URL="${FUSION_PORTAL_URL:-${FUSION_BASE_URL%/}/portal}"
DB_FILE="${DB_FILE:-$FUSION_HOME/config/cavidades/customfusion.db}"
GED_API_URL="${FUSION_BASE_URL%/}"
if [[ "$GED_API_URL" != */fusion ]]; then
  GED_API_URL+="/fusion"
fi
GED_API_URL+="/api/v1/documents/"

echo "Tomcat e Fusion detectados automaticamente:"
echo "  Tomcat: $CATALINA_BASE"
echo "  Fusion: $FUSION_HOME"
echo "  Contexto Fusion: $FUSION_DOCBASE"
echo "URLs derivadas da URL informada:"
echo "  API GED padrão: $GED_API_URL"
echo "  Aplicação: $CAVIDADES_PUBLIC_URL"

if [[ -f "$LOCAL_CONFIG" ]]; then
  PRESERVE_LOCAL_CONFIG=true
  FUSION_FOLDER_BASE=""
  FUSION_API_TOKEN=""
  echo "Configuração GED local existente será preservada sem exibir o token."
else
  if [[ -z "$FUSION_FOLDER_BASE" ]]; then
    ask_value FUSION_FOLDER_BASE "Pasta base de destino no GED" ""
  fi
  if [[ -n "$FUSION_FOLDER_BASE" ]]; then
    read -r -s -p "Token do GED (Enter para configurar depois): " FUSION_API_TOKEN
    printf '\n'
  else
    FUSION_API_TOKEN=""
    echo "Pasta GED não informada; a publicação no GED ficará desabilitada até configurá-la."
  fi
fi
trap cleanup EXIT

echo "Configuração da nova instalação da Cavidades."

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
if [[ ! -e "$FUSION_DOCBASE_PATH" ]]; then
  echo "ERRO: docBase do Fusion não encontrado: $FUSION_DOCBASE_PATH." >&2
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
DB_DIR="$(dirname "$DB_FILE")"
if [[ -L "$DB_FILE" ]]; then
  echo "ERRO: o arquivo do banco é um link simbólico: $DB_FILE" >&2
  exit 1
elif [[ -e "$DB_FILE" ]]; then
  DB_EXISTS=true
  if ! python3 - "$DB_FILE" <<'PY'
import sqlite3
import sys
from pathlib import Path

path = Path(sys.argv[1])
uri = path.as_uri() + "?mode=ro"
try:
    connection = sqlite3.connect(uri, uri=True, timeout=30)
    connection.execute("PRAGMA busy_timeout=30000")
    result = connection.execute("PRAGMA integrity_check").fetchone()
    if result != ("ok",):
        raise SystemExit(f"ERRO: integrity_check do banco falhou: {result}")
    history = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND lower(name)='historico_grades'"
    ).fetchone()
    if history:
        raise SystemExit(
            "ERRO: este banco contém a tabela historico_grades, que o esquema "
            "do pacote atual removeria na inicialização. Nenhuma alteração foi feita."
        )
except sqlite3.Error as error:
    raise SystemExit(f"ERRO: não foi possível validar o banco SQLite: {error}")
finally:
    if "connection" in locals():
        connection.close()
PY
  then
    exit 1
  fi
else
  DB_EXISTS=false
  if [[ -d "$DB_DIR" ]] && find "$DB_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    echo "ERRO: o diretório do banco já contém arquivos: $DB_DIR" >&2
    echo "Defina DB_FILE para um caminho novo e vazio para uma instalação nova." >&2
    exit 1
  fi
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
if [[ "$PRESERVE_LOCAL_CONFIG" == true ]]; then
  echo "  Configuração GED: local existente será preservada (token não exibido)"
else
  echo "  Pasta GED: $FUSION_FOLDER_BASE"
fi
if [[ "$DB_EXISTS" == true ]]; then
  echo "  Banco existente: será preservado; backup SQLite será criado e validado"
else
  echo "  Banco novo: $DB_FILE"
fi
if [[ "$PRESERVE_LOCAL_CONFIG" == true ]]; then
  GED_TOKEN_CONFIGURED=true
  echo "  Token GED: configuração local preservada sem exibição"
elif [[ -n "$FUSION_API_TOKEN" ]]; then
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
if [[ "$PRESERVE_LOCAL_CONFIG" == true ]]; then
  LOCAL_CONFIG_STAGE="$STAGE_DIR/WEB-INF/classes/application-local.properties"
  cp -p "$LOCAL_CONFIG" "$LOCAL_CONFIG_STAGE"
  python3 - "$LOCAL_CONFIG_STAGE" "$DB_FILE" "$FUSION_BASE_URL" "$FUSION_LOGIN_URL" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])

def escape(value):
    value = value.replace("\\", "\\\\").replace("\t", "\\t")
    value = value.replace("\n", "\\n").replace("\r", "\\r")
    if value.startswith((" ", "\f")):
        value = "\\" + value
    return value

with path.open("a", encoding="utf-8", newline="\n") as config:
    if path.stat().st_size:
        config.write("\n")
    config.write("# Atualizado pelo instalador da Cavidades; demais propriedades locais preservadas.\n")
    config.write(f"app.sqlite.path={escape(sys.argv[2])}\n")
    config.write(f"app.fusion.base-url={escape(sys.argv[3])}\n")
    config.write(f"app.fusion.login-url={escape(sys.argv[4])}\n")
PY
else
  {
    printf 'app.sqlite.path=%s\n' "$DB_FILE"
    printf 'app.fusion.base-url=%s\n' "$FUSION_BASE_URL"
    printf 'app.fusion.login-url=%s\n' "$FUSION_LOGIN_URL"
    printf 'app.fusion.api-token=%s\n' "$FUSION_API_TOKEN"
    printf 'app.fusion.folder-base=%s\n' "$FUSION_FOLDER_BASE"
  } > "$STAGE_DIR/WEB-INF/classes/application-local.properties"
fi
unset FUSION_API_TOKEN

if [[ "$DB_EXISTS" != true ]]; then
  mkdir -p "$DB_DIR"
  chown "$TOMCAT_USER:$TOMCAT_GROUP" "$DB_DIR"
  chmod 0750 "$DB_DIR"
fi
chown -R "$TOMCAT_USER:$TOMCAT_GROUP" "$STAGE_DIR"
chmod 0755 "$STAGE_DIR"
chown "$TOMCAT_USER:$TOMCAT_GROUP" "$STAGE_DIR/WEB-INF/classes/application-local.properties"
chmod 0640 "$STAGE_DIR/WEB-INF/classes/application-local.properties"

echo "Parando os serviços Fusion para instalar..."
FUSION_STOPPED=true
bash "$FUSION_HOME/stop.sh"

if [[ "$DB_EXISTS" == true ]]; then
  DB_BACKUP="$(python3 - "$DB_FILE" "$STAMP" <<'PY'
import os
import sqlite3
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
backup_path = source_path.with_name(
    f"{source_path.name}.backup-{sys.argv[2]}-{os.getpid()}"
)
source_uri = source_path.as_uri() + "?mode=ro"
source = None
backup = None
created = False
try:
    descriptor = os.open(backup_path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    os.close(descriptor)
    created = True
    source = sqlite3.connect(source_uri, uri=True, timeout=30)
    source.execute("PRAGMA busy_timeout=30000")
    integrity = source.execute("PRAGMA integrity_check").fetchone()
    if integrity != ("ok",):
        raise RuntimeError(f"integrity_check do banco falhou: {integrity}")
    history = source.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND lower(name)='historico_grades'"
    ).fetchone()
    if history:
        raise RuntimeError(
            "o banco contém historico_grades, que o esquema atual removeria"
        )
    backup = sqlite3.connect(backup_path, timeout=30)
    source.backup(backup, pages=1000, sleep=0.1)
    backup.commit()
    integrity = backup.execute("PRAGMA integrity_check").fetchone()
    if integrity != ("ok",):
        raise RuntimeError(f"integrity_check do backup falhou: {integrity}")
    backup.close()
    backup = None
    source.close()
    source = None
    os.chmod(backup_path, 0o600)
    verified_file = os.open(backup_path, os.O_RDWR)
    try:
        os.fsync(verified_file)
    finally:
        os.close(verified_file)
    if os.name == "posix":
        directory = os.open(backup_path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    print(backup_path)
except Exception as error:
    if backup is not None:
        backup.close()
    if source is not None:
        source.close()
    if created:
        backup_path.unlink(missing_ok=True)
    raise SystemExit(f"ERRO: backup SQLite não foi criado/verificado: {error}")
PY
  )"
  echo "Backup SQLite íntegro e preservado em: $DB_BACKUP"
fi
if [[ -d "$APP_DIR/assets" ]]; then
  cp -a "$APP_DIR/assets" "$STAGE_DIR/assets"
  echo "Arquivos locais preservados de: $APP_DIR/assets"
fi

FUSION_CONFIG_ONLY=true \
CATALINA_BASE="$CATALINA_BASE" \
FUSION_HOME="$FUSION_HOME" \
FUSION_DOCBASE="$FUSION_DOCBASE" \
FUSION_PORTAL_URL="$FUSION_PORTAL_URL" \
bash "$SESSION_SETUP"

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
if [[ "$DB_EXISTS" == true ]]; then
  echo "Banco existente preservado em: $DB_FILE"
  echo "Backup SQLite verificado em: $DB_BACKUP"
else
  echo "Banco novo será criado em: $DB_FILE"
fi
if [[ -d "$BACKUP" ]]; then
  echo "Aplicação anterior preservada em: $BACKUP"
fi
echo "Iniciando os serviços Fusion..."
bash "$FUSION_HOME/start.sh"
FUSION_STOPPED=false

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
if [[ "$PRESERVE_LOCAL_CONFIG" == true ]]; then
  echo "Configurações locais da instalação anterior, incluindo as do GED, foram preservadas."
elif [[ -z "$FUSION_FOLDER_BASE" ]]; then
  echo "Configure app.fusion.folder-base e app.fusion.api-token em $APP_DIR/WEB-INF/classes/application-local.properties para publicar no GED."
elif [[ "$GED_TOKEN_CONFIGURED" == "false" ]]; then
  echo "Configure app.fusion.api-token em $APP_DIR/WEB-INF/classes/application-local.properties para publicar no GED."
fi
