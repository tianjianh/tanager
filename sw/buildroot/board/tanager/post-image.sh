#!/bin/sh
# Buildroot post-image hook: build the Tanager device trees next to the images.
# $1 = BINARIES_DIR. sw/dts/Makefile takes the configuration from the environment
# (CORES, THREADS, MEM, FPU); the defaults are the st build with F/D, 1 GiB.
set -e
make -C "$BR2_EXTERNAL_TANAGER_PATH/../dts" O="$1" DTC=dtc CPP="gcc-15 -E"
