# Boost library path（BOOST_HOME 环境变量，默认使用本地预置的 Boost 1.53.0）
BOOST_HOME ?= /share/home/lifr/workspace/data/boost1.53.0

CPP = g++
INCLUDE = -I../include -I../lib/libcuckoo/src -I../lib/libcuckoo/cityhash-1.1.1/src -I$(BOOST_HOME)/include
LIBS = ../src/libgalloc.a -libverbs -lpthread ../lib/libcuckoo/cityhash-1.1.1/src/.libs/libcityhash.a -L$(BOOST_HOME)/lib -lboost_thread -lboost_system -Wl,-rpath,$(BOOST_HOME)/lib
CFLAGS += -rdynamic -std=c++11 -O3 -DDHT -D_GLIBCXX_USE_CXX11_ABI=1

%.o: %.cc
	$(CPP) $(CFLAGS) $(INCLUDE) -c -o $@ $^ 

benchmark: kvbench.o kvclient.o
	cd ../src; make clean; make dht=1 -j; cd ../dht
	$(CPP) -o $@ $^ $(LIBS) 

clean:
	rm *.o benchmark
