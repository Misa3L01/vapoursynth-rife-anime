@echo off
:: Descarga (o actualiza) mpv en la carpeta mpv\. Lo necesita "Ver en tiempo
:: real". La logica esta en install-mpv.ps1.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-mpv.ps1"
if errorlevel 1 (
    echo.
    echo [X] No se pudo instalar mpv.
)
pause
