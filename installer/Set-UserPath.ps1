# Adds or removes a folder from the current user's PATH.
#
# The installers call this because Inno Setup's Pascal script cannot broadcast
# WM_SETTINGCHANGE on its own. Safe to run by hand:
#
#   .\Set-UserPath.ps1 -Dir "$env:LOCALAPPDATA\Programs\EmLoad\bin"
#   .\Set-UserPath.ps1 -Dir "$env:LOCALAPPDATA\Programs\EmLoad\bin" -Remove
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Dir,

    [switch]$Remove,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'PathTools.ps1')

$target = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\')

if ($Remove) {
    $changed = Remove-UserPath -Entry $target
    if (-not $Quiet) {
        if ($changed) { Write-Host "Removed $target from PATH." }
        else { Write-Host "$target was not on PATH." }
    }
}
else {
    $changed = Add-UserPath -Entry $target
    if (-not $Quiet) {
        if ($changed) { Write-Host "Added $target to PATH. Open a new terminal to use it." }
        else { Write-Host "$target is already on PATH." }
    }
}

exit 0
