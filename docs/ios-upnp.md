# iOS UPnPの一時停止

iOSの実機署名でマルチキャスト entitlement を要求しないよう、UPnPによる自動ポート開放を一時停止しています。Android側の動作は変更していません。

- `ios/Runner/Runner.entitlements` は空の辞書を維持し、Debug / Profile / Release 共通でマルチキャスト権限を要求しません。
- `UpnpService.isSupported` でiOSを除外し、設定画面・操作画面・ルーター検出を無効化しています。
- 視聴・リレー用のローカルネットワーク許可と、SPによるポート確認は維持しています。
- 既存のルーターのポート転送設定は削除しません。必要に応じてルーターの管理画面で変更してください。

## 再有効化する場合

1. Apple Developerの契約だけでなく、マルチキャスト entitlement を利用できる署名・プロビジョニング条件を確認します。
2. `ios/Runner/Runner.entitlements` の辞書に `com.apple.developer.networking.multicast` を boolean の `true` として戻します。
3. `UpnpService.isSupported` のiOS除外を解除します。
4. `ios/Runner/Info.plist` の `NSLocalNetworkUsageDescription` にUPnPのルーター検出・ポート開放の用途を戻します。
5. 一時停止を検証するテストを更新し、実機で署名ビルド、権限許可、ルーター検出、開放・削除を検証します。

UPnPの実装自体は削除していません。
