$PSScriptRoot = "C:\Users\akmal\OneDrive - Energetic Point Sdn Bhd\Documents\GitHub\rembayung-availability"
Set-Location $PSScriptRoot
$env:TELEGRAM_BOT_TOKEN="8768100850:AAHzqk52JXnDbwvvn1zg6rR6HOGolvcK5sY"
$env:TELEGRAM_CHAT_ID="56391574"
.\fetch-availability.ps1 -Days 14 -PartySize 3
git add availability.json opened.json 2>$null
if (-not (git diff --cached --quiet)) { git commit -m "data $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ') [skip netlify]"; git push }
