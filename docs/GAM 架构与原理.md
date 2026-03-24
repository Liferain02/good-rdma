# GAM 架构与原理

> v1.0
>
> 李福润
>
> 2026/3/24

---

## 1. 架构总览

GAM（Global Addressable Memory）是一个构建在 libibverbs 之上的用户态分布式内存管理系统。它不依赖操作系统内核，通过 RDMA 单边操作在多台机器间提供统一的全局地址空间。

```
┌──────────────────────────────────────────────────────────────────────┐
│                          应用层                                        │
│                  GAlloc API（用户调用）                               │
└────────────────────────┬─────────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    GAlloc 类（gallocator.cc）                         │
│         Read / Write / Malloc / Lock / MFence / Put / Get            │
└────────────────────────┬─────────────────────────────────────────────┘
                         │ WorkRequest 压入无锁队列
                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│               WorkerHandle（worker_handle.h）                          │
│              桥接应用线程与 Worker 事件循环                            │
└────────────────────────┬─────────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    Worker 线程（worker.cc）                            │
│              aeEventLoop 事件循环，epoll/kqueue 驱动                  │
│                                                                           │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │
│   │  Local Req   │  │ Remote Req   │  │ Rdma Req    │                │
│   │  Processor   │  │  Processor   │  │  Processor   │                │
│   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘                │
│          │                 │                  │                        │
│          ▼                 ▼                  ▼                        │
│   ┌──────────────────────────────────────────────────────────┐        │
│   │         Cache（本地 DRAM 缓存，slab allocator 管理）       │        │
│   └──────────────────────────────────────────────────────────┘        │
│          │                 │                  │                        │
│          ▼                 ▼                  ▼                        │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │
│   │  Directory   │  │   Client    │  │   Server     │                │
│   │  (每节点)    │  │ (发送 RDMA) │  │ (接收 RDMA) │                │
│   └──────────────┘  └──────┬───────┘  └──────┬───────┘               │
└────────────────────────────┼────────────────┼────────────────────────┘
                             │                │
                             ▼                ▼
                     ┌────────────────────────────┐
                     │    InfiniBand / RoCE NIC   │
                     │   (ibv_post_send / recv)   │
                     └────────────────────────────┘
                             │                │
                             └──────┬─────────┘
                                    │
                                    ▼
                           RDMA 网络（QP 互联）
```

**与 NUMA 的层次对应**：

| 单机 NUMA         | GAM                         |
| ----------------- | --------------------------- |
| CPU Core          | 应用线程                    |
| L1/L2/L3 Cache    | 本地 DRAM 缓存（CacheLine） |
| Cache Agent       | Worker 线程                 |
| QPI / IF 互联     | InfiniBand RDMA 网络        |
| Memory Controller | Worker + Directory          |
| Socket DRAM       | 节点本地 DRAM               |

---

## 2. 核心概念速查

### 2.1 GAddr — 全局虚拟地址

```c
//include/structure.h
// GAddr 高 16 位为 Worker ID，低 48 位为节点内偏移
#define WID(gaddr)  ((gaddr) >> 48)
#define OFF(gaddr)  ((gaddr) & 0xFFFFFFFFFFFF)
```

### 2.2 GAlloc — 用户 API

```c
GAddr  Malloc(Size size, Flag flag = 0);
void   Free(GAddr addr);
int    Read(GAddr addr, void* buf, Size count);
int    Write(GAddr addr, void* buf, Size count);
void   MFence();
void   SFence();
void   RLock(GAddr, Size);
void   WLock(GAddr, Size);
void   UnLock(GAddr, Size);
Size   Put(uint64_t key, void* val, Size count);
Size   Get(uint64_t key, void* val);
```

### 2.3 关键内部组件

