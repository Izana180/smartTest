#!/bin/sh
# 接続されているHDDの不良セクタ数を smartctl で調べて表示する
# 不良セクタ数 = Reallocated_Sector_Ct(5) + Current_Pending_Sector(197) + Offline_Uncorrectable(198)
# 使い方: sudo ./check_bad_sectors.sh

if ! command -v smartctl >/dev/null 2>&1; then
    echo "smartctl not found (macOS: brew install smartmontools / Linux: apt install smartmontools)" >&2
    exit 2
fi

total=0

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
done

echo "Total Failed: $total"

[ "$total" -eq 0 ]
