# GT3 Revisited: HD textures and movies from the game's own dumps, on this PC.
#
#   pwsh -ExecutionPolicy Bypass -File $HOME\source\gt3r-xbox\hd-pack.ps1 -Textures
#       texture_dump\*.png (build.ps1 -FetchDir texture_dump) -> textures-hd\ (same names)
#   pwsh -ExecutionPolicy Bypass -File $HOME\source\gt3r-xbox\hd-pack.ps1 -Textures -Retry
#       only those Real-ESRGAN could not do last time; the textures made go to textures-hd-new too
#   pwsh -ExecutionPolicy Bypass -File $HOME\source\gt3r-xbox\hd-pack.ps1 -Textures -Check
#       compares every texture in textures-hd with its original and makes again those that are
#       spoiled (black or garbage parts: Real-ESRGAN losing the GPU part way); list in textures-check.txt
#   ... -Torch: Real-ESRGAN through PyTorch on CUDA (tools\upscale.py; set up by torch-setup.ps1)
#       instead of realesrgan-ncnn-vulkan: no Vulkan, the alpha scaled apart
#   ... -SmallOnly: only the small images (with -Menus -Redo: the small ones made again)
#   Small menu images (the shorter side 64 or less, the longer 128 or less: the car icons, short
#   labels) are always scaled by lanczos: Real-ESRGAN paints over that little detail.
#   ... -NoAI: no Real-ESRGAN at all, lanczos only (it also stops by itself after the GPU is lost 3
#       times in a run: on some PCs a lost GPU can take the whole screen down)
#   pwsh -ExecutionPolicy Bypass -File $HOME\source\gt3r-xbox\hd-pack.ps1 -Menus
#       the menus' art: menu_dump\*.png (build.ps1 -FetchDir menu_dump) -> menu-hd\, at 4x (-MenuScale);
#       -Retry and -Check work for it too (menu-plain.txt, menu-check.txt)
#   pwsh -ExecutionPolicy Bypass -File $HOME\source\gt3r-xbox\hd-pack.ps1 -Fonts -Torch
#       the fonts' glyph atlases: font_dump\*.png (build.ps1 -FetchDir font_dump) -> fonts-hd\, at 4x
#       (-MenuScale), the alpha (the glyphs' shapes) through Real-ESRGAN too
#   pwsh -ExecutionPolicy Bypass -File $HOME\source\gt3r-xbox\hd-pack.ps1 -Movies [-Only opening.pss]
#       movie_dump\*.pss + movies.txt (build.ps1 -FetchDir movie_dump) -> movies-hd\<name>.pss.m2v
#
# Then onto the console: build.ps1 -PutDir textures-hd -To textures (and menu-hd the same), and
# build.ps1 -PutDir movies-hd -To movies_hd (the game makes both folders when it starts).
#
# Needs ffmpeg (winget install Gyan.FFmpeg) and Real-ESRGAN's portable Vulkan build: unzip
# realesrgan-ncnn-vulkan-<version>-windows.zip (github.com/xinntao/Real-ESRGAN, Releases) into
# tools\realesrgan\ beside this script, so tools\realesrgan\realesrgan-ncnn-vulkan.exe and its
# models\ folder are there.
#
# Textures: 4x by realesrgan-x4plus, then halved (-Scale 2, the default: a quarter of the
# memory of 4x, and the Xbox loads every one when its course or car loads) or kept (-Scale 4).
# Movies: the field-split ones (two field pictures stacked per frame, see movies.txt) rebuilt as
# interlaced frames and deinterlaced at the field rate (bwdif), the others as they are; 2x by
# realesr-animevideov3; MPEG-2 at -Quality (ffmpeg's -q:v, 2 best .. 6), its sound stays the
# disc's. A movie's frames go through a temporary folder (several GB for a long one).
[CmdletBinding()]
param(
    [switch]$Textures,
    [switch]$Menus,
    [switch]$Fonts,
    [int]$MenuScale = 4,
    [switch]$Movies,
    [int]$Scale = 2,
    [string]$Only,
    [int]$Quality = 3,
    [switch]$Redo,
    [switch]$Retry,
    [string]$List,
    [switch]$Check,
    [switch]$NoAI,
    [switch]$Torch,
    [switch]$SmallOnly,
    [int]$Limit = 80,
    [int]$Tile = 256,
    [string]$Work # the folder with the dumps and the packs made (default: this script's)
)
# Windows PowerShell 5 (powershell.exe, or .\script.ps1 from it): this needs PowerShell 7 (pwsh).
if ($PSVersionTable.PSVersion.Major -lt 7) {
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) { throw "PowerShell 7 is needed: winget install Microsoft.PowerShell, then a new terminal" }
    $pass = foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { "-$k" } } else { "-$k"; "$v" }
    }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @pass
    exit $LASTEXITCODE
}
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$data = if ($Work) { (New-Item -Force -ItemType Directory $Work).FullName } else { $root }
$esrgan = Join-Path $root "tools\realesrgan\realesrgan-ncnn-vulkan.exe"
Start-Transcript -Path (Join-Path $data "hd-pack.log") -Force | Out-Null
try {
    $torchPy = Join-Path $root "tools\torch-venv\Scripts\python.exe"
    $upscaler = Join-Path $root "tools\upscale.py"
    $torchModel = Join-Path $root "tools\RealESRGAN_x4plus.pth"
    if ($Torch) {
        foreach ($need in $torchPy, $upscaler, $torchModel) {
            if (-not (Test-Path $need)) { throw "$need is missing: run torch-setup.ps1 first" }
        }
    } elseif (-not $NoAI -and -not (Test-Path $esrgan)) { throw "Real-ESRGAN is not at $esrgan (see the top of this script)" }
    # A terminal opened before ffmpeg was installed has the old PATH: the current one, then winget's folder.
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    }
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        $found = Get-ChildItem (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet") -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { $env:Path += ";" + $found.DirectoryName }
    }
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { throw "ffmpeg is not on PATH: winget install Gyan.FFmpeg (then a new terminal)" }

    function Run([string]$what, [string]$exe, [string[]]$arguments) {
        & $exe @arguments 2>&1 | ForEach-Object { "$_" } | Select-Object -Last 3 | ForEach-Object { Write-Host "   $_" }
        if ($LASTEXITCODE) { throw "$what failed (exit $LASTEXITCODE)" }
    }

    # How far an upscaled texture is from its original: each 4x4-texel block of the original against
    # the upscale box-filtered back to the original's size, the mean difference of the worst block in
    # any channel, alpha too (0-255). Real-ESRGAN's good ones stay under about 40; black or garbage
    # tiles (a lost GPU, vkQueueSubmit -4) are far over. 999: not readable. A string, for -Parallel.
    $diffText = @'
