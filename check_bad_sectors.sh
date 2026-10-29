#!/bin/sh
# 接続されているHDDの不良セクタ数を smartctl で調べて表示する
# 不良セクタ数 = Reallocated_Sector_Ct(5) + Current_Pending_Sector(197) + Offline_Uncorrectable(198)
# 不良セクタが 0 のディスクは、マウント先に約1GBのテストファイルを書き込み・読み戻して
# チェックサムを比較する。テストファイルは終了時(中断時含む)に必ず削除する。
# 使い方: sudo ./check_bad_sectors.sh   (テストサイズ変更: TEST_MB=512 ./check_bad_sectors.sh)

TEST_MB=${TEST_MB:-1024}
TESTFILE=""

if ! command -v smartctl >/dev/null 2>&1; then
    echo "smartctl not found (macOS: brew install smartmontools / Linux: apt install smartmontools)" >&2
    exit 2
fi

if command -v sha256sum >/dev/null 2>&1; then
    SHA="sha256sum"
else
    SHA="shasum -a 256"
fi

cleanup() {
    [ -n "$TESTFILE" ] && rm -f "$TESTFILE"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# macOS: df の /dev/diskXsY から、物理ディスク(whole disk)名を求める
whole_of() {
    info=$(diskutil info "$1" 2>/dev/null)
    store=$(printf '%s\n' "$info" | awk -F': *' '/APFS Physical Store/ {print $2; exit}')
    [ -n "$store" ] && info=$(diskutil info "$store" 2>/dev/null)
    printf '%s\n' "$info" | awk -F': *' '/Part of Whole/ {print "/dev/" $2; exit}'
}

# デバイスにマウントされている書き込み可能なディレクトリを列挙する
mounts_of() {
    dev=$1
    if [ "$(uname)" = "Darwin" ]; then
        df -P | awk 'NR>1 && $1 ~ /^\/dev\/disk/ {d=$1; $1=$2=$3=$4=$5=""; sub(/^ +/, ""); print d "\t" $0}' |
        while IFS="$(printf '\t')" read -r fs mp; do
            [ "$(whole_of "$fs")" = "$dev" ] && echo "$mp"
        done
    else
        lsblk -nro MOUNTPOINT "$dev" 2>/dev/null | grep '^/'
    fi
}

drop_cache() {
    sync
    if [ "$(uname)" = "Darwin" ]; then
        purge 2>/dev/null
    elif [ -w /proc/sys/vm/drop_caches ]; then
        echo 3 > /proc/sys/vm/drop_caches
    fi
}

# 戻り値: 0=OK, 1=NG, 2=SKIP(テスト先なし/容量不足)
io_test() {
    dev=$1
    dir=""
    for mp in $(mounts_of "$dev" | tr ' ' '\001'); do
        mp=$(printf '%s' "$mp" | tr '\001' ' ')
        free_kb=$(df -Pk "$mp" | awk 'NR==2 {print $4}')
        if [ -w "$mp" ] && [ "${free_kb:-0}" -gt $((TEST_MB * 1024 * 12 / 10)) ]; then
            dir=$mp
            break
        fi
    done
    [ -z "$dir" ] && return 2

    TESTFILE="$dir/.smart_io_test.$$"
    # 書き込みと同時に書いたデータのハッシュを取る
    wsum=$(dd if=/dev/urandom bs=1048576 count="$TEST_MB" 2>/dev/null | tee "$TESTFILE" | $SHA | awk '{print $1}')
    drop_cache
    rsum=$($SHA < "$TESTFILE" | awk '{print $1}')
    rm -f "$TESTFILE"
    TESTFILE=""

    [ -n "$wsum" ] && [ "$wsum" = "$rsum" ]
}

total=0
io_failed=0

for dev in $(smartctl --scan | awk '{print $1}'); do
    attrs=$(smartctl -A "$dev" 2>/dev/null)

    # 属性テーブルがない(NVMe等)デバイスは対象外
    if ! printf '%s\n' "$attrs" | grep -q 'RAW_VALUE'; then
        echo "$dev Failed: N/A"
        continue
    fi

    # 先頭の数値部分のみを RAW 値として加算する
    count=$(printf '%s\n' "$attrs" | awk '$1==5 || $1==197 || $1==198 {s += $10+0} END {print s+0}')

    echo "$dev Failed: $count"
    total=$((total + count))

    # 不良セクタ0(SMART上はpass)のディスクのみ実読み書きテスト
    if [ "$count" -eq 0 ]; then
        io_test "$dev"
        case $? in
            0) echo "$dev IO test: OK (${TEST_MB}MB)" ;;
            2) echo "$dev IO test: SKIP (no writable mount with enough space)" ;;
            *) echo "$dev IO test: FAILED"; io_failed=$((io_failed + 1)) ;;
        esac
    fi
done

echo "Total Failed: $total"
echo "IO Test Failed: $io_failed"

[ "$total" -eq 0 ] && [ "$io_failed" -eq 0 ]
