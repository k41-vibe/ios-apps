# apps/<Name> を GitHub Actions(macOS) でビルドし、.ipa を iPhone 受け渡し用フォルダへ置く
# 使い方: .\tools\build.ps1 HelloLC [-NoPush]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [switch]$NoPush,
    [switch]$NoRelease,
    [int]$KeepAssets = 5,
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

# ---- リリースへの版の積み上げ ----------------------------------------------
# アプリごとにリリースは 1 つ(タグ = 小文字のアプリ名)。資産のファイル名に
# コミット番号を入れて積み、古いものは $KeepAssets 個を超えたら消す。
if (-not $NoRelease) {
    $tag = $Name.ToLower()
    $sha = (git rev-parse --short HEAD).Trim()
    $subject = (git log -1 --pretty=%s).Trim()
    $asset = "$Name-$sha.ipa"
    $assetPath = Join-Path "$root\dist" $asset
    Copy-Item $ipa.FullName $assetPath -Force

    if (-not (gh release view $tag --json tagName 2>$null)) {
        gh release create $tag --title "$Name" --notes "$Name のビルド置き場。資産のファイル名の末尾がコミット番号。" | Out-Null
        Write-Host "release 作成: $tag"
    }
    # 説明文の先頭に今回の行を足す(新しい版が上)
    $body = gh release view $tag --json body --jq .body
    $line = "- ``$sha`` $asset — $subject"
    gh release edit $tag --notes "$line`n$body" | Out-Null

    Write-Host "release へ添付中: $asset ..."
    gh release upload $tag $assetPath --clobber
    Remove-Item $assetPath -Force -ErrorAction SilentlyContinue

    # 古い資産の掃除(名前順ではなく更新時刻順で残す)
    $assets = gh release view $tag --json assets --jq '.assets | sort_by(.updatedAt) | reverse | .[].name'
    $old = @($assets) | Select-Object -Skip $KeepAssets
    foreach ($a in $old) {
        if ($a) { gh release delete-asset $tag $a --yes 2>$null; Write-Host "古い資産を削除: $a" }
    }
    $url = gh release view $tag --json url --jq .url
    Write-Host "release: $url  (最新資産 = $asset)"
}
