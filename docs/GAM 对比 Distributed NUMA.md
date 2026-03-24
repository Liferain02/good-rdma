# GAM 对比 Distributed NUMA

> v1.0
>
> 李福润
>
> 2026/3/24

---

## 1. NUMA 是什么？

NUMA（Non-Uniform Memory Access，非均匀内存访问）是一种**对称多处理器（SMP）的扩展架构**。它将多个 CPU Socket 通过高速互联（如 Intel QPI、AMD Infinity Fabric）连接在一起，每个 Socket 拥有本地 DRAM：

```
        ┌─────────────────┐         ┌─────────────────┐
        │    Socket 0     │         │    Socket 1     │
        │  ┌───────────┐  │         │  ┌───────────┐  │
        │  │ CPU Cores │  │  QPI /  │  │ CPU Cores │  │
        │  │  L1/L2    │  │  IF     │  │  L1/L2    │  │
        │  └───────────┘  │◄───────►│  └───────────┘  │
        │  ┌───────────┐  │         │  ┌───────────┐  │
        │  │ L3 Cache  │  │         │  │ L3 Cache  │  │
        │  │  (LLC)    │  │         │  │  (LLC)    │  │
        │  └───────────┘  │         │  └───────────┘  │
        │  ┌───────────┐  │         │  ┌───────────┐  │
        │  │  Memory   │  │         │  │  Memory   │  │
        │  │ Controller│  │         │  │ Controller│  │
        │  └───────────┘  │         │  └───────────┘  │
        │       ↓         │         │       ↓         │
        │   本地 DRAM     │         │   本地 DRAM     │
        │   (低延迟)       │         │   (低延迟)       │
        └─────────────────┘         └─────────────────┘
                    ↑                           ↑
                    └─────── QPI / IF ─────────┘
                    (高延迟，但带宽高)
```

**关键特性**：

- **统一的虚拟地址空间**：所有 CPU 可以用同一个虚拟地址访问任意内存位置
- **不统一的访问延迟**：访问本地内存 ~80ns，访问远端内存 ~150ns（延迟差约 2 倍）
- **硬件一致性**：CPU Cache 之间通过 MESI 协议自动维护一致性
- **OS 透明性**：应用无需知道数据在哪，OS 自动处理页迁移（NUMA balancing）

---

## 2. NUMA 访问的完整路径

### 2.1 读内存（本地）

```
应用代码:  mov eax, [0x7f3a2b1c000]    ← 虚拟地址
                ↓
         页表查找（TLB）           ← 虚拟地址 → 物理地址
                ↓
         L1 Cache 查询            ← 物理地址作为 tag
                ├── 命中 ──→ 直接返回数据（~4 cycles）
                └── 未命中
                        ↓
                L2 Cache 查询
                        ├── 命中 ──→ 返回 + 填充 L1（~12 cycles）
                        └── 未命中
                                ↓
                        L3 Cache 查询
                                ├── 命中 ──→ 返回 + 填充 L2/L1（~40 cycles）
                                └── 未命中
                                        ↓
                                内存控制器（本地 DRAM）
                                        ↓
                                DRAM 返回 + 填充 Cache（~80 cycles）
```

### 2.2 读内存（远端 NUMA 节点）

```
应用代码:  mov eax, [0x7f3a2b1c000]    ← 虚拟地址（但物理地址在 Socket 1）
                ↓
         页表查找（TLB）
                ↓
         L1/L2/L3 全部未命中
                ↓
         内存控制器发现物理地址不在本地
                ↓
         通过 QPI/IF 发送请求到远端 Socket
                ↓
         远端内存控制器读取 DRAM
                ↓
         数据通过 QPI/IF 返回
                ↓
         填充本地 Cache（~150ns 总延迟）
```

### 2.3 远端写入（Store）

```
应用代码:  mov [0x7f3a2b1c000], edx  ← 虚拟地址
                ↓
         页表查找 → 发现是远端节点
                ↓
         CPU 执行 store 指令
         数据写入本地 store buffer
                ↓
         CPU Cache 控制器通过 QPI/IF 发送 RFO（Request For Ownership）
         远端节点收到 RFO，Invalidate 远端 Cache 行
                ↓
         数据通过 QPI 写入远端 DRAM
                ↓
         本地 store buffer 清空（后续 load 可以看到数据）
```

