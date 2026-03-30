#!/bin/bash
#
# Good-RDMA 一键构建脚本
#
# 用法: bash scripts/build.sh [选项]
#
# 选项:
#   --all       构建所有模块（src, test, dht, database）
#   --src       仅构建核心库 src/
#   --test      仅构建测试程序 test/
#   --dht       仅构建 DHT 模块
#   --database  仅构建数据库测试
#   --clean     清理后重新构建
#   --help      显示帮助信息
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="$(cd "$(dirname "$SCRIPT_DIR")" && pwd)"
BOOST_HOME="${BOOST_HOME:-/share/home/lifr/workspace/data/boost1.53.0}"

BUILD_ALL=0
BUILD_SRC=0
BUILD_TEST=0
BUILD_DHT=0
BUILD_DATABASE=0
CLEAN=0

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            BUILD_ALL=1
            shift
            ;;
        --src)
            BUILD_SRC=1
            shift
            ;;
        --test)
            BUILD_TEST=1
            shift
            ;;
        --dht)
            BUILD_DHT=1
            shift
            ;;
        --database)
            BUILD_DATABASE=1
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --help|-h)
            echo "用法: bash $0 [选项]"
            echo ""
            echo "选项:"
            echo "  --all       构建所有模块（src, test, dht, database）"
            echo "  --src       仅构建核心库 src/"
            echo "  --test      仅构建测试程序 test/"
            echo "  --dht       仅构建 DHT 模块"
            echo "  --database  仅构建数据库测试"
            echo "  --clean     清理后重新构建"
            echo "  --help      显示帮助信息"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            echo "使用 --help 查看帮助"
            exit 1
            ;;
    esac
done

# 如果没有指定任何模块，默认构建所有
if [[ $BUILD_ALL -eq 0 && $BUILD_SRC -eq 0 && $BUILD_TEST -eq 0 && $BUILD_DHT -eq 0 && $BUILD_DATABASE -eq 0 ]]; then
    BUILD_ALL=1
fi

# 清理
if [[ $CLEAN -eq 1 ]]; then
    echo "========================================"
    echo "清理旧的编译产物..."
    echo "========================================"
    bash "$SCRIPT_DIR/clean.sh"
fi

echo ""
echo "========================================"
echo "Good-RDMA 构建脚本"
echo "Boost 路径: $BOOST_HOME"
echo "========================================"
echo ""

# =============================================
# 步骤 1: 构建 libcuckoo（包含 cityhash）
# =============================================
build_libcuckoo() {
    echo ""
    echo "[1/4] 构建 libcuckoo (cityhash)..."
    echo "----------------------------------------"

    cd "$PROJ_DIR/lib/libcuckoo"

    # 检查是否已构建（configure 存在且 libcityhash.a 存在）
    if [[ -f "cityhash-1.1.1/src/.libs/libcityhash.a" ]]; then
        echo "  libcuckoo 已构建，跳过。"
        return 0
    fi

    # 如果已配置但库不存在，执行 make
    if [[ -f "Makefile" ]]; then
        echo "  重新构建 libcuckoo..."
        make clean 2>/dev/null || true
        make 2>/dev/null || true
    else
        echo "  运行 autoconf..."
        autoreconf -i 2>/dev/null || true

        echo "  配置 libcuckoo..."
        ./configure --prefix=$(pwd) 2>/dev/null || true

        echo "  编译 libcuckoo..."
        make 2>/dev/null || true
    fi

    echo "  安装 libcuckoo..."
    make install 2>/dev/null || true

    # 验证
    if [[ -f "cityhash-1.1.1/src/.libs/libcityhash.a" ]]; then
        echo "  [OK] cityhash 库已就绪"
    else
        echo "  [ERROR] cityhash 库构建失败"
        return 1
    fi
}

# =============================================
# 步骤 2: 构建核心库
# =============================================
build_src() {
    echo ""
    echo "[2/4] 构建核心库 libgalloc.a..."
    echo "----------------------------------------"

    cd "$PROJ_DIR/src"

    echo "  编译中 (make -j)..."
    make -j

    if [[ -f "libgalloc.a" ]]; then
        echo "  [OK] libgalloc.a 已生成 ($(du -h libgalloc.a | cut -f1))"
    else
        echo "  [ERROR] libgalloc.a 构建失败"
        return 1
    fi
}

# =============================================
# 步骤 3: 构建测试程序
# =============================================
build_test() {
    echo ""
    echo "[3/4] 构建测试程序..."
    echo "----------------------------------------"

    cd "$PROJ_DIR/test"

    echo "  编译中 (make build -j)..."
    make clean 2>/dev/null || true
    make build -j

    echo "  [OK] 测试程序已构建:"
    for prog in benchmark lru_test lock_test slab_test worker master rw_test fence_test hashtable_test cs_test; do
        if [[ -f "$prog" ]]; then
            echo "    - $prog"
        fi
    done
}

# =============================================
# 步骤 4: 构建 DHT 模块
# =============================================
build_dht() {
    echo ""
    echo "[4/4] 构建 DHT 模块..."
    echo "----------------------------------------"

    cd "$PROJ_DIR/dht"

    echo "  编译中 (make -j)..."
    make clean 2>/dev/null || true
    make -j

    if [[ -f "benchmark" ]]; then
        echo "  [OK] DHT benchmark 已生成"
    fi
}

# =============================================
# 执行构建
# =============================================
if [[ $BUILD_ALL -eq 1 ]]; then
    build_libcuckoo
    build_src
    build_test
    build_dht
elif [[ $BUILD_SRC -eq 1 ]]; then
    build_libcuckoo
    build_src
elif [[ $BUILD_TEST -eq 1 ]]; then
    build_libcuckoo
    build_src
    build_test
elif [[ $BUILD_DHT -eq 1 ]]; then
    build_libcuckoo
    build_src
    build_dht
elif [[ $BUILD_DATABASE -eq 1 ]]; then
    build_libcuckoo
    build_src
    echo ""
    echo "[extra] 构建数据库测试..."
    echo "----------------------------------------"
    cd "$PROJ_DIR/database/scripts"
    bash compile.sh
fi

echo ""
echo "========================================"
echo "构建完成！"
echo "========================================"
echo ""
echo "核心库: $PROJ_DIR/src/libgalloc.a"
echo "测试程序: $PROJ_DIR/test/"
echo ""
echo "下一步："
echo "  1. 配置节点: vi $PROJ_DIR/scripts/slaves"
echo "  2. 运行测试: cd $PROJ_DIR/test && ./example"
echo "  3. 运行基准测试: bash $PROJ_DIR/scripts/benchmark-all.sh"
echo ""
