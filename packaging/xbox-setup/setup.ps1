# GT3 Revisited for Xbox: the one-stop setup (README.txt beside this script).
#
# Drag your GT3 disc image onto Setup.bat, or run:
#   pwsh -ExecutionPolicy Bypass -File setup.ps1 [<disc.iso>] [-Xbox <console IP>] [-Hd | -NoHd]
#
# 1. Checks the disc image.
# 2. Installs the latest GT3 Revisited Xbox package on the console (Device Portal), with the VCLibs
#    framework it needs.
# 3. Prepares a USB drive for the console (NTFS, readable by apps) and copies the disc image to it.
# 4. Optionally makes HD texture packs from your disc on this PC (an NVIDIA RTX graphics card,
#    an hour or more) and puts them on the console.
# Running it again picks up where it left off: steps already done are offered to be skipped.
#
# Nothing of the game's data leaves your PC except onto your own console and USB drive; the HD
# packs are made from your disc and are yours only (do not share them).
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Disc,
    [string]$Xbox,
    [switch]$Hd,
    [switch]$NoHd,
    [string]$Repo = "bally199/GT3-revisited-mod"
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue" # (Invoke-WebRequest's progress bar slows downloads down a lot)
$root = $PSScriptRoot
$work = Join-Path $root "work"
$downloads = Join-Path $root "downloads"
$stateFile = Join-Path $root "setup-state.json"
New-Item -Force -ItemType Directory $work, $downloads | Out-Null
Start-Transcript -Path (Join-Path $root "setup.log") -Force | Out-Null
Get-ChildItem $root -Recurse -File -Include *.ps1, *.py, *.bat -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# --- Little helpers ------------------------------------------------------------------------------

function Say([string]$text) { Write-Host $text }
function Step([string]$text) { Write-Host ""; Write-Host "=== $text ===" -ForegroundColor Cyan }
function Good([string]$text) { Write-Host "  OK: $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "  Note: $text" -ForegroundColor Yellow }
function Ask([string]$question, [string]$default = "") {
    $hint = if ($default) { " [$default]" } else { "" }
    $a = Read-Host "  $question$hint"
    if (-not $a) { return $default }
    return $a.Trim()
}
function YesNo([string]$question, [bool]$default) {
    $d = if ($default) { "Y/n" } else { "y/N" }
    while ($true) {
        $a = (Read-Host "  $question ($d)").Trim().ToLower()
        if (-not $a) { return $default }
        if ($a -in "y", "yes") { return $true }
        if ($a -in "n", "no") { return $false }
    }
}
function Load-State {
    if (Test-Path $stateFile) { try { return Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable } catch {} }
    return @{}
}
function Save-State { $state | ConvertTo-Json | Set-Content $stateFile }
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}
function Winget([string]$id, [string]$what) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is missing (Microsoft Store: 'App Installer'); install $what yourself, then run this again"
    }
    Say "  Installing $what (winget $id)..."
    & winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements | Out-Host
    Refresh-Path
}

# --- Device Portal (the console's web interface) -----------------------------------------------

