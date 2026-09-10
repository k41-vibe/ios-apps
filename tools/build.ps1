# apps/<Name> を GitHub Actions(macOS) でビルドし、.ipa を iPhone 受け渡し用フォルダへ置く
# 使い方: .\tools\build.ps1 HelloLC [-NoPush]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [switch]$NoPush,
    [string]$Dest = "C:\Users\rutoi\SharedFolder\ios-apps"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if (-not (Test-Path "apps\$Name\project.yml")) { throw "apps\$Name\project.yml がありません" }

if (-not $NoPush) {
    git add -A
    if (git status --porcelain) {
        git commit -q -m "build: $Name" 2>&1 | Out-Null
    }
    git push -q origin main 2>&1 | Out-Null
}

# 直前の run id を控えてから dispatch し、新しい run が現れるのを待つ
$before = gh run list --workflow build.yml -L 1 --json databaseId --jq '.[0].databaseId' 2>$null
gh workflow run build.yml -f app=$Name | Out-Null
$runId = $null
for ($i = 0; $i -lt 30 -and -not $runId; $i++) {
    Start-Sleep -Seconds 3
    $latest = gh run list --workflow build.yml -L 1 --json databaseId --jq '.[0].databaseId' 2>$null
    if ($latest -and $latest -ne $before) { $runId = $latest }
}
if (-not $runId) { throw "run が始まりません (gh auth status を確認)" }
Write-Host "run: https://github.com/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/actions/runs/$runId"

gh run watch $runId --exit-status
if ($LASTEXITCODE -ne 0) {
    Write-Host "--- build.log (末尾) ---"
    $tmp = Join-Path $env:TEMP "ios-apps-log-$runId"
    gh run download $runId -n "$Name-build.log" -D $tmp 2>$null
    Get-Content (Join-Path $tmp "build.log") -Tail 40 -ErrorAction SilentlyContinue
    throw "ビルド失敗 (run $runId)"
}

New-Item -ItemType Directory -Force $Dest | Out-Null
New-Item -ItemType Directory -Force "$root\dist" | Out-Null
$tmp = Join-Path $env:TEMP "ios-apps-ipa-$runId"
gh run download $runId -n "$Name.ipa" -D $tmp
$ipa = Get-ChildItem $tmp -Filter *.ipa -Recurse | Select-Object -First 1
Copy-Item $ipa.FullName "$root\dist\$Name.ipa" -Force
Copy-Item $ipa.FullName "$Dest\$Name.ipa" -Force
Write-Host "完成: $Dest\$Name.ipa  ($([math]::Round($ipa.Length/1KB)) KB)"
Write-Host "iPhone: ファイルApp → SharedFolder/ios-apps/$Name.ipa → 共有 → LiveContainer"
