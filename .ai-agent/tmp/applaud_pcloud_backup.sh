#!/bin/zsh

# applaud_pcloud_backup.sh
#
# 文字起こしキャッシュ (*_transcription.txt) を pCloud へ退避するスクリプト。
# transcribe_summarize.py が音声ファイルの隣に残す <stem>_transcription.txt を
# 対象に、コピー → 照合 (SHA-256) → 一致したものだけローカルを削除する。
#
# Issue #2 ガード:
#   同名の音声ファイル (<stem>.WAV など) が同じディレクトリに残っている
#   転記ファイルは「未処理 WAV のキャッシュ」なので、退避・削除の対象外にする。
#   キャッシュが消えると未処理 WAV の再文字起こしが必要になるため。
#
# 使い方:
#   applaud_pcloud_backup.sh [--config <config.sh>]
#
# 環境変数 (テスト・上書用):
#   APPLAUD_BACKUP_SRC_DIR  退避元ディレクトリ (既定: config.sh の AUDIO_DEST_DIR)
#   APPLAUD_PCLOUD_DIR      退避先ディレクトリ
#                           (既定: ~/pCloud Drive/AppLaud/transcription_cache)
#   APPLAUD_BACKUP_DRY_RUN  1 のときコピー・削除を行わず対象だけ表示する

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

# --- 退避元ディレクトリの決定 ---
SRC_DIR="${APPLAUD_BACKUP_SRC_DIR:-${AUDIO_DEST_DIR}}"
if [ -z "$SRC_DIR" ]; then
    echo "エラー: 退避元ディレクトリ (AUDIO_DEST_DIR) が設定されていません。" >&2
    exit 1
fi
# 相対パスは config.sh のあるディレクトリ基準で解決する (file_mover.sh と同じ流儀)
if [[ "$SRC_DIR" != /* ]]; then
    SRC_DIR="$(cd "$(dirname "$CONFIG_FILE")" && realpath "$SRC_DIR" 2>/dev/null || echo "$SRC_DIR")"
fi

if [ ! -d "$SRC_DIR" ]; then
    echo "エラー: 退避元ディレクトリが存在しません: $SRC_DIR" >&2
    exit 1
fi
echo "退避元ディレクトリ: $SRC_DIR"

# --- 退避先ディレクトリの決定 ---
DEST_DIR="${APPLAUD_PCLOUD_DIR:-${HOME}/pCloud Drive/AppLaud/transcription_cache}"
DRY_RUN="${APPLAUD_BACKUP_DRY_RUN:-0}"

if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$DEST_DIR"
    if [ ! -d "$DEST_DIR" ]; then
        echo "エラー: 退避先ディレクトリを作成できません: $DEST_DIR" >&2
        exit 1
    fi
fi
echo "退避先ディレクトリ: $DEST_DIR"

# --- 対象ファイルの走査 ---
BACKED_UP_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0

for f in "${SRC_DIR}"/*_transcription.txt(N); do
    base="${f:t}"
    stem="${base%_transcription.txt}"

    # Issue #2 ガード: 同名の音声ファイルが残っていれば未処理とみなし対象外
    unprocessed=0
    for ext in WAV wav MP3 mp3 M4A m4a; do
        if [ -f "${SRC_DIR}/${stem}.${ext}" ]; then
            unprocessed=1
            break
        fi
    done
    if [ $unprocessed -eq 1 ]; then
        echo "スキップ (未処理の音声が残存): $base"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    dest_path="${DEST_DIR}/${base}"

    if [ "$DRY_RUN" = "1" ]; then
        echo "DRY-RUN: 退避対象: $f -> $dest_path"
        BACKED_UP_COUNT=$((BACKED_UP_COUNT + 1))
        continue
    fi

    # コピー
    cp -p "$f" "$dest_path"
    if [ $? -ne 0 ]; then
        echo "エラー: コピーに失敗しました: $f" >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # 照合 (SHA-256)
    src_sum=$(shasum -a 256 "$f" | awk '{print $1}')
    dest_sum=$(shasum -a 256 "$dest_path" | awk '{print $1}')
    if [ -z "$src_sum" ] || [ "$src_sum" != "$dest_sum" ]; then
        echo "エラー: 照合に失敗したためローカルを残します: $base" >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    # 照合が取れたものだけローカルを削除する
    rm -f "$f"
    if [ -f "$f" ]; then
        echo "エラー: ローカルファイルの削除に失敗しました: $f" >&2
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    fi

    echo "退避完了: $base"
    BACKED_UP_COUNT=$((BACKED_UP_COUNT + 1))
done

echo "pCloud退避 結果: 退避 ${BACKED_UP_COUNT} 件 / スキップ ${SKIPPED_COUNT} 件 / エラー ${ERROR_COUNT} 件"

if [ $ERROR_COUNT -gt 0 ]; then
    exit 1
fi
exit 0
