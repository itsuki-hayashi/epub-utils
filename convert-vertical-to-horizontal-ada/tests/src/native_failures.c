/* Test-only linker interposition. This file is never linked into the release. */
#include <windows.h>
#include <shellapi.h>
#include <stdint.h>
#include <string.h>
#include <wchar.h>
#include <stdatomic.h>
#include <stddef.h>

static int armed_operation = 0;
static unsigned calls_to_skip = 0;
static SRWLOCK fault_lock = SRWLOCK_INIT;
static _Atomic int heap_armed;
static unsigned heap_skip;
void epub_test_heap_failure(unsigned skip);
void epub_test_heap_failure(unsigned skip)
{
    AcquireSRWLockExclusive(&fault_lock);
    heap_skip = skip;
    atomic_store_explicit(&heap_armed, 1, memory_order_relaxed);
    ReleaseSRWLockExclusive(&fault_lock);
}
void epub_test_heap_clear(void);
void epub_test_heap_clear(void)
{
    atomic_store_explicit(&heap_armed, 0, memory_order_relaxed);
}
void *__real_malloc(size_t size);
void *__wrap_malloc(size_t size);
void *__wrap_malloc(size_t size)
{
    if (atomic_load_explicit(&heap_armed, memory_order_relaxed) != 0) {
        BOOL fail = FALSE;
        AcquireSRWLockExclusive(&fault_lock);
        if (atomic_load_explicit(&heap_armed, memory_order_relaxed) != 0) {
            if (heap_skip != 0U) --heap_skip;
            else { atomic_store_explicit(&heap_armed, 0, memory_order_relaxed); fail = TRUE; }
        }
        ReleaseSRWLockExclusive(&fault_lock);
        if (fail) return NULL;
    }
    return __real_malloc(size);
}
static unsigned cpu_api_flags = 0;
static BOOL close_after_write_failure = FALSE;
static BOOL output_close_only = FALSE;
static HANDLE failed_write_handle = INVALID_HANDLE_VALUE;
static HANDLE rolling_event = NULL;
static BOOL rolling_first_released = FALSE;
static BOOL rolling_third_started = FALSE;
static BOOL rolling_timeout = FALSE;

int epub_test_begin_rolling(void);
int epub_test_begin_rolling(void)
{
    HANDLE event = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (event == NULL) return 0;
    AcquireSRWLockExclusive(&fault_lock);
    rolling_event = event;
    rolling_first_released = FALSE;
    rolling_third_started = FALSE;
    rolling_timeout = FALSE;
    ReleaseSRWLockExclusive(&fault_lock);
    return 1;
}

int epub_test_end_rolling(void);
int epub_test_end_rolling(void)
{
    HANDLE event;
    int success;
    AcquireSRWLockExclusive(&fault_lock);
    event = rolling_event;
    rolling_event = NULL;
    success = rolling_third_started && !rolling_timeout;
    ReleaseSRWLockExclusive(&fault_lock);
    if (event != NULL) CloseHandle(event);
    return success;
}

static void rolling_before_open(LPCWSTR path, DWORD access_mode, DWORD creation)
{
    HANDLE event;
    BOOL first = FALSE, third = FALSE;
    const wchar_t *base = wcsrchr(path, L'\\');
    base = base == NULL ? path : base + 1;
    AcquireSRWLockExclusive(&fault_lock);
    event = rolling_event;
    if (event != NULL && creation == OPEN_EXISTING && (access_mode & GENERIC_READ) != 0U) {
        first = wcscmp(base, L"rolling-first.epub") == 0;
        third = wcscmp(base, L"rolling-third.epub") == 0;
        if (third && !rolling_first_released) rolling_third_started = TRUE;
    }
    ReleaseSRWLockExclusive(&fault_lock);
    if (third) SetEvent(event);
    if (first) {
        DWORD waited = WaitForSingleObject(event, 10000U);
        AcquireSRWLockExclusive(&fault_lock);
        rolling_first_released = TRUE;
        if (waited != WAIT_OBJECT_0) rolling_timeout = TRUE;
        ReleaseSRWLockExclusive(&fault_lock);
    }
}

void epub_test_cpu_apis(unsigned flags);
void epub_test_cpu_apis(unsigned flags)
{
    AcquireSRWLockExclusive(&fault_lock);
    cpu_api_flags = flags;
    ReleaseSRWLockExclusive(&fault_lock);
}

static BOOL WINAPI fail_group_set(HANDLE thread, const void *data, void *previous)
{
    (void)thread; (void)data; (void)previous;
    SetLastError(ERROR_ACCESS_DENIED);
    return FALSE;
}

static BOOL WINAPI wrong_group_readback(HANDLE thread, void *data)
{
    (void)thread;
    memset(data, 0, sizeof(GROUP_AFFINITY));
    return TRUE;
}

static BOOL WINAPI wrong_group_identity(HANDLE thread, void *data)
{
    GROUP_AFFINITY *group = data;
    if (!GetThreadGroupAffinity(thread, group)) return FALSE;
    group->Group = (WORD)(group->Group ^ 1U);
    return TRUE;
}

