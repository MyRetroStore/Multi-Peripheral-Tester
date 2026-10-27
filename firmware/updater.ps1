<#
    Firmware updater for the Multi Peripheral Tester (ATmega1280).

    Windows users: right-click this file and choose "Run with PowerShell", or from a
    prompt in this folder:

        powershell -ExecutionPolicy Bypass -File .\updater.ps1

    It reads the firmware version from the board, compares it with the latest GitHub
    release, downloads and SHA-256 verifies the image, then flashes it with avrdude.
    It never downgrades a board.

    Options: -Port COM3 -Baud 57600 -Programmer arduino -Timeout 5 -Yes -Force
             -DryRun -Version -Help
#>
[CmdletBinding()]
param(
    [string]$Port = "",
    [int]$Baud = 115200,
    [int]$BootBaud = 0,
    [string]$Programmer = "",
    [int]$Timeout = 5,
    [switch]$Yes,
    [switch]$Force,
    [switch]$DryRun,
    [string]$Hex = "",
    [switch]$NoDownload,
    [switch]$Version,
    [switch]$Help
)

$ScriptVersion = "1.1"

$LocalHex = $Hex
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Label = "ATmega1280"
$Repo = "MyRetroStore/Multi-Peripheral-Tester"
$Api = "https://api.github.com/repos/$Repo/releases/latest"
$RawVersion = "https://raw.githubusercontent.com/$Repo/main/version"
$Site = "https://myretrostore.co.uk"

if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Host ""
    Write-Host "This PC is running Windows PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Yellow
    Write-Host "The updater needs version 3.0 or newer because GitHub now requires TLS 1.2,"
    Write-Host "which PowerShell 2.0 cannot do."
    Write-Host ""
    Write-Host "  Option 1 - update this PC: install Windows Management Framework 5.1"
    Write-Host "             https://www.microsoft.com/download/details.aspx?id=54616"
    Write-Host "             reboot, then run this again."
    Write-Host ""
    Write-Host "  Option 2 - flash by hand: download the .hex from"
    Write-Host "             https://github.com/$Repo/releases/latest"
    Write-Host "             then run, with avrdude installed and the board on COM3:"
    Write-Host "             avrdude -c arduino -p m1280 -P COM3 -b 57600 -D -U flash:w:firmware.hex:i"
    Write-Host ""
    exit 1
}

function Get-WebText([string]$Url) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "MultiPeripheralTester-Updater")
        $wc.Headers.Add("Accept", "application/vnd.github.v3+json")
        return $wc.DownloadString($Url)
    } catch {
        return $null
    }
}

function Expand-Zip([string]$ZipFile, [string]$Dest) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipFile, $Dest, $true)
        return $true
    } catch { }
    try {
        if (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {
            Expand-Archive -LiteralPath $ZipFile -DestinationPath $Dest -Force -ErrorAction Stop
            return $true
        }
    } catch { }
    try {
        $shell = New-Object -ComObject Shell.Application
        $shell.Namespace($Dest).CopyHere($shell.Namespace($ZipFile).Items(), 16)
        Start-Sleep -Seconds 2
        return $true
    } catch { }
    return $false
}