**NUMA 的关键：CPU 负责一致性协议（Cache Line 粒度），内存控制器负责数据存取。** 对应用来说，远端访问就是一条 `mov` 指令——完全透明。

---

## 3. GAM 的本质是什么

GAM 是一个**基于 RDMA 的分布式内存管理系统**，用软件在多台机器上模拟全局地址空间：

```
        节点 A                              节点 B
   ┌─────────────────┐               ┌─────────────────┐
   │   应用代码       │               │   应用代码       │
   │   GAlloc API    │               │   GAlloc API    │
   │        ↓        │               │        ↓        │
   │   Worker 线程    │    RDMA       │   Worker 线程    │
   │        ↓        │◄─────────────►│        ↓        │
   │   本地 Cache    │   InfiniBand   │   本地 Cache    │
   │        ↓        │               │        ↓        │
   │  Registered MR  │               │  Registered MR  │
   │        ↓        │               │        ↓        │
   │   Slab Alloc    │               │   Slab Alloc    │
   │        ↓        │               │        ↓        │
   │   本地 DRAM     │               │   本地 DRAM     │
   └─────────────────┘               └─────────────────┘
```

**GAM 的核心 API**：

```cpp
GAddr addr = alloc->Malloc(1024);        // 分配内存，返回 GAddr
alloc->Read(addr, &buf, sizeof(buf));    // 显式读取
alloc->Write(addr, &buf, sizeof(buf));   // 显式写入
```

**关键区别**：GAM 要求应用**显式**指定要访问哪个 `GAddr`，而不是用虚拟地址自动寻址。

---

## 4. 逐维度对比：GAM vs NUMA

| 维度                | NUMA                            | GAM                                                |
| ------------------- | ------------------------------- | -------------------------------------------------- |
| **物理基础**        | 多 Socket + QPI/IF              | 多机器 + InfiniBand/RoCE RDMA                      |
| **地址空间**        | 统一虚拟地址空间，应用无感知    | 显式 GAddr，应用必须知道数据在哪                   |
| **访问语法**        | `value = *ptr`（普通指针）      | `Read(addr, &value, sz)`（API 调用）               |
| **地址传播**        | OS 自动管理页表，无需应用感知   | **应用层手动传播**（Put/Get 或自定义）             |
| **缓存层**          | CPU L1/L2/L3（硬件管理）        | 本地 DRAM CacheLine（slab allocator 软件管理）     |
| **一致性**          | 硬件 MESI 协议，CPU 自动维护    | 软件目录协议，应用显式加锁                         |
| **数据迁移**        | OS 透明迁移页（NUMA balancing） | **静态分配，home 节点固定**                        |
| **Cache miss 处理** | 硬件自动触发 cache line fetch   | 软件显式触发 RDMA Read                             |
| **计算位置**        | 始终在本地 CPU                  | Read-Modify-Write：本地 CPU；GFUNC：可触发远程 CPU |
| **NUMA awareness**  | OS 自动亲和性调度               | 应用手动指定节点                                   |
| **延迟模型**        | 本地 ~80ns，远端 ~150ns         | 本地 ~0.5μs（cache hit），远端 ~1-2μs（RDMA RTT）  |

---

## 5. 核心区别

### 5.1 地址空间：透明 vs 显式

**NUMA（透明）**：

```c
// 所有节点共享同一个虚拟地址空间
void* ptr = malloc(1024);     // OS 自动选择节点分配
*ptr = 42;                    // CPU 自动处理远端访问
```

**NUMA 对应用的约束**：应用不需要感知 NUMA 拓扑。OS 可以透明地将数据迁移到被访问最多的节点。

**GAM（显式）**：

```cpp
// 应用必须显式使用 GAddr
GAddr addr = alloc->Malloc(1024);   // 分配在某节点
alloc->Put(0x1000, &addr, sizeof(GAddr));  // 必须告诉其他节点

// ... 其他节点需要 ...
alloc->Get(0x1000, &addr, sizeof(GAddr));  // 才能知道地址
alloc->Read(addr, &value, sizeof(value));
```

