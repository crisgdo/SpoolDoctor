# SpoolDoctor (`v1.0.0`)

Ferramenta em PowerShell para diagnosticar e limpar a fila de impressão do Windows, local e remotamente, com segurança, verificação pós-ação e trilha de auditoria.

## Visão geral

Quando a fila de impressão trava, reiniciar o spooler às cegas apaga tudo sem informar o que falhou, sem salvar cópia dos arquivos e sem gerar histórico. O **SpoolDoctor** substitui esse processo por um fluxo seguro e auditável:

- **Diagnóstico preventivo (`Test-Spooler`):** verifica estado do serviço `Spooler`, impressoras em alerta/offline, jobs travados por idade ou status e arquivos `.SPL`/`.SHD` órfãos.
- **Cancelamento seletivo (`Remove-SpoolerJob`):** tenta remover apenas o job problemático antes de recorrer ao reset completo.
- **Reset verificado com backup (`Reset-Spooler`):** faz backup prévio dos arquivos `.SPL`/`.SHD` com retenção automática, reinicia o serviço mesmo em falha (`finally`) e só reporta sucesso após confirmar serviço em execução e fila vazia.
- **Simulação (`-WhatIf`) e auditoria:** toda operação (incluindo simulações e recusas) registra log estruturado.
- **Interface gráfica (`Iniciar.bat`) e operação remota via WinRM:** elevação automática via UAC, seleção de máquinas autorizadas (allow-list), suporte a lote e proteção contra reset acidental em servidores de impressão.

> **Nota sobre script legado:** o arquivo `limpar_fila_impressao.bat` (v0) permanece no repositório apenas como referência histórica e plano B, sem alterações.

---

## Requisitos

- **Sistema operacional:** Windows 10/11 ou Windows Server.
- **PowerShell:** Windows PowerShell 5.1 (nativo no Windows; **nenhum** módulo externo é exigido em tempo de execução).
- **Execução remota (opcional):** WinRM habilitado e conta com privilégio de Administrador na máquina de destino (alinhar previamente com a equipe de TI).
- **Desenvolvimento e testes:** Pester 5+ e `PSScriptAnalyzer`.

---

## Uso rápido pela Interface Gráfica (`Iniciar.bat`)

1. Dê duplo clique em **`Iniciar.bat`**.
2. A interface solicita elevação automática via UAC (com trava anti-loop para não abrir janelas duplicadas).
3. Se você recusar o UAC, a janela abre em **modo somente leitura local** e exibe o botão **Reiniciar como Administrador**. Mesmo sem UAC local, alvos **remotos** habilitam **Cancelar job selecionado** e **Resetar Spooler**, pois o privilégio de administrador é validado no destino via WinRM.

### Controles da janela

- **Seletor `Máquina`:** inicia em `Local (<COMPUTERNAME>)`. Lista as máquinas da allow-list (`config/allowed-computers.txt`), marcando servidores de impressão como `<HOSTNAME> [Servidor de Impressão]`. Quando há 2 ou mais máquinas cadastradas, exibe também **`Todas autorizadas (N máquinas)`** para consulta/operação em lote.
- **`Impressora (opcional)` e `Atualizar`:** filtra a lista de jobs pelo nome da impressora na máquina ou lote selecionado. A grade mostra a coluna **`Máquina`** para identificar a origem de cada job.
- **`Usar credencial alternativa`:** disponível apenas para alvos remotos. Solicita usuário/senha via `Get-Credential` e mantém a credencial **somente em memória** enquanto marcada e até fechar a janela (nunca é gravada em arquivo ou log).
- **`Modo simulação (-WhatIf)`:** simula cancelamento ou reset sem alterar o sistema, exibindo e registrando `Simulated`.
- **`Fazer backup antes de resetar`:** ligado por padrão; desmarque apenas se quiser acionar `-SkipBackup`.
- **`Diagnosticar`:** executa `Test-Spooler` na máquina local, remota ou em todo o lote e exibe o resumo no painel de status.
- **`Cancelar job selecionado`:** cancela o job marcado na grade, direcionando automaticamente para a máquina exata do job e exibindo o hostname na confirmação.
- **`Resetar Spooler`:** exibe confirmação explícita com a máquina de destino. Em servidores marcados com `|PrintServer`, exige **confirmação reforçada em 2 etapas**; no modo lote, servidores `|PrintServer` são bloqueados automaticamente para evitar quedas acidentais de impressão coletiva.

