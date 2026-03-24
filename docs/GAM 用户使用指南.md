# GAM 用户使用指南

> v1.0
>
> 李福润
>
> 2026/3/24

## 1. 快速上手

以下是一个单节点的最小完整程序，演示分配、写、读、释放的全流程：

```cpp
#include "gallocator.h"
#include <iostream>

int main() {
    GAlloc* alloc = GAllocFactory::CreateAllocator();

    GAddr gaddr = alloc->Malloc(1024);

    int data = 42;
    alloc->Write(gaddr, &data, sizeof(int));

    int result;
    alloc->Read(gaddr, &result, sizeof(int));

    std::cout << "Result: " << result << std::endl;  // 输出 42

    alloc->Free(gaddr);
    delete alloc;
    return 0;
}
```

---

## 2. 配置与初始化

### 2.1 完整配置结构

`Conf`（定义于 `include/structure.h`）控制所有运行时参数：

```cpp
Conf conf;

// 节点角色（必填）
conf.is_master = false;                    // Master 节点设为 true，Worker 设为 false

// Master 地址
conf.master_ip   = "192.168.1.100";
conf.master_port = 12345;

// 本节点地址
conf.worker_ip   = "192.168.1.101";
conf.worker_port = 12346;

// 内存池大小（必填）
conf.size = 1024ULL * 1024 * 512;        // 本节点内存池大小（字节），默认 512MB

// 缓存阈值（默认 0.15）
// 当本地空闲内存低于 size * cache_th 时，开始从远端分配
conf.cache_th = 0.15;

// 日志
conf.loglevel = LOG_INFO;                // LOG_WARNING / LOG_DEBUG / LOG_FATAL

// 以下为高级参数，通常不需要修改
conf.backlog           = 511;             // TCP listen backlog
conf.timeout           = 10;             // 连接超时（毫秒）
conf.eviction_period   = 100;             // 缓存驱逐检查周期（毫秒）
conf.maxclients       = 1024;            // 最大客户端数
conf.maxthreads       = 10;               // 最大线程数
```

### 2.2 三种初始化方式

```cpp
// 方式一：从配置文件创建（推荐用于生产环境）
GAlloc* alloc = GAllocFactory::CreateAllocator("config.txt");

// 方式二：传入 Conf 结构体（推荐用于代码中配置）
GAlloc* alloc = GAllocFactory::CreateAllocator(&conf);

// 方式三：无参数（使用默认值，localhost + 默认配置）
GAlloc* alloc = GAllocFactory::CreateAllocator();
```

`CreateAllocator` 内部完成的操作：

```
TCP 连接到 Master
       ↓
TCP 交换 RDMA 连接参数（QPN, PSN, LID, rkey, vaddr）
       ↓
Worker 之间两两建立 RDMA QP（INIT → RTR → RTS）
       ↓
分配 slab allocator 内存池，注册到 RDMA NIC（ibv_reg_mr）
       ↓
启动 Worker 线程，开始监听 RDMA CQ 和 TCP socket
```

---

## 3. Flag 系统详解

`Flag`（`include/workrequest.h`）控制每次操作的行为，可以组合使用（位或 `|`）：

```c
//include/workrequest.h
#define REMOTE      (1 << 0)   // 强制在远端节点分配
#define RANDOM      (1 << 1)   // 随机选择一个节点分配
#define CACHED      (1 << 2)   // 经过本地缓存（默认）
#define ASYNC       (1 << 3)   // 异步模式（Write 默认）
#define NOT_CACHE   (1 << 13)  // 绕过本地缓存，直接操作远端内存
#define TRY_LOCK    (1 << 7)   // 非阻塞获取锁（用于 TryRLock/TryWLock）
#define LOCKED      (1 << 6)   // 内部使用：标记锁请求
```

### 3.1 常用 Flag 组合

