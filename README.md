# AIボイスレコーダー化アプリ (AppLaud)

## 概要

AppLaudは、USBボイスレコーダーをMacに接続した際に、音声ファイルを自動的に取り込み、文字起こしと要約を行うアプリケーションです。生成されたテキストはMarkdownファイルとして保存され、日々の音声記録の管理と活用を効率化します。

## 主な機能

*   **自動ファイル取り込み:** 指定されたUSBボイスレコーダーの接続を検知し、音声ファイル（wav, mp3, m4a）を自動でローカルフォルダに移動します。
*   **AIによる文字起こしと要約:** Gemini APIを利用して、音声ファイルの文字起こしと要約を高精度で行います。
*   **Markdown形式での保存:** 要約結果をMarkdownファイルとして、整理された形式で保存します。ファイル名は日付と内容に基づき自動生成されます。
*   **長時間音声対応:** 20分を超える音声ファイルは自動的に分割処理され、APIの制限に対応しつつ、途切れることのない文字起こし結果を得られます。

## システム構成要素

*   **`file_mover.sh` (zshスクリプト):** USBデバイスの監視、音声ファイルの検出と移動、Pythonスクリプトの呼び出しを行います。全ての検出された音声ファイルを毎回必ず移動し、Pythonスクリプトを呼び出します。
*   **`transcribe_summarize.py` (Pythonスクリプト):** Gemini APIとの連携、音声ファイルの文字起こし、要約、Markdownファイル生成、処理記録を行います。
*   **`config.sh` (設定ファイル):** ボイスレコーダーの名称、各種フォルダパス、処理対象の拡張子などを設定します。
*   **`launchd` (macOS):** USBデバイス接続をトリガーとして `file_mover.sh` を実行します。 (ユーザーによる設定が必要です)

## セットアップ

1.  **リポジトリのクローン:**
    ```bash
    git clone https://github.com/your-username/AppLaud.git
    cd AppLaud
    ```
2.  **設定ファイルの編集:**
    *   `script/config.sh` を開き、お使いの環境に合わせて以下の項目を設定してください。
        *   `RECORDER_NAME`: 監視対象のボイスレコーダーのボリューム名 (Macでマウントされたときの名前)。
        *   `VOICE_FILES_SUBDIR`: 音声ファイルが格納されているUSBデバイス内のサブディレクトリ名。
        *   `AUDIO_DEST_DIR`: 音声ファイルの移動先ローカルフォルダ。
        *   `MARKDOWN_OUTPUT_DIR`: Markdown要約ファイルの出力先ローカルフォルダ。
        *   その他、必要に応じてパスを調整してください。
3.  **依存ライブラリのインストール (Python):**
    ```bash
    pip install google-generativeai pydub
    ```
    (Pythonの実行環境によっては `pip3` を使用してください。)
4.  **APIキーの設定:**
    *   Google CloudでGemini APIを有効にし、APIキーを取得してください。
    *   取得したAPIキーを環境変数 `GOOGLE_API_KEY` に設定します。シェルの設定ファイル (例: `~/.zshrc`, `~/.bash_profile`) に追記するか、`launchd` の設定ファイルに含める方法があります。
        ```bash
        export GOOGLE_API_KEY="YOUR_API_KEY"
        ```