**GAM 的约束**：数据分布由应用控制，`Malloc` 后其他节点不知道地址，必须显式传播。

### 5.2 缓存层：硬件 vs 软件

**NUMA 的 CPU Cache**：

```
应用程序看到的：  value = *ptr;           ← 一条 CPU 指令
硬件实际做的：    L1 → L2 → L3 → DRAM    ← 硬件自动处理
                  ↑
            CPU Cache Agent 负责
```

**GAM 的本地 DRAM 缓存**：

```
应用程序看到的：  alloc->Read(addr, &buf, sz);
软件实际做的：    Cache hit? → memcpy(cline, buf)
                 Cache miss? → RDMA Read cline → memcpy(cline, buf)
                                      ↑
                              Worker 线程负责
```

**关键差异**：

- NUMA：Cache miss → 硬件自动从 DRAM 填充 Cache Line（~80ns）
- GAM：Cache miss → Worker 线程发起 RDMA Read → 数据到达后 memcpy 到用户 buf

GAM 比 NUMA **多一次软件 memcpy**（CacheLine → user buf），这是因为 GAM 的 Cache 是 slab allocator 分配的普通 DRAM，而不是 CPU Cache。

### 5.3 地址传播：自动 vs 手动

**NUMA（OS 自动管理）**：

```
malloc() 触发:
  1. OS 选择一个节点分配物理页
  2. 页表建立：虚拟地址 → (节点ID, 物理偏移)
  3. CPU TLB 缓存该映射

后续任何 CPU 访问该虚拟地址:
  1. MMU 查询页表，得到节点ID
  2. 如果是远端，通过 QPI/IF 访问
  3. 节点ID 对应用完全透明
```

**NUMA balancing** 可以动态迁移页，进一步降低远端访问比例。

**GAM（应用手动传播）**：

```
Malloc() 触发:
  1. 本地 slab allocator 分配一块内存
  2. GAddr = (WorkerID << 48) | offset
  3. 只有本节点知道这个 GAddr

其他节点要访问:
  1. 必须通过 Put(key, &addr) 告诉 Master
  2. 其他节点通过 Get(key, &addr) 获取
  3. 或者通过自定义通信（TCP、RPC、文件）
```

**对比**：

|                | NUMA             | GAM                |
| -------------- | ---------------- | ------------------ |
| 谁知道数据在哪 | OS（页表）       | 应用（显式传播）   |
| 传播机制       | 页表自动更新     | Put/Get 或自定义   |
| 传播时机       | 按需（页访问时） | 分配时（或需要时） |

### 5.4 计算位置：透明 vs 显式控制

**NUMA**：

```
所有计算都在本地 CPU 完成：
  value = *ptr;              ← 本地 CPU 执行
  value = value + 1;         ← 本地寄存器
  *ptr = value;              ← 本地 CPU 执行（可能触发 RFO）
```

**GAM（普通模式）**：

```
Read-Modify-Write 模式：
  alloc->Read(addr, &val, sz);   ← RDMA Read 数据到本地
  val = val + 1;                  ← 本地 CPU 计算
  alloc->Write(addr, &val, sz);   ← RDMA Write 数据回远端

GFUNC 模式（可选）：
  alloc->Write(addr, &val, sz, Incr, 1);  ← RDMA + 触发远程函数
                                      ↑
                              计算在远端 CPU 完成
```

### 5.5 数据迁移：动态 vs 静态

**NUMA（动态）**：

```bash
# Linux NUMA balancing 自动迁移页
echo 1 > /proc/sys/kernel/numa_balancing
```

OS 监控每个页的访问热度，自动将热页迁移到访问最多的节点。对应用完全透明。

**GAM（静态）**：

```
GAddr 的 home 节点 = 分配时的 WorkerID
home 节点一旦确定，永远不变：
  GAddr = (WorkerID << 48) | offset

如果某个节点持续访问大量远端数据:
  - NUMA: OS 可能迁移页，降低远端访问比例
  - GAM: 无透明迁移，只能应用层手动重分布
```

