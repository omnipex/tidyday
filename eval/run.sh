#!/bin/zsh
# 編譯 App 的原始碼（不含 @main）＋ Eval.swift，跑分類評估。用法：eval/run.sh [每案次數=3] [案例 id 前綴]
set -e
D=${0:A:h}
B=$D/build
rm -rf $B; mkdir -p $B
for f in $D/../Sources/TidyDay/*.swift; do [ "${f:t}" = TidyDayApp.swift ] || cp $f $B/; done
cp $D/Eval.swift $B/main.swift
swiftc -swift-version 5 -O $B/*.swift -o $B/eval 2>&1 | grep error: || true
$B/eval "$@"
