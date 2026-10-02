@echo off
rem ==========================================================================
rem  Ruta historica que usa Miku. El script real vive en scripts\ junto al
rem  resto del pipeline; esto solo reenvia los argumentos y el codigo de
rem  salida, para no romper la configuracion externa de Miku.
rem ==========================================================================
call "%~dp0..\scripts\interpolar_miku.bat" %*
exit /b %errorlevel%
