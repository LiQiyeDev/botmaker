<#
.SYNOPSIS
  release.ps1 - Windows PowerShell port of release.sh. Cut a coordinated, dependency-ordered
  release of the BotMaker submodules.

.DESCRIPTION
  Faithful port of ./release.sh for Windows (the bash script needs curl/sed/seq/sort -V and a POSIX
  shell). Behaviour matches release.sh exactly - same flags, same ordered flow, same JitPack waits.

  The library submodules form the chain  shared -> sdk -> studio.  JitPack owns each module's OWN
  version (it serves every git tag as com.github.LiQiyeDev:<repo>:<tag>, ignoring the pom version), so
  this script does NOT touch any module's <version>. The one cross-module thing that must be managed is
  studio's MavenService.SDK_FALLBACK_VERSION (bumped to the released sdk tag).

  botmaker-pilot is a CLIENT APP, not a JitPack library and not in the reactor. Tagging it triggers its
  own GitHub Actions workflow (release-apk.yml) which builds the APK and attaches it to the Release.
  It has no dependency on the library chain, so it is tagged FIRST (its APK build runs in parallel with
  the shared/sdk JitPack waits).

  Each module flag takes an OPTIONAL argument:
    * an explicit version   -Sdk 1.0.7    (tag exactly that)
    * a bump level          -Sdk minor    (patch|minor|major from its latest tag)
    * nothing at all        -Sdk          (defaults to a patch bump)

.EXAMPLE
  ./release.ps1 -All                       # patch-bump + release every changed module
  ./release.ps1 -All minor                 # minor-bump them all
  ./release.ps1 -Shared -Sdk -Studio       # the library chain (each patch-bumps)
  ./release.ps1 -Shared 1.1.0 -Sdk 1.0.7 -Studio 1.0.7   # explicit versions, any subset
  ./release.ps1 -Sdk minor                 # SDK-only minor bump
  ./release.ps1 -Pilot 0.2.0               # pilot at an explicit version (tags -> APK Release)
  ./release.ps1 -All -DryRun               # print everything (incl. computed versions), change nothing
  ./release.ps1 -Studio 1.0.18 -Force      # release even when the module has no changes since its tag
#>

# NOTE: args are parsed manually (like release.sh's take_optional) because each module flag has an
# OPTIONAL value that may or may not consume the next token - which PowerShell's param() can't express.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Owner  = 'LiQiyeDev'
$script:Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DryRun = $false
$script:Force  = $false

function Die  { param([string]$Msg) [Console]::Error.WriteLine("error: $Msg"); exit 1 }
function Info { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor Blue }
function Show-Cmd { param([string]$S) Write-Host "    `$ $S" }

function Show-Usage {
    @'
release.ps1 - cut a coordinated, dependency-ordered release of the BotMaker submodules.

Usage:
  ./release.ps1 -All [level]                 patch|minor|major bump every changed module (default patch)
  ./release.ps1 -Shared [v] -Sdk [v] -Studio [v] -Pilot [v]   any subset; v = x.y.z or patch|minor|major
  ./release.ps1 -DryRun                       print the plan + commands, change nothing
  ./release.ps1 -Force                        release even when a module is unchanged since its tag
  ./release.ps1 -Help

Flags -Shared/-Sdk/-Studio/-Pilot each take an OPTIONAL value: an explicit x.y.z, a bump level
(patch|minor|major), or nothing (defaults to a patch bump). -All [level] seeds every module not set
explicitly. Order: pilot (parallel APK) -> shared (+JitPack wait) -> sdk (+wait) -> studio -> umbrella
pointer commit.
'@ | Write-Host
}

# ---- arg parsing (mirrors release.sh take_optional) ----
$argv = @($args)
if ($argv.Count -eq 0) { Show-Usage; exit 1 }

