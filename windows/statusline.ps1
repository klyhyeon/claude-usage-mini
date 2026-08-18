# Claude Code statusline for Windows (PowerShell).
#
# Reads the caches ClaudeUsageMini writes and renders one line:
#   <dir> | <branch> | <model> (<effort>) | Usage: NN% | Weekly: NN% | Fable: NN%
#
# Register it in %USERPROFILE%\.claude\settings.json:
#   "statusLine": { "type": "command",
#     "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\statusline.ps1\"" }

$ErrorActionPreference = 'SilentlyContinue'
$input_json = [Console]::In.ReadToEnd()
$data = $input_json | ConvertFrom-Json

$parts = @()

# Directory
$cwd = $data.workspace.current_dir
if ($cwd) { $parts += Split-Path $cwd -Leaf }

# Branch
$branch = git -C $cwd rev-parse --abbrev-ref HEAD 2>$null
if ($branch) { $parts += $branch }

# Model (+ effort)
$model = $data.model.display_name
if ($model) {
    $effort = $data.effort.level
    if ($effort) { $parts += "$model ($effort)" } else { $parts += $model }
}

# Context %
$ctx = $data.context_window.used_percentage
if ($null -ne $ctx) { $parts += "Ctx: $ctx%" }

function Read-Cache($name) {
    $path = Join-Path $env:USERPROFILE ".claude\$name"
    if (-not (Test-Path $path)) { return $null }
    $lines = Get-Content $path
    $map = @{}
    foreach ($l in $lines) {
        $kv = $l -split '=', 2
        if ($kv.Count -eq 2) { $map[$kv[0]] = $kv[1] }
    }
    # Only trust a cache the app refreshed in the last 5 minutes.
    $ts = [int64]$map['TIMESTAMP']
    $now = [int64][double]::Parse((Get-Date -UFormat %s))
    if (($now - $ts) -ge 300) { return $null }
    return $map
}

# Usage / Weekly
$usage = Read-Cache '.statusline-usage-cache'
if ($usage) {
    if ($usage['UTILIZATION']) { $parts += "Usage: $($usage['UTILIZATION'])%" }
    if ($usage['WEEKLY_UTILIZATION']) { $parts += "Weekly: $($usage['WEEKLY_UTILIZATION'])%" }
}

# Fable
$fable = Read-Cache '.statusline-fable-cache'
if ($fable -and $fable['FABLE_UTILIZATION']) { $parts += "Fable: $($fable['FABLE_UTILIZATION'])%" }

$parts -join ' | '
