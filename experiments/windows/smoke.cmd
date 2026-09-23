@echo off
call C:\BuildTools\Common7\Tools\VsDevCmd.bat -arch=amd64
if errorlevel 1 exit /b 1
set "PATH=C:\moon\bin;%PATH%"
where cl.exe || exit /b 1
moon.exe version --all || exit /b 1
mkdir C:\probe || exit /b 1
cd /d C:\probe || exit /b 1
moon.exe new hello || exit /b 1
cd hello || exit /b 1
moon.exe check || exit /b 1
moon.exe test || exit /b 1
moon.exe run --target native cmd/main || exit /b 1
moon.exe build --target native --release || exit /b 1
