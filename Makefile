all: cnws
cnws: cnws.cpp
	g++ -Icppjieba/deps/limonp/include -Icppjieba/include -O3 -o cnws cnws.cpp
clean:
	rm -f *.a *.o cnws
