#!/bin/bash

# 定义要匹配的关键词列表
KEYWORDS=('lifr/code/gam/')

# 构建正则表达式（匹配任意一个关键词）
PATTERN=$(IFS="|"; echo "${KEYWORDS[*]}")

# 查找进程 PID
pids=$(ps -ef | grep -E "$PATTERN" | grep -v grep | awk '{print $2}')

if [[ -z "$pids" ]]; then
    echo "未找到以下关键词的进程: ${KEYWORDS[*]}"
    exit 0
fi

echo "正在终止以下进程 (关键词: ${KEYWORDS[*]}):"
echo "$pids"
kill -9 $pids
echo "操作完成"

# /public/home/tensor/perl5/lifr/code/rdma-tso-test/RDMA-tests/litmus-tests/kill.sh