function Get-FileSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try { $hash = $sha.ComputeHash($stream) } finally { $stream.Close() }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLower()
}
function Write-Ok($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Info($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn2($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Die($m) { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

function Show-Usage {
    @"
Usage: updater.ps1 [OPTIONS]

Reads the installed firmware version, compares it with the latest release on GitHub,
verifies the download and flashes it.  Board: $Label, FTDI FT231X (USB 0403:6015).

  -Port <COMn>         serial port, auto-detected when omitted
  -Baud <baud>         console baud for reading the version (default $Baud)
  -BootBaud <baud>     bootloader baud (default 57600)
  -Programmer <id>     avrdude programmer id (default arduino)
  -Timeout <sec>       version read timeout (default $Timeout)
  -Yes                 flash without confirmation
  -Force               flash even when already up to date, or to downgrade
  -DryRun              download and verify, then stop before flashing
  -Hex <path>          flash this .hex instead of downloading (needs no internet)
  -NoDownload          never fetch software from the internet
  -Version             script version
  -Help                this text

Website: $Site
Releases: https://github.com/$Repo
"@
}

if ($Help) { Show-Usage; exit 0 }
if ($Version) { Write-Host "updater.ps1 version $ScriptVersion"; exit 0 }

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

function Find-Avrdude {
    $bundled = Join-Path $ScriptRoot "avrdude\avrdude.exe"
    if (Test-Path $bundled) { return $bundled }
    $bundled = Join-Path $ScriptRoot "avrdude.exe"
    if (Test-Path $bundled) { return $bundled }
    $bundled = Join-Path (Get-Location) "avrdude.exe"
    if (Test-Path $bundled) { return $bundled }
    $cmd = Get-Command avrdude.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:USERPROFILE ".platformio\packages\tool-avrdude\avrdude.exe"),
        (Join-Path $env:LOCALAPPDATA "Arduino15\packages\arduino\tools\avrdude"),
        "C:\Program Files (x86)\Arduino\hardware\tools\avr\bin\avrdude.exe",
        "C:\Program Files\Arduino\hardware\tools\avr\bin\avrdude.exe",
        (Join-Path $env:USERPROFILE ".platformio\packages\tool-avrdude")
    )
    foreach ($c in $candidates) {
        $hit = Get-ChildItem -Path $c -Filter avrdude.exe -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Install-Avrdude {
    $avrArch = "windows_mingw-x64"
    if (-not [Environment]::Is64BitOperatingSystem) { $avrArch = "windows-x86" }
    $avrTag = "v8.3"
    $url = "https://api.github.com/repos/avrdudes/avrdude/releases/tags/$avrTag"
    Write-Info "avrdude was not found - downloading $avrTag ($avrArch) into .\avrdude"

    $info = $null
    try {
        $info = Invoke-RestMethod -Uri $url -Headers @{ Accept = "application/vnd.github.v3+json" } `
            -UseBasicParsing -TimeoutSec 20
    } catch {
        $text = Get-WebText $url
        if ($text) { try { $info = $text | ConvertFrom-Json } catch { } }
    }
    if (-not $info) { Write-Warn2 "Could not reach the avrdude release page"; return $null }

    $asset = $info.assets | Where-Object { $_.name -like "*$avrArch*" } | Select-Object -First 1
    if (-not $asset) { Write-Warn2 "No $avrArch build in avrdude $avrTag"; return $null }

    $zip = Join-Path ([System.IO.Path]::GetTempPath()) $asset.name
    Write-Info "Downloading $($asset.name) ($([int]($asset.size / 1MB)) MB)"
    try {
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -TimeoutSec 300
    } catch {
        Write-Warn2 "Download failed: $($_.Exception.Message)"
        return $null
    }

    if (([string]$asset.digest) -match '^sha256:([0-9a-fA-F]{64})$') {
        $want = $Matches[1].ToLower()
        if ((Get-FileSha256 $zip) -ne $want) {
            Remove-Item $zip -Force -ErrorAction SilentlyContinue
            Write-Warn2 "The downloaded avrdude did not match its published SHA-256 - discarded"
            return $null
        }
        Write-Ok "SHA-256 matches"
    }

    $dest = Join-Path (Get-Location) "avrdude"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    if (-not (Expand-Zip $zip $dest)) {
        Write-Warn2 "Could not unpack $($asset.name)"
        return $null
    }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue

    $exe = Get-ChildItem -Path $dest -Filter avrdude.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($exe) { Write-Ok "avrdude installed in $dest"; return $exe.FullName }
    Write-Warn2 "Unpacked, but no avrdude.exe appeared"
    return $null
}

function Get-PortTable {
    $rows = @()
    $devices = @()
    try { $devices = Get-WmiObject Win32_PnPEntity -ErrorAction Stop } catch { }
    foreach ($name in [System.IO.Ports.SerialPort]::GetPortNames()) {
        $dev = $devices | Where-Object { $_.Name -like "*($name)*" } | Select-Object -First 1
        $rows += New-Object PSObject -Property @{
            Port = $name
            Name = $(if ($dev) { [string]$dev.Name } else { "" })
            Id   = $(if ($dev) { [string]$dev.DeviceID } else { "" })
        }
    }
    return $rows
}

function Read-BoardVersion([string]$ComPort) {
    $sp = New-Object System.IO.Ports.SerialPort($ComPort, $Baud, 'None', 8, 'One')
    $sp.DtrEnable = $true
    $sp.RtsEnable = $false
    try { $sp.Open() } catch { return $null }
    Start-Sleep -Milliseconds 1600
    try { $sp.WriteLine("version") } catch { }
    $deadline = (Get-Date).AddSeconds($Timeout)
    $buffer = ""
    $found = $null
    while ((Get-Date) -lt $deadline) {
        try { $buffer += $sp.ReadExisting() } catch { break }
        $m = [regex]::Match($buffer, 'FIRMWARE:\s*Version\s+([0-9]+(?:\.[0-9]+)*)', 'IgnoreCase')
        if (-not $m.Success) {
            $m = [regex]::Match($buffer, 'Version:\s*([0-9]+(?:\.[0-9]+)*)', 'IgnoreCase')
        }
        if ($m.Success) { $found = $m.Groups[1].Value; break }
        Start-Sleep -Milliseconds 100
    }
    try { $sp.Close() } catch { }
    return $found
}

function Compare-SemVer([string]$Left, [string]$Right) {
    $a = ($Left -replace '[^0-9.]', '') -split '\.'
    $b = ($Right -replace '[^0-9.]', '') -split '\.'
    for ($i = 0; $i -lt 4; $i++) {
        $x = 0
        $y = 0
        if ($i -lt $a.Count -and $a[$i] -ne "") { [void][int]::TryParse($a[$i], [ref]$x) }
        if ($i -lt $b.Count -and $b[$i] -ne "") { [void][int]::TryParse($b[$i], [ref]$y) }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

Write-Host "====================================================" -ForegroundColor White
Write-Host "      Firmware updater for Multi-Peripheral Tester" -ForegroundColor White
Write-Host "                  Script version $ScriptVersion" -ForegroundColor White
Write-Host "  $Site"
Write-Host "  https://github.com/$Repo"
Write-Host "====================================================" -ForegroundColor White
Write-Host ""

$Avrdude = Find-Avrdude
if (-not $Avrdude -and -not $NoDownload) { $Avrdude = Install-Avrdude }
if (-not $Avrdude) {
    Write-Host "[ERROR] avrdude.exe was not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "Put avrdude.exe (and its avrdude.conf) in the same folder as this script,"
    Write-Host "or download it from https://github.com/avrdudes/avrdude/releases into .\avrdude\."
    Write-Host "(The automatic download needs internet; -NoDownload disables it.)"
    exit 1
}
Write-Ok "avrdude: $Avrdude"

$Tag = ""
$Remote = ""
$HexName = ""
$HexUrl = ""
$HexDigest = ""
$SumsName = ""
$SumsUrl = ""

$release = $null
if ($LocalHex) {
    if (-not (Test-Path $LocalHex)) { Die "Local hex not found: $LocalHex" }
    $Tag = "local file"
    $Remote = "local"
    Write-Ok "Flashing a local file: $LocalHex (GitHub not used)"
} else {
    Write-Info "Checking the latest release"
    $apiError = ""
    try {
        $release = Invoke-RestMethod -Uri $Api -Headers @{ Accept = "application/vnd.github.v3+json" } `
            -UseBasicParsing -TimeoutSec 15
    } catch {
        $apiError = $_.Exception.Message
        $text = Get-WebText $Api
        if ($text) {
            try { $release = $text | ConvertFrom-Json } catch { $apiError += " / parse: $($_.Exception.Message)" }
        }
    }

    if (-not $release) {
        Write-Warn2 "GitHub release API failed: $apiError"
        $text = Get-WebText $RawVersion
        if ($text) { $Tag = "v" + $text.Trim() }
        else {
            Write-Host ""
            Write-Host "Could not determine the latest version from GitHub." -ForegroundColor Red
            Write-Host "PowerShell $($PSVersionTable.PSVersion), .NET $($PSVersionTable.CLRVersion), TLS: $([Net.ServicePointManager]::SecurityProtocol)"
            Write-Host ""
            Write-Host "If this PC is behind a proxy, or GitHub is blocked here, flash a local file instead:"
            Write-Host "  1. download firmware.hex from https://github.com/$Repo/releases/latest"
            Write-Host "  2. run:  .\update.cmd -Hex .\firmware.hex"
            exit 1
        }
    }

    if ($release) {
        $Tag = [string]$release.tag_name
        $hexAsset = $release.assets | Where-Object { $_.name -match '\.hex$' } | Select-Object -First 1
        $sumsAsset = $release.assets | Where-Object { $_.name -match '(sha256|sha256sums?|checksums?)(\.txt)?$' } |
            Select-Object -First 1
        if ($hexAsset) {
            $HexName = [string]$hexAsset.name
            $HexUrl = [string]$hexAsset.browser_download_url
            $HexDigest = ([string]$hexAsset.digest).Trim()
        }
        if ($sumsAsset) {
            $SumsName = [string]$sumsAsset.name
            $SumsUrl = [string]$sumsAsset.browser_download_url
        }
    }

    if (-not $Tag) { Die "Could not parse the release tag from GitHub." }
    $Remote = $Tag.TrimStart([char[]]'vV')
    if (-not $Remote) { Die "Could not parse the latest version from '$Tag'." }
    Write-Ok "Latest version: $Tag"
}
Write-Host ""

if (-not $Port) {
    $table = @(Get-PortTable)
    if ($table.Count -eq 0) {
        Write-Host "[ERROR] This PC has no COM ports at all." -ForegroundColor Red
        Write-Host ""
        Write-Host "That is a driver problem, not a cable-selection problem. Check Device Manager:"
        Write-Host "under Ports you should see \"USB Serial Port (COMx)\" for the FT231X."
        Write-Host "If it shows with a warning triangle, install the FTDI VCP driver:"
        Write-Host "  https://ftdichip.com/drivers/vcp-drivers/"
        Write-Host "Then plug the tester in again and re-run this."
        exit 1
    }

    $board = $table | Where-Object {
        $_.Id -match 'VID_0403' -or $_.Name -match 'FTDI|FT231|USB Serial'
    } | Select-Object -First 1
    if (-not $board -and $table.Count -eq 1) { $board = $table[0] }

    if (-not $board) {
        Write-Host "[ERROR] Several COM ports exist and none looks like the tester:" -ForegroundColor Red
        foreach ($row in $table) { Write-Host ("  {0,-6} {1}" -f $row.Port, $row.Name) }
        Write-Host ""
        Write-Host "Pick the one the tester is plugged into, for example:"
        Write-Host "  .\update.cmd -Port COM3"
        exit 1
    }

    $Port = $board.Port
    Write-Ok "Port: $Port  $($board.Name)"
} else {
    if ($Port -notmatch '^COM\d+$' -and -not (Test-Path $Port)) {
        Die "Port $Port does not exist."
    }
    Write-Ok "Port: $Port"
}
Write-Ok "Board: $Label on $Port"
Write-Host ""

Write-Info "Reading the installed firmware version"
$Installed = Read-BoardVersion $Port
if (-not $Installed) {
    Die "Could not read the firmware version from $Label on $Port. Check the cable, close any other program using $Port (Arduino IDE, a serial monitor), and confirm the board is running the tester firmware."
}
Write-Ok "Installed version: $Installed"
Write-Host ""

if ($LocalHex) {
    Write-Warn2 "Board is on v$Installed; flashing the local file regardless"
} else {
    $cmp = Compare-SemVer $Remote $Installed
    if ($cmp -eq 0) {
        if (-not $Force) {
            Write-Host "Up to date: v$Installed" -ForegroundColor Green
            exit 0
        }
        Write-Warn2 "Up to date (v$Installed); flashing anyway because -Force was given"
    } elseif ($cmp -gt 0) {
        Write-Host "Update available: v$Installed -> v$Remote" -ForegroundColor Yellow
    } else {
        if (-not $Force) {
            Write-Host "Board is newer than the latest release: v$Installed vs v$Remote" -ForegroundColor Green
            Write-Host "Nothing to do - this updater never downgrades." -ForegroundColor Green
            exit 0
        }
        Write-Warn2 "Board v$Installed is NEWER than release v$Remote; -Force asks for a DOWNGRADE"
    }
}
Write-Host ""

if (-not $LocalHex -and -not $HexUrl) { Die "Release $Tag has no .hex asset to flash." }

$Proceed = $false
if ($Yes) {
    $Proceed = $true
} else {
    $answer = Read-Host "Download and flash v$Remote now? [y/N]"
    if ($answer -match '^[yY]') { $Proceed = $true }
}
if (-not $Proceed) {
    Write-Warn2 "Nothing flashed."
    exit 0
}

if ($LocalHex) {
    try {
        $Target = (Resolve-Path -Path $LocalHex -ErrorAction Stop).Path
    } catch {
        Die "Cannot use '$LocalHex' as the image to flash: $($_.Exception.Message)"
    }
    if (Test-Path "$Target.sha256") {
        $line = (Get-Content "$Target.sha256" -TotalCount 1)
        if ($line -match '^([0-9a-fA-F]{64})') { $HexDigest = "sha256:" + $Matches[1] }
    }
    Write-Info "Using local file $Target"
} else {
    $Target = Join-Path (Get-Location) ($(if ($HexName) { $HexName } else { "firmware.hex" }))
    Write-Info "Downloading $HexName"
    try {
        Invoke-WebRequest -Uri $HexUrl -OutFile $Target -UseBasicParsing -TimeoutSec 120
    } catch {
        Die "Download failed: $($_.Exception.Message)"
    }
    Write-Ok ("Downloaded {0} bytes" -f (Get-Item $Target).Length)
}

$Expected = ""
if ($HexDigest -match '^sha256:([0-9a-fA-F]{64})$') {
    $Expected = $Matches[1].ToLower()
    Write-Info "Verifying against the SHA-256 published for $(Split-Path $Target -Leaf)"
} elseif ($SumsUrl) {
    $sumsFile = Join-Path ([System.IO.Path]::GetTempPath()) "mpt-checksums.txt"
    Write-Info "Downloading $SumsName"
    try {
        Invoke-WebRequest -Uri $SumsUrl -OutFile $sumsFile -UseBasicParsing -TimeoutSec 30
    } catch {
        Die "Could not download $SumsName"
    }
    $leaf = (Split-Path $Target -Leaf)
    foreach ($line in Get-Content $sumsFile) {
        $m = [regex]::Match($line, '^([0-9a-fA-F]{64})\s+\*?(.+)$')
        if ($m.Success -and $m.Groups[2].Value.Trim() -eq $leaf) {
            $Expected = $m.Groups[1].Value.ToLower()
            break
        }
    }
    Remove-Item $sumsFile -ErrorAction SilentlyContinue
    if (-not $Expected) { Die "The checksum file does not list $leaf" }
} else {
    Write-Warn2 "Release $Tag publishes no SHA-256; the download cannot be verified"
}

if ($Expected) {
    $Actual = Get-FileSha256 $Target
    if ($Actual -ne $Expected) {
        Remove-Item $Target -ErrorAction SilentlyContinue
        Write-Host "[ERROR] SHA-256 MISMATCH" -ForegroundColor Red
        Write-Host "  published:  $Expected"
        Write-Host "  downloaded: $Actual"
        Write-Host "The image has been deleted and nothing was flashed."
        exit 1
    }
    Write-Ok "SHA-256 matches"
}

if ($DryRun) {
    Write-Ok "Dry run: stopping before flashing $Target"
    exit 0
}

$AvrdudeDir = Split-Path $Avrdude -Parent
$ConfigArg = @()
$conf = Join-Path $AvrdudeDir "..\etc\avrdude.conf"
if (Test-Path $conf) { $ConfigArg = @("-C", (Resolve-Path $conf).Path) }
else {
    $conf = Join-Path $AvrdudeDir "avrdude.conf"
    if (Test-Path $conf) { $ConfigArg = @("-C", (Resolve-Path $conf).Path) }
}

$attempts = @("arduino:57600", "arduino:115200", "wiring:57600")
$flashed = $false
foreach ($attempt in $attempts) {
    $prog = if ($Programmer) { $Programmer } else { $attempt.Split(':')[0] }
    $rate = if ($BootBaud -gt 0) { $BootBaud } else { [int]$attempt.Split(':')[1] }
    Write-Info "avrdude -c $prog -p m1280 -b $rate"
    $avrArgs = @("-c", $prog, "-p", "m1280", "-P", $Port, "-b", "$rate", "-D",
        "-U", ("flash:w:{0}:i" -f $Target)) + $ConfigArg
    & $Avrdude @avrArgs
    if ($LASTEXITCODE -eq 0) { $flashed = $true; break }
    Write-Warn2 "No response with -c $prog -b $rate, trying the next profile"
}

if (-not $flashed) {
    Write-Host "[ERROR] Flashing failed for every programmer/baud combination" -ForegroundColor Red
    Write-Host "Check the cable and the bootloader, then try different -Programmer and -BootBaud values."
    exit 1
}

Write-Ok "Flashed"
Start-Sleep -Seconds 5
$fresh = Read-BoardVersion $Port
if ($fresh) {
    Write-Ok "Board now reports v$fresh"
} else {
    Write-Warn2 "No version reported after flashing; check the board"
}
exit 0