void epub_test_fail_next(int operation, unsigned skip);
void epub_test_fail_next(int operation, unsigned skip)
{
    AcquireSRWLockExclusive(&fault_lock);
    armed_operation = operation;
    calls_to_skip = skip;
    close_after_write_failure = FALSE;
    output_close_only = FALSE;
    failed_write_handle = INVALID_HANDLE_VALUE;
    ReleaseSRWLockExclusive(&fault_lock);
}

void epub_test_fail_output_close(unsigned skip);
void epub_test_fail_output_close(unsigned skip)
{
    epub_test_fail_next(7, skip);
    AcquireSRWLockExclusive(&fault_lock);
    output_close_only = TRUE;
    ReleaseSRWLockExclusive(&fault_lock);
}

void epub_test_fail_write_then_close(void);
void epub_test_fail_write_then_close(void)
{
    AcquireSRWLockExclusive(&fault_lock);
    armed_operation = 4;
    calls_to_skip = 0;
    close_after_write_failure = TRUE;
    output_close_only = FALSE;
    failed_write_handle = INVALID_HANDLE_VALUE;
    ReleaseSRWLockExclusive(&fault_lock);
}

static BOOL should_fail(int operation)
{
    AcquireSRWLockExclusive(&fault_lock);
    if (operation != armed_operation) {
        ReleaseSRWLockExclusive(&fault_lock);
        return FALSE;
    }
    if (calls_to_skip != 0U) {
        --calls_to_skip;
        ReleaseSRWLockExclusive(&fault_lock);
        return FALSE;
    }
    armed_operation = 0;
    ReleaseSRWLockExclusive(&fault_lock);
    SetLastError(ERROR_ACCESS_DENIED);
    return TRUE;
}

#define DECLARE(result, name, parameters) \
    result WINAPI __real_##name parameters; \
    result WINAPI __wrap_##name parameters

DECLARE(FARPROC, GetProcAddress, (HMODULE module, LPCSTR name));
FARPROC WINAPI __wrap_GetProcAddress(HMODULE module, LPCSTR name)
{
    unsigned flags;
    union {
        FARPROC symbol;
        BOOL (WINAPI *set)(HANDLE, const void *, void *);
        BOOL (WINAPI *get)(HANDLE, void *);
    } target;
    AcquireSRWLockShared(&fault_lock);
    flags = cpu_api_flags;
    ReleaseSRWLockShared(&fault_lock);
    if ((uintptr_t)name > UINT16_MAX) {
        if ((flags & 1U) != 0U && strcmp(name, "GetSystemCpuSetInformation") == 0) return NULL;
        if ((flags & 2U) != 0U && strcmp(name, "GetLogicalProcessorInformationEx") == 0) return NULL;
        if ((flags & 4U) != 0U && strcmp(name, "SetThreadGroupAffinity") == 0) {
            target.set = fail_group_set;
            return target.symbol;
        }
        if ((flags & 8U) != 0U && strcmp(name, "GetThreadGroupAffinity") == 0) {
            target.get = wrong_group_readback;
            return target.symbol;
        }
        if ((flags & 16U) != 0U && strcmp(name, "GetThreadGroupAffinity") == 0) {
            target.get = wrong_group_identity;
            return target.symbol;
        }
    }
    return __real_GetProcAddress(module, name);
}

DECLARE(HANDLE, CreateFileW, (LPCWSTR path, DWORD access_mode, DWORD share_mode,
    LPSECURITY_ATTRIBUTES security, DWORD creation, DWORD flags, HANDLE template_file));
HANDLE WINAPI __wrap_CreateFileW(LPCWSTR path, DWORD access_mode, DWORD share_mode,
    LPSECURITY_ATTRIBUTES security, DWORD creation, DWORD flags, HANDLE template_file)
{
    rolling_before_open(path, access_mode, creation);
    if (should_fail(1)) { return INVALID_HANDLE_VALUE; }
    return __real_CreateFileW(path, access_mode, share_mode, security, creation, flags, template_file);
}

DECLARE(BOOL, ReadFile, (HANDLE handle, LPVOID buffer, DWORD count, LPDWORD transferred, LPOVERLAPPED overlap));
BOOL WINAPI __wrap_ReadFile(HANDLE handle, LPVOID buffer, DWORD count, LPDWORD transferred, LPOVERLAPPED overlap)
{
    if (should_fail(2)) { return FALSE; }
    if (should_fail(3)) {
        if (transferred != NULL) { *transferred = 0; }
        return TRUE;
    }
    return __real_ReadFile(handle, buffer, count, transferred, overlap);
}

DECLARE(BOOL, WriteFile, (HANDLE handle, LPCVOID buffer, DWORD count, LPDWORD transferred, LPOVERLAPPED overlap));
BOOL WINAPI __wrap_WriteFile(HANDLE handle, LPCVOID buffer, DWORD count, LPDWORD transferred, LPOVERLAPPED overlap)
{
    if (should_fail(4)) {
        AcquireSRWLockExclusive(&fault_lock);
        if (close_after_write_failure) {
            failed_write_handle = handle;
            close_after_write_failure = FALSE;
        }
        ReleaseSRWLockExclusive(&fault_lock);
        return FALSE;
    }
    if (should_fail(5)) {
        if (transferred != NULL) { *transferred = 0; }
        return TRUE;
    }
    return __real_WriteFile(handle, buffer, count, transferred, overlap);
}