| 组件          | 文件              | 职责                                             |
| ------------- | ----------------- | ------------------------------------------------ |
| `Worker`      | `worker.h/.cc`    | aeEventLoop 事件循环，RDMA 请求分发              |
| `Cache`       | `cache.h/.cc`     | 本地 DRAM 缓存，CacheLine 分配/驱逐/状态机       |
| `Directory`   | `directory.h/.cc` | 分布式目录协议，home 节点的状态管理              |
| `RdmaContext` | `rdma.h/.cc`      | 单一 QP 的 RDMA 连接封装（Read/Write/Send/Recv） |
| `Client`      | `client.h/.cc`    | 向远端 Worker 发送 RDMA 请求                     |
| `Server`      | `server.h/.cc`    | 接收并处理远端 RDMA SEND 请求                    |
| `Master`      | `master.h/.cc`    | 协调节点，TCP 握手、key-value 存储               |
| `Slabs`       | `slabs.h/.cc`     | slab 分配器，管理本地内存池                      |
| `Fence`       | `fence.h`         | MFence/SFence 的 Per-thread 同步状态             |

---

## 3. 连接建立：从 CreateAllocator 到 RDMA QP 就绪

整个建立过程由 `GAllocFactory::CreateAllocator()` 触发，`Worker::PostConnectMaster()` 和 `Client::ExchConnParam()` 配合完成。

### 3.1 建立时序

```
应用线程                         Master                      Worker 0..N
   │                              │                              │
   │  CreateAllocator(&conf)      │                              │
   │  ──────────────────────────► │                              │
   │                              │                              │
   │  ① TCP connect(master_ip)   │                              │
   │  ───────────────────────────┼────────────────────────────► │
   │                              │                              │
   │                              │  ② 收集所有 Worker 的连接字符串  │
   │                              │  ③ 广播完整 worker 列表       │
   │  ◄───────────────────────────┼───────────────────────────── │
   │                              │                              │
   │  ④ TCP connect(worker_i)    │                              │
   │  ────────────────────────────────────────────────────────► │
   │                              │                              │
   │  ⑤ 交换 RDMA 连接参数（QPN, PSN, LID, rkey, vaddr）      │
   │  ◄────────────────────────────────────────────────────────► │
   │                              │                              │
   │  ⑥ QP 状态机: INIT → RTR → RTS（双方同时执行）           │
   │  ────────────────────────────────────────────────────────► │
   │                              │                              │
   │  Worker 线程启动，监听 CQ fd 和 TCP fd                      │
   │  ────────────────────────────────────────────────────────► │
```

### 3.2 连接字符串格式

Worker 与 Worker 之间交换的信息（TCP 发送）：

```
格式: "wid:lid:qpn:psn:rkey:vaddr"
示例: "0001:0032:00001234:00abcdef:0000abcd:7f0000010000"
```

| 字段    | 说明                                    |
| ------- | --------------------------------------- |
| `wid`   | Worker ID（高 16 位地址的标识）         |
| `lid`   | RDMA 本地 ID（交换机端口）              |
| `qpn`   | Queue Pair Number（QP 编号）            |
| `psn`   | Packet Sequence Number（包序号）        |
| `rkey`  | Remote Key（远端内存访问权限）          |
| `vaddr` | 本节点注册的内存基址（virtual address） |

`rkey` + `vaddr` 是 RDMA 操作远端内存的关键——没有这两个值，就无法 post RDMA Read/Write。

### 3.3 QP 状态机

```c
//src/rdma.cc — SetRemoteConnParam()
QP INIT ──(ibv_modify_qp: RTR)──► QP RTR ──(ibv_modify_qp: RTS)──► QP RTS
         设置:
         • dest_qp = 对端 QPN
         • ah.dlid = 对端 LID
         • max_rd_atomic = 1
                                       设置:
                                       • timeout
                                       • retry_cnt
                                       • sq_psn = 本端 PSN
```

---

## 4. Worker 事件循环

Worker 是整个系统的中枢——它同时监听三个事件源：RDMA Completion Queue（RDMA 操作完成）、TCP socket（来自 Master 的消息）、本地请求队列。

### 4.1 aeEventLoop 事件驱动

GAM 使用了来自 Redis 的 `aeEventLoop`（`ae_*.cc`），通过 `epoll`/`kqueue`/`select` 监听多个文件描述符：

