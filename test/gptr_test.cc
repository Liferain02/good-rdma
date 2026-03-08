#include <string>
#include <iostream>
#include <cstring>
#include "gallocator.h"
// #include "util.h"
// #include "gptr.h"
using namespace std;

int main()
{
    Conf conf;
    conf.loglevel = LOG_WARNING;
    conf.is_master = true;
    conf.worker_port = 12347;

    GAlloc *allocator = GAllocFactory::CreateAllocator(&conf);
    // GAddr lptr = allocator->Malloc(sizeof(int), RANDOM);
    GAddr lptr = allocator->Malloc(sizeof(int), REMOTE);
    printf("%lx is local? %s, local addr = %p\n", lptr,
           allocator->IsLocal(lptr) == true ? "true" : "false",
           allocator->GetLocal(lptr));
    // int i = 2, j = 0;
    // 使用 GPtr 包装全局地址
    GAlloc::GPtr<int> gptr(lptr, allocator);
    // 写入值
    *gptr = 2;

    // 读取值
    int j = *gptr;
    cout << "j = " << j << endl;
    // allocator->Write(lptr, &i, sizeof(int));
    // allocator->Read(lptr, &j, sizeof(int));
    // cout << "j = " << j << endl;

    allocator->Free(lptr);
    return 0;
}
