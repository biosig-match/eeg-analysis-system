-----

# リアルタイム脳波解析システム (ESP32 + Flutter + Python Server)

このプロジェクトは、自作の8チャンネル脳波計（ESP32-S3）で取得したデータを、スマートフォンアプリを介してWindowsサーバーに送信し、**MNE-Pythonライブラリ**でリアルタイムに解析・可視化するフルスタックアプリケーションです。

-----

## ✨ 主な機能

  - **ハードウェア**: Seeed Studio XIAO ESP32S3 を用いた8チャンネル脳波データ取得
  - **データ圧縮**: **zstandardライブラリ**による高効率なデータ圧縮・転送
  - **リアルタイム通信**: **BLE**による安定したデータストリーミング（ACKフロー制御付き）
  - **スマホアプリ (Flutter)**:
      - 生波形（8ch）のリアルタイムスクロール表示
      - スマホアプリで計算した快不快変化のリアルタイムスクロール表示
      - サーバーで解析された結果（画像・数値）の表示
  - **サーバーサイド解析 (Python)**:
      - **SQLite**データベースへのデータ永続化
      - 周波数スペクトル解析 (**PSD**): 各チャンネルのパワースペクトルを色分け表示
      - 同期度解析 (**Coherence**): 電極間の結合度を円グラフで可視化

-----

## 🚀 アーキテクチャ

本システムは、役割を明確に分離した3つのコンポーネントで構成されています。

  * **Firmware (ESP32)**: センサーデータの取得、タイムスタンプ付与、圧縮に専念します。
  * **Mobile App (Flutter)**: ESP32とサーバーを中継し、生波形と解析結果の両方を表示するユーザーインターフェースです。
  * **Server (Python)**: データを受け取ってDBに保存し、バックグラウンドでMNEによる重い解析処理を実行します。

-----

## 🔧 開発環境のセットアップ

このリポジトリをクローンした後、各コンポーネントを以下の手順でセットアップしてください。

### 1\. Server (Python / Windows)

解析の心臓部となるPythonサーバーをセットアップします。

```bash
# /server ディレクトリに移動
cd server

# 仮想環境を作成
python -m venv venv

# 仮想環境を有効化
.\venv\Scripts\activate

# 必要なライブラリをすべてインストール
pip install -r requirements.txt

# サーバーを起動
python server.py
```

> **注意:** 起動時に警告が出る場合がありますが、動作には影響ありません。サーバーが `http://0.0.0.0:5000` でリクエストを待ち受けます。

-----

### 2\. Firmware (ESP32)

**PlatformIO**を使用したESP32のファームウェアです。

1.  **VSCodeで開く**: `/firmware` ディレクトリを新しいウィンドウで開きます。
2.  **ビルド & アップロード**: PlatformIO拡張機能が自動的に `/firmware` ディレクトリをプロジェクトとして認識します。
      - チェックマーク（✔）アイコンでビルドします。
      - 矢印（→）アイコンでESP32にファームウェアを書き込みます。

-----

### 3\. Mobile App (Flutter)

リアルタイム表示とサーバーへのデータ中継を行うスマホアプリです。

1.  **サーバーIPアドレスの設定**:
    `mobile_app/lib/analysis_provider.dart` ファイルを開き、`serverIp` 定数の値を、サーバーを起動しているPCのIPアドレスに書き換えてください。

    ```dart
    // 例:
    const String serverIp = "192.168.1.10";
    ```

2.  **ライブラリのインストール**:

    ```bash
    # /mobile_app ディレクトリに移動
    cd mobile_app

    # 依存パッケージを取得
    flutter pub get
    ```

3.  **アプリの実行**:
    Androidの実機をPCに接続し、以下の設定を完了してください。

      - **USBデバッグを有効化**:
        1.  「設定」\>「デバイス情報」\>「ビルド番号」を7回タップして開発者向けオプションを有効化。
        2.  「設定」\>「システム」\>「開発者向けオプション」から「USBデバッグ」を一度オフにし、再度オンに切り替えます。
      - **USB接続モードの確認**:
        USB接続モードが **ファイル転送 / Android Auto** になっていることを確認します。

    準備が完了したら、以下のコマンドでアプリを起動します。

    ```bash
    flutter run
    ```

-----

## ⚙️ `.gitignore` の設定

リポジトリをクリーンに保つため、各プロジェクトフォルダに以下の内容で `.gitignore` ファイルを作成してください。

#### `/firmware/.gitignore`

```gitignore
.pio/
.vscode/
```

#### `/mobile_app/.gitignore`

> **注意**: Flutterが自動生成するデフォルトの `.gitignore` をそのまま使用してください。

#### `/server/.gitignore`

```gitignore
venv/
__pycache__/
*.pyc
eeg_data.db
```



### サーバーサイド設計
既存の資産を活かしつつ、将来的な拡張性と保守性を最大限に高めることを目的とした、詳細なソフトウェア設計を提案します。あなたの持つMCPエージェントの知見は、特にサービス間連携の部分で大いに参考になります。

