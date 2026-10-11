# win-privacy.ps1 (ASCII only - Windows PowerShell 5.1 reads scripts as ANSI).
# Russian texts and the list of settings live in win-privacy.json (UTF-8) next to this file.
#
# Sets Windows / Edge / Office privacy with regular policy registry values. No services are
# stopped, no hosts or firewall blocks, no third-party tools.
#   win-privacy.ps1                     check: show current vs wanted, change nothing (no admin)
#   win-privacy.ps1 -Apply              apply; previous values go to backup\ for -Undo
#   win-privacy.ps1 -Apply -Skip OneDrive,Location     leave these groups alone
#   win-privacy.ps1 -Undo               put back the values saved by the latest -Apply
# -Apply and -Undo elevate themselves (UAC) and continue in a new window; every run writes
# a log to logs\. HKCU values belong to the user who runs the script.
param(
    [switch]$Apply,
    [switch]$Undo,
    [string]$Skip = '',
    [string]$BackupFile = '',
    [switch]$Elevated
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $root 'win-privacy.json'), [Text.Encoding]::UTF8))
$M = $cfg.messages
$mode = if ($Undo) { 'undo' } elseif ($Apply) { 'apply' } else { 'check' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path $root 'logs'
$backupDir = Join-Path $root 'backup'
$logFile = Join-Path $logDir "win-privacy-$mode-$stamp.log"
$utf8Bom = New-Object Text.UTF8Encoding($true)
$logOk = $true

function Say([string]$text, [string]$color = 'Gray') {
    Write-Host $text -ForegroundColor $color
    if (-not $script:logOk) { return }
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
        [IO.File]::AppendAllText($logFile, $text + "`r`n", $utf8Bom)
    } catch {
        $script:logOk = $false
        Write-Host ($M.log_failed -f $logDir, $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Finish([int]$code) {
    if ($script:logOk) { Say ($M.log_saved -f $logFile) }
    if ($Elevated) { Read-Host $M.press_enter | Out-Null }
    exit $code
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# -Apply / -Undo need admin: restart this script elevated (Start-Process -Verb RunAs works with -File only).
if ($mode -ne 'check' -and -not $isAdmin) {
    Write-Host $M.need_admin -ForegroundColor Yellow
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"
    if ($Apply) { $a += ' -Apply' }
    if ($Undo) { $a += ' -Undo' }
    if ($Skip) { $a += " -Skip `"$Skip`"" }
    if ($BackupFile) { $a += " -BackupFile `"$BackupFile`"" }
    try {
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList $a
        Write-Host ($M.elevated_started -f $logDir)
        exit 0
    } catch {
        Write-Host ($M.uac_declined -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}

function Open-Base([string]$hive) {
    $h = if ($hive -eq 'HKLM') { [Microsoft.Win32.RegistryHive]::LocalMachine } else { [Microsoft.Win32.RegistryHive]::CurrentUser }
    [Microsoft.Win32.RegistryKey]::OpenBaseKey($h, [Microsoft.Win32.RegistryView]::Registry64)
}

# Current state of one value: @{ exists; value; kind }.
function Get-State([string]$hive, [string]$path, [string]$name) {
    $base = Open-Base $hive
    try {
        $k = $base.OpenSubKey($path)
        if ($null -eq $k) { return @{ exists = $false } }
        try {
            $v = $k.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -eq $v) { return @{ exists = $false } }
            return @{ exists = $true; value = $v; kind = $k.GetValueKind($name).ToString() }
        } finally { $k.Close() }
    } finally { $base.Close() }
}

function Set-Value([string]$hive, [string]$path, [string]$name, $value, [string]$kind) {
    $typed = switch ($kind) {
        'DWord' { [int]$value }
        'QWord' { [long]$value }
        'Binary' { [byte[]]$value }
        'MultiString' { [string[]]$value }
        default { [string]$value }
    }
    $base = Open-Base $hive
    try {
        $k = $base.CreateSubKey($path)
        try { $k.SetValue($name, $typed, [Microsoft.Win32.RegistryValueKind]$kind) } finally { $k.Close() }
    } finally { $base.Close() }
}

function Remove-Value([string]$hive, [string]$path, [string]$name) {
    $base = Open-Base $hive
    try {
        $k = $base.OpenSubKey($path, $true)
        if ($null -ne $k) { try { $k.DeleteValue($name, $false) } finally { $k.Close() } }
    } finally { $base.Close() }
}

function Show-Value($state) {
    if (-not $state.exists) { return $M.not_set }
    if ($state.value -is [array]) { return ($state.value -join ',') }
    return [string]$state.value
}

$edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
$who = "$env:USERDOMAIN\$env:USERNAME"
Say $M.title 'Cyan'
Say $M.("mode_$mode") 'Cyan'
Say ($M.who -f $env:COMPUTERNAME, $who, $edition, $(if ($isAdmin) { $M.yes } else { $M.no }))
Say ($M.hkcu_note -f $who)
if ($edition -notmatch 'Enterprise|Education|Server') { Say $M.pro_note 'Yellow' }
Say ''

# ---------------------------------------------------------------- undo
if ($mode -eq 'undo') {
    $file = $BackupFile
    if (-not $file) {
        $latest = $null
        if (Test-Path -LiteralPath $backupDir) {
            $latest = Get-ChildItem -LiteralPath $backupDir -Filter "$env:COMPUTERNAME-$env:USERNAME-*.json" |
                Sort-Object Name -Descending | Select-Object -First 1
        }
        if ($null -eq $latest) { Say ($M.undo_none -f $who, $backupDir) 'Yellow'; Finish 1 }
        $file = $latest.FullName
    }
    $b = ConvertFrom-Json ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8))
    if ($b.computer -ne $env:COMPUTERNAME -or $b.user -ne $env:USERNAME) {
        Say ($M.undo_wrong -f $b.computer, $b.user) 'Red'; Finish 1
    }
    Say ($M.undo_using -f $file, $b.created)
    $done = 0; $failed = 0
    foreach ($it in $b.items) {
        $label = "$($it.hive)\$($it.path)\$($it.name)"
        try {
            if ($it.existed) {
                Set-Value $it.hive $it.path $it.name $it.value $it.kind
                Say ($M.st_restored -f $label, $(if ($it.value -is [array]) { $it.value -join ',' } else { $it.value })) 'Green'
            } else {
                Remove-Value $it.hive $it.path $it.name
                Say ($M.st_removed -f $label) 'Green'
            }
            $done++
        } catch { $failed++; Say ($M.st_fail -f $label, $_.Exception.Message) 'Red' }
    }
    if ($failed -eq 0) { Rename-Item -LiteralPath $file -NewName ((Split-Path -Leaf $file) + '.undone') }
    Say ''
    Say ($M.sum_undo -f $done, $failed) 'Cyan'
    Say $M.reboot 'Yellow'
    Finish $(if ($failed) { 1 } else { 0 })
}

# ---------------------------------------------------------------- check / apply
$ids = @($cfg.groups | ForEach-Object { $_.id })
$skipIds = @($Skip -split '[,; ]+' | Where-Object { $_ })
foreach ($s in $skipIds) {
    if ($ids -notcontains $s) { Say ($M.skip_unknown -f $s, ($ids -join ', ')) 'Red'; Finish 1 }
}

$total = 0; $same = 0; $changed = 0; $failed = 0
$saved = New-Object System.Collections.ArrayList
foreach ($g in $cfg.groups) {
    if ($skipIds -contains $g.id) { Say ($M.group_skipped -f $g.title, $g.id) 'DarkGray'; Say ''; continue }
    Say ($M.group -f $g.title, $g.id) 'White'
    foreach ($it in $g.items) {
        $total++
        $label = "$($it.hive)\$($it.path)\$($it.name)"
        $st = Get-State $it.hive $it.path $it.name
        # "kind" in the json is the registry type (DWord unless stated, String for environment variables);
        # "accept" lists other values that are fine as they are (e.g. AllowTelemetry 0).
        $kind = if ($it.kind) { $it.kind } else { 'DWord' }
        if ($st.exists -and $st.kind -eq $kind -and (@($it.value) + @($it.accept) -contains $st.value)) {
            $same++
            Say ($M.st_ok -f $label, $st.value, $it.note) 'DarkGreen'
        } elseif ($mode -eq 'check') {
            Say ($M.st_diff -f $label, (Show-Value $st), $it.value, $it.note) 'Yellow'
        } else {
            try {
                Set-Value $it.hive $it.path $it.name $it.value $kind
                [void]$saved.Add([ordered]@{ hive = $it.hive; path = $it.path; name = $it.name
                        existed = [bool]$st.exists; value = $st.value; kind = $st.kind })
                $changed++
                Say ($M.st_set -f $label, (Show-Value $st), $it.value, $it.note) 'Green'
            } catch { $failed++; Say ($M.st_fail -f $label, $_.Exception.Message) 'Red' }
        }
    }
    if ($g.id -eq 'Defender') {
        try {
            $mp = Get-MpPreference -ErrorAction Stop
            Say ($M.defender_effective -f $mp.MAPSReporting, $mp.SubmitSamplesConsent) 'DarkGray'
        } catch { }
    }
    Say ''
}

if ($mode -eq 'check') {
    Say ($M.sum_check -f $same, $total, ($total - $same)) 'Cyan'
    if ($total -ne $same) { Say $M.sum_check_hint }
    Finish 0
}

Say ($M.sum_apply -f $changed, $same, $failed) 'Cyan'
if ($saved.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    $bf = Join-Path $backupDir "$env:COMPUTERNAME-$env:USERNAME-$stamp.json"
    $doc = [ordered]@{ computer = $env:COMPUTERNAME; user = $env:USERNAME
        created = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); items = $saved }
    [IO.File]::WriteAllText($bf, (ConvertTo-Json $doc -Depth 6), $utf8Bom)
    Say ($M.backup_saved -f $bf)
    Say $M.reboot 'Yellow'
} else {
    Say $M.nothing_changed
}
Finish $(if ($failed) { 1 } else { 0 })
