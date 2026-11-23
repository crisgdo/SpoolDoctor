# AGENTS.md: SpoolDoctor

Ferramenta em PowerShell para diagnosticar e limpar a fila de impressão do Windows, local e remotamente. A fonte de verdade é o `spec.md`. Leia-o antes de qualquer tarefa.

## Regras inegociáveis

1. **Nunca apagar arquivos fora de `%SystemRoot%\System32\spool\PRINTERS`.** Todo caminho passa pela função de validação (com normalização para bloquear *path traversal* `..\`) antes de `Remove-Item`. Apagar só `.SPL` e `.SHD`.
2. **Nunca reportar sucesso sem verificar** o resultado (serviço em execução, fila vazia). Se a remoção falhar após parar o serviço, tentar reiniciar o serviço antes de retornar `Failed`.
3. **Toda função que altera algo usa `SupportsShouldProcess`** e respeita `-WhatIf`. Simulação não pode alterar nada, mas deve registrar log e retornar `ActionResult` com `Outcome = 'Simulated'`.
4. **Toda ação é registrada em log** (data/hora, máquina, usuário, ação, resultado), inclusive simulações e recusas.
5. **Remoto:** só executar em máquinas da allow-list (`config/allowed-computers.txt`). Nunca aceitar nome livre. Hostname em todo log e confirmação. Falha em uma máquina não afeta as outras. Servidores de impressão bloqueados por padrão.
6. **Nunca gravar credenciais** em arquivo, log ou repositório.
7. **Não adicionar módulos ou dependências externas** sem aprovação explícita. Em tempo de execução, só PowerShell 5.1 e o que o Windows já traz.
8. **Não alterar nem apagar `limpar_fila_impressao.bat`** (v0, plano B).
9. **Nunca executar o reset real na máquina de desenvolvimento.** Testes usam `Mock`.

## Como trabalhar

- Siga as **Operations** do `spec.md` na ordem em que estão (começando pela **Operação 0: scaffold + CI**), **uma tarefa por vez**. Antes de codar, proponha um plano curto e espere aprovação.
- **Testes primeiro:** liste os casos (incluindo entradas inválidas, caminhos fora da pasta, *path traversal*, extensão inválida, falha de serviço, máquina inacessível) e escreva o teste antes da implementação.
- Mudanças pequenas: **um commit atômico por tarefa**, mensagem no padrão `tipo: descrição` (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `chore:`).
- Se o código precisar divergir do spec, **pare e proponha a mudança no spec primeiro**.
- Não faça refatorações ou "melhorias" fora do escopo da tarefa.
- Se algo estiver ambíguo, pergunte em vez de supor.
- Explique o que mudou de forma que a pessoa possa revisar o diff linha a linha. Ela está aprendendo PowerShell: prefira código simples e legível a truques.

## Estrutura

- `src/Public`: funções exportadas (`Get-SpoolerAllowedComputer`, `Get-SpoolerJob`, `Remove-SpoolerJob`, `Reset-Spooler`, `Test-Spooler`).
- `src/Private`: wrappers finos do sistema, log, backup, validação de caminho. **Só aqui se toca o sistema.** Wrappers têm nome próprio (ex.: `Get-SpoolerJobRaw`), nunca o nome de um cmdlet nativo.
- `src/Remote`: despacho remoto e leitura da allow-list.
- `ui/`: interface WinForms, camada fina sem lógica de negócio.
- `tests/`: Pester. Testes não tocam o spooler real nem a rede.

## Convenções de código

- Verbos aprovados do PowerShell. Nomes de código em inglês; mensagens e log em português.
- **Encoding:** salvar arquivos `.ps1`, `.psm1` e `.psd1` em **UTF-8 com BOM** para evitar corrupção de acentos no Windows PowerShell 5.1.
- `try/catch` com `-ErrorAction Stop`; sem `SilentlyContinue` sem justificativa em comentário.
- Sem `Write-Host` na lógica: retornar objetos e logar em arquivo.
- Funções pequenas, com parâmetros tipados e validação (`[ValidateNotNullOrEmpty()]` etc.).
- **Mocks no Pester 5:** ao mockar funções privadas ou chamadas internas do módulo, sempre declarar `-ModuleName SpoolDoctor` (ex.: `Mock Stop-SpoolerService -ModuleName SpoolDoctor { ... }`).
- **Logs em testes:** nunca gravar no disco real durante testes; redirecionar para `TestDrive:\` usando o parâmetro `-LogPath`.

## Sensores (devem passar antes de qualquer commit)

> Pré-requisito no PC de desenvolvimento: o Windows traz Pester 3.4, e o `-CI` abaixo é do Pester 5. Instale uma vez: `Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck` e `Install-Module PSScriptAnalyzer`. Isso é dependência de desenvolvimento, não de execução.

```powershell
Invoke-Pester -Path ./tests -CI

$paths = @('./src', './ui') | Where-Object { Test-Path $_ }
$issues = foreach ($path in $paths) {
    Invoke-ScriptAnalyzer -Path $path -Recurse -Severity Warning,Error
}
if ($issues) {
    $issues | Format-Table -AutoSize
    exit 1
}
```

O CI (`.github/workflows/ci.yml`, `windows-latest`) roda os mesmos comandos e falha explicitamente se houver qualquer erro de teste ou aviso do analisador. PR com teste falhando ou aviso do analisador não é mergeado.

## Testes obrigatórios

- Remoção recusa qualquer caminho fora da pasta do spooler, tentativas de *path traversal* (`..\`) e extensões diferentes de `.SPL` e `.SHD`.
- Falha em `Stop-Service`/`Start-Service` ou arquivo remanescente na verificação final nunca vira mensagem de sucesso.
- Falha ao apagar arquivos após parar o serviço ainda tenta reiniciar o spooler (`finally`) antes de retornar `Failed`.
- `-WhatIf` não chama nenhuma função destrutiva, grava o registro no log e retorna `Outcome = 'Simulated'`.
- Execução sem privilégio de administrador é recusada antes de tocar no sistema e registrada em log.
- Remoto: máquina fora da allow-list é recusada; máquina inacessível gera `Unreachable` e as demais continuam.
- Servidor de impressão sem confirmação reforçada é bloqueado.

## Higiene de contexto

- Prefira sessões curtas, uma tarefa por sessão. Se a conversa ficar longa, resuma o estado e recomece.
- Mantenha este arquivo e o `spec.md` atualizados com o estado real do repositório.