```c
//src/worker.cc — Worker::Start()
aeEventLoop* el = aeCreateEventLoop();
resource->GetChannelFd()  → 注册到 epoll →  RDMA CQ 事件（读完成）
master->GetSocketFd()     → 注册到 epoll →  Master TCP 消息
pipe_fd[0]               → 注册到 epoll →  本地请求通知
```

### 4.2 主循环

```c
//src/worker.cc — Worker::StartService()
while (!stop_) {
    aeProcessEvents(el, AE_BEFORE_SLEEP);

    // 1. 轮询 RDMA CQ（ibv_poll_cq）
    int ne = ibv_poll_cq(cq, MAX_CQ_EVENTS, wc);
    for each wc in completed_wcs:
        if (wc.status == IBV_WC_SUCCESS) {
            if (wc.opcode == IBV_WC_RDMA_READ ||
                wc.opcode == IBV_WC_RDMA_WRITE) {
                Server::ProcessRdmaRequest(wc);   // 处理 RDMA 完成通知
            }
        }

    // 2. 处理本地请求队列中的待处理请求
    while (to_serve_local_requests 非空)
        ProcessLocalRequest(request);
}
```

### 4.3 三类处理函数

| 函数                       | 处理什么                        | 谁触发                    |
| -------------------------- | ------------------------------- | ------------------------- |
| `ProcessLocalRequest(wr)`  | 本地发起的 Read/Write/Lock 等   | 应用线程通过无锁队列      |
| `ProcessRdmaRequest(wc)`   | 远端发来的 RDMA SEND/RECV       | 网卡 CQ 完成事件          |
| `ProcessRemoteRequest(wr)` | 远端发来的 WorkRequest 反序列化 | `ProcessRdmaRequest` 调用 |

---

## 5. 三层缓存架构

### 5.1 缓存行大小与结构

GAM 以 **512 字节**（`BLOCK_SIZE = 1 << 9`）为粒度管理缓存。

```c
//include/cache.h
struct CacheLine {
  void* line;                           // 512 字节数据缓冲区（从 Slab 分配）
  GAddr addr;                           // 块对齐的 GAddr
  CacheState state;                     // INVALID / SHARED / DIRTY / TO_*
  unordered_map<GAddr, int> locks;      // 子地址粒度的读写锁计数
  CacheLine* prev;                      // LRU 链表指针
  CacheLine* next;
};
```

### 5.2 缓存状态机

根据 `include/cache.h` 枚举和 `src/cache.cc` 中所有 `ToTo*`/`To*` 调用整理：

```
初始状态：INVALID（不在缓存中）

┌──────────────────────────────────────────────────────────────────────┐
│  INVALID                                                           │
│                                                                      │
│  ① 本地 Read miss  ──────────────────────────────────────────────► │
│                                                                      │
│  ② 本地 Write miss ──────────────────────────────────────────────► │
└──────────────────────────────────────────────────────────────────────┘
          │                                    │
          │  TO_SHARED                         │  TO_DIRTY
          │  (RDMA Read 进行中)               │  (Directory invalidation 进行中)
          ▼                                    ▼
┌────────────────────┐              ┌────────────────────────────────┐
│ TO_SHARED         │              │ TO_DIRTY                        │
│                    │              │                                 │
│ RDMA Read 完成后：  │              │ Directory Invalidation 完成后：  │
│ memcpy → SHARED    │              │ memcpy → DIRTY                  │
└────────────────────┘              └────────────────────────────────┘
          │                                    │
          ▼                                    ▼
┌────────────────────┐              ┌────────────────────────────────┐
│ SHARED（只读）      │              │ DIRTY（本地已修改）             │
│                    │              │                                 │
│ ③ 本地 Write ──────┼────────────► │                                 │
│ ④ 驱逐 ────────────┼──────────►  │ ⑤ 驱逐（写回）─────► TO_INVALID │
└────────────────────┘              └────────────────────────────────┘
                                           ▲
                                           │
                              ┌────────────────────────────────────┐
                              │ DIRTY 时：                         │
                              │ ⑥ 远程 Read miss 触发转发 ──► TO_SHARED │
                              │    (需要先写回 home，再转发数据)      │
                              └────────────────────────────────────┘

所有过渡态（TO_*）期间：
  - 块被锁保护（防止驱逐）
  - 并发访问同一块的其他请求被加入 to_serve 等待队列
  - RDMA 完成后再按序处理等待队列
```

