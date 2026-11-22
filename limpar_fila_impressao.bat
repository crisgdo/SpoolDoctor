@echo off
:: Configura o console para UTF-8 para exibir caracteres corretamente
chcp 65001 > nul

echo =======================================================
echo     LIMPANDO A FILA DE IMPRESSÃO (SPOOLER DE IMPRESSÃO)
echo =======================================================
echo.

:: Verifica se o script esta rodando como Administrador
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERRO] Este script precisa ser executado como Administrador!
    echo.
    echo Por favor, clique com o botão direito neste arquivo .bat
    echo e selecione "Executar como Administrador".
    echo.
    pause
    exit /b
)

echo Parando o serviço de Spooler de Impressão...
net stop spooler
echo.

echo Apagando arquivos travados na fila de impressão...
del "%systemroot%\System32\spool\printers\*" /Q /F /S
echo.

echo Reiniciando o serviço de Spooler de Impressão...
net start spooler
echo.

echo =======================================================
echo     Fila de impressão limpa com sucesso!
echo =======================================================
echo.
pause
