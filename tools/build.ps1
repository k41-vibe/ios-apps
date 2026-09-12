# apps/<Name> を GitHub Actions(macOS) でビルドし、.ipa を iPhone 受け渡し用フォルダへ置く
#
#   開発ビルド : .\tools\build.ps1 XiOSLite            版 0.0.YYYYMMDD、Release は作らない
#   リリース   : .\tools\build.ps1 XiOSLite -Release 0.1.0
#                CHANGELOG の [Unreleased] を確定 → タグ xioslite-v0.1.0 を push → CI が Release を発行
#   決まりは docs/VERSIONING.md
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Release = "",
    [switch]$NoPush,
    [string]$Dest = "C:\Users\rutoi\SharedFolder\ios-apps"
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if (-not (Test-Path "apps\$Name\project.yml")) { throw "apps\$Name\project.yml がありません" }
$repo = gh repo view --json nameWithOwner --jq .nameWithOwner

function Wait-NewRun([string]$before) {
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 3
        $latest = gh run list --workflow build.yml -L 1 --json databaseId --jq '.[0].databaseId' 2>$null
        if ($latest -and $latest -ne $before) { return $latest }
    }
    throw "run が始まりません (gh auth status を確認)"
}

$before = gh run list --workflow build.yml -L 1 --json databaseId --jq '.[0].databaseId' 2>$null
$tag = $null

if ($Release) {
    # ---- リリース: CHANGELOG 確定 → コミット → タグ push(タグ push が CI を起動する) ----
    if ($Release -notmatch '^\d+\.\d+\.\d+$') { throw "-Release は X.Y.Z 形式で ($Release)" }
    $tag = "$($Name.ToLower())-v$Release"
    if (git tag -l $tag) { throw "タグ $tag は既にあります" }
    $changelog = "apps\$Name\CHANGELOG.md"
    if (-not (Test-Path $changelog)) { throw "$changelog がありません (docs/VERSIONING.md)" }
    $text = [IO.File]::ReadAllText($changelog)
    if ($text -notmatch '## \[Unreleased\]') { throw "$changelog に '## [Unreleased]' がありません" }
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $text = $text -replace '## \[Unreleased\]', "## [Unreleased]`n`n## [$Release] - $today"
    [IO.File]::WriteAllText($changelog, $text, (New-Object Text.UTF8Encoding $false))

    git add -A
    git commit -q -m "release: $Name v$Release" 2>&1 | Out-Null
    git push -q origin main
    git tag -a $tag -m "$Name v$Release"
    git push -q origin $tag
    Write-Host "タグ $tag を push。CI がリリースビルドを開始します"
} else {
    # ---- 開発ビルド: コミット/push してから workflow_dispatch ----
    if (-not $NoPush) {
        git add -A
        if (git status --porcelain) {
            git commit -q -m "build: $Name" 2>&1 | Out-Null
        }
        git push -q origin main 2>&1 | Out-Null
    }
    gh workflow run build.yml -f app=$Name | Out-Null
}

$runId = Wait-NewRun $before
Write-Host "run: https://github.com/$repo/actions/runs/$runId"

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
# 大きい ipa(100MB 級)は途中で接続が切れることがあるので 3 回まで再試行
$ipa = $null
for ($try = 1; $try -le 3 -and -not $ipa; $try++) {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    gh run download $runId -n "$Name.ipa" -D $tmp 2>&1 | Out-Null
    $ipa = Get-ChildItem $tmp -Filter *.ipa -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ipa) { Write-Host "download retry $try"; Start-Sleep -Seconds 5 }
}
if (-not $ipa) { throw "ipa のダウンロードに失敗 (run $runId)" }
Copy-Item $ipa.FullName "$root\dist\$Name.ipa" -Force
Copy-Item $ipa.FullName "$Dest\$Name.ipa" -Force
Write-Host "完成: $Dest\$Name.ipa  ($([math]::Round($ipa.Length/1KB)) KB)"
Write-Host "iPhone: ファイルApp → SharedFolder/ios-apps/$Name.ipa → 共有 → LiveContainer"
if ($tag) {
    # Release はアプリごとに 1 つ(タグ = 小文字のアプリ名)。資産は版ごとに <App>-vX.Y.Z.ipa
    $rel = $Name.ToLower()
    $url = gh release view $rel --json url --jq .url 2>$null
    Write-Host "Release: $url"
    Write-Host "資産: $Name-v$Release.ipa   (ソースは git タグ $tag)"
    Write-Host "LiveContainer の一覧に v$Release と出れば新版が入っています"
}