**各状态含义**：

| 状态         | 含义                                                         |
| ------------ | ------------------------------------------------------------ |
| `INVALID`    | 块不在本地缓存                                               |
| `SHARED`     | 本地持有只读副本，远程可能有多个共享者                       |
| `DIRTY`      | 本地持有修改过的副本，必须写回后才能被其他节点访问           |
| `TO_SHARED`  | 正在从远程获取数据（RDMA Read pending）                      |
| `TO_DIRTY`   | 正在升级到 DIRTY（向目录请求写权限，等待 invalidation 完成） |
| `TO_INVALID` | 正在驱逐（DIRTY 时需要先 RDMA Write Back）                   |

**状态转换的驱动者**：

| 转换                 | 触发时机                     | 代码位置                      |
| -------------------- | ---------------------------- | ----------------------------- |
| INVALID → TO_SHARED  | `Cache::ToToShared()`        | `src/cache.cc`                |
| INVALID → TO_DIRTY   | `Cache::ToToDirty()`         | `src/cache.cc`                |
| TO_SHARED → SHARED   | RDMA Read 完成               | `src/cache.cc`                |
| TO_DIRTY → DIRTY     | Directory Invalidation 完成  | `src/cache.cc`                |
| SHARED → TO_DIRTY    | 本地 Write 升级权限          | `src/cache.cc`                |
| DIRTY → TO_SHARED    | 远程 Read miss，需要转发数据 | `src/remote_request_cache.cc` |
| DIRTY → TO_INVALID   | 驱逐 dirty 行                | `src/cache.cc`                |
| TO_INVALID → INVALID | Write Back 完成或直接失效    | `src/cache.cc`                |

### 5.3 缓存查找流程

```c
//src/cache.cc — Cache::ReadWrite()

输入: 请求 addr + count, 用户 buf
遍历请求覆盖的每个 BLOCK_SIZE 块：

  CASE 1: Cache Hit（SHARED 或 DIRTY）
    直接 memcpy(cache_line, user_buf)
    无 RDMA 开销，零网络往返

  CASE 2: Cache Miss（INVALID）
    1. SetCLine(i)：分配 CacheLine（从 Slab）
    2. ToToShared(cline)：状态置 TO_SHARED
    3. 发起 RDMA Read，目标为 CacheLine buffer
    4. 等待 RDMA 完成
    5. memcpy(cache_line, user_buf)
    总共 1 次网络往返

  CASE 3: 过渡态（TO_SHARED / TO_DIRTY）
    请求加入 to_serve 等待队列
    RDMA 完成后再重试
```

**关键设计点**：RDMA Read 的目标是 `CacheLine`（slab buffer），而不是用户 `buf`。每次 cache miss 都产生两次 memcpy（远端内存→CacheLine→user buf）。

### 5.4 缓存驱逐策略

当缓存占用超过 `cache_th = 0.15 * conf.size` 阈值时，`Cache::Evict(n)` 触发驱逐：

1. 从 10 个 LRU 桶中随机选择起始位置扫描
2. 跳过有锁或处于过渡态的行
3. DIRTY 状态：发起 RDMA Write Back → 状态置 TO_INVALID → 写回完成 → INVALID
4. SHARED 状态：直接置为 INVALID（无需写回）
5. 释放 slab 内存

---

## 6. 目录式缓存一致性协议

每个节点（作为 home 角色时）维护一个 Directory，记录该节点所拥有数据的块状态。

### 6.1 目录条目结构

```c
//include/directory.h
struct DirEntry {
  DirState state;                           // UNSHARED / SHARED / DIRTY / TO_*
  list<GAddr> shared;                       // 持有 SHARED 副本的节点列表（用 GAddr 表示 Client）
  ptr_t addr;                               // home 节点内存中的物理地址
  unordered_map<ptr_t, int> locks;          // 各节点持有的锁计数
};
```

