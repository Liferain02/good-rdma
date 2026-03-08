#!/usr/bin/env bash

# 3台机器
slaves_content="12.12.12.1 12345
12.12.12.2 12345
12.12.12.3 12345"

# 创建临时 slaves 文件
slaves_file=$(mktemp)
echo "$slaves_content" > "$slaves_file"

# 测试程序路径
SRC_HOME=/public/home/tensor/perl5/lifr/code/gam/test

# 运行测试
run() {
    echo "Starting gptr test..."
    old_IFS=$IFS
    IFS=$'\n'
    i=0
    for slave in `cat "$slaves_file"`
    do
        ip=`echo $slave | cut -d ' ' -f1`
        port=`echo $slave | cut -d ' ' -f2`
        if [ $i = 0 ]; then
            is_master=1
            master_ip=$ip
        else
            is_master=0
        fi
        echo "Starting node on $ip with is_master=$is_master"
        ssh $ip "$SRC_HOME/simple_gptr --ip_master $master_ip --ip_worker $ip --port_worker $port --is_master $is_master --port_master 12341" &
        sleep 1
        i=$((i+1))
    done
    wait
    IFS="$old_IFS"
    echo "Test completed."
}

# 执行测试
run

# 清理临时文件
rm "$slaves_file"