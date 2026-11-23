# Instalar a Cavidades em um servidor Linux

Este procedimento instala ou atualiza a Cavidades em um Tomcat que já executa
o Fusion. Em uma instalação nova, o script cria um banco SQLite. Se encontrar
um banco existente, preserva-o, cria e valida um backup SQLite antes de trocar
a aplicação e reinicia os serviços Fusion.

## Requisitos

- Fusion já instalado, com `stop.sh` e `start.sh`;
- Tomcat 10.1+ e Java 21+;
- `python3`, `curl`, acesso root e SSH/SCP;
- autorização para alterar o `server.xml` do Tomcat do Fusion.

## 1. Enviar o WAR e os scripts

Este repositório contém o WAR pronto em `dist/CustomFusionWeb.war`; não é
necessário compilar no servidor. Execute os comandos abaixo no PowerShell do
computador local, fora da sessão SSH, na raiz do repositório clonado (a pasta
que contém `dist\` e `scripts\`). O `scp` coloca os três arquivos diretamente
em `/tmp/cavidades`, lado a lado.

```powershell
$server = "usuario@servidor"
Test-Path .\dist\CustomFusionWeb.war
Test-Path .\scripts\instalar-cavidades.sh
Test-Path .\scripts\configurar-sessao-fusion.sh
ssh $server "mkdir -p /tmp/cavidades"
scp .\dist\CustomFusionWeb.war .\scripts\instalar-cavidades.sh .\scripts\configurar-sessao-fusion.sh "${server}:/tmp/cavidades/"
```

Confira o hash local:

```powershell
Get-FileHash .\dist\CustomFusionWeb.war -Algorithm SHA256
```

O SHA-256 esperado para este WAR é
`623C6D09137DA6000E705E6EC45656F731562A4BDC02CE9C0C2A735762B71448`.
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
ls -l ./CustomFusionWeb.war ./instalar-cavidades.sh ./configurar-sessao-fusion.sh
sha256sum ./CustomFusionWeb.war
bash -n ./instalar-cavidades.sh
bash -n ./configurar-sessao-fusion.sh
bash ./instalar-cavidades.sh
```

O `ls` deve encontrar os três arquivos diretamente em `/tmp/cavidades`. Se o
shell informar `No such file or directory`, a cópia não foi concluída ou os
comandos estão sendo executados em outra pasta. Volte ao PowerShell local,
repita o `scp` a partir da raiz do repositório e só continue quando os arquivos
aparecerem. Compare o resultado de `sha256sum` com o SHA-256 esperado acima.

O instalador usa o `CustomFusionWeb.war` no mesmo diretório. Ele extrai e
implanta o conteúdo como `/cavidades`; não é necessário renomear o WAR.

O instalador detecta automaticamente o Tomcat ativo, o contexto `/fusion` no
`server.xml`, o diretório do Fusion e o usuário do Tomcat. Informe uma única
URL base do servidor (por exemplo, `https://servidor:porta`) ou a URL do Fusion
terminada em `/fusion`. As URLs da aplicação e de validação são derivadas
automaticamente. O endpoint do GED (`/api/v1/documents/`) é padrão no
aplicativo e não precisa ser informado.

A pasta GED é opcional durante uma instalação nova; informe o nome/caminho
exato existente no Fusion para habilitar a publicação. O token só é solicitado
quando a pasta é informada; ele não aparece na tela e pode ser deixado em branco
para configurar depois. Em uma atualização, o arquivo de configuração local e
os arquivos existentes em `assets/` são preservados; o token GED não é exibido.
O caminho do banco e o usuário do Tomcat são detectados/calculados automaticamente. Se o
banco existir, o Fusion é parado temporariamente e um backup SQLite consistente
é criado e validado antes de alterar a aplicação. O backup fica ao lado do banco
e deve ser mantido até a atualização ser confirmada. Se o banco contiver
`historico_grades`, o instalador interrompe antes de alterar o servidor, porque
o esquema do pacote removeria essa tabela. Se a detecção do Fusion falhar,
também interrompe antes de alterar o servidor.

Revise o resumo antes de confirmar. Confirme que o Tomcat detectado é o do
Fusion, não o do OLAP, e que a pasta GED está correta. O script também pede
confirmação antes de configurar `sessionCookiePath=/`: isso faz o navegador
enviar o cookie de sessão do Fusion a todos os contextos no mesmo host e porta.
Faça isso apenas se esses aplicativos forem confiáveis.

Na atualização, o backup do SQLite fica ao lado do banco operacional; não o
remova até confirmar a aplicação e os dados. A aplicação anterior é preservada
em um backup temporário. Se a instalação falhar após parar o Fusion, o
instalador tenta iniciá-lo novamente. Para uma instalação nova, o diretório do
banco deve estar vazio. O instalador nunca sobrescreve o banco existente.

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