### 6.2 目录状态机

根据 `src/directory.cc` 整理，6 个状态、正确的转换路径：

```
┌──────────────────────────────────────────────────────────────────────────┐
│ DIR_UNSHARED                                                           │
│                                                                        │
│  ① Read miss ───────────────────────────────────────────────────────► │
│                                                                        │
│  ② Write miss ──────────────────────────────────────────────────────► │
└──────────────────────────────────────────────────────────────────────────┘
            │                                         │
            │ DIR_SHARED                             │ DIR_TO_DIRTY
            │ (多个共享者)                           │ (正在失效其他共享者)
            ▼                                         ▼
┌───────────────────────────────┐    DIR_DIRTY ◄──────────────────────────┘
│ DIR_SHARED                    │    (独占修改权)
│                               │
│ ③ Write miss + Invalidate ───┼──► DIR_TO_DIRTY ──► DIR_DIRTY
│     (失效所有共享者)           │
│                               │    ④ Read miss（远程）时：
│ ⑤ 驱逐最后一个共享者 ─────────┼──► UNSHARED（直接删除条目）
└───────────────────────────────┘
                                                   │
                    ┌──────────────────────────────┘
                    │
                    │ DIRTY 时：
                    │ ⑥ Read miss ──► DIR_TO_SHARED ──► DIR_SHARED
                    │    (转发到持有 DIRTY 副本的节点，写回 home 后再共享)
                    │
                    │ ⑦ 驱逐 DIRTY ──► DIR_TO_UNSHARED ──► DIR_UNSHARED
                    │    (Write Back 后变为独占但未修改)
```

**状态语义**：

| 状态          | 语义                                              |
| ------------- | ------------------------------------------------- |
| `UNSHARED`    | home 节点持有唯一有效副本，无共享者               |
| `SHARED`      | 多个节点持有只读副本                              |
| `DIRTY`       | 某个节点持有修改过的副本（尚未写回 home）         |
| `TO_DIRTY`    | 正在失效所有 SHARED 共享者（写请求正在处理中）    |
| `TO_SHARED`   | DIRTY 块被转发给请求者，home 等待 Write Back 完成 |
| `TO_UNSHARED` | DIRTY 块正在 Write Back，写回完成后回到 UNSHARED  |

### 6.3 home 角色与目录查找

**home 节点的确定**：GAddr 的高 16 位 Worker ID 决定 home 节点，一旦分配永不改变。

**目录查找是 RDMA SEND 操作**：

```c
// 节点 A 访问节点 B 的数据（GAddr 的 home = B）
节点 A ── RDMA SEND (控制消息) ──► 节点 B
                                  节点 B Worker:
                                    1. directory.lock(addr)
                                    2. 查 DirEntry → 决定操作类型
                                    3. 若需数据：RDMA WRITE WITH_IMM 回 A
                                    4. directory.unlock(addr)
```

---

## 7. RDMA 操作路径

### 7.1 操作类型总览

GAM 直接封装 libibverbs（`ibv_post_send` 系列）：

| 操作       | 函数                          | RDMA 类型                  | 远端 CPU       |
| ---------- | ----------------------------- | -------------------------- | -------------- |
| 读         | `RdmaContext::Read()`         | IBV_WR_RDMA_READ           | ❌              |
| 写         | `RdmaContext::Write()`        | IBV_WR_RDMA_WRITE          | ❌              |
| 原子 CAS   | `RdmaContext::Cas()`          | IBV_WR_ATOMIC_CMP_AND_SWP  | ❌              |
| 发送       | `RdmaContext::Send()`         | IBV_WR_SEND                | ✅（处理 recv） |
| 带立即数写 | `RdmaContext::WriteWithImm()` | IBV_WR_RDMA_WRITE_WITH_IMM | ✅（触发 recv） |

### 7.2 RDMA SEND 的合并机制

当多个 WorkRequest 需要向同一目标 Worker 发送 RDMA SEND 时，`MERGE_RDMA_REQUESTS` 将其合并为一条消息，减少网络往返：

