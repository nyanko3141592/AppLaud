#!/bin/zsh

# applaud_resume_after_reboot.sh
#
# 再起動後の復帰処理を行うスクリプト。
#
# 処理内容:
# 1. ローカル音声ディレクトリ (AUDIO_DEST_DIR) に未処理の音声ファイルが
#    残っていれば、録音デバイスが接続されていなくても処理できるよう
#    file_mover.sh --local-only で取り込む (Issue #3)。
# 2. 取り込み完了フラグ (.ai-agent/tmp/applaud_ingest_done.flag) を
#    上限時間つきで待つ (Issue #2)。フラグは file_mover.sh が処理を
#    正常完了したときに作成する。
# 3. フラグが確認できたら pCloud 退避 (applaud_pcloud_backup.sh) を実行し、
#    フラグを消費 (削除) する。タイムアウトした場合は退避をスキップして
#    正常終了する (退避が取り込み完了前に走る事態を防ぐのが目的)。
#
# 使い方:
#   applaud_resume_after_reboot.sh [--config <config.sh>]
#
# 環境変数:
#   APPLAUD_INGEST_FLAG        フラグファイルのパス
#                              (既定: <repo>/.ai-agent/tmp/applaud_ingest_done.flag)
#   APPLAUD_FLAG_WAIT_TIMEOUT  フラグ待機の上限秒数 (既定: 600)
#   APPLAUD_FLAG_POLL_SEC      フラグ確認の間隔秒数 (既定: 5)

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
CONFIG_FILE="${REPO_ROOT}/script/config.sh"

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
        *)
            echo "警告: 未知の引数を無視します: $1" >&2
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

FILE_MOVER="${REPO_ROOT}/script/file_mover.sh"
BACKUP_SCRIPT="${REPO_ROOT}/.ai-agent/tmp/applaud_pcloud_backup.sh"
INGEST_FLAG="${APPLAUD_INGEST_FLAG:-${REPO_ROOT}/.ai-agent/tmp/applaud_ingest_done.flag}"
FLAG_WAIT_TIMEOUT="${APPLAUD_FLAG_WAIT_TIMEOUT:-600}"
FLAG_POLL_SEC="${APPLAUD_FLAG_POLL_SEC:-5}"

# AUDIO_DEST_DIR の解決 (相対パスは config.sh のあるディレクトリ基準)
AUDIO_DIR="${AUDIO_DEST_DIR}"
if [[ "$AUDIO_DIR" != /* ]]; then
    AUDIO_DIR="$(cd "$(dirname "$CONFIG_FILE")" && realpath "$AUDIO_DIR" 2>/dev/null || echo "$AUDIO_DIR")"
fi

if [ ! -d "$AUDIO_DIR" ]; then
    echo "音声ディレクトリが存在しないため、復帰処理は不要です: $AUDIO_DIR"
    exit 0
fi
echo "音声ディレクトリ: $AUDIO_DIR"

# --- 1. ローカル未処理音声の取り込み (Issue #3: --local-only を優先使用) ---
unprocessed_count=$(find "$AUDIO_DIR" -maxdepth 1 -type f \( -iname '*.wav' -o -iname '*.mp3' -o -iname '*.m4a' \) | wc -l | tr -d ' ')
ingest_attempted=0
ingest_rc=0

if [ "$unprocessed_count" -gt 0 ]; then
    echo "未処理の音声ファイルが ${unprocessed_count} 件あります。file_mover.sh --local-only で取り込みます。"
    ingest_attempted=1
    "$FILE_MOVER" --local-only --config "$CONFIG_FILE"
    ingest_rc=$?
    if [ $ingest_rc -ne 0 ]; then
        echo "警告: ローカル取り込みが失敗しました (終了コード: $ingest_rc)。pCloud退避は行いません。" >&2
        exit 0
    fi
    echo "ローカル取り込みが完了しました。"
else
    echo "未処理の音声ファイルはありません。"
fi

# --- 2. 転記キャッシュの有無を確認 ---
transcription_count=$(find "$AUDIO_DIR" -maxdepth 1 -type f -name '*_transcription.txt' | wc -l | tr -d ' ')
if [ "$transcription_count" -eq 0 ]; then
    echo "退避対象の転記ファイルがないため、復帰処理を終了します。"
    exit 0
fi
echo "転記ファイルが ${transcription_count} 件あります。取り込み完了フラグを確認します: $INGEST_FLAG"

# --- 3. 取り込み完了フラグを上限つきで待つ (Issue #2) ---
elapsed=0
while [ ! -f "$INGEST_FLAG" ]; do
    if [ $elapsed -ge $FLAG_WAIT_TIMEOUT ]; then
        echo "警告: 取り込み完了フラグが ${FLAG_WAIT_TIMEOUT} 秒以内に現れなかったため、pCloud退避をスキップします。" >&2
        exit 0
    fi
    sleep $FLAG_POLL_SEC
    elapsed=$((elapsed + FLAG_POLL_SEC))
done
echo "取り込み完了フラグを確認しました。"

# --- 4. pCloud 退避を実行し、フラグを消費する ---
"$BACKUP_SCRIPT" --config "$CONFIG_FILE"
backup_rc=$?
if [ $backup_rc -eq 0 ]; then
    rm -f "$INGEST_FLAG"
    echo "pCloud退避が完了し、取り込み完了フラグを消費しました。"
else
    echo "警告: pCloud退避が失敗しました (終了コード: $backup_rc)。フラグは残します。" >&2
fi

exit $backup_rc