```cpp
// 同步 Write（阻塞直到完成）
alloc->Write(addr, &data, sizeof(int), 0);

// 异步 Write（立即返回，写操作在后台 RDMA 完成）
alloc->Write(addr, &data, sizeof(int), ASYNC);

// 非缓存 Write（直接 RDMA 到远端内存，不经过本地缓存）
// 适合：只写一次、不需要后续读取的场景
alloc->Write(addr, &data, sizeof(int), ASYNC | NOT_CACHE);

// 带 GFUNC 的 Write（NOT_CACHE 是 GFUNC 的必要条件）
alloc->Write(addr, &data, sizeof(int), ASYNC | NOT_CACHE, IncrDouble, 1);
```

---

## 4. 内存分配 API

### 4.1 完整的 Malloc 系列

```cpp
// 基本分配（在本节点分配）
GAddr addr = alloc->Malloc(1024);

// 指定节点分配
GAddr addr = alloc->Malloc(1024, REMOTE);    // 在远端随机一个节点分配
GAddr addr = alloc->Malloc(1024, RANDOM);    // 同上，随机选节点

// 亲和性分配（优先在与 base_hint 同一节点上分配）
GAddr addr = alloc->Malloc(1024, base_hint);

// 对齐分配（512 字节边界，用于 CacheLine 对齐的数据结构）
GAddr addr = alloc->AlignedMalloc(4096);
GAddr addr = alloc->AlignedMalloc(4096, base_hint);

// Calloc（分配并清零）
GAddr addr = alloc->Calloc(nmemb, size, 0, 0);

// Realloc（重新分配）
GAddr new_addr = alloc->Realloc(old_addr, new_size, 0);

// 释放
alloc->Free(addr);
```

### 4.2 REMOTE vs RANDOM 的区别

两者都分配在远端节点，但语义不同：

```cpp
// REMOTE：通常指远端"home"节点（数据归属的节点）
// 用于：期望数据最终存储在远端，不在本地缓存
GAddr remote_data = alloc->Malloc(1024, REMOTE);

// RANDOM：随机选择任意一个远端节点
// 用于：数据分布无关紧要，只是不想占用本节点内存
GAddr random_data = alloc->Malloc(1024, RANDOM);
```

---

## 5. 模式一：基本的读-改-写（两跳）

```
节点 A                              节点 B（home）
   │                                     │
   │ ─────── RDMA Read ────────────────> │ 远端 DRAM → 本地 buf
   │                                     │
   │ [本地 CPU: value = value + 1]        │
   │                                     │
   │ ─────── RDMA Write ────────────────> │ 本地 buf → 远端 DRAM
int local_val;

// ① 同步读 — 阻塞直到 RDMA 完成
alloc->Read(target_addr, &local_val, sizeof(int));

// ② 本地计算（CPU 寄存器）
local_val = local_val + 1;

// ③ 异步写 — 立即返回（默认 ASYNC）
alloc->Write(target_addr, &local_val, sizeof(int));

// ④（可选）等待写入完成
alloc->MFence();
```

**为什么需要两步？** RDMA Read 和 Write 本身都不包含计算能力，必须将数据带回本地 CPU 计算，再送回去。要一跳完成计算，用 GFUNC。

---

## 6. 模式二：GFUNC 原子操作（一跳）

对于 `counter++` 这类简单原子操作，GFUNC 将 2 次往返减少到 1 次：

```
节点 A                              节点 B（home）
   │                                     │
   │ ─ RDMA SEND with Imm ────────────> │
   │   (携带: 函数ID + 参数)              │
   │                                     │ 远端 CPU 执行: *(ptr) += arg
   │ <────────────── ACK ───────────────│
```

### 6.1 预置 GFUNC

```c
//src/gfunc.cc
void Incr(char* ptr, uint64_t arg)     { (*ptr) += (char)arg; }
void IncrInt(int* ptr, uint64_t arg)    { (*ptr) += (int)arg; }
void IncrDouble(double* ptr, uint64_t arg) { (*ptr) += *(double*)&arg; }
```

### 6.2 使用方式

```cpp
#include "gallocator.h"
#include "gfunc.h"

double inc = 1.0;
uint64_t incl = force_cast<uint64_t>(inc);

// 一跳完成加法，无需本地变量，无竞态
alloc->Write(target_addr, &local_val, sizeof(int), IncrDouble, incl);
```

### 6.3 自定义 GFUNC