```c
//src/rdma.cc — ProcessPendingRequests()
for each pending_request:
    if (op == SEND && prev_op == SEND && buf_pos + len <= MAX_REQUEST_SIZE):
        // 合并：用 '\0' 分隔多条 WorkRequest
        memcpy(prev_buf + buf_pos, '\0', 1);
        memcpy(prev_buf + buf_pos + 1, req.src, req.len);
        buf_pos += (1 + req.len);
    else:
        // 新建独立的 ibv_send_wr
```

### 7.3 数据传输目标

在默认的 CACHED 模式下：

- **RDMA Read 的目标**：`CacheLine->line`（slab buffer），不是用户 `buf`
- **RDMA Write 的目标**：`CacheLine->line`（写入本地缓存），不直接写 home

这是因为用户 buf 可能不在 Registered MR 范围内，而 CacheLine 始终是已注册的 slab buffer。

---

## 8. Read/Write 数据流详解

### 8.1 Read 完整路径（本地 Cache Miss）

```
应用线程                 Worker（本地）                  Home 节点 B
   │                          │                             │
   │  Read(addr, &val, sz)   │                             │
   │  ──────────────────────► │                             │
   │                          │                             │
   │  IsLocal(addr)? → 否    │                             │
   │  Cache hit? → 否        │                             │
   │                          │                             │
   │  分配 CacheLine          │                             │
   │  ToToShared(cline)       │                             │
   │                          │                             │
   │  RDMA SEND ─────────────────────────────────────────► │
   │  (WorkRequest: addr, cline->line)                      │
   │                          │                             │
   │                          │            directory.lock(addr)
   │                          │            DirEntry 查询
   │                          │            RDMA WRITE WITH_IMM
   │                          │            (数据从 home → cline)
   │                          │                             │
   │  RDMA WRITE ◄───────────────────────────────────────── │
   │  (clinesize 数据到达)    │                             │
   │                          │                             │
   │  memcpy(cline, user_buf) │                             │
   │  ◄─────────────────────  │                             │
   │                          │                             │
   │  [val 已填充]            │                             │
```

### 8.2 Write 完整路径（本地 Cache Hit, SHARED 状态）

```
应用线程                 Worker（本地）                  Home 节点
   │                          │                             │
   │  Write(addr, &val, sz)   │                             │
   │  ──────────────────────► │                             │
   │                          │                             │
   │  Cache SHARED            │                             │
   │  ToToDirty(cline)        │  ← 状态置 TO_DIRTY          │
   │  memcpy(user_buf, cline)  │                             │
   │  ◄─────────────────────  │                             │
   │                          │                             │
   │  RDMA SEND ─────────────────────────────────────────► │
   │  (通知 home: 升级为 DIRTY，失效其他共享者)              │
   │                          │                             │
   │  Invalidation 完成        │                             │
   │  cline 状态 → DIRTY      │                             │
   │                          │                             │
   │  [返回，数据在 cline]     │                             │
   │  [lazy write-back 延迟]  │                             │
```

### 8.3 Write 完整路径（本地 Cache Hit, DIRTY 状态）

```
应用线程                 Worker（本地）
   │                          │
   │  Write(addr, &val, sz)   │
   │  ──────────────────────► │
   │                          │
   │  Cache DIRTY             │
   │  memcpy(user_buf, cline) │
   │  ◄───────────────────── │
   │                          │
   │  [返回，无网络操作]       │
   │  [数据仍在 cline，未发往 home] │
```

### 8.4 数据拷贝次数汇总

| 场景              | 拷贝次数 | 说明                             |
| ----------------- | -------- | -------------------------------- |
| Read, Cache Hit   | 1        | CacheLine → user buf（memcpy）   |
| Read, Cache Miss  | 2        | 远端 DRAM → CacheLine → user buf |
| Write, DIRTY Hit  | 1        | user buf → CacheLine（memcpy）   |
| Write, SHARED Hit | 1        | user buf → CacheLine（memcpy）   |
| Write, Cache Miss | 1        | user buf → CacheLine（memcpy）   |
| 驱逐 DIRTY        | 0        | RDMA DMA 直接从 CacheLine 写回   |

