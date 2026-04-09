#!/bin/bash
# 构建脚本：清理并重新编译 src 和 test 目录

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================"
echo "Building: $SCRIPT_DIR"
echo "======================================"

echo ""
echo "[1/2] === Cleaning src ==="
cd "$SCRIPT_DIR/src"
make clean 2>/dev/null || true
echo ""
echo "[1/2] === Building src ==="
make -j16

echo ""
echo "[2/2] === Cleaning test ==="
cd "$SCRIPT_DIR/test"
make clean 2>/dev/null || true
echo ""
echo "[2/2] === Building test ==="
make -j16

echo ""
echo "======================================"
echo "Build complete!"
echo "======================================"
