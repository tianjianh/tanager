# tgsim: build with the host GCC 15 (WSL Ubuntu-24.04).
# CXX has a built-in default (g++, which is GCC 13 on Ubuntu 24.04), so `?=` would never apply here.
ifeq ($(origin CXX),default)
CXX      := g++-15
endif
CXXFLAGS ?= -std=c++23 -O2 -g -Wall -Wextra -Wno-unused-parameter -march=native
SRC      := $(wildcard src/*.cpp)
OBJ      := $(patsubst src/%.cpp,build/obj/%.o,$(SRC))

build/tgsim: $(OBJ)
	$(CXX) $(CXXFLAGS) -o $@ $^

build/obj/%.o: src/%.cpp $(wildcard src/*.h) | build/obj
	$(CXX) $(CXXFLAGS) -c -o $@ $<

build/obj:
	mkdir -p $@

clean:
	rm -rf build/obj build/tgsim

.PHONY: clean
