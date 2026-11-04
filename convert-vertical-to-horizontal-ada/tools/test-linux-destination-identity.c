/* Standalone native-boundary tests; never linked into the application. */
#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <linux/fs.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/ioctl.h>

int epub_directory_identity(const char *, uint64_t *, uint64_t *, int *);

static long filesystem;
static int attributes, flags_known, open_allowed, close_allowed;
static int stat_allowed = 1, statfs_allowed = 1, is_directory = 1;
static unsigned opened, checks;

int __wrap_stat(const char *path, struct stat *info);
int __wrap_stat(const char *path, struct stat *info)
{
    (void)path;
    if (!stat_allowed) { errno = EACCES; return -1; }
    memset(info, 0, sizeof(*info));
    info->st_mode = is_directory ? S_IFDIR : S_IFREG;
    info->st_dev = 11;
    info->st_ino = 22;
    return 0;
}

int __wrap_statfs(const char *path, struct statfs *info);
int __wrap_statfs(const char *path, struct statfs *info)
{
    (void)path;
    if (!statfs_allowed) { errno = EIO; return -1; }
    memset(info, 0, sizeof(*info));
    info->f_type = filesystem;
    return 0;
}

int __wrap_open(const char *path, int flags, ...);
int __wrap_open(const char *path, int flags, ...)
{
    (void)path; (void)flags;
    ++opened;
    if (!open_allowed) { errno = EACCES; return -1; }
    return 7;
}

int __wrap_ioctl(int fd, unsigned long request, ...);
int __wrap_ioctl(int fd, unsigned long request, ...)
{
    va_list args;
    int *value;
    assert(fd == 7 && request == FS_IOC_GETFLAGS);
    if (!flags_known) { errno = EOPNOTSUPP; return -1; }
    va_start(args, request);
    value = va_arg(args, int *);
    va_end(args);
    *value = attributes;
    return 0;
}

int __wrap_close(int fd);
int __wrap_close(int fd)
{
    assert(fd == 7);
    if (!close_allowed) { errno = EIO; return -1; }
    return 0;
}

static void check(int expected_status, int expected_sensitive)
{
    uint64_t device = 0, inode = 0;
    int sensitive = -1;
    int status = epub_directory_identity("synthetic", &device, &inode, &sensitive);
    assert(status == expected_status);
    if (status == 0) {
        assert(device == 11 && inode == 22);
        assert(sensitive == expected_sensitive);
    }
    ++checks;
}

int main(void)
{
    const long flag_filesystems[] = {0xef53L, 0x9123683eL, 0x01021994L};
    open_allowed = close_allowed = flags_known = 1;
    for (unsigned i = 0; i < sizeof(flag_filesystems) / sizeof(flag_filesystems[0]); ++i) {
        filesystem = flag_filesystems[i];
        attributes = 0; check(0, 1);
        attributes = FS_CASEFOLD_FL; check(0, 0);
        flags_known = 0; check(0, 0); flags_known = 1;
        open_allowed = 0; check(0, 0); open_allowed = 1;
    }
    filesystem = 0x58465342L; /* XFS can use ASCII-CI; magic is insufficient. */
    opened = 0;
    attributes = 0; check(0, 0);
    attributes = FS_CASEFOLD_FL; check(0, 0);
    assert(opened == 0);
    filesystem = 0x1234L; check(0, 0);
    statfs_allowed = 0; check(0, 0); statfs_allowed = 1;
    is_directory = 0; check(-ENOTDIR, 0); is_directory = 1;
    stat_allowed = 0; check(-EACCES, 0); stat_allowed = 1;
    filesystem = 0xef53L; attributes = 0; close_allowed = 0; check(-EIO, 0);
    printf("{\"native_destination_identity_cases\":%u,\"result\":\"PASS\"}\n", checks);
    return 0;
}
