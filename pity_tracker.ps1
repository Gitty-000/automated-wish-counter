$githubOwner = "Gitty-000"        
$githubRepo  = "automated-wish-counter"            
$githubTokenEncoded = "Z2hwX21tbnFtY1dZelpNOVJDUmx1eTR2R09VSlBaS3NUWjBIbk1hTw==" 

function Decode-Token {
    param([string]$enc)
    if ([string]::IsNullOrWhiteSpace($enc) -or $enc -like "*PASTE_BASE64_TOKEN_HERE*") {
        Write-Host "GitHub token not set. Please edit the script and provide a base64 encoded token." -ForegroundColor Red
        return $null
    }
    try {
        return [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($enc))
    } catch {
        Write-Host "Failed to decode GitHub token." -ForegroundColor Red
        return $null
    }
}

function Find-GachaUrl {
    # Locate Genshin Impact log files and extract the wish history url.
    $localLow = [Environment]::GetFolderPath('LocalApplicationData').Replace('Local','LocalLow')
    $mhyDir = Join-Path $localLow 'miHoYo'
    if (-not (Test-Path $mhyDir)) {
        Write-Host 'Genshin Impact does not seem to be installed.' -ForegroundColor Yellow
        return $null
    }
    $logFiles = Get-ChildItem -Path $mhyDir -Filter 'output_log*.txt' -Recurse -ErrorAction SilentlyContinue
    foreach ($file in $logFiles) {
        $match = Select-String -Path $file.FullName -Pattern 'https.*getGachaLog' -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) { return $match.Line.Trim() }
    }
    Write-Host 'Wish history link not found. Open the Wish History once in-game and rerun.' -ForegroundColor Yellow
    return $null
}

function Fetch-GachaHistory {
    param([string]$baseUrl, [string]$gachaType)
    $page = 1
    $endId = 0
    $all = @()
    while ($true) {
        $url = "$baseUrl&gacha_type=$gachaType&page=$page&size=20&end_id=$endId"
        try {
            $res = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 10
            if ($res.data.list.Count -eq 0) { break }
            $all += $res.data.list
            $endId = $res.data.list[-1].id
            $page++
        } catch {
            break
        }
    }
    return $all
}

function Compute-Stats {
    param([array]$records, [string[]]$standardPool)
    $fiveStars = $records | Where-Object { $_.rank_type -eq '5' }
    $pullsSince5 = 0
    if ($records.Count -gt 0) {
        $last5Index = $records.FindIndex({ $_.rank_type -eq '5' })
        if ($last5Index -ge 0) { $pullsSince5 = $last5Index } else { $pullsSince5 = $records.Count }
    }
    $last5 = $fiveStars | Select-Object -First 1
    $guaranteed = $false
    if ($last5) {
        $guaranteed = $standardPool -contains $last5.name
    }
    return [PSCustomObject]@{
        pullsSinceLast5 = $pullsSince5
        fiveStarCount   = $fiveStars.Count
        lastFiveStar    = $last5.name
        guaranteed      = $guaranteed
        guaranteedIn    = 90 - $pullsSince5
    }
}

function Upload-Result {
    param([string]$filePath, [string]$token)
    $content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content $filePath -Raw)))
    $uri = "https://api.github.com/repos/$($githubOwner)/$($githubRepo)/contents/$([System.IO.Path]::GetFileName($filePath))"
    $body = @{ message = "update tracking"; content = $content } | ConvertTo-Json
    $headers = @{ Authorization = "token $token" }
    try {
        $res = Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -Body $body
    } catch {
        Write-Host "Failed to upload result to GitHub." -ForegroundColor Red
    }
}

# --- main script ---
$uid = Read-Host 'Enter your UID'
$token = Decode-Token $githubTokenEncoded
if (-not $token) { exit }
$baseUrl = Find-GachaUrl
if (-not $baseUrl) { exit }

$charTypes = @('301','302')
$weaponTypes = @('400')
$charRecords = @()
foreach ($t in $charTypes) { $charRecords += Fetch-GachaHistory $baseUrl $t }
$weaponRecords = @()
foreach ($t in $weaponTypes) { $weaponRecords += Fetch-GachaHistory $baseUrl $t }

$standardChars = @('Diluc','Mona','Qiqi','Keqing','Jean','Tighnari','Dehya')
$charStats = Compute-Stats ($charRecords | Sort-Object id -Descending) $standardChars
$weaponStats = Compute-Stats ($weaponRecords | Sort-Object id -Descending) @()

$result = @{ UID=$uid; character=$charStats; weapon=$weaponStats } | ConvertTo-Json -Depth 4
$outFile = "result_$uid.json"
$result | Out-File $outFile -Encoding utf8

Upload-Result $outFile $token
$ghUrl = "https://$githubOwner.github.io/$githubRepo/track.html?uid=$uid"
Write-Host "Result uploaded. View at: $ghUrl"
