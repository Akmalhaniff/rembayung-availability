@echo off
:: 1-click setup: registers Rembayung 5min task pointing at run-job.bat
:: Self-elevate to admin if needed
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting admin rights...
  powershell -Command "Start-Process '%~f0' -Verb RunAs"
  exit /b
)
echo Stopping old task (if running)...
schtasks /delete /tn "Rembayung 5min" /f 2>nul
echo Registering scheduled task...
schtasks /create /tn "Rembayung 5min" /tr "\"%~dp0run-job.bat\" --no-pause" /sc minute /mo 5 /ru SYSTEM /rl HIGHEST /f
echo.
echo Exit code: %errorlevel%
echo.
echo Done. The job now runs every 5 min. Double-click run-job.bat for a manual run.
pause
