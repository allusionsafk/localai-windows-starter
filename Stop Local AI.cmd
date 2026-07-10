@echo off
title Stop Local AI
cd /d "%~dp0"
echo Stopping Local AI...
echo.
rem Same interpreter probe as Start Local AI.cmd: the installer used py -3.12.
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
echo Run "Install Local AI.cmd" first.
goto :end

:run
%PYCMD% -m localai stop
if errorlevel 1 (
  echo.
  echo Something went wrong - read the messages above this line.
)

:end
echo.
pause