-----

## 🏛️ DGFAシステムアーキテクチャ設計

このシステムは、役割ごとに明確に分離された独立したサービス（モジュール）群で構成されます。各サービスはAPIやメッセージキューを介して通信し、互いの内部実装を知る必要がありません。これにより、サービスごとに最適な言語（TypeScript/Python）や技術を選択できます。

### 構成モジュール一覧

| サービス名 (モジュール名) | 主な言語 | 役割 |
| :--- | :--- | :--- |
| **API Gateway** | TypeScript | 全リクエストの受付、認証、各サービスへのルーティング |
| **Data Ingestion Service** | TypeScript | 生データ（脳波、IMU、メディア）の受付と一次処理 |
| **Observer Service** | Python | 生データの解析、**有意な変化点**の検知、現状認識 |
| **Empath Service** | TypeScript | 欲求推定、LINE/Discordを介したユーザーとの対話 |
| **Strategist Service** | TypeScript | 欲求を満たすための行動計画立案とツール（MCP）実行 |
| **Coach Service** | TypeScript | 満足度評価の依頼と学習データの生成 |
| **Push Notification Service** | TypeScript | スマホアプリへのプッシュ通知 |

-----

## 🔩 各モジュールの詳細設計

### 1\. API Gateway

  * **役割**: システム全体の唯一のエンドポイント。クライアント（スマホアプリ）からのリクエストを適切なサービスに振り分けます。
  * **技術スタック**:
      * フレームワーク: **NestJS** または **Apollo Gateway**
      * 認証: **JWT (JSON Web Token)** を使用
  * **主なAPI**:
      * `POST /upload`: Data Ingestion Serviceへルーティング
      * `POST /label/satisfaction`: Coach Serviceへルーティング
      * `GET /analysis/realtime`: （既存機能）Observer Serviceへルーティング

### 2\. Data Ingestion Service (データ受付)

  * **役割**: スマホアプリから送られてくる全てのデータを受け取り、後続のサービスが処理しやすいようにメッセージキューに流します。
  * **技術スタック**:
      * フレームワーク: **NestJS**
      * メッセージキュー: **RabbitMQ** または **Kafka**
  * **処理フロー**:
    1.  スマホアプリから圧縮データ（脳波、IMU、画像、音声）を受信。
    2.  データを解凍。
    3.  画像・音声ファイルは\*\*オブジェクトストレージ (AWS S3など)\*\*にアップロード。
    4.  **メッセージを正規化**し、キューに送信。
          * 脳波/IMUデータ → `bio_raw_data` キューへ
          * メディアデータ（S3のURLなど） → `media_raw_data` キューへ

### 3\. Observer Service (現状認識・変化点検知)

  * **役割**: 生データを監視し、ユーザーの状態に**有意な変化**があった場合にイベントを発火させます。計算量の多い処理が多いためPythonで実装します。
  * **技術スタック**:
      * フレームワーク: **FastAPI**
      * ライブラリ: **MNE-Python**, **NumPy**, **OpenCV**, **Transformers** (マルチモーダルLLM用)
  * **処理フロー**:
    1.  `bio_raw_data` と `media_raw_data` キューを購読。
    2.  **脳波/IMU**: 時系列データとしてメモリ上に保持し、リアルタイムで特徴量（パワースペクトル、活動量など）を計算。**異常検知アルゴリズム**（例: 移動平均からの乖離）を用いて変化点を検出。
    3.  **画像/音声**: マルチモーダルLLM API (Geminiなど) を利用して、シーンのコンテキスト（場所、物体、行動）をJSON形式で抽出。
    4.  **変化点を検知した場合**: 脳波特徴量、IMU特徴量、シーンコンテキストを一つのイベントとしてまとめ、`significant_event` キューに送信。
    5.  （既存機能）スマホアプリからの要求に応じて、リアルタイム解析結果（PSD画像など）を生成して返すAPIも提供。

### 4\. Empath Service (欲求推定・対話)

  * **役割**: 発生したイベントを基にユーザーの「欲求」を仮説立てし、LINE/Discord Botを通じて対話を開始します。
  * **技術スタック**:
      * フレームワーク: **NestJS**
      * ライブラリ: **LangChain.js**, **LINE Messaging API SDK**, **Discord.js**
  * **処理フロー**:
    1.  `significant_event` キューを購読。
    2.  イベント情報と、後述の**ベクトルDB**から取得した過去の類似イベントをコンテキストとしてLLMに入力し、欲求仮説と最初の問いかけを生成。
    3.  LINE/Discord APIを呼び出し、ユーザーにメッセージを送信。
    4.  ユーザーからの返信は、各プラットフォームのWebhook経由で受信し、対話を継続。
    5.  対話が一段落したら、Strategist ServiceをAPIコールで起動。

