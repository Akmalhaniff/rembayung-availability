@echo off
cd /d "%~dp0"
echo [%date% %time%] --- run start --- >> "%~dp0run-job.log"
echo === Rembayung availability check ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fetch-availability.ps1" -Days 14 -PartySize 3
echo [%date% %time%] fetch exit: %errorlevel% >> "%~dp0run-job.log"
powershell -NoProfile -Command "(Get-Content '%~dp0availability.json' -Raw | ConvertFrom-Json).lastUpdated" >> "%~dp0run-job.log" 2>nul
echo.
echo === Pushing to GitHub ===
git add availability.json opened.json 2>nul
git diff --cached --quiet
if errorlevel 1 (
  git commit -m "data %date% %time% [skip netlify]"
  git push
  echo [%date% %time%] pushed >> "%~dp0run-job.log"
) else (
  echo No changes, nothing to push.
  echo [%date% %time%] no changes >> "%~dp0run-job.log"
)
echo.
if "%1"=="--no-pause" exit /b 0
pause
