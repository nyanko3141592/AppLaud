#!/bin/zsh

# file_mover.sh
#
# USBデバイスがマウントされた際に呼び出され、音声ファイルを処理するスクリプト。
#
# 処理内容:
# 1. 設定ファイルを読み込む。
# 2. マウントされたUSBデバイスのパスを引数として受け取る。
# 3. デバイス内の音声ファイルを検索する。
# 4. ファイルを指定ディレクトリに移動する。
# 5. Pythonスクリプトを呼び出して文字起こしと要約を行う。

echo "引数: $@"

# --- 柔軟な引数パース（--configとマウントパスの順不同対応） ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG_FILE="${SCRIPT_DIR}/config.sh"
MOUNTED_DEVICE_PATH=""
LOCAL_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            if [[ -n "$2" ]]; then
                CONFIG_FILE="$2"
                shift 2
            else
                echo "エラー: --config オプションの後にパスが必要です" >&2
                exit 1
            fi
            ;;
        --local-only)
            # Issue #3: デバイス探索をスキップし、ローカル音声のみ処理する
            LOCAL_ONLY=1
            shift
            ;;
        *)
            if [[ -z "$MOUNTED_DEVICE_PATH" ]]; then
                MOUNTED_DEVICE_PATH="$1"
            fi
            shift
            ;;
    esac
done

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "設定ファイルを読み込みました: $CONFIG_FILE"
else
    echo "エラー: 設定ファイルが見つかりません: $CONFIG_FILE" >&2
    exit 1
fi

if [ -z "$MOUNTED_DEVICE_PATH" ] && [ $LOCAL_ONLY -eq 0 ]; then
    echo "エラー: マウントされたUSBデバイスのパスが指定されていません。" >&2
    echo "使用法: $0 <マウントパス> [--config <設定ファイル>] または $0 --local-only [--config <設定ファイル>]" >&2
    exit 1
fi

if [ $LOCAL_ONLY -eq 1 ]; then
    echo "ローカルオンリーモード: デバイス探索をスキップします。"
else
    echo "マウントパス: $MOUNTED_DEVICE_PATH"
fi

if [ $LOCAL_ONLY -eq 0 ]; then
# --- 検索対象パスの決定 ---
SEARCH_PATH="$MOUNTED_DEVICE_PATH"
if [ -n "$VOICE_FILES_SUBDIR" ]; then
    SEARCH_PATH="${MOUNTED_DEVICE_PATH}/${VOICE_FILES_SUBDIR}"
fi
echo "検索対象パス: $SEARCH_PATH"

# --- マウントポイントの準備待機 ---
echo "マウントポイント準備待機中: $SEARCH_PATH"
RETRY_COUNT=0
MAX_RETRIES=30 # 最大30秒待機
while [ ! -d "$SEARCH_PATH" ]; do
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "エラー: $SEARCH_PATH が $MAX_RETRIES 秒以内に利用可能になりませんでした。"
        exit 1
    fi
    sleep 1
    RETRY_COUNT=$((RETRY_COUNT + 1))
done
echo "$SEARCH_PATH 準備完了。"
fi

# --- ディレクトリ作成 ---
mkdir -p "${AUDIO_DEST_DIR}"
echo "音声ファイル保存先ディレクトリを確認/作成しました: ${AUDIO_DEST_DIR}"
mkdir -p "${MARKDOWN_OUTPUT_DIR}"
echo "Markdown出力先ディレクトリを確認/作成しました: ${MARKDOWN_OUTPUT_DIR}"
LOG_FILE_DIR=$(dirname "${PROCESSED_LOG_FILE}")
if [ ! -d "$LOG_FILE_DIR" ]; then
    mkdir -p "$LOG_FILE_DIR"
    echo "ログファイル用ディレクトリを作成しました: $LOG_FILE_DIR"
fi
touch "${PROCESSED_LOG_FILE}"
echo "処理済み記録ファイルを確認/作成しました: ${PROCESSED_LOG_FILE}"

AUDIO_DONE_DIR="${AUDIO_DEST_DIR}/done"
mkdir -p "${AUDIO_DONE_DIR}"
echo "完了ファイル保存先ディレクトリを確認/作成しました: ${AUDIO_DONE_DIR}"

if [ $LOCAL_ONLY -eq 0 ]; then
# --- 音声ファイルの検索 ---
echo "指定されたパスから音声ファイルを検索します: $SEARCH_PATH"
echo "検索拡張子 (配列): ${TARGET_EXTENSIONS_ARRAY[@]}"

echo "findコマンド実行前に5秒待機します..."
sleep 5

find_args=("$SEARCH_PATH")

echo "実行するfindコマンドのパス部分: $find_args[1]"
print -lr -- "実行するfindコマンドの述語部分 (TARGET_EXTENSIONS_ARRAY):" "${TARGET_EXTENSIONS_ARRAY[@]}"

AUDIO_FILES=()
find_stderr_output=""
find_output_stdout=$(find "$find_args[1]" -type f \
    \( "${TARGET_EXTENSIONS_ARRAY[@]}" \) \
    -not -name '._*' \
    -print0 2> >(find_stderr_output=$(cat); echo "$find_stderr_output" >&2) )
