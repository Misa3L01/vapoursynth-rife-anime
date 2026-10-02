@echo off
:: Abre la app de interpolacion. Portable: resuelve la ruta desde donde este
:: este archivo, asi que funciona en cualquier unidad o PC.
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\interpolar-app.ps1"
