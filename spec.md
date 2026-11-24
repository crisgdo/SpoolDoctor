# Spec: SpoolDoctor (PowerShell)

Ferramenta para diagnosticar e limpar a fila de impressão do Windows, local e remotamente. Evolução do script `limpar_fila_impressao.bat` (v0), que continua sendo o plano B até este projeto provar que funciona.

Formato: REASONS Canvas. Regra de ouro: se a realidade divergir deste documento, **corrija o spec primeiro e só depois o código**.

---

## R: Requirements

### Problema
Quando a fila de impressão trava, o v0 resolve apagando tudo e reiniciando o spooler. Limitações: reporta sucesso mesmo quando falha, não mostra o que foi apagado, não permite limpar só uma impressora ou um job, não deixa log e só funciona na máquina local.

### Requisitos funcionais
- **RF1.** Listar impressoras e jobs da fila (nome, status, tamanho, idade), local e remoto.
- **RF2.** Cancelar um job específico (caminho "educado"), sem resetar o spooler.
- **RF3.** Reset completo do spooler (parar serviço, apagar arquivos da fila, iniciar serviço), como último recurso.
- **RF4.** Modo simulação (`-WhatIf` / dry-run): mostra o que seria feito, sem alterar nada, registra no log e retorna `ActionResult` com `Outcome = 'Simulated'`.
- **RF5.** Verificar o resultado: só reportar sucesso se o serviço estiver rodando e a fila vazia ao final.
- **RF6.** Log de toda ação (data/hora ISO-8601, máquina, usuário, ação, resultado, mensagem).
  - Caminho padrão: `%ProgramData%\SpoolDoctor\logs\spooldoctor.log` (criando o diretório automaticamente se não existir), em UTF-8, uma linha estruturada por evento.
  - Aceitar parâmetro opcional `-LogPath` para redirecionamento em testes (`TestDrive:\`) ou uso customizado.
- **RF7.** Backup dos arquivos da fila antes de apagar (opcional, ligado por padrão).
  - Caminho padrão: `%ProgramData%\SpoolDoctor\backups\<yyyyMMdd-HHmmss>` (criando o diretório automaticamente apenas quando houver arquivos a copiar).
  - Aceitar parâmetros opcionais em `Reset-Spooler`: `-BackupPath` para redirecionamento em testes (`TestDrive:\`) ou destino customizado, e `-SkipBackup` para desabilitar o backup.
  - Em caso de falha no backup, abortar a remoção dos arquivos, tentar reiniciar o serviço `Spooler` no `finally` e retornar `Outcome = 'Failed'`.
  - Retenção automática via `-BackupRetentionDays` em `Reset-Spooler` (padrão `7`, faixa `0..365`; `0` desativa), removendo apenas subdiretórios diretos `yyyyMMdd-HHmmss` vencidos dentro da raiz padrão `%ProgramData%\SpoolDoctor\backups` (nunca varre `-BackupPath` customizado nem executa em `-WhatIf` ou `-SkipBackup`).
  - Falha ao remover backups antigos registra aviso na mensagem e no log sem alterar o `Outcome` do reset para `Failed`.
- **RF8.** Elevação automática: exigir ou solicitar administrador, em vez de depender do usuário.
  - Na inicialização da interface gráfica (`ui/SpoolDoctorUI.ps1`, inclusive via `Iniciar.bat`), quando a sessão atual não possui privilégio de Administrador, o SpoolDoctor solicita elevação automaticamente via UAC (`Start-Process -FilePath 'powershell.exe' -Verb RunAs`), preservando `-NoProfile`, `-ExecutionPolicy Bypass`, `-STA`, `-WindowStyle Hidden`, `-File "<caminho>"` (com aspas para suportar espaços), `-LogPath` (se informado) e a flag interna `-ElevationAttempted`, encerrando a instância original sem abrir janela duplicada.
  - **Trava anti-loop obrigatória:** quando `-ElevationAttempted` ou `-NoElevate` estiver presente (ou quando o script for carregado com `-NoShow`/dot-source em testes/CI), a UI nunca tenta relançar automaticamente.
  - **Degradação graciosa:** se o usuário cancelar o prompt UAC (`Win32Exception` código `1223` em qualquer nível da cadeia de `InnerException` ou `OperationCanceledException`), se ocorrer falha no relançamento ou se a janela abrir sem privilégio de Administrador, a UI abre em **modo somente leitura** exibindo claramente o privilégio no título e no cabeçalho (`Administrador` vs. `Usuário padrão (somente leitura)`), mantendo `Atualizar` e `Diagnosticar` habilitados, desabilitando `Cancelar job selecionado`, `Reiniciar serviço` e `Limpar fila (Resetar)`, exibindo aviso claro no painel de status e oferecendo o botão explícito **"Reiniciar como Administrador"**.
  - **Separação UI vs. módulo CLI (Safeguard 3):** chamadas diretas a `Reset-Spooler`, `Restart-Spooler` e `Remove-SpoolerJob` em `src/Public/` sem privilégio de Administrador continuam recusando a operação antes de tocar no sistema, registrando no log e retornando `ActionResult` com `Outcome = 'Failed'`, sem disparar popup UAC.
  - `Iniciar.bat` permanece como launcher de uma linha sem BOM UTF-8, delegando a checagem de elevação, trava anti-loop e degradação graciosa para `ui/SpoolDoctorUI.ps1`.
- **RF9.** Diagnóstico: serviço do spooler ativo, jobs parados há mais de N minutos, impressora respondendo.
  - Operação somente leitura (`Test-Spooler`, sem `SupportsShouldProcess` e sem exigir elevação obrigatória), aceitando `-StuckThresholdMinutes` (`1..1440`, padrão `15`) e `-LogPath`.
  - Consolida estado do serviço `Spooler`, impressoras com status de erro/offline (incluindo flags compostas separadas por vírgula), jobs travados (idade `>= $StuckThresholdMinutes` ou status problemático `Error`, `Blocked`, `Deleting`, `Offline`, `PaperOut`, `UserIntervention`) e arquivos `.SPL`/`.SHD` em `PRINTERS` (incluindo detecção de arquivos órfãos quando há arquivos e `0` jobs).
  - Se a leitura de `PRINTERS` retornar acesso negado (`UnauthorizedAccessException`) sem privilégio de administrador, não interrompe o diagnóstico: define `SpoolFileCount = $null` e registra aviso claro em `Issues`.
  - Falha ao consultar o serviço `Spooler` ou ao listar impressoras/jobs com o serviço ativo registra `Outcome = 'Failed'` no log e propaga o erro explicitamente.
  - Quando `ServiceStatus` for diferente de `'Running'` (ex.: `'Stopped'`), `Recommendation` orienta tentar primeiro **`Restart-Spooler`** (preservando os documentos da fila) antes de recorrer a `Reset-Spooler`.
- **RF10. Execução remota:** executar RF1, RF2, RF3, RF9 e RF13 em outra máquina via `Invoke-Command` (WinRM), com relatório por máquina.
  - **Escopo da Operação 6 (uma máquina):**
    - Parâmetros opcionais em `Get-SpoolerJob`, `Remove-SpoolerJob`, `Reset-Spooler`, `Restart-Spooler` e `Test-Spooler`: `-ComputerName` (`[string]`, exatamente uma máquina por chamada; com `[AllowNull()][AllowEmptyString()]` e detecção via `$PSBoundParameters.ContainsKey('ComputerName')` para nunca cair em execução local quando vazio/inválido e sempre registrar recusa em log), `-Credential` (`[PSCredential]`, usa login atual quando omitido, nunca gravado em arquivo/log) e `-AllowedComputersPath` (`[string]`, padrão `config/allowed-computers.txt` na raiz do repositório, permitindo redirecionamento para `TestDrive:\` em testes).
    - Em `Reset-Spooler` e `Restart-Spooler`, parâmetro adicional `-AllowPrintServer` (`[switch]`) para liberação explícita com confirmação reforçada em servidores de impressão (Safeguard 8).
    - Em `Remove-SpoolerJob`, `-ComputerName` **não** usa `ValueFromPipelineByPropertyName` nesta etapa, preservando integralmente o fluxo de pipeline local `Get-SpoolerJob | Remove-SpoolerJob`.
  - **Preservação do modo local:** omitir `-ComputerName` (ou informar `localhost`, `$env:COMPUTERNAME` ou FQDN local derivado de `$env:USERDNSDOMAIN` sem consulta DNS) executa localmente sem consultar a allow-list nem abrir WinRM; informar `-Credential` em execução local é recusado com `Failed` e registrado em log.
  - **Validação e allow-list:** `-ComputerName` aceita estritamente hostname ou FQDN (RFC 1123; recusa nulo, vazio, espaços, caracteres especiais, `..\`, barras, wildcards e IPs literais). Qualquer alvo remoto precisa constar na allow-list (comparação *case-insensitive*); caso contrário, a ação é recusada antes de abrir conexão e registrada em log como `Outcome = 'Failed'`.
  - **Proteção de servidor de impressão (`Reset-Spooler` e `Restart-Spooler`, Safeguard 8):** detecção em duas camadas — (1) estática via marcação opcional `HOSTNAME|PrintServer` na allow-list (bloqueia antes de conectar) e (2) dinâmica no destino antes de parar o `Spooler` (SO Windows Server `Win32_OperatingSystem.ProductType` `2` ou `3`, ou presença de impressora compartilhada com `Shared = $true`). Sem `-AllowPrintServer`, a operação é bloqueada (`Outcome = 'Failed'`) informando explicitamente o motivo detectado; com `-AllowPrintServer`, a confirmação exibe aviso reforçado `[SERVIDOR DE IMPRESSÃO]`.
  - **Privilégio de administrador (Safeguard 3):** em execução remota, `Test-IsAdministrator` é verificado na máquina de destino (não exige UAC local quando operando com `-Credential` de administrador no destino).
  - **Simulação, confirmação e ciclo de sessão:** `-WhatIf` e recusa de `-Confirm` exibem o hostname de destino no `ShouldProcess`, gravam log local (`Simulated`/`Skipped`) e **não** abrem sessão remota. Sessões WinRM (`New-PSSession` / `Invoke-Command` / `Remove-PSSession`, encapsuladas em wrappers finos dentro de `src/Remote/` sem exportação no manifesto) injetam em memória apenas as funções necessárias via `[scriptblock]::Create()` + `New-Item -Path 'Function:'` (sem instalação prévia e sem `Invoke-Expression`) e são sempre encerradas em bloco `finally`.
  - **Classificação de falhas:** falhas de conectividade, máquina offline, WinRM desabilitado ou *timeout* resultam em `Outcome = 'Unreachable'`; falhas de autenticação, acesso negado, entrada inválida, máquina fora da allow-list, servidor de impressão bloqueado ou erro operacional resultam em `Outcome = 'Failed'`. `Reset-Spooler`, `Restart-Spooler` e `Remove-SpoolerJob` retornam `ActionResult` com o hostname de destino e gravam log; `Get-SpoolerJob` e `Test-Spooler` gravam log (`Unreachable`/`Failed`) e propagam erro explícito (`throw`).
  - **Escopo da Operação 7 (múltiplas máquinas em lote com isolamento de falhas):**
    - Evolução de `-ComputerName` para `[string[]]` com `[AllowNull()][AllowEmptyCollection()][AllowEmptyString()]` em `Get-SpoolerJob`, `Remove-SpoolerJob`, `Reset-Spooler`, `Restart-Spooler` e `Test-Spooler`, preservando 100% de compatibilidade com execução local (parâmetro omitido) e máquina única (1 alvo).
    - **Lista vazia ou nula:** informar `-ComputerName $null` ou array vazio `@()` nunca cai em execução local; gera falha explícita (`Outcome = 'Failed'`, `Computer=(inválido)`) e registra log.
    - **Entradas inválidas misturadas no lote:** itens nulos ou em branco (ex.: `@('PC-01', $null, '   ', 'PC-02')`) geram falha isolada (`Computer=(inválido)`, `Outcome = 'Failed'`) sem interromper as demais máquinas. Não há remoção silenciosa de espaços antes da validação, preservando a recusa de espaços nas bordas por `Test-ValidComputerName`.
    - **Deduplicação *case-insensitive*:** alvos nomeados válidos repetidos (incluindo aliases locais como `localhost`, `$env:COMPUTERNAME` e FQDN local) e alvos nomeados inválidos repetidos (ex.: mesmo host fora da allow-list) são deduplicados separadamente com comparação `OrdinalIgnoreCase`, preservando a ordem da primeira ocorrência e garantindo que um item inválido (ex.: `'PC-01 '`) nunca suprima um alvo válido subsequente (`'PC-01'`).
    - **Definição explícita de modo lote (`$isBatchMode`):** determinado sobre a lista **já resolvida e deduplicada** (`$resolvedTargets.Count -gt 1`), evitando ambiguidade quando entradas duplicadas (ex.: `@('PC-01', 'pc-remoto-01')`) colapsam para um único alvo.
    - **Isolamento de falhas entre máquinas (Safeguard 9):** qualquer falha em uma máquina do lote (entrada inválida, fora da allow-list, `-Credential` em alvo local, servidor de impressão bloqueado, máquina offline/`Unreachable`, falha de autenticação/`Failed`, recusa de `-Confirm` com `Skipped` ou erro operacional) grava 1 linha de log para aquela máquina e o processamento continua normalmente para as demais.
    - **Contrato de erro em lote vs. máquina única:**
      - `Reset-Spooler`, `Restart-Spooler` e `Remove-SpoolerJob`: emitem 1 `SpoolDoctor.ActionResult` (`OK`, `Failed`, `Unreachable`, `Skipped`, `Simulated`) e gravam 1 linha de log por máquina em ambos os modos.
      - `Test-Spooler`: em máquina única (`$resolvedTargets.Count -le 1`) grava log e lança `throw`; em lote (`$resolvedTargets.Count -gt 1`) emite 1 `SpoolDoctor.Diagnostic` e grava 1 linha de log por máquina — em caso de falha ou indisponibilidade isolada, emite `SpoolDoctor.Diagnostic` com `Health = 'Unreachable'` ou `'Failed'`, `IsHealthy = $false`, `ServiceStatus = 'Unknown'`, `PrinterCount = $null`, `JobCount = $null`, `SpoolFileCount = $null`, `UnhealthyPrinters = @()`, `StuckJobs = @()`, `HasOrphanSpoolFiles = $false`, `Issues = @(<erro>)` e `Recommendation` orientada.
      - `Get-SpoolerJob`: em máquina única (`$resolvedTargets.Count -le 1`) grava log e lança `throw`; em lote (`$resolvedTargets.Count -gt 1`) emite os objetos `SpoolDoctor.PrintJob` das máquinas bem-sucedidas (mantendo atomicidade intra-máquina), grava 1 linha de log por máquina e reporta cada falha isolada via erro não terminativo (`$PSCmdlet.WriteError` com `FullyQualifiedErrorId = "SpoolDoctor.<Outcome>"`, `TargetObject = <ComputerName>` e categoria `ConnectionError` quando `Unreachable`), mantendo o stream de saída composto apenas por `SpoolDoctor.PrintJob` e prosseguindo para as demais máquinas.
    - **Confirmação, `-WhatIf` e sessões por máquina:** `$PSCmdlet.ShouldProcess` é avaliado individualmente exibindo o hostname correspondente (e `[SERVIDOR DE IMPRESSÃO]` com `-AllowPrintServer` em `Reset-Spooler` e `Restart-Spooler`), sem abrir sessão WinRM em `-WhatIf` ou recusa de `-Confirm`, e encerrando todas as sessões abertas em bloco `finally`.
    - **Preservação do pipeline em `Remove-SpoolerJob`:** `-ComputerName` permanece sem `ValueFromPipelineByPropertyName`, preservando integralmente `Get-SpoolerJob | Remove-SpoolerJob`.
  - **Exposição pública somente leitura da allow-list:** `Get-SpoolerAllowedComputer` em `src/Public/` (opcional `[string]$AllowedComputersPath`) delega diretamente para `Get-AllowedComputer` em `src/Remote/` e retorna `SpoolDoctor.AllowedComputer[]` sem duplicar parsing na interface.
  - **Pré-requisitos (fora do controle do código):** WinRM habilitado na máquina de destino e conta com permissão de administrador nela. Em ambiente corporativo, isso depende do setor de TI: combinar com a TI **antes** de testar em máquinas reais.
- **RF11.** Interface gráfica (WinForms dentro do PowerShell) como camada fina sobre o módulo `SpoolDoctor`, com lista de jobs, botões, confirmação, seleção remota e modo em lote:
  - Aceita parâmetro opcional `-AllowedComputersPath`, repassado para `Get-SpoolerAllowedComputer`, para as operações remotas (`Get-SpoolerJob`, `Remove-SpoolerJob`, `Restart-Spooler`, `Reset-Spooler`, `Test-Spooler`) e preservado (com aspas) no relançamento UAC.
  - Cabeçalho com seletor de alvo (`ComboBox` `DropDownStyle = DropDownList`) populado via `Get-SpoolerAllowedComputer`: `Local (<COMPUTERNAME>)` como padrão; cada máquina autorizada (marcando `[Servidor de Impressão]` quando `IsPrintServer = $true`); e, quando houver 2 ou mais máquinas na allow-list, a opção de lote `Todas autorizadas (<N> máquinas)`. Se a allow-list estiver vazia (só comentários), opera normalmente apenas no modo local sem erro; se falhar ao carregar, abre no modo local exibindo `[AVISO]` claro no painel de status.
  - Grade (`DataGridView`) com 8 colunas incluindo **`Máquina`** (`ComputerName`). Ao cancelar um job selecionado na grade (inclusive em lote), usa o `ComputerName` armazenado em `$row.Tag` para direcionar `Remove-SpoolerJob` à máquina exata e exibe esse hostname no diálogo de confirmação.
  - Opção discreta de credencial alternativa em memória (`CheckBox "Usar credencial alternativa"` + wrapper mockável `Request-SpoolDoctorCredential` encapsulando `Get-Credential`), habilitada apenas para alvos remotos (desabilitada e nunca repassada em alvo local, conforme RF10), limpa ao desmarcar ou fechar a janela, sem persistência em disco e sem registrar usuário ou senha em status ou log (Safeguard 10).
  - Privilégio local vs. remoto (Safeguard 3): quando sem UAC local (`IsElevated = $false`), mantém `Cancelar job selecionado`, `Reiniciar serviço` e `Limpar fila (Resetar)` desabilitados para alvo/jobs locais, mas habilita `Reiniciar serviço` e `Limpar fila (Resetar)` ao selecionar alvo remoto e `Cancelar job selecionado` ao selecionar um job remoto na grade (pois o administrador é validado no destino via WinRM).
  - Proteção de servidor de impressão (`|PrintServer`, Safeguard 8): `Reiniciar serviço` (`Restart-Spooler`) e `Limpar fila (Resetar)` (`Reset-Spooler`) em alvo individual marcado como `|PrintServer` exigem confirmação reforçada em 2 etapas (`Warning` com aviso explícito `[SERVIDOR DE IMPRESSÃO]` + `Error` confirmando explicitamente `-AllowPrintServer`, ambas com botão padrão `Não`); no modo lote, a UI **nunca** passa `-AllowPrintServer` e avisa na confirmação que servidores `|PrintServer` serão bloqueados automaticamente.
  - Tratamento de lote e ações na UI: `Invoke-SpoolDoctorRefresh` captura erros não terminativos de `Get-SpoolerJob` (`-ErrorVariable ... -ErrorAction Continue`) para exibir os jobs das máquinas saudáveis na grade e listar as falhas/`Unreachable` no painel de status; `Invoke-SpoolDoctorDiagnose` formata 1 ou múltiplos objetos `SpoolDoctor.Diagnostic` (exibindo `N/D` quando `PrinterCount` ou `JobCount` forem `$null`); `Invoke-SpoolDoctorRestart` (botão **Reiniciar serviço**, `$form.Tag.RestartButton`) ignora `Fazer backup antes de resetar`, respeita `-WhatIf` e atualiza a grade automaticamente (`Invoke-SpoolDoctorRefresh -PreserveStatus`) quando houver ao menos um resultado `OK` fora de `-WhatIf`; `Invoke-SpoolDoctorReset` (botão **Limpar fila (Resetar)**, `$form.Tag.ResetButton`) formata 1 ou múltiplos `ActionResult`.
- **RF12.** Launcher `.bat` de uma linha para duplo clique.
- **RF13.** Reinício seguro do serviço `Spooler` sem apagar a fila (`Restart-Spooler`):
  - `[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]`, retornando `SpoolDoctor.ActionResult` (`Action = 'Restart-Spooler'`).
  - Parâmetros: `-LogPath`, `-ComputerName` (`[string[]]`), `-Credential` (`[PSCredential]`), `-AllowedComputersPath`, `-AllowPrintServer` (`[switch]`).
  - **Nunca** acessa ou altera a pasta `PRINTERS` (0 chamadas a `Get-SpoolFile`, `Copy-SpoolFile`, `Remove-SpoolFile` e `Remove-OldSpoolBackup`), preservando integralmente os arquivos `.SPL`/`.SHD` na fila.
  - Exige privilégio de Administrador (local ou no destino remoto — Safeguard 3).
  - Se `Get-SpoolerServiceStatus` retornar `'Stopped'`, executa apenas `Start-SpoolerService -Confirm:$false` (sem chamar `Stop-SpoolerService`); para qualquer outro estado, executa `Stop-SpoolerService -Confirm:$false` seguido de `Start-SpoolerService -Confirm:$false` (tentando reiniciar em `finally` caso falhe após parar).
  - Verificação final obrigatória (Safeguard 2): confirma via `Get-SpoolerServiceStatus` que o serviço terminou em `'Running'`; caso contrário retorna `Outcome = 'Failed'`.
  - Suporte completo a `-WhatIf` (`Simulated`), recusa de `-Confirm` (`Skipped`), execução remota (1 máquina e lote com deduplicação e isolamento de falhas), allow-list, proteção de servidor de impressão em 2 camadas + `-AllowPrintServer`, encerramento de sessão em `finally` e 1 linha de log por máquina via `Write-SpoolDoctorLog`.

### Requisitos não funcionais
- Apenas PowerShell 5.1 (já presente no Windows), sem módulos externos em tempo de execução.
- Rodar sem instalar nada nas máquinas (exceção: a execução remota exige WinRM habilitado no destino, ver RF10).
- Dependências de **desenvolvimento** (Pester 5+, PSScriptAnalyzer) são permitidas; só não podem ser exigidas em tempo de execução.
- Testável sem tocar no spooler real.

### Fora de escopo (por ora)
Agendamento automático, ícone de bandeja, reset em servidor de impressão sem confirmação reforçada.

### Definição de Pronto (por funcionalidade)
Spec atualizado, testes Pester passando, PSScriptAnalyzer sem avisos, teste manual numa VM, log verificado, commit atômico.

---

## E: Entities

- **Printer:** `Name`, `Status`, `PortName`.
- **PrintJob:** `Id`, `PrinterName`, `Document`, `SizeBytes`, `SubmittedAt`, `Age` (`[timespan]` ou `$null` se `SubmittedAt` estiver ausente; clamp em `[timespan]::Zero` para timestamps futuros), `Status`, `ComputerName`.
- **SpoolerService:** estado (`Running`, `Stopped`, ...), máquina.
- **ActionResult:** `ComputerName`, `Action`, `Outcome` (`OK`, `Failed`, `Unreachable`, `Skipped`, `Simulated`), `Message`, `Timestamp`.
- **SpoolerDiagnostic:** `ComputerName`, `ServiceStatus`, `PrinterCount` (`[int]` ou `$null` quando indisponível em falha isolada de lote), `UnhealthyPrinters`, `JobCount` (`[int]` ou `$null` quando indisponível em falha isolada de lote), `StuckJobs`, `SpoolFileCount` (`[int]` ou `$null` se leitura de `PRINTERS` indisponível/negada), `HasOrphanSpoolFiles`, `Health` (`Healthy`, `Warning`, `Critical`; além de `Unreachable` e `Failed` para falhas isoladas em lote), `IsHealthy`, `Issues`, `Recommendation`, `Timestamp`.
- **TargetList:** lista de máquinas permitidas (allow-list) lida de arquivo, composta por objetos `SpoolDoctor.AllowedComputer` (`ComputerName`, `IsPrintServer`).

Relações: Printer 1..N PrintJob; cada ação produz um ActionResult por máquina.

---

## A: Approach

- **Módulo `.psm1`** com a lógica em funções pequenas; a interface e o launcher são camadas finas por cima.
- **Isolamento do sistema:** só poucas funções privadas tocam o sistema. Cada uma é um wrapper fino com **nome próprio** (ex.: `Get-SpoolerPrinterRaw`, `Get-SpoolerJobRaw`, `Remove-SpoolerJobRaw`, `Get-SpoolerServiceStatus`, `Stop-SpoolerService`, `Start-SpoolerService`, `Get-SpoolFile`, `Remove-SpoolFile`, `Copy-SpoolFile`, `Remove-OldSpoolBackup`) que chama o cmdlet nativo por dentro (`Get-Printer`, `Get-PrintJob`, `Remove-PrintJob`, `Get-Service`, `Stop-Service`, `Start-Service`, `Get-ChildItem`, `Remove-Item`, `Copy-Item`). Nunca criar função com o mesmo nome de um cmdlet nativo. Os testes substituem os wrappers com `Mock` (Pester 5, usando `-ModuleName SpoolDoctor`).
- **Remoto como camada de despacho sem instalação prévia:** uma função em `src/Remote` decide *onde* executar (local ou `Invoke-Command`) sem alterar a lógica do reset. Como nada é instalado nas máquinas de destino, o despacho remoto injeta os *scriptblocks*/funções necessários diretamente na sessão remota.
- **Escalonamento do reparo:** primeiro cancelar o job (`Remove-SpoolerJob`); se necessário, reiniciar/iniciar o serviço preservando a fila (`Restart-Spooler`); só então recorrer ao reset completo (`Reset-Spooler`).
- **Recuperação em falha parcial:** se `Reset-Spooler` parar o serviço `Spooler` e ocorrer erro na remoção dos arquivos, a função tenta iniciar o serviço novamente no bloco `finally` antes de retornar `ActionResult` com `Outcome = 'Failed'`, evitando deixar a máquina com o serviço parado.
- **Simulação explícita (`-WhatIf`):** quando `SupportsShouldProcess` intercepta a execução sob `-WhatIf`, nenhum wrapper destrutivo é chamado; a função registra explicitamente a simulação no log e retorna `ActionResult` com `Outcome = 'Simulated'`.
- **Falha explícita:** cada passo verifica o resultado; erros viram `ActionResult` com `Failed`, nunca sucesso silencioso.

---

## S: Structure

```
SpoolDoctor/
  AGENTS.md
  spec.md
  .editorconfig                    # UTF-8 com BOM para arquivos PowerShell
  limpar_fila_impressao.bat        # v0, intocado, plano B
  src/
    SpoolDoctor.psd1
    SpoolDoctor.psm1
    Public/    # Get-SpoolerAllowedComputer, Get-SpoolerJob, Remove-SpoolerJob, Reset-Spooler, Restart-Spooler, Test-Spooler
    Private/   # wrappers do sistema, log, backup, validação de caminho
    Remote/    # despacho remoto e leitura da allow-list
  ui/
    SpoolDoctorUI.ps1
  Iniciar.bat                      # launcher
  config/
    allowed-computers.txt
  tests/       # Pester
  .github/workflows/ci.yml         # Pester 5 + PSScriptAnalyzer (windows-latest)
```

Dependências: `ui` e `Iniciar.bat` dependem de `src`; `src/Public` depende de `Private` e `Remote`; `Private` não depende de ninguém.

---

## O: Operations (ordem de implementação)

0. **Estrutura inicial e CI (scaffold):** criar árvore de pastas, `.editorconfig`, manifesto `src/SpoolDoctor.psd1`, loader `src/SpoolDoctor.psm1`, teste smoke mínimo em `tests/` e `.github/workflows/ci.yml` validando Pester 5 e PSScriptAnalyzer.
1. `Reset-Spooler`: reescrita do v0 com verificação de erro, recuperação do serviço no `finally`, validação completa de caminho (normalização via `[System.IO.Path]::GetFullPath`, bloqueio de *path traversal* `..\`, pasta exata `PRINTERS` e extensões `.SPL`/`.SHD`), log (`-LogPath`), `-WhatIf` (retornando `Simulated` + log), verificação final (serviço `Running` e ausência de arquivos `.SPL`/`.SHD` restantes em `PRINTERS`) e **exigência de administrador** (RF3, RF4, RF5, RF6; Safeguards 1 a 4 e 11).
2. `Get-SpoolerJob` com idade e status (RF1).
3. `Remove-SpoolerJob` para um job (RF2).
4. **Janela WinForms** com lista de jobs, cancelar job e reset, mais launcher `Iniciar.bat` (RF11, RF12). A janela é camada fina: só chama as funções do módulo.
5. **Extras** (a janela ganha os botões correspondentes a cada um):
   - 5a. Backup dos arquivos da fila antes de apagar (RF7)
   - 5b. `Test-Spooler`: diagnóstico (RF9)
   - 5c. Elevação automática (RF8)
6. **Remoto, uma máquina:** allow-list, `Invoke-Command`, relatório (RF10). Pré-requisito: WinRM e autorização da TI.
7. **Remoto, em lote:** `[string[]]$ComputerName` nas 4 funções públicas com resolução/deduplicação via `Resolve-SpoolerTargetList`, modo lote determinado por `$resolvedTargets.Count -gt 1`, isolamento de falhas por máquina (Safeguard 9), `ShouldProcess`/`-WhatIf` individual por host e contratos de lote (`WriteError` não terminativo em `Get-SpoolerJob`; `SpoolDoctor.Diagnostic` de falha em `Test-Spooler`). A seleção remota na UI fica para etapa dedicada posterior.
8. **Suporte remoto e em lote na UI WinForms:** exposição somente leitura da allow-list via `Get-SpoolerAllowedComputer`, seletor de máquina no cabeçalho (local, alvos autorizados e lote `Todas autorizadas`), coluna `Máquina` na grade, credencial alternativa apenas em memória para alvos remotos, adaptação de privilégio local vs. remoto (Safeguard 3), confirmação reforçada em 2 etapas para `|PrintServer` individual (nunca `-AllowPrintServer` em lote) e tratamento de erros parciais/múltiplos resultados na interface.
9. **`Restart-Spooler` (`v1.1.0`):** reinício/início do serviço `Spooler` sem apagar os arquivos da fila (`PRINTERS`), preenchendo a lacuna entre `Remove-SpoolerJob` e `Reset-Spooler`, com suporte completo a `-WhatIf`, `-Confirm`, execução remota (1 máquina e lote), proteção de servidor de impressão em 2 camadas + `-AllowPrintServer`, refinamento da recomendação em `Test-Spooler` e botão **Reiniciar serviço** na UI (renomeando visualmente o reset para **Limpar fila (Resetar)**).

Cada passo: teste primeiro (ou auditoria rigorosa do teste), implementação, revisão do diff, commit atômico.

> Nota: a janela (passo 4) vem antes dos extras por escolha do projeto. Consequência aceita: a janela será estendida nos passos 5a a 5c e, depois, no remoto.

---

## N: Norms

- Funções com verbo aprovado do PowerShell (`Get-`, `Remove-`, `Reset-`, `Restart-`, `Test-`), `[CmdletBinding(SupportsShouldProcess)]` nas que alteram algo.
- Mensagens e log em português; nomes de código em inglês.
- Arquivos `.ps1`, `.psm1` e `.psd1` salvos em **UTF-8 com BOM** para compatibilidade com acentuação no Windows PowerShell 5.1.
- Sem `Write-Host` na lógica; saída como objetos, log em arquivo.
- Tratamento de erro com `try/catch` e `-ErrorAction Stop`; nada de `-ErrorAction SilentlyContinue` sem justificativa.
- Sem módulos externos em tempo de execução.
- Commits pequenos, mensagens no padrão `tipo: descrição` (ex.: `feat: lista jobs da fila`, `chore: estrutura inicial do modulo e CI`).

---

## Safeguards (inegociáveis)

1. **Nunca apagar fora da pasta do spooler** (`%SystemRoot%\System32\spool\PRINTERS`). Todo caminho é normalizado (`GetFullPath`) e validado antes de qualquer remoção, recusando caminhos fora da pasta exata ou tentativas de *path traversal* (`..\`). Apagar só arquivos `.SPL` e `.SHD`.
2. **Nunca reportar sucesso sem verificar** (serviço em execução e fila vazia). Em caso de erro após parar o serviço, tentar reiniciá-lo antes de reportar `Failed`.
3. **Exigir administrador** antes de qualquer ação que altere o sistema.
4. **Todas as ações são registradas em log**, inclusive simulações e recusas.
5. **Confirmação explícita** antes de reset, mostrando a máquina de destino.
6. **Remoto:** só máquinas presentes na allow-list; nenhum nome digitado livremente é executado.
7. **Remoto:** hostname em toda linha de log e em toda confirmação.
8. **Remoto:** servidores de impressão ficam bloqueados por padrão (reset derruba a impressão de todos); liberar exige confirmação reforçada.
9. **Remoto:** falha ou indisponibilidade de uma máquina não interrompe as demais nem aparece como sucesso.
10. **Credenciais:** nunca gravar senha em arquivo ou no repositório; usar o login atual ou `Get-Credential`.
11. **Simulação não altera nada:** teste automatizado obrigatório.
12. Testar numa VM/PC descartável antes do ambiente de trabalho; o v0 só é aposentado após validação.