@echo off
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars32.bat" >nul 2>&1
cd /d "%~dp0"
cl /nologo /W3 /MT chargedbuffer_repro.c odbc32.lib /Fechargedbuffer_repro.exe
