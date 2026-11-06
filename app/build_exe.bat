@echo off
rem Builds WalkingPad.exe from this folder. Needs Python 3.12 (python.org, tick "Add python.exe to PATH").
title Building WalkingPad.exe
cd /d "%~dp0"
set "PY=python"
py -3 --version >nul 2>nul && set "PY=py -3"
%PY% -m pip install --upgrade bleak aiohttp pywebview pystray pillow pyinstaller || goto :fail
%PY% -m PyInstaller --noconfirm --onefile --noconsole --icon walkingpad.ico --name WalkingPad ^
  --add-data "walkingpad_ui.html;." --add-data "..\addon\Windrunner;Windrunner" ^
  --collect-all bleak --collect-all winrt --collect-all webview --collect-all clr_loader --collect-all pythonnet ^
  --hidden-import pystray._win32 walkingpad_app.py || goto :fail
echo.
echo Done: dist\WalkingPad.exe
pause
exit /b 0
:fail
echo Build failed - see above.
pause
exit /b 1
