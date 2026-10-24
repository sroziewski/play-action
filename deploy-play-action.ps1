<#
.SYNOPSIS
Records with play-action on a remote Linux server: connects over SSH, sets the
server up, starts record.ps1 there in a screen session and downloads the
finished file.

.DESCRIPTION
Takes every option of record.ps1 (same names, same checks) plus the server's
-Ip, -User, -Key and -Port. On the server it checks for Linux x86_64, git and
Docker (or installs them with -Setup), clones or updates the public
repository, gets PowerShell if missing, checks the free disk space, rebuilds
the Docker image when the code or the image's age calls for it, uploads the
-Cookies file to a private folder and starts the recording in a screen
session, so it survives a dropped connection. This terminal follows the
progress; when the recording ends the file is downloaded to -LocalDir.
Ctrl+C only stops following: -Attach follows again, -Stop ends the recording
early (and still downloads what was recorded).

The server runs the code pushed to the repository, not local edits.

.EXAMPLE
.\deploy-play-action.ps1 -Setup -Ip 203.0.113.7 -User me -Key ~\.ssh\id_ed25519 -Port 22
Installs Docker, git, screen and PowerShell on an Ubuntu server (passwordless sudo).

.EXAMPLE
.\deploy-play-action.ps1 https://example.com/... -Audio -Cookies .\cookies.txt -Ip 203.0.113.7 -User me -Key ~\.ssh\id_ed25519 -Port 22

.EXAMPLE
.\deploy-play-action.ps1 https://example.com -DurationMin 60 -Fps 50 -Title news -Ip 203.0.113.7 -User me -Key .\server.key -Port 2222 -Detach
Starts the recording and returns at once.

.EXAMPLE
.\deploy-play-action.ps1 -Attach -Ip 203.0.113.7 -User me -Key .\server.key -Port 2222
Follows the latest recording again and downloads it when it ends.