---

## 9. Fence 与一致性模型

### 9.1 PSO（Partial Store Order）一致性模型

GAM 采用 PSO——写操作异步化（立即返回），读操作同步化（等待完成）：

```
Read()   ── 同步 ──►  等待 RDMA 完成才返回
Write()  ── 异步 ──►  立即返回，RDMA 在后台完成
MFence() ── 同步 ──►  等待所有之前 Write 的 RDMA 完成
```

### 9.2 MFence 实现机制

`MFence` 不是简单的内存屏障指令，而是一个**调度点**——确保在它之前的 Write 都已被 Worker 线程处理（已提交 RDMA）。

```c
//src/gallocator.cc
void GAlloc::MFence() {
    WorkRequest wr { .op = MFENCE, .flag = ASYNC };
    wh->SendRequest(&wr);  // 等待 wr.counter == 0
}

//src/local_request.cc — ProcessLocalMFence()
Fence* fence = fences_.at(wr->fd);
if (IsFenced(fence, wr)) {
    AddToFence(fence, wr);    // 之前的写未完成，挂起
} else {
    if (fence->pending_writes)    // 如果有待处理写
        fence-><tool_call> = true;   // 标记需要 fence
}
```

Fence 的核心字段：

```c
struct Fence {
    atomic<int> pending_writes;  // 尚未 post 的写请求数
    bool sfenced;                // store fence 已设置
    bool[email protected];               // full fence 已设置
    deque<WorkRequest*> pending_works;  // fence 后的待处理请求
};
```

### 9.3 SFence

SFence 是**线程内有序写屏障**（`local_request.cc:227` 注释：`SFENCE is not supported for now!`）：

```c
void GAlloc::SFence() {
    WorkRequest wr { .op = SFENCE, .flag = ASYNC };
    wh->SendRequest(&wr);
}
// 在 Worker 内部：fence->sfenced = true
// 仅确保本线程内的写操作顺序，不跨线程
```

### 9.4 Fence 的处理逻辑

```c
//src/worker.cc — 事件循环中
while (true) {
    // 处理 to_serve_local_requests
    for each request in queue:
        ProcessLocalRequest(req);

    // fence 驱动的批处理
    if (fence-></tool_call>) {
        // 等待所有 pending_writes 清零
        flush_all_pending_writes();
        // 按序处理 pending_works 队列中的请求
        for each req in fence->pending_works:
            ProcessLocalRequest(req);
    }
}
```

---

## 10. GFUNC 远程计算

### 10.1 为什么需要 GFUNC

普通 Read-Modify-Write 需要两次网络往返（Read + Write），对于轻量计算（counter++）浪费严重。GFUNC 通过 RDMA SEND with Immediate 触发远程节点执行函数，只用一次往返。

### 10.2 实现路径

```c
//src/gallocator.cc — Write(..., GFunc* gfunc, uint64_t arg)
wr.op = WRITE;
wr.flag = ASYNC | NOT_CACHE;  // 不经过本地缓存
wr.gfunc = gfunc;
wr.arg = arg;

// Worker 事件循环 → ProcessLocalRequest → SubmitRequest
// → Client → RdmaContext::Send (IBV_WR_SEND_WITH_IMM)

// 远端收到 IBV_WC_WITH_IMM
// → Server::ProcessRdmaRequest()
// → Worker::HandleGfunc(work.op, work.gfunc, work.arg)
```

### 10.3 约束

1. **只能在 home 节点执行**（需要直接操作 home 内存）
2. **不能跨 CacheLine 边界**
3. **必须无副作用**（只能访问传入 addr）
4. **必须预注册**（`GAllocFactory::gfuncs[]`，编译时确定）
5. **使用 NOT_CACHE flag**，直接操作远程内存，不经过本地缓存

---

## 11. 锁机制

### 11.1 锁的粒度

GAM 的锁是**块粒度**（512 字节 BLOCK_SIZE 对齐），与缓存行一致：

```c
//include/cache.h — CacheLine.locks
unordered_map<GAddr, int> locks;  // key=子地址偏移, value=引用计数
```

