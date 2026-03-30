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

## 构建步骤

### 完整构建流程

按照以下顺序执行：

```bash
cd /path/to/good-rdma

# =============================================
# 第 1 步：清理旧的编译产物（首次可跳过）
# =============================================
bash scripts/clean.sh

# =============================================
# 第 2 步：构建 libcuckoo（包含 cityhash）
#           libcuckoo 使用 Autotools 构建
# =============================================
cd lib/libcuckoo

# 运行 autoconf 生成 configure 脚本
autoreconf -i

# 配置并安装到项目目录
./configure --prefix=$(pwd)
make
make install
```

> **注意**：`make install` 会将 cityhash 的库文件安装到 `lib/libcuckoo/cityhash-1.1.1/src/.libs/` 目录，Good-RDMA 主项目从此路径链接 cityhash 库。

### 第 3 步：构建核心库 `libgalloc.a`

```bash
cd /path/to/good-rdma/src
make -j
```

这会编译 `src/` 下所有 `.cc` 文件并生成 `libgalloc.a` 静态库。

### 第 4 步：构建测试程序

有两种方式构建测试程序：

**方式 A：在 `src/` 目录下构建（部分测试）**

```bash
cd /path/to/good-rdma/src
make test -j
```

这会构建 `benchmark`、`lock_test`、`example`、`worker`、`master` 等测试程序。

**方式 B：在 `test/` 目录下构建（全部测试）**

```bash
cd /path/to/lifr/workspace/code/good-rdma/test
make build -j
```

这会构建所有测试程序：`benchmark`、`lru_test`、`lock_test`、`slab_test`、`hashtable_test`、`garray_test`、`cs_test` 等。

### 第 5 步：构建 DHT 模块（可选）

```bash
cd /path/to/good-rdma/dht
make -j
```

> DHT 模块需要 `src/libgalloc.a` 已构建完成。

### 第 6 步：构建数据库测试模块（可选）

```bash
cd /path/to/good-rdma/database/scripts
bash compile.sh
```

这会依次构建 `src/`、`database/tpcc/`、`database/test/` 三个部分。

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
# 完整构建
cd lib/libcuckoo && autoreconf -i && ./configure && make && make install
cd ../../src && make -j
cd ../test && make build -j

# 清理所有编译产物
bash scripts/clean.sh

# 查看可用的 make 目标
make help 2>/dev/null || make -n
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
│   ├── clean.sh        # 清理脚本
│   ├── slaves          # 集群节点配置
│   ├── test.sh         # 简单测试脚本
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

---

## 代码更新后的重新构建

每次 pull 新代码后，建议执行：

```bash
# 1. 清理旧产物
bash scripts/clean.sh

# 2. 重新构建（从 libcuckoo 开始）
cd lib/libcuckoo && make distclean 2>/dev/null; autoreconf -i && ./configure && make && make install
cd ../../src && make clean && make -j
cd ../test && make clean && make build -j

# 3. 验证构建成功
ls -la src/libgalloc.a test/benchmark
```
