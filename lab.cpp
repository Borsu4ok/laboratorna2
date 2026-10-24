#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define KERNEL extern "C" __attribute__((noipa))

constexpr int      MAT_N      = 1024;       
constexpr int      MAT_REPS   = 2;
constexpr size_t   VEC_N      = 1u << 22;    
constexpr int      SAXPY_REPS = 300;
constexpr size_t   BR_N       = 1u << 23;    
constexpr int      BR_REPS    = 60;
constexpr int      FIB_K      = 40;

using Clock = std::chrono::steady_clock;
static double secs(Clock::time_point a, Clock::time_point b) {
    return std::chrono::duration<double>(b - a).count();
}

__attribute__((noipa)) static void fill_random_f(std::vector<float> &a) {
    for (float &x : a) x = static_cast<float>(std::rand()) / static_cast<float>(RAND_MAX);
}
__attribute__((noipa)) static void fill_random_i(std::vector<int32_t> &a) {
    for (int32_t &x : a) x = std::rand() & 255;  
}

KERNEL void matmul(const float *__restrict A, const float *__restrict B,
                   float *__restrict C, int n) {
    for (int i = 0; i < n * n; i++) C[i] = 0.0f;
    for (int i = 0; i < n; i++)
        for (int k = 0; k < n; k++) {
            const float a = A[i * n + k];
            for (int j = 0; j < n; j++)
                C[i * n + j] += a * B[k * n + j];
        }
}

KERNEL void saxpy(float a, const float *__restrict x, float *__restrict y, size_t n) {
    for (size_t i = 0; i < n; i++)
        y[i] = a * x[i] + y[i];
}

KERNEL int64_t branchy_sum(const int32_t *__restrict a, size_t n) {
    int64_t s = 0;
    for (size_t i = 0; i < n; i++)
        if (a[i] >= 128)
            s += a[i];
    return s;
}

KERNEL uint64_t fib(int k) {
    return k < 2 ? static_cast<uint64_t>(k) : fib(k - 1) + fib(k - 2);
}

int main(int argc, char **argv) {
    int scale = (argc > 1) ? std::atoi(argv[1]) : 1;
    if (scale < 1) scale = 1;
    std::srand(12345);

    const int n = MAT_N;
    std::vector<float>   A(static_cast<size_t>(n) * n), B(A.size()), C(A.size());
    std::vector<float>   x(VEC_N), y(VEC_N);
    std::vector<int32_t> br(BR_N);

    auto t0 = Clock::now(), t = t0;
    const auto t_start = t0; 
    fill_random_f(A); fill_random_f(B); fill_random_f(x); fill_random_f(y);
    fill_random_i(br);
    t = Clock::now(); std::printf("[init  ] %7.3f s\n", secs(t0, t)); t0 = t;

    double check = 0.0;

    for (int r = 0; r < MAT_REPS * scale; r++) matmul(A.data(), B.data(), C.data(), n);
    check += C.front() + C.back();
    t = Clock::now(); std::printf("[matmul] %7.3f s\n", secs(t0, t)); t0 = t;

    for (int r = 0; r < SAXPY_REPS * scale; r++) saxpy(1.0001f, x.data(), y.data(), VEC_N);
    check += y.front() + y.back();
    t = Clock::now(); std::printf("[saxpy ] %7.3f s\n", secs(t0, t)); t0 = t;

    int64_t bs = 0;
    for (int r = 0; r < BR_REPS * scale; r++) bs += branchy_sum(br.data(), BR_N);
    check += static_cast<double>(bs);
    t = Clock::now(); std::printf("[branch] %7.3f s\n", secs(t0, t)); t0 = t;

    uint64_t f = 0;
    for (int r = 0; r < scale; r++) f += fib(FIB_K);
    check += static_cast<double>(f);
    t = Clock::now(); std::printf("[fib   ] %7.3f s\n", secs(t0, t));
    
    std::printf("[total ] %7.3f s\n", secs(t_start, t));

    std::printf("checksum = %.6e\n", check);
    return 0;
}
