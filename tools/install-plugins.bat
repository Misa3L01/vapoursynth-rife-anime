@echo off
setlocal
chcp 65001 >nul
pushd "%~dp0.."

set "VSREPO=%CD%\Python\Scripts\vsrepo.exe"
if not exist "%VSREPO%" (
    echo [X] No existe %VSREPO%
    echo     Instala vsrepo primero:  Python\python.exe -m pip install -r requirements.txt
    goto :fin
)

echo Actualizando indice de paquetes...
"%VSREPO%" update

echo.
echo Instalando plugins requeridos...
"%VSREPO%" install systems.innocent.lsmas com.vapoursynth.misc com.holywu.cas info.akarin.vsplugin

echo.
echo Instalando plugins opcionales ^(deband por GPU^)...
"%VSREPO%" install com.vs.placebo

echo.
echo Verificando...
"%CD%\Python\python.exe" -c "import vapoursynth as vs; c=vs.core; ns=sorted(p.namespace for p in c.plugins()); req=['lsmas','misc','cas','akarin']; missing=[n for n in req if n not in ns]; print('FALTAN:', missing) if missing else print('OK - todos los plugins requeridos estan presentes')"

:fin
popd
pause
