# PeerCast App

FlutterによるiOS / Android向けPeerCastクライアント。

## 現在の状態

開発環境を構築し、Flutter公式テンプレートを作成した段階です。
現在の画面は環境検証用のカウンターです。PeerCast視聴・リレー・YP・掲示板機能はまだ実装していません。
取得した `native/peercast-yt` は調査用の上流ソースで、アプリには未リンクです。

- Windowsの開発・実行方法: [開発環境](docs/DEVELOPMENT.md)
- 確定した機能仕様: [実装計画](docs/IMPLEMENTATION_PLAN.md)
- 使用バージョン: [toolchain.json](toolchain.json)

## Windowsで実行

このフォルダーをPowerShellで開き、次を実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flutter.ps1 --version
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flutter.ps1 doctor -v
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flutter.ps1 run
```

`run` にはUSBデバッグを許可したAndroid端末、または起動済みAndroidエミュレーターが必要です。
実行ポリシーの指定はそのPowerShellプロセスだけに作用します。
