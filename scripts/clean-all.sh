#!/bin/bash
# Copyright (c) 2018 The GAM authors

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="${PROJ_DIR:-${SCRIPT_DIR}}"

echo "正在清理 $PROJ_DIR ..."

# 停止相关进程
pids=$(ps -ef | grep "$PROJ_DIR" | grep -v grep | grep -v "$0" | awk '{print $2}')
if [[ -n "$pids" ]]; then
    echo "正在终止进程..."
    kill -9 $pids 2>/dev/null || true
fi

# src 目录
echo "清理 src 目录..."
make -C "$PROJ_DIR/src" clean 2>/dev/null || rm -f "$PROJ_DIR/src"/*.o "$PROJ_DIR/src"/*.a "$PROJ_DIR/src"/*.so "$PROJ_DIR/src"/benchmark "$PROJ_DIR/src"/lock_test "$PROJ_DIR/src"/example "$PROJ_DIR/src"/example-r "$PROJ_DIR/src"/worker "$PROJ_DIR/src"/master "$PROJ_DIR/src"/rw_test "$PROJ_DIR/src"/fence_test "$PROJ_DIR/src"/gfunc_test "$PROJ_DIR/src"/map_test 2>/dev/null || true

# test 目录
echo "清理 test 目录..."
make -C "$PROJ_DIR/test" clean 2>/dev/null || rm -f \
    "$PROJ_DIR/test"/benchmark "$PROJ_DIR/test"/cs_test \
    "$PROJ_DIR/test"/example "$PROJ_DIR/test"/example-r \
    "$PROJ_DIR/test"/fence_test "$PROJ_DIR/test"/garray_test \
    "$PROJ_DIR/test"/gfunc_test "$PROJ_DIR/test"/hashtable_test \
    "$PROJ_DIR/test"/hashtable_throw_test "$PROJ_DIR/test"/lock_test \
    "$PROJ_DIR/test"/lru_test "$PROJ_DIR/test"/master \
    "$PROJ_DIR/test"/map_test "$PROJ_DIR/test"/rw_test \
    "$PROJ_DIR/test"/slab_test "$PROJ_DIR/test"/worker 2>/dev/null || true

# dht 目录
echo "清理 dht 目录..."
make -C "$PROJ_DIR/dht" clean 2>/dev/null || rm -f "$PROJ_DIR/dht"/*.o "$PROJ_DIR/dht"/benchmark "$PROJ_DIR/dht"/kvbench "$PROJ_DIR/dht"/kvclient "$PROJ_DIR/dht"/kvserver 2>/dev/null || true

# database 目录
echo "清理 database 目录..."
make -C "$PROJ_DIR/database" clean 2>/dev/null || (find "$PROJ_DIR/database" -name "*.o" -delete 2>/dev/null || true)

# libcuckoo (Autotools)
echo "清理 libcuckoo..."
if [[ -f "$PROJ_DIR/lib/libcuckoo/Makefile" ]]; then
    make -C "$PROJ_DIR/lib/libcuckoo" distclean 2>/dev/null || true
fi
# 清理残留的 Autotools 文件
rm -f "$PROJ_DIR/lib/libcuckoo"/Makefile "$PROJ_DIR/lib/libcuckoo"/Makefile.in
rm -f "$PROJ_DIR/lib/libcuckoo"/configure
rm -f "$PROJ_DIR/lib/libcuckoo"/aclocal.m4
rm -f "$PROJ_DIR/lib/libcuckoo"/install-sh "$PROJ_DIR/lib/libcuckoo"/missing "$PROJ_DIR/lib/libcuckoo"/depcomp
rm -f "$PROJ_DIR/lib/libcuckoo"/config.sub "$PROJ_DIR/lib/libcuckoo"/config.guess
rm -f "$PROJ_DIR/lib/libcuckoo"/libtool "$PROJ_DIR/lib/libcuckoo"/ltmain.sh
rm -f "$PROJ_DIR/lib/libcuckoo"/config.log "$PROJ_DIR/lib/libcuckoo"/config.status
rm -f "$PROJ_DIR/lib/libcuckoo"/config.h.in "$PROJ_DIR/lib/libcuckoo"/stamp-h1
rm -f "$PROJ_DIR/lib/libcuckoo"/compile "$PROJ_DIR/lib/libcuckoo"/test-driver
rm -rf "$PROJ_DIR/lib/libcuckoo"/autom4te.cache
rm -f "$PROJ_DIR/lib/libcuckoo"/m4/*.m4
rm -rf "$PROJ_DIR/lib/libcuckoo"/.libs "$PROJ_DIR/lib/libcuckoo"/*.lo "$PROJ_DIR/lib/libcuckoo"/*.la

# cityhash
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/Makefile "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/Makefile.in
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/configure
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/aclocal.m4
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/install-sh "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/missing "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/depcomp
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/config.sub "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/config.guess
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/libtool "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/ltmain.sh
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/config.log "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/config.status
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/config.h "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/config.h.in "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/stamp-h1
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/test-driver
rm -rf "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/autom4te.cache
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/m4/*.m4
rm -rf "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/.libs "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/*.lo "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1"/*.la

# cityhash/src
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1/src"/Makefile "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1/src"/Makefile.in
rm -rf "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1/src"/.deps "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1/src"/.libs
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1/src"/*.o "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1/src"/*.lo "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1/src"/*.la
rm -f "$PROJ_DIR/lib/libcuckoo/cityhash-1.1.1/src"/cityhash_unittest

# libcuckoo/tests
rm -f "$PROJ_DIR/lib/libcuckoo/tests"/Makefile "$PROJ_DIR/lib/libcuckoo/tests"/Makefile.in
rm -f "$PROJ_DIR/lib/libcuckoo/tests"/configure
rm -f "$PROJ_DIR/lib/libcuckoo/tests"/aclocal.m4
rm -f "$PROJ_DIR/lib/libcuckoo/tests"/install-sh "$PROJ_DIR/lib/libcuckoo/tests"/missing "$PROJ_DIR/lib/libcuckoo/tests"/depcomp
rm -f "$PROJ_DIR/lib/libcuckoo/tests"/config.sub "$PROJ_DIR/lib/libcuckoo/tests"/config.guess
rm -f "$PROJ_DIR/lib/libcuckoo/tests"/libtool "$PROJ_DIR/lib/libcuckoo/tests"/ltmain.sh
rm -f "$PROJ_DIR/lib/libcuckoo/tests"/test-driver
rm -rf "$PROJ_DIR/lib/libcuckoo/tests"/autom4te.cache
rm -f "$PROJ_DIR/lib/libcuckoo/tests"/m4/*.m4
rm -rf "$PROJ_DIR/lib/libcuckoo/tests"/.libs "$PROJ_DIR/lib/libcuckoo/tests"/*.lo "$PROJ_DIR/lib/libcuckoo/tests"/*.la
for subdir in "$PROJ_DIR/lib/libcuckoo/tests"/benchmarks "$PROJ_DIR/lib/libcuckoo/tests"/stress-tests "$PROJ_DIR/lib/libcuckoo/tests"/unit-tests; do
    rm -f "$subdir"/Makefile "$subdir"/Makefile.in 2>/dev/null || true
done

# scripts 目录日志文件
echo "清理日志文件..."
rm -f "$PROJ_DIR/scripts"/log.*

echo "清理 core dump..."
rm -f "$PROJ_DIR"/core.* "$PROJ_DIR"/core

echo "清理完成！"