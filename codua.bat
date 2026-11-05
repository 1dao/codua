@echo off
setlocal

rem Resolve assets and configuration relative to the launcher, even when called elsewhere.
pushd "%~dp0" || exit /b 1

if not exist "bin\xnet.exe" (
    echo Error: Cannot find bin\xnet.exe. Restore or build the bundled runtime first.
    popd
    pause
    exit /b 1
)

"bin\xnet.exe" "scripts\xagent\gui.lua" %*
set "codua_exit_code=%errorlevel%"
popd

rem Keep startup errors visible when launched from Explorer.
if not "%codua_exit_code%"=="0" pause
exit /b %codua_exit_code%