#define BOOL_WRAPPER(name, operation, parameters, arguments) \
    DECLARE(BOOL, name, parameters); \
    BOOL WINAPI __wrap_##name parameters \
    { \
        if (should_fail(operation)) { return FALSE; } \
        return __real_##name arguments; \
    }

BOOL_WRAPPER(FlushFileBuffers, 6, (HANDLE handle), (handle))
DECLARE(BOOL, CloseHandle, (HANDLE handle));
BOOL WINAPI __wrap_CloseHandle(HANDLE handle)
{
    BOOL following;
    const BOOL disk_file = GetFileType(handle) == FILE_TYPE_DISK;
    BOOL eligible = disk_file;
    AcquireSRWLockExclusive(&fault_lock);
    const BOOL output_only = output_close_only;
    following = handle == failed_write_handle;
    if (following) failed_write_handle = INVALID_HANDLE_VALUE;
    ReleaseSRWLockExclusive(&fault_lock);
    if (eligible && output_only) {
        wchar_t path[32768];
        const DWORD length = GetFinalPathNameByHandleW(handle, path, 32768, FILE_NAME_NORMALIZED);
        const wchar_t *base = length > 0U && length < 32768U ? wcsrchr(path, L'\\') : NULL;
        eligible = base != NULL && wcsncmp(base + 1, L".epub-horizontal-", 17) == 0;
    }
    const BOOL result = __real_CloseHandle(handle);
    /* Worker runtime thread/event handles are not conversion file closes. */
    if (following || (eligible && should_fail(7))) {
        SetLastError(ERROR_ACCESS_DENIED);
        return FALSE;
    }
    return result;
}
BOOL_WRAPPER(MoveFileW, 8, (LPCWSTR source, LPCWSTR destination), (source, destination))
BOOL_WRAPPER(DeleteFileW, 9, (LPCWSTR path), (path))
BOOL_WRAPPER(GetFileSizeEx, 10, (HANDLE handle, PLARGE_INTEGER size), (handle, size))

DECLARE(DWORD, GetFileAttributesW, (LPCWSTR path));
DWORD WINAPI __wrap_GetFileAttributesW(LPCWSTR path)
{
    if (should_fail(11)) { return INVALID_FILE_ATTRIBUTES; }
    return __real_GetFileAttributesW(path);
}
BOOL_WRAPPER(CreateDirectoryW, 12, (LPCWSTR path, LPSECURITY_ATTRIBUTES security), (path, security))
DECLARE(HANDLE, FindFirstFileW, (LPCWSTR pattern, LPWIN32_FIND_DATAW data));
HANDLE WINAPI __wrap_FindFirstFileW(LPCWSTR pattern, LPWIN32_FIND_DATAW data)
{
    if (should_fail(13)) { return INVALID_HANDLE_VALUE; }
    return __real_FindFirstFileW(pattern, data);
}
BOOL_WRAPPER(FindNextFileW, 14, (HANDLE handle, LPWIN32_FIND_DATAW data), (handle, data))
DECLARE(BOOL, FindClose, (HANDLE handle));
BOOL WINAPI __wrap_FindClose(HANDLE handle)
{
    const BOOL result = __real_FindClose(handle);
    if (should_fail(15)) { return FALSE; }
    return result;
}
DECLARE(DWORD, GetCurrentDirectoryW, (DWORD capacity, LPWSTR buffer));
DWORD WINAPI __wrap_GetCurrentDirectoryW(DWORD capacity, LPWSTR buffer)
{
    if (should_fail(16)) { return 0; }
    return __real_GetCurrentDirectoryW(capacity, buffer);
}
DECLARE(DWORD, GetFullPathNameW, (LPCWSTR path, DWORD capacity, LPWSTR buffer, LPWSTR *file_part));
DWORD WINAPI __wrap_GetFullPathNameW(LPCWSTR path, DWORD capacity, LPWSTR buffer, LPWSTR *file_part)
{
    if (should_fail(17)) { return 0; }
    return __real_GetFullPathNameW(path, capacity, buffer, file_part);
}
DECLARE(LPWSTR *, CommandLineToArgvW, (LPCWSTR command, int *count));
LPWSTR * WINAPI __wrap_CommandLineToArgvW(LPCWSTR command, int *count)
{
    if (should_fail(18)) { return NULL; }
    return __real_CommandLineToArgvW(command, count);
}
DECLARE(HLOCAL, LocalFree, (HLOCAL pointer));
HLOCAL WINAPI __wrap_LocalFree(HLOCAL pointer)
{
    if (should_fail(19)) {
        (void)__real_LocalFree(pointer);
        SetLastError(ERROR_ACCESS_DENIED);
        return pointer;
    }
    return __real_LocalFree(pointer);
}
BOOL_WRAPPER(SetConsoleOutputCP, 20, (UINT code_page), (code_page))
