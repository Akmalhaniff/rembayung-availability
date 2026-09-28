# Rembayung Dine-In Availability

Static site showing Rembayung (UMAI) dine-in / takeaway availability.
Data is fetched by `run-job.bat` on a local PC every 5 min and pushed here;
GitHub Pages redeploys automatically. All times are Malaysia Time (MYT).

## Files

- `index.html` — the website
- `fetch-availability.ps1` — UMAI fetcher (handles queue + server errors, MYT)
- `run-job.bat` — double-click to run once (fetch + push)
- `setup-task.bat` — double-click (admin) to schedule every 5 min
- `.github/workflows/pages.yml` — Pages deploy on data push

## Setup

1. `setx TELEGRAM_BOT_TOKEN "xxx"` + `setx TELEGRAM_CHAT_ID "yyy"`
2. Double-click `setup-task.bat`
3. Repo Settings → Pages → Source: **GitHub Actions**
