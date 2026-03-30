# Boost library path（BOOST_HOME 环境变量，默认使用本地预置的 Boost 1.53.0）
BOOST_HOME ?= /share/home/lifr/workspace/data/boost1.53.0

CPP = g++ -std=c++11 -O3 -D_GLIBCXX_USE_CXX11_ABI=1
INCLUDE = -I../include -I../lib/libcuckoo/src -I../lib/libcuckoo/cityhash-1.1.1/src -I$(BOOST_HOME)/include
LIBS = ../src/libgalloc.a -libverbs -lpthread ../lib/libcuckoo/cityhash-1.1.1/src/.libs/libcityhash.a -L$(BOOST_HOME)/lib -lboost_thread -lboost_system -Wl,-rpath,$(BOOST_HOME)/lib
CFLAGS += -g -rdynamic

build: benchmark lru_test example example-r worker master slab_test rw_test fence_test lock_test hashtable_test hashtable_throw_test garray_test cs_test simple_gptr gptr_test

benchmark: benchmark.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS) 

lru_test: lru_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

lock_test: lock_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

fence_test: fence_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

rw_test: rw_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

slab_test: slab_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

example: example.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

example-r: example-r.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

worker: worker_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)
	
master: master_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

hashtable_test: hashtable_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

hashtable_throw_test: hashtable_throw_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)
	
garray_test: garray_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)
	
cs_test: cs_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

simple_gptr: simple_gptr.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

gptr_test: gptr_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -o $@ $^ $(LIBS)

gfunc_test: ../test/gfunc_test.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -g -o $@ $^ $(LIBS)		

clean:
	rm -rf example example-r worker master slab_test rw_test lock_test lru_test fence_test benchmark hashtable_test hashtable_throw_test garray_test cs_test gfunc_test simple_gptr gptr_test
