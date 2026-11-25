#!/usr/bin/env bash
set -euo pipefail

NVCC="${NVCC:-/usr/local/cuda/bin/nvcc}"
SRC="/tmp/p2p_speed_bench.cu"
BIN="/tmp/p2p_speed_bench"

cleanup() {
    sudo nvidia-smi -rmc >/dev/null 2>&1 || true
    sudo nvidia-smi -rgc >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== 1. Waking GPUs to P0 (PCIe Gen 4 x8) ==="
sudo nvidia-smi -pm 1 >/dev/null
sudo nvidia-smi -lmc 9501,9501 >/dev/null
sleep 1

echo "=== 2. Driver, BAR1 & PCIe Link Status ==="
head -n 1 /proc/driver/nvidia/version
nvidia-smi --query-gpu=index,pci.bus_id,pstate,pcie.link.gen.current,pcie.link.width.current,memory.total --format=csv
echo "--- BAR1 Aperture ---"
nvidia-smi -q -d MEMORY | awk '/^GPU /{gpu=$2} /BAR1 Memory Usage/{f=1;next} f&&/Total/{print "GPU " gpu " BAR1 Total: " $3 " " $4; f=0}'
echo "--- P2P Write Topology ---"
nvidia-smi topo -p2p w | head -n 5

cat << 'CU_EOF' > "$SRC"
#include <cstdio>
#include <cstdlib>
#include <chrono>
#include <cuda_runtime.h>

#define CHECK_CUDA(call) do { \
    cudaError_t err = (call); \
    if (err != cudaSuccess) { \
        fprintf(stderr, "CUDA Error at line %d: %s\n", __LINE__, cudaGetErrorString(err)); \
        exit(1); \
    } \
} while (0)

double bench_uni(void *dst, int dstDev, void *src, int srcDev, size_t bytes, int iters, cudaStream_t s) {
    CHECK_CUDA(cudaMemcpyPeerAsync(dst, dstDev, src, srcDev, bytes, s));
    CHECK_CUDA(cudaStreamSynchronize(s));
    auto t0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < iters; i++) {
        CHECK_CUDA(cudaMemcpyPeerAsync(dst, dstDev, src, srcDev, bytes, s));
    }
    CHECK_CUDA(cudaStreamSynchronize(s));
    auto t1 = std::chrono::high_resolution_clock::now();
    double sec = std::chrono::duration<double>(t1 - t0).count();
    return (double(bytes) * iters / 1e9) / sec;
}

double bench_bi(void *d0, void *d1, size_t bytes, int iters, cudaStream_t s0, cudaStream_t s1) {
    CHECK_CUDA(cudaMemcpyPeerAsync(d1, 1, d0, 0, bytes, s0));
    CHECK_CUDA(cudaMemcpyPeerAsync(d0, 0, d1, 1, bytes, s1));
    CHECK_CUDA(cudaStreamSynchronize(s0));
    CHECK_CUDA(cudaStreamSynchronize(s1));
    auto t0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < iters; i++) {
        CHECK_CUDA(cudaMemcpyPeerAsync(d1, 1, d0, 0, bytes, s0));
        CHECK_CUDA(cudaMemcpyPeerAsync(d0, 0, d1, 1, bytes, s1));
    }
    CHECK_CUDA(cudaStreamSynchronize(s0));
    CHECK_CUDA(cudaStreamSynchronize(s1));
    auto t1 = std::chrono::high_resolution_clock::now();
    double sec = std::chrono::duration<double>(t1 - t0).count();
    return (double(bytes) * 2.0 * iters / 1e9) / sec;
}

double bench_lat_us(void *dst, int dstDev, void *src, int srcDev, size_t bytes, int iters, cudaStream_t s) {
    CHECK_CUDA(cudaMemcpyPeerAsync(dst, dstDev, src, srcDev, bytes, s));
    CHECK_CUDA(cudaStreamSynchronize(s));
    auto t0 = std::chrono::high_resolution_clock::now();
    for (int i = 0; i < iters; i++) {
        CHECK_CUDA(cudaMemcpyPeerAsync(dst, dstDev, src, srcDev, bytes, s));
        CHECK_CUDA(cudaStreamSynchronize(s));
    }
    auto t1 = std::chrono::high_resolution_clock::now();
    double us = std::chrono::duration<double, std::micro>(t1 - t0).count();
    return us / iters;
}

