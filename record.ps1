<#
.SYNOPSIS
Records a web page in full-screen Chrome to an MP4 (or, with -Audio, its sound
to an .m4a or .mp3) on this machine.

.DESCRIPTION
Runs the chrome-rec image, then copies the finished video out of the container
and removes the container. Builds the image from this folder when it is
missing. Without -Duration it records until you press Ctrl+C.

.EXAMPLE
.\record.ps1 https://example.com -Duration 30

.EXAMPLE
.\record.ps1 https://example.com -Width 1280 -Height 720 -Fps 60 -Output demo.mp4

.EXAMPLE
.\record.ps1 https://example.com -Title "Evening news"
Saves .\recordings\Evening news.mp4.

.EXAMPLE
.\record.ps1 https://example.com -Dir D:\videos\tv -Title "Evening news"
Saves D:\videos\tv\Evening news.mp4.

.EXAMPLE
.\record.ps1 https://example.com/... -Audio -Cookies .\cookies.txt -Title album
Records only the sound, as AAC 256 kbit/s in an .m4a.

.EXAMPLE
.\record.ps1 https://example.com
Records until Ctrl+C.
#>
[CmdletBinding(DefaultParameterSetName = 'Record')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Record')]
    [ValidatePattern('^(https?|file)://')]
    [string] $Url,

    # Seconds to record; omit to record until Ctrl+C.
    [ValidateRange(1, 86400)]
    [int] $Duration,

    # The same in minutes, fractions allowed (1.5 = 90 s); not with -Duration.
    [ValidateRange(0.02, 1440)]
    [double] $DurationMin,

    [ValidateRange(16, 7680)]
    [int] $Width = 1920,

    [ValidateRange(16, 4320)]
    [int] $Height = 1080,

    [ValidateRange(1, 120)]
    [int] $Fps = 60,

    # Seconds the page gets to load before recording starts.
    [ValidateRange(0, 600)]
    [int] $Warmup = 3,

    # Where the MP4 goes; defaults to .\recordings\recording-<timestamp>.mp4.
    [string] $Output,

    # File name without extension, saved as <Dir>\<Title>.mp4.
    [ValidateScript({ $_.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0 -and $_.Trim(' .') })]
    [string] $Title,

    # Folder for the recording, created if missing; defaults to .\recordings.
    [ValidateNotNullOrEmpty()]
    [string] $Dir,

    [string] $Image = 'chrome-rec',

    # Record the whole page instead of the fullscreen video (YouTube and
    # .play-action players).
    [switch] $KeepPage,

    # After recording, re-encode to H.265: 30-45% smaller, but takes about
    # 1-2.5x the recording's length on all CPU cores.
    [switch] $Compress,

    # H.265 quality for -Compress: lower is better and bigger; 26 looks about
    # like the live H.264 recording.
    [ValidateRange(0, 51)]
    [int] $Crf = 26,

    # H.265 speed for -Compress: slower presets give smaller files.
    [ValidateSet('ultrafast', 'superfast', 'veryfast', 'faster', 'fast', 'medium', 'slow', 'slower', 'veryslow')]
    [string] $Preset = 'medium',

    # With -Compress, also keep the uncompressed H.264 recording next to it.
    [switch] $KeepOriginal,

    # Cookies exported from your own browser (cookies.txt or JSON), so the page
    # opens logged in. The file is a login: keep it private.
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $Cookies,

    # What to press on a site's cookie banner; 'keep' leaves it on screen.
    [ValidateSet('reject', 'accept', 'keep')]
    [string] $CookieBanner = 'reject',

    # Rebuild the image even if it already exists.
    [switch] $Build,

    # Record the page's sound only, to an .m4a or .mp3; presses Spotify's play
    # button instead of going fullscreen.
    [switch] $Audio,

    # Bitrate in kbit/s for -Audio; default 256 for m4a, 320 for mp3. 320 is
    # mp3 only: ffmpeg's AAC encoder spends at most ~265 kbit/s on 44.1 kHz
    # stereo, so it would be 256 in disguise.
    [ValidateSet(128, 160, 192, 224, 256, 320)]
    [int] $AudioBitrate,

    # File format for -Audio: m4a (AAC) or mp3.
    [ValidateSet('m4a', 'mp3')]
    [string] $AudioFormat = 'm4a',

    # Only check the options and exit: deploy-play-action.ps1 runs this
    # locally, so a bad combination fails before anything starts remotely.
    [Parameter(DontShow, ParameterSetName = 'Record')]
    [switch] $ValidateOnly,

    # Print the full usage guide and exit.
    [Parameter(Mandatory, ParameterSetName = 'Help')]
    [Alias('h')]
    [switch] $Help
)