find_exit_code=$?

echo "Find command exit code: $find_exit_code"

if [ $find_exit_code -ne 0 ]; then
    echo "エラー: findコマンドの実行に失敗しました。終了コード: $find_exit_code。パス: $find_args[1]" >&2
    if [ -n "$find_stderr_output" ] && [[ "$find_stderr_output" != *"Permission denied"* ]] && [[ "$find_stderr_output" != *"Operation not permitted"* ]]; then
        echo "Find command stderr: $find_stderr_output" >&2
    fi
    if [ ! -d "$find_args[1]" ]; then
        echo "エラー: 検索対象ディレクトリが存在しません: $find_args[1]" >&2
    fi
    exit 1
fi

if [ -n "$find_output_stdout" ]; then
  while IFS= read -r -d $'\0' file; do
      if [ -n "$file" ]; then
          AUDIO_FILES+=("$file")
      fi
  done <<< "$find_output_stdout"
else
  echo "findコマンドの標準出力は空でした（対象ファイルなし、またはエラー）。"
fi

echo "検出された音声ファイル (AUDIO_FILES配列):"
for f in "${AUDIO_FILES[@]}"; do echo "  - $f"; done

echo "検出された音声ファイル数: ${#AUDIO_FILES[@]}"

# --- ファイルごとの処理ループ ---
echo "\n処理を開始します..."

for audio_file_full_path in "${AUDIO_FILES[@]}"; do
    audio_file_name=$(basename "$audio_file_full_path")
    echo "\n--------------------------------------------------"
    echo "処理対象ファイル: $audio_file_full_path ($audio_file_name)"

    # --- ファイルの移動 ---
    destination_path="${AUDIO_DEST_DIR}/${audio_file_name}"
    echo "ファイルを移動します: $audio_file_full_path -> $destination_path"
    mv -f "$audio_file_full_path" "$destination_path"
    if [ $? -ne 0 ]; then
        echo "エラー: ファイルの移動に失敗しました: $audio_file_full_path" >&2
        # 移動失敗時もPythonスクリプトは呼び出されるため、ここではexitしない
    else
        echo "ファイルの移動に成功しました。"
    fi
done # 個別ファイル移動ループの終了
else
    echo "ローカルオンリーモード: デバイスからの移動をスキップし、${AUDIO_DEST_DIR} 内の未処理ファイルを処理します。"
fi

# --- Pythonスクリプトの呼び出し (AUDIO_DEST_DIR を対象とする) ---
# 個別ファイルごとではなく、一度だけ呼び出すように変更
# AUDIO_FILES 配列の要素数に関わらず、常にPythonスクリプトを呼び出す
abs_python_script_path="$(cd "${SCRIPT_DIR}" && realpath "${PYTHON_SCRIPT_PATH}")"
abs_summary_prompt_file_path="$(cd "${SCRIPT_DIR}" && realpath "${SUMMARY_PROMPT_FILE_PATH}")"
abs_processed_log_file_path="$(cd "${SCRIPT_DIR}" && realpath "${PROCESSED_LOG_FILE}")"
abs_markdown_output_dir="$(cd "${SCRIPT_DIR}" && realpath "${MARKDOWN_OUTPUT_DIR}")"
abs_audio_dest_dir_for_python="$(cd "${SCRIPT_DIR}" && realpath "${AUDIO_DEST_DIR}")"

echo "Pythonスクリプトを呼び出します: $abs_python_script_path (対象ディレクトリ: $abs_audio_dest_dir_for_python)"
python3 "$abs_python_script_path" \
    --audio_processing_dir "$abs_audio_dest_dir_for_python" \
    --markdown_output_dir "$abs_markdown_output_dir" \
    --summary_prompt_file_path "$abs_summary_prompt_file_path" \
    --processed_log_file_path "$abs_processed_log_file_path"

python_exit_code=$?
if [ $python_exit_code -eq 0 ]; then
    echo "Pythonスクリプトの実行に成功しました。"
    # Issue #2: 取り込み完了フラグを作成する
    # (applaud_resume_after_reboot.sh がこのフラグを確認してから pCloud 退避を起動する)
    INGEST_FLAG_PATH="${APPLAUD_INGEST_FLAG:-${SCRIPT_DIR}/../.ai-agent/tmp/applaud_ingest_done.flag}"
    mkdir -p "$(dirname "$INGEST_FLAG_PATH")"
    touch "$INGEST_FLAG_PATH"
    echo "取り込み完了フラグを作成しました: $INGEST_FLAG_PATH"
else
    echo "エラー: Pythonスクリプトの実行に失敗しました。(終了コード: $python_exit_code)" >&2
fi

echo "\n全ての処理が完了しました。"

# ローカルオンリーモードでは呼び出し元 (resume スクリプト) が成否を判定できるよう
# Pythonスクリプトの終了コードを伝播する。通常モードは従来どおり 0 で終了する。
if [ $LOCAL_ONLY -eq 1 ]; then
    exit $python_exit_code
fi
exit 0 