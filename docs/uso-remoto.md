# Tutorial: Como adicionar e usar um PC remoto no SpoolDoctor

Este guia mostra passo a passo como preparar, cadastrar e diagnosticar ou limpar a fila de impressão de outro computador na rede usando o **SpoolDoctor**, tanto pela interface gráfica (`Iniciar.bat`) quanto pelo PowerShell (CLI).

> **Nada precisa ser instalado no PC remoto:** o SpoolDoctor envia apenas as funções necessárias em memória pela sessão WinRM e encerra a conexão ao final.

---

## Pré-requisitos antes de cadastrar

Antes de incluir um computador na allow-list, confirme os 3 itens abaixo no PC de destino:

1. **PC ligado e acessível por nome (hostname ou FQDN):**
   - Exemplos válidos: `PC-RECEPCAO-01` ou `ESTACAO-ATENDIMENTO-02.empresa.local`.
   - **IPs literais (como `192.168.1.50`) são bloqueados** por segurança e validação RFC 1123.
2. **WinRM habilitado (porta TCP `5985`):**
   - Em ambiente corporativo, o WinRM e a regra de firewall costumam ser liberados pela equipe de TI (via GPO). Combine com a TI antes de habilitar em máquinas da empresa.
3. **Conta com privilégio de Administrador no PC remoto:**
   - Pode ser o seu usuário atual do domínio (se for administrador na máquina alvo) ou uma conta alternativa informada na hora (somente em memória).

### Domínio Active Directory vs. Workgroup (Grupo de Trabalho)

- **Em Domínio (AD):** se os dois PCs estiverem no mesmo domínio, a autenticação Kerberos funciona diretamente pelo hostname ou FQDN — normalmente basta o WinRM habilitado e permissão de administrador no destino.
- **Em Workgroup (fora de domínio):** como não há Kerberos de domínio, o Windows exige configurar `TrustedHosts` no **seu** PC (como Administrador) e usar uma conta local administradora do destino (`NOME-DO-PC\Administrador`) na opção de credencial alternativa:
  ```powershell
  # Apenas em redes Workgroup (execute no seu PC como Administrador)
  Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'PC-RECEPCAO-01' -Concatenate -Force
  ```

---

## Passo 1 — Descobrir e validar o nome do PC remoto

No **PC com problema** (ou consultando o inventário da TI), confira o hostname e o sufixo DNS:

```powershell
hostname
$env:COMPUTERNAME
$env:USERDNSDOMAIN
```

No **seu PC**, confirme que o nome resolve corretamente na rede:

```powershell
Resolve-DnsName -Name 'PC-RECEPCAO-01'
# Ou teste rápido de alcance:
ping -n 1 PC-RECEPCAO-01
```

> Se `Resolve-DnsName` não resolver pelo nome curto, use o FQDN completo (ex.: `PC-RECEPCAO-01.empresa.local`).

---

## Passo 2 — Validar o WinRM antes de cadastrar

No **seu PC**, teste se o serviço WinRM do destino está respondendo:

```powershell
Test-WSMan -ComputerName 'PC-RECEPCAO-01'
```

- **Se funcionar:** o comando retorna propriedades com `wsmid`, `ProtocolVersion` e `ProductVersion`. O destino está pronto.
- **Se falhar** (timeout ou conexão recusada): o WinRM está desabilitado ou bloqueado por firewall no destino.

Caso você tenha autorização da TI para habilitar o WinRM diretamente no **PC remoto**, abra o PowerShell **como Administrador no destino** e execute:

```powershell
Enable-PSRemoting -Force
```

Em seguida, repita `Test-WSMan -ComputerName 'PC-RECEPCAO-01'` a partir do seu PC.

---

## Passo 3 — Cadastrar o PC em `config/allowed-computers.txt`

Por segurança, o SpoolDoctor recusa qualquer máquina que não esteja listada na allow-list do repositório.

1. Abra o arquivo `config/allowed-computers.txt` em um editor de texto (como o Bloco de Notas).
2. Adicione **um hostname ou FQDN por linha**, respeitando as regras:
   - Linhas vazias e linhas iniciadas por `#` são ignoradas.
   - **Nunca** coloque IPs literais.
   - **Nunca** coloque senhas ou credenciais neste arquivo.
   - Para **servidores de impressão** (ou PCs com impressoras compartilhadas cujo reset derrubaria vários usuários), adicione `|PrintServer` ao final da linha para exigir confirmação reforçada.

### Exemplo de `config/allowed-computers.txt`

```text
# Estações autorizadas
PC-RECEPCAO-01
ESTACAO-ATENDIMENTO-02.empresa.local

# Servidor de impressão (bloqueado por padrão para reset; exige confirmação reforçada)
SRV-PRINT-01|PrintServer
```

3. Salve o arquivo e valide localmente **sem abrir nenhuma conexão na rede**:

```powershell
Import-Module .\src\SpoolDoctor.psd1
Get-SpoolerAllowedComputer
```

Saída esperada: lista com `ComputerName` e `IsPrintServer` (`True` ou `False`) para cada linha cadastrada.

---

## Passo 4 — Averiguar e operar pela Interface Gráfica (`Iniciar.bat`)

1. Dê duplo clique em **`Iniciar.bat`** na pasta raiz do projeto.
   - *Observação:* mesmo que você recuse o prompt UAC no seu computador (abrindo em modo somente leitura local), **as ações remotas continuam habilitadas**, pois o privilégio de administrador é verificado na máquina de destino via WinRM.