if ($Help) {
    Write-Host @'
record.ps1 - records a web page in full-screen Chrome, with sound, to an MP4
             (or only its sound to an .m4a or .mp3, see AUDIO ONLY)

USAGE
  .\record.ps1 <Url> [options]
  .\record.ps1 -Help

  Chrome runs in kiosk mode (no tabs or address bar) inside a Docker
  container. When the recording ends, the MP4 is copied to this machine and
  the container is removed. Without -Duration it records until you press
  Ctrl+C; whatever was recorded up to then is kept.

WHAT TO RECORD
  <Url>               Page to open: http://, https:// or file://  (required)
  -Duration <s>       Seconds to record, 1-86400. Omit to record until Ctrl+C.
  -DurationMin <m>    The same in minutes, up to 1440; fractions are allowed
                      (1.5 = 90 s). Not together with -Duration.
  -Warmup <s>         Seconds the page gets to load before recording starts.
                      Default 3.

WHERE TO SAVE
  -Dir <folder>       Folder to save in, created if missing. Default
                      .\recordings (under the current folder).
  -Title <name>       File name without extension: <Dir>\<name>.mp4
                      Default name: recording-<timestamp>-<id>.mp4
  -Output <path>      Full path of the MP4 instead; not with -Dir or -Title.
                      A file that already exists is overwritten.

PICTURE
  -Width <px>         Video width, even number. Default 1920.
  -Height <px>        Video height, even number. Default 1080.
  -Fps <n>            Frames per second, 1-120. Default 60, which suits 30 and
                      60 fps videos (most of YouTube). Use 50 for 25/50 fps
                      sources such as European TV, or the video judders.

PAGE HANDLING
  -CookieBanner <x>   What to press on the site's cookie banner:
                        reject  reject optional cookies (default)
                        accept  accept, for pages that only work after it
                        keep    leave the banner on screen
  -Cookies <file>     Cookies exported from your own browser (cookies.txt or
                      JSON, e.g. with "Get cookies.txt LOCALLY"), so the page
                      opens logged in. The file IS a login: keep it private.
                      It is copied into the container, never mounted.
  -KeepPage           Record the whole page instead of the fullscreen video
                      (YouTube and pages with a .play-action player).

AUDIO ONLY
  -Audio              Record only the page's sound, to <name>.m4a (AAC) or
                      <name>.mp3, 44.1 kHz stereo. Nothing goes
                      fullscreen; -Width, -Height, -Fps and -KeepPage
                      don't matter. After the page loads, Spotify's
                      play button is pressed: the
                      album/playlist page's own big button, else the
                      bottom-bar play/pause toggle; never one that already
                      reads "Pauza"/"Pause" (= playing). Other pages: a
                      .play-action button; YouTube simply plays.
                      Recording starts just before the click, so the file
                      opens with a moment of silence.
  -AudioFormat <f>    m4a (default): AAC, the codec Spotify streams, so the
                      smallest file for the same quality. mp3: plays on
                      anything (old players, car radios), constant bitrate.
  -AudioBitrate <k>   Bitrate in kbit/s: 128, 160, 192, 224, 256, and 320
                      for mp3 only. Default 256 for m4a, 320 for mp3.
                      Spotify's web player streams at most AAC 256 (Premium;
                      128 on Free); use 128 for spoken word or Free.
  Length: without -Duration/-DurationMin on a Spotify album or playlist,
  the track list's times are added up (+5 s, +0.25 s per track), shuffle
  and repeat are switched off and playback starts from the first track, so
  the file holds exactly the album. Elsewhere it records until Ctrl+C;
  Ctrl+C always stops early.
  Works with -Duration/-DurationMin, -Cookies, -CookieBanner, -Title, -Dir
  and -Output (named .m4a or .mp3 to match); not with -Compress or
  -KeepOriginal. Spotify needs a login: pass your exported cookies with
  -Cookies.

