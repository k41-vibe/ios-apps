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
    [string]$Dest = "$env:USERPROFILE\SharedFolder\ios-apps"
)
$ErrorActionPreference = "Stop"

# git は警告(CRLF の置換など)を stderr に書く。$ErrorActionPreference="Stop" のままだと
# それが NativeCommandError になって止まる(2026-09-13 に開発ビルドが git add で落ちた)。
# git を呼ぶときだけ Continue にし、終了コードで判断する。
function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)] $GitArgs)
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & git.exe -c core.safecrlf=false @GitArgs 2>$null } finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed ($LASTEXITCODE)" }
}
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
    # [IO.File] は .NET のカレントディレクトリを見る。Set-Location は PowerShell の
    # 位置しか変えないので、相対パスのままだと起動時のディレクトリ次第で外す
    $changelog = Join-Path $root "apps\$Name\CHANGELOG.md"
    if (-not (Test-Path $changelog)) { throw "$changelog がありません (docs/VERSIONING.md)" }
    $text = [IO.File]::ReadAllText($changelog)
    if ($text -notmatch '## \[Unreleased\]') { throw "$changelog に '## [Unreleased]' がありません" }
    $today = (Get-Date).ToString("yyyy-MM-dd")
    $text = $text -replace '## \[Unreleased\]', "## [Unreleased]`n`n## [$Release] - $today"
    [IO.File]::WriteAllText($changelog, $text, (New-Object Text.UTF8Encoding $false))

    # リリースも作りかけを巻き込まないよう、このアプリと共有ツールだけを積む
    Invoke-Git add --ignore-removal "apps/$Name" shared tools docs .github
    Invoke-Git commit -q -m "release: $Name v$Release"
    Invoke-Git push -q origin main
    Invoke-Git tag -a $tag -m "$Name v$Release"
    Invoke-Git push -q origin $tag
    Write-Host "タグ $tag を push。CI がリリースビルドを開始します"
} else {
    # ---- 開発ビルド: コミット/push してから workflow_dispatch ----
    if (-not $NoPush) {
        # 作りかけを巻き込まないよう、このアプリと共有ツールだけを commit する
        # (以前 git add -A で、別作業中のエージェントが書いた途中のファイルを
        #  ビルドに載せかけた。何を積んだかは下に出す)
        Invoke-Git add --ignore-removal "apps/$Name" shared tools docs .github
        # `git diff --cached --quiet` は出力を持たないので、if に直接書くと常に偽になる
        # (2026-09-13: 何も無いのに commit しようとして落ちた)。終了コードで見る
        & git.exe diff --cached --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "commit するものなし (HEAD をビルドします)"
        } else {
            Write-Host "--- この commit に載るもの ---"
            git diff --cached --name-only | ForEach-Object { Write-Host "  $_" }
            Invoke-Git commit -q -m "build: $Name"
        }
        $stray = git status --porcelain
        if ($stray) {
            Write-Host "--- commit していない変更 (ビルドには載りません) ---"
            $stray | ForEach-Object { Write-Host "  $_" }
        }
        Invoke-Git push -q origin main
    }
    # workflow_dispatch が落ちる(GitHub 側の 500、2026-09-13)ときは build/<Name> ブランチへの
    # push で同じビルドを起動する(build.yml の push.branches)
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    gh workflow run build.yml -f app=$Name 2>$null | Out-Null
    $dispatched = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $old
    if (-not $dispatched) {
        Write-Host "workflow_dispatch が失敗したので build/$Name への push で起動します"
        Invoke-Git push -q -f origin "HEAD:refs/heads/build/$Name"
    }
}

$runId = Wait-NewRun $before
Write-Host "run: https://github.com/$repo/actions/runs/$runId"

$assetTag = if ($tag) { $tag } else { "dev-$Name" }
gh run watch $runId --exit-status
if ($LASTEXITCODE -ne 0) {
    Write-Host "--- build.log (末尾) ---"
    $tmp = Join-Path $env:TEMP "ios-apps-log-$runId"
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    gh release download $assetTag -p "build.log" -D $tmp --clobber 2>$null
    $ErrorActionPreference = $old
    Get-Content (Join-Path $tmp "build.log") -Tail 40 -ErrorAction SilentlyContinue
    throw "ビルド失敗 (run $runId)"
}

