#include <stddef.h>
#ifdef _WIN32
#include <windows.h>
#else
#define _DEFAULT_SOURCE
#include <sys/mman.h>
#include <unistd.h>
#endif

void *epub_test_codec_guard_open(size_t *length);
void epub_test_codec_guard_close(void *buffer, size_t length);

void *epub_test_codec_guard_open(size_t *length)
{
#ifdef _WIN32
    SYSTEM_INFO information;
    DWORD previous;
    GetSystemInfo(&information);
    const size_t page = (size_t)information.dwPageSize;
    unsigned char *base = VirtualAlloc(NULL, page * 3U, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (base == NULL) return NULL;
    if (!VirtualProtect(base, page, PAGE_NOACCESS, &previous) ||
        !VirtualProtect(base + page * 2U, page, PAGE_NOACCESS, &previous)) {
        (void)VirtualFree(base, 0, MEM_RELEASE);
        return NULL;
    }
#else
    const long reported = sysconf(_SC_PAGESIZE);
    if (reported <= 0) return NULL;
    const size_t page = (size_t)reported;
    unsigned char *base = mmap(NULL, page * 3U, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) return NULL;
    if (mprotect(base, page, PROT_NONE) != 0 || mprotect(base + page * 2U, page, PROT_NONE) != 0) {
        (void)munmap(base, page * 3U);
        return NULL;
    }
#endif
    *length = page;
    return base + page;
}

void epub_test_codec_guard_close(void *buffer, size_t length)
{
    if (buffer == NULL) return;
#ifdef _WIN32
    (void)VirtualFree((unsigned char *)buffer - length, 0, MEM_RELEASE);
#else
    (void)munmap((unsigned char *)buffer - length, length * 3U);
#endif
}
