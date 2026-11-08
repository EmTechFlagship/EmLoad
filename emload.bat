@echo off
rem EmLoad CLI launcher - always uses the project virtual environment.
setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\emload.exe" (
    echo Virtual environment not found. Create it first:
    echo   python -m venv .venv
    echo   .venv\Scripts\pip install -r requirements.txt
    pause
    exit /b 1
)

".venv\Scripts\emload.exe" %*