5.  **`launchd` エージェントの設定 (macOSユーザー向け):**
    *   USBデバイス接続時に `file_mover.sh` を自動実行するために、`launchd` のエージェントを設定する必要があります。
    *   本リポジトリの `document/com.example.applaud.filemover.plist` は、このための設定ファイルテンプレートです。
    *   **重要: 設定はすべて `script/config.sh` で一元管理してください。APIキーやパスは `.plist` には直接書かず、`config.sh` にまとめて記述します。**
    *   `.plist` の `ProgramArguments` で `--config /ABSOLUTE/PATH/TO/YOUR/AppLaud/script/config.sh` を渡すことで、設定ファイルの場所を明示的に指定できます。
    *   **file_mover.sh 側の設定ファイル読込例:**
        ```zsh
        #!/bin/zsh
        # 設定ファイルのパスを引数で受け取る
        if [[ "$1" == "--config" && -n "$2" ]]; then
          source "$2"
          shift 2
        else
          source "./config.sh"
        fi
        # ...以降、環境変数として設定値が利用可能...
        ```
    *   **手順:**
        1.  テンプレートファイルを `~/Library/LaunchAgents/` ディレクトリにコピーします。
            ```bash
            cp script/com.example.applaud.filemover.plist ~/Library/LaunchAgents/
            ```
        2.  コピーした `~/Library/LaunchAgents/com.example.applaud.filemover.plist` をテキストエディタで開きます。
        3.  ファイル内の以下のプレースホルダーを、ご自身の環境に合わせて修正してください。
            *   `/ABSOLUTE/PATH/TO/YOUR/AppLaud/script/file_mover.sh`: `file_mover.sh` スクリプトへの絶対パス。
            *   `/ABSOLUTE/PATH/TO/YOUR/AppLaud/script/config.sh`: `config.sh` への絶対パス。
            *   `/Volumes/YOUR_RECORDER_NAME`: `WatchPaths` 内。`config.sh` の `RECORDER_NAME` で設定したボイスレコーダーのボリューム名（例: `/Volumes/IC RECORDER`）。
            *   ログパス (`StandardOutPath`, `StandardErrorPath`) も必要に応じて変更してください（デフォルトは `/tmp/` 以下に出力されます）。
        4.  編集後、`launchd` エージェントを読み込みます。
            ```bash
            launchctl load ~/Library/LaunchAgents/com.example.applaud.filemover.plist
            ```
        5.  これで、指定したUSBデバイスがマウントされると自動的に `file_mover.sh` が実行されるようになります。
    *   **動作確認とログ:**
        *   ログは `.plist` ファイル内で指定したパス（デフォルトでは `/tmp/com.example.applaud.filemover.stdout.log` および `stderr.log`）に出力されます。問題が発生した場合はこれらのログファイルを確認してください。
        *   Console.app (`アプリケーション > ユーティリティ > コンソール`) でも `launchd` やスクリプトからのログを確認できる場合があります。
        *   **tailコマンドによるリアルタイム監視例:**
            ```bash
            tail -f /tmp/com.example.applaud.filemover.stdout.log
            tail -f /tmp/com.example.applaud.filemover.stderr.log
            ```
        *   ログファイルの内容をリアルタイムで確認したい場合に便利です。
    *   **アンロード (停止):**
        *   `launchd` エージェントの動作を停止（アンロード）するには、以下のコマンドを実行します。
            ```bash
            launchctl unload ~/Library/LaunchAgents/com.example.applaud.filemover.plist
            ```
        *   アンロード後、再度有効にするには `launchctl load` を実行します。`.plist` ファイルを修正した場合は、アンロードしてからロードし直すことで変更が反映されます。
6.  **動作確認用ディレクトリの作成 (任意):**
    *   `debug/dummy_usb/` にサンプル音声ファイルを置くことで、USB接続なしに動作をテストできます (別途 `file_mover.sh` の修正または手動実行が必要)。
    *   `debug/processed_audio/` と `debug/summaries/` は、処理された音声ファイルと生成されたMarkdownファイルが保存される場所のデフォルト例です。`.gitignore` にも含まれています。

## 使い方

1.  上記セットアップを完了します。
2.  設定したボイスレコーダーをMacにUSB接続します。
3.  自動的に処理が開始され、`config.sh` で指定した `MARKDOWN_OUTPUT_DIR` に要約Markdownファイルが生成されます。
4.  処理済みの音声ファイルは `AUDIO_DEST_DIR` に移動されます。
5.  処理のログは `PROCESSED_LOG_FILE` (デフォルト: `debug/processed_log.jsonl`) に記録されます。

## 注意事項

*   本アプリケーションはmacOSでの使用を前提としています。特に `launchd` を利用した自動実行部分はmacOS特有の機能です。
*   APIキーの取り扱いには十分注意してください。環境変数など、安全な方法で管理してください。
*   長時間音声の処理には時間がかかる場合があります。

## 今後の改善点 (TODO)

*   Windows/Linuxへの対応。
*   より詳細なエラーハンドリングと通知機能。
*   Web UIによる設定や操作インターフェース。
*   `launchd.plist` の設定を簡略化する補助スクリプトや、より詳細なインストラクションの提供。

詳細は `document/project.md` を参照してください。

## ライセンス

本ソフトウェアはMITライセンスのもとで公開しています。詳細は [LICENSE](LICENSE) を参照してください。