---

## Uso via CLI (módulo `SpoolDoctor`)

Importe o módulo a partir da raiz do repositório:

```powershell
Import-Module .\src\SpoolDoctor.psd1
```

### Funções públicas exportadas

| Função | Finalidade | Altera o sistema? |
|---|---|---|
| `Test-Spooler` | Diagnostica serviço, impressoras em erro, jobs travados e arquivos órfãos. | Não (somente leitura) |
| `Get-SpoolerJob` | Lista jobs da fila com tamanho, idade e status. | Não (somente leitura) |
| `Remove-SpoolerJob` | Cancela um job específico com verificação pós-remoção. | Sim (`SupportsShouldProcess`) |
| `Reset-Spooler` | Para o `Spooler`, faz backup, limpa `.SPL`/`.SHD`, reinicia e verifica. | Sim (`SupportsShouldProcess`) |
| `Get-SpoolerAllowedComputer` | Lê a allow-list (`config/allowed-computers.txt`) sem alterar nada. | Não (somente leitura) |

### Exemplos prontos (copie e cole)

**Diagnóstico rápido:**

```powershell
# Diagnóstico local com limiar padrão de 15 minutos para jobs travados
Test-Spooler

# Considerando jobs travados a partir de 5 minutos
Test-Spooler -StuckThresholdMinutes 5
```

**Listar e cancelar um job específico:**

```powershell
# Simular cancelamento via pipeline
Get-SpoolerJob | Where-Object { $_.Id -eq 42 } | Remove-SpoolerJob -WhatIf

# Cancelar um job informando impressora e ID diretamente (como Administrador)
Remove-SpoolerJob -PrinterName 'HP LaserJet' -Id 42
```

**Reset seguro (`-WhatIf`, backup padrão com retenção e `-SkipBackup`):**

```powershell
# Simular o reset completo sem alterar o sistema
Reset-Spooler -WhatIf

# Reset com backup padrão e retenção de 14 dias (padrão: 7 dias; 0 desativa limpeza)
Reset-Spooler -BackupRetentionDays 14

# Reset sem copiar backup antes de apagar (use apenas quando tiver certeza)
Reset-Spooler -SkipBackup
```

**Execução remota em 1 máquina e em lote:**

```powershell
# Conferir máquinas autorizadas na allow-list
Get-SpoolerAllowedComputer

# Diagnóstico e listagem em uma máquina autorizada
Test-Spooler -ComputerName 'PC-FINANCEIRO-01'
Get-SpoolerJob -ComputerName 'PC-FINANCEIRO-01'

# Execução em lote usando credencial alternativa em memória
$cred = Get-Credential
Test-Spooler -ComputerName @('PC-FINANCEIRO-01', 'ESTACAO-ATENDIMENTO-02.empresa.local') -Credential $cred
Reset-Spooler -ComputerName @('PC-FINANCEIRO-01', 'ESTACAO-ATENDIMENTO-02.empresa.local') -Credential $cred -WhatIf

# Reset em servidor de impressão exige liberação explícita (-AllowPrintServer) e confirmação
Reset-Spooler -ComputerName 'SRV-PRINT-01' -AllowPrintServer -Credential $cred
```

---

## Segurança e Proteções (Safeguards)

### Allow-list obrigatória (`config/allowed-computers.txt`)

> **Guia prático:** veja o passo a passo completo de preparação de rede/WinRM, cadastro de máquinas e solução de problemas em [docs/uso-remoto.md](docs/uso-remoto.md).

- A execução remota aceita **apenas** máquinas previamente cadastradas em `config/allowed-computers.txt` (um hostname ou FQDN por linha; linhas em branco e iniciadas por `#` são ignoradas).
- Para marcar servidores de impressão, utilize a tag explícita:
  ```text
  PC-FINANCEIRO-01
  ESTACAO-ATENDIMENTO-02.empresa.local
  SRV-PRINT-01|PrintServer
  ```
