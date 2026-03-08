#include <string>
#include <iostream>
#include <cstring>
#include "gallocator.h"
using namespace std;

// 全局指针类，用于管理 GAddr 并重载运算符
template <typename T>
class GPtr
{
private:
    GAddr addr;
    GAlloc *allocator; // 用于调用 Read 和 Write

public:
    // 构造函数
    GPtr(GAddr a, GAlloc *alloc) : addr(a), allocator(alloc) {}

    // 代理类，用于处理读写操作
    class Proxy
    {
    private:
        GAddr addr;
        GAlloc *allocator;

    public:
        Proxy(GAddr a, GAlloc *alloc) : addr(a), allocator(alloc) {}

        // 重载赋值运算符，用于写入
        // Proxy &operator=(const T &value)
        // {
        //     allocator->Write(addr, &value, sizeof(T));
        //     return *this;
        // }
        Proxy &operator=(const T &value)
        {
            void *buf = const_cast<void *>(static_cast<const void *>(&value)); // 为了和write的void* buf兼容
            allocator->Write(addr, buf, sizeof(T));
            return *this;
        }

        // 类型转换运算符，用于读取
        operator T()
        {
            T value;
            allocator->Read(addr, &value, sizeof(T));
            return value;
        }
    };

    // 重载解引用运算符，返回 Proxy 对象
    Proxy operator*()
    {
        return Proxy(addr, allocator);
    }

    // 重载索引运算符，支持数组访问
    Proxy operator[](size_t n)
    {
        GAddr element_addr = GADD(addr, sizeof(T) * n);
        return Proxy(element_addr, allocator);
    }

    // 可选：支持指针运算
    GPtr<T> operator+(size_t n) const
    {
        return GPtr<T>(GADD(addr, sizeof(T) * n), allocator);
    }
};
