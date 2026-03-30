#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ_DIR="${PROJ_DIR:-$SCRIPT_DIR/..}"
SLAVES_FILE="${SCRIPT_DIR}/slaves"
TIMEOUT=10

echo "============================================"
echo "开始清理所有节点上的旧进程..."
echo "============================================"

# 清理当前节点
echo ""
echo ">>> 清理本地节点..."
pkill -9 -f "benchmark" 2>/dev/null || true
sleep 2

# 确保端口释放
for port in 1231 12345; do
    pid=$(lsof -ti:$port 2>/dev/null || true)
    if [[ -n "$pid" ]]; then
        echo "  杀死占用端口 $port 的进程: $pid"
        kill -9 $pid 2>/dev/null || true
    fi
done

# 从 slaves 文件读取节点列表
if [[ ! -f "$SLAVES_FILE" ]]; then
    echo "错误: slaves 文件不存在: $SLAVES_FILE"
    exit 1
fi

echo ""
echo ">>> 清理远程节点..."

while IFS= read -r line; do
    # 跳过空行和注释
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue

    ip=$(echo "$line" | awk '{print $1}')
    port=$(echo "$line" | awk '{print $2}')

    [[ -z "$ip" ]] && continue

    echo ""
    echo ">>> 清理节点: $ip"

    # SSH 到远程节点，清理 benchmark 进程
    ssh -o ConnectTimeout=$TIMEOUT -o StrictHostKeyChecking=no "$ip" "
        pkill -9 -f 'benchmark' 2>/dev/null || true
        sleep 1

        # 清理占用端口的进程
        for p in 1231 12345; do
            pid=\$(lsof -ti:\$p 2>/dev/null || true)
            if [[ -n \"\$pid\" ]]; then
                echo '  killing port \$p pid: '\$pid
                kill -9 \$pid 2>/dev/null || true
            fi
        done

        sleep 1
        echo '  节点 $ip 清理完成'
    " 2>/dev/null &

done < "$SLAVES_FILE"

# 等待所有 SSH 命令完成
echo ""
echo ">>> 等待所有远程清理完成..."
wait

sleep 3

# 验证清理结果
echo ""
echo "============================================"
echo "清理完成！验证结果："
echo "============================================"

echo ""
echo ">>> 本地进程检查:"
ps aux | grep benchmark | grep -v grep || echo "  无 benchmark 进程运行"

echo ""
echo ">>> 本地端口检查:"
for port in 1231 12345; do
    if lsof -i:$port >/dev/null 2>&1; then
        echo "  端口 $port 仍被占用:"
        lsof -i:$port 2>/dev/null || true
    else
        echo "  端口 $port: 已释放"
    fi
done

echo ""
echo "============================================"
echo "清理脚本执行完毕！"
echo "============================================"