# Returns @{ Val = <value>; Shift = <1|2> } - a flag with no following value (or another flag next)
# defaults to 'patch' and consumes 1 token; otherwise it consumes the value (2 tokens).
function Take-Optional { param([int]$Index)
    $next = if (($Index + 1) -lt $argv.Count) { $argv[$Index + 1] } else { $null }
    if ($next -and ($next -notmatch '^-')) { return @{ Val = $next; Shift = 2 } }
    return @{ Val = 'patch'; Shift = 1 }
}

$AllSpec = ''; $SharedSpec = ''; $SdkSpec = ''; $StudioSpec = ''; $PilotSpec = ''
$i = 0
while ($i -lt $argv.Count) {
    $a = $argv[$i]
    switch -CaseSensitive ($a) {
        { $_ -in '-All','--all' }        { $o = Take-Optional $i; $AllSpec    = $o.Val; $i += $o.Shift; continue }
        { $_ -in '-Shared','--shared' }  { $o = Take-Optional $i; $SharedSpec = $o.Val; $i += $o.Shift; continue }
        { $_ -in '-Sdk','--sdk' }        { $o = Take-Optional $i; $SdkSpec    = $o.Val; $i += $o.Shift; continue }
        { $_ -in '-Studio','--studio' }  { $o = Take-Optional $i; $StudioSpec = $o.Val; $i += $o.Shift; continue }
        { $_ -in '-Pilot','--pilot' }    { $o = Take-Optional $i; $PilotSpec  = $o.Val; $i += $o.Shift; continue }
        { $_ -in '-Force','--force' }    { $script:Force  = $true; $i++; continue }
        { $_ -in '-DryRun','--dry-run' } { $script:DryRun = $true; $i++; continue }
        { $_ -in '-Help','--help','-h' } { Show-Usage; exit 0 }
        default { Die "unknown arg: $a (see -Help)" }
    }
}

# --all seeds every module that wasn't set explicitly (an explicit flag wins).
if ($AllSpec) {
    if (-not $SharedSpec) { $SharedSpec = $AllSpec }
    if (-not $SdkSpec)    { $SdkSpec    = $AllSpec }
    if (-not $StudioSpec) { $StudioSpec = $AllSpec }
    if (-not $PilotSpec)  { $PilotSpec  = $AllSpec }
}
if (-not "$SharedSpec$SdkSpec$StudioSpec$PilotSpec") {
    Die 'nothing to release (pass -All or -Shared/-Sdk/-Studio/-Pilot)'
}

$umbrellaPom = Join-Path $script:Root 'pom.xml'
if (-not (Test-Path $umbrellaPom) -or
    -not (Select-String -Path $umbrellaPom -SimpleMatch '<artifactId>BotMaker</artifactId>' -Quiet)) {
    Die 'must be run from the botmaker umbrella root'
}

if ($script:DryRun) { Info 'DRY RUN - no changes will be made.' }

# ---- helpers ----

# Abort unless the submodule's working tree is clean and it's on a branch (not detached).
function Test-Preflight { param([string]$Mod)
    $dir = Join-Path $script:Root $Mod
    if (-not (Test-Path (Join-Path $dir '.git'))) { Die "$Mod`: not a git submodule checkout" }
    $status = & git -C $dir status --porcelain
    if ($status) {
        if ($script:DryRun) { Info "$Mod`: working tree not clean (ok in dry-run)" }
        else { Die "$Mod`: working tree not clean - commit/stash first" }
    }
    $branch = & git -C $dir symbolic-ref --quiet --short HEAD 2>$null
    if (-not $branch) {
        if ($script:DryRun) { Info "$Mod`: detached HEAD (ok in dry-run)" }
        else { Die "$Mod`: detached HEAD - 'git -C $Mod checkout main' first" }
    }
}

