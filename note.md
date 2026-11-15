# SYNC_AquaFX 作業ノート

## プロジェクトの前提

- フォルダーは `V:\DelphiProg\SYNC_AquaFX`。Delphi プロジェクト名は `SYNC_AquaFX`、グループは `SYNC`、プラグイン名は `水面演出`。
- 共通基盤は `SYNC_ParticleFX` が参考元。ビルド・コメント・文字コードの規則は、同プロジェクトと `SYNC_Mine`、`SYNC_PhotoShot` の `note.md` から、本プロジェクトに必要な内容を引き継ぐ。
- ユーザー指定により、本番の `SYNC_AquaFX.auf2` のみを改良・ビルド・検査する。単独版・補助プラグイン・追加プラグイン用プロジェクトを作成しない。
- 素材なしではフィルタオブジェクトへ「水面演出」を追加して生成する。プリセットを最上段へ置き、その直下の「設定」で各パラメータへ一括反映する。
- 詳細仕様は `docs/SPECIFICATION.md`、現在の機能・制限は `README.md` を参照する。

## ビルド

- Delphi 37.0 / Win64。IDE では `SYNC_AquaFX.dproj` を直接開く。
- プロジェクトルートで `rsvars.bat` を呼び、MSBuild で Debug / Release の両方を実行する。警告0・エラー0を原則とし、最後に Release を配置する。

```powershell
cmd /c 'call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" && msbuild SYNC_AquaFX.dproj /t:Build /p:Config=Debug /p:Platform=Win64'
cmd /c 'call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" && msbuild SYNC_AquaFX.dproj /t:Build /p:Config=Release /p:Platform=Win64'
```

全体を再ビルドする場合は `/t:Rebuild` を使う。ログを残す場合:

```powershell
New-Item -ItemType Directory -Path Win64\BuildLogs -Force | Out-Null
cmd /c 'call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" && msbuild SYNC_AquaFX.dproj /t:Rebuild /p:Config=Debug /p:Platform=Win64 /fl /flp:"logfile=Win64\BuildLogs\Debug.log;verbosity=normal;encoding=UTF-8"'
cmd /c 'call "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat" && msbuild SYNC_AquaFX.dproj /t:Rebuild /p:Config=Release /p:Platform=Win64 /fl /flp:"logfile=Win64\BuildLogs\Release.log;verbosity=normal;encoding=UTF-8"'
```

## ビルド後イベントとプロジェクト登録

