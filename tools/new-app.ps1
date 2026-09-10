# 新しいアプリの雛形を apps/<Name> に作る
# 使い方: .\tools\new-app.ps1 HelloLC
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z][A-Za-z0-9]{1,30}$')][string]$Name
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$dst = Join-Path $root "apps\$Name"
if (Test-Path $dst) { throw "apps\$Name は既にあります" }

Copy-Item (Join-Path $root "templates\app") $dst -Recurse
Get-ChildItem $dst -Recurse -File | ForEach-Object {
    $t = [IO.File]::ReadAllText($_.FullName)
    $t = $t.Replace("__APP_LOWER__", $Name.ToLower()).Replace("__APP__", $Name)
    [IO.File]::WriteAllText($_.FullName, $t, (New-Object Text.UTF8Encoding $false))
}
Rename-Item (Join-Path $dst "Sources\App.swift") "$($Name)App.swift"
Write-Host "作成: $dst"
Write-Host "次: .\tools\build.ps1 $Name"
