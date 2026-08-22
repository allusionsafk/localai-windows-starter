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
echo.
echo   AFK-101 - AFK AI is not installed on this PC yet.
echo   What to do: double-click "Install Local AI.cmd" in this folder, let it
echo   finish, then use this icon again.
goto :end

:run
%PYCMD% -m localai start
if errorlevel 1 (
  echo.
  echo   AFK-100 - AFK AI could not finish starting up.
  echo.
  echo   What to do: make sure Docker Desktop is open and has finished
  echo   starting (its whale icon near the clock stops animating), then
  echo   double-click this icon again.
  echo.
  echo   Still stuck? Open "AFK AI Control Center.cmd" in this folder and use
  echo   Copy Diagnostic Report, then send that text to whoever set this up.
  echo.
  echo   Advanced: the raw technical detail is in the messages above this box.
  goto :end
)
echo.
echo   AFK AI is ready. Your chat should have opened in the browser.
echo   If it did not, open  http://127.0.0.1:3000

:end
echo.
pause
