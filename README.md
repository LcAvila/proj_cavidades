# Cavidades

Pacote de implantação do Controle de Cavidades: aplicação web para acompanhar
grades e não conformidades de moldes, visualizar modelos 3D e publicar relatórios
no GED do Fusion.

Este repositório contém o WAR pronto para implantação, scripts e documentação
operacional. O código-fonte Java não está neste repositório.

## Requisitos

- Fusion já instalado no servidor;
- Tomcat 10.1+ e Java 21+;
- Linux com `python3`, `curl` e acesso administrativo;
- sessão e permissões de usuário fornecidas pelo Fusion.

O catálogo e as grades operacionais são armazenados em SQLite. A integração
com o GED exige token e permissão de publicação na pasta de destino. Autodesk
APS é opcional; o visualizador 3D local continua disponível sem APS.

O pacote publicado não inclui catálogo empresarial, banco SQLite com dados,
desenhos, imagens de peças, modelos STL nem logo. Na primeira inicialização, a
aplicação cria um banco vazio com o esquema necessário. Os dados e arquivos do
ambiente devem ser cadastrados ou enviados diretamente ao servidor.

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

## Implantar em Linux

O WAR e os dois scripts de implantação estão em `dist/` e `scripts/`. O
instalador detecta os caminhos do Tomcat/Fusion e pede a URL base do servidor.
Deriva as URLs da aplicação e da API GED padrão. Em uma instalação nova, cria o
banco no caminho padrão. Se encontrar o banco existente, preserva os dados, cria
e valida uma cópia SQLite antes de trocar a aplicação e mantém as configurações
locais existentes, inclusive as do GED, e os arquivos em `assets/`.
Não substitui o banco.

Execute a transferência no PowerShell do computador local, fora da sessão SSH,
na raiz do repositório clonado (a pasta que contém `dist\` e `scripts\`). O
comando `scp` copia os três arquivos para a raiz de `/tmp/cavidades`, lado a
lado.

```powershell
$server = "usuario@servidor"
Test-Path .\dist\CustomFusionWeb.war
Test-Path .\scripts\instalar-cavidades.sh
Test-Path .\scripts\configurar-sessao-fusion.sh
ssh $server "mkdir -p /tmp/cavidades"
scp .\dist\CustomFusionWeb.war .\scripts\instalar-cavidades.sh .\scripts\configurar-sessao-fusion.sh "${server}:/tmp/cavidades/"
ssh $server
```

No servidor:

```bash
sudo -i
cd /tmp/cavidades
ls -l ./CustomFusionWeb.war ./instalar-cavidades.sh ./configurar-sessao-fusion.sh
sha256sum ./CustomFusionWeb.war
bash -n ./instalar-cavidades.sh
bash -n ./configurar-sessao-fusion.sh
bash ./instalar-cavidades.sh
```

O `ls` deve encontrar os três arquivos diretamente em `/tmp/cavidades`. Se
algum estiver ausente, volte ao PowerShell local e repita o `scp`; não execute
o instalador até que a transferência esteja completa. Compare o SHA-256 com o
valor em [Artefato](#artefato).

O instalador detecta o Tomcat ativo, o contexto `/fusion`, o diretório do
Fusion e o usuário do Tomcat. Informe a URL base do servidor ou a URL terminada
em `/fusion`; as URLs da aplicação e de validação são derivadas
automaticamente. A rota da API GED é padrão e não precisa ser informada.

Informe a pasta GED apenas se quiser habilitar a publicação agora. O token é
solicitado somente quando a pasta é informada, sem aparecer na tela, e pode ser
deixado em branco para configurar depois. Em uma atualização, o instalador
preserva o arquivo de configuração local existente sem exibir o token. Se o
banco existir, o Fusion é parado temporariamente e o instalador cria um backup
SQLite consistente e verifica sua integridade antes de alterar a aplicação.
O backup fica ao lado do banco e não é removido pelo instalador. Se o banco
contiver `historico_grades`, o instalador interrompe antes de alterar o
servidor, pois o esquema deste pacote removeria essa tabela. Se a detecção do
Fusion falhar, também interrompe antes de alterar o servidor. Revise o resumo
antes de digitar `SIM`.
Após a instalação, entre no Fusion pelo navegador e confirme que
`/cavidades/api/usuario-atual` retorna `"autenticado": true`.

O [guia de instalação Linux](docs/migracao-servidor-linux.md) contém os
requisitos, verificação do hash, configuração GED, solução de problemas e
orientações de segurança. A configuração opcional do viewer Autodesk está em
[APS](docs/aps-setup.md).

## Artefato

- WAR: [`dist/CustomFusionWeb.war`](dist/CustomFusionWeb.war)
- SHA-256: `4F676805D0F2F96ECBE16534F601427A4F694898966B41A732E1F320D95D29D6`

Não publique no Git configurações locais, tokens, cookies de sessão ou bancos
operacionais.
