# ライセンスと共通基盤の由来

水面演出（SYNC_AquaFX）: Copyright (c) 2026 VRAMの魔術師

本体のソースコードは参考元と同じ GNU General Public License v3.0（GPL-3.0-only）です。全文は [LICENSE](LICENSE) を参照してください。SDK 由来の定義については、次の MIT ライセンスの表示も同梱します。

## AviUtl ExEdit2 Plugin SDK

- 著作権: Copyright (c) 2025 Kenkun
- ライセンス: MIT
- 対象: `Source/Lib/AviUtl2FilterTypes.pas` に移植した SDK 型定義、コールバックと編集 API の ABI 定義。
- ライセンス全文: [ThirdParty/LICENSE.AviUtl2-SDK.txt](ThirdParty/LICENSE.AviUtl2-SDK.txt)

SDK ヘッダーを参照して Delphi の宣言へ移植しています。SDK の著作権表示と MIT ライセンス全文は、ソースと配布 ZIP の双方に同梱します。

## 継承元

- **SYNC_ParticleFX**: Delphi プロジェクト、Win64 Debug / Release ビルド設定・ビルドイベント、DLL の公開関数、SDK 型定義、フィルターテーブル登録処理、配布 ZIP 作成スクリプトとカタログ形式を引き継ぎました。パーティクルの計算・描画とサンプル素材は含みません。
- **SYNC_Mine（SYNC_MINE）**: SYNC_ParticleFX のプロジェクト・SDK 定義・配布処理の継承元です。
- **SYNC_PhotoShot**: Win64 のビルド設定・ビルドイベントの継承元です。
- **SYNC_Nicomea**: SYNC_Mine のプロジェクトと共通基盤の移植元です。
- **Syncroh2 / SYNC_Lyrics**: `PluginFilterTable.pas` の元となるフィルターテーブル登録処理です。
- **Aul2AudioFilter**: 参考元の SYNC_ParticleFX が参考にした、選択リスト・設定ボタンと編集 API による標準項目への一括反映方式を引き継いでいます。音声処理や専用 UI は含みません。

## 開発環境・検査画像

本体は Delphi RTL と Windows API を使用します。検査 EXE は VCL の PNG 出力も使用します。AviUtl2 本体、Delphi の開発環境、検査 EXE は配布 ZIP に含めません。

ZIP 作成時の xxhsum.exe は開発環境から呼び出し、配布 ZIP には含めません。本体に外部の画像・写真・キャラクター素材は組み込んでいません。

検査用の水面・油膜・比較模様は本プロジェクトのプログラムで生成します。これらを本プロジェクトの確認画像として提供する場合も GPL-3.0-only とします。
