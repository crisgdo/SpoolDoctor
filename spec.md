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
- **RF8.** Elevação automática: exigir ou solicitar administrador, em vez de depender do usuário.
- **RF9.** Diagnóstico: serviço do spooler ativo, jobs parados há mais de N minutos, impressora respondendo.
- **RF10. Execução remota:** executar RF1, RF2, RF3 e RF9 em outra máquina via `Invoke-Command` (WinRM), com relatório por máquina.
  - **Pré-requisitos (fora do controle do código):** WinRM habilitado na máquina de destino e conta com permissão de administrador nela. Em ambiente corporativo, isso depende do setor de TI: combinar com a TI **antes** de testar em máquinas reais.
- **RF11.** Interface gráfica (WinForms dentro do PowerShell) com lista de jobs, botões e confirmação.
- **RF12.** Launcher `.bat` de uma linha para duplo clique.

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
- **PrintJob:** `Id`, `PrinterName`, `Document`, `SizeBytes`, `SubmittedAt`, `Status`, `ComputerName`.
- **SpoolerService:** estado (`Running`, `Stopped`, ...), máquina.
- **ActionResult:** `ComputerName`, `Action`, `Outcome` (`OK`, `Failed`, `Unreachable`, `Skipped`, `Simulated`), `Message`, `Timestamp`.
- **TargetList:** lista de máquinas permitidas (allow-list) lida de arquivo.

Relações: Printer 1..N PrintJob; cada ação produz um ActionResult por máquina.

---

## A: Approach

- **Módulo `.psm1`** com a lógica em funções pequenas; a interface e o launcher são camadas finas por cima.
- **Isolamento do sistema:** só poucas funções privadas tocam o sistema. Cada uma é um wrapper fino com **nome próprio** (ex.: `Get-SpoolerJobRaw`, `Remove-SpoolerJobRaw`, `Get-SpoolerServiceStatus`, `Stop-SpoolerService`, `Start-SpoolerService`, `Get-SpoolFile`, `Remove-SpoolFile`, `Copy-SpoolFile`) que chama o cmdlet nativo por dentro (`Get-PrintJob`, `Remove-PrintJob`, `Get-Service`, `Stop-Service`, `Start-Service`, `Get-ChildItem`, `Remove-Item`, `Copy-Item`). Nunca criar função com o mesmo nome de um cmdlet nativo. Os testes substituem os wrappers com `Mock` (Pester 5, usando `-ModuleName SpoolDoctor`).
- **Remoto como camada de despacho sem instalação prévia:** uma função em `src/Remote` decide *onde* executar (local ou `Invoke-Command`) sem alterar a lógica do reset. Como nada é instalado nas máquinas de destino, o despacho remoto injeta os *scriptblocks*/funções necessários diretamente na sessão remota.
- **Escalonamento do reparo:** primeiro cancelar o job; só então reset do spooler.
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
    Public/    # Get-SpoolerJob, Remove-SpoolerJob, Reset-Spooler, Test-Spooler
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
7. **Remoto, em lote:** várias máquinas, falha isolada por máquina.

Cada passo: teste primeiro (ou auditoria rigorosa do teste), implementação, revisão do diff, commit atômico.

> Nota: a janela (passo 4) vem antes dos extras por escolha do projeto. Consequência aceita: a janela será estendida nos passos 5a a 5c e, depois, no remoto.

---

## N: Norms

- Funções com verbo aprovado do PowerShell (`Get-`, `Remove-`, `Reset-`, `Test-`), `[CmdletBinding(SupportsShouldProcess)]` nas que alteram algo.
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