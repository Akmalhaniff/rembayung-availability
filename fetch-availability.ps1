param(
    [int]    $Days = 14,
    [int]    $PartySize = 3,
    [string] $OutFile = "availability.json",
    [string] $TelegramToken = "",
    [string] $TelegramChatId = "",
    [string] $ApiKeyFallback = "0e07c684-30c4-4212-9496-aee0e42231b4",
    [string] $LiveKeyUrl = "https://letsumai.com/e/tQ2dyw",
    [string] $BookingPage = "https://reservation.umai.io/en/widget/rembayung"
)

# Fetches Rembayung (UMAI) dine-in availability for the next $Days days, writes
# availability.json, and (optionally) sends a Telegram alert when a date NEWLY
# opens. Telegram creds come from params or env (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID).

$ErrorActionPreference = 'Stop'
$BaseUrl = "https://letsumai.com/widget/api"
$Ua      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
# Malaysia Time (MYT, UTC+8)
$tz = try { [TimeZoneInfo]::FindSystemTimeZoneById('Asia/Kuala_Lumpur') } catch { [TimeZoneInfo]::FindSystemTimeZoneById('Malay Peninsula Standard Time') }
function Get-MytNow { return [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz) }

function Test-QueueAndWait {
    param([string]$Html)
    if (-not $Html) { return $false }
    if ($Html -match 'Masa menunggu anda dianggarkan selama\s*(\d+)\s*minit' -or $Html -match 'giliran maya' -or $Html -match 'Anda kini dalam talian') {
        $mins = 4
        if ($Matches[1]) { try { $mins = [int]$Matches[1] } catch {} }
        if ($mins -lt 1) { $mins = 1 }
        if ($mins -gt 15) { $mins = 15 }
        $waitSec = $mins * 60 + 15
        Write-Host "[queue] Waiting page detected (est. $mins min) - sleeping $waitSec sec..." -ForegroundColor Yellow
        Start-Sleep -Seconds $waitSec
        return $true
    }
    return $false
}

# Fall back to environment variables if params not supplied (used by GitHub Actions secrets).
if (-not $TelegramToken)  { $TelegramToken  = $env:TELEGRAM_BOT_TOKEN }
if (-not $TelegramChatId) { $TelegramChatId = $env:TELEGRAM_CHAT_ID }

$script:ApiKey       = $null
$script:AltchaToken  = $null
$script:AltchaExpire = 0

function Get-ApiKey {
    if ($script:ApiKey) { return $script:ApiKey }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $src = (Invoke-WebRequest -Uri $LiveKeyUrl -UseBasicParsing -TimeoutSec 20 -UserAgent $Ua).Content
            if (Test-QueueAndWait $src) { continue }
            $m = [regex]::Match($src, 'widgetApiKey[\s\S]{0,2000}?([A-Za-z0-9-]{20,})')
            if ($m.Success -and $m.Groups[1].Value.Length -ge 20) {
                $script:ApiKey = $m.Groups[1].Value
                Write-Host "[key] live key: $($script:ApiKey.Substring(0,12))..."
                return $script:ApiKey
            }
            Write-Host "[key] key not found in page, attempt $($attempt+1)"
        } catch { Write-Host "[key] live fetch failed: $_" }
        if ($attempt -lt 4) { Start-Sleep -Seconds 5 }
    }
    $script:ApiKey = $ApiKeyFallback
    Write-Host "[key] using fallback key"
    return $script:ApiKey
}