GAM 的静态特性使性能可预测（无隐式页迁移开销），但对于访问模式不均匀的工作负载，需要应用层显式优化数据分布。

---

## 6. GAM 放弃了什么

1. **地址透明性**：NUMA 的"任意 CPU 用任意地址"被放弃，改为显式 GAddr
2. **硬件一致性**：MESI 协议的 ~10ns 原子操作被替换为软件锁的 ~μs 级别
3. **动态迁移**：NUMA balancing 的自动页迁移被放弃，改为静态分配
4. **通用指针语义**：`*ptr` 自动远端访问被替换为 `Read/Write` API 调用

---

## 7. 基于 GAM 实现分布式 NUMA：需要做什么

以下是在 GAM 基础上逐步逼近分布式 NUMA 语义所需的改造，按依赖顺序排列。

### 7.1 第一层：透明地址解析

**目标**：让应用像 NUMA 一样用 `*ptr` 访问远端数据，而不是显式调用 `Read/Write`。

**需要什么**：

1. **全局虚拟地址空间**：将 GAddr 包装在透明指针类型中
2. **按需地址解析**：第一次解引用时，通过 Master 查询 GAddr
3. **本地指针缓存**：避免每次访问都查 Master

```cpp
// 目标语法：像 NUMA 一样透明访问
DistributedPtr<int> ptr;      // 声明一个"分布式指针"
ptr = alloc->MakePtr(key);    // 通过 key 获取（而不是显式 GAddr）
int x = *ptr;                 // 透明读取
*ptr = x + 1;                // 透明写入
```

### 7.2 第二层：消除多余的 memcpy

**问题在哪**：当前 GAM 的 Read 路径中，RDMA DMA 的目标是 `CacheLine buffer`，而不是用户 `buf`。数据到达 CacheLine 后，还需要一次 `memcpy(CacheLine → user_buf)` 才能被应用使用。去掉缓存层和用户空间之间多余的这次软件拷贝。

**NUMA 的工作方式（硬件透明）**：

```
CPU load 指令
    ↓
MMU 查找页表
    ↓
CPU Cache Agent 自动从远端 DRAM 读取 Cache Line → 直接进入 CPU 寄存器
    ↓
计算
```

**改造后的 GAM（应用层控制，保留一致性）**：

```
应用声明：将这块用户 buf 注册到 RDMA NIC
    ↓
首次访问：RDMA Read → user buf（DMA 直接到用户内存，无多余拷贝）
    ↓
数据已在用户 buf 中，可直接使用
    ↓
一致性协议仍在：当远端写入时，通过 invalidation 作废/更新本地 buf
```

**NUMA vs 改造 GAM 的根本区别**：

|                | NUMA（硬件透明）       | 改造 GAM（应用层控制）     |
| -------------- | ---------------------- | -------------------------- |
| 谁决定缓存什么 | CPU Cache Agent 自动   | 应用显式分配和注册         |
| 数据存储位置   | CPU Cache（L1/L2/LLC） | 用户已注册的 buf           |
| 访问触发者     | CPU 指令自动触发       | 显式 `Read()` API          |
| 一致性维护     | 硬件 MESI，自动        | 软件 Directory，应用层配合 |

改造需要：

1. 用户分配内存时，同时注册到 RDMA NIC（`ibv_reg_mr`），使 DMA 可以直接访问用户内存
2. CacheLine 的 `line` 指针指向用户 `buf` 而不是独立的 slab buffer（保留缓存一致性协议）
3. 一致性协议不变：远端写入时，通过 `NOTIFY → memcpy` 作废/更新用户 buf

### 7.3 第三层：页迁移机制

**目标**：像 NUMA balancing 一样，动态将热数据迁移到访问最多的节点。

**NUMA 的页迁移**：

```
OS 监控页访问热度
    ↓
发现节点 A 持续访问节点 B 的页
    ↓
OS 在节点 A 分配新页，复制数据
    ↓
更新页表：虚拟地址 → 节点 A
    ↓
Invalidate 旧副本
```

**GAM 的页迁移改造**：

