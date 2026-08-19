param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [string]$Base = "main"
)

$ErrorActionPreference = "Stop"
$repoRoot = (git rev-parse --show-toplevel).Trim()
$parent = Split-Path $repoRoot -Parent
$path = Join-Path $parent ("worktree-" + $Name)
$branch = "agent/" + $Name

if (Test-Path $path) {
    throw "Worktree path already exists: $path"
}

Write-Host "Creating $branch from $Base at $path"
git worktree add -b $branch $path $Base
Write-Host "Created. Open this directory in a separate Claude Code or Codex session: $path"
