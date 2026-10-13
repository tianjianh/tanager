/* The two LZ4 functions Verilator's FST writer calls (public LZ4 API, liblz4 1.9).
   Used only because the build host has the liblz4 runtime but not liblz4-dev; sim/Makefile
   links the runtime library directly. Remove once liblz4-dev is installed. */
#ifndef TG_COMPAT_LZ4_H
#define TG_COMPAT_LZ4_H
#ifdef __cplusplus
extern "C" {
#endif
int LZ4_compressBound(int inputSize);
int LZ4_compress_default(const char* src, char* dst, int srcSize, int dstCapacity);
#ifdef __cplusplus
}
#endif
#endif