# Highest semver among the module's git tags (leading 'v' stripped), or '' when none.
# Fetches tags from origin first so auto-increment sees released tags, not just local ones.
function Get-LatestVersion { param([string]$Mod)
    $dir = Join-Path $script:Root $Mod
    & git -C $dir fetch --tags --quiet origin 2>$null | Out-Null
    $vers = @()
    foreach ($t in (& git -C $dir tag --list)) {
        $s = $t -replace '^v', ''
        if ($s -match '^\d+\.\d+\.\d+$') { $vers += [version]$s }
    }
    if ($vers.Count -eq 0) { return '' }
    $max = ($vers | Sort-Object)[-1]
    return "$($max.Major).$($max.Minor).$($max.Build)"
}

# Increment a version by patch|minor|major.
function Get-Bumped { param([string]$Ver, [string]$Level)
    $p = $Ver.Split('.'); $ma = [int]$p[0]; $mi = [int]$p[1]; $pa = [int]$p[2]
    switch ($Level) {
        'major' { return "$($ma + 1).0.0" }
        'minor' { return "$ma.$($mi + 1).0" }
        'patch' { return "$ma.$mi.$($pa + 1)" }
        default { Die "unknown bump level '$Level'" }
    }
}

# A literal x.y.z passes through; a bump level is applied to the module's latest tag (0.0.0 when none).
function Resolve-Version { param([string]$Mod, [string]$Spec)
    if ($Spec -match '^\d+\.\d+\.\d+$') { return $Spec }
    if ($Spec -notin @('patch', 'minor', 'major')) {
        Die "$Mod`: bad version/level '$Spec' (want x.y.z or patch|minor|major)"
    }
    $cur = Get-LatestVersion $Mod
    if (-not $cur) { $cur = '0.0.0' }
    return Get-Bumped $cur $Spec
}

# True when the module has something new to release: no prior tag, or HEAD tree differs from the latest
# release tag. False only when HEAD is byte-identical to the latest tag.
function Test-HasChanges { param([string]$Mod)
    $dir = Join-Path $script:Root $Mod
    $last = Get-LatestVersion $Mod
    if (-not $last) { return $true }
    foreach ($t in @("v$last", "$last")) {
        & git -C $dir rev-parse -q --verify "refs/tags/$t^{commit}" *> $null
        if ($LASTEXITCODE -eq 0) {
            & git -C $dir diff --quiet $t HEAD
            return ($LASTEXITCODE -ne 0)
        }
    }
    return $true
}

# Decide whether to cut a tag. An explicit version, an upstream-forced release, or -Force always releases;
# a bump-level spec releases only when Test-HasChanges says there is something new.
function Test-ShouldRelease { param([string]$Mod, [string]$Spec, [bool]$Forced)
    if ($script:Force) { return $true }
    if ($Forced) { return $true }
    if ($Spec -match '^\d+\.\d+\.\d+$') { return $true }
    return (Test-HasChanges $Mod)
}

# Commit (if there is anything to commit) and tag+push a module.
function Invoke-CommitTagPush { param([string]$Mod, [string]$Ver, [string]$Msg)
    $dir = Join-Path $script:Root $Mod
    if ($Msg) {
        Show-Cmd "git -C $Mod diff --quiet || git -C $Mod commit -am '$Msg'"
        if (-not $script:DryRun) {
            & git -C $dir diff --quiet
            if ($LASTEXITCODE -ne 0) {
                & git -C $dir commit -am $Msg
                if ($LASTEXITCODE -ne 0) { Die "$Mod`: commit failed" }
            }
        }
    }
    # idempotent: don't fail if the tag already exists (resuming an interrupted release).
    Show-Cmd "git -C $Mod rev-parse -q --verify refs/tags/v$Ver || git -C $Mod tag v$Ver"
    if (-not $script:DryRun) {
        & git -C $dir rev-parse -q --verify "refs/tags/v$Ver" *> $null
        if ($LASTEXITCODE -ne 0) {
            & git -C $dir tag "v$Ver"
            if ($LASTEXITCODE -ne 0) { Die "$Mod`: tag failed" }
        }
    }
    Show-Cmd "git -C $Mod push origin HEAD"
    if (-not $script:DryRun) { & git -C $dir push origin HEAD; if ($LASTEXITCODE -ne 0) { Die "$Mod`: push HEAD failed" } }
    Show-Cmd "git -C $Mod push origin v$Ver"
    if (-not $script:DryRun) { & git -C $dir push origin "v$Ver"; if ($LASTEXITCODE -ne 0) { Die "$Mod`: push tag failed" } }
}

