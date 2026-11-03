/* Test-only linker interposition. This file is never linked into the release. */
#include <windows.h>
#include <shellapi.h>

static int armed_operation = 0;
static unsigned calls_to_skip = 0;

void epub_test_fail_next(int operation, unsigned skip);
void epub_test_fail_next(int operation, unsigned skip)
{
    armed_operation = operation;
    calls_to_skip = skip;
}

static BOOL should_fail(int operation)
{
    if (operation != armed_operation) {
        return FALSE;
    }
    if (calls_to_skip != 0U) {
        --calls_to_skip;
        return FALSE;
    }
    armed_operation = 0;
    SetLastError(ERROR_ACCESS_DENIED);
    return TRUE;
}

#define DECLARE(result, name, parameters) \
    result WINAPI __real_##name parameters; \
    result WINAPI __wrap_##name parameters

DECLARE(HANDLE, CreateFileW, (LPCWSTR path, DWORD access_mode, DWORD share_mode,
    LPSECURITY_ATTRIBUTES security, DWORD creation, DWORD flags, HANDLE template_file));
HANDLE WINAPI __wrap_CreateFileW(LPCWSTR path, DWORD access_mode, DWORD share_mode,
    LPSECURITY_ATTRIBUTES security, DWORD creation, DWORD flags, HANDLE template_file)
{
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
    if (should_fail(4)) { return FALSE; }
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
    const BOOL result = __real_CloseHandle(handle);
    if (should_fail(7)) { return FALSE; }
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
