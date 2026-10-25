# Shared helpers for editing the current user's PATH.
#
# Dot-source this file; do not run it directly.
#
# EmLoad never touches the machine-wide PATH and never needs admin rights. Both
# installers use these functions so an entry is added once and removed cleanly.

function Update-Environment {
    <# Tell Explorer that the environment changed, so new terminals see it. #>
    try {
        Add-Type -Namespace EmLoadInstaller -Name Native -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@ -ErrorAction Stop
    }
    catch {
        # Already loaded in this session; harmless.
    }

    try {
        $result = [UIntPtr]::Zero
        [EmLoadInstaller.Native]::SendMessageTimeout(
            [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
    }
    catch { }
}

function Get-PathEntries {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-PathEntry {
    param([string]$Value, [string]$Entry)

    $wanted = $Entry.TrimEnd('\')
    foreach ($item in (Get-PathEntries $Value)) {
        if ($item.TrimEnd('\') -ieq $wanted) { return $true }
    }
    return $false
}

function Add-UserPath {
    <# Returns $true when the PATH was changed. #>
    param([Parameter(Mandatory = $true)][string]$Entry)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Test-PathEntry $current $Entry) { return $false }

    $updated = (@((Get-PathEntries $current) + $Entry) -join ';')
    [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
    Update-Environment
    return $true
}

function Remove-UserPath {
    <# Returns $true when the PATH was changed. #>
    param([Parameter(Mandatory = $true)][string]$Entry)

    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Test-PathEntry $current $Entry)) { return $false }

    $wanted = $Entry.TrimEnd('\')
    $kept = @(Get-PathEntries $current | Where-Object { $_.TrimEnd('\') -ine $wanted })
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    Update-Environment
    return $true
}
