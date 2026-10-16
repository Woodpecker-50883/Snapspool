# Mac App Store 公開チェックリスト

Snapspool を App Store に出すまでの手順。
**[済]** は完了、**[ループ]** は自律ループが実装する分、**[要あなた]** は
Apple Developerアカウントの操作や撮影など、本人でないとできない作業。

## 1. 実装・成果物

- [済] 実装（Phase 1〜16の実装分）。`requirements.md` の機能要件はすべて実装済み
- [済] アプリアイコン（`Resources/Assets.xcassets/AppIcon.appiconset`、16〜1024の全10サイズ）
- [済] メニューバーアイコン（テンプレート画像、ライト/ダーク両対応）
- [済] 日本語・英語のローカライズ
- [済] `Info.plist` の `LSApplicationCategoryType` と `NSHumanReadableCopyright`
- [済] アプリ内からプライバシーポリシーへ到達する導線（公開URLの設定は要あなた）
- [済] `DEVELOPMENT_TEAM` を外から与えられるビルド設定

## 2. 掲載情報

- [済] App名・サブタイトル・説明文・キーワード（日英） → `docs/app-store-metadata.md`
- [済] 審査メモ（App Review Notes） → 同上
- [済] プライバシーポリシー本文（日英） → `docs/privacy-policy.md`
- [要あなた] プライバシーポリシーを**公開URL**にする（下記3-1）
- [要あなた] サポートURLの用意（下記3-2）
- [要あなた] スクリーンショットの撮影（構図案は `docs/app-store-metadata.md`）

## 3. あなたの作業（順番に）

### 3-1. プライバシーポリシーを公開する

`docs/privacy-policy.md` は記入済み。次のいずれかで公開する。

1. **GitHub Pages** — このリポジトリをpublicにしてPagesを有効化（最も手軽）
2. **公開用の別リポジトリ** — 本体はprivateのまま、文書だけ公開
3. **Gist** — 1ファイルだけ公開。URLは安定する

公開したURLを控える。アプリ内導線にも同じURLを設定する。

### 3-2. サポートURLを用意する

publicリポジトリのIssuesページで要件を満たせる。専用ページを作ってもよい。

### 3-3. Apple Developer / App Store Connect の設定

1. Certificates, Identifiers & Profiles で **App ID `app.snapspool.Snapspool`** を登録
   - App Sandbox を使うため、Capabilities の設定を確認する
2. App Store Connect で**新規Appを作成**
   - プラットフォーム: macOS
   - 名称: Snapspool
   - バンドルID: 上で登録したもの
3. **チームID**を確認し、ビルド時に渡す（手順3-5）

### 3-4. アプリ名の最終確認

Web・App Store検索では同名アプリが見つからなかったが、**商標の正式調査は未実施**。
公開前に、少なくとも特許情報プラットフォーム（J-PlatPat）等で確認しておくと安全。

### 3-5. 配布用ビルドの作成

チームIDを設定した状態でアーカイブする。手順は実装タスク完了後に確定するが、概形はこれ。

```bash
cd ~/dev/projects/Snapspool
xcodegen generate --spec xcodegen.yml
xcodebuild archive -scheme Snapspool -destination 'platform=macOS' \
  -archivePath build/Snapspool.xcarchive \
  DEVELOPMENT_TEAM=<あなたのチームID>
```

その後 Xcode の Organizer から **Distribute App → App Store Connect** でアップロードする。

### 3-6. 掲載情報の入力と申請

`docs/app-store-metadata.md` の内容をApp Store Connectに貼り付け、
スクリーンショットとURLを設定して申請する。

## 4. 申請前の最終確認

- [ ] `requirements.md` の「完了条件」24項目を実機で確認した
- [ ] `findings.md` の未対応指摘がゼロ、または先送り理由が明記されている
- [ ] バージョン番号を確認（現在 `CFBundleShortVersionString = 1.0` / `CFBundleVersion = 1`）
- [ ] アプリ内のプライバシーポリシー導線が、実際に公開URLを開く
- [ ] App Sandbox有効のまま動作する（`codesign -d --entitlements -` で確認）

## 5. 審査で引っかかりやすい点（事前に把握しておく）

- **クリップボードを扱うアプリは審査で注視される**。審査メモ（`docs/app-store-metadata.md`）で
  「ネットワーク通信なし・収集なし」を明示してある
- **自動貼り付けを実装している**（2026-10-16に方針変更）。`CGEvent.post` による⌘V送出で
  ガイドライン2.4.5のリジェクトを受けた報告はあるが、Maccyが同じ実装のままApp Storeで
  配布されている前例を確認済み。落ちた場合は前例を挙げて反論する（詳細は `docs/technical-notes.md`）
- **プライバシーポリシーはアプリ内からも到達できる必要がある**。導線は実装済みで、公開URLの設定が残っている
