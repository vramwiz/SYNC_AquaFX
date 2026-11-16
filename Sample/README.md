# 画像と動作サンプル

ラーメン・コーヒー・牛乳・浴槽の元画像は内蔵image_genで生成した1536×1024のPNGです。各 `.prompt.txt` に生成指示を保存しています。液体の範囲は手動で合わせており、自動認識は行いません。

| 素材 | 効果 | 確認用GIF | 現在のプロジェクト位置（0-based、30fps） |
| --- | --- | --- | --- |
| ramen.png | 渦で回る油膜 | ramen_vortex_preview.gif | 600～749 |
| coffee.png | 液面の波・渦 | coffee_vortex_preview.gif | 波150～299、渦300～449 |
| milk_glass.png | ガラス内の液面の波・渦 | milk_wave_preview.gif | 波900～1049、渦1050～1199 |
| bathtub.png | 固定点から広がる波紋 | bath_ripples_preview.gif | 1200～1379 |
| shore_sand.png | 平面の海岸の寄せ返し | shore_sand_preview.gif | 1560～1919（2層） |
| bathtub.png | 排水口へ水が集まって抜ける | bath_drain_preview.gif | 1920～2159（2層） |
| 素材なし | 中央が凹む渦 | vortex_depression_verified.png（実機静止画） | 2160～2339 |

`*_alias.txt` はAI MIRAI経由の配置に使う完全な保存値です。画像のパスはこの開発環境の絶対パスなので、別環境では修正してください。牛乳の現在の「画像の陰影」は0です。コーヒー・ラーメンはユーザー確認済み、牛乳は及第点の評価です。

浴槽の元画像には水を描いていません。下層の浴槽画像に、上層の長方形水面を重ねます。「落水の波紋」の散らばり0で中心を固定し、波紋の縦横比155で円形へ補正しています。落ちる水や水滴自体は描画しません。`bath_ripples_verified.png` はAI MIRAIで取得した実機画像です。

GIFは本番AUF2の描画結果から作成しています。浴槽と最終牛乳の18フレームはホストを起動せずに生成し、他のGIFはAI MIRAIの取得画像から作成しました。GIFは縮小・減色したプレビューであり、再生負荷やFPSの計測には使えません。

浴槽の本番AUF2描画コールバックは1536×1024で中央値40.323ms（9フレーム、ウォームアップ後）。Debugログで確認した合成処理を改善し、変更前87.044msから約2.16倍に改善しました。AviUtl2全体の再生FPSを保証する数値ではありません。

「海岸の寄せ返し」は平面の波打ち際の試作です。`shore_sand_preview.gif` は砂浜へ重ねた結果、`shore_alpha_preview.gif` は透過確認用の市松へ重ねた結果です。768×432・72フレーム・6秒・12fpsで、本番AUF2をホストなしで読み込んで生成しています。`shore_preview.png` は2.5秒、`shore_phases.png` は4時刻の比較です。

`shore_sand.png` は `Tests/make_shore_preview.ps1` が決まったシードから作る砂模様で、AI生成画像や実写写真ではありません。海水と泡は砂浜素材に含めず、すべて本番AUF2の出力を合成します。確認画像の再生成は、Delphiの環境設定後に `Tests/run_tests.ps1 -ShorePreview -ImageDirectory <絶対パス>` を実行し、そのフォルダーを `Tests/make_shore_preview.ps1 -FramesDirectory <絶対パス>` へ渡します。合成スクリプトはWindows PowerShell 5.1で実行してください。

`shore_mirai_verified.png` はAI MIRAIから取得した1920×1080の実機画像です。現在のプロジェクトでは、レイヤー0の砂浜画像へ、レイヤー1の同じ画像に付けた水面演出を重ねています。両方の標準描画を250%へ拡大しています。生成用の全設定は `shore_sand_alias.txt` / `shore_water_alias.txt` に保存しています。オフラインGIFと実機の画像オブジェクトでは投影の基準寸法が異なるため、水際の輪郭は完全には一致しません。

引き波の開始時に左右から四角く泡が現れる不具合を修正し、海岸のGIF・PNGを更新しました。`shore_mirai_turnaround.png` は修正後の実機で折返し直後（オブジェクト先頭から2.2秒）を取得した画像です。`shore_mirai_verified.png` も修正後の2.5秒の画像へ更新しています。

`bath_drain_preview.gif` は「栓を抜く」を8秒のタイムラインとして描画した96フレームの確認用GIFです。表示は576×384・12fpsで、最後の空の浴槽を1秒止めてから繰り返します。`bath_drain_phases.png` は4段階の比較、`bath_drain_mirai_verified.png` は実機の排水中の画像です。`vortex_depression_verified.png` は水量を保ち、中央だけを凹ませる「渦」の実機画像です。

浴槽の排水中心は元画像中心からX=522、Y=-1へ合わせています。水面側はX=0、Y=-7、拡大率51、縦横比70、透明度35で、以前の浴槽の範囲を利用しました。完全な設定は `bathtub_drain_source_alias.txt` / `bathtub_drain_alias.txt` / `vortex_depression_alias.txt` に保存しています。再生成は `Tests/run_tests.ps1 -DrainPreview -ImageDirectory <絶対パス>` と、Windows PowerShell 5.1の `Tests/make_drain_preview.ps1 -FramesDirectory <絶対パス>` を使います。

ユーザーの評価に合わせ、吸い込む動きを保って白い螺旋の輪と泡を取り除き、中央の影を薄くしました。渦と排水のサンプルは波紋の量・泡の量とも0です。この光沢だけの調整時には、排水96フレームのアルファが一致しました。

さらに終盤を、濃さを保った水の尾が栓へ流れ込む表現に変更しています。現在のGIFと `bath_drain_phases.png` はこの変更後です。`bath_drain_tail.png` は終盤のオフライン合成、`bath_drain_tail_verified.png` は同じ終盤の実機画像です。前半58フレームは変更前と画像が完全一致し、設定値とタイムラインの長さは維持しています。