2. No seletor **`Máquina:`** (canto superior esquerdo), escolha o computador desejado (ex.: `PC-RECEPCAO-01`).
   - Máquinas marcadas com `|PrintServer` aparecem como `<HOSTNAME> [Servidor de Impressão]`.
   - Com 2 ou mais máquinas cadastradas, aparece também **`Todas autorizadas (N máquinas)`** para consulta e ações em lote.
3. **Se o seu login atual não for administrador no destino:**
   - Marque **`Usar credencial alternativa`** e informe usuário (`DOMINIO\usuario` ou `PC-RECEPCAO-01\Administrador`) e senha.
   - A credencial fica **apenas em memória** enquanto a opção estiver marcada e até fechar a janela (nunca é gravada em disco ou log).
4. **Siga a ordem segura de investigação:**
   1. Clique em **`Diagnosticar`**: consulta o serviço `Spooler`, impressoras com alerta/offline, jobs travados e arquivos `.SPL`/`.SHD` órfãos sem alterar nada.
   2. Clique em **`Atualizar`**: lista os jobs na grade, exibindo na primeira coluna (**`Máquina`**) a origem de cada item.
   3. *(Se houver job travado)* Selecione a linha do job na grade e clique em **`Cancelar job selecionado`**. Se quiser testar antes, marque **`Modo simulação (-WhatIf)`**.
   4. *(Último recurso)* Mantenha **`Fazer backup antes de resetar`** marcado e clique em **`Resetar Spooler`**.
      - Em alvo individual marcado como `|PrintServer`, a janela exige **confirmação reforçada em 2 etapas**.
      - No modo lote (`Todas autorizadas`), servidores `|PrintServer` são bloqueados automaticamente e não são resetados sem seleção individual.

---

## Passo 5 — Alternativa rápida via PowerShell (CLI)

A partir da pasta do SpoolDoctor:

```powershell
Import-Module .\src\SpoolDoctor.psd1

# 1. Diagnóstico somente leitura em 1 máquina
Test-Spooler -ComputerName 'PC-RECEPCAO-01'

# 2. Listar jobs da fila remota
Get-SpoolerJob -ComputerName 'PC-RECEPCAO-01'

# 3. Simular o cancelamento de um job específico (ID 42)
Remove-SpoolerJob -ComputerName 'PC-RECEPCAO-01' -PrinterName 'HP LaserJet' -Id 42 -WhatIf

# 4. Usar credencial alternativa em memória para diagnóstico e reset simulado
$cred = Get-Credential
Test-Spooler -ComputerName 'PC-RECEPCAO-01' -Credential $cred
Reset-Spooler -ComputerName 'PC-RECEPCAO-01' -Credential $cred -WhatIf

# 5. Consulta em lote (erros isolados não interrompem as máquinas saudáveis)
Test-Spooler -ComputerName @('PC-RECEPCAO-01', 'ESTACAO-ATENDIMENTO-02.empresa.local') -Credential $cred
```

> Para resetar um servidor de impressão via CLI, é obrigatório informar `-AllowPrintServer` explicitamente (além de confirmar o prompt):
> `Reset-Spooler -ComputerName 'SRV-PRINT-01' -AllowPrintServer -Credential $cred -WhatIf`

---

## Solução de problemas comuns (Troubleshooting)

| Sintoma / Mensagem | Causa provável | Como resolver |
|---|---|---|
| **`Outcome = Unreachable`** | PC desligado, fora da VPN/rede, DNS não resolve o nome ou WinRM bloqueado. | Confirme `Resolve-DnsName` e `Test-WSMan -ComputerName 'NOME-DO-PC'`; alinhe liberação do WinRM/firewall com a TI. |
| **`Outcome = Failed` — Acesso negado / autenticação** | O usuário atual não tem permissão de Administrador no PC remoto (ou falta `TrustedHosts` em Workgroup). | Marque **`Usar credencial alternativa`** (ou use `-Credential`) com uma conta admin do destino; em Workgroup, revise `TrustedHosts`. |
| **`não está autorizada na allow-list`** | O hostname ainda não está em `config/allowed-computers.txt` (ou está comentado com `#`). | Adicione o hostname exato em `config/allowed-computers.txt` e reabra a janela do SpoolDoctor. |
| **`Nome de máquina inválido`** | Foi informado IP literal (ex.: `192.168.1.50`), espaço ou caractere especial. | Substitua o IP pelo hostname ou FQDN válido (RFC 1123). |
| **`[AVISO]` ao abrir a janela sobre allow-list** | Linha malformada, marcação diferente de `\|PrintServer` ou IP dentro de `config/allowed-computers.txt`. | Corrija a linha apontada no arquivo e reabra a janela; enquanto isso o SpoolDoctor opera em modo local. |
| **`Reset bloqueado` (servidor de impressão)** | O alvo está marcado com `\|PrintServer` ou foi detectado como Windows Server / impressora compartilhada. | Confirme que não há outros usuários imprimindo; selecione o servidor individualmente na UI (confirmação em 2 etapas) ou use `-AllowPrintServer` na CLI. |

---

## Como remover um PC e consultar os logs

- **Remover acesso:** apague a linha do computador em `config/allowed-computers.txt` (ou comente com `#` no início) e reabra a interface gráfica.
- **Auditoria local das ações:** todas as tentativas (sucesso, `Unreachable`, falhas, simulações `-WhatIf` e recusas) ficam registradas em `%ProgramData%\SpoolDoctor\logs\spooldoctor.log`:

```powershell
Get-Content -LiteralPath "$env:ProgramData\SpoolDoctor\logs\spooldoctor.log" -Tail 20 -Encoding UTF8
```