function Get-AltchaToken {
    if ($script:AltchaToken -and [datetime]::UtcNow.Ticks -lt $script:AltchaExpire) {
        return $script:AltchaToken
    }
    $key = Get-ApiKey
    $ch  = Http-Json -Method GET -Path "v2/altcha/challenge" -Key $key
    $salt = $ch.salt; $target = $ch.challenge; $sig = $ch.signature
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $enc = [System.Text.Encoding]::UTF8
    $found = $null
    for ($n = 0; $n -lt 6000000; $n++) {
        $h = [BitConverter]::ToString($sha.ComputeHash($enc.GetBytes("$salt$n"))).Replace('-', '')
        if ($h -eq $target) { $found = $n; break }
    }
    if ($null -eq $found) { throw "ALTCHA unsolved" }
    $sol = @{ algorithm='SHA-256'; salt=$salt; number=$found; challenge=$target; signature=$sig } | ConvertTo-Json -Compress
    $solB64 = [Convert]::ToBase64String($enc.GetBytes($sol))
    $vk = Http-Json -Method POST -Path "v2/altcha/verify" -Key $key -BodyBytes $enc.GetBytes((@{ solution=$solB64 } | ConvertTo-Json -Compress))
    $script:AltchaToken = $vk.token
    $script:AltchaExpire = [datetime]::UtcNow.AddSeconds(900).Ticks
    Write-Host "[altcha] solved at $found, token ok"
    return $script:AltchaToken
}

function Http-Json {
    param($Method, $Path, $Key, $BodyBytes, $Token)
    for ($qAttempt = 0; $qAttempt -lt 5; $qAttempt++) {
        $req = [System.Net.HttpWebRequest]::Create("$BaseUrl/$Path")
        $req.Method = $Method; $req.UserAgent = $Ua; $req.Accept = 'application/json'
        $req.Referer = $BookingPage
        $req.Headers.Add('Origin', 'https://reservation.umai.io')
        $req.Headers.Add('VENUE-API-KEY', $Key)
        if ($Token) { $req.Headers.Add('X-Altcha-Token', $Token) }
        $req.Timeout = 20000
        if ($BodyBytes) {
            $req.ContentType = 'application/json'
            $rs = $req.GetRequestStream(); $rs.Write($BodyBytes, 0, $BodyBytes.Length); $rs.Close()
        }
        try { $res = $req.GetResponse() }
        catch [System.Net.WebException] { $res = $_.Exception.Response }
        if (-not $res) { throw "No response on $Path" }
        $sr = New-Object System.IO.StreamReader($res.GetResponseStream())
        $txt = $sr.ReadToEnd()
        # UMAI waiting page returns HTML with queue message instead of JSON
        if ($txt -match 'Masa menunggu|giliran maya|Anda kini dalam talian') {
            if (Test-QueueAndWait $txt) { continue }
        }
        if ($res.StatusCode -ne 200 -and $res.StatusCode -ne 201) {
            throw "HTTP $($res.StatusCode) on $Path : $txt"
        }
        try {
            return ($txt | ConvertFrom-Json)
        } catch {
            if ($txt -match 'Masa menunggu|giliran maya') {
                if (Test-QueueAndWait $txt) { continue }
            }
            throw "Invalid JSON on $Path : $txt"
        }
    }
    throw "Queue wait exceeded retries on $Path"
}

function Get-Slots($Key, $Date, $Token) {
    $path = "v2/slots?party_size=$PartySize&date=$Date"
    $tok = $Token
    if (-not $tok) {
        if ($script:AltchaToken -and [datetime]::UtcNow.Ticks -lt $script:AltchaExpire) {
            $tok = $script:AltchaToken
        }
    }
    try {
        return (Http-Json -Method GET -Path $path -Key $Key -Token $tok)
    } catch {
        if ($_.Exception.Message -match '40\d') {
            Write-Host "[slots] verification required, solving ALTCHA..."
            $tok = Get-AltchaToken
            return (Http-Json -Method GET -Path $path -Key $Key -Token $tok)
        }
        throw
    }
}