1. 在 `src/gfunc.cc` 的 `GAllocFactory::gfuncs[]` 中添加函数指针
2. 重新编译 `libgalloc.a`

```c
// src/gfunc.cc
void MyAtomicOr(void* ptr, uint64_t arg) {
    (*(uint32_t*)ptr) |= (uint32_t)arg;
}
// 注册到 gfuncs[] 数组
```

### 6.4 GFUNC 约束

1. **只能操作一个 CacheLine 内的数据**（512 字节，不跨块边界）
2. **函数必须无副作用**：只能访问传入的 `addr`
3. **必须预注册**：不支持运行时动态注册
4. **必须在 home 节点执行**：不能操作非 home 节点的数据

### 6.5 方案对比

| 方案                | 网络往返 | 原子性         | 复杂度         |
| ------------------- | -------- | -------------- | -------------- |
| Read → 计算 → Write | 2        | 无（需额外锁） | 简单           |
| GFUNC               | 1        | 远端原子执行   | 需要预注册函数 |

---

## 7. 模式三：带锁的事务性更新

### 7.1 阻塞锁 vs 非阻塞锁

```cpp
// 阻塞获取写锁（会等待，直到拿到锁）
alloc->WLock(addr, sizeof(int));
// ... 临界区 ...
alloc->UnLock(addr, sizeof(int));

// 非阻塞获取写锁（返回 0 表示成功）
if (alloc->Try_WLock(addr, sizeof(int)) != 0) {
    std::this_thread::yield();  // 自旋等待
}
// ... 临界区 ...
alloc->UnLock(addr, sizeof(int));
```

### 7.2 读锁 vs 写锁

```cpp
// 读锁（共享锁）：允许多个节点同时持有读锁，但阻塞所有写锁
alloc->RLock(addr, sizeof(int));
// ... 只读操作 ...
alloc->UnLock(addr, sizeof(int));

// 写锁（排他锁）：只有一个节点可以持有，阻塞其他所有锁
alloc->WLock(addr, sizeof(int));
// ... 读写操作 ...
alloc->UnLock(addr, sizeof(int));
```

### 7.3 锁的粒度

锁的粒度是 **512 字节（BLOCK_SIZE）**，与 CacheLine 对齐。如果需要保护一个跨多个块的数据结构，需要对每个块分别加锁：

```cpp
// 保护跨 3 个 CacheLine 的结构
alloc->WLock(addr + 0,   BLOCK_SIZE);
alloc->WLock(addr + 512, BLOCK_SIZE);
alloc->WLock(addr + 1024, BLOCK_SIZE);
// ... 操作 ...
alloc->UnLock(addr + 0,   BLOCK_SIZE);
alloc->UnLock(addr + 512, BLOCK_SIZE);
alloc->UnLock(addr + 1024, BLOCK_SIZE);
```

**注意**：GAM 的锁是**分布式锁**——它通过网络消息协调，延迟远高于本地 pthread 锁。只用于协调跨节点的数据访问，不要用它替代本地锁。

---

## 8. GPtr 模板指针

`GPtr<T>`（`include/gptr.h`）重载了 `*`、`[]`、`+` 运算符，使远端数据访问接近普通指针语法：

### 8.1 基本用法

```cpp
GPtr<int> ptr(remote_addr, alloc);

int val = *ptr;           // 底层: alloc->Read()
*ptr = val + 1;          // 底层: alloc->Write()
```

### 8.2 数组访问

```cpp
// GPtr 支持数组下标操作
GPtr<double> vec(base_addr, alloc);

double first = vec[0];    // Read(base + 0, &first, sizeof(double))
double third = vec[3];    // Read(base + 3*sizeof(double), &third, sizeof(double))

vec[5] = 42.0;           // Write(base + 5*sizeof(double), &val, sizeof(double))
```

### 8.3 指针运算

```cpp
// 支持 + 偏移
GPtr<int> p1 = ptr + 10;     // addr + 10 * sizeof(T)
int val = *p1;
```

### 8.4 重要限制

