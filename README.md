# Rembayung Dine-In Availability Website

A tiny static site that shows which dates have **dine-in** tables open at
Rembayung (UMAI), updated automatically in the cloud via GitHub Actions —
no PC left running, no database.

## What's in here

- `index.html` — the website. Fetches `availability.json` and lists every
  date that currently has open dine-in slots (takeaway is ignored).
- `fetch-availability.ps1` — PowerShell script that queries the UMAI API
  (same API the booking widget uses) and writes `availability.json`.
- `.github/workflows/update.yml` — GitHub Action that runs the script every
  15 minutes and commits the fresh `availability.json`.

## Setup (one time)

1. Make a free GitHub account if you don't have one.
2. Create a new **public** repository (e.g. `rembayung-availability`).
3. Upload these files into it (drag & drop in the GitHub web UI, or use
   GitHub Desktop / `git`):
   - `index.html`
   - `fetch-availability.ps1`
   - `.github/workflows/update.yml`  (keep the folder structure)
4. Enable GitHub Pages:
   - Repo **Settings → Pages → Build and deployment → Source: "Deploy from a
     branch"**, then choose **main** / **/ (root)** and Save.
5. Go to the **Actions** tab and you should see the workflow start (or click
   "Run workflow"). Within a minute or two it creates `availability.json`.
6. Open your site:
   ```
   https://<your-username>.github.io/<repo-name>/
   ```

The page refreshes itself every minute; the data behind it is recomputed by
GitHub every 15 minutes. When dine-in slots open, they appear as green cards
with the available times and a "Book on UMAI" link.

## Customising

- **Party size / how many days to scan:** edit the arguments in
  `.github/workflows/update.yml`:
  ```yaml
  run: .\fetch-availability.ps1 -Days 60 -PartySize 3 -OutFile availability.json
  ```
  (you can also just edit the defaults at the top of `fetch-availability.ps1`).

## Notes

- No API key or secret is needed — the widget API key is public (it's embedded
  in the booking page) and is auto-discovered by the script.
- The UMAI API asks for an ALTCHA proof-of-work challenge; the script solves
  it automatically.
- `fetch-availability.ps1` also runs locally (PowerShell) if you want to test:
  ```powershell
  .\fetch-availability.ps1 -Days 30 -PartySize 3
  ```
  (to view the HTML locally you need a tiny static server, because browsers
  block `fetch()` on `file://`; the GitHub Pages URL avoids this).

## Want phone notifications too?

Keep the original `rembayung-monitor.ps1` running on your PC (it can send
Telegram / WhatsApp the moment slots open) — the website is just the
always-up view you can check from anywhere.
