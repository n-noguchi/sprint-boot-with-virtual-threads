# Virtual Threads ベンチマーク検証

## 1. 目的

Spring Boot 3.x (Java 21) で **Virtual Threads** を有効にした場合と無効にした場合で、
IO bound な API が **どれだけのリクエストを捌けるか** を定量的に比較する。

特に、ある API が別の遅い API を呼び出す「多段構成」において、
呼び出し元・呼び出し先それぞれの Virtual Threads の有無がスループット・レイテンシに
どう影響するかを、4 通りの組み合わせで検証する。

## 2. 検証アーキテクチャ

```
                    ┌─────────────────────┐
                    │        k6           │
                    │  (負荷生成クライアント) │
                    └─────────┬───────────┘
                              │ HTTP GET /api1
                              ▼
                    ┌─────────────────────┐
                    │       api1          │  Spring Boot + Tomcat
                    │  (中継 API)          │  RestClient で api2 を呼ぶ
                    └─────────┬───────────┘
                              │ HTTP GET /api2
                              ▼
                    ┌─────────────────────┐
                    │       api2          │  Spring Boot + Tomcat
                    │  (遅い API)          │  Thread.sleep で IO bound をエミュレート
                    └─────────────────────┘
```

- **api1**: k6 からリクエストを受け、api2 へ HTTP 呼び出し(ブロッキング I/O)を行う中継 API。
  api2 の応答を待つ間、呼び出し側のスレッドがブロックされる。
- **api2**: `Thread.sleep` で固定遅延(既定 200ms)を発生させ、IO bound な処理をエミュレートする。
- 両者とも **同一の Spring Boot アプリケーション** だが、コンテナを分けて api1 役・api2 役として起動する。
- AP サーバーは **Tomcat**(Spring Boot 標準)。

### 技術スタック
| 項目 | 内容 |
|------|------|
| 言語 / ランタイム | Java 21 (Eclipse Temurin) |
| フレームワーク | Spring Boot 3.3.x |
| AP サーバー | Tomcat |
| ビルド | Maven |
| コンテナ | Docker / Docker Compose |
| 負荷テスト | k6 (grafana/k6 イメージ) |

## 3. 仮説

### プラットフォームスレッド(無効)の場合
- Tomcat の max threads(既定で 200、本検証では明示的に 10 に固定)が上限。
- api1 は api2 への呼び出しで **スレッドを占有してブロック** する。
  api2 が 200ms の遅延を持つため、api1 側のスレッドは応答待ちで滞留しやすくなる。
- api2 側も各リクエストでスレッドを 200ms 占有するため、スレッド枯渇しやすい。
- どちらかが枯渇した時点でスループットが頭打ちになり、レイテンシが急増する。

### Virtual Threads(有効)の場合
- リクエストごとに Virtual Thread が割り当てられ、ブロックしてもキャリアスレッドを解放する。
- api1 は api2 の応答待ちの間も次々とリクエストを受け付けられる。
- api2 も sleep 中にキャリアスレッドを解放し、多数の同時リクエストを捌ける。
- 結果として高いスループットと安定したレイテンシが期待される。

### 組み合わせによる違い
- api1 のみ有効: api1 の中継待ちは改善するが、api2 が platform thread だと api2 がボトルネックになる。
- api2 のみ有効: api2 の同時処理は改善するが、api1 が platform thread だと api1 の worker が api2 待ちで枯渇する。
- 両方有効: エンドツーエンドで最もスループットが高くなると期待される。

## 4. 測定項目

k6 により以下を計測する。

| 指標 | 説明 |
|------|------|
| `http_reqs.count` | 総リクエスト数 |
| `http_reqs.rate` | スループット(req/s) |
| `http_req_duration` | レイテンシ(avg / p50 / p90 / p95 / max) |
| `http_req_failed.value` | エラー率(非 2xx、0〜1) |
| `vus` | 仮想ユーザー数 |
| `iterations.count` | 総反復数 |

## 5. 検証パターン

api1 と api2 それぞれの Virtual Threads の有効/無効を組み合わせた **4 パターン** を検証する。

| パターン名 | api1 (中継) | api2 (遅い) | 想定結果 |
|------------|:-----------:|:-----------:|----------|
| `api1-off_api2-off` | 無効(platform) | 無効(platform) | ベースライン。worker 枯渇で低スループット |
| `api1-on_api2-off` | 有効(virtual) | 無効(platform) | api2 がボトルネック。api1 改善分は限定的 |
| `api1-off_api2-on` | 無効(platform) | 有効(virtual) | api1 が api2 待ちで枯渇。改善限定的 |
| `api1-on_api2-on` | 有効(virtual) | 有効(virtual) | 最高スループット・安定レイテンシを期待 |

