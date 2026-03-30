# Good-RDMA 开发指南

本文档介绍如何在新环境（克隆代码后）配置并编译运行 Good-RDMA 项目。

---

## 环境依赖

### 系统依赖

| 依赖 | 说明 | 安装命令（CentOS/RHEL） |
|------|------|------------------------|
| GCC/G++ | C++11 支持 | `yum install gcc gcc-c++` |
| autoconf | 自动配置脚本生成 | `yum install autoconf` |
| automake | Makefile 生成 | `yum install automake` |
| libtool | 共享库管理 | `yum install libtool` |
| libibverbs | RDMA  verbs | `yum install libibverbs-devel` |
| Boost >= 1.53 | 线程和系统库 | `yum install boost-devel` |
| pthread | POSIX 线程 | 通常已默认安装 |

### Boost 库路径

项目默认使用本地预置的 Boost 1.53.0（路径：`/share/home/lifr/workspace/data/boost1.53.0`）。如果使用系统安装的 Boost，可以设置环境变量：

```bash
export BOOST_HOME=/usr
```

或者在编译时通过 `BOOST_HOME=/usr make ...` 覆盖。

---

## 构建

使用 `build.sh` 一键构建所有模块：

```bash
bash scripts/build.sh
```

默认构建所有模块（libcuckoo、src、test、dht），支持以下选项：

| 选项 | 说明 |
|------|------|
| `--all` | 构建所有模块（默认） |
| `--src` | 仅构建核心库 `src/` |
| `--test` | 仅构建测试程序 `test/` |
| `--dht` | 仅构建 DHT 模块 |
| `--database` | 仅构建数据库测试 |
| `--clean` | 清理后重新构建 |
| `--help` | 显示帮助信息 |

**构建流程（默认 --all）：**

1. **构建 libcuckoo**：运行 `autoconf` 生成配置脚本，执行 `./configure`，编译并安装 cityhash 库
2. **构建核心库**：`src/Makefile` 执行 `make -j`，生成 `libgalloc.a`
3. **构建测试程序**：`test/Makefile` 执行 `make build -j`，生成 benchmark、master、worker 等可执行文件
4. **构建 DHT 模块**：`dht/Makefile` 执行 `make -j`，生成 DHT benchmark

**示例：**

```bash
# 构建所有
bash scripts/build.sh

# 仅构建核心库
bash scripts/build.sh --src

# 清理后重新构建
bash scripts/build.sh --clean

# 构建特定模块
bash scripts/build.sh --test
bash scripts/build.sh --dht
```

## 清理

```bash
# 清理所有编译产物（.o、libgalloc.a、测试程序、日志、core dump）
bash scripts/clean-all.sh
```

`clean-all.sh` 会清理以下内容：

| 目录/文件 | 清理内容 |
|-----------|----------|
| `src/` | `.o`、`.a`、`.so`、可执行文件 |
| `test/` | benchmark、master、worker 等测试程序 |
| `dht/` | `.o`、benchmark、kvbench、kvserver |
| `database/` | `.o` 文件 |
| `lib/libcuckoo/` | Autotools 配置残留（Makefile、configure、.libs 等） |
| `scripts/` | 日志文件 `log.*` |
| 项目根目录 | `core.*`、`core` |

清理远程节点进程：

```bash
bash scripts/killall.sh
```

该脚本同时清理本地和 `scripts/slaves` 中配置的远程节点，杀掉所有 benchmark 进程并释放端口 1231、12345。

---

## 运行程序

### 配置文件

编辑 `scripts/slaves` 文件，配置集群节点信息。格式为每行一个节点，格式为：

```
<IP> <端口>
```

例如：

```
10.10.11.22 12345
10.10.11.23 12345
10.10.11.24 12345
```

### 运行 benchmark 测试

```bash
cd /path/to/good-rdma/test

# 在 master 节点上运行
./benchmark --cache_th 0.15 --op_type 0 --no_node 2 --no_thread 4 \
    --remote_ratio 50 --shared_ratio 0 --read_ratio 50 \
    --space_locality 0 --time_locality 0 \
    --result_file ./results/test.txt \
    --ip_master 10.10.11.22 --ip_worker 10.10.11.22 --port_worker 12345 \
    --is_master 1 --port_master 12341

# 在 worker 节点上运行
ssh 10.10.11.23 "./test/benchmark --cache_th 0.15 --op_type 0 --no_node 2 --no_thread 4 \
    --remote_ratio 50 --shared_ratio 0 --read_ratio 50 \
    --space_locality 0 --time_locality 0 \
    --result_file ./results/test.txt \
    --ip_master 10.10.11.22 --ip_worker 10.10.11.23 --port_worker 12345 \
    --is_master 0 --port_master 12341"
```

或者使用自动化脚本：

```bash
cd /path/to/good-rdma
bash scripts/benchmark-all.sh
```

### 运行其他测试程序

```bash
# 锁测试
./lock_test

# 示例程序
./example

# Worker 测试
./worker
```

---

## 快速参考

### 常用命令汇总

```bash
# 一键构建所有模块
bash scripts/build.sh

# 清理 + 重新构建
bash scripts/build.sh --clean

# 清理编译产物
bash scripts/clean-all.sh

# 清理远程节点进程
bash scripts/killall.sh
```

### 目录结构

```
good-rdma/
├── src/                 # 核心库 libgalloc.a 源代码
│   ├── Makefile
│   └── libgalloc.a       # 编译产物
├── test/                # 测试程序
│   ├── Makefile
│   ├── benchmark        # 基准测试程序
│   └── ...
├── dht/                 # DHT 模块
│   ├── Makefile
│   └── kvbench         # KV 基准测试
├── database/            # 数据库集成测试
│   ├── tpcc/           # TPC-C 基准测试
│   └── test/           # 数据库测试
├── lib/
│   └── libcuckoo/      # libcuckoo 哈希库（包含 cityhash）
│       └── cityhash-1.1.1/
│           └── src/.libs/libcityhash.a  # cityhash 库文件
├── scripts/
│   ├── build.sh         # 一键构建脚本
│   ├── clean-all.sh     # 清理脚本
│   ├── killall.sh       # 清理远程节点进程
│   ├── slaves          # 集群节点配置
│   └── benchmark-all.sh # 自动化基准测试
└── include/            # 头文件
```

### 常见问题

**1. `libcityhash.a` 找不到**

确保 libcuckoo 已正确构建并执行了 `make install`，cityhash 库会被安装到 `lib/libcuckoo/cityhash-1.1.1/src/.libs/`。

**2. `libibverbs` 链接失败**

确保已安装 `libibverbs-devel`。如果系统没有 RDMA 网卡，也需要安装兼容的 providers（如 `rdma-core`）。

**3. Boost 库版本问题**

项目默认使用 Boost 1.53.0。如果使用更高版本，可能需要调整代码或 Makefile。

**4. Autotools 工具缺失**

如果 `autoreconf` 或 `configure` 命令不存在，需要安装 `autoconf`、`automake`、`libtool`。
