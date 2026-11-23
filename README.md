# Cavidades

Pacote de implantação do Controle de Cavidades: aplicação web para acompanhar
grades e não conformidades de moldes, visualizar modelos 3D e publicar relatórios
no GED do Fusion.

Este repositório contém o WAR pronto para implantação, scripts e documentação
operacional. O código-fonte Java não está neste repositório.

## Sumário

- [O que há neste repositório](#o-que-há-neste-repositório)
- [Requisitos](#requisitos)
- [Como funciona a instalação](#como-funciona-a-instalação)
- [1. Clonar o repositório](#1-clonar-o-repositório)
- [2. Enviar os arquivos ao servidor](#2-enviar-os-arquivos-ao-servidor)
- [3. Validar os arquivos no servidor](#3-validar-os-arquivos-no-servidor)
- [4. Executar o instalador](#4-executar-o-instalador)
- [5. Instalação nova x atualização](#5-instalação-nova-x-atualização)
- [6. Verificar depois de instalar](#6-verificar-depois-de-instalar)
- [7. Configurar a publicação no GED](#7-configurar-a-publicação-no-ged)
- [Problemas comuns](#problemas-comuns)
- [APIs](#apis)
- [Artefato](#artefato)

## O que há neste repositório

```text
proj_cavidades/
├── dist/
│   └── CustomFusionWeb.war          # pacote pronto para implantar (sem compilar)
├── scripts/
│   ├── instalar-cavidades.sh        # instalador / atualizador (roda como root)
│   └── configurar-sessao-fusion.sh  # ajusta sessionCookiePath=/ no server.xml
├── docs/
│   ├── migracao-servidor-linux.md   # guia completo de implantação Linux
│   └── aps-setup.md                 # viewer 3D opcional (Autodesk APS)
├── .gitattributes                   # mantém os .sh em LF (evita erro de CRLF)
└── README.md
```

Não há nada para compilar: o WAR já está versionado em `dist/`. Os três arquivos
(`CustomFusionWeb.war`, `instalar-cavidades.sh`, `configurar-sessao-fusion.sh`)
são enviados juntos ao servidor e ficam lado a lado em `/tmp/cavidades`.

## Requisitos

- Fusion já instalado no servidor, com `stop.sh` e `start.sh`;
- Tomcat 10.1+ e Java 21+;
- Linux com `python3`, `curl` e acesso root (sudo);
- SSH/SCP a partir do computador Windows;
- autorização para alterar o `server.xml` do Tomcat do Fusion.

O catálogo e as grades operacionais são armazenados em SQLite. A integração com
o GED exige token e permissão de publicação na pasta de destino. Autodesk APS é
opcional; o visualizador 3D local continua disponível sem APS.

O pacote publicado não inclui catálogo empresarial, banco SQLite com dados,
desenhos, imagens de peças, modelos STL nem logo. Na primeira inicialização, a
aplicação cria um banco vazio com o esquema necessário. Os dados e arquivos do
ambiente devem ser cadastrados ou enviados diretamente ao servidor.

## Como funciona a instalação

Fluxo resumido — nada é alterado antes do resumo e da confirmação `SIM`:

```text
Windows                      Servidor Linux
-------                      -------------
git pull
scp dos 3 arquivos   --->   /tmp/cavidades/
                             bash -n (sintaxe) + sha256sum (hash)
                             bash ./instalar-cavidades.sh
                               ├─ detecta Tomcat, contexto /fusion, Fusion, usuário
                               ├─ pede a URL base
                               ├─ pede pasta/token do GED (opcional)
                               ├─ valida WAR, URLs e banco (nada alterado até aqui)
                               ├─ mostra o resumo e pede "SIM"
                               ├─ para o Fusion
                               ├─ cria backup do SQLite (se existir banco)
                               ├─ ajusta sessionCookiePath=/ no server.xml
                               ├─ instala a aplicação em webapps/cavidades
                               ├─ inicia o Fusion
                               └─ espera HTTP 200 + JSESSIONID Path=/
```

## 1. Clonar o repositório

No PowerShell, na pasta onde deseja o código:

```powershell
git clone https://github.com/LcAvila/proj_cavidades.git
cd proj_cavidades
git pull origin main
```

Sempre faça `git pull` antes de enviar os arquivos: os scripts mudam de versão e
uma versão antiga do instalador pode recusar o banco existente (veja
[Problemas comuns](#problemas-comuns)).

## 2. Enviar os arquivos ao servidor

Execute no PowerShell do computador local, **fora** da sessão SSH, na raiz do
repositório (a pasta que contém `dist\` e `scripts\`):

```powershell
$server = "usuario@servidor"

# confirma que os três arquivos existem localmente
Test-Path .\dist\CustomFusionWeb.war
Test-Path .\scripts\instalar-cavidades.sh
Test-Path .\scripts\configurar-sessao-fusion.sh

# cria a pasta no servidor e envia os três arquivos para ela
ssh $server "mkdir -p /tmp/cavidades"
scp .\dist\CustomFusionWeb.war .\scripts\instalar-cavidades.sh .\scripts\configurar-sessao-fusion.sh "${server}:/tmp/cavidades/"

# hash local do WAR (deve bater com o SHA-256 em Artefato)
Get-FileHash .\dist\CustomFusionWeb.war -Algorithm SHA256

# conecta no servidor
ssh $server
```

Os três arquivos precisam ficar **lado a lado** em `/tmp/cavidades`, não em
subpastas.

## 3. Validar os arquivos no servidor

Ainda conectado ao servidor via `ssh`, com privilégios de root:

```bash
sudo -i
cd /tmp/cavidades

# os três arquivos estão presentes?
ls -l ./CustomFusionWeb.war ./instalar-cavidades.sh ./configurar-sessao-fusion.sh

# o WAR é o mesmo que está no repositório?
sha256sum ./CustomFusionWeb.war

# os scripts não estão com fim de linha do Windows (CRLF)?
grep -c $'\r' ./instalar-cavidades.sh ./configurar-sessao-fusion.sh

# os scripts estão sintaticamente válidos?
bash -n ./instalar-cavidades.sh
bash -n ./configurar-sessao-fusion.sh
```

O que esperar:

| Verificação | Resultado esperado |
|---|---|
| `ls -l` | os três arquivos listados em `/tmp/cavidades` |
| `sha256sum` | `4f676805d0f2f96ecbe16534f601427a4f694898966b41a732e1f320d95d29d6` |
| `grep -c $'\r'` | `0` para cada arquivo (se sair `1` ou mais, há CRLF — corrija abaixo) |
| `bash -n` | sem saída = sintaxe OK |

Se o `grep` encontrar `\r`, corrija antes de continuar:

```bash
sed -i 's/\r$//' ./instalar-cavidades.sh ./configurar-sessao-fusion.sh
bash -n ./instalar-cavidades.sh && bash -n ./configurar-sessao-fusion.sh
```

> O `.gitattributes` deste repositório mantém os `.sh` em LF, então um `scp`
> feito a partir de uma cópia atualizada do repositório já sai correto. O `sed`
> acima é a correção para cópias antigas ou transferidas de outra origem.

## 4. Executar o instalador

```bash
cd /tmp/cavidades
bash ./instalar-cavidades.sh
```

O instalador precisa de root (`execute como root`) e pergunta, nesta ordem:

| Pergunta | Obrigatório? | Observação |
|---|---|---|
| `URL do servidor/Fusion` | Sim | Ex.: `https://servidor` ou `https://servidor/fusion`. Informe **só** a base, sem parâmetros. |
| `Pasta base de destino no GED` | Não | `Enter` deixa a publicação desabilitada para configurar depois. |
| `Token do GED` | Não | Só aparece se a pasta foi informada. Não é exibido na tela (`read -s`). |
| `Confirma a instalação? Digite SIM:` | Sim | Digite exatamente `SIM`; qualquer outra coisa cancela sem alterar nada. |

Exemplo de sessão:

```text
URL do servidor/Fusion (ex.: https://servidor ou https://servidor/fusion): https://194.0.0.109/fusion
Tomcat e Fusion detectados automaticamente:
  Tomcat: /opt/tomcat/apache-tomcat-10.1.44
  Fusion: /opt/neomind/fusion
  Contexto Fusion: /opt/neomind/fusion/WebContent/fusion.war
URLs derivadas da URL informada:
  API GED padrão: https://194.0.0.109/fusion/api/v1/documents/
  Aplicação: https://194.0.0.109/cavidades
Pasta base de destino no GED (Enter para configurar depois):
Pasta GED não informada; a publicação no GED ficará desabilitada até configurá-la.
Configuração da nova instalação da Cavidades.

Resumo (o token não será exibido):
  Tomcat: /opt/tomcat/apache-tomcat-10.1.44
  ...
Confirma a instalação? Digite SIM: SIM
```

Você pode pular a primeira pergunta passando a URL por variável de ambiente:

```bash
SERVER_URL=https://servidor/fusion bash ./instalar-cavidades.sh
```

Outras variáveis aceitas: `CATALINA_BASE`, `FUSION_HOME`, `FUSION_DOCBASE`,
`TOMCAT_USER`, `DB_FILE`, `FUSION_FOLDER_BASE`, `FUSION_API_TOKEN`,
`CAVIDADES_PUBLIC_URL`. Normalmente **não** é preciso informá-las: o
instalador detecta tudo sozinho e só falha se encontrar mais de uma instalação
compatível.

Antes do `SIM`, o instalador só valida (Tomcat, Fusion, WAR, banco, URLs). Se
algo falhar nesse ponto, o Fusion **não é parado** e Tomcat, banco e aplicação
ficam intactos — basta corrigir a causa e rodar de novo.

## 5. Instalação nova x atualização

**Instalação nova** — não existe `customfusion.db`:

- cria o diretório do banco com dono igual ao usuário do Tomcat detectado e
  modo `0750`;
- grava `application-local.properties` com caminho do banco e URLs;
- instala a aplicação em `<CATALINA_BASE>/webapps/cavidades`.

Se o diretório do banco existir e **não** estiver vazio, o instalador aborta
com `ERRO: o diretório do banco já contém arquivos` e encerra indicando que você
deve definir `DB_FILE` para um caminho novo e vazio. Ele nunca sobrescreve nem
apaga um banco.

**Atualização** — o banco já existe:

- valida o SQLite com `PRAGMA integrity_check` (só leitura);
- aborta se existir a tabela `historico_grades`, que o esquema atual removeria;
- para o Fusion;
- cria e revalida um backup: `customfusion.db.backup-<data>-<pid>`, no mesmo
  diretório do banco, modo `0600`;
- preserva o `application-local.properties` existente (inclusive token/pasta
  GED, sem exibir) e os arquivos de `assets/`;
- guarda a aplicação anterior em `/tmp/cavidades-instalacao-backup-<data>-<pid>`;
- reinicia o Fusion e só então valida a API.

Mantenha o backup do SQLite até confirmar que a aplicação e os dados estão
corretos. Se a instalação falhar depois de parar o Fusion, o instalador tenta
reiniciá-lo automaticamente.

> Para reaplicar só a configuração de sessão (`sessionCookiePath=/`) sem
> instalar nada, envie e execute `configurar-sessao-fusion.sh` como root.

## 6. Verificar depois de instalar

O instalador já valida sozinho: espera a API responder `HTTP 200` e confirma
que o Fusion emitiu `JSESSIONID` com `Path=/`. No fim, ele imprime:

```text
API respondeu HTTP 200 e JSESSIONID está com Path=/.
Acesse: https://servidor/cavidades
Entre no Fusion e confirme que /cavidades/api/usuario-atual retorna autenticado=true.
```

Confirmação manual — abra **no mesmo navegador em que você entrou no Fusion**:

```text
https://servidor/cavidades/api/usuario-atual
```

JSON esperado, com sessão ativa:

```json
{"autenticado": true, ...}
```

`"autenticado": false` com HTTP 200 significa que o endpoint está no ar, mas não
recebeu a sessão do Fusion (cookie sem `Path=/`). Veja
[Problemas comuns](#problemas-comuns).

Logs, se algo falhar:

```bash
tail -n 100 <CATALINA_BASE>/logs/catalina.out
ss -ltnp
```

Se `catalina.out` não existir, liste os arquivos em `<CATALINA_BASE>/logs`.

## 7. Configurar a publicação no GED

A configuração fica somente no servidor, em:

```text
<CATALINA_BASE>/webapps/cavidades/WEB-INF/classes/application-local.properties
```

```properties
app.sqlite.path=/opt/neomind/fusion/config/cavidades/customfusion.db
app.fusion.base-url=https://servidor/fusion
app.fusion.login-url=https://servidor/fusion
app.fusion.api-token=********
app.fusion.folder-base=Relatorios/Cavidades
```

O nome da pasta precisa corresponder exatamente ao destino criado no Fusion; em
subpastas, separe com `/`. A configuração aceita acentos em UTF-8. Nunca coloque
token no Git, no WAR ou no código.

Se a publicação retornar erro de permissão, confira separadamente:

1. o caminho em `app.fusion.folder-base`;
2. o autor enviado (usuário da sessão, salvo se `app.fusion.author-padrao`
   estiver definido);
3. a permissão de publicação desse autor na pasta de destino.

Login na Cavidades, token de API e permissão de pasta são controles distintos.

## Problemas comuns

| Sintoma | Causa | Solução |
|---|---|---|
| `syntax error near unexpected token '$'{\r''` ou `sh: set: pipefail: invalid option name` | Script com fim de linha Windows (CRLF), normalmente por transferir de uma cópia antiga | `sed -i 's/\r$//' ./instalar-cavidades.sh ./configurar-sessao-fusion.sh` e valide com `bash -n` |
| `ERRO: o banco já existe: ...customfusion.db` / `O instalador não reutiliza nem apaga um banco existente` | Instalador **antigo** em execução | `git pull` no repositório, reenvie os três arquivos com `scp` e execute de novo. O instalador atual preserva o banco e cria backup |
| `No such file or directory` no `ls` | `scp` não concluído ou comandos em outra pasta | Repita o `scp` a partir da raiz do repositório |
| `sha256sum` diferente do esperado | WAR corrompido ou versão errada | Repita o `scp` do `dist/CustomFusionWeb.war` |
| `ERRO: execute como root` | Rodou sem sudo | `sudo -i` antes de executar |
| `ERRO: não foi possível detectar um único Tomcat com o contexto /fusion` | Mais de uma instalação compatível, ou Tomcat parado | Defina `CATALINA_BASE`, `FUSION_HOME` e `FUSION_DOCBASE` e rode de novo |
| `ERRO: o diretório do banco já contém arquivos` | Instalação nova apontando para diretório com dados | Defina `DB_FILE` para caminho novo e vazio, ou trate como atualização |
| `ERRO: este banco contém a tabela historico_grades` | Banco legado com tabela que o esquema atual remove | Faça backup manual e migração antes de instalar |
| `ERRO: API não respondeu HTTP 200` | Aplicação não subiu | `tail -n 100 <CATALINA_BASE>/logs/catalina.out` |
| `ERRO: Fusion não emitiu JSESSIONID com Path=/` | `sessionCookiePath` não aplicado no contexto ativo | `bash ./configurar-sessao-fusion.sh` e reinicie o Fusion |
| `autenticado: false` no `/api/usuario-atual` | Sessão não compartilhada entre `/fusion` e `/cavidades` | Confirme `Path=/` no cookie `JSESSIONID` (mesmo host/porta) |
| `PERMISSION DENIED` ao rodar script | Permissões após cópia | `chmod +x *.sh` ou execute com `bash ./script.sh` |

## APIs

Use o prefixo do contexto implantado, normalmente `/cavidades`. Todas as rotas
abaixo exigem sessão do Fusion, exceto `GET /api/usuario-atual`; operações de
escrita também exigem permissão do papel do usuário.

| Método | Endpoint | Descrição |
|---|---|---|
| GET | `/api/usuario-atual` | Identidade, papéis e permissões efetivas |
| GET | `/api/config/` | Índice do catálogo |
| GET | `/api/config/moldes` | Catálogo de moldes e cavidades |
| GET | `/api/config/desenhos`, `/api/config/formas`, `/api/config/maquinas` | Catálogos auxiliares |
| GET | `/api/config/modelos3d` | Catálogo de modelos 3D |
| GET | `/api/config/modelo3d/existe?caminho=...` | Verifica se um arquivo 3D existe |
| GET | `/api/config/layouts/{id}` | Layout de uma grade |
| GET, POST | `/api/grades` | Lista ou cria grades |
| GET, PUT, DELETE | `/api/grades/{id}` | Consulta, salva ou exclui uma grade |
| POST | `/api/grades/importar` | Importa grades legadas |
| GET, DELETE | `/api/moldes/{codigo}` | Consulta ou exclui molde |
| PUT | `/api/moldes/{codigo}/cavidades` | Atualiza cavidades do molde |
| POST | `/api/moldes/cadastrar` | Cadastra/atualiza molde e arquivos (multipart) |
| POST | `/api/moldes/{codigo}/publicar-ged` | Publica relatório no GED |
| GET, POST | `/api/anotacoes3d/{grade}?modelo={chave}` | Lista ou cria anotações 3D |
| PUT, DELETE | `/api/anotacoes3d/{grade}/{anotacao}?modelo={chave}` | Edita ou exclui anotação |
| DELETE | `/api/anotacoes3d/{grade}?modelo={chave}&minhas=1` | Exclui as próprias anotações |
| GET, POST | `/api/papeis` | Consulta/configura permissões por papel |
| GET | `/api/aps/token` | Token de visualização APS, se configurado |
| GET | `/api/aps/modelo?arquivo=...` | Consulta/prepara modelo APS; `verificar=1` só verifica |

A publicação recebe JSON com `file` e `fileBytes` (Base64). A aplicação usa o
autor autenticado no Fusion; o token do GED nunca é enviado pelo navegador.

## Artefato

- WAR: [`dist/CustomFusionWeb.war`](dist/CustomFusionWeb.war)
- SHA-256: `4F676805D0F2F96ECBE16534F601427A4F694898966B41A732E1F320D95D29D6`

Verificação:

```powershell
# Windows
Get-FileHash .\dist\CustomFusionWeb.war -Algorithm SHA256
```

```bash
# Linux
sha256sum ./CustomFusionWeb.war
```

## Documentação relacionada

- [Instalação em servidor Linux](docs/migracao-servidor-linux.md) — requisitos,
  hash, configuração GED, segurança e solução de problemas em detalhe.
- [Setup do Autodesk APS](docs/aps-setup.md) — visualizador 3D opcional.

## Segurança

- Configure HTTPS e regras de firewall antes de liberar o acesso.
- Faça backup periódico do SQLite e dos arquivos em
  `webapps/cavidades/assets`.
- Não publique no Git configurações locais, tokens, cookies de sessão ou bancos
  operacionais.
- Não compartilhe o `application-local.properties` nem o backup do banco.