### 5\. Strategist Service (計画立案・実行)

  * **役割**: ユーザーの欲求を満たすための具体的なタスクを計画し、外部ツールを実行してギャップを埋めます。
  * **技術スタック**:
      * フレームワーク: **NestJS**
      * ライブラリ: **LangChain.js**
  * **処理フロー**:
    1.  Empath Serviceから、対話によって明確化された「理想の状態」と「現状」を受け取る。
    2.  LLM（LangChain.js経由）を使って、タスクリストを生成。
    3.  各タスクを実行するために、定義されたツールを呼び出す。
          * **ツール連携**: あなたが実装したMCPのように、Pythonスクリプトを**サブプロセスとして呼び出す**か、あるいは各ツールを**個別のFastAPIサービスとして起動**し、HTTPリクエストで呼び出す。この方法なら、TypeScriptからPythonのツールをクリーンに利用できます。
    4.  タスク完了後、Coach Serviceに通知。

### 6\. Coach Service (評価・学習)

  * **役割**: 実行されたアクションの満足度をユーザーから収集し、システム全体の学習データとして整形・保存します。
  * **技術スタック**:
      * フレームワーク: **NestJS**
  * **処理フロー**:
    1.  Strategist Serviceからアクション完了通知を受け取る。
    2.  Push Notification Serviceを介して、スマホアプリに「体験の評価をお願いします」という通知を送信。
    3.  スマホアプリの評価画面（スライダーUI）から送信された満足度スコアをAPIで受信。
    4.  `イベントデータ`, `対話ログ`, `実行されたアクション`, `満足度スコア` を一組の**学習データ**として、データベースに永続化。

-----

## 💾 データ管理とデータベース設計

### 長期的なデータ管理（ベクトルDBの活用）

ユーザーを長期間観察するため、過去の膨大なデータを効率的に参照する仕組みが不可欠です。

  * **目的**: 「ユーザーが過去に『仕事のストレス』について話していて、満足度が低かった体験」のような、曖昧な記憶を検索可能にする。
  * **実装**:
    1.  **データのベクトル化**: Coach Serviceが学習データを保存する際、イベントのコンテキスト、対話ログの要約などをLLMのEmbedding APIでベクトル化します。
    2.  **保存**: このベクトルを、メインのDBに保存します。**PostgreSQL**の拡張機能である **pgvector** を使えば、追加のDBなしでベクトル検索を実装でき、管理がシンプルになります。
    3.  **活用**: Empath Serviceが対話を開始する際、現在のイベント状況に類似した過去のイベントをベクトルDBから検索し、LLMのコンテキストに含めます。これにより、「以前、同じような状況であなたはこう感じていましたね」といった、長期的な記憶に基づいた深い対話が可能になります。

### データベーススキーマ設計 (PostgreSQL)

```sql
-- ユーザー情報
CREATE TABLE users (
    user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    line_user_id TEXT UNIQUE,
    discord_user_id TEXT UNIQUE
);

-- タイムスタンプ、コンテキスト、ベクトル化された要約を持つイベント
CREATE EXTENSION IF NOT EXISTS vector; -- pgvector拡張
CREATE TABLE events (
    event_id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(user_id),
    timestamp TIMESTAMPTZ NOT NULL,
    trigger_type TEXT NOT NULL, -- 'bio_signal_change', 'user_request' 등
    scene_context JSONB, -- ObserverからのJSON
    bio_state JSONB,     -- ObserverからのJSON
    summary_embedding VECTOR(1536) -- OpenAI embedding v3 large
);

-- 生の時系列データ (TimescaleDBのHypertableにするとより良い)
CREATE TABLE bio_signal_raw (
    "time" TIMESTAMPTZ NOT NULL,
    user_id UUID NOT NULL REFERENCES users(user_id),
    -- 8チャンネルの脳波データ
    fp1 REAL, fp2 REAL, f7 REAL, f8 REAL, t7 REAL, t8 REAL, p7 REAL, p8 REAL,
    -- IMUデータ
    acc_x REAL, acc_y REAL, acc_z REAL, gyro_x REAL, gyro_y REAL, gyro_z REAL
);

-- メディアファイルへの参照
CREATE TABLE media_objects (
    media_id BIGSERIAL PRIMARY KEY,
    event_id BIGINT NOT NULL REFERENCES events(event_id),
    storage_url TEXT NOT NULL,
    media_type TEXT NOT NULL -- 'image', 'audio'
);

-- 対話ログ
CREATE TABLE conversations (
    conversation_id BIGSERIAL PRIMARY KEY,
    event_id BIGINT NOT NULL REFERENCES events(event_id),
    user_id UUID NOT NULL REFERENCES users(user_id),
    start_time TIMESTAMPTZ NOT NULL,
    full_log_text TEXT,
    summary_text TEXT,
    log_embedding VECTOR(1536) -- 対話ログのベクトル
);

-- 実行されたアクションと満足度評価
CREATE TABLE actions (
    action_id BIGSERIAL PRIMARY KEY,
    conversation_id BIGINT NOT NULL REFERENCES conversations(conversation_id),
    plan_details JSONB, -- Strategistが立てた計画
    execution_status TEXT NOT NULL,
    satisfaction_score INT, -- 0-10の評価
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

