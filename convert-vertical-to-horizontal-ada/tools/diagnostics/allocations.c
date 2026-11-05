/* Diagnostic-only interposition; no production or dependency source changes. */
#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <inttypes.h>

void *__real_malloc(size_t n);
void *__real_calloc(size_t n, size_t size);
void *__real_realloc(void *p, size_t n);
void __real_free(void *p);
void *__wrap_malloc(size_t n);
void *__wrap_calloc(size_t n, size_t size);
void *__wrap_realloc(void *p, size_t n);
void __wrap_free(void *p);
void epub_heap_profile_dump(void);

typedef struct {
    DWORD tid, reserved;
    uint64_t malloc_calls, calloc_calls, realloc_calls, free_calls;
    uint64_t requested, allocation_ticks, free_ticks;
    unsigned char padding[64];
} Row;
_Static_assert(sizeof(Row) == 128, "Avoid false sharing between counter rows");
_Alignas(128) static Row rows[128];
/* Avoid compiler emulated TLS: its initialization allocates through malloc. */
static Row *local_row(void) {
    DWORD tid = GetCurrentThreadId();
    unsigned first = (tid >> 2) & 127U;
    for (unsigned i = 0; i < 128U; ++i) {
        Row *r = &rows[(first + i) & 127U];
        DWORD owner = r->tid;
        if (owner == tid) return r;
        if (owner == 0U && InterlockedCompareExchange((volatile LONG *)&r->tid, (LONG)tid, 0) == 0) return r;
    }
    return NULL;
}static uint64_t ticks(void) {
    LARGE_INTEGER value;
    QueryPerformanceCounter(&value);
    return (uint64_t)value.QuadPart;
}
void *__wrap_malloc(size_t n) {
    Row *r = local_row();
    if (r == NULL || r->reserved) return __real_malloc(n);
    r->reserved = 1; uint64_t start = ticks();
    void *p = __real_malloc(n);
    uint64_t elapsed = ticks() - start;
    if (r != NULL) { r->malloc_calls++; r->requested += n; r->allocation_ticks += elapsed; }
    r->reserved = 0; return p;
}
void *__wrap_calloc(size_t n, size_t size) {
    Row *r = local_row();
    if (r == NULL || r->reserved) return __real_calloc(n, size);
    r->reserved = 1; uint64_t start = ticks();
    void *p = __real_calloc(n, size);
    uint64_t elapsed = ticks() - start;
    if (r != NULL) { r->calloc_calls++; r->requested += (uint64_t)n * size; r->allocation_ticks += elapsed; }
    r->reserved = 0; return p;
}
void *__wrap_realloc(void *p, size_t n) {
    Row *r = local_row();
    if (r == NULL || r->reserved) return __real_realloc(p, n);
    r->reserved = 1; uint64_t start = ticks();
    void *result = __real_realloc(p, n);
    uint64_t elapsed = ticks() - start;
    if (r != NULL) { r->realloc_calls++; r->requested += n; r->allocation_ticks += elapsed; }
    r->reserved = 0; return result;
}
void __wrap_free(void *p) {
    Row *r = local_row();
    if (r == NULL || r->reserved) { __real_free(p); return; }
    r->reserved = 1; uint64_t start = ticks();
    __real_free(p);
    uint64_t elapsed = ticks() - start;
    if (r != NULL) { r->free_calls++; r->free_ticks += elapsed; }
    r->reserved = 0;
}
void epub_heap_profile_dump(void) {
    wchar_t path[32768]; DWORD length;
    Row *own = local_row(); DWORD previous = own != NULL ? own->reserved : 0; if (own != NULL) own->reserved = 1;
    length = GetEnvironmentVariableW(L"EPUB_ALLOC_PROFILE_PATH", path, 32768);
    if (length == 0 || length >= 32768) { if (own != NULL) own->reserved = previous; return; }
    HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) { if (own != NULL) own->reserved = previous; return; }
    const char header[] = "thread,malloc_calls,calloc_calls,realloc_calls,free_calls,requested_bytes,allocation_seconds,free_seconds\n";
    DWORD written; WriteFile(file, header, (DWORD)(sizeof(header) - 1), &written, NULL);
    LARGE_INTEGER frequency; QueryPerformanceFrequency(&frequency);
    LONG count = 128;
    for (LONG i = 0; i < count; ++i) {
        const Row *r = &rows[i]; char line[512]; if (r->tid == 0) continue;
        int bytes = snprintf(line, sizeof(line), "%lu,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%.9f,%.9f\n",
            (unsigned long)r->tid, r->malloc_calls, r->calloc_calls, r->realloc_calls, r->free_calls,
            r->requested, (double)r->allocation_ticks / frequency.QuadPart, (double)r->free_ticks / frequency.QuadPart);
        if (bytes > 0 && bytes < (int)sizeof(line)) WriteFile(file, line, (DWORD)bytes, &written, NULL);
    }
    CloseHandle(file); if (own != NULL) own->reserved = previous;
}