COMPRESSION (runs after recording)
  -Compress           Re-encode to H.265: usually 30-45% smaller, but takes
                      about 1-2.5 minutes per minute of video on all cores.
                      Ctrl+C or a failure keeps the H.264 file; so does an
                      H.265 file that came out bigger.
  -Crf <0-51>         H.265 quality: lower is better and bigger. Default 26;
                      28 is fine for talking heads.
  -Preset <name>      H.265 speed: ultrafast, superfast, veryfast, faster,
                      fast, medium (default), slow, slower, veryslow.
                      Slower presets give smaller files.
  -KeepOriginal       With -Compress, also keep the H.264 file as
                      <name>.h264.mp4.

DOCKER
  -Image <name>       Docker image to run. Default chrome-rec.
  -Build              Rebuild the image, e.g. after editing the Dockerfile,
                      browse.py or entrypoint.sh. It is built automatically
                      when it doesn't exist yet.

WHAT HAPPENS ON THE PAGE
  YouTube (watch, shorts, live, youtu.be links):
    "Before you continue" dialog pre-accepted, ads waited out (up to 2 min),
    the original audio track picked instead of an auto-dub, subtitles off,
    fullscreen (unless -KeepPage), rewound to 0:00 and started about a second
    into the recording.
  Other pages:
    The cookie banner is handled as -CookieBanner says (it keeps looking for
    up to 12 s, since banners appear late). A .play-action play button, if
    there is one, is clicked about a second into the recording, followed by
    the player's fullscreen button (unless -KeepPage).
  The lines starting with "browse:" at the end of the run say what was done.

PROGRESS
  Preparing page... 00:05            page loading, banners, ads
  REC 00:12 / 00:30 (00:18 left)     recording with -Duration
  REC 00:12 (Ctrl+C to stop)         recording without -Duration
  H.265 12:34 / 90:00 (14%, ETA ..)  compressing

EXAMPLES
  .\record.ps1 https://example.com -Duration 30
  .\record.ps1 https://example.com -Title "Evening news"
  .\record.ps1 https://tv.example/live -Fps 50 -Title news -DurationMin 60
  .\record.ps1 https://example.com -Dir D:\videos\tv -Title "Evening news"
  .\record.ps1 https://www.youtube.com/watch?v=... -Compress
  .\record.ps1 https://site.com/page -Cookies .\site-cookies.txt -Duration 600
  .\record.ps1 https://example.com -Width 1280 -Height 720 -Output D:\vids\demo.mp4
  .\record.ps1 https://example.com/... -Audio -Cookies .\cookies.txt -Title album

GOOD TO KNOW
  Size: about 7.5 MB per minute for busy 1080p30 video, more at 60 fps; a
  static page takes a few hundred KB per minute. -Fps 30 or -Compress
  make files smaller.
  CPU: 1080p at 50-60 fps needs about 3.5 cores. Lower -Fps or the size on
  small machines.
  Sound and picture are lined up to within about 40 ms. If sound can't be
  captured, the video is saved without it.
  Asian and Arabic text shows as boxes unless you add fonts to the Dockerfile.

More detail in README.md next to this script.
'@
    exit 0
}