- 出力先は Debug / Release 共通で `C:\ProgramData\aviutl2\Plugin\SYNC_AquaFX\`。DLL を `SYNC_AquaFX.auf2` へコピーし、成功後に DLL を削除する。Release では RSM も削除する。
- 現在のイベントは一行の `copy ... && del ...`。後続コマンドが `if` の条件内へ取り込まれる `&&if errorlevel ...` の連結へ戻さない。
- DCU は `Win64\Debug\DCU` / `Win64\Release\DCU`。AUF2 の更新時刻・サイズと、DLL / Release RSM が残っていないことを確認する。
- デバッガーホストは Debug が `D:\aviutl2_v2.1.16\aviutl2.exe`、Release が `D:\aviutl2_v2.1.17\aviutl2.exe`。ユーザーの指定なしに変更しない。
- ユニット追加時は `.dpr` の `in` と `.dproj` の `DCCReference` を両方更新する。`Source\Common`、`Source\Lib`、`Source\Lib\FilterTable`、`Source\Plugin\Filter` をユニット検索パスへ登録する。
- 開いている `.dpr` / `.dproj` を外部更新した場合は、IDE でプロジェクトを開き直して参照を読み込む。古い内容で保存して追加ユニットの参照を失わないようにする。
- MSBuild 成功と IDE の Code Insight・メッセージ表示は区別する。IDE 内のビルドを未確認なら、確認済みと報告しない。

## ソース配置

- `SYNC_AquaFX.dpr`: DLL の初期化・終了・エクスポート。
- `Source/Common/AquaFX_Settings.pas`: 共通設定、項目の範囲、プリセット初期値。
- `Source/Common/AquaFX_Renderer.pas`: 時刻とシードによる CPU 水面描画、形状、画像変形。
- `Source/Common/AquaFX_Projection.pas`: 符号付き傾斜、中心・位置・拡縮・3軸回転の投影。正の傾斜は上側が奥、負は下側が奥。
- `Source/Common/AquaFX_OilSurface.pas`: 時刻とシードから直接評価する浮遊油膜。下地から独立した色・被覆・縁・光沢。
- `Source/Plugin/Filter`: 標準パラメータ、編集 API、ホスト画像の入出力、エフェクトごとの描画資源。
- `Source/Lib`: SDK 型定義とフィルターテーブル登録の共通基盤。
- `Tests`: 本番 AUF2 を読み込む検査用 EXE。プラグインを追加登録しない。

## コメント・分割・文字コード

- ユニット先頭に目的と責務を書く。
- 公開処理には入力、出力、重要な副作用を記載する。必要に応じて値の単位、状態の有効範囲、所有権、保存対象も明記する。
- ホストの画像・テーブル・項目ポインター、描画バッファ、キャッシュは、誰が保持・解放するかを書く。コードをそのまま言い換えるコメントは避ける。
- 日本語を含む `.pas` / `.dpr` / Windows PowerShell 用 `.ps1` は UTF-8 BOM 付きとし、改行は CRLF にする。
- 1ユニットは約1,500行を目安に責務で分割する。関連ユニットは機能別フォルダーへ置き、フォームの `.pas` と `.dfm` は同じフォルダーに置く。
- UI は操作と画面状態を担当し、検証・解析・描画は各処理側へ置く。
- SDK 型の順序・サイズ・配置を変更する場合は公式定義と照合する。ホスト所有ポインターをコールバックの外へ保存せず、DLL 境界へ例外を漏らさない。

## 検査

```powershell
.\Tests\run_tests.ps1
```

- 検査用 EXE は `Win64\Verification`、確認画像はその下の `Images` に出力する。
- 本番配置先の `SYNC_AquaFX.auf2` を読み込み、素材なしの 204×204 描画、全面透明の入力でも生成すること、14プリセットの画像差、アニメーションと逆シーク、入力アルファの保持を確認する。
- 通常 EXE 内でも形状、シード、背景なし、画像モード、無効サイズを確認する。結果を再生順へ依存させない。
- 通常のビルド・検査では AviUtl2 と IDE を起動・操作しない。画面操作を停止された場合はその状態を維持する。

## 配布 ZIP

- Release ビルド後、`setup/make_release_zip.ps1` または同名 `.bat` で既存 AUF2 を梱包する。スクリプトはビルドやネットワーク公開を行わない。
- ZIP 内の AUF2 は本番の1つのみ。README とライセンスを合わせて5ファイルを収録する。
- カタログ末尾バージョンの XXH3-128 は、ZIP へ格納する AUF2 と同じコピーから計算する。

## 2026-11-15 の確認

- MSBuild の `/t:Rebuild` で Win64 Debug / Release とも警告0・エラー0を確認した。本番 AUF2 を読み込む描画検査も両構成で成功した。
- 再ビルドのログは `Win64/BuildLogs/Debug.log` / `Win64/BuildLogs/Release.log` に保存した。最終配置は Release。
- IDE には `AquaFX_Renderer` に関連するエラー表示を確認した。画面操作はユーザーが停止したため、IDE 内での再コンパイル完了は未確認。
- `.dpr` / `.dproj` の両方の参照に加え、ユニット検索パスを明示した。IDE 側ではプロジェクトを開き直して確認する。

## v0.3.0 の傾斜と座標

- ユーザー指定により「座標・変形」に X/Y/Z、中心X/Y/Z、X/Y/Z軸回転、拡大率、縦横比、透明度を追加した。初期値は座標・回転・縦横比・透明度が0、拡大率100。
- 既存の項目名と識別値は維持し、新規トラックは列挙末尾へ追加する。プリセットを適用しても配置・変形の12項目を上書きしない。
- 3D傾斜角度を -89～89度に変更した。従来の絶対値に依存する透視を共通の投影へ置き換え、正値を上側が奥、負値を下側が奥とした。以前の正値の見た目は変わる。
- X軸回転は傾斜角へ加算する。正のXは右、Yは下、Zは奥。縦横比は正で横、負で縦へ広げる。透明度100と拡大率0は透明出力とする。
- 画像とアルファも同じ投影で移動する。出力サイズは変えず、範囲外やカメラ背面は描画しない。新しいプラグインは作成しない。
- Debug / Release の全体再ビルドは警告0・エラー0。本番AUF2で12項目の反映・プリセット時の維持・正負の傾斜・中心XYZ・3軸回転・透明度・画像アルファ移動を検査した。共通投影は81点の順逆変換とカメラ背面の除外を確認した。
- `Win64/Verification/Images/tilt_comparison.png` は本番AUF2の出力で、左が+45度、右が-45度。最終配置とZIPは v0.3.0 のReleaseで、本体は1つ。
- 表示桁数はユーザーの標準描画の画像に合わせる。X/Y/Z・中心XYZ・XYZ軸回転・透明度は0.01刻みの小数2桁、拡大率・縦横比は0.001刻みの小数3桁とする。

## v0.4.0 の水系と油

- 海・海岸・川・池・湖・水たまり・お風呂・プールは「魔法液体」の共通波・粘度・光沢を基準にする。形状だけで波を3倍細かくしていた処理を除去した。「魔法液体」の色・形状・見た目は維持する。
- 「油」は下地とは別の琥珀色の膜が浮くプリセット。新しい「表面の油」に量・サイズ・光沢・色を追加し、すべて通常の標準項目へ保存する。水系へプリセット適用すると油膜の量は0へ戻す。
- 油膜は連続したノイズ場と縁の明暗、薄い干渉色で描く。時刻・シードだけで再現し、量0では模様を評価しない。画像と背景なしでも、同じ油膜をアルファの範囲内へ描く。
- 本番と同じプロジェクトを `Win64/BuildCheck/Debug` / `Release` へ出力する場合は、MSBuild の `/p:DCC_ExeOutput=` だけで検査先を上書きする。別のプラグイン用プロジェクトや登録を作らない。
- 検査先を指定する場合は `Tests/run_tests.ps1 -PluginPath <AUF2>`。`-ImageDirectory <フォルダー> -PreviewsOnly` は本番AUF2の14プリセットを同じ時刻でPNGへ出す。通常の検査も本番AUF2から画像を出力する。
- 描画変更前の画像は `Win64/Verification/BeforeOil` に保存した。「魔法液体」のPNGは変更前後でSHA-256が一致することを確認した。
- 波紋の帯の外では平方根・三角関数を省き、列の補間位置を先に計算する。背景ありでは色とマスクだけを補間し、油膜なしでは追加の油膜格子を確保しない。
- Debug / Release の全体再ビルドは警告0・エラー0。本番AUF2を読み込む検査で、膜と下地が分離すること、量0・サイズ・光沢・色の反映、シーク再現、画像アルファ、プリセット切替時の油膜解除を確認した。
- `Win64/Verification/Images/water_oil.png` は配置済みReleaseから生成した確認画像。左が海、右が油。最終配置とZIPは v0.4.0、本体は1つ。

## v0.5.0 の油と配布

- 油プリセットの下地を黄色、膜を黄金色にした。模様・量・サイズ・動きは維持し、縁の陰と暖色の白い照りを加えた。干渉色は使用しない。
- 表示モード末尾に「画像に油膜」を追加した。元画像の座標とアルファを保ち、薄い膜色・陰・照りだけを合成する。座標・変形は油膜の領域に適用する。油膜の量0・透明度100・拡大率0は入力をそのまま返す。
- Debug / Release の全体再ビルドは警告0・エラー0。両方の本番AUF2を検査EXEから読み込み、油膜の形状・色・光沢、画像の細部とアルファ、領域の移動、無効化、シーク再現まで確認した。実写のラーメン画像での見た目は未確認。
- 水系8種と魔法液体のPNGは `Win64/Verification/BeforeRamen` とSHA-256が一致した。`Images/oil_overlay_check.png` は検査模様の左が入力、右が本番AUF2による油膜合成。
- `SYNC_ParticleFX/setup` の現行版とバッチ・PS1・カタログを照合した。AquaFX名、ZIPルート、単一AUF2、5ファイルのインストール・削除先を維持し、JSONを v0.5.0 へ更新した。
- バッチはシステムのWindows PowerShellを絶対パスで呼び、終了コードを返す。PS1の既定入力は `%ProgramData%/aviutl2/Plugin/SYNC_AquaFX`。末尾バージョンが本番AUF2だけを1回記載することも検査する。
- ハッシュ計算用のxxhsum.exeをParticleFXと同じ `Win64/Dependencies/xxHash-0.8.4` に配置した。開発用のみで、配布ZIPには含めない。
- AviUtl2による配置先のファイルロックがあったため、検査済みの `Win64/BuildCheck/Release` を `-ReleaseDirectory` で指定して実際のバッチを実行した。別のカレントフォルダーから終了コード0で成功した。
- ZIPは5ファイルで本体は1つ。格納AUF2とReleaseのSHA-256、JSONと格納AUF2のXXH3-128を照合した。AUF2がない場合は終了コード1となり、既存ZIPとJSONは変更されないことも確認した。
- v0.5.0の配布AUF2のXXH3-128は `da4178787ea8f4afce09b8460aa2330f`。ユーザーのAviUtl2終了連絡後、本番配置へ上書き済み。配置AUF2・検査済みRelease・配布ZIP・JSONのハッシュ一致と、本体が1つであることを確認した。

- 配置後は別のカレントフォルダーから引数なしの setup/make_release_zip.bat も実行し、終了コード0と、再生成ZIPの本体が配置AUF2と一致することを確認した。