- **Por que IPs literais são bloqueados:** `-ComputerName` e a allow-list aceitam estritamente hostnames/FQDNs válidos (RFC 1123). Bloquear IPs garante vínculo inequívoco com a allow-list nominal, compatibilidade padrão com autenticação Kerberos no WinRM e rastreabilidade clara por hostname em confirmações e logs.

### Proteções operacionais

- **Isolamento de pasta e extensão:** todo caminho é normalizado (`GetFullPath`) para bloquear *path traversal* (`..\`) e garantir que somente arquivos `.SPL` e `.SHD` dentro de `%SystemRoot%\System32\spool\PRINTERS` possam ser removidos.
- **Recuperação garantida e verificação final:** se `Reset-Spooler` parar o serviço e ocorrer erro no backup ou remoção, o bloco `finally` tenta reiniciar o serviço `Spooler` antes de retornar `Failed`. O resultado só é `OK` se o serviço estiver `Running` e a pasta estiver vazia.
- **Proteção de servidor de impressão:** bloqueado em duas camadas — estática via `|PrintServer` na allow-list e dinâmica no destino (Windows Server `ProductType` 2/3 ou impressora compartilhada). Sem `-AllowPrintServer` (e confirmação reforçada), o reset é recusado.
- **Isolamento de falhas em lote e sigilo de credenciais:** falha ou máquina indisponível (`Unreachable`) gera log individual e não interrompe as demais máquinas; usuários e senhas nunca são gravados em disco ou log.

### Logs, backups e restauração

- **Logs:** `%ProgramData%\SpoolDoctor\logs\spooldoctor.log` (UTF-8, uma linha estruturada por evento; redirecionável via `-LogPath`).
- **Backups:** `%ProgramData%\SpoolDoctor\backups\<yyyyMMdd-HHmmss>` (criado quando há arquivos a salvar, com limpeza automática de pastas vencidas após 7 dias por padrão; redirecionável via `-BackupPath`).
- **Como restaurar um backup:** caso precise recuperar um documento removido, abra o PowerShell como Administrador, pare o serviço (`Stop-Service -Name Spooler`), copie o par de arquivos `.SPL` e `.SHD` da pasta de backup para `%SystemRoot%\System32\spool\PRINTERS` e inicie o serviço (`Start-Service -Name Spooler`).

---

## Desenvolvimento e Testes

### Estrutura do repositório

```text
SpoolDoctor/
├── config/
│   └── allowed-computers.txt      # Allow-list de máquinas remotas e |PrintServer
├── docs/
│   └── uso-remoto.md              # Tutorial passo a passo de configuração e uso remoto
├── src/
│   ├── SpoolDoctor.psd1           # Manifesto do módulo (v1.0.0)
│   ├── SpoolDoctor.psm1           # Loader de Private, Remote e Public
│   ├── Public/                    # 5 funções exportadas (CLI e consumidas pela UI)
│   ├── Private/                   # Wrappers de sistema, log, backup e validação de caminho
│   └── Remote/                    # Validação de alvo, allow-list e despacho WinRM
├── ui/
│   └── SpoolDoctorUI.ps1          # Interface WinForms (camada fina + UAC automático)
├── tests/                         # Suíte Pester 5+ (com Mocks e TestDrive:\)
├── .github/workflows/ci.yml       # Pipeline CI (windows-latest)
├── Iniciar.bat                    # Launcher da UI em uma linha
└── limpar_fila_impressao.bat      # Script legado v0 (mantido apenas por histórico)
```

### Rodando os testes e o analisador localmente

Instale as dependências de desenvolvimento uma única vez no PowerShell:

```powershell
Install-Module -Name Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force
```

Execute os mesmos sensores do CI antes de qualquer commit:

```powershell
Invoke-Pester -Path ./tests -CI

$paths = @('./src', './ui') | Where-Object { Test-Path -Path $_ }
$issues = foreach ($path in $paths) {
    Invoke-ScriptAnalyzer -Path $path -Recurse -Severity Warning,Error
}
if ($issues) {
    $issues | Format-Table -AutoSize
    exit 1
}
```