function Find-Categories($SlotsJson) {
    $dineIn = @(); $takeaway = @()
    if (-not $SlotsJson) { return @{ dineIn = $dineIn; takeaway = $takeaway } }
    foreach ($grp in $SlotsJson) {
        if ($grp -isnot [PSCustomObject]) { continue }
        $ra = $grp.reservation_availability
        $nm = if ($ra) { $ra.name } else { '' }
        $sl = $grp.slots
        # The REAL availability signal is whether the API returned actual slot inventory.
        # An empty `slots` object means that session has no released/bookable slots yet
        # (even if its config looks "active"), so it must NOT be counted as open.
        if (-not $sl -or $sl.PSObject.Properties.Name.Count -eq 0) { continue }
        # Collect the exact open start times from the inventory.
        $isTake = $nm -match 'takeaway|take away|bungkus|pickup'
        $openTimes = @()
        foreach ($k in $sl.PSObject.Properties.Name) {
            foreach ($e in $sl.$k) {
                $open = $e.spots_open
                if (($null -eq $open) -or ($open -gt 0)) {
                    $t = if ($e.start_time) { ($e.start_time -split ' ')[1] } else { $k }
                    if ($t -match ':') { $t = $t.Substring(0,5) }
                    $openTimes += $t
                }
            }
        }
        if ($openTimes.Count -eq 0) { continue }
        foreach ($t in ($openTimes | Sort-Object -Unique)) {
            if ($isTake) { $takeaway += $t } else { $dineIn += $t }
        }
    }
    return @{ dineIn = $dineIn; takeaway = $takeaway }
}

function Send-Telegram($Token, $ChatId, $Msg) {
    if (-not $Token -or -not $ChatId) { return }
    try {
        $text = [System.Uri]::EscapeDataString($Msg)
        $u = "https://api.telegram.org/bot$Token/sendMessage?chat_id=$ChatId&text=$text"
        Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 20 | Out-Null
        Write-Host "[telegram] sent"
    } catch { Write-Host "[telegram] failed: $_" }
}

# ---------------- MAIN ----------------
$key   = Get-ApiKey
$token = Get-AltchaToken   # solve once up front so the first slots call carries it
$start = Get-MytNow
$results = @()

Write-Host "Scanning next $Days days (party of $PartySize) for dine-in and takeaway..."
for ($i = 0; $i -lt $Days; $i++) {
    $d = $start.AddDays($i)
    $dateStr = $d.ToString('yyyy-MM-dd')
    $queueRetries = 0
    while ($true) {
        try {
            $slots = Get-Slots -Key $key -Date $dateStr -Token $token
            $cat = Find-Categories $slots
            $times = $cat.dineIn
            $takeTimes = $cat.takeaway
            break
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match 'Masa menunggu|giliran maya|Queue wait exceeded' -and $queueRetries -lt 3) {
                $queueRetries++
                Write-Host "  $dateStr : queue detected, retry $queueRetries..."
                continue
            }
            Write-Host "  $dateStr : error ($_)"
            $times = @(); $takeTimes = @()
            $results += [PSCustomObject]@{ date=$dateStr; day=$d.ToString('ddd'); available=$false; times=@(); name=''; takeaway=$false; takeawayTimes=@(); takeawayName=''; note='error' }
            $times = $null # signal already handled
            break
        }
    }
    if ($null -eq $times) { continue }
    $available = $times.Count -gt 0
    $takeawayAvail = $takeTimes.Count -gt 0
    $results += [PSCustomObject]@{
        date          = $dateStr
        day           = $d.ToString('ddd')
        available     = $available
        times         = @($times)
        name          = ''
        takeaway      = $takeawayAvail
        takeawayTimes = @($takeTimes)
        takeawayName  = ''
        note          = if (-not $available) { 'no dine-in yet' } else { '' }
    }
    $di = if ($available) { "$($times.Count) dine-in: $($times -join ', ')" } else { 'no dine-in' }
    $ta = if ($takeawayAvail) { "$($takeTimes.Count) takeaway: $($takeTimes -join ', ')" } else { 'no takeaway' }
    if ($available) { Write-Host "  $dateStr : $di | $ta" -ForegroundColor Green }
    else            { Write-Host "  $dateStr : $di | $ta" }
}