# Not 'Stop': Windows PowerShell 5.1 turns every stderr line of a native
# command into an error record, so harmless docker/Xvfb warnings would abort
# the script. Native failures are checked through $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'

if ($PSBoundParameters.ContainsKey('DurationMin')) {
    if ($PSBoundParameters.ContainsKey('Duration')) {
        throw 'Use either -Duration or -DurationMin, not both.'
    }
    $Duration = [math]::Max(1, [int][math]::Round($DurationMin * 60))
}

if ($Audio -and ($Compress -or $KeepOriginal)) {
    throw '-Compress and -KeepOriginal re-encode video; they do not apply to -Audio.'
}
foreach ($p in 'AudioBitrate', 'AudioFormat') {
    if (-not $Audio -and $PSBoundParameters.ContainsKey($p)) { throw "-$p only applies together with -Audio." }
}
if (-not $AudioBitrate) { $AudioBitrate = if ($AudioFormat -eq 'mp3') { 320 } else { 256 } }
if ($AudioFormat -eq 'm4a' -and $AudioBitrate -gt 256) {
    throw "AAC (m4a) goes up to 256 kbit/s here; use -AudioBitrate 256, or -AudioFormat mp3 for 320."
}
$ext = if ($Audio) { ".$AudioFormat" } else { '.mp4' }

# libx264 with yuv420p rejects odd frame sizes.
if ($Width % 2 -or $Height % 2) {
    throw "Width and Height must be even numbers (got ${Width}x${Height})."
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# The suffix keeps recordings started in the same second apart.
$runId = "$stamp-$('{0:x4}' -f (Get-Random -Maximum 0x10000))"
if ($Output -and ($Title -or $Dir)) {
    throw '-Output is a full path; use it without -Title and -Dir.'
}
if (-not $Output) {
    if (-not $Dir) { $Dir = Join-Path (Get-Location) 'recordings' }
    $file = if ($Title) { "$Title$ext" } else { "recording-$runId$ext" }
    $Output = Join-Path $Dir $file
}
elseif ($Audio -and [IO.Path]::GetExtension($Output) -ne $ext) {
    throw "-Audio -AudioFormat $AudioFormat saves an $ext file; give -Output an $ext name (got $Output)."
}
if ($ValidateOnly) { exit 0 }
$Output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
New-Item -ItemType Directory -Force (Split-Path $Output) -ErrorAction Stop | Out-Null

$imageEnv = docker image inspect -f '{{json .Config.Env}}' $Image 2> $null
$missing = $LASTEXITCODE -ne 0
# An image built before audio-only mode existed would quietly record video,
# one built before mp3 support an .m4a under the .mp3 name.
$outdated = $Audio -and -not $missing -and ("$imageEnv" -notmatch '"AUDIO_ONLY=' -or
    ($AudioFormat -eq 'mp3' -and "$imageEnv" -notmatch '"AUDIO_FORMAT='))
if ($Build -or $missing -or $outdated) {
    Write-Host "Building image $Image..."
    # deploy-play-action.ps1 compares this label with the server's checkout
    # to tell whether a pulled change needs a rebuild.
    $label = @()
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $rev = git -C $PSScriptRoot log -1 --format=%H -- Dockerfile browse.py entrypoint.sh 2> $null
        if ($LASTEXITCODE -eq 0 -and $rev) { $label = '--label', "play-action.rev=$rev" }
    }
    # Set by deploy-play-action.ps1 when the image is old: the cache would
    # hand back the same Chrome layer, so the base image and every step are
    # fetched again.
    $refresh = $env:PLAY_ACTION_REFRESH -eq '1'
    $built = docker image inspect -f '{{index .Config.Labels "play-action.rev"}}' $Image 2> $null
    docker build -t $Image @label @(if ($refresh) { '--pull', '--no-cache' }) $PSScriptRoot
    # --pull needs the registry, and a working image beats no recording; the
    # next run tries the refresh again. The existing image only counts when
    # it holds this code, else a cached build brings the code in (the
    # changed layers are only the copied scripts).
    if ($LASTEXITCODE -ne 0 -and $refresh -and -not $missing -and -not $outdated) {
        if ($rev -and $built -eq $rev) {
            Write-Warning 'Refreshing the image failed; recording with the existing one.'
            $global:LASTEXITCODE = 0
        }
        else {
            Write-Warning 'Refreshing the image failed; building it from the cache instead.'
            docker build -t $Image @label $PSScriptRoot
            # Offline even the cached build fails: Docker looks the FROM image
            # up in the registry, and builds don't keep it under its name.
            if ($LASTEXITCODE -ne 0) {
                Write-Warning 'That failed too; recording with the existing image, which was built from older code.'
                $global:LASTEXITCODE = 0
            }
        }
    }
    if ($LASTEXITCODE -ne 0) { throw 'docker build failed.' }
}

