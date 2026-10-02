# Railsサンプルの追加PSS

修正版は、2・3・4台目の追加PSSが単一プロセスRSSの40%以下という目標を満たしました。
比率は37.910%、35.820%、38.053%です。
5構成をそれぞれ600秒測定し、合計300,000 RPC、エラー0件、全ワーカーへの負荷、全プロセスの回収を確認しました。

## 判定方法

ワーカー自身のPSSには共有ページの按分が含まれるため、増設の費用は親プロセスを含む全体の差分で判定します。

```text
F(N) = masterとNワーカーの合計PSS
R = workers 0で実際にRPCを処理する単一プロセスのRSS
追加比率(N) = (F(N) - F(N-1)) / R   N = 2, 3, 4
合格条件 = 3つの追加比率がすべて0.40以下
```

Linuxの`/proc/PID/smaps_rollup`を30秒ごとに読み、最後の3回（約540・570・600秒）の中央値を使います。
単一プロセス構成の合計PSSにはlauncherも含みますが、分母のRSSはRPCを処理するプロセスだけです。
各ワーカーのPSS・USSも記録し、増設差分とは分けて扱います。
([Linux proc documentation](https://www.kernel.org/doc/html/latest/filesystems/proc.html))

## 正式結果

2026-10-02 17:07:28–17:57:33 UTCに逐次実行しました。
単一実行プロセスのRSS基準は105.660 MiB、追加PSSの上限は42.264 MiBです。

| 構成 | 合計PSS中央値（MiB） | RPC数 | エラー |
| --- | ---: | ---: | ---: |
| single | 113.403 | 60,000 | 0 |
| preload_warmup_1 | 123.205 | 60,000 | 0 |
| preload_warmup_2 | 163.261 | 60,000 | 0 |
| preload_warmup_3 | 201.108 | 60,000 | 0 |
| preload_warmup_4 | 241.315 | 60,000 | 0 |

| 増設 | 追加合計PSS（MiB） | 単一RSSに対する比率 | 判定 |
| --- | ---: | ---: | --- |
| 1 → 2ワーカー | 40.056 | 37.910% | 合格 |
| 2 → 3ワーカー | 37.848 | 35.820% | 合格 |
| 3 → 4ワーカー | 40.207 | 38.053% | 合格 |

生データは[rails-memory-final.json](rails-memory-final.json)に保存しています。
`complete: true`、`gate_passed: true`、実行コマンドの終了コードは0です。
SHA256は`d69bf2e703b5f71d92da6ce38238e08a6960832406d12470ea0cad6df5a23cc3`です。

## 測定条件と修正

- ARM64 Linux、2 CPU、物理メモリ2,005,512 KiB。
- Ruby 3.4.11、Rails / Active Record 8.1.4、SQLite 2.9.6、grpc 1.83.0。
- サーバーは各ワーカー4スレッド、DBプールも4接続。
- 独立した32チャネル、クライアント4スレッド、合計毎秒100 RPC、deadlineは2秒。
- SQLiteの商品3件を`GetProduct`で読み、返却ID・名称・worker PIDを検証。
- 通常のGCとアロケータ設定を使用。`MALLOC_ARENA_MAX`、`GLIBC_TUNABLES`は未指定。
- Coreは`cdacf94bec4ba5df71ce5f96782ddeb81e800136`。ロードされたCore・Native・Railsの全Rubyファイル、サンプルと測定スクリプトのSHA256を記録し、各構成の開始前に変更がないことを確認。
- 他のRubyテストや別構成を並列に実行せず、ホストのIdle Sleepを一時的に抑制。

Coreはwarmup前にフレームワークも事前ロードし、通常のメトリクス・状態送信を`status_interval`に合わせました。
Railsはwarmup前と各fork前に全DBプールを切断します。
さらに、ステータス・シグナル・Adminの待機読み取りでバッファを再利用します。
修正前の1,000回の待機ポーリングは12,312,000 byteを確保し、修正後は512 KiB未満に抑えられることを回帰テストで確認しました。
この短い割り当てテストだけは測定中のGCを止めますが、正式負荷試験のGC方針は変更しません。
起動・終了時のGCカウンターと`allow_full_mark: true`も生データに記録しています。
カウンターの差は起動から終了までを含み、GCの発生時刻を特定する記録ではありません。

## 再現

Linux上で`gritz-rails`の開発用依存関係をインストールし、次を実行します。
正式測定の前に短時間で動作確認する場合も、保存先を変えて原本を保持します。

```sh
CASE_SET=gate GRITZ_THREADS=4 RAILS_MEMORY_CORE_COMMIT=cdacf94bec4ba5df71ce5f96782ddeb81e800136 bundle exec ruby tools/check_rails_memory.rb 600 tmp/rails-memory.json
```

測定時はワークスペースの各Gemを参照するLinux用Gemfileを使いました。

```sh
caffeinate -i docker exec -e BUNDLE_GEMFILE=/workspace/gritz-native/tmp/phase5.Gemfile -e BUNDLE_APP_CONFIG=/tmp/gritz-phase5-bundle -e CASE_SET=gate -e GRITZ_THREADS=4 -e RAILS_MEMORY_CORE_COMMIT=cdacf94bec4ba5df71ce5f96782ddeb81e800136 -w /workspace/gritz-rails gritz-t2-test bundle exec ruby tools/check_rails_memory.rb 600 tmp/rails-memory.json
```

`CASE_SET=full`は、事前ロードなし・ありの4ワーカー比較を追加した7構成です。
今回の合格判定には、単一プロセスとpreload + warmupの1〜4ワーカーを測る`gate`を使いました。
短時間の実行は600秒の正式測定を代替しません。

## 保存した未達・中断結果

以下の原本は上書きせず、合格結果と区別して保存しています。

| 生データ | 条件・結果 |
| --- | --- |
| [旧7構成](T5-07-rails-memory.json) | 16スレッド、各600秒、420,000 RPC・エラー0件。追加比率60.571%、40.473%、41.754%で未達。SHA256 `d33585ec2878afef5ee4a4f3f6de35643ba579faae0b2ee65bd0c7fa41d9c985`。 |
| [送信待ち修正後](T5-07-rails-memory-fixed.json) | 単一・1・2ワーカー各600秒、180,000 RPC・エラー0件。2台目60.050%で未達、3・4ワーカー未測定。SHA256 `07b10c1d2f120c89d361843b85571364f4bc7660e1da601339640138963ec27a`。 |
| [ホストSleepで除外](T5-07-rails-memory-fixed-excluded-sleep.json) | 約50秒のホスト停止とdeadlineエラー2件が重なったため除外。プロセスを回収後、以降は一時的にIdle Sleepを抑制。 |
| [GC設定の試行](T5-07-rails-memory-cow.json) | オーナー指示で中断。単一600秒のみ完了。1ワーカーは510.4秒・51,040 RPC時点で328.872 MiBに増加。2〜4ワーカー未測定。この設定はmainへ取り込んでいません。 |
| [バッファ修正前](rails-memory-idle-allocation.json) | 4スレッド・`MALLOC_ARENA_MAX=1`、5構成各600秒、300,000 RPC・エラー0件。追加比率39.423%、39.656%、72.806%で未達。 |

過去の測定には異なるCore・スレッド数・アロケータ条件が含まれるため、修正単体の効果を切り分ける比較ではありません。
原本に記録されたコミットとSHA256は、その測定時点のコードを示します。

## 適用範囲

対象は`rails new --api --minimal`で作った商品モデルと`CurrentAttributes`を使うサンプルです。
4スレッド・毎秒100 RPCという上記の条件で目標を満たした結果であり、既定の16スレッドや別の業務アプリの結果を示すものではありません。
モデル数、依存Gem、接続数、負荷、ネイティブ拡張が異なるアプリでは同じ手順で再測定してください。
