# Windows開発環境

## 構成

- Git: `C:\develop\bin\Git\cmd\git.exe`（既存）
- Flutter 3.47.2: `C:\develop\sdks\flutter`
- Dart 3.13.2: Flutterに同梱
- Temurin JDK 17.0.20.1+1: `C:\develop\sdks\jdk-17.0.20.1+1`
- Android SDK: `%LOCALAPPDATA%\Android\Sdk`（既存を使用）
- Android command-line tools: 19.0（`cmdline-tools\latest`）
- NDK: 28.2.13676358（r28c）

SDKをGit本体と分離し、Git Bashに依存しない構成にしています。
Git Bash自体の不具合を確認したわけではありません。

## 今回確認した問題と対応

1. Codex通常実行が `helper_unknown_error: setup refresh had errors` で起動に失敗。
   明示的なPowerShell指定でも同じエラーとなり、サンドボックス外の実行は成功しました。
   Codexのサンドボックス設定・ACLは変更していません。開発ツールの修復とこのエラーは別問題です。
2. 既存Android StudioのJBRで `jbr\lib\jvm.cfg` が欠け、Java起動に失敗。
   既存JBRは上書きせず、公式Temurin JDKを追加しFlutterに指定しました。
3. Flutterが未導入。公式リポジトリのstable（3.47.2）から導入しました。
4. Androidコマンドラインツールが未導入。最新版23.0では新Android CLIに転送され、
   FlutterのNDK自動取得が `Package ndk not found` で失敗しました。
   チェックサム確認済みの公式19.0へ切り替え、NDKを取得しました。
   23.0はSDK内の `cmdline-tools\23.0` に保持しています。
5. `.git` がCodexSandboxOffline所有のため通常ユーザーでGitが拒否。
   `safe.directory` にこのリポジトリの絶対パスだけを追加しました。ワイルドカードは使っていません。

## 通常の作業

```powershell
# このセッションで開発ツールを使う
. .\scripts\dev-env.ps1
flutter --version
flutter doctor -v
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

スクリプト実行ポリシーで拒否される場合はREADMEのラッパー実行方法を使ってください。
ユーザー・マシンのPATHとJAVA_HOMEは変更していません。スクリプトは現在のプロセスの環境だけを設定します。
Flutter自身の設定にはJDKとAndroid SDKのパスを保存しています。
VS Code向けのローカル `.vscode/settings.json` はGit対象外です。

別の場所へSDKを導入した場合は、次のように指定できます。

```powershell
. .\scripts\dev-env.ps1 -FlutterRoot C:\path\flutter -JavaRoot C:\path\jdk -AndroidSdk C:\path\android-sdk
flutter config --jdk-dir="$env:JAVA_HOME" --android-sdk="$env:ANDROID_HOME"
```

Android Studioでこのプロジェクトを開く場合は、Flutterプラグインを有効にし、Flutter SDKに上記パスを指定してください。
Gradle JDKもTemurinのパスに設定します。Android Studio自体の起動は今回検証していません。

## 診断時の注意

- Visual Studio未導入の警告はWindowsデスクトップ版向けです。iOS / Androidの作業には不要です。
- SDK XML version 4の警告が残る場合があります。ビルドの終了コードで成否を判断してください。
- 未使用SDKを含むライセンスの一括承諾はしていません。
  追加SDKのライセンス確認が必要になった場合は `flutter doctor --android-licenses` を実行して内容を確認してください。
- Android実機は接続されていません。実機での動作確認は別途必要です。

## Mac / iOS

MacにもFlutter 3.47.2とXcodeを導入し、このプロジェクトで `flutter pub get`、`flutter doctor -v` を実行します。
Xcodeで `ios/Runner.xcworkspace` を開き、Signing & Capabilitiesで自分のTeamを選択して接続したiPhoneで実行します。
WindowsではiOSのビルド・署名・実機検証は行えません。

## 配布物

`flutter build apk --debug` の出力は `build/app/outputs/flutter-apk/app-debug.apk` です。
現段階では環境検証用テンプレートのAPKであり、PeerCast機能を持つ完成版ではありません。

## 検証結果（2026-09-07）

- Flutter 3.47.2 / Dart 3.13.2: 新しいPowerShellプロセスで起動成功。
- Temurin JDK: `java -version` 成功。
- `flutter pub get`: 成功。
- `flutter analyze`: No issues found。
- `flutter test`: テンプレートのCounter increments smoke test 1件成功。
- `flutter build apk --debug`: 成功。
- 検証したAPK: `build/app/outputs/flutter-apk/app-debug.apk`。
- PeerCast機能、リレー、掲示板投稿、Android実機、iOSビルド・実機検証は未実施。
