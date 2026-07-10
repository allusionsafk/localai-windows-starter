@echo off
title Start Local AI
cd /d "%~dp0"
echo Starting Local AI (Ollama + chat UI). First start can take a minute...
echo.
rem The installer installs localai into Python 3.12 (py -3.12). Probe for the
rem interpreter that actually has it: a bare "py" launches the NEWEST Python
rem on the PC, which may not be the one localai was installed into.
py -3.12 -c "import localai" >nul 2>nul
if not errorlevel 1 (
  set "PYCMD=py -3.12"
  goto :run
)
py -c "import localai" >nul 2>nul
if not errorlevel 1 (
  set "PYCMD=py"
  goto :run
)
python -c "import localai" >nul 2>nul
if not errorlevel 1 (
  set "PYCMD=python"
  goto :run
)
echo Could not find the Local AI program on this PC.
echo Run "Install Local AI.cmd" first, then try this again.
goto :end

:run
%PYCMD% -m localai start
if errorlevel 1 (
  echo.
  echo Something went wrong - read the messages above this line.
  goto :end
)
echo.
echo Chat is at  http://127.0.0.1:3000

:end
echo.
pause
