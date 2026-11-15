# ライセンスと共通基盤の由来

水面演出（SYNC_AquaFX）: Copyright (c) 2026 VRAMの魔術師

本体のソースコードはコピー元と同じ GNU General Public License v3.0（GPL-3.0-only）です。全文は [LICENSE](LICENSE) を参照してください。

## AviUtl ExEdit2 Plugin SDK

- 著作権: Copyright (c) 2025 Kenkun
- ライセンス: MIT
- 対象: `Source/Lib/AviUtl2FilterTypes.pas` に移植した SDK 型定義、コールバックと編集 API の ABI 定義。
- ライセンス全文: [ThirdParty/LICENSE.AviUtl2-SDK.txt](ThirdParty/LICENSE.AviUtl2-SDK.txt)

SDK のライセンス表示はソースと配布 ZIP の双方に同梱します。AviUtl2 本体と Delphi の開発環境は含みません。

## 継承元

- **SYNC_ParticleFX**: Delphi プロジェクト、Win64 Debug / Release ビルド設定・ビルドイベント、DLL の公開関数、SDK 型定義、フィルターテーブル登録処理、配布 ZIP 作成スクリプトとカタログ形式を引き継ぎました。パーティクルの計算・描画とサンプル素材は含みません。
- **SYNC_Mine（SYNC_MINE）**: SYNC_ParticleFX のプロジェクト・SDK 定義・配布処理の継承元です。
- **SYNC_PhotoShot**: Win64 のビルド設定・ビルドイベントの継承元です。
- **SYNC_Nicomea**: SYNC_Mine のプロジェクトと共通基盤の移植元です。
- **Syncroh2 / SYNC_Lyrics**: `PluginFilterTable.pas` の元となるフィルターテーブル登録処理です。

ZIP 作成に使用する xxhsum.exe は開発環境から呼び出し、配布 ZIP には含めません。