# Detect dates that just opened (compared to the previous availability.json).
$prevAvail = @{}
if (Test-Path $OutFile) {
    try {
        $prev = (Get-Content $OutFile -Raw | ConvertFrom-Json)
        foreach ($pd in $prev.dates) { $prevAvail[$pd.date] = $pd.available }
    } catch { Write-Host "[prev] could not read previous data: $_" }
}
$newlyOpen = $results | Where-Object { $_.available -and $prevAvail[$_.date] -ne $true }
if ($newlyOpen.Count -gt 0) {
    Write-Host "*** $($newlyOpen.Count) newly-open date(s) -> sending Telegram ***"
    foreach ($d in $newlyOpen) {
        $bookUrl = "$BookingPage`?party_size=$PartySize&date=$($d.date)"
        $msg = "Rembayung DINE-IN OPEN`nDate: $($d.date) ($($d.day))`nTimes: $(($d.times -join ', '))`nBook: $bookUrl"
        Write-Host $msg
        Send-Telegram $TelegramToken $TelegramChatId $msg
    }
} else {
    Write-Host "No newly-opened dates since last check."
}

# Booking horizon: furthest date that currently has any released slot inventory.
$furthest = $null
foreach ($r in $results) {
    if (($r.available -or $r.takeaway) -and ($null -eq $furthest -or $r.date -gt $furthest)) { $furthest = $r.date }
}
$windowDays = $null
if ($furthest) {
    $fbDate = [datetime]::Parse($furthest)
    $windowDays = ($fbDate - (Get-MytNow).Date).Days
    Write-Host "Booking horizon: up to $furthest (window ~$windowDays days)"
}

# Record the EXACT time each date first opened for booking (dine-in / takeaway),
# persisted across runs so we learn the real release schedule.
$openedDir = [System.IO.Path]::GetDirectoryName($OutFile)
if (-not $openedDir) { $openedDir = '.' }
$openedFile = Join-Path $openedDir 'opened.json'
$opened = @{ dineIn = @{}; takeaway = @{} }
if (Test-Path $openedFile) {
    try {
        $o = (Get-Content $openedFile -Raw | ConvertFrom-Json)
        if ($o.dineIn)   { foreach ($k in $o.dineIn.PSObject.Properties.Name)   { $opened.dineIn[$k]   = $o.dineIn.$k } }
        if ($o.takeaway) { foreach ($k in $o.takeaway.PSObject.Properties.Name) { $opened.takeaway[$k] = $o.takeaway.$k } }
    } catch { Write-Host "[opened] could not read: $_" }
}
$nowIso = (Get-MytNow).ToString('yyyy-MM-dd HH:mm:ss')
foreach ($r in $results) {
    if ($r.available -and -not $opened.dineIn[$r.date])   { $opened.dineIn[$r.date]   = $nowIso }
    if ($r.takeaway -and -not $opened.takeaway[$r.date]) { $opened.takeaway[$r.date] = $nowIso }
    if ($r.available)   { $r | Add-Member -NotePropertyName dineInOpenedAt   -NotePropertyValue $opened.dineIn[$r.date]   -Force } else { $r | Add-Member -NotePropertyName dineInOpenedAt   -NotePropertyValue $null -Force }
    if ($r.takeaway) { $r | Add-Member -NotePropertyName takeawayOpenedAt -NotePropertyValue $opened.takeaway[$r.date] -Force } else { $r | Add-Member -NotePropertyName takeawayOpenedAt -NotePropertyValue $null -Force }
}
$opened | ConvertTo-Json -Depth 3 | Set-Content -Path $openedFile -Encoding UTF8

$out = [PSCustomObject]@{
    lastUpdated        = (Get-MytNow).ToString('yyyy-MM-dd HH:mm:ss') + ' MYT'
    partySize          = $PartySize
    note               = 'Dine-in and takeaway are shown separately.'
    bookingPage        = $BookingPage
    furthestBookable   = $furthest
    bookingWindowDays  = $windowDays
    dates              = $results
}
$out | ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "Wrote $OutFile ($($results.Count) dates)."
