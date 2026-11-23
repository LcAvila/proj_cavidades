# Instalar a Cavidades em um servidor Linux

Este procedimento instala a Cavidades em um Tomcat que já executa o Fusion.
Use-o para uma instalação nova: o script cria um banco SQLite novo, não migra
nem reutiliza o banco de outro servidor e reinicia os serviços Fusion.

## Requisitos

- Fusion já instalado, com `stop.sh` e `start.sh`;
- Tomcat 10.1+ e Java 21+;
- `python3`, `curl`, acesso root e SSH/SCP;
- autorização para alterar o `server.xml` do Tomcat do Fusion.

## 1. Enviar o WAR e os scripts

Este repositório contém o WAR pronto em `dist/CustomFusionWeb.war`; não é
necessário compilar no servidor. No PowerShell, informe o usuário e o endereço
do servidor de destino:

```powershell
$server = "usuario@servidor"
ssh $server "mkdir -p /tmp/cavidades"
scp .\dist\CustomFusionWeb.war .\scripts\instalar-cavidades.sh .\scripts\configurar-sessao-fusion.sh "${server}:/tmp/cavidades/"
```

Confira o hash local:

```powershell
Get-FileHash .\dist\CustomFusionWeb.war -Algorithm SHA256
```

O SHA-256 esperado para este WAR é
`DBBE282FBA1AC502ADEAF6DC5DD66B50A98A9DDF51B7B6DEB47110D88B7E3BF5`.
Depois da transferência, compare com o hash calculado no Linux. Conecte-se ao
servidor:

```powershell
ssh $server
```

## 2. Validar e executar

No servidor:

```bash
sudo -i
cd /tmp/cavidades
bash -n ./instalar-cavidades.sh
bash -n ./configurar-sessao-fusion.sh
bash ./instalar-cavidades.sh
```

O instalador usa o `CustomFusionWeb.war` no mesmo diretório. Ele extrai e
implanta o conteúdo como `/cavidades`; não é necessário renomear o WAR.

Informe os valores encontrados no servidor, sem reutilizar caminhos ou URLs de
outro ambiente:

- diretório base do Tomcat que executa o Fusion;
- diretório do Fusion e `docBase` declarado no `server.xml`;
- URL interna do Fusion e URLs públicas de login e da Cavidades;
- URL local para validar a API;
- caminho novo do SQLite e usuário do Tomcat;
- nome/caminho exato da pasta de destino no GED;
- token do GED (opcional nesta etapa; é digitado sem aparecer na tela).

O instalador mostra um resumo antes de prosseguir. Confirme que o Tomcat
selecionado é o do Fusion, não o Tomcat do OLAP, e que o destino GED é a pasta
existente com as permissões corretas. O script também pede confirmação antes de
configurar `sessionCookiePath=/`: isso faz o navegador enviar o cookie de
sessão do Fusion a todos os contextos no mesmo host e porta. Faça isso apenas
se esses aplicativos forem confiáveis.

O banco precisa estar em um caminho novo e vazio. O instalador recusa sobrescrever
um banco existente, preserva a aplicação anterior em um backup temporário,
instala a Cavidades e reinicia o Fusion uma vez. Não o use como procedimento de
atualização de uma instalação com dados existentes.

## 3. Verificar a instalação

O instalador aguarda a API responder HTTP 200 e verifica se o Fusion emite
`JSESSIONID` com `Path=/`. Depois, abra a URL pública da Cavidades no mesmo
navegador em que você entrou no Fusion e consulte:

```text
/cavidades/api/usuario-atual
```

Após o login, o JSON deve conter `"autenticado": true`. Uma chamada sem sessão
pode responder HTTP 200 com `"autenticado": false`; isso indica que o endpoint
está acessível, mas não recebeu uma sessão do Fusion.

## 4. GED: pasta, token e permissões

O instalador grava `app.fusion.folder-base` e `app.fusion.api-token` no arquivo
local da instalação:

```text
<CATALINA_BASE>/webapps/cavidades/WEB-INF/classes/application-local.properties
```

O nome da pasta precisa corresponder exatamente ao destino criado no Fusion. Se
o destino estiver em subpastas, separe os nomes com `/`. A configuração suporta
acentos em UTF-8. O token pode ser informado na instalação ou configurado
depois por um administrador do Fusion. Nunca o coloque no código, no Git ou no
WAR.

Se a publicação retornar erro de permissão, confirme separadamente:

1. o caminho configurado em `app.fusion.folder-base`;
2. o autor enviado pela integração (usuário da sessão, salvo se
   `app.fusion.author-padrao` estiver definido);
3. a permissão de publicação desse autor na pasta de destino do GED.

Login na Cavidades, token de API e permissão de publicação na pasta são controles
distintos. Alterar o token não substitui a permissão de pasta.

## 5. Sessão e solução de problemas

Se a API indicar `autenticado:false` mesmo após o login, confira no navegador o
cookie `JSESSIONID` do Fusion. Ele deve ter `Path=/`. O instalador ajusta o
contexto ativo do Fusion no `server.xml`, não o `META-INF/context.xml` de um WAR
desempacotado.

Para reaplicar essa configuração em um servidor existente, envie
`scripts/configurar-sessao-fusion.sh` e execute-o como root:

```bash
bash ./configurar-sessao-fusion.sh
```

Se a API não iniciar, consulte os logs do Tomcat selecionado:

```bash
tail -n 100 <CATALINA_BASE>/logs/catalina.out
ss -ltnp
```

Se `catalina.out` não existir, liste os arquivos de log recentes em
`<CATALINA_BASE>/logs`.

## 6. Dados e segurança

- Configure HTTPS e regras de firewall antes de liberar o acesso.
- Faça backup periódico do banco SQLite configurado e dos arquivos enviados em
  `webapps/cavidades/assets`.
- O seed versionado contém apenas o catálogo inicial; não substitui backup do
  banco operacional.
- Não compartilhe token, cookies de sessão ou arquivos de configuração local.