param([string]$src, [string]$up)
if ([IO.Path]::GetFileName($src) -notmatch '^(\d+)x(\d+)_') { return 999 }
$w = [int]$Matches[1]; $h = [int]$Matches[2]
$bw = [int][math]::Max(1, [math]::Ceiling($w / 4)); $bh = [int][math]::Max(1, [math]::Ceiling($h / 4))
$raw = [IO.Path]::Combine([IO.Path]::GetTempPath(), "gt3r-check-" + [Guid]::NewGuid().ToString("N") + ".raw")
$graph = "[0]scale=${w}:${h}:flags=area,format=rgba[u];[1]format=rgba[s];[u][s]blend=all_mode=difference,scale=${bw}:${bh}:flags=area,format=rgba"
& ffmpeg -v quiet -y -i $up -i $src -filter_complex $graph -f rawvideo -pix_fmt rgba $raw 2>$null
$bad = $LASTEXITCODE -or -not (Test-Path $raw)
if ($bad) { Remove-Item $raw -ErrorAction SilentlyContinue; return 999 }
$bytes = [IO.File]::ReadAllBytes($raw)
Remove-Item $raw -ErrorAction SilentlyContinue
if ($bytes.Length -lt 4) { return 999 }
$m = 0
foreach ($b in $bytes) { if ($b -gt $m) { $m = $b } }
return [int]$m
'@
    # $pairs: objects with Name, Src and Up; returns a hashtable Name -> difference (several at once).
    function Diffs($pairs) {
        $result = @{}
        if (-not @($pairs).Count) { return $result }
        @($pairs) | ForEach-Object -ThrottleLimit 12 -Parallel {
            $d = if (Test-Path $_.Up) { & ([scriptblock]::Create($using:diffText)) $_.Src $_.Up } else { 999 }
            [pscustomobject]@{ Name = $_.Name; Diff = [int]$d }
        } | ForEach-Object { $result[$_.Name] = $_.Diff }
        return $result
    }

    $sets = @()
    if ($Textures) { $sets += @{ Dump = "texture_dump"; Out = "textures-hd"; Scale = $Scale; Name = "textures" } }
    if ($Menus) { $sets += @{ Dump = "menu_dump"; Out = "menu-hd"; Scale = $MenuScale; Name = "menu"; Small = $true } }
    if ($Fonts) { $sets += @{ Dump = "font_dump"; Out = "fonts-hd"; Scale = $MenuScale; Name = "fonts"; AlphaModel = $true } }
    foreach ($set in $sets) {
        $Scale = $set.Scale
        $in = Join-Path $data $set.Dump
        $out = Join-Path $data $set.Out
        if (-not (Test-Path $in)) { throw "No $($set.Dump) folder here: build.ps1 -FetchDir $($set.Dump) first" }
        $tmp = Join-Path $data "textures-x4"
        New-Item -Force -ItemType Directory $out, $tmp | Out-Null
        # Only those not done before (the names are the contents), all of them with -Redo, or with
        # -Retry those that Real-ESRGAN failed on last time (textures-plain.txt).
        $plainList = Join-Path $data "$($set.Name)-plain.txt"
        $all = @(Get-ChildItem -File -Filter *.png $in)
        if ($Retry) {
            $names = @{}
            $from = if ($List) { Join-Path $data $List } else { $plainList }
            if (Test-Path $from) { Get-Content $from | ForEach-Object { $names[$_.Trim()] = $true } }
            $todo = @($all | Where-Object { $names.ContainsKey($_.Name) })
        } elseif ($Check) {
            # Every texture made before against its original; the spoiled ones (and missing ones) again.
            Write-Host "== Checking $($all.Count) textures against their originals (a few minutes)"
            $diffs = Diffs @($all | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Src = $_.FullName; Up = (Join-Path $out $_.Name) } })
            $todo = @($all | Where-Object { $diffs[$_.Name] -ge $Limit })
            $report = Join-Path $data "$($set.Name)-check.txt"
            $diffs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First ([math]::Max(200, $todo.Count)) |
                ForEach-Object { "$($_.Value) $($_.Key)" } | Set-Content -Path $report
            $missing = @($todo | Where-Object { $diffs[$_.Name] -eq 999 }).Count
            Write-Host "== $($todo.Count) spoiled ($missing missing or unreadable) of $($all.Count); the worst listed in $($set.Name)-check.txt"
        } else {
            $todo = @($all | Where-Object { $Redo -or -not (Test-Path (Join-Path $out $_.Name)) })
        }
        # Small menu images: lanczos, never Real-ESRGAN.
        $isSmall = {
            param($f)
            if (-not $set.Small -or $f.Name -notmatch '^(\d+)x(\d+)_') { return $false }
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            return [math]::Min($a, $b) -le 64 -and [math]::Max($a, $b) -le 128
        }
        $small = @($todo | Where-Object { & $isSmall $_ })
        if ($SmallOnly) { $todo = @() } else { $todo = @($todo | Where-Object { -not (& $isSmall $_) }) }
        if ($small.Count) {
            Write-Host "== $($small.Count) small $($set.Name) images: lanczos"
            New-Item -Force -ItemType Directory $out | Out-Null
            foreach ($f in $small) {
                $dst = Join-Path $out $f.Name
                Run "ffmpeg (scaling $($f.Name))" "ffmpeg" @("-v", "error", "-y", "-i", $f.FullName, "-vf",
                    "scale=iw*${Scale}:ih*${Scale}:flags=lanczos", "-pix_fmt", "rgba", $dst)
            }
        }
        Write-Host "== $($todo.Count) $($set.Name) images to upscale"
        # The ones made this run also go to textures-hd-new, for putting on the console on their own.
        $new = Join-Path $data "$($set.Out)-new"
        Remove-Item -Recurse -Force $new -ErrorAction SilentlyContinue
        New-Item -ItemType Directory $new | Out-Null
        foreach ($f in $small) { Copy-Item (Join-Path $out $f.Name) $new }
        $batch = Join-Path $data "textures-in"
        # A 4x upscale of $f into the pack: kept (-Scale 4) or halved, and into the -new folder.
        function Place($f, [string]$big) {
            $dst = Join-Path $out $f.Name
            if ($Scale -eq 4) { Move-Item -Force $big $dst }
            else {
                Run "ffmpeg (halving $($f.Name))" "ffmpeg" @("-v", "error", "-y", "-i", $big, "-vf", "scale=iw/2:ih/2:flags=lanczos",
                                                            "-pix_fmt", "rgba", $dst)
            }
            Copy-Item $dst $new
        }
        # Real-ESRGAN on the colour only, the alpha scaled by lanczos: for those whose alpha it
        # spoils (masks with hard steps); returns those still too far from their originals.
        function Split($files) {
            if ($NoAI -or $Torch -or $script:gpuLost -ge 3) { return $files }
            $rgbIn = Join-Path $data "textures-rgb"
            $rgbUp = Join-Path $data "textures-rgb-x4"
            Remove-Item -Recurse -Force $rgbIn, $rgbUp, $tmp -ErrorAction SilentlyContinue
            New-Item -ItemType Directory $rgbIn, $rgbUp, $tmp | Out-Null
            foreach ($f in $files) {
                Run "ffmpeg (colour of $($f.Name))" "ffmpeg" @("-v", "error", "-y", "-i", $f.FullName, "-vf", "format=rgb24",
                                                              (Join-Path $rgbIn $f.Name))
            }
            $lines = @(& $esrgan -i $rgbIn -o $rgbUp -n realesrgan-x4plus -s 4 -t 64 -j 1:1:1 -g 0 -f png 2>&1 | ForEach-Object { "$_" })
            if (@($lines | Where-Object { $_ -match 'vk\w+ failed' }).Count) { $script:gpuLost++; return $files }
            foreach ($f in $files) {
                $up = Join-Path $rgbUp $f.Name
                if (-not (Test-Path $up) -or $f.Name -notmatch '^(\d+)x(\d+)_') { continue }
                $w = 4 * [int]$Matches[1]; $h = 4 * [int]$Matches[2]
                & ffmpeg -v error -y -i $up -i $f.FullName -filter_complex `
                    "[1]scale=${w}:${h}:flags=lanczos,format=rgba,alphaextract,format=gray[a];[0]scale=${w}:${h},format=rgb24[c];[c][a]alphamerge" `
                    -pix_fmt rgba (Join-Path $tmp $f.Name) 2>$null
            }
            $diffs = Diffs @($files | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Src = $_.FullName; Up = (Join-Path $tmp $_.Name) } })
            $still = New-Object System.Collections.Generic.List[object]
            foreach ($f in $files) {
                if ($diffs[$f.Name] -ge $Limit) { $still.Add($f); continue }
                Place $f (Join-Path $tmp $f.Name)
            }
            Remove-Item -Recurse -Force $rgbIn, $rgbUp -ErrorAction SilentlyContinue
            return $still
        }
        # Real-ESRGAN over $files (in batches: a lost GPU, vkQueueSubmit -4, only spoils its own batch);
        # returns those it did not make, or spoiled (Diffs at $Limit or over).
        function Esrgan($files, [int]$tile) {
            $failed = New-Object System.Collections.Generic.List[object]
            for ($at = 0; $at -lt $files.Count; $at += 400) {
                $part = $files[$at..([math]::Min($at + 400, $files.Count) - 1)]
                if ($NoAI -or $script:gpuLost -ge 3) { $part | ForEach-Object { $failed.Add($_) }; continue }
                Remove-Item -Recurse -Force $batch, $tmp -ErrorAction SilentlyContinue
                New-Item -ItemType Directory $batch, $tmp | Out-Null
                $part | ForEach-Object { Copy-Item $_.FullName $batch }
                # A lost GPU spoils everything after it in the run (it carries on, writing black or
                # noise, and exits 0): when it says so, the whole batch again in a new process, up
                # to 3 times. One GPU thread at a time (-j 1:1:1): fewer submissions in flight.
                if ($Torch) {
                    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
                    New-Item -ItemType Directory $tmp | Out-Null
                    $extra = @(if ($set.AlphaModel) { "--alpha-model" })
                    $lines = @(& $torchPy $upscaler $torchModel $batch $tmp @extra 2>&1 | ForEach-Object { "$_" })
                }
                for ($try = 1; $try -le 3 -and -not $Torch; $try++) {
                    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
                    New-Item -ItemType Directory $tmp | Out-Null
                    $lines = @(& $esrgan -i $batch -o $tmp -n realesrgan-x4plus -s 4 -t $tile -j 1:1:1 -g 0 -f png 2>&1 |
                        ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^\s*[\d.]+%$' })
                    $lost = @($lines | Where-Object { $_ -match 'vk\w+ failed' }).Count
                    if (-not $lost) { break }
                    $script:gpuLost++
                    Write-Host "   GPU lost ($lost errors) on try $try of 3 ($script:gpuLost this run)"
                    if ($script:gpuLost -ge 3) { Write-Host "== The GPU was lost 3 times: no more Real-ESRGAN this run (lanczos instead)"; break }
                }
                $lines | Select-Object -Last 2 | ForEach-Object { Write-Host "   $_" }
                # Each one against its original: not made, or spoiled (black or garbage tiles), goes again.
                $diffs = Diffs @($part | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Src = $_.FullName; Up = (Join-Path $tmp $_.Name) } })
                foreach ($f in $part) {
                    if ($diffs[$f.Name] -ge $Limit) { $failed.Add($f); continue }
                    Place $f (Join-Path $tmp $f.Name)
                }
                Write-Host "== $([math]::Min($at + 400, $files.Count)) of $($files.Count) ($($failed.Count) to retry)"
            }
            return $failed
        }
        $script:gpuLost = 0
        if ($todo.Count) {
            $failed = Esrgan $todo $Tile
            if ($failed.Count -and -not $Torch -and -not $NoAI) {
                Write-Host "== Again with smaller tiles: $($failed.Count)"
                $failed = Esrgan @($failed) 64
            }
            # What it still could not do: ffmpeg's lanczos, named in textures-plain.txt for -Retry.
            if ($failed.Count -and $failed.Count -le 50 -and $script:gpuLost -lt 3 -and -not $NoAI -and -not $Torch) {
                Write-Host "== Again with smaller tiles, one at a time: $($failed.Count)"
                $still = New-Object System.Collections.Generic.List[object]
                foreach ($f in @($failed)) { foreach ($g in (Esrgan @($f) 64)) { $still.Add($g) } }
                $failed = $still
            }
            if ($failed.Count -and -not $Torch -and -not $NoAI) {
                Write-Host "== Colour by Real-ESRGAN, alpha by lanczos: $($failed.Count)"
                $still = New-Object System.Collections.Generic.List[object]
                foreach ($g in (Split @($failed))) { $still.Add($g) }
                $failed = $still
            }
            foreach ($f in $failed) {
                $dst = Join-Path $out $f.Name
                Run "ffmpeg (scaling $($f.Name))" "ffmpeg" @("-v", "error", "-y", "-i", $f.FullName, "-vf",
                    "scale=iw*${Scale}:ih*${Scale}:flags=lanczos", "-pix_fmt", "rgba", $dst)
                Copy-Item $dst $new
            }
            Set-Content -Path $plainList -Value @($failed | ForEach-Object Name)
            Remove-Item -Recurse -Force $batch, $tmp -ErrorAction SilentlyContinue
            Write-Host "== $($todo.Count - $failed.Count) by Real-ESRGAN, $($failed.Count) scaled plainly (listed in $($set.Name)-plain.txt)"
        }
        Write-Host "== Done in $out; next: build.ps1 -PutDir $($set.Out) -To textures -Xbox <ip>"
    }

    if ($Movies) {
        $in = Join-Path $data "movie_dump"
        $out = Join-Path $data "movies-hd"
        $manifest = Join-Path $in "movies.txt"
        if (-not (Test-Path $manifest)) { throw "No movie_dump\movies.txt here: Settings > Video > Dump movies, then build.ps1 -FetchDir movie_dump" }
        New-Item -Force -ItemType Directory $out | Out-Null
        foreach ($line in Get-Content $manifest) {
            if ($line -match '^\s*#' -or -not $line.Trim()) { continue }
            $name, $layout, $size, $fps = $line -split '\s+'
            if ($Only -and $name -ne $Only) { continue }
            $dst = Join-Path $out "$name.m2v"
            if (Test-Path $dst) { Write-Host "== $name done before"; continue }
            $fields = $layout -eq "fields"
            $rate = [double]::Parse($fps, [Globalization.CultureInfo]::InvariantCulture) * $(if ($fields) { 2 } else { 1 })
            $rateText = $rate.ToString("0.###", [Globalization.CultureInfo]::InvariantCulture)
            Write-Host "== $name ($layout, $size, out at $rateText fps)"
            $movieWork = Join-Path $data "movie-work"
            Remove-Item -Recurse -Force $movieWork -ErrorAction SilentlyContinue
            New-Item -ItemType Directory "$movieWork\in", "$movieWork\up" | Out-Null
            # Field-split: the stacked halves interleaved back into lines (il), then one picture a field.
            $vf = if ($fields) { "il=l=i:c=i,setfield=tff,bwdif=mode=send_field:parity=tff:deint=all" } else { "null" }
            Run "ffmpeg (frames)" "ffmpeg" @("-v", "error", "-y", "-f", "mpeg", "-i", (Join-Path $in $name), "-map", "0:v:0", "-vf", $vf,
                                             "-fps_mode", "passthrough", "$movieWork\in\%06d.png")
            & $esrgan -i "$movieWork\in" -o "$movieWork\up" -n realesr-animevideov3 -s 2 -t $Tile -f png 2>&1 | ForEach-Object { "$_" } |
                Where-Object { $_ -notmatch '^\s*[\d.]+%$' } | Select-Object -Last 5 | ForEach-Object { Write-Host "   $_" }
            # Frames Real-ESRGAN did not make or made blank: ffmpeg's (lanczos) instead.
            $plain = 0
            foreach ($f in Get-ChildItem -File "$movieWork\in") {
                $up = Join-Path "$movieWork\up" $f.Name
                if ((Test-Path $up) -and (Get-Item $up).Length -ge [math]::Max(2048, $f.Length / 4)) { continue }
                $plain++
                Run "ffmpeg (scaling $($f.Name))" "ffmpeg" @("-v", "error", "-y", "-i", $f.FullName, "-vf", "scale=iw*2:ih*2:flags=lanczos", $up)
            }
            if ($plain) { Write-Host "   $plain frames scaled plainly (Real-ESRGAN missing or blank)" }
            Run "ffmpeg (MPEG-2)" "ffmpeg" @("-v", "error", "-y", "-framerate", $rateText, "-i", "$movieWork\up\%06d.png",
                                             "-c:v", "mpeg2video", "-q:v", "$Quality", "-g", "15", "-bf", "2", "-pix_fmt", "yuv420p",
                                             "-f", "mpeg2video", $dst)
            Remove-Item -Recurse -Force $movieWork
            Write-Host "== $name -> $dst ($([math]::Round((Get-Item $dst).Length / 1MB)) MB)"
        }
        Write-Host "== Movies in $out; next: build.ps1 -PutDir movies-hd -To movies_hd -Xbox <ip>"
    }
    if (-not $Textures -and -not $Menus -and -not $Fonts -and -not $Movies) { Write-Host "Say -Textures, -Menus, -Fonts and / or -Movies (see the top of this script)." }
} finally {
    Stop-Transcript | Out-Null
}
