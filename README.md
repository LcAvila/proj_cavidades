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
instalador é para uma instalação nova com um Fusion existente: pergunta os
caminhos e URLs do ambiente, o nome exato da pasta GED e o token, cria um banco
novo, configura a sessão do Fusion e valida a API. Ele não migra nem substitui
um banco existente.

No PowerShell, substitua `usuario@servidor` pelo usuário e endereço do servidor:

```powershell
$server = "usuario@servidor"
ssh $server "mkdir -p /tmp/cavidades"
scp .\dist\CustomFusionWeb.war .\scripts\instalar-cavidades.sh .\scripts\configurar-sessao-fusion.sh "${server}:/tmp/cavidades/"
ssh $server
```

No servidor:

```bash
sudo -i
cd /tmp/cavidades
bash -n ./instalar-cavidades.sh
bash -n ./configurar-sessao-fusion.sh
bash ./instalar-cavidades.sh
```

Responda às perguntas com os valores específicos do servidor. Após a
instalação, entre no Fusion pelo navegador e confirme que
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
