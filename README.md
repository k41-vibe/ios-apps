# ios-apps

Windows から iOS アプリを作って LiveContainer で動かすための土台。
ビルドは GitHub Actions の macOS ランナーが行う。手順は `CLAUDE.md` を参照。

```powershell
.\tools\new-app.ps1 MyApp     # 雛形を作る
.\tools\build.ps1 MyApp       # ビルドして SharedFolder\ios-apps\MyApp.ipa に置く
```
