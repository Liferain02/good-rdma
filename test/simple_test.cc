#include <iostream>
#include <thread>
#include <atomic>
#include <unistd.h>
#include "gallocator.h"
#include "util.h"
#include "gptr.h"

#define SYNC_KEY 1000

int main(int argc, char *argv[])
{
    string ip_master = "12.12.12.1";
    int port_master = 12341;
    string ip_worker = "12.12.12.1";
    int port_worker = 12345;
    int is_master = 0;
    for (int i = 1; i < argc; i++)
    {
        if (strcmp(argv[i], "--ip_master") == 0)
        {
            ip_master = string(argv[++i]);
        }
        else if (strcmp(argv[i], "--ip_worker") == 0)
        {
            ip_worker = string(argv[++i]);
        }
        else if (strcmp(argv[i], "--port_master") == 0)
        {
            port_master = atoi(argv[++i]);
        }
        else if (strcmp(argv[i], "--port_worker") == 0)
        {
            port_worker = atoi(argv[++i]);
        }
        else if (strcmp(argv[i], "--is_master") == 0)
        {
            is_master = atoi(argv[++i]);
        }
    }

    // 初始化 GAlloc
    Conf conf;
    conf.loglevel = LOG_WARNING;
    conf.is_master = is_master;
    conf.master_ip = ip_master;
    conf.master_port = port_master;
    conf.worker_ip = ip_worker;
    conf.worker_port = port_worker;
    GAlloc *alloc = GAllocFactory::CreateAllocator(&conf);

    int node_id = alloc->GetID();
    std::cout << "Node " << node_id << " started." << std::endl;

    // 同步所有节点
    int sync_value = node_id;
    alloc->Put(SYNC_KEY + node_id, &sync_value, sizeof(int));
    for (int i = 1; i <= 3; i++)
    {
        int read_value;
        alloc->Get(SYNC_KEY + i, &read_value);
        if (read_value != i)
        {
            std::cerr << "Sync failed for node " << i << std::endl;
            return 1;
        }
    }
    std::cout << "All nodes synchronized." << std::endl;
    sleep(1);
    // 主节点（node_id == 1）分配内存
    if (node_id == 1)
    {
        GAddr addr = alloc->Malloc(sizeof(int), REMOTE);
        std::cout << "Node 1 allocated memory at " << addr << std::endl;
        if (alloc->IsLocal(addr))
        {
            std::cout << "addr at Node " << node_id << std::endl;
        }
        // 将分配的地址写入全局键值对，供其他节点访问
        alloc->Put(1, &addr, sizeof(GAddr));
    }

    sleep(2);

    // 从节点 2（node_id == 2）写入数据
    if (node_id == 2)
    {
        GAddr addr;
        alloc->Get(1, &addr); // 获取主节点分配的地址
        if (alloc->IsLocal(addr))
        {
            std::cout << "addr at Node " << node_id << std::endl;
        }
        // char data[1024];
        // memset(data, 'A', 1024);
        int data = 666;
        // GPtr<int> gptr(addr, alloc);
        // *addr = data;
        // int j = *addr;
        alloc->Write(addr, &data, sizeof(int));
        std::cout << "Node 2 wrote 666 to " << addr << ": " << data << std::endl;
    }

    sleep(2);

    // 从节点 3（node_id == 3）读取数据
    if (node_id == 3)
    {
        GAddr addr;
        alloc->Get(1, &addr); // 获取主节点分配的地址
        if (alloc->IsLocal(addr))
        {
            std::cout << "addr at Node " << node_id << std::endl;
        }
        int data;
        // GPtr<int> gptr(addr, allocator);
        // data = *addr;
        alloc->Read(addr, &data, sizeof(int));
        std::cout << "Node 3 read from " << addr << ": " << data << std::endl;
        if (data == 666)
        {
            std::cout << "Test passed." << std::endl;
        }
        else
        {
            std::cout << "Test failed." << std::endl;
        }
        alloc->Free(addr);
    }
    // // 清理
    // alloc->MFence();
    delete alloc;
    return 0;
}