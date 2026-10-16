# App Store Connect 掲載情報

App Store Connectの各欄にそのまま貼れる形で用意したもの。
文字数制限は2026年10月時点の仕様に基づく（出典は末尾）。

## 基本情報

| 項目 | 値 | 備考 |
|---|---|---|
| App名 | `Snapspool` | 2〜30文字。Web/App Store検索で重複なしを確認済み（商標の正式調査は未実施） |
| バンドルID | `app.snapspool.Snapspool` | App Store Connectで要登録 |
| カテゴリ | 仕事効率化 / Productivity | `LSApplicationCategoryType = public.app-category.productivity` |
| 価格 | 無料 | 課金・広告なし |
| 年齢制限 | 4+ | 収集データなし・ユーザー生成コンテンツなし |
| 著作権表記 | `2026 Woodpecker-50883` | `NSHumanReadableCopyright` にも同じ値を入れる |

## サブタイトル（30文字以内）

**日本語**
```
スクショもテキストも履歴から
```

**English**
```
Clipboard history with images
```

## 説明文（4,000文字以内）

**日本語**
```
Snapspoolは、コピーしたものを後から選んで貼り直せるクリップボード履歴アプリです。
テキストだけでなく、スクリーンショットやコピーした画像も履歴に残せます。

■ 覚えるキーは増えません
Command+C でコピー、Command+V で貼り付け。この2つはmacOS標準のままです。
少し前にコピーしたものを使いたいときだけ Command+Shift+V を押すと、
画像とテキストが混ざった履歴が新しい順に並びます。画像もテキストも、
選んだらそのまま前面のアプリへ自動で貼り付けられます。
（自動貼り付けは設定でオフにもできます。その場合はクリップボードに戻るだけになります）

■ スクリーンショットがファイルとしても残ります
クリップボードに入った画像は、指定したフォルダにPNGとして自動保存されます。
履歴から溢れた後もファイルとして手元に残るので、後から探せます。
保存先は自由に変更できます。既にスクリーンショット用のフォルダを使っているなら、
そこを指定すれば置き場所は今までのままです。

■ 画像とテキストで別々の上限
履歴の件数は画像とテキストで独立しています。テキストを何度コピーしても、
撮ったスクリーンショットが押し出されることはありません。

■ 外に出ません
ネットワーク通信を一切行いません。解析も広告もトラッキングもありません。
テキスト履歴はアプリを終了すると消え、ディスクには残りません。
パスワードマネージャが秘匿指定してコピーした内容は、履歴にもファイルにも残しません。

■ 使い始めるには
macOSの設定で「スクリーンショットをクリップボードにコピー」のショートカットを
有効にしてください。普段お使いのキーをそちら側に割り当てれば、今までと同じ操作のまま
Snapspoolが拾えるようになります。初回起動時に案内を表示します。

完全無料です。アプリ内課金も広告もありません。
```

**English**
```
Snapspool is a clipboard history app that lets you go back and paste something you
copied earlier — images and screenshots included, not just text.

■ No new shortcuts to learn
Command+C to copy and Command+V to paste stay exactly as macOS defines them.
Press Command+Shift+V only when you want something older: your images and text
appear together, newest first. Pick an image or text item and it is automatically
pasted into the app you were using.
(Automatic pasting can be turned off in Settings, in which case the item simply
returns to the clipboard.)

■ Screenshots are kept as files too
Images that reach the clipboard are saved automatically as PNG files in a folder you
choose. Even after an item drops out of the history, the file is still there.
Point it at the folder you already use for screenshots and nothing about your
filing habits has to change.

■ Separate limits for images and text
Image and text history have independent limits, so copying text all day never pushes
your screenshots out of the list.

■ Nothing leaves your Mac
No network connections. No analytics, ads, or tracking. Text history lives only in
memory and is gone when you quit. Content that a password manager marks as concealed
is never recorded.

■ Getting started
Enable the macOS shortcut for copying screenshots to the clipboard. Assign the key you
already use to that side, and your muscle memory keeps working while Snapspool picks
the image up. The app shows a setup guide on first launch.

Free, with no in-app purchases and no ads.
```

