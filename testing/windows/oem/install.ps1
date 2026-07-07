# Installs BotMaker Studio inside the dockurr/windows guest.
#
# Source of the installer (in priority order):
#   1. A local *.msi placed in this OEM folder  -> installs that exact build.
#   2. Otherwise, a GitHub release .msi          -> $Version below, or the latest.
#
# The jpackage MSI is self-contained (it bundles its own JDK runtime), so nothing
# else needs to be provisioned in the guest. Runs as SYSTEM during OEM setup.

$ErrorActionPreference = 'Stop'
$Repo    = 'LiQiyeDev/botmaker-studio'
$Version = ''          # e.g. 'v1.0.8' to pin; empty = latest release
$OemDir  = $PSScriptRoot

Write-Host "=== BotMaker Studio OEM install $(Get-Date -Format o) ==="
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ua = @{ 'User-Agent' = 'botmaker-oem' }

# 1. Local MSI wins (lets you test a specific CI-built installer).
$local = Get-ChildItem -Path $OemDir -Filter *.msi -ErrorAction SilentlyContinue | Select-Object -First 1
if ($local) {
    $msiPath = $local.FullName
    Write-Host "Using local MSI: $msiPath"
}
else {
    # 2. Resolve the windows-x64 .msi asset from a GitHub release.
    if ($Version) { $api = "https://api.github.com/repos/$Repo/releases/tags/$Version" }
    else          { $api = "https://api.github.com/repos/$Repo/releases/latest" }
    Write-Host "Querying $api"
    $rel   = Invoke-RestMethod -Uri $api -Headers $ua
    $asset = $rel.assets | Where-Object { $_.name -like '*windows-x64.msi' } | Select-Object -First 1
    if (-not $asset) { throw "No *windows-x64.msi asset in release $($rel.tag_name)" }

    $msiPath = Join-Path $env:TEMP $asset.name
    Write-Host "Downloading $($asset.name) from $($rel.tag_name)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msiPath -Headers $ua
}

# 3. Silent install (3010 = success, reboot required — fine).
Write-Host "Installing $msiPath"
$log = Join-Path $OemDir 'msi.log'
$p = Start-Process msiexec.exe `
    -ArgumentList '/i', "`"$msiPath`"", '/qn', '/norestart', '/l*v', "`"$log`"" `
    -Wait -PassThru
Write-Host "msiexec exit code: $($p.ExitCode)"
if ($p.ExitCode -notin 0, 3010) { throw "MSI install failed (exit $($p.ExitCode)); see $log" }

Write-Host "BotMaker Studio installed (Start menu + desktop shortcut created)."
