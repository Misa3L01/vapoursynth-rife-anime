@echo off
:: Arrastra un video encima para verlo en mpv interpolado en tiempo real, sin
:: generar archivos. Los ajustes estan en config.bat, seccion "ver en tiempo
:: real". Tambien se abre desde la app (Interpolar.bat).
call "%~dp0scripts\ver-en-vivo.bat" %*