# Poll JitPack until it has built <repo>:<tag> (its pom is downloadable), or time out (~10 min).
function Wait-ForJitpack { param([string]$Repo, [string]$Tag)
    $url = "https://jitpack.io/com/github/$($script:Owner)/$Repo/$Tag/$Repo-$Tag.pom"
    if ($script:DryRun) { Write-Host "    (dry-run) would poll $url until built"; return }
    Info "waiting for JitPack to build ${Repo}:${Tag} ..."
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 `
            -Uri "https://jitpack.io/api/builds/com.github.$($script:Owner)/$Repo/$Tag" | Out-Null
    } catch { }
    for ($n = 0; $n -lt 60; $n++) {   # ~10 min at 10s
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Method Head -TimeoutSec 20 -Uri $url
            if ($resp.StatusCode -eq 200) { Info "JitPack build of ${Repo}:${Tag} is ready."; return }
        } catch { }
        Start-Sleep -Seconds 10
    }
    Die "${Repo}:${Tag} not built on JitPack after 10 min - check https://jitpack.io/#$($script:Owner)/$Repo"
}

# ---- preflight all targeted modules up front ----
if ($SharedSpec) { Test-Preflight 'botmaker-shared' }
if ($SdkSpec)    { Test-Preflight 'botmaker-sdk' }
if ($StudioSpec) { Test-Preflight 'botmaker-studio' }
if ($PilotSpec)  { Test-Preflight 'botmaker-pilot' }

# ---- resolve specs into concrete versions, then show the plan ----
$SharedVer = ''; $SdkVer = ''; $StudioVer = ''; $PilotVer = ''
if ($SharedSpec) { $SharedVer = Resolve-Version 'botmaker-shared' $SharedSpec }
if ($SdkSpec)    { $SdkVer    = Resolve-Version 'botmaker-sdk'    $SdkSpec }
if ($StudioSpec) { $StudioVer = Resolve-Version 'botmaker-studio' $StudioSpec }
if ($PilotSpec)  { $PilotVer  = Resolve-Version 'botmaker-pilot'  $PilotSpec }

Info 'Release plan:'
if ($SharedVer) { Write-Host "    shared : $SharedSpec -> v$SharedVer" }
if ($SdkVer)    { Write-Host "    sdk    : $SdkSpec -> v$SdkVer" }
if ($StudioVer) { Write-Host "    studio : $StudioSpec -> v$StudioVer" }
if ($PilotVer)  { Write-Host "    pilot  : $PilotSpec -> v$PilotVer  (tags -> APK GitHub Release)" }

# A skipped module has its *Ver cleared, so downstream pom-pins and the pointer commit ignore it.

# ---- 1) pilot ----  (independent: tagged FIRST so its APK build runs in parallel with the JitPack waits)
if ($PilotVer) {
    if (Test-ShouldRelease 'botmaker-pilot' $PilotSpec $false) {
        Info "Releasing botmaker-pilot v$PilotVer"
        Invoke-CommitTagPush 'botmaker-pilot' $PilotVer ''
        Info "botmaker-pilot v$PilotVer tagged - its CI builds + publishes botpilot.apk (runs in parallel)."
    } else {
        Info 'botmaker-pilot: no changes since its latest tag - skipping'; $PilotVer = ''
    }
}

# ---- 2) shared ----
if ($SharedVer) {
    if (Test-ShouldRelease 'botmaker-shared' $SharedSpec $false) {
        Info "Releasing botmaker-shared v$SharedVer"
        Invoke-CommitTagPush 'botmaker-shared' $SharedVer ''   # no pom edit - its own version is cosmetic
        Wait-ForJitpack 'botmaker-shared' "v$SharedVer"
    } else {
        Info 'botmaker-shared: no changes since its latest tag - skipping'; $SharedVer = ''
    }
}

# ---- 3) sdk ----  (forced when shared released this run: JitPack must rebuild the SDK against new shared)
if ($SdkVer) {
    $forced = [bool]$SharedVer
    if (Test-ShouldRelease 'botmaker-sdk' $SdkSpec $forced) {
        Info "Releasing botmaker-sdk v$SdkVer"
        Invoke-CommitTagPush 'botmaker-sdk' $SdkVer ''
        Wait-ForJitpack 'botmaker-sdk' "v$SdkVer"
    } else {
        Info 'botmaker-sdk: no changes since its latest tag - skipping'; $SdkVer = ''
    }
}

# ---- 4) studio ----  (forced when shared or sdk released this run)
if ($StudioVer) {
    $forced = [bool]("$SharedVer$SdkVer")
    if (Test-ShouldRelease 'botmaker-studio' $StudioSpec $forced) {
        Info "Releasing botmaker-studio v$StudioVer"
        # New bots should default to the just-released SDK (a .java constant); the pom's shared.version
        # stays 0.0.0-SNAPSHOT (studio's release.yml injects the newest shared tag at build time).
        if ($SdkVer) {
            $mavenService = Join-Path $script:Root 'botmaker-studio/src/main/java/com/botmaker/studio/services/MavenService.java'
            Show-Cmd "set SDK_FALLBACK_VERSION -> $SdkVer in MavenService.java"
            if (-not $script:DryRun) {
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                $content = [System.IO.File]::ReadAllText($mavenService)
                $content = $content -replace '(SDK_FALLBACK_VERSION = ")[^"]*(")', ('${1}' + $SdkVer + '${2}')
                [System.IO.File]::WriteAllText($mavenService, $content, $utf8NoBom)
            }
        }
        Invoke-CommitTagPush 'botmaker-studio' $StudioVer "release: studio v$StudioVer"
    } else {
        Info 'botmaker-studio: no changes since its latest tag - skipping'; $StudioVer = ''
    }
}

# ---- 5) record moved submodule pointers in the umbrella ----
Info 'Recording submodule pointers in the umbrella'
$pointers = @()
if ($SharedVer) { Show-Cmd 'git add botmaker-shared'; if (-not $script:DryRun) { & git -C $script:Root add botmaker-shared }; $pointers += "shared v$SharedVer" }
if ($SdkVer)    { Show-Cmd 'git add botmaker-sdk';    if (-not $script:DryRun) { & git -C $script:Root add botmaker-sdk };    $pointers += "sdk v$SdkVer" }
if ($StudioVer) { Show-Cmd 'git add botmaker-studio'; if (-not $script:DryRun) { & git -C $script:Root add botmaker-studio }; $pointers += "studio v$StudioVer" }
if ($PilotVer)  { Show-Cmd 'git add botmaker-pilot';  if (-not $script:DryRun) { & git -C $script:Root add botmaker-pilot };  $pointers += "pilot v$PilotVer" }

$pointerMsg = "release: " + ($pointers -join ' ')
Show-Cmd "git commit -m '$pointerMsg' (if staged)"
if (-not $script:DryRun) {
    & git -C $script:Root diff --cached --quiet
    if ($LASTEXITCODE -ne 0) { & git -C $script:Root commit -m $pointerMsg }
}

$prefix = if ($script:DryRun) { '(dry run) ' } else { '' }
Info "Done. $prefix Released: $($pointers -join ' ')"
