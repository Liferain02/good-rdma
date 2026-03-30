# Boost library path（BOOST_HOME 环境变量，默认使用本地预置的 Boost 1.53.0）
BOOST_HOME ?= /share/home/lifr/workspace/data/boost1.53.0

CPP = g++ -std=c++11 -D_GLIBCXX_USE_CXX11_ABI=1
GAM_INCLUDE = -I../../include -I../ -I../../lib/libcuckoo/src -I../../lib/libcuckoo/cityhash-1.1.1/src -I$(BOOST_HOME)/include
DB_INCLUDE = -I.. -I../bench -I../storage -I../txn -I../utils
INCLUDE = $(GAM_INCLUDE) $(DB_INCLUDE)
LIBS = ../../src/libgalloc.a -L$(BOOST_HOME)/lib -libverbs -lboost_filesystem -lboost_system -lboost_date_time -lboost_thread ../../lib/libcuckoo/cityhash-1.1.1/src/.libs/libcityhash.a -Wl,-rpath,$(BOOST_HOME)/lib
CFLAGS += -O3 -DLOCK -DBACKOFF #-DPROFILE

all: tpcc
build: tpcc

SRC = TpccBenchmarkMain.cpp TpccRandomGenerator.cpp ../Meta.cpp ../txn/TransactionManager2PL.cpp ../txn/TransactionManagerST.cpp ../utils/Profiler.cpp
OBJ = TpccBenchmarkMain.o TpccRandomGenerator.o ../Meta.o ../txn/TransactionManager2PL.o ../txn/TransactionManagerST.o ../utils/Profiler.o

$(OBJ): %.o : %.cpp
	$(CPP) $< $(CFLAGS) $(INCLUDE) -g -c -o $@

tpcc: $(OBJ)
	$(CPP) $(CFLAGS) $(INCLUDE) -g -o $@ $^ $(LIBS) 

clean:
	rm -rf tpcc *.o ../*.o ../bench/*.o ../storage/*.o ../txn/*.o ../utils/*.o