## キーワード（100バイト以内）

**日本語**
```
クリップボード,履歴,スクショ,スクリーンショット,貼り付け,コピー,画像,メニューバー
```

**English**
```
clipboard,history,screenshot,paste,copy,image,menubar,snippet,manager
```

## 必須URL（あなたの準備が必要）

| 項目 | 状態 |
|---|---|
| プライバシーポリシーURL | 文面は `docs/privacy-policy.md` に用意済み。**公開URLの用意が必要** |
| サポートURL | **未用意**。GitHubのIssuesページ、または問い合わせ用ページ |

プライバシーポリシーの公開方法の候補:

1. **GitHub Pages** — このリポジトリをpublicにしてPagesを有効化する（最も手軽）
2. **別のpublicリポジトリ** — 本体をprivateのまま、文書だけ公開用リポジトリに置く
3. **Gist** — 1ファイルだけ公開する。URLは安定する

サポートURLは、publicリポジトリのIssuesページで要件を満たせます。

## スクリーンショット（あなたの撮影が必要）

**仕様**: 16:10で `1280×800` / `1440×900` / `2560×1600` / `2880×1800` のいずれか。
PNGまたはJPEG、RGB、**透過なし**。1ロケールにつき最大10枚、**3枚以上を推奨**。

推奨する構図（4枚）:

1. **履歴ピッカーを開いた状態** — 画像とテキストが混ざって並んでいるところ。このアプリの本体
2. **スクショを撮った直後** — メニューバーのアイコンと、保存先フォルダにPNGが増えている様子
3. **設定画面** — 保存先・画像/テキストの件数・ショートカットが見える
4. **初回セットアップ案内** — macOS側の設定変更を案内している画面

撮影時の注意:
- 個人情報が映り込まないよう、履歴の内容はダミーにする
- デスクトップの壁紙とメニューバーの他アプリが映るので、事前に整理する
- 透過を含めないため、ウィンドウ単体ではなく画面全体またはトリミングで用意する

## 審査メモ（App Review Notes、4,000バイト以内）

```
Snapspoolはクリップボードの変化を監視し、画像とテキストの履歴を保持するユーティリティです。

・ネットワーク通信は行いません。収集・送信するデータはありません。
・App Sandboxを有効にしたまま動作します。
・画像の保存には com.apple.security.assets.pictures.read-write を使用し、既定の保存先
  （~/Pictures/Snapspool/）へ選択パネルなしで書き込みます。ユーザーが別のフォルダを
  選んだ場合は files.user-selected.read-write とセキュリティスコープブックマークを使います。
・グローバルショートカット（既定 Command+Shift+V）はCarbonの RegisterEventHotKey を
  使用しており、入力監視やアクセシビリティの権限は要求しません。
・履歴から項目を選ぶと、クリップボードへ書き戻したうえで前面のアプリへ貼り付けます。
  この貼り付けには CGEvent によるキーイベント送出を使い、macOSのイベント送出権限を
  利用します。権限はユーザーが明示的に許可した場合のみ有効で、許可されていない場合は
  貼り付けを行わず、クリップボードに戻したことを案内するだけです。
  この機能は設定でオフにできます。

動作確認の手順:
1. システム設定 > キーボード > キーボードショートカット > スクリーンショット で
   「選択部分のピクチャをクリップボードにコピー」を有効にする
2. その設定したキーで範囲スクリーンショットを撮る
3. Command+Shift+V で履歴が表示され、選択すると前面のアプリへ貼り付けられることを確認する
   （初回はイベント送出の権限の許可が必要。許可しない場合はクリップボードに戻るだけになる）
```

## 出典

- [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- 画面サイズ・文字数制限は2026年10月時点の公開情報に基づく（[参考](https://www.picssizer.com/app-store-sizes/mac-app-store)）