## 6. 検証条件(パラメータ)

以下は環境変数で調整可能。既定値で検証する。

| パラメータ | 環境変数 | 既定値 | 内容 |
|-----------|----------|--------|------|
| api1 の VT 有無 | `API1_VT` | `false` | `spring.threads.virtual.enabled` に反映 |
| api2 の VT 有無 | `API2_VT` | `false` | 同上 |
| api2 の遅延時間 | `API2_DELAY_MS` | `200` | api2 の `Thread.sleep` のミリ秒 |
| Tomcat max threads | `SERVER_TOMCAT_THREADS_MAX` | `200` | platform 時のスレッド上限(明示固定) |
| k6 のターゲット URL | `BASE_URL` | `http://api1:8080` | k6 が叩く api1 の URL |

### k6 負荷パターン(段階的 ramp-up)
ramping-vus で仮想ユーザー数を段階的に上げ、各段階での挙動を観察する。

| フェーズ | 継続時間 | ターゲット VU |
|----------|----------|:------------:|
| ramp-up 1 | 20s | 100 |
| hold 1 | 30s | 100 |
| ramp-up 2 | 20s | 300 |
| hold 2 | 30s | 300 |
| ramp-up 3 | 20s | 500 |
| hold 3 | 30s | 500 |
| ramp-down | 10s | 0 |

合計 約 2 分 40 秒 / パターン。

## 7. プロジェクト構成

```
sprint-boot-with-virtual-threads/
├── README.md                      ← 本ドキュメント(検証計画・結果)
├── app/                           ← Spring Boot アプリ(api1/api2 共通)
│   ├── pom.xml
│   ├── Dockerfile
│   └── src/main/
│       ├── java/com/example/bench/
│       │   ├── BenchApplication.java
│       │   └── ApiController.java
│       └── resources/
│           └── application.yml
├── app-go/                        ← Go (Gin) アプリ(api1/api2 共通)
│   ├── main.go
│   ├── go.mod
│   └── Dockerfile
├── k6/
│   └── script.js                  ← k6 負荷テストスクリプト
├── docker-compose.yml             ← api1 / api2 / api1-go / api2-go / k6 の構成
├── run-bench.sh                   ← Java 4 パターン自動実行スクリプト(bash / Git Bash 対応)
├── run-bench-go.sh                ← Go 2 パターン自動実行スクリプト
└── results/                       ← 検証結果出力先(k6 ログ・サマリ JSON)
```

### api エンドポイント仕様
- `GET /api1`: api2 の `/api2` を RestClient で呼び出し、結果を返す。
- `GET /api2`: `Thread.sleep(API2_DELAY_MS)` 後、`"ok"` を返す。

api1 と api2 は **同じアプリ** だが、コンテナを 2 つ起動し、
api1 コンテナは api2 コンテナの `/api2` を呼ぶように環境変数 `API2_URL` で設定する。

## 8. 再検証手順

### 前提
- Docker / Docker Compose が利用可能であること。
- Git Bash(または bash)が利用可能であること。`curl` が含まれていること(Git for Windows に同梱)。

### 方法 A: 全パターンを一括実行(推奨)

`run-bench.sh` を実行すると、4 パターンを順にビルド→起動→k6 実行→停止し、
結果を `results/` に出力する。

```bash
# Git Bash でプロジェクトルートに移動して実行
./run-bench.sh
```

結果:
- `results/<パターン名>.log`  — k6 の標準出力(レイテンシ分布など)
- `results/<パターン名>.json` — k6 のサマリ(機械可読)

### 方法 B: 特定パターンだけ再検証

`run-bench.sh` の第 1 引数にパターン名を指定すると、1 パターンだけ実行できる。
api2 の遅延時間は環境変数 `API2_DELAY_MS` で変更する。

```bash
# api1/api2 ともに Virtual Threads 有効のみ検証
./run-bench.sh api1-on_api2-on

# パラメータを変えて検証(例: api2 の遅延を 100ms に)
API2_DELAY_MS=100 ./run-bench.sh api1-on_api2-on
```

指定可能なパターン名: `api1-off_api2-off`, `api1-on_api2-off`, `api1-off_api2-on`, `api1-on_api2-on`

### 動作確認用: QUICK モード

環境変数 `QUICK=true` を付けると、k6 の負荷パターンが短縮版(10 VU / 13 秒)になり、
設定やスクリプトの動作確認を素早く行える。本番の検証では付けないこと。

```bash
# QUICK モードで1パターンだけ動作確認
QUICK=true ./run-bench.sh api1-on_api2-on
```

### 方法 C: 手動で段階的に実行(デバッグ用)

環境変数を直接設定してコンテナを起動し、k6 を別途実行する。