```
统计模块监控 GAddr 的访问热度
    ↓
发现节点 A 持续访问节点 B 的某个 GAddr 区域
    ↓
在节点 A 的 slab allocator 分配新空间
    ↓
RDMA Read 复制数据到节点 A
    ↓
更新"地址路由表"（GAddr → 节点ID 的映射）
    ↓
其他节点通过 Get 更新本地缓存的 GAddr
```

**需要什么**：

1. **地址路由表**（替代固定 GAddr 编码）：`GAddr → home WorkerID` 的映射可动态更新
2. **GAddr 重编码**：不再用固定 WorkerID 位段，而是查表得到当前 home
3. **引用计数**：跟踪每个 GAddr 被多少节点缓存，迁移前需要作废所有缓存副本
4. **一致性协议增强**：迁移过程中需要锁保护，避免出现不一致状态

### 7.4 第四层：NUMA-aware 调度

**目标**：让计算线程靠近它访问的数据（类似 OS 的 NUMA 亲和性调度）。

**NUMA 的线程调度**：

```
OS 调度器感知 NUMA 拓扑
    ↓
线程绑定到某个 CPU Socket
    ↓
该 Socket 的本地内存优先分配给线程
    ↓
减少远端内存访问
```

**GAM 的线程调度改造**：

```
应用声明数据访问模式
    ↓
分析模块计算最优数据分布
    ↓
将线程调度到数据所在的节点
    ↓
Malloc 时优先在该节点分配
```

### 7.5 第五层：硬件级一致性

**目标**：用 RDMA 原子操作（CAS、FAA）替代软件锁，实现 NUMA 级别的原子操作性能。

**NUMA 的原子操作**：

```
lock inc [addr]    ← 单条 CPU 指令
    ↓
CPU Cache Agent 发送 Cache Line 请求
    ↓
MESI 协议确保原子性（~10ns）
```

**GAM 的原子操作（当前）**：

```
WLock() → Read() → 计算 → Write() → UnLock()   （~μs 级别）
```

**RDMA 原子操作支持**：

```c
// GAM 已支持 ibv_wr_atomic_cas（Compare-And-Swap）
// 改造后可实现真正的单边原子操作：
//   CAS(addr, old_val, new_val)   ← 单条 RDMA 原子操作，无需锁
```

### 7.6 改造路线图

```
当前 GAM                          分布式 NUMA
─────────────────────────────────────────────────────
显式 GAddr + Read/Write      ──→ 透明指针 *ptr 访问
                                   ↑
                              第一层：透明地址解析

CacheLine → buf memcpy        ──→ 直接 RDMA 到用户 buf
                                   ↑
                              第二层：消除多余拷贝

静态 GAddr（home 固定）        ──→ 动态 GAddr → 节点映射
                                   ↑
                              第三层：页迁移机制

应用层数据分布                ──→ NUMA-aware 自动调度
                                   ↑
                              第四层：亲和性调度

软件锁 (μs 级)               ──→ RDMA 原子操作 (ns 级)
                                   ↑
                              第五层：硬件一致性
```

---

## 附录：NUMA 术语对照

| NUMA 术语                   | GAM 对应                       | 说明                         |
| --------------------------- | ------------------------------ | ---------------------------- |
| Socket / Node               | Worker / 物理节点              | NUMA 拓扑中的一个节点        |
| Cache Line (64B)            | CacheLine (512B)               | 一致性协议的最小粒度         |
| MESI Protocol               | Directory Protocol             | 维护多节点间缓存一致性的协议 |
| Memory Controller           | Worker + Client                | 负责处理远端内存请求         |
| Page Table                  | GAddr encoding / Routing Table | 地址翻译                     |
| NUMA Balancing              | Page Migrator（需改造）        | 动态调整数据分布             |
| RFO (Request For Ownership) | Directory invalidation         | 获取独占访问权               |
| QPI / IF                    | InfiniBand / RoCE              | 节点间互联                   |
| Cache Hit                   | Cache Hit                      | 数据已在本地缓存             |
| Cache Miss                  | Cache Miss                     | 需要从远端获取               |