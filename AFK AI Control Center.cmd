@echo off
title AFK AI - Control Center
cd /d "%~dp0"
echo Opening the AFK AI Control Center...
echo.
rem Same interpreter probe as "Start Local AI.cmd": a bare "py" launches the
rem NEWEST Python on the PC, which may not be the one localai was installed into.
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
echo   finish, then open the Control Center again.
goto :end

:run
%PYCMD% -m localai dashboard
if errorlevel 1 (
  echo.
  echo   AFK-102 - The Control Center could not open.
  echo   What to do: double-click "Start Local AI.cmd" first, wait for it to say
  echo   it is ready, then try the Control Center again.
  echo.
  echo   Advanced: the raw error is printed above this box.
  goto :end
)

:end
echo.
pause
