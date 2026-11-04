#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <sys/ioctl.h>
#include <linux/fs.h>
#include <unistd.h>

/* Return negative errno values; no Ada code depends on libc struct layouts. */
int epub_open(const char *path, int exclusive)
{
    int fd;
    do {
        fd = open(path, exclusive ? O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC |
                  O_NOFOLLOW : O_RDONLY | O_CLOEXEC, 0666);
    } while (fd < 0 && errno == EINTR);
    return fd < 0 ? -errno : fd;
}

int epub_close(int fd) { return close(fd) == 0 ? 0 : -errno; }
int epub_seek(int fd, long long offset)
{
    off_t result;
    do { result = lseek(fd, (off_t)offset, SEEK_SET); }
    while (result < 0 && errno == EINTR);
    return result < 0 ? -errno : 0;
}
int epub_flush(int fd)
{
    int result;
    do { result = fsync(fd); } while (result < 0 && errno == EINTR);
    return result == 0 ? 0 : -errno;
}
long long epub_size(int fd)
{
    struct stat info;
    if (fstat(fd, &info) != 0) return -errno;
    if (!S_ISREG(info.st_mode)) return -EINVAL;
    return (long long)info.st_size;
}
long long epub_read(int fd, void *buffer, size_t count)
{
    ssize_t result;
    do { result = read(fd, buffer, count); } while (result < 0 && errno == EINTR);
    return result < 0 ? -errno : (long long)result;
}
long long epub_write(int fd, const void *buffer, size_t count)
{
    ssize_t result;
    do { result = write(fd, buffer, count); } while (result < 0 && errno == EINTR);
    return result < 0 ? -errno : (long long)result;
}
int epub_kind(const char *path, int follow)
{
    struct stat info;
    if ((follow ? stat(path, &info) : lstat(path, &info)) != 0)
        return errno == ENOENT || errno == ENOTDIR ? 0 : -errno;
    if (S_ISLNK(info.st_mode)) return 3;
    if (S_ISDIR(info.st_mode)) return 2;
    return S_ISREG(info.st_mode) ? 1 : 4;
}
int epub_remove(const char *path)
{
    if (unlink(path) == 0 || errno == ENOENT) return 0;
    return -errno;
}
int epub_publish(const char *source, const char *destination)
{
    /* Linux renameat2 atomically refuses replacement, including dangling links. */
    if (renameat2(AT_FDCWD, source, AT_FDCWD, destination, RENAME_NOREPLACE) == 0)
        return 0;
    if (errno != EINVAL && errno != ENOSYS && errno != EOPNOTSUPP)
        return -errno;
    /* DrvFS does not support RENAME_NOREPLACE. A hard link also publishes the
       complete verified inode atomically and fails if any target exists.
       Never fall back to a replacing rename or to a nonexclusive copy. */
    if (link(source, destination) != 0) return -errno;
    return unlink(source) == 0 ? 0 : -errno;
}
int epub_pid(void) { return (int)getpid(); }

int epub_directory_identity(const char *path, uint64_t *device,
                            uint64_t *inode, int *case_sensitive)
{
    struct stat info;
    struct statfs fs;
    int fd, flags = 0;
    if (stat(path, &info) != 0) return -errno;
    if (!S_ISDIR(info.st_mode)) return -ENOTDIR;
    *device = (uint64_t)info.st_dev;
    *inode = (uint64_t)info.st_ino;
    *case_sensitive = 0;
    if (statfs(path, &fs) != 0) return 0;
    /* For unknown or remote filesystems, conservatively serialize publication
       within this directory instead of guessing at its filename collation. */
    /* XFS may use its legacy ASCII-CI format. Treat it conservatively.
       tmpfs, like ext4, can have casefold directories; never infer lookup
       behavior from the filesystem magic alone. */
    if ((unsigned long)fs.f_type == 0xef53UL ||    /* ext4 */
        (unsigned long)fs.f_type == 0x9123683eUL || /* Btrfs */
        (unsigned long)fs.f_type == 0x01021994UL) { /* tmpfs */
        fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (fd >= 0) {
            if (ioctl(fd, FS_IOC_GETFLAGS, &flags) == 0 &&
                (flags & FS_CASEFOLD_FL) == 0) *case_sensitive = 1;
            if (close(fd) != 0) return -errno;
        }
    }
    return 0;
}