# A session with its anti-forgery token. Scripts sign in as "auto-<user>": Device Portal then
# skips the browser CSRF check that refuses scripted uploads (Microsoft's Device Portal docs,
# "CSRF Protection and Scripting").
function Portal([string]$address, [pscredential]$cred) {
    $address = ($address -replace '^https?://', '' -replace '/.*$', '' -replace ':\d+$', '')
    $base = "https://${address}:11443"
    $user = $cred.UserName.TrimStart('\')
    if (-not $user.StartsWith("auto-")) { $cred = [pscredential]::new("auto-$user", $cred.Password) }
    $session = $null
    Invoke-WebRequest "$base/api/os/info" -Credential $cred -SkipCertificateCheck -SessionVariable session -TimeoutSec 15 | Out-Null
    return @{ Base = $base; Session = $session; Cred = $cred }
}
function Csrf($p) { ($p.Session.Cookies.GetCookies($p.Base) | Where-Object Name -eq "CSRF-Token" | Select-Object -Last 1).Value }
function Get-Portal($p, [string]$path) {
    Invoke-RestMethod "$($p.Base)$path" -WebSession $p.Session -Credential $p.Cred -SkipCertificateCheck
}
function Post-Portal($p, [string]$path) {
    Invoke-WebRequest -Method Post "$($p.Base)$path" -WebSession $p.Session -Credential $p.Cred `
        -Headers @{ "X-CSRF-Token" = (Csrf $p) } -SkipCertificateCheck | Out-Null
}
# One file as a one-part multipart upload, built by hand: the shapes PowerShell and .NET make
# (filename*=, a quoted boundary) are not taken by Device Portal.
function Send-PortalFile($p, [string]$uri, [System.IO.FileInfo]$file) {
    $net = $p.Cred.GetNetworkCredential()
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.ServerCertificateCustomValidationCallback = [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
    $handler.CookieContainer = $p.Session.Cookies
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $stream = $null
    try {
        $boundary = "----GT3RFormBoundary" + [guid]::NewGuid().ToString("N")
        $head = [Text.Encoding]::UTF8.GetBytes("--$boundary`r`nContent-Disposition: form-data; name=`"$($file.Name)`"; filename=`"$($file.Name)`"`r`nContent-Type: application/octet-stream`r`n`r`n")
        $tail = [Text.Encoding]::UTF8.GetBytes("`r`n--$boundary--`r`n")
        $stream = [System.IO.File]::OpenRead($file.FullName)
        # Head, file and tail read as one stream: a large package is never held in memory whole.
        $concat = [GT3R.ConcatStream]::new([System.IO.Stream[]]@([System.IO.MemoryStream]::new($head), $stream, [System.IO.MemoryStream]::new($tail)))
        $body = [System.Net.Http.StreamContent]::new($concat)
        $body.Headers.ContentLength = $head.Length + $file.Length + $tail.Length
        [void]$body.Headers.TryAddWithoutValidation("Content-Type", "multipart/form-data; boundary=$boundary")
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $uri)
        $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($net.UserName):$($net.Password)"))
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Basic", $basic)
        $csrf = Csrf $p
        if ($csrf) { $request.Headers.Add("X-CSRF-Token", $csrf) }
        $request.Content = $body
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) { throw "upload refused: $([int]$response.StatusCode) $text" }
    } finally {
        if ($stream) { $stream.Dispose() }
        $client.Dispose()
    }
}
Add-Type -TypeDefinition @'
namespace GT3R {
    // Several streams read one after the other (a multipart body around a large file).
    public class ConcatStream : System.IO.Stream {
        readonly System.IO.Stream[] parts; int at;
        public ConcatStream(System.IO.Stream[] parts) { this.parts = parts; }
        public override int Read(byte[] buffer, int offset, int count) {
            while (at < parts.Length) {
                int n = parts[at].Read(buffer, offset, count);
                if (n > 0) return n;
                at++;
            }
            return 0;
        }
        public override bool CanRead { get { return true; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return false; } }
        public override long Length { get { throw new System.NotSupportedException(); } }
        public override long Position { get { throw new System.NotSupportedException(); } set { throw new System.NotSupportedException(); } }
        public override void Flush() {}
        public override long Seek(long o, System.IO.SeekOrigin s) { throw new System.NotSupportedException(); }
        public override void SetLength(long v) { throw new System.NotSupportedException(); }
        public override void Write(byte[] b, int o, int c) { throw new System.NotSupportedException(); }
    }
}
'@
function Installed($p) {
    $list = Get-Portal $p "/api/app/packagemanager/packages"
    return $list.InstalledPackages | Where-Object { $_.PackageFullName -like "GT3Revisited.Xbox_*" } | Select-Object -First 1
}
function Has-Package($p, [string]$like) {
    $list = Get-Portal $p "/api/app/packagemanager/packages"
    return [bool]($list.InstalledPackages | Where-Object { $_.PackageFullName -like $like })
}
function Install-Package($p, [System.IO.FileInfo]$file) {
    Send-PortalFile $p "$($p.Base)/api/app/packagemanager/package?package=$([uri]::EscapeDataString($file.Name))" $file
    for ($i = 0; $i -lt 300; $i++) {
        Start-Sleep 2
        $r = Invoke-WebRequest "$($p.Base)/api/app/packagemanager/state" -WebSession $p.Session -Credential $p.Cred `
            -SkipCertificateCheck -SkipHttpErrorCheck
        if ($r.StatusCode -ne 204) { break }
    }
    if ($r.StatusCode -ge 400) { throw "the console did not install $($file.Name): $($r.StatusCode) $($r.Content)" }
}
function Start-Game($p) {
    $pkg = Installed $p
    if (-not $pkg) { return }
    $b64 = { param($s) [uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))) }
    $praid = if ($pkg.PackageRelativeId) { $pkg.PackageRelativeId } else { "$($pkg.PackageFamilyName)!App" }
    Post-Portal $p "/api/taskmanager/app?appid=$(& $b64 $praid)&package=$(& $b64 $pkg.PackageFullName)"
}
# The game's files on the console: LocalAppData of the package, under LocalState.
function AppQuery($pkg, [string]$path) {
    return "knownfolderid=LocalAppData&packagefullname=$([uri]::EscapeDataString($pkg.PackageFullName))&path=$([uri]::EscapeDataString($path))"
}
function List-AppFolder($p, $pkg, [string]$path) {
    try { return @((Get-Portal $p "/api/filesystem/apps/files?$(AppQuery $pkg $path)").Items) } catch { return $null }
}
# Makes every missing folder along "\LocalState\a\b\c".
function Ensure-AppFolder($p, $pkg, [string]$path) {
    $parts = $path.Trim('\').Split('\')
    $at = "\" + $parts[0]
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $items = List-AppFolder $p $pkg $at
        if (-not ($items | Where-Object { $_.Name -eq $parts[$i] })) {
            Post-Portal $p "/api/filesystem/apps/folder?$(AppQuery $pkg $at)&newfoldername=$([uri]::EscapeDataString($parts[$i]))"
        }
        $at += "\" + $parts[$i]
    }
}
# Every file of $dir into the console folder $path (those already there by name are skipped:
# a pack's names are their contents, so a second run only sends what is missing).
function Put-Folder($p, $pkg, [string]$dir, [string]$path) {
    Ensure-AppFolder $p $pkg $path
    $have = @{}
    foreach ($item in @(List-AppFolder $p $pkg $path)) { if ($item) { $have[$item.Name] = $true } }
    $files = @(Get-ChildItem -File $dir | Where-Object { -not $have.ContainsKey($_.Name) })
    Say "  $($files.Count) files to send ($($have.Count) there already)"
    $uri = "$($p.Base)/api/filesystem/apps/file?$(AppQuery $pkg $path)"
    $n = 0; $failedInRow = 0
    foreach ($file in $files) {
        try {
            Send-PortalFile $p $uri $file
            $n++; $failedInRow = 0
            if ($n % 200 -eq 0) { Say "  $n of $($files.Count)..." }
        } catch {
            Warn "could not send $($file.Name): $_"
            if (++$failedInRow -ge 20) { throw "20 files in a row were refused: is the console still on, and signed in?" }
        }
    }
    Good "$n files sent to the console"
}

# --- The steps ---------------------------------------------------------------------------------

$state = Load-State
try {
    Write-Host ""
    Write-Host "  GT3 Revisited for Xbox - setup" -ForegroundColor White
    Write-Host "  ------------------------------"
    Say "  Before you start, you need:"
    Say "   - your Xbox in Developer Mode (Dev Home showing), on the same network as this PC"
    Say "   - Device Portal on: Dev Home > Remote Access Settings > Enable Device Portal,"
    Say "     with a user name and password set (Dev Home shows the console's address too)"
    Say "   - a USB drive plugged into this PC with at least 5 GB free"
    Say "   - your own Gran Turismo 3 A-spec disc image (.iso or .chd)"
    if (-not (YesNo "Ready?" $true)) { return }

    # 1. The disc image.
    Step "1 of 4: the disc image"
    if (-not $Disc) { $Disc = $state.disc }
    if (-not $Disc -or -not (Test-Path -LiteralPath $Disc)) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = [System.Windows.Forms.OpenFileDialog]::new()
        $dialog.Title = "Your Gran Turismo 3 disc image"
        $dialog.Filter = "GT3 disc image (*.iso;*.chd)|*.iso;*.chd|All files (*.*)|*.*"
        if ($dialog.ShowDialog() -ne "OK") { throw "no disc image chosen" }
        $Disc = $dialog.FileName
    }
    $discFile = Get-Item -LiteralPath $Disc
    if ($discFile.Length -lt 500MB) { throw "$($discFile.Name) is only $([math]::Round($discFile.Length / 1MB)) MB: not a whole GT3 disc image" }
    if ($discFile.Extension -eq ".iso") {
        # Windows mounts ISO images: the game's CORE.GT3 or its archive (GT3.VOL, or *.VOL) should be on it.
        $hasVol = $null
        try {
            $image = Mount-DiskImage -ImagePath $discFile.FullName -PassThru -StorageType ISO
            try {
                $letter = ($image | Get-Volume).DriveLetter
                if ($letter) { $hasVol = (Test-Path "${letter}:\CORE.GT3") -or [bool](Get-ChildItem "${letter}:\*.VOL" -ErrorAction SilentlyContinue) }
            } finally {
                Dismount-DiskImage -ImagePath $discFile.FullName | Out-Null
            }
        } catch {
            Warn "could not look inside the image ($($_.Exception.Message)); carrying on"
        }
        if ($hasVol -eq $false) { throw "$($discFile.Name) has no CORE.GT3 or GT3.VOL: it does not look like Gran Turismo 3 A-spec" }
    }
    $state.disc = $discFile.FullName; Save-State
    Good "$($discFile.Name) ($([math]::Round($discFile.Length / 1GB, 2)) GB)"

    # HD packs: asked now, made last (they take the longest).
    $nvidia = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object Name -match "NVIDIA") | Select-Object -First 1
    $wantHd = $false
    if ($Hd) { $wantHd = $true }
    elseif (-not $NoHd) {
        Say ""
        Say "  HD textures: sharper cars, tracks, menus and text, made from your disc on this PC by an AI"
        Say "  upscaler. Needs an NVIDIA RTX graphics card and takes an hour or more (and ~10 GB of space)."
        if ($nvidia) {
            Say "  Graphics card found: $($nvidia.Name)"
            $wantHd = YesNo "Make HD textures at the end?" ($state.hd -ne $false)
        } else {
            Warn "no NVIDIA graphics card found: HD textures are skipped (the game is the same, at the disc's detail)"
        }
    }
    $state.hd = $wantHd; Save-State

    # 2. The console.
    Step "2 of 4: the console"
    if (-not $Xbox) { $Xbox = Ask "The console's IP address (Dev Home shows it, e.g. 192.168.0.95)" $state.xbox }
    if (-not $Xbox) { throw "no console address" }
    $credFile = Join-Path $root "xbox-cred.xml"
    $p = $null
    for ($try = 1; -not $p; $try++) {
        if (Test-Path $credFile) { $cred = Import-Clixml $credFile }
        else {
            $cred = Get-Credential -Message "The Device Portal user name and password you set in Dev Home > Remote Access Settings"
            if (-not $cred) { throw "no Device Portal sign-in" }
        }
        try {
            $p = Portal $Xbox $cred
            $cred | Export-Clixml $credFile # (encrypted for this Windows user only)
        } catch {
            Remove-Item $credFile -ErrorAction SilentlyContinue
            Warn "could not reach Device Portal at https://${Xbox}:11443 ($($_.Exception.Message))"
            if ($try -ge 3) { throw "Device Portal did not answer: check the address, that Device Portal is on, and the sign-in" }
            Say "  Check the console is in Dev Home with Device Portal on; then try again."
            $Xbox = Ask "The console's IP address" $Xbox
        }
    }
    $state.xbox = $Xbox; Save-State
    Good "connected to the console at $Xbox"

    # The latest release of the Xbox package (and the PC build for the HD step).
    $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "gt3r-xbox-setup" }
    $assets = @{}
    foreach ($a in $release.assets) { $assets[$a.name] = $a.browser_download_url }
    $msixName = "gt3r-xbox.msix"; $vclibsName = "Microsoft.VCLibs.x64.14.00.appx"
    foreach ($need in $msixName, $vclibsName) { if (-not $assets[$need]) { throw "the release $($release.tag_name) has no $need" } }
    $relDir = Join-Path $downloads $release.tag_name
    New-Item -Force -ItemType Directory $relDir | Out-Null
    function Fetch([string]$name) {
        $to = Join-Path $relDir $name
        if (-not (Test-Path $to)) {
            Say "  Downloading $name..."
            Invoke-WebRequest $assets[$name] -OutFile "$to.part" -Headers @{ "User-Agent" = "gt3r-xbox-setup" }
            Move-Item -Force "$to.part" $to
        }
        return Get-Item $to
    }

    if ($state.installed -eq $release.tag_name -and (Installed $p) -and -not (YesNo "GT3 Revisited $($release.tag_name) is installed already. Install it again?" $false)) {
        Good "GT3 Revisited $($release.tag_name) is on the console"
    } else {
        $vclibs = Fetch $vclibsName
        $msix = Fetch $msixName
        if (-not (Has-Package $p "Microsoft.VCLibs.140.00_*x64*")) {
            Say "  Installing the Visual C++ libraries package on the console..."
            Install-Package $p $vclibs
        }
        Say "  Installing GT3 Revisited $($release.tag_name) on the console (a minute or two)..."
        Install-Package $p $msix
        if (-not (Installed $p)) { throw "the console says the install went through, but GT3 Revisited is not listed" }
        $state.installed = $release.tag_name; Save-State
        Good "GT3 Revisited $($release.tag_name) installed"
    }

    # 3. The USB drive.
    Step "3 of 4: the USB drive"
    $copied = $state.usb_done -eq $discFile.FullName
    if ($copied -and -not (YesNo "The disc image went onto a USB drive last time. Do a USB drive again?" $false)) {
        Good "skipped"
    } else {
        $usbLetters = @(Get-Disk -ErrorAction SilentlyContinue | Where-Object BusType -eq "USB" | Get-Partition -ErrorAction SilentlyContinue |
                        Where-Object DriveLetter | ForEach-Object { [string]$_.DriveLetter })
        $volumes = @(Get-Volume | Where-Object { $_.DriveLetter -and ($_.DriveType -eq "Removable" -or [string]$_.DriveLetter -in $usbLetters) } |
                     Sort-Object DriveLetter)
        if (-not $volumes.Count) { throw "no USB drive found: plug one in (5 GB free or more) and run this again" }
        Say "  USB drives:"
        foreach ($v in $volumes) {
            Say ("   {0}:  {1,-16} {2,-6} {3,6:N1} GB free of {4:N1} GB" -f $v.DriveLetter, $(if ($v.FileSystemLabel) { $v.FileSystemLabel } else { "(no name)" }),
                 $v.FileSystem, ($v.SizeRemaining / 1GB), ($v.Size / 1GB))
        }
        $letter = (Ask "Which drive letter?" ([string]$volumes[0].DriveLetter)).TrimEnd(':').ToUpper()
        $vol = $volumes | Where-Object { [string]$_.DriveLetter -eq $letter } | Select-Object -First 1
        if (-not $vol) { throw "$letter is not one of the USB drives listed" }
        $format = $vol.FileSystem -ne "NTFS"
        if ($format) {
            Warn "$letter`: is $($vol.FileSystem): the Xbox only lets apps read NTFS drives, so it has to be formatted NTFS."
            Write-Host "  FORMATTING ERASES EVERYTHING ON ${letter}:" -ForegroundColor Red
            $typed = Ask "Type FORMAT $letter to format it (anything else stops)"
            if ($typed -ne "FORMAT $letter") { throw "not formatted: copy what you need off ${letter}: (or use an NTFS drive) and run this again" }
        } elseif ($vol.SizeRemaining -lt $discFile.Length + 50MB -and -not (Test-Path "${letter}:\$($discFile.Name)")) {
            throw "${letter}: has $([math]::Round($vol.SizeRemaining / 1GB, 1)) GB free; the disc image needs $([math]::Round($discFile.Length / 1GB, 1)) GB"
        }
        # Formatting and the permission need an administrator: one prompt for both. The permission:
        # ALL APPLICATION PACKAGES (S-1-15-2-1) may read the drive, files to come included.
        $admin = "`$ErrorActionPreference = 'Stop'; try { "
        if ($format) { $admin += "Format-Volume -DriveLetter $letter -FileSystem NTFS -NewFileSystemLabel GT3 -Confirm:`$false -Force | Out-Null; " }
        $admin += "icacls '${letter}:\' /grant '*S-1-15-2-1:(OI)(CI)RX' /T /C /Q | Out-Null; exit `$LASTEXITCODE } catch { exit 1 }"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($admin))
        Say "  Windows will ask for administrator permission (to $(if ($format) { 'format the drive and ' })let Xbox apps read it)..."
        $proc = Start-Process pwsh -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList "-NoProfile -EncodedCommand $encoded"
        if ($proc.ExitCode) { throw "setting up ${letter}: failed (exit $($proc.ExitCode))" }
        if ($format) { Good "${letter}: formatted NTFS" }
        $dest = "${letter}:\$($discFile.Name)"
        if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -eq $discFile.Length) {
            Good "the disc image is on ${letter}: already"
        } else {
            Say "  Copying the disc image to ${letter}: (a few minutes)..."
            & robocopy $discFile.DirectoryName "${letter}:\" $discFile.Name /J /NJH /NJS /NDL /R:2 /W:2 | Out-Host
            if ($LASTEXITCODE -ge 8) { throw "copying to ${letter}: failed (robocopy $LASTEXITCODE)" }
            Good "copied to $dest"
        }
        $state.usb_done = $discFile.FullName; $state.usb_letter = $letter; Save-State
    }

    # 4. HD textures.
    Step "4 of 4: HD textures"
    if (-not $wantHd) {
        Good "skipped"
    } else {
        # ffmpeg and Python, then PyTorch with the upscaler model (torch-setup.ps1).
        if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { Winget "Gyan.FFmpeg" "ffmpeg" }
        if (-not (Get-Command py -ErrorAction SilentlyContinue)) { Winget "Python.Python.3.12" "Python 3.12" }
        if (-not (Test-Path (Join-Path $root "tools\torch-venv\Scripts\python.exe")) -or -not (Test-Path (Join-Path $root "tools\RealESRGAN_x4plus.pth"))) {
            Say "  Setting up the AI upscaler (PyTorch, a few GB the first time)..."
            & (Join-Path $root "torch-setup.ps1")
        }
        # The game for Windows dumps the disc's textures, menu images and fonts here (--dump-all).
        $dumped = (Test-Path (Join-Path $work "texture_dump")) -and $state.dumped -eq $discFile.FullName
        if (-not $dumped) {
            if (-not $assets["gt3r-windows-x64.zip"]) { throw "the release $($release.tag_name) has no gt3r-windows-x64.zip (the PC game, for the dump)" }
            $zip = Fetch "gt3r-windows-x64.zip"
            $pcGame = Join-Path $root "tools\gt3r-windows"
            Remove-Item -Recurse -Force $pcGame -ErrorAction SilentlyContinue
            Expand-Archive $zip.FullName $pcGame
            $exe = Get-ChildItem $pcGame -Recurse -Filter gt3r.exe | Select-Object -First 1
            if (-not $exe) { throw "no gt3r.exe in $($zip.Name)" }
            Say "  Dumping the disc's textures with the PC game (a window opens; 5-15 minutes)..."
            $env:GT3R_DATA_DIR = $work
            $env:GT3R_SKIP_MOVIES = "1"
            try {
                $proc = Start-Process $exe.FullName -ArgumentList @("`"$($discFile.FullName)`"", "--dump-all") -Wait -PassThru -WorkingDirectory $exe.DirectoryName
            } finally {
                Remove-Item Env:GT3R_DATA_DIR, Env:GT3R_SKIP_MOVIES -ErrorAction SilentlyContinue
            }
            $count = @(Get-ChildItem (Join-Path $work "texture_dump") -Filter *.png -ErrorAction SilentlyContinue).Count
            if ($proc.ExitCode -or $count -lt 1000) {
                throw "the dump did not finish (exit $($proc.ExitCode), $count textures): see work\gt3r.log"
            }
            $state.dumped = $discFile.FullName; Save-State
            Good "$count textures dumped"
        }
        Say "  Upscaling (an hour or more: leave it running; it carries on where it left off if stopped)..."
        & (Join-Path $root "hd-pack.ps1") -Textures -Menus -Fonts -Torch -Work $work
        # Onto the console, into the game's textures folder (packs two folders deep are read).
        $pkg = Installed $p
        $data = "\LocalState\GT3Revisited\GT3Revisited"
        foreach ($pack in @(@{ Dir = "textures-hd"; To = "hd-3d" }, @{ Dir = "menu-hd"; To = "hd-menus" }, @{ Dir = "fonts-hd"; To = "hd-fonts" })) {
            $dir = Join-Path $work $pack.Dir
            if (-not (Test-Path $dir)) { continue }
            Say "  Sending $($pack.Dir) to the console..."
            Put-Folder $p $pkg $dir "$data\textures\$($pack.To)"
        }
        Good "HD textures on the console (Settings > Video > HD textures turns them on and off)"
    }

    Step "Done"
    Say "  Last steps, on the Xbox:"
    Say "   1. Plug the USB drive into the console. If it asks how to use it, choose media,"
    Say "      NOT game storage (that would format it)."
    Say "   2. Dev Home: highlight GT3 Revisited > View details > App type: Game (as an App it"
    Say "      only gets a fraction of the console's power)."
    Say "   3. Start it. The first time it asks for the disc: pick the drive (usually E:) and the"
    Say "      disc image. It remembers it from then on."
    Say ""
    Say "  Run this again any time to update to a newer release."
} catch {
    Write-Host ""
    Write-Host "  SETUP STOPPED: $_" -ForegroundColor Red
    Write-Host "  (Details in setup.log beside this script. Fix the above and run it again: it carries on.)"
    exit 1
} finally {
    Stop-Transcript | Out-Null
}