$name = "chrome-rec-$runId"
$runArgs = @(
    'create', '--name', $name, '--shm-size=2g',
    '-e', "URL=$Url",
    '-e', "WIDTH=$Width", '-e', "HEIGHT=$Height", '-e', "FPS=$Fps",
    '-e', "WARMUP=$Warmup",
    '-e', "YT_FULLSCREEN=$(if ($KeepPage -or $Audio) { 0 } else { 1 })",
    '-e', "COOKIE_BANNER=$CookieBanner"
)
if ($Audio) {
    $runArgs += '-e', 'AUDIO_ONLY=1', '-e', "AUDIO_BITRATE=$AudioBitrate", '-e', "AUDIO_FORMAT=$AudioFormat",
        '-e', "OUT=/out/recording$ext"
}
if ($Duration) { $runArgs += '-e', "DURATION=$Duration" }
if ($Cookies) { $runArgs += '-e', 'COOKIES=/tmp/cookies.txt' }
$runArgs += $Image

docker @runArgs | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'docker create failed.' }
if ($Cookies) {
    # Copied rather than mounted: the copy dies with the container (`rm -v` below).
    docker cp (Resolve-Path -LiteralPath $Cookies).Path "${name}:/tmp/cookies.txt" *> $null
    if ($LASTEXITCODE -ne 0) { docker rm -v $name *> $null; throw 'Could not copy the cookies file into the container.' }
}
docker start $name | Out-Null
if ($LASTEXITCODE -ne 0) { docker rm -v $name *> $null; throw 'docker start failed.' }

$length = if ($Duration) { "$Duration s" }
    elseif ($Audio -and $Url -match '^https?://open\.spotify\.com/(intl-[a-z-]+/)?(album|playlist)/') { 'as long as the album/playlist (else until Ctrl+C)' }
    else { 'until Ctrl+C' }
if ($Audio) {
    $codec = if ($AudioFormat -eq 'mp3') { 'MP3' } else { 'AAC' }
    Write-Host "Recording the sound of $Url as $codec $AudioBitrate kbit/s, $length"
}
else {
    Write-Host "Recording $Url at ${Width}x${Height} ${Fps} fps, $length"
}

function Format-Time([int] $seconds) {
    '{0:00}:{1:00}' -f [math]::Floor($seconds / 60), ($seconds % 60)
}