```bash
# 1. 環境変数で VT の有無を指定
export API1_VT=true
export API2_VT=true

# 2. api1 / api2 を起動(ビルド付き)
docker compose up -d --build api1 api2

# 3. 起動確認
curl http://localhost:8081/api1   # → "ok"
curl http://localhost:8082/api2   # → "ok"

# 4. k6 を実行(コンテナ経由)
docker compose run --rm k6 run /scripts/script.js

# 5. 後片付け
docker compose down
```

## 9. 公平性のための留意点

- 各パターンで **同じ k6 スクリプト・同じ負荷パターン** を使う。
- Tomcat の max threads を明示的に固定(検証では `10`)し、プラットフォームスレッド時の
  上限を環境に依存させない。
- Virtual Threads 有効時は Spring Boot がリクエストごとに Virtual Thread を使うため、
  max threads 設定は実質無視される(各リクエストが独立した Virtual Thread)。
- api2 の遅延は固定(`Thread.sleep`)で再現性を保つ。
- 各パターン実行前に `docker compose down` でクリーンな状態にする。
- リソース(CPU/メモリ)は Docker の既定割り当てで統一する。

## 10. 注意事項

- 本検証は **ブロッキング I/O のエミュレーション** であり、実際のネットワーク I/O とは挙動が異なる場合がある。
- `Thread.sleep` はスケジューラの精度に依存するため、遅延時間が短すぎると誤差が大きくなる。200ms 程度が現実的。
- Docker Desktop (WSL2) 環境ではホストリソースの制限に注意。VU 数を上げすぎるとクライアント側(k6)がボトルネックになる可能性がある。

## 11. 検証結果

### 11.1 検証条件
- AP サーバー: **Tomcat**(Spring Boot 3.3.5 組み込み)
  - ※ 当初ユーザー指定の Undertow で検証したが、`spring.threads.virtual.enabled=true` でも同期リクエスト処理が Virtual Thread にならなかった(`/thread` で `isVirtual=false`、スレッド名 `XNIO-1 task-N` を確認)。Tomcat に変更後、VT 有効時に `isVirtual=true`(`tomcat-handler-N`)となることを確認済み。詳細は 11.4 参照。
- Tomcat max threads: **10**(固定、platform 時のスレッド上限)
- api2 遅延: 200ms(`Thread.sleep`)
- k6 負荷: ramping-vus(100 → 300 → 500 VU)、2 分 40 秒 / パターン
- 実行環境: Docker Desktop (WSL2)

### 11.2 結果サマリ(Tomcat / max threads=10)

| パターン | 総リクエスト数 | スループット(rps) | avg(ms) | p90(ms) | p95(ms) | max(ms) | エラー率 |
|----------|---:|---:|---:|---:|---:|---:|---:|
| api1-off_api2-off | 7,867 | 47.7 | 5,410.8 | 10,074.8 | 10,082.6 | 10,282.5 | 0.0% |
| api1-on_api2-off | 7,912 | 48.0 | 5,369.2 | 10,025.4 | 10,028.7 | 10,034.3 | 0.0% |
| api1-off_api2-on | 7,859 | 47.6 | 5,416.5 | 10,095.0 | 10,097.6 | 10,300.7 | 0.0% |
| api1-on_api2-on  | 210,435 | 1,314.0 | 201.96 | 203.15 | 204.32 | 231.69 | 0.0% |

> 各パターンの詳細ログは `results/<パターン名>.log`、機械可読サマリは `results/<パターン名>.json` を参照。

### 11.3 考察

**api1・api2 ともに Virtual Threads 有効(`api1-on_api2-on`)の場合のみ、劇的な性能向上が見られた。**

- スループット: 47.7 rps → 1,314.0 rps(**約 28 倍**)
- レイテンシ p95: 10,083 ms → 204 ms(**約 50 分の 1**)
- エラー率: 全パターン 0%

#### パターン別の分析

| パターン | ボトルネック | 結果 |
|----------|--------------|------|
| api1-off_api2-off | api1・api2 ともに max=10 スレッド | api2 が 10 スレッド×200ms=50rps 上限。実測 47.7rps |
| api1-on_api2-off | api2 が platform(max=10) | api1 は VT で api2 を多数同時呼び出しできるが、api2 が 10 スレッドで律速。48.0rps |
| api1-off_api2-on | api1 が platform(max=10) | api1 が api2 呼び出しで 10 スレッドを占有。api2 が VT でも api1 が律速。47.6rps |
| api1-on_api2-on | なし(両方 VT) | api1・api2 ともスレッド上限なし。api2 の 200ms 遅延を多数の VT で並列処理。1,314rps |

#### 第 3 節の仮説の検証結果