```cpp
// 注意：GPtr 重载的 operator* 和 operator= 底层仍然是
// 两次独立的 RDMA 操作，不保证原子性！
// 两个节点的以下操作仍会竞态：
GPtr<int> p(shared_addr, alloc);
(*p)++;      // = Read + Write，仍是两跳，不是原子

// 要保证原子性，必须用 GFUNC 或显式加锁
```

---

## 9. Async 模式与 MFence

### 9.1 Write 的 Async 默认行为

`Write` 默认是 **ASYNC**（非阻塞）——调用立即返回，写操作在 Worker 线程中异步完成：

```cpp
// 默认：ASYNC，立即返回
alloc->Write(addr, &data, sizeof(int));
// 此时数据可能尚未到达远端！

// 同步 Write（显式加 ASYNC flag 是多余的，因为默认就是 ASYNC）
alloc->Write(addr, &data, sizeof(int), ASYNC);
```

### 9.2 MFence：等待所有写操作完成

`MFence` 等待**所有之前的 Write** 都已通过 RDMA 发送出去（不一定已到达远端 DRAM）：

```cpp
// 发送一系列写
alloc->Write(addr1, &val1, sizeof(int));
alloc->Write(addr2, &val2, sizeof(int));
alloc->Write(addr3, &val3, sizeof(int));

// MFence 等待所有写完成
alloc->MFence();    // 阻塞，直到所有 pending writes 处理完毕

// 之后的 Read 能看到之前所有 Write 的结果
```

### 9.3 WLock 隐含 MFence

```cpp
alloc->WLock(addr, sizeof(int));
// 等价于:
//   1. MFence() — 等待所有 pending writes 完成
//   2. 获取排他锁

alloc->UnLock(addr, sizeof(int));
// 等价于:
//   1. 释放排他锁
//   2. MFence() — 保证所有写操作到达远端
```

---

## 10. GAddr 地址传播

`Malloc` 是纯本地操作——分配后其他节点不知道这个地址。

### 10.1 Put/Get

```cpp
// ===== 节点 A：分配 + 存储地址到 Master =====
GAddr addr = alloc->Malloc(sizeof(int));
alloc->Write(addr, &data, sizeof(int));
alloc->Put(0x1000, &addr, sizeof(GAddr));

// ===== 节点 B：从 Master 获取地址 =====
GAddr addr;
alloc->Get(0x1000, &addr, sizeof(GAddr));
alloc->Read(addr, &data, sizeof(int));
```

### 10.2 固定偏移约定

当数据布局是事先确定的时候，不需要动态传播：

```cpp
// 所有节点都知道：节点 i 的数据在 base + i * elem_size
GAddr base = alloc->Malloc(total_size);  // Master 分配
// Master 通过命令行参数或配置文件告知各节点 base 值
// 无需 Put/Get
```

---

## 11. 常见任务参考

### 11.1 广播

```cpp
// Master 分配广播数据
GAddr bcast = alloc->Malloc(sizeof(int));
alloc->Write(bcast, &val, sizeof(int));
alloc->Put(BROADCAST_KEY, &bcast, sizeof(GAddr));

// Worker 获取并读取
GAddr bcast;
alloc->Get(BROADCAST_KEY, &bcast, sizeof(GAddr));
alloc->Read(bcast, &val, sizeof(int));
```

### 11.2 全局聚合

```cpp
// 每个节点写自己的 slot
GAddr my_slot = base + my_id * elem_size;
alloc->Write(my_slot, &my_data, sizeof(int));

// Master 聚合
for (int i = 0; i < n; i++) {
    alloc->Read(base + i * elem_size, &data, sizeof(int));
    total += data;
}
```

---

## 12. 每一步操作的拷贝层级

### 12.1 Read（Cache Miss）

```
远端 DRAM ──DMA──> 远端 Registered MR
                         │
                         │ RDMA 网络
                         ▼
              本地 Registered MR ──DMA──> 本地 CacheLine
                                                 │
                                                 │ memcpy（GAM 软件层）
                                                 ▼
                                             用户 buf
```

- **3 次 DMA**（网卡硬件）：两端 Registered MR 各一次，网络一次
- **1 次 memcpy**（软件）：CacheLine → user buf

### 12.2 Read（Cache Hit）

