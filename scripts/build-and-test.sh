#!/bin/bash
# ビルドとテストを実行し、結果を build-log.txt に保存します。
cd "$(dirname "$0")/.." || exit 1
if ! command -v swift >/dev/null; then
  echo "Swift が見つかりません。App Store で Xcode を入れて一度起動してから、もう一度実行してください。"
  exit 1
fi
{
  echo "== swift --version"; swift --version
  echo "== swift build"; swift build 2>&1
  echo "== swift test"; swift test 2>&1
} | tee build-log.txt
echo
echo "結果は build-log.txt に保存しました。"