.EXAMPLE
.\deploy-play-action.ps1 -Stop -Ip 203.0.113.7 -User me -Key .\server.key -Port 2222
Ends the latest recording early and downloads it.
#>
# 'Setup' as the default: `-Setup -Ip ...` alone fits both Setup and Record,
# and PowerShell would pick Record and ask for a Url. A call with a Url
# still resolves to Record, since Url belongs to no other set.
[CmdletBinding(DefaultParameterSetName = 'Setup')]
param(
    # Server address (IP or host name).
    [Parameter(Mandatory, ParameterSetName = 'Record')]
    [Parameter(Mandatory, ParameterSetName = 'Attach')]
    [Parameter(Mandatory, ParameterSetName = 'Stop')]
    [Parameter(Mandatory, ParameterSetName = 'Setup')]
    [ValidateNotNullOrEmpty()]
    [string] $Ip,

    # Login on the server.
    [Parameter(Mandatory, ParameterSetName = 'Record')]
    [Parameter(Mandatory, ParameterSetName = 'Attach')]
    [Parameter(Mandatory, ParameterSetName = 'Stop')]
    [Parameter(Mandatory, ParameterSetName = 'Setup')]
    [ValidateNotNullOrEmpty()]
    [string] $User,

    # Private key file for the login.
    [Parameter(Mandatory, ParameterSetName = 'Record')]
    [Parameter(Mandatory, ParameterSetName = 'Attach')]
    [Parameter(Mandatory, ParameterSetName = 'Stop')]
    [Parameter(Mandatory, ParameterSetName = 'Setup')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $Key,

    # SSH port.
    [Parameter(Mandatory, ParameterSetName = 'Record')]
    [Parameter(Mandatory, ParameterSetName = 'Attach')]
    [Parameter(Mandatory, ParameterSetName = 'Stop')]
    [Parameter(Mandatory, ParameterSetName = 'Setup')]
    [ValidateRange(1, 65535)]
    [int] $Port,

    # Folder on the server, relative to the login's home or absolute.
    [ValidateNotNullOrEmpty()]
    [string] $RemoteDir = 'play-action',

    [ValidateNotNullOrEmpty()]
    [string] $Repo = 'https://github.com/sroziewski/play-action.git',

    # Where finished recordings are downloaded to.
    [ValidateNotNullOrEmpty()]
    [string] $LocalDir = 'recordings',

    # Rebuild the server's Docker image once it is older than this.
    [Parameter(ParameterSetName = 'Record')]
    [ValidateRange(1, 3650)]
    [int] $MaxImageAgeDays = 30,

    # Install Docker, git, screen and PowerShell on an Ubuntu server first
    # (needs passwordless sudo). On its own, or together with a recording.
    # Not mandatory in 'Setup': connection options alone land in that set,
    # and a mandatory switch there would be prompted for, which can't be
    # answered. The script explains instead (see the start of `end`).
    [Parameter(ParameterSetName = 'Record')]
    [Parameter(ParameterSetName = 'Setup')]
    [switch] $Setup,

    # Start the recording and return without following it.
    [Parameter(ParameterSetName = 'Record')]
    [switch] $Detach,

    # Leave the finished recording on the server only.
    [switch] $NoDownload,

    # Follow the latest recording on the server again.
    [Parameter(Mandatory, ParameterSetName = 'Attach')]
    [switch] $Attach,

    # End the latest recording early; what was recorded is kept.
    [Parameter(Mandatory, ParameterSetName = 'Stop')]
    [switch] $Stop,

    # With -Attach or -Stop: the recording's id instead of the latest.
    [Parameter(ParameterSetName = 'Attach')]
    [Parameter(ParameterSetName = 'Stop')]
    [ValidatePattern('^\d{8}-\d{6}-[0-9a-f]{4}$')]
    [string] $Run,

    # Print the usage guide, followed by record.ps1's.
    [Parameter(Mandatory, ParameterSetName = 'Help')]
    [Alias('h')]
    [switch] $Help
)

# record.ps1's own parameters, with their validation, become this script's:
# nothing to keep in sync by hand, and Tab completion offers them all.
DynamicParam {
    $dict = [Management.Automation.RuntimeDefinedParameterDictionary]::new()
    $record = Join-Path $PSScriptRoot 'record.ps1'
    if (-not (Test-Path -LiteralPath $record)) { return $dict }
    $common = [Management.Automation.PSCmdlet]::CommonParameters + [Management.Automation.PSCmdlet]::OptionalCommonParameters
    foreach ($p in (Get-Command $record).Parameters.Values) {
        if ($p.Name -in $common -or $p.Name -in 'Help', 'ValidateOnly') { continue }
        $attributes = [Collections.ObjectModel.Collection[Attribute]]::new()
        foreach ($a in $p.Attributes) {
            if ($a -is [Management.Automation.ParameterAttribute]) {
                $copy = [Management.Automation.ParameterAttribute]::new()
                $copy.ParameterSetName = 'Record'
                $copy.Mandatory = $a.Mandatory
                $copy.Position = $a.Position
                $attributes.Add($copy)
            }
            else { $attributes.Add($a) }
        }
        $dict.Add($p.Name, [Management.Automation.RuntimeDefinedParameter]::new($p.Name, $p.ParameterType, $attributes))
    }
    $dict
}

end {
    # As in record.ps1: Windows PowerShell 5.1 turns native stderr lines into
    # errors, so failures are checked through $LASTEXITCODE instead.
    $ErrorActionPreference = 'Continue'
    $record = Join-Path $PSScriptRoot 'record.ps1'

    if ($Help) {
        Write-Host @'
deploy-play-action.ps1 - records with play-action on a remote Linux server

USAGE
  .\deploy-play-action.ps1 <Url> [record.ps1 options] -Ip <ip> -User <login> -Key <file> -Port <port>
  .\deploy-play-action.ps1 -Setup  -Ip ... -User ... -Key ... -Port ...
  .\deploy-play-action.ps1 -Attach -Ip ... -User ... -Key ... -Port ... [-Run <id>]
  .\deploy-play-action.ps1 -Stop   -Ip ... -User ... -Key ... -Port ... [-Run <id>]

CONNECTION (all required)
  -Ip <address>       Server IP or host name.
  -User <login>       Login on the server; it must be allowed to use Docker.
  -Key <file>         Private key for the login (OpenSSH format).
  -Port <port>        SSH port, e.g. 22.

WHAT HAPPENS
  1. Checks the server: Linux x86_64, git, Docker usable by the login.
  2. Clones the repository into ~/play-action (or updates it), and gets
     PowerShell 7 into ~/.play-action if the server has none (no sudo).
  3. Checks the free disk space (3 GB, or 5 GB when the image is built), and
     rebuilds the Docker image when the pulled code changed it or it is
     older than -MaxImageAgeDays (default 30), so Chrome stays current.
  4. Uploads the -Cookies file into a private folder; it is deleted again
     when the recording ends.
  5. Starts record.ps1 there in a screen session (play-action-<id>), so it
     keeps recording if the connection drops and you can watch it on the
     server with screen -r. The session closes by itself when the
     recording is saved; the file stays in the server's recordings folder
     (or -Dir/-Output). Without screen installed it runs as a plain
     background process. The first run builds the Docker image (minutes).
  6. Follows the progress here and downloads the file when it is done.

OPTIONS OF THIS SCRIPT
  -Setup              Install what is missing on an Ubuntu server first:
                      Docker (from Docker's repository; a snap Docker is
                      removed), git, screen, PowerShell 7, the login in the
                      docker group, and no automatic Docker restarts by
                      unattended upgrades. Needs passwordless sudo. Alone
                      or together with a recording.
  -Detach             Start and return at once; follow later with -Attach.
  -Attach             Follow the latest recording again (and download it).
  -Stop               End the latest recording early, as Ctrl+C would; it
                      is still saved and downloaded.
  -Run <id>           With -Attach/-Stop: that recording instead of the
                      latest (the id is printed when it starts).
  -NoDownload         Leave the finished file on the server only.
  -LocalDir <folder>  Where downloads go. Default .\recordings.
  -RemoteDir <path>   Folder on the server. Default play-action (in home).
  -Repo <url>         Repository to clone. Default the public play-action.
  -MaxImageAgeDays <n>  Rebuild an older image. Default 30.

  Ctrl+C only stops following; the recording carries on on the server.
  -Dir and -Output name paths on the server, relative to its play-action
  folder. The server runs the code pushed to the repository.

EXAMPLES
  .\deploy-play-action.ps1 -Setup -Ip 203.0.113.7 -User me -Key ~\.ssh\id_ed25519 -Port 22
  .\deploy-play-action.ps1 https://example.com/... -Audio -Cookies .\cookies.txt -Ip 203.0.113.7 -User me -Key ~\.ssh\id_ed25519 -Port 22
  .\deploy-play-action.ps1 https://example.com -DurationMin 60 -Title news -Ip 203.0.113.7 -User me -Key .\server.key -Port 2222 -Detach
  .\deploy-play-action.ps1 -Stop -Ip 203.0.113.7 -User me -Key .\server.key -Port 2222

All other options are record.ps1's, with the same names and meaning:
'@
        & $record -Help
        exit 0
    }

    if ($PSCmdlet.ParameterSetName -eq 'Setup' -and -not $Setup) {
        Write-Host 'Say what to do on the server: a page to record (the first argument), -Setup, -Attach or -Stop.'
        Write-Host 'For example:  .\deploy-play-action.ps1 https://example.com -Duration 60 -Ip ... -User ... -Key ... -Port ...'
        Write-Host 'All options:  .\deploy-play-action.ps1 -Help'
        exit 1
    }

    $recordNames = (Get-Command $record).Parameters.Keys |
        Where-Object { $_ -notin [Management.Automation.PSCmdlet]::CommonParameters + [Management.Automation.PSCmdlet]::OptionalCommonParameters }
    if ($PSCmdlet.ParameterSetName -eq 'Record') {
        # Parameter validation already ran; this adds record.ps1's checks of
        # how options combine (m4a at 320, -Output's extension, ...).
        $local = @{}
        foreach ($name in $PSBoundParameters.Keys) {
            if ($name -in $recordNames) { $local[$name] = $PSBoundParameters[$name] }
        }
        try { & $record @local -ValidateOnly }
        catch {
            Write-Host "Error: $($_.Exception.Message)"
            exit 1
        }
    }

    foreach ($tool in 'ssh', 'scp') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool not found. Install the OpenSSH client (Settings > System > Optional features > OpenSSH Client)."
        }
    }

    # The remote scripts go to ssh's stdin and its output comes back as text;
    # both sides are UTF-8, but 5.1 sends ASCII and both read the console's
    # code page (852 here), which garbles a title with Polish letters.
    # Under code page 65001, 5.1 also writes a BOM ahead of piped text, taken
    # from the console's input encoding; bash would read it as part of the
    # first command and skip `set -euo pipefail`.
    $savedEncodings = $OutputEncoding, [Console]::OutputEncoding, [Console]::InputEncoding
    try {
    $OutputEncoding = [Text.UTF8Encoding]::new($false)
    # A process without a console has no code page to set (or to garble).
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    }
    catch {}

    $Ip = $Ip.Trim('[', ']')
    $Key = (Resolve-Path -LiteralPath $Key).Path
    $sshOptions = @('-i', $Key, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30')
    $target = "$User@$Ip"
    # scp needs brackets around an IPv6 address; ssh takes it bare.
    $scpTarget = if ($Ip -match ':') { "$User@[$Ip]" } else { $target }

    # "-" stands for empty: ssh joins its arguments into one command line, so
    # an empty one would vanish and shift the rest.
    function ConvertTo-Base64([string] $text) {
        if (-not $text) { return '-' }
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
    }

    # Every remote step is a fixed bash script on stdin; values travel as
    # base64 arguments, so nothing the user typed is ever parsed by a shell.
    # PowerShell ends piped text with CRLF; the closing comment line takes
    # the stray CR, which would otherwise end up in the last command.
    function Invoke-Remote([string] $script, [string[]] $arguments) {
        (($script -replace "`r?`n", "`n") + "`n#") | ssh @sshOptions -p $Port $target bash -s -- @arguments
    }

    function Get-Text($output) { @($output | ForEach-Object { "$_" }) }

    # ssh itself exits 255 when it cannot connect or log in, and Windows'
    # ssh -1 when the server drops the connection; any other failure comes
    # from the script on the server.
    function Test-SshFailure([int] $code) { $code -eq 255 -or $code -eq -1 }

    function Assert-Remote($output, [string] $what) {
        if ($LASTEXITCODE -eq 0) { return }
        $text = (Get-Text $output) -join "`n"
        if (Test-SshFailure $LASTEXITCODE) {
            if ($text -match 'UNPROTECTED PRIVATE KEY|bad permissions') {
                Write-Host "The key file is readable by other users, so ssh refuses it. Fix with:"
                Write-Host "  icacls `"$Key`" /inheritance:r /grant:r `"$($env:USERNAME):R`""
            }
            elseif ($text -match 'Permission denied') { Write-Host "The server refused the login: check -User and -Key." }
            elseif ($text -match 'Connection refused|timed out|Could not resolve|No route|Network is unreachable') {
                Write-Host "Could not reach ${Ip}:$Port. Check -Ip, -Port and the server's firewall."
            }
            $text -split "`n" | Where-Object { $_ } | ForEach-Object { Write-Host "  $_" }
            throw "Connecting to $target failed."
        }
        $messages = $text -split "`n" | Where-Object { $_ -like 'play-action: error:*' }
        # Progress lines (play-action: ...) were shown live already.
        if (-not $messages) { $messages = $text -split "`n" | Where-Object { $_ -and $_ -notlike 'play-action:*' } | Select-Object -Last 15 }
        $messages | ForEach-Object { Write-Host "  $_" }
        throw "$what failed on the server (exit $LASTEXITCODE)."
    }

    $setupScript = @'
set -euo pipefail
fail() { echo "play-action: error: $*" >&2; exit 3; }
say() { echo "play-action: $*"; }
me=$(id -un)
sudo -n true 2>/dev/null || fail "-Setup needs passwordless sudo for $me"
. /etc/os-release
[[ $ID == ubuntu ]] || fail "-Setup supports Ubuntu; this server runs ${PRETTY_NAME:-$ID}"
# On 24.04 needrestart restarts services even in non-interactive runs and
# ignores NEEDRESTART_MODE (LP #2059337); suspending it is what holds.
# Passed through env, not sudo -E, which sudoers without SETENV refuse.
apt=(sudo -n env DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=yes apt-get -y -q -o DPkg::Lock::Timeout=300)
# The lock timeout doesn't cover the lists lock that `update` takes, and a
# fresh cloud server is often still running its own apt for a while.
apt_log=$(mktemp)
trap 'rm -f "$apt_log"' EXIT
try_update() {
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    "${apt[@]}" update >"$apt_log" 2>&1 && return 0
    sleep 10
  done
  return 1
}
# $1: a source this script just added; one that fails to update would break
# every later apt run, so it goes again.
apt_update() {
  try_update && return 0
  [[ -n ${1:-} ]] && { sudo -n rm -f "$1" || true; }
  local msg
  msg=$(grep -E '^(E|W):' "$apt_log" | tail -3 | tr '\n' ' ' || true)
  [[ -n $msg ]] || msg=$(tail -3 "$apt_log" | tr '\n' ' ')
  fail "apt-get update kept failing: $msg"
}
apt_update
missing=()
for p in ca-certificates curl git screen; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
if (( ${#missing[@]} )); then say "installing ${missing[*]}"; "${apt[@]}" install "${missing[@]}" >/dev/null; fi
# A snap Docker is confined: it can't build from or copy into most paths.
if command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
  say "removing the snap Docker"; sudo -n snap remove --purge docker >/dev/null
fi
if ! dpkg -s docker-ce >/dev/null 2>&1; then
  conflicts=()
  for p in docker.io docker-doc docker-compose docker-compose-v2 docker-buildx podman-docker containerd runc; do
    dpkg -s "$p" >/dev/null 2>&1 && conflicts+=("$p")
  done
  if (( ${#conflicts[@]} )); then say "removing ${conflicts[*]}"; "${apt[@]}" remove "${conflicts[@]}" >/dev/null; fi
  say "installing Docker from Docker's repository"
  sudo -n install -m 0755 -d /etc/apt/keyrings
  sudo -n curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo -n chmod a+r /etc/apt/keyrings/docker.asc
  sudo -n rm -f /etc/apt/sources.list.d/docker.list
  printf '%s\n' 'Types: deb' 'URIs: https://download.docker.com/linux/ubuntu' \
    "Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}" 'Components: stable' \
    "Architectures: $(dpkg --print-architecture)" 'Signed-By: /etc/apt/keyrings/docker.asc' \
    | sudo -n tee /etc/apt/sources.list.d/docker.sources >/dev/null
  apt_update /etc/apt/sources.list.d/docker.sources
  # A source that can't be fetched is only a warning to `apt-get update`
  # (exit 0); the missing candidate is what shows it. Not `apt-cache show`:
  # Ubuntu packages that mention docker-ce make it a known name that shows
  # nothing with exit 0. awk, not grep -q, which under pipefail can kill
  # apt-cache early and fail a working repository.
  candidate=$(apt-cache policy docker-ce 2>/dev/null | awk '/Candidate:/ { print $2 }')
  if [[ -z $candidate || $candidate == '(none)' ]]; then
    sudo -n rm -f /etc/apt/sources.list.d/docker.sources
    fail "Docker's repository could not be read: $(grep -E '^(E|W):' "$apt_log" | tail -3 | tr '\n' ' ' || true)"
  fi
  "${apt[@]}" install docker-ce docker-ce-cli containerd.io docker-buildx-plugin >/dev/null
fi
sudo -n systemctl enable --now docker >/dev/null 2>&1 || true
if ! id -nG "$me" | tr ' ' '\n' | grep -qx docker; then
  say "adding $me to the docker group"; sudo -n usermod -aG docker "$me"
fi
# Microsoft only packages LTS and some interim releases; without a package
# every recording run falls back to a portable PowerShell by itself.
if ! command -v pwsh >/dev/null; then
  say "installing PowerShell from Microsoft's repository"
  tmp=$(mktemp -d)
  # try_update, not apt_update: its `exit` would end the script even here.
  if curl -fsSL "https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb" -o "$tmp/ms.deb" \
     && sudo -n dpkg -i "$tmp/ms.deb" >/dev/null && try_update && "${apt[@]}" install powershell >/dev/null; then :
  else
    say "no PowerShell package for Ubuntu $VERSION_ID; recordings will use a portable PowerShell"
    # A source that fails to update would break every later apt run.
    if dpkg -s packages-microsoft-prod >/dev/null 2>&1; then
      "${apt[@]}" purge packages-microsoft-prod >/dev/null 2>&1 || sudo -n dpkg --purge packages-microsoft-prod >/dev/null 2>&1 || true
      try_update || true
    fi
  fi
  rm -rf "$tmp"
fi
# Upgrading docker-ce or containerd.io restarts its daemon (their packaging
# restarts after upgrade), and with it every container, ending a recording.
# unattended-upgrades must skip them (Python regexes), needrestart must not
# restart containerd (docker it already skips), and live-restore keeps
# containers running across a patch-level daemon restart.
printf '%s\n' 'Unattended-Upgrade::Package-Blacklist {' '    "docker-ce$";' '    "docker-ce-cli$";' '    "containerd\.io$";' '};' \
  | sudo -n tee /etc/apt/apt.conf.d/51play-action >/dev/null
if [[ -d /etc/needrestart ]]; then
  sudo -n mkdir -p /etc/needrestart/conf.d
  printf '%s\n' '$nrconf{override_rc}{qr(^containerd)} = 0;' \
    | sudo -n tee /etc/needrestart/conf.d/play-action.conf >/dev/null
fi
if [[ ! -s /etc/docker/daemon.json ]]; then
  sudo -n mkdir -p /etc/docker
  echo '{ "live-restore": true }' | sudo -n tee /etc/docker/daemon.json >/dev/null
  sudo -n systemctl reload docker >/dev/null 2>&1 || true
elif ! grep -q '"live-restore"' /etc/docker/daemon.json; then
  say "note: /etc/docker/daemon.json exists, so live-restore was not added; add \"live-restore\": true to keep recordings through Docker restarts"
fi
# The enable above may fail quietly; "ready" with no daemon would send the
# next recording back here with "cannot use Docker".
sudo -n docker info >/dev/null 2>&1 || fail "Docker is installed but its daemon is not running; see: sudo systemctl status docker"
say "server ready: $(docker --version 2>/dev/null || echo docker), $(pwsh --version 2>/dev/null || echo pwsh), $(screen --version 2>/dev/null | head -1 | cut -d' ' -f1-3)"
'@

    $prepareScript = @'
set -euo pipefail
dec() { [[ ${1:--} == - ]] || printf %s "$1" | base64 -d; }
dir=$(dec "${1:-}")
repo=$(dec "${2:-}")
ver=$3
mode=$4
image=$(dec "${5:-}")
max_age_days=$6
fail() { echo "play-action: error: $*" >&2; exit 3; }
cd ~
umask 077
mkdir -p ~/.play-action/cookies ~/.play-action/dl
chmod 700 ~/.play-action ~/.play-action/cookies
# Leftovers of runs that never got to delete them; a running recording
# copied its cookies into its container at the start.
find ~/.play-action/cookies -type f -mtime +0 -delete 2>/dev/null || true
echo "HOME=$HOME"
if [[ $mode == light ]]; then
  [[ -d $dir ]] || fail "nothing deployed in ~/$dir yet"
  echo "DIR=$(cd "$dir" && pwd)"
  exit 0
fi
[[ $(uname -s) == Linux ]] || fail "the server must run Linux"
[[ $(uname -m) == x86_64 ]] || fail "the server must be x86_64 (amd64); Chrome has no Linux build for $(uname -m)"
command -v git >/dev/null || fail "git is missing; run with -Setup, or: sudo apt-get install -y git"
command -v docker >/dev/null || fail "Docker is missing; run with -Setup (Ubuntu), or see https://docs.docker.com/engine/install/"
docker info >/dev/null 2>&1 || fail "$(id -un) cannot use Docker: run with -Setup, or: sudo usermod -aG docker $(id -un), then reconnect"
umask 022
if [[ -d $dir/.git ]]; then
  git -C "$dir" pull -q --ff-only || echo "play-action: could not update $dir; using the code already there" >&2
else
  echo "play-action: cloning $repo"
  git clone -q "$repo" "$dir"
fi
mkdir -p "$dir/logs"
if command -v pwsh >/dev/null; then
  pw=$(command -v pwsh)
else
  pw=$HOME/.play-action/pwsh-$ver/pwsh
  if [[ ! -x $pw ]]; then
    echo "play-action: downloading PowerShell $ver (only once)"
    url=https://github.com/PowerShell/PowerShell/releases/download/v$ver/powershell-$ver-linux-x64.tar.gz
    if command -v curl >/dev/null; then get=(curl -fsSL "$url")
    elif command -v wget >/dev/null; then get=(wget -qO- "$url")
    else fail "neither curl nor wget is installed"
    fi
    # Extracted aside and moved into place, so a broken download never
    # leaves a pwsh that looks installed.
    tmp=$(mktemp -d ~/.play-action/pwsh-tmp.XXXXXX)
    "${get[@]}" | tar -xz -C "$tmp" || { rm -rf "$tmp"; fail "downloading PowerShell from $url failed"; }
    chmod +x "$tmp/pwsh"
    rm -rf "${pw%/pwsh}"
    mv "$tmp" "${pw%/pwsh}"
  fi
fi
echo "PWSH=$pw"
echo "DIR=$(cd "$dir" && pwd)"
# The image is rebuilt when the code that goes into it isn't the code it was
# built from, or once it is old: Chrome and its DRM module need updates.
# record.ps1 labels its builds with that code's last commit; commit times
# can't decide it (a commit made before a build may be pulled after it).
created=$(docker image inspect -f '{{.Created}}' "$image" 2>/dev/null || true)
if [[ -z $created ]]; then
  echo "IMAGE=missing"
else
  built=$(date -d "$created" +%s)
  label=$(docker image inspect -f '{{index .Config.Labels "play-action.rev"}}' "$image" 2>/dev/null || true)
  [[ $label == "<no value>" ]] && label=
  rev=$(git -C "$dir" log -1 --format=%H -- Dockerfile browse.py entrypoint.sh 2>/dev/null || true)
  age_days=$(( ($(date +%s) - built) / 86400 ))
  # Age first: its rebuild bypasses the cache and covers a code change too,
  # while a cached one for the code would reset the age with Chrome unchanged.
  if (( age_days >= max_age_days )); then echo "IMAGE=old $age_days"
  elif [[ -n $rev && $label != "$rev" ]]; then echo "IMAGE=changed"
  else echo "IMAGE=ok"
  fi
fi
free_kb() { df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'; }
echo "FREE_DIR=$(free_kb "$dir")"
root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)
[[ -n $root && -d $root ]] && echo "FREE_DOCKER=$(free_kb "$root")"
true
'@

    # The wrapper runs record.ps1 with the options decoded from JSON, so no
    # value is ever re-quoted, and deletes the uploaded cookies afterwards.
    $startScript = @'
set -euo pipefail
dec() { [[ ${1:--} == - ]] || printf %s "$1" | base64 -d; }
dir=$(dec "${1:-}")
pw=$(dec "${2:-}")
options=$3
id=$4
cookies=$(dec "${5:-}")
# Written aside and moved into place: another recording's PowerShell may be
# reading the current one.
cat > ~/.play-action/run.ps1.$id <<'EOF'
param([string] $Options, [string] $Repo, [string] $Cookies)
$code = $null
try {
    # record.ps1 prints sizes as "1.2 MB"; a pl-PL or fr-FR server would
    # write "1,2 MB" and thousands with a non-breaking space.
    [cultureinfo]::CurrentCulture = [cultureinfo]::InvariantCulture
    $named = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Options)) | ConvertFrom-Json
    $splat = @{}
    # Strings come base64-encoded: ConvertFrom-Json would turn a date-like
    # -Title into a DateTime.
    foreach ($p in $named.PSObject.Properties) {
        $value = $p.Value
        if ($value -is [string] -and $value.StartsWith('b64:')) {
            $value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value.Substring(4)))
        }
        $splat[$p.Name] = $value
    }
    Set-Location -LiteralPath $Repo
    $global:LASTEXITCODE = 0
    & ./record.ps1 @splat
    $code = if ($?) { $LASTEXITCODE } else { 1 }
}
catch { $code = 1; throw }
finally {
    if ($Cookies) { Remove-Item -LiteralPath $Cookies -Force -ErrorAction SilentlyContinue }
    # Neither set nor caught: Ctrl+C (-Stop), after which record.ps1 has
    # still saved what it had.
    if ($null -eq $code) { Write-Host "play-action: finished (exit 130, stopped)"; $code = 130 }
    else { Write-Host "play-action: finished (exit $code)" }
}
exit $code
EOF
mv -f ~/.play-action/run.ps1.$id ~/.play-action/run.ps1
cd "$dir"
# The portable PowerShell would need libicu, which minimal servers lack.
[[ $pw == "$HOME/.play-action/"* ]] && export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
export NO_COLOR=1
# An age rebuild has to bypass Docker's cache, or the cached Chrome layer
# comes back unchanged (record.ps1 reads this).
[[ ${6:-0} == 1 ]] && export PLAY_ACTION_REFRESH=1
export LOG=$dir/logs/$id.log
# Exists before anything follows it, or tail would give up at once.
: > "$LOG"
cmd=("$pw" -NoProfile -NonInteractive -File "$HOME/.play-action/run.ps1" -Options "$options" -Repo "$dir" -Cookies "$cookies")
if command -v screen >/dev/null; then
  # The session shows the output live and closes when the recording ends;
  # tee also writes the log this script follows (screen's own -L log lags
  # and needs screen 4.6+). tee -i keeps going on a Ctrl+C in the session,
  # so record.ps1's messages while it saves the file still reach the log.
  screen -dmS "play-action-$id" bash -c '"$@" 2>&1 | tee -i "$LOG"' _ "${cmd[@]}"
  pid=
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pid=$(screen -ls 2>/dev/null | grep -oE "[0-9]+\.play-action-$id" | head -1 | cut -d. -f1 || true)
    [[ -n $pid ]] && break
    sleep 0.2
  done
  [[ -n $pid ]] || { echo "play-action: error: the screen session did not start" >&2; exit 3; }
  echo "SCREEN=play-action-$id"
else
  # Not `cmd &`: a script's background jobs ignore SIGINT for good, and -Stop
  # needs it to reach PowerShell so that record.ps1 saves the file.
  setsid -f bash -c 'echo $$ > "$0"; exec "$@" > "$LOG" 2>&1 < /dev/null' "logs/$id.pid" "${cmd[@]}"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s logs/$id.pid ]] && break; sleep 0.2; done
  pid=$(cat "logs/$id.pid" 2>/dev/null || true)
  [[ -n $pid ]] || { echo "play-action: error: the recording did not start" >&2; exit 3; }
  echo "NOSCREEN"
fi
echo "$pid" > "logs/$id.pid"
ln -sfn "$id.log" logs/latest.log
ln -sfn "$id.pid" logs/latest.pid
'@

    $resolveRun = @'
cd "$dir" 2>/dev/null || { echo "play-action: error: nothing deployed in $dir" >&2; exit 3; }
if [[ $id == latest ]]; then
  [[ -L logs/latest.log ]] || { echo "play-action: error: no recording has been started here" >&2; exit 3; }
  id=$(readlink logs/latest.log); id=${id%.log}
fi
[[ -f logs/$id.log ]] || { echo "play-action: error: no recording $id here" >&2; exit 3; }
pid=$(cat "logs/$id.pid" 2>/dev/null || true)
# Only a pid that is still this recording's counts; an old one may have
# been reused by another process since.
alive=
if [[ -n $pid && -r /proc/$pid/cmdline ]] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -qE 'SCREEN|screen|pwsh|run\.ps1'; then alive=1; fi
'@

    # record.ps1 redraws its progress with carriage returns; they become
    # separate lines here so that this side can redraw them in place.
    $followScript = @"
set -euo pipefail
dir=`$(printf %s "`$1" | base64 -d)
id=`$2
$resolveRun
echo "RUN=`$id"
echo "ALIVE=`${alive:-0}"
if [[ -z `$alive ]]; then
  tr '\r' '\n' < "logs/`$id.log"
elif command -v stdbuf >/dev/null; then
  tail -c +1 -f --pid="`$pid" "logs/`$id.log" | stdbuf -oL tr '\r' '\n'
else
  tail -c +1 -f --pid="`$pid" "logs/`$id.log" | tr '\r' '\n'
fi
"@

    # The same Ctrl+C a user would press: record.ps1 then stops the recorder
    # and saves what it has. Only this one recording is touched.
    $stopScript = @"
set -euo pipefail
dir=`$(printf %s "`$1" | base64 -d)
id=`$2
$resolveRun
if [[ -z `$alive ]]; then
  if grep -q '^play-action: finished' "logs/`$id.log"; then echo "play-action: recording `$id has already finished"
  else echo "play-action: recording `$id is not running"
  fi
  exit 0
fi
if screen -ls 2>/dev/null | grep -q "\.play-action-`$id\b"; then
  # || true: a recording that ends just now takes its session with it.
  screen -S "play-action-`$id" -p 0 -X stuff `$'\003' || true
else
  kill -INT -- "-`$pid"
fi
echo "play-action: asked recording `$id to stop; it is saving the file"
"@

    $linkScript = @'
set -euo pipefail
saved=$(printf %s "$1" | base64 -d)
id=$2
[[ -f $saved ]] || { echo "play-action: error: $saved is not on the server" >&2; exit 3; }
ln -sfn -- "$saved" ~/.play-action/dl/"$id"
'@

    $cleanupScript = @'
set -euo pipefail
rm -f -- ~/.play-action/dl/"$1" ~/.play-action/cookies/"$1".txt
'@

    function Watch-Run([string] $remoteDir, [string] $id, $state) {
        Invoke-Remote $followScript @((ConvertTo-Base64 $remoteDir), $id) 2>&1 | ForEach-Object {
            $line = ("$_" -replace '\x1b\[[0-9;?]*[A-Za-z]', '').TrimEnd()
            if (-not $line) { return }
            # A message printed right after a progress redraw shares its line.
            if ($line -match '^\s+(?:REC \d|Preparing page|H\.265 \d).*?\s{2,}(Saved .+|Kept the unprocessed capture as .+)$') { $line = $Matches[1] }
            if ($line -match '^\s+(REC \d|Preparing page|H\.265 \d)') {
                Write-Host -NoNewline ("`r" + $line.PadRight(70))
                $state.Progress = $true
                return
            }
            if ($state.Progress) { Write-Host ''; $state.Progress = $false }
            if ($line -match '^RUN=(.+)$') { $state.Run = $Matches[1]; Write-Host "Following recording $($Matches[1]) on $Ip"; return }
            if ($line -match '^ALIVE=(\d)$') { $state.Alive = $Matches[1] -eq '1'; return }
            if ($line -match '^play-action: finished \(exit (\d+)') { $state.Code = [int]$Matches[1]; return }
            if ($line -match '^Saved (.+) \(\d[\d.,]* [KMG]?B(, [^)]*)?\)$') { $state.Saved = $Matches[1] }
            if ($line -match '^Kept the unprocessed capture as (.+)$') { $state.Raw = $Matches[1] }
            if ($line -like 'play-action: error:*') { $state.Errors += $line }
            Write-Host $line
        }
        $state.Exit = if (Test-SshFailure $LASTEXITCODE) { 255 } else { $LASTEXITCODE }
        if ($state.Progress) { Write-Host ''; $state.Progress = $false }
    }

    function Receive-File([string] $remotePath, [string] $id) {
        $local = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LocalDir)
        New-Item -ItemType Directory -Force $local | Out-Null
        $file = Join-Path $local ($remotePath -split '/')[-1]
        # The server-side name never goes into the scp spec: older scp passes
        # it through the server's shell. A fixed link points at it instead.
        $linked = Invoke-Remote $linkScript @((ConvertTo-Base64 $remotePath), $id) 2>&1
        Assert-Remote $linked 'Preparing the download'
        Write-Host "Downloading to $file..."
        scp @sshOptions -P $Port -q "${scpTarget}:.play-action/dl/$id" $file
        $ok = $LASTEXITCODE -eq 0
        Invoke-Remote $cleanupScript @($id) *> $null
        if (-not $ok) { throw "Download failed; the recording is still on the server: $remotePath" }
        Write-Host "Downloaded $file ($('{0:N1} MB' -f ((Get-Item -LiteralPath $file).Length / 1MB)))"
    }

    # Runs in `finally`, so a Ctrl+C here still says how to carry on.
    function Complete-Run($state) {
        if ($null -eq $state.Code) {
            Write-Host ''
            if ($state.Exit -eq 3) {
                $why = if ($state.Errors) { $state.Errors -join '; ' } else { "exit 3" }
                throw "Following the recording failed: $why"
            }
            # A follow that ended by itself (exit 0) means the recording's
            # process is gone, so without its final message it died.
            if ($state.Done -and $state.Exit -ne 255 -and ($state.Alive -eq $false -or $state.Exit -eq 0) -and -not ($state.Saved -or $state.Raw)) {
                Write-Host "Recording $($state.Run) is no longer running and never finished (killed, or the server restarted)."
                Write-Host "Its log on the server: logs/$($state.Run).log in the play-action folder."
                exit 1
            }
            if ($state.Exit -eq 255) {
                Write-Host "The connection to $Ip was lost; the recording goes on on the server."
                $runHint = if ($state.Run) { " -Run $($state.Run)" } else { '' }
                Write-Host "Follow it again with -Attach$runHint (same -Ip/-User/-Key/-Port)."
                # Nothing was downloaded; ssh's own -1 would otherwise be left behind.
                exit 1
            }
            if ($state.Saved -or $state.Raw) {
                Write-Host "The recording ended without its final message; check the log on the server."
            }
            else {
                Write-Host "Stopped following; the recording goes on on the server."
                $runHint = if ($state.Run) { " -Run $($state.Run)" } else { '' }
                Write-Host "Follow it again with -Attach$runHint, end it early with -Stop$runHint (same -Ip/-User/-Key/-Port)."
                return
            }
        }
        if ($state.Saved) {
            if ($NoDownload) { Write-Host "Kept on the server: $($state.Saved)" }
            else { Receive-File $state.Saved $state.Run }
            return
        }
        if ($state.Raw) {
            Write-Warning "Saving the final file failed; downloading the unprocessed capture instead."
            if ($NoDownload) { Write-Host "Kept on the server: $($state.Raw)" }
            else { Receive-File $state.Raw $state.Run }
            exit 1
        }
        Write-Host "No recording was saved on the server (exit $($state.Code))."
        exit 1
    }

    function Watch-And-Receive([string] $remoteDir, [string] $id) {
        $state = @{ Saved = $null; Raw = $null; Code = $null; Progress = $false; Run = $null; Done = $false; Exit = $null; Errors = @(); Alive = $null }
        try {
            Watch-Run $remoteDir $id $state
            $state.Done = $true
        }
        finally {
            if ($state.Done -or $null -eq $state.Code) { Complete-Run $state }
        }
    }

    Write-Host "Connecting to $target (port $Port)..."

    if ($Setup) {
        Invoke-Remote $setupScript @() 2>&1 | ForEach-Object { "$_" } | Tee-Object -Variable setupOutput |
            Where-Object { $_ -like 'play-action:*' -and $_ -notlike 'play-action: error:*' } | ForEach-Object { Write-Host "  $_" }
        Assert-Remote $setupOutput 'Setting up the server'
        if ($PSCmdlet.ParameterSetName -eq 'Setup') { return }
    }

    $mode = if ($Attach -or $Stop) { 'light' } else { 'full' }
    $image = if ($PSBoundParameters.ContainsKey('Image')) { $PSBoundParameters['Image'] } else { 'chrome-rec' }
    $prepared = Invoke-Remote $prepareScript @((ConvertTo-Base64 $RemoteDir), (ConvertTo-Base64 $Repo), '7.4.6', $mode,
        (ConvertTo-Base64 $image), $MaxImageAgeDays) 2>&1
    Assert-Remote $prepared 'Preparing the server'
    $info = @{}
    foreach ($line in Get-Text $prepared) {
        if ($line -match '^(HOME|PWSH|DIR|IMAGE|FREE_DIR|FREE_DOCKER)=(.*)$') { $info[$Matches[1]] = $Matches[2] }
        elseif ($line -like 'play-action:*') { Write-Host "  $line" }
    }
    $remoteDir = $info.DIR

    if ($Attach -or $Stop) {
        $id = if ($Run) { $Run } else { 'latest' }
        if ($Stop) {
            $stopped = Invoke-Remote $stopScript @((ConvertTo-Base64 $remoteDir), $id) 2>&1
            Get-Text $stopped | Where-Object { $_ } | ForEach-Object { Write-Host "  $_" }
            Assert-Remote $stopped 'Stopping the recording'
        }
        Watch-And-Receive $remoteDir $id
        return
    }

    $options = [ordered]@{}
    foreach ($name in $PSBoundParameters.Keys) {
        if ($name -notin $recordNames -or $name -in 'Help', 'ValidateOnly') { continue }
        $value = $PSBoundParameters[$name]
        if ($value -is [switch]) { $value = $value.IsPresent }
        elseif ($value -is [string]) { $value = 'b64:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value)) }
        $options[$name] = $value
    }

    $rebuild = $info.IMAGE -ne 'ok' -or $options.Build
    $refresh = 0
    switch -Wildcard ($info.IMAGE) {
        'missing' { Write-Host "  the Docker image will be built on the server (takes a few minutes)" }
        'changed' { Write-Host "  the pulled code changed the Docker image; rebuilding it"; $options.Build = $true }
        'old *' {
            Write-Host "  the Docker image is $($info.IMAGE.Substring(4)) days old; rebuilding it from scratch so Chrome is current (takes a few minutes)"
            $options.Build = $true
            $refresh = 1
        }
    }

    # The recording is written inside Docker's storage, then copied into the
    # repository folder: both need room. Building needs ~2 GB more.
    $needGB = if ($rebuild) { 5 } else { 3 }
    foreach ($pair in @(@('FREE_DIR', $remoteDir), @('FREE_DOCKER', "Docker's storage"))) {
        $kb = $info[$pair[0]]
        if ($kb -match '^\d+$' -and [long]$kb -lt $needGB * 1MB) {
            throw ("Only {0:N1} GB free for {1} on the server; {2} GB are needed. Delete old recordings (in {3}/recordings) or unused images (docker image prune)." -f ([long]$kb / 1MB), $pair[1], $needGB, $remoteDir)
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $id = "$stamp-$('{0:x4}' -f (Get-Random -Maximum 0x10000))"
    $remoteCookies = ''
    if ($options.Contains('Cookies')) {
        # A fixed name under the home folder: no user value in the scp spec.
        $remoteCookies = "$($info.HOME)/.play-action/cookies/$id.txt"
        scp @sshOptions -P $Port -q (Resolve-Path -LiteralPath $PSBoundParameters['Cookies']).Path "${scpTarget}:.play-action/cookies/$id.txt"
        if ($LASTEXITCODE -ne 0) { throw 'Uploading the cookies file failed.' }
        $options.Cookies = 'b64:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteCookies))
        Write-Host "  uploaded the cookies (deleted on the server when the recording ends)"
    }

    $json = $options | ConvertTo-Json -Compress
    $started = Invoke-Remote $startScript @((ConvertTo-Base64 $remoteDir), (ConvertTo-Base64 $info.PWSH), (ConvertTo-Base64 $json), $id,
        (ConvertTo-Base64 $remoteCookies), $refresh) 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Invoke-Remote $cleanupScript @($id) *> $null
        # The cleanup's own exit code would otherwise hide the failure.
        $global:LASTEXITCODE = $code
    }
    Assert-Remote $started 'Starting the recording'
    Write-Host "Started recording $id on $Ip (log: $remoteDir/logs/$id.log)"
    if (Get-Text $started | Where-Object { $_ -like 'SCREEN=*' }) {
        Write-Host "  It runs in screen session play-action-$id. To watch it on the server: ssh in, then"
        Write-Host "  screen -r play-action-$id   (detach again with Ctrl+A, D; Ctrl+C there stops the recording)"
    }
    else {
        Write-Host "  screen is not installed on the server, so it runs as a background process."
        Write-Host "  (-Setup, or sudo apt-get install -y screen, gives a session you can attach to.)"
    }

    if ($Detach) {
        Write-Host "Follow it with -Attach -Run $id, end it early with -Stop -Run $id (same -Ip/-User/-Key/-Port)."
        return
    }
    Watch-And-Receive $remoteDir $id

    }
    finally {
        $OutputEncoding = $savedEncodings[0]
        try {
            [Console]::OutputEncoding = $savedEncodings[1]
            [Console]::InputEncoding = $savedEncodings[2]
        }
        catch {}
    }
}
