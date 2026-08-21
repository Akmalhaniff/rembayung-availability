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

# Fall back to environment variables if params not supplied (used by GitHub Actions secrets).
if (-not $TelegramToken)  { $TelegramToken  = $env:TELEGRAM_BOT_TOKEN }
if (-not $TelegramChatId) { $TelegramChatId = $env:TELEGRAM_CHAT_ID }

$script:ApiKey       = $null
$script:AltchaToken  = $null
$script:AltchaExpire = 0

function Get-ApiKey {
    if ($script:ApiKey) { return $script:ApiKey }
    try {
        $src = (Invoke-WebRequest -Uri $LiveKeyUrl -UseBasicParsing -TimeoutSec 20 -UserAgent $Ua).Content
        $m = [regex]::Match($src, 'widgetApiKey[\s\S]{0,2000}?([A-Za-z0-9-]{20,})')
        if ($m.Success -and $m.Groups[1].Value.Length -ge 20) {
            $script:ApiKey = $m.Groups[1].Value
            Write-Host "[key] live key: $($script:ApiKey.Substring(0,12))..."
            return $script:ApiKey
        }
    } catch { Write-Host "[key] live fetch failed: $_" }
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
    $sr = New-Object System.IO.StreamReader($res.GetResponseStream())
    $txt = $sr.ReadToEnd()
    if ($res.StatusCode -ne 200 -and $res.StatusCode -ne 201) {
        throw "HTTP $($res.StatusCode) on $Path : $txt"
    }
    return ($txt | ConvertFrom-Json)
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
        $isTake = $nm -match 'takeaway|take away|bungkus|pickup'
        $target = if ($isTake) { $takeaway } else { $dineIn }
        $sl = $grp.slots
        if ($sl) {
            foreach ($k in $sl.PSObject.Properties.Name) {
                foreach ($e in $sl.$k) {
                    $open = $e.spots_open
                    if (($null -eq $open) -or ($open -gt 0)) {
                        $t = ($e.start_time -split ' ')[1]
                        $target += [PSCustomObject]@{ Time = $t; Name = $nm; Open = $open }
                    }
                }
            }
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
$start = Get-Date
$results = @()

Write-Host "Scanning next $Days days (party of $PartySize) for dine-in and takeaway..."
for ($i = 0; $i -lt $Days; $i++) {
    $d = $start.AddDays($i)
    $dateStr = $d.ToString('yyyy-MM-dd')
    try {
        $slots = Get-Slots -Key $key -Date $dateStr -Token $token
        $cat = Find-Categories $slots
        $times = $cat.dineIn
        $takeTimes = $cat.takeaway
    } catch {
        Write-Host "  $dateStr : error ($_)"
        $results += [PSCustomObject]@{ date=$dateStr; day=$d.ToString('ddd'); available=$false; times=@(); name=''; takeaway=$false; takeawayTimes=@(); takeawayName=''; note='error' }
        continue
    }
    $available = $times.Count -gt 0
    $takeawayAvail = $takeTimes.Count -gt 0
    $results += [PSCustomObject]@{
        date          = $dateStr
        day           = $d.ToString('ddd')
        available     = $available
        times         = @($times | ForEach-Object { $_.Time })
        name          = if ($available) { $times[0].Name } else { '' }
        takeaway      = $takeawayAvail
        takeawayTimes = @($takeTimes | ForEach-Object { $_.Time })
        takeawayName  = if ($takeawayAvail) { $takeTimes[0].Name } else { '' }
        note          = if (-not $available) { 'no dine-in yet' } else { '' }
    }
    $di = if ($available) { "$($times.Count) dine-in: $($times.Time -join ', ')" } else { 'no dine-in' }
    $ta = if ($takeawayAvail) { "$($takeTimes.Count) takeaway: $($takeTimes.Time -join ', ')" } else { 'no takeaway' }
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

$out = [PSCustomObject]@{
    lastUpdated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    partySize   = $PartySize
    note        = 'Dine-in and takeaway are shown separately.'
    bookingPage = $BookingPage
    dates       = $results
}
$out | ConvertTo-Json -Depth 4 | Set-Content -Path $OutFile -Encoding UTF8
Write-Host "Wrote $OutFile ($($results.Count) dates)."
