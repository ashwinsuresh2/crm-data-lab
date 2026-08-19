$ErrorActionPreference = "Stop"

Write-Host "== Git whitespace check =="
git diff --check

if (Test-Path "package.json") {
    Write-Host "== JavaScript/TypeScript checks =="
    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        pnpm install --frozen-lockfile
        pnpm run typecheck --if-present
        pnpm run lint --if-present
        pnpm test --if-present
    } elseif (Get-Command npm -ErrorAction SilentlyContinue) {
        npm ci
        npm run typecheck --if-present
        npm run lint --if-present
        npm test --if-present
    } else {
        throw "Neither pnpm nor npm is installed."
    }
}

if (Test-Path "docker-compose.yml" -or Test-Path "compose.yml") {
    Write-Host "== Docker Compose validation =="
    docker compose config --quiet
}

Write-Host "Verification script completed. Project-specific checks should be added as the repository is scaffolded."