```
本地 CacheLine ──memcpy──> 用户 buf     
```

### 12.3 Write（Cache Hit, DIRTY）

```
用户 buf ──memcpy──> 本地 CacheLine    
```

---

## 13. 判断与调试

### 13.1 判断地址是否在本地

```cpp
// 快速判断，避免不必要的网络操作
if (alloc->IsLocal(addr)) {
    // 直接本地访问（跳过 RDMA 开销）
    void* local_ptr = alloc->GetLocal(addr);
    memcpy(buf, local_ptr, count);
} else {
    // 走 RDMA 路径
    alloc->Read(addr, buf, count);
}
```

### 13.2 缓存命中率统计

```cpp
// 打印缓存命中率、驱逐次数等统计
alloc->ReportCacheStatistics();
```

典型输出：

```
Cache hits:     12345
Cache misses:   234
Hit rate:       98.1%
Evictions:      12
Dirty writebacks: 5
```

### 13.3 常用日志级别

```cpp
conf.loglevel = LOG_FATAL;  // 仅致命错误
conf.loglevel = LOG_WARNING; // 警告 + 错误（生产推荐）
conf.loglevel = LOG_INFO;   // INFO + WARNING + ERROR
conf.loglevel = LOG_DEBUG;  // 全部日志（调试时使用）
```

### 13.4 RDMA 连接状态检查

```bash
# 查看 RDMA 设备
ibv_devices

# 查看活跃 QP
ibv_rc_pingpong <local_ip> <remote_ip>
```

---

## 14. API 快速索引

### 内存管理

| 操作                                          | 说明             |
| --------------------------------------------- | ---------------- |
| `GAllocFactory::CreateAllocator(&conf)`       | 创建分配器       |
| `GAddr Malloc(Size size, Flag flag=0)`        | 分配全局内存     |
| `GAddr Malloc(Size size, GAddr base_hint)`    | 亲和性分配       |
| `GAddr AlignedMalloc(Size size, Flag flag=0)` | 对齐分配（512B） |
| `GAddr Calloc(Size nmemb, Size size, ...)`    | 分配并清零       |
| `GAddr Realloc(GAddr ptr, Size size, ...)`    | 重新分配         |
| `void Free(GAddr addr)`                       | 释放内存         |

### 数据传输

| 操作                      | 说明                    | 远端 CPU |
| ------------------------- | ----------------------- | -------- |
| `Read(addr, buf, count)`  | 同步 RDMA READ          | ❌        |
| `Write(addr, buf, count)` | 异步 RDMA WRITE         | ❌        |
| `Write(..., GFunc*, arg)` | RDMA + 触发远程函数     | ✅        |
| `MFence()`                | 等待所有 pending writes | —        |

### 同步原语

| 操作                     | 说明                          |
| ------------------------ | ----------------------------- |
| `WLock(addr, count)`     | 阻塞获取写锁                  |
| `Try_WLock(addr, count)` | 非阻塞获取写锁（返回 0=成功） |
| `RLock(addr, count)`     | 获取读锁（共享）              |
| `UnLock(addr, count)`    | 释放锁（ASYNC_UNLOCK 时异步） |

### 键值存储

| 操作                   | 说明           |
| ---------------------- | -------------- |
| `Put(key, val, count)` | 存储到 Master  |
| `Get(key, val)`        | 从 Master 获取 |

### 判断

| 操作                      | 说明                 |
| ------------------------- | -------------------- |
| `IsLocal(addr)`           | 判断地址是否在本节点 |
| `GetLocal(addr)`          | 转换为本地 void*     |
| `ReportCacheStatistics()` | 打印缓存命中率       |

### Flag 常量

| Flag        | 值        | 用途               |
| ----------- | --------- | ------------------ |
| `ASYNC`     | `1 << 3`  | 异步（Write 默认） |
| `NOT_CACHE` | `1 << 13` | 绕过本地缓存       |
| `REMOTE`    | `1 << 0`  | 在远端分配         |
| `RANDOM`    | `1 << 1`  | 随机节点分配       |
| `TRY_LOCK`  | `1 << 7`  | 非阻塞获取锁       |