int main() {
    size_t sz = 256ULL * 1024 * 1024; // 256 MiB
    int iters = 10;
    void *d0 = nullptr, *d1 = nullptr, *h = nullptr;
    cudaStream_t s0, s1;

    CHECK_CUDA(cudaSetDevice(0));
    CHECK_CUDA(cudaMalloc(&d0, sz));
    CHECK_CUDA(cudaMallocHost(&h, sz));
    CHECK_CUDA(cudaStreamCreate(&s0));

    CHECK_CUDA(cudaSetDevice(1));
    CHECK_CUDA(cudaMalloc(&d1, sz));
    CHECK_CUDA(cudaStreamCreate(&s1));

    printf("\n=== 3. Host Pinned RAM <-> GPU Bandwidth (256 MiB x %d) ===\n", iters);
    for (int g = 0; g < 2; g++) {
        void *dg = (g == 0) ? d0 : d1;
        cudaStream_t sg = (g == 0) ? s0 : s1;
        CHECK_CUDA(cudaSetDevice(g));
        CHECK_CUDA(cudaMemcpyAsync(dg, h, sz, cudaMemcpyHostToDevice, sg));
        CHECK_CUDA(cudaStreamSynchronize(sg));
        auto t0 = std::chrono::high_resolution_clock::now();
        for (int i = 0; i < iters; i++) CHECK_CUDA(cudaMemcpyAsync(dg, h, sz, cudaMemcpyHostToDevice, sg));
        CHECK_CUDA(cudaStreamSynchronize(sg));
        double h2d = (double(sz) * iters / 1e9) / std::chrono::duration<double>(std::chrono::high_resolution_clock::now() - t0).count();

        t0 = std::chrono::high_resolution_clock::now();
        for (int i = 0; i < iters; i++) CHECK_CUDA(cudaMemcpyAsync(h, dg, sz, cudaMemcpyDeviceToHost, sg));
        CHECK_CUDA(cudaStreamSynchronize(sg));
        double d2h = (double(sz) * iters / 1e9) / std::chrono::duration<double>(std::chrono::high_resolution_clock::now() - t0).count();
        printf("GPU %d : Host -> GPU = %6.2f GB/s | GPU -> Host = %6.2f GB/s\n", g, h2d, d2h);
    }

    printf("\n=== 4. GPU 0 <-> GPU 1 [P2P DISABLED / Host-Staged] ===\n");
    printf("Unidirectional GPU 0 -> GPU 1 : %6.2f GB/s\n", bench_uni(d1, 1, d0, 0, sz, iters, s0));
    printf("Unidirectional GPU 1 -> GPU 0 : %6.2f GB/s\n", bench_uni(d0, 0, d1, 1, sz, iters, s1));
    printf("Bidirectional  GPU 0 <-> GPU 1: %6.2f GB/s\n", bench_bi(d0, d1, sz, iters, s0, s1));
    printf("4 KiB Transfer Latency        : %6.2f us\n", bench_lat_us(d1, 1, d0, 0, 4096, 1000, s0));

    int can01 = 0, can10 = 0;
    CHECK_CUDA(cudaDeviceCanAccessPeer(&can01, 0, 1));
    CHECK_CUDA(cudaDeviceCanAccessPeer(&can10, 1, 0));

    printf("\n=== 5. GPU 0 <-> GPU 1 [P2P ENABLED / Direct BAR1] ===\n");
    if (can01 && can10) {
        CHECK_CUDA(cudaSetDevice(0)); CHECK_CUDA(cudaDeviceEnablePeerAccess(1, 0));
        CHECK_CUDA(cudaSetDevice(1)); CHECK_CUDA(cudaDeviceEnablePeerAccess(0, 0));

        printf("Unidirectional GPU 0 -> GPU 1 : %6.2f GB/s\n", bench_uni(d1, 1, d0, 0, sz, iters, s0));
        printf("Unidirectional GPU 1 -> GPU 0 : %6.2f GB/s\n", bench_uni(d0, 0, d1, 1, sz, iters, s1));
        printf("Bidirectional  GPU 0 <-> GPU 1: %6.2f GB/s\n", bench_bi(d0, d1, sz, iters, s0, s1));
        printf("4 KiB Transfer Latency        : %6.2f us\n", bench_lat_us(d1, 1, d0, 0, 4096, 1000, s0));

        CHECK_CUDA(cudaSetDevice(0)); CHECK_CUDA(cudaDeviceDisablePeerAccess(1));
        CHECK_CUDA(cudaSetDevice(1)); CHECK_CUDA(cudaDeviceDisablePeerAccess(0));
    } else {
        printf("cudaDeviceCanAccessPeer = 0 (Stock driver loaded; direct P2P is currently OFF).\n");
    }

    cudaFree(d0); cudaFree(d1); cudaFreeHost(h);
    return 0;
}
CU_EOF

"$NVCC" -O2 -std=c++17 -arch=sm_86 "$SRC" -o "$BIN"
"$BIN"

echo ""
echo "=== 6. Restoring Dynamic GPU Clocks ==="