function Format-Size([long] $bytes) {
    if ($bytes -ge 1GB) { '{0:N2} GB' -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { '{0:N1} MB' -f ($bytes / 1MB) }
    else { '{0:N0} KB' -f ($bytes / 1KB) }
}

# Runs in a throwaway container fed by `docker cp`, because bind mounts are not
# reliable on every Docker Desktop setup.
function Compress-Recording([string] $source, [string] $target) {
    $encName = "$name-x265"
    $script = 'ffprobe -v error -show_entries format=duration -of default=nw=1 /tmp/in.mp4 && ' +
        'ffmpeg -hide_banner -v error -nostats -progress pipe:1 -y -i /tmp/in.mp4 -map 0 ' +
        "-c:v libx265 -preset $Preset -crf $Crf -tag:v hvc1 -x265-params log-level=error " +
        '-c:a copy -movflags +faststart /tmp/out.mp4'
    docker create --name $encName --entrypoint sh $Image -c $script | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    try {
        docker cp $source "${encName}:/tmp/in.mp4" *> $null
        if ($LASTEXITCODE -ne 0) { return $false }

        $total = 0.0
        $clock = [Diagnostics.Stopwatch]::StartNew()
        docker start -a $encName 2>$null | ForEach-Object {
            if ($_ -match '^duration=([\d.]+)') { $total = [double]$Matches[1] }
            elseif ($_ -match '^out_time_us=(\d+)' -and $total -gt 0) {
                $done = [math]::Min([double]$Matches[1] / 1e6, $total)
                $pct = $done / $total
                $eta = if ($pct -gt 0.01) { Format-Time ($clock.Elapsed.TotalSeconds * (1 - $pct) / $pct) } else { '--:--' }
                $line = "  H.265 $(Format-Time $done) / $(Format-Time $total)  ({0:P0}, ETA $eta)" -f $pct
                Write-Host -NoNewline ("`r" + $line.PadRight(60))
            }
        }
        if ((docker inspect -f '{{.State.ExitCode}}' $encName) -ne '0') { Write-Host ''; return $false }
        Write-Host ("`r" + "  H.265 $(Format-Time $total) / $(Format-Time $total)  (100%)".PadRight(60))

        docker cp "${encName}:/tmp/out.mp4" $target *> $null
        return $LASTEXITCODE -eq 0
    }
    finally {
        docker rm -f -v $encName *> $null
    }
}

# The copy-out lives in `finally` so that Ctrl+C, which ends the wait loop,
# still stops the recorder cleanly and saves what was recorded so far.
$startedAt = $null
$limit = $Duration
$setup = [Diagnostics.Stopwatch]::StartNew()
try {
    while ((docker inspect -f '{{.State.Running}}' $name) -eq 'true') {
        # The markers are on the container's stdout; its stderr is only noise.
        if (-not $startedAt) {
            $log = docker logs $name 2>$null
            if ($log | Select-String -SimpleMatch 'recording started' -Quiet) {
                $startedAt = Get-Date
                # -Audio without a length: the recorder took it from the track
                # list. Not stored in $Duration: its ValidateRange re-checks on
                # assignment and a playlist over 24 h would throw.
                $auto = $log | Select-String '^recording length: (\d+) s' | Select-Object -First 1
                if ($auto -and -not $Duration) {
                    $limit = [int]$auto.Matches[0].Groups[1].Value
                    Write-Host ("`r" + "  Length from the Spotify track list: $(Format-Time $limit)".PadRight(60))
                }
            }
        }
        $line = if (-not $startedAt) {
            "  Preparing page... $(Format-Time $setup.Elapsed.TotalSeconds)"
        }
        else {
            $elapsed = [int]((Get-Date) - $startedAt).TotalSeconds
            if ($limit) {
                $elapsed = [math]::Min($elapsed, $limit)
                "  REC $(Format-Time $elapsed) / $(Format-Time $limit)  ($(Format-Time ($limit - $elapsed)) left)"
            }
            else {
                "  REC $(Format-Time $elapsed)  (Ctrl+C to stop)"
            }
        }
        Write-Host -NoNewline ("`r" + $line.PadRight(60))
        Start-Sleep -Milliseconds 500
    }
}
finally {
    # The timer starts on a polled log line, so it can trail ffmpeg by up to a
    # poll interval; a completed timed recording did record the full length.
    $finished = (docker inspect -f '{{.State.Running}} {{.State.ExitCode}}' $name) -eq 'false 0'
    # A stopped container exits 0 too; only a run that lasted its length is complete.
    if ($finished -and $startedAt -and $limit -and ((Get-Date) - $startedAt).TotalSeconds -ge $limit - 2) {
        Write-Host -NoNewline ("`r" + "  REC $(Format-Time $limit) / $(Format-Time $limit)  (00:00 left)".PadRight(60))
    }
    Write-Host ''
    # Generous timeout: after a stop the container still trims the file's end.
    docker stop -t 120 $name *> $null
    docker logs $name 2>$null | Where-Object { "$_" -like 'browse: *' } | ForEach-Object { Write-Host "  $_" }
    $exitCode = [int](docker inspect -f '{{.State.ExitCode}}' $name)
    docker cp "${name}:/out/recording$ext" $Output *> $null
    $copied = $LASTEXITCODE -eq 0
    if ($Audio -and -not $copied) {
        if ($AudioFormat -eq 'mp3') {
            # The mp3 capture already is the final file, only not renamed.
            # Through a temp name: a recording already saved under $Output
            # must survive a capture that turns out empty.
            $part = "$Output.part"
            docker cp "${name}:/out/recording.audio.mp3" $part *> $null
            # An empty or header-only capture is no recording; the header
            # alone is ~1.1 KB at 320 kbit/s, 8 KB is 0.2-0.5 s of sound.
            $copied = $LASTEXITCODE -eq 0 -and (Get-Item -LiteralPath $part).Length -gt 8KB
            if ($copied) { Move-Item -LiteralPath $part $Output -Force }
            Remove-Item -LiteralPath $part -ErrorAction SilentlyContinue
        }
        else {
            # The raw capture survives a failed repackaging; it plays in most players.
            $raw = [IO.Path]::ChangeExtension($Output, '.aac')
            docker cp "${name}:/out/recording.audio.aac" $raw *> $null
            if ($LASTEXITCODE -eq 0) { Write-Host "Kept the unprocessed capture as $raw" }
        }
    }
    if (-not $copied -or $exitCode -ne 0) {
        Write-Host 'Container log:'
        docker logs --tail 30 $name 2>&1 | ForEach-Object { Write-Host "  $_" }
    }
    docker rm -v $name *> $null

    if ($copied) {
        Write-Host "Saved $Output ($(Format-Size (Get-Item -LiteralPath $Output).Length))"
    }
    else {
        Write-Error 'No recording was produced (stopped during warmup, or the recorder failed).'
    }
}
if (-not $copied) { exit 1 }

if ($copied -and $Compress) {
    $original = [IO.Path]::ChangeExtension($Output, '.h264.mp4')
    Move-Item -Force -LiteralPath $Output $original
    Write-Host "Compressing to H.265 (preset $Preset, crf $Crf)..."
    $kept = $false
    # `finally` because Ctrl+C skips any else-branch: the H.264 recording must
    # end up back under the requested name whenever no better file replaced it.
    try {
        if (Compress-Recording $original $Output) {
            $before = (Get-Item -LiteralPath $original).Length
            $after = (Get-Item -LiteralPath $Output).Length
            if ($after -lt $before) {
                Write-Host ("Saved $Output ($(Format-Size $after), {0:P0} smaller)" -f (1 - $after / $before))
                $kept = $true
                if ($KeepOriginal) { Write-Host "Kept original $original" } else { Remove-Item -LiteralPath $original }
            }
            else {
                Write-Host "H.265 came out bigger ($(Format-Size $after)); keeping the H.264 recording."
            }
        }
        else {
            Write-Error 'Compression failed; keeping the H.264 recording.'
        }
    }
    finally {
        if (-not $kept) {
            Remove-Item -LiteralPath $Output -ErrorAction SilentlyContinue
            Move-Item -Force -LiteralPath $original $Output
            Write-Host ''
            Write-Host "Saved $Output ($(Format-Size (Get-Item -LiteralPath $Output).Length))"
        }
    }
}