### 11.2 读锁 vs 写锁

```c
// 读锁：增加共享计数
// 任何写锁都会失败（除非计数 == 0 或全部为读锁）
locks[addr]++;

// 写锁：独占计数
// 使用 EXCLUSIVE_LOCK_TAG (255) 作为标记
locks[addr] = EXCLUSIVE_LOCK_TAG;

// 解锁：减少计数，计数归零时释放锁
locks[addr]-- → 0 → erase
```

### 11.3 锁在 Directory 中的对应

```c
//include/directory.h — DirEntry.locks
unordered_map<ptr_t, int> locks;  // key=ptr_t(子地址), value=计数
```

当本地 Cache 持有锁时，目录中的对应条目也会记录锁状态，确保远程节点在锁被持有时无法转移数据所有权。

### 11.4 TryLock

```c
// Try_WLock: 非阻塞尝试获取写锁
// 成功返回 0，失败返回 -1
// 失败时不阻塞，调用方自旋重试
```

---

## 12. NOCACHE 模式

当 `settings.h` 中定义 `#define NOCACHE` 时，GAM 跳过本地缓存层，直接操作远程内存。

### 12.1 差异对比

| 特性        | 默认模式（CACHED） | NOCACHE 模式                  |
| ----------- | ------------------ | ----------------------------- |
| Read 目标   | CacheLine buffer   | 用户 buf（必须事先注册到 MR） |
| Write 目标  | CacheLine buffer   | 用户 buf（必须事先注册到 MR） |
| 缓存一致性  | 完整目录协议       | 目录协议（但无本地副本）      |
| LRU 驱逐    | 有                 | 无                            |
| 数据局部性  | 好（缓存热点数据） | 无（每次都 RDMA）             |
| memcpy 次数 | cache miss: 2次    | 0次（直接 DMA）               |
| 适用场景    | 读多写少的工作集   | 全局共享数据（无局部性）      |

### 12.2 NOCACHE 路径

```c
// src/local_request_nocache.cc
ProcessLocalRequest(wr):
    if (IsLocal(addr)):
        // 直接读写本地内存
        memcpy(user_buf, local_addr, count);
    else:
        // 直接 RDMA Read → user buf
        // 直接 RDMA Write ← user buf
        // 无 CacheLine 中转
```

---

## 附录：源码文件索引

```
include/
├── gallocator.h          # GAlloc 公开 API
├── gptr.h               # GPtr<T> 模板指针
├── configuration.h       # Conf 结构体
├── workrequest.h        # WorkRequest 操作描述符
├── structure.h           # GAddr 编解码、BLOCK_SIZE
├── settings.h           # 所有编译选项
├── cache.h              # CacheLine、CacheState、Cache 类
├── directory.h           # DirEntry、DirState、Directory 类
├── rdma.h               # RdmaContext（QP 封装）
├── worker.h             # Worker 类
├── worker_handle.h      # WorkerHandle
├── client.h             # Client 类
├── master.h             # Master 类
├── fence.h              # MFence/SFence 状态
└── internal/

src/
├── gallocator.cc         # GAlloc 方法
├── cache.cc            # Cache::ReadWrite, Evict, SetCLine
├── directory.cc        # 目录状态机、锁管理
├── rdma.cc             # RDMA verbs（ibv_post_send 系）
├── worker.cc           # Worker 事件循环
├── worker_handle.cc    # 应用线程 → Worker 的队列桥接
├── client.cc           # Client::Write/Read/Send, ExchConnParam
├── server.cc           # Server 接收处理
├── master.cc           # Master 协调、Put/Get key-value
├── remote_request.cc   # 所有 ProcessRemote* 分发（switch op）
├── remote_request_cache.cc  # 带缓存的远程处理
├── remote_request_nocache.cc  # 无缓存的远程处理
├── local_request.cc    # MFence/SFence/锁处理
├── local_request_cache.cc   # 带缓存的本地处理
├── local_request_nocache.cc  # 无缓存的本地处理
├── slabs.cc            # slab allocator
└── ae_*.cc            # 事件循环（epoll/kqueue/select）
```