New-Item -ItemType Directory -Force $Dest | Out-Null
New-Item -ItemType Directory -Force "$root\dist" | Out-Null
$tmp = Join-Path $env:TEMP "ios-apps-ipa-$runId"
# ipa は Release 資産($assetTag)から取る。開発ビルドは dev-<Name>、リリースは <name>-vX.Y.Z。
# (アーティファクト容量は無料枠 500MB で溜まり、上限に達すると 6〜12 時間 upload が止まるため)。
# 大きい ipa は途中で切れることがあるので 3 回まで再試行
$ipa = $null
for ($try = 1; $try -le 3 -and -not $ipa; $try++) {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    try {
        $ErrorActionPreference = "Continue"
        gh release download $assetTag -p "$Name.ipa" -D $tmp --clobber 2>&1 | Out-Null
    } catch {
        Write-Host "download error: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = "Stop"
    }
    $ipa = Get-ChildItem $tmp -Filter *.ipa -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $ipa) { Write-Host "download retry $try"; Start-Sleep -Seconds 8 }
}
if (-not $ipa) { throw "ipa のダウンロードに失敗 (run $runId)。Release $assetTag から手動で取れます" }
Copy-Item $ipa.FullName "$root\dist\$Name.ipa" -Force
Copy-Item $ipa.FullName "$Dest\$Name.ipa" -Force
Write-Host "完成: $Dest\$Name.ipa  ($([math]::Round($ipa.Length/1KB)) KB)"
Write-Host "iPhone: ファイルApp → SharedFolder/ios-apps/$Name.ipa → 共有 → LiveContainer"

# ---- 取り込み経路 ----------------------------------------------------------
# Syncthing が止まっていると SharedFolder は iPhone に届かない(2026-09-12 に発覚)。
# 代わりに dist/ を LAN と Tailscale に配る小さなサーバーを立てておく。
# LiveContainer は URL から取り込めるので、毎回同じ URL を貼るだけで済む。
$port = 8788
$listening = $false
try {
    $listening = [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
} catch { }
if (-not $listening) {
    $py = (Get-Command pythonw.exe -ErrorAction SilentlyContinue)
    if (-not $py) { $py = (Get-Command python.exe -ErrorAction SilentlyContinue) }
    if ($py) {
        $script = Join-Path $root 'tools\serve-ipa.py'
        Start-Process -FilePath $py.Source -ArgumentList "`"$script`"", $port -WindowStyle Hidden
        Start-Sleep -Seconds 2
        Write-Host "ipa 配布サーバーを起こしました (ポート $port)"
    }
}
$urls = @()
try {
    $s = New-Object Net.Sockets.UdpClient
    $s.Connect("8.8.8.8", 80)
    $urls += "LAN       http://$($s.Client.LocalEndPoint.Address):$port/$Name.ipa"
    $s.Close()
} catch { }
$tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
if (Test-Path $tsExe) {
    $ts = (& $tsExe ip -4 2>$null | Select-Object -First 1)
    if ($ts) { $urls += "Tailscale http://$($ts.Trim()):$port/$Name.ipa" }
}
$sync = Get-Process -Name syncthing -ErrorAction SilentlyContinue
if (-not $sync) {
    Write-Host "注意: Syncthing が動いていないので SharedFolder は iPhone に届きません"
}
Write-Host "iPhone: LiveContainer の + に URL を貼る:"
foreach ($u in $urls) { Write-Host "  $u" }

# ---- Discord 通知(任意) ---------------------------------------------------
# tools/discord-webhook.txt(git 管理外)に Webhook URL があれば、出来上がりを知らせる。
# 版・ビルド番号は配布サーバーの manifest(ipa の Info.plist から生成)を読む
$hook = Join-Path $root 'tools\discord-webhook.txt'
if (Test-Path $hook) {
    try {
        $m = Invoke-RestMethod -UseBasicParsing -TimeoutSec 5 "http://127.0.0.1:$port/$Name.json"
        $text = "$Name build $($m.build) ($($m.version) $($m.commit)) が配布サーバーに載りました。アプリの「更新」から取り込めます"
        if ($tag) { $text = "$Name v$Release (build $($m.build)) をリリースしました。アプリの「更新」から取り込めます" }
        $body = [Text.Encoding]::UTF8.GetBytes((@{ content = $text } | ConvertTo-Json -Compress))
        Invoke-RestMethod -UseBasicParsing -Method Post -Uri (Get-Content $hook -Raw).Trim() `
            -ContentType 'application/json; charset=utf-8' -Body $body | Out-Null
        Write-Host "Discord に通知しました"
    } catch {
        Write-Host "Discord 通知に失敗: $($_.Exception.Message)"
    }
}

if ($tag) {
    # kioku と同じ 1 版 = 1 リリース(タグ <app>-vX.Y.Z、資産は <App>.ipa 固定)
    $url = gh release view $tag --json url --jq .url 2>$null
    Write-Host "Release: $url"
    Write-Host "LiveContainer の一覧とアプリ画面に v$Release と出れば新版が入っています"
}