- ✅ api1 のみ有効: api2 がボトルネックになり改善限定的
- ✅ api2 のみ有効: api1 が api2 待ちで枯渇し改善限限
- ✅ 両方有効: 最高スループット・安定レイテンシ

仮説通り、**多段呼び出しの両端で Virtual Threads を有効にする必要がある**ことが確認された。
片方だけでは、無効側のスレッドプールがボトルネックになり効果が出ない。

### 11.4 補足: Undertow での検証結果

当初、ユーザー指定の Undertow で検証を実施したが、`spring.threads.virtual.enabled=true` を設定しても
同期リクエスト処理スレッドが Virtual Thread にならなかった(`/thread` エンドポイントで `isVirtual=false`、
スレッド名 `XNIO-1 task-N` を確認)。そのため 4 パターンすべてで差が出なかった(worker=200 でも worker=10 でも同一)。

Undertow は XNIO ワーカースレッドで同期リクエストを処理する構造であり、
`spring.threads.virtual.enabled` は非同期 executor にのみ影響し、同期リクエスト処理には反映されない
可能性がある。Tomcat ではリクエスト処理スレッド自体が VT に切り替わるため、効果が明確に出た。

Undertow の結果は `results-w200/`(worker=200)と `results-undertow/`(worker=10)に保存済み。

## 12. Go (Gin) との比較検証

### 12.1 検証条件
- 言語 / フレームワーク: **Go 1.22 + Gin v1.10**(Go で最も人気の Web フレームワーク)
- Go は各リクエストを **goroutine**(軽量スレッド)で処理するのが標準
- 2 パターンを検証:
  - **go-unlimited**: goroutine 無制限(軽量スレッド = Java VT に相当)
  - **go-limited-10**: 同時処理数 10 に制限(channel セマフォ、重いスレッド = Java platform max=10 に相当)
- api2 遅延: 200ms、k6 負荷: ramping-vus(100→300→500 VU)、2 分 40 秒 / パターン
- その他の条件は Java/Tomcat 検証(第 11 節)と同一

### 12.2 結果サマリ(Go / Gin)

| パターン | 総リクエスト数 | スループット(rps) | avg(ms) | p90(ms) | p95(ms) | max(ms) | エラー率 |
|----------|---:|---:|---:|---:|---:|---:|---:|
| go-unlimited (goroutine) | 210,791 | 1,316.3 | 201.62 | 202.43 | 202.87 | 214.27 | 0.0% |
| go-limited-10 (同時10) | 7,904 | 47.9 | 5,380.9 | 10,061.3 | 10,061.9 | 10,063.7 | 0.0% |

### 12.3 Java / Go 統合比較

| 実装 | モード | スレッド種別 | スループット(rps) | p95(ms) | エラー率 |
|------|--------|--------------|---:|---:|---:|
| Java/Tomcat | platform (max=10) | 重い(platform) | 47.7 | 10,082.6 | 0.0% |
| Go/Gin | 並行制限 (同時10) | 重い相当 | 47.9 | 10,061.9 | 0.0% |
| Java/Tomcat | virtual threads | 軽い(VT) | 1,314.0 | 204.32 | 0.0% |
| Go/Gin | goroutine (無制限) | 軽い(goroutine) | 1,316.3 | 202.87 | 0.0% |

### 12.4 考察

**軽量スレッドの効果は言語を超えて一貫しており、劇的だった。**

- スループット: 約 48 rps(重い) → 約 1,315 rps(軽い)= **約 27 倍**
- レイテンシ p95: 約 10,000 ms → 約 203 ms = **約 49 分の 1**
- **Java Virtual Threads と Go goroutine は、本ワークロードでほぼ同等の性能**(1,314 vs 1,316 rps、差は誤差の範囲)
- 重いスレッド(platform / 並行制限)も両言語でほぼ同等(47.7 vs 47.9 rps)

#### 結論
- IO bound な多段 API 呼び出しにおいて、**軽量スレッド(VT / goroutine)は重いスレッドの約 27 倍のスループット**を発揮する。
- Java(Virtual Threads)と Go(goroutine)の**軽量スレッド同士の性能差はほぼない**。フレームワークやランタイムの選定よりも、軽量スレッドを使うかどうかが圧倒的に重要。
- 軽量スレッドの恩恵を得るには、**呼び出し chain の両端(api1・api2)で有効にする必要がある**(第 11.3 節参照)。

### 12.5 Go 版の実行手順

```bash
# 全パターン(goroutine 無制限 + 並行制限10)
./run-bench-go.sh

# 特定パターンのみ
./run-bench-go.sh go-unlimited

# 動作確認(QUICK モード)
QUICK=true ./run-bench-go.sh go-unlimited
```

Go 版の結果は `results/go-*.json`・`results/go-*.log` に出力される。
