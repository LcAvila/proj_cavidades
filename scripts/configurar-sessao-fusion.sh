#!/usr/bin/env bash
set -euo pipefail

CATALINA_BASE="${CATALINA_BASE:-}"
FUSION_HOME="${FUSION_HOME:-}"
FUSION_DOCBASE="${FUSION_DOCBASE:-}"
FUSION_PORTAL_URL="${FUSION_PORTAL_URL:-}"
FUSION_CONFIG_ONLY="${FUSION_CONFIG_ONLY:-false}"

ask_required() {
  local variable="$1"
  local label="$2"
  local answer
  while true; do
    read -r -p "$label: " answer
    if [[ -n "$answer" ]]; then
      printf -v "$variable" '%s' "$answer"
      return
    fi
    echo "Este valor é obrigatório."
  done
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERRO: execute como root (por exemplo: sudo bash ./configurar-sessao-fusion.sh)." >&2
  exit 1
fi

[[ -n "$CATALINA_BASE" ]] || ask_required CATALINA_BASE "Diretório base do Tomcat do Fusion"
[[ -n "$FUSION_HOME" ]] || ask_required FUSION_HOME "Diretório do Fusion (contém stop.sh/start.sh)"
[[ -n "$FUSION_DOCBASE" ]] || ask_required FUSION_DOCBASE "Caminho do Fusion usado em server.xml"
if [[ "$FUSION_CONFIG_ONLY" != "true" && -z "$FUSION_PORTAL_URL" ]]; then
  ask_required FUSION_PORTAL_URL "URL do portal Fusion para validar o cookie"
fi

CONTEXT_FILE="$CATALINA_BASE/conf/server.xml"
if [[ ! -f "$CONTEXT_FILE" ]]; then
  echo "ERRO: configuração do Tomcat não encontrada: $CONTEXT_FILE" >&2
  echo "Informe o caminho correto com CATALINA_BASE=/caminho/do/tomcat." >&2
  exit 1
fi
if [[ ! -x "$FUSION_HOME/stop.sh" || ! -x "$FUSION_HOME/start.sh" ]]; then
  echo "ERRO: scripts do Fusion não encontrados em $FUSION_HOME." >&2
  echo "Informe o caminho correto com FUSION_HOME=/caminho/do/fusion." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERRO: este script precisa de python3 instalado." >&2
  exit 1
fi
if [[ "$FUSION_CONFIG_ONLY" != "true" ]] && ! command -v curl >/dev/null 2>&1; then
  echo "ERRO: este script precisa de curl instalado." >&2
  exit 1
fi

echo "Este procedimento vai:"
echo "  - ajustar somente o contexto Fusion em $CONTEXT_FILE"
echo "  - criar um backup do server.xml"
if [[ "$FUSION_CONFIG_ONLY" == "true" ]]; then
  echo "  - deixar o reinício para o instalador principal"
else
  echo "  - reiniciar os serviços Fusion"
fi
echo "  - configurar o cookie de sessão com Path=/ (visível a todos os apps neste host)"
read -r -p "Confirma? Digite SIM: " confirmacao
if [[ "$confirmacao" != "SIM" ]]; then
  echo "Cancelado; nenhuma alteração foi feita."
  if [[ "$FUSION_CONFIG_ONLY" == "true" ]]; then
    exit 1
  fi
  exit 0
fi

BACKUP="$CONTEXT_FILE.bak.$(date +%Y%m%d-%H%M%S)"
if [[ -e "$BACKUP" ]]; then
  BACKUP="$BACKUP.$$.bak"
fi
cp -a "$CONTEXT_FILE" "$BACKUP"

python3 - "$CONTEXT_FILE" "$FUSION_DOCBASE" <<'PY'
import os
import re
import stat
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

path = Path(sys.argv[1])
fusion_docbase = sys.argv[2]
original = path.read_bytes()
text = original.decode("utf-8")
tag_pattern = re.compile(r"""<Context\b(?:[^>"']|"[^"]*"|'[^']*')*>""", re.DOTALL)
matches = []

for match in tag_pattern.finditer(text):
    tag = match.group(0)
    parseable_tag = tag[:-1].rstrip()
    if not parseable_tag.endswith("/"):
        parseable_tag += "/"
    element = ET.fromstring(parseable_tag + ">")
    if (element.attrib.get("path") == "/fusion"
            and element.attrib.get("docBase") == fusion_docbase):
        matches.append(match)

if len(matches) != 1:
    raise SystemExit(
        f"ERRO: esperado exatamente um Context com path=/fusion e "
        f"docBase={fusion_docbase}; encontrados: {len(matches)}. "
        "Nenhuma alteração foi feita."
    )

match = matches[0]
tag = match.group(0)
cookie_path = re.search(
    r"""(\bsessionCookiePath\s*=\s*)(["'])(.*?)\2""", tag, re.DOTALL
)
if cookie_path:
    replacement = cookie_path.group(1) + cookie_path.group(2) + "/" + cookie_path.group(2)
    updated_tag = tag[:cookie_path.start()] + replacement + tag[cookie_path.end():]
    changed = cookie_path.group(3) != "/"
else:
    insert_at = tag.rfind("/>")
    if insert_at < 0:
        insert_at = tag.rfind(">")
    updated_tag = tag[:insert_at].rstrip() + ' sessionCookiePath="/"' + tag[insert_at:]
    changed = True

updated = text[:match.start()] + updated_tag + text[match.end():]
ET.fromstring(updated)

if changed:
    file_stat = path.stat()
    fd, temporary_name = tempfile.mkstemp(prefix=".server.xml.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as temporary:
            temporary.write(updated.encode("utf-8"))
        os.chmod(temporary_name, stat.S_IMODE(file_stat.st_mode))
        os.chown(temporary_name, file_stat.st_uid, file_stat.st_gid)
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
    print("sessionCookiePath=/ aplicado ao contexto Fusion.")
else:
    print("sessionCookiePath=/ já estava configurado no contexto Fusion.")
PY

echo "Backup criado: $BACKUP"
if [[ "$FUSION_CONFIG_ONLY" == "true" ]]; then
  echo "Configuração salva; o instalador principal reiniciará os serviços Fusion."
  exit 0
fi

echo "Reiniciando os serviços Fusion..."
bash "$FUSION_HOME/stop.sh"
bash "$FUSION_HOME/start.sh"

HEADERS="$(mktemp)"
trap 'rm -f -- "$HEADERS"' EXIT
COOKIE_PATH=""
for _ in $(seq 1 60); do
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
    name = cookie.split("=", 1)[0].strip()
    if name.lower() != "jsessionid":
        continue
    path = re.search(r"(?:^|;)\s*path=([^;]*)", cookie, re.IGNORECASE)
    print(path.group(1).strip() if path else "(Path não informado)")
    break
PY
)"
  if [[ "$COOKIE_PATH" == "/" ]]; then
    break
  fi
  sleep 2
done

if [[ "$COOKIE_PATH" != "/" ]]; then
  echo "ERRO: não foi confirmado JSESSIONID com Path=/ (recebido: ${COOKIE_PATH:-nenhum})." >&2
  echo "Backup preservado em: $BACKUP" >&2
  echo "Verifique o contexto ativo em $CONTEXT_FILE e os logs do Tomcat." >&2
  exit 1
fi

echo "OK: servidor emitiu JSESSIONID com Path=/."
echo "Remova os cookies antigos no navegador, faça login novamente no Fusion e teste:"
echo "  /cavidades/api/usuario-atual"
echo 'O campo "autenticado" deve ser true.'
