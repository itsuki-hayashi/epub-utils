#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

struct epub_cpu {
    uint32_t group, logical, core, efficiency;
    uint32_t allowed, physical_known, class_known;
};

static char *cpu_list(const char *path)
{
    FILE *file = fopen(path, "r");
    char *line = NULL;
    size_t capacity = 0;
    if (!file) return NULL;
    if (getline(&line, &capacity, file) < 0) { free(line); line = NULL; }
    fclose(file);
    return line;
}

static int list_has(const char *list, unsigned cpu, unsigned *highest)
{
    int found = 0;
    if (!list) return 0;
    while (*list && *list != '\n') {
        char *next;
        unsigned long first = strtoul(list, &next, 10), last = first;
        if (next == list || first >= INT_MAX) return 0;
        list = next;
        if (*list == '-') {
            last = strtoul(list + 1, &next, 10);
            if (next == list + 1 || last < first || last >= INT_MAX) return 0;
            list = next;
        }
        if (highest && last > *highest) *highest = (unsigned)last;
        if (cpu >= first && cpu <= last) found = 1;
        if (*list == ',') ++list;
        else if (*list != '\n' && *list != '\0') return 0;
    }
    return found;
}

unsigned epub_cpu_count(void)
{
    char *list = cpu_list("/sys/devices/system/cpu/possible");
    unsigned highest = 0;
    if (!list) return 0;
    (void)list_has(list, 0, &highest);
    free(list);
    return highest + 1;
}

static int read_number(const char *path, unsigned *value)
{
    FILE *file = fopen(path, "r");
    int ok;
    if (!file) return 0;
    ok = fscanf(file, "%u", value) == 1;
    fclose(file);
    return ok;
}

long long epub_cpu_topology(struct epub_cpu *output, size_t capacity)
{
    unsigned count = epub_cpu_count();
    size_t used = 0, bytes;
    cpu_set_t *allowed;
    char *online, *performance;
    if (!count || capacity < count) return -EINVAL;
    allowed = CPU_ALLOC(count);
    if (!allowed) return -ENOMEM;
    bytes = CPU_ALLOC_SIZE(count);
    CPU_ZERO_S(bytes, allowed);
    if (sched_getaffinity(0, bytes, allowed) != 0) {
        int error = errno;
        CPU_FREE(allowed);
        return -error;
    }
    online = cpu_list("/sys/devices/system/cpu/online");
    performance = cpu_list("/sys/devices/cpu_core/cpus");
    for (unsigned cpu = 0; cpu < count; ++cpu) {
        char path[160];
        unsigned sibling = cpu, efficiency = 0;
        struct stat info;
        struct epub_cpu item = {0};
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%u", cpu);
        if (stat(path, &info) != 0 || !S_ISDIR(info.st_mode)) continue;
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%u/topology/thread_siblings_list", cpu);
        item.physical_known = (uint32_t)read_number(path, &sibling);
        item.logical = cpu;
        item.core = sibling;
        item.allowed = (uint32_t)(CPU_ISSET_S(cpu, bytes, allowed) != 0 &&
                                  (!online || list_has(online, cpu, NULL)));
        if (performance) {
            efficiency = list_has(performance, cpu, NULL) ? 2 : 1;
            item.class_known = 1;
        } else {
            snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%u/cpu_capacity", cpu);
            item.class_known = (uint32_t)read_number(path, &efficiency);
        }
        item.efficiency = efficiency;
        output[used++] = item;
    }
    free(performance);
    free(online);
    CPU_FREE(allowed);
    return (long long)used;
}

int epub_cpu_pin(unsigned cpu)
{
    unsigned count = epub_cpu_count();
    size_t bytes;
    cpu_set_t *mask;
    int result, error;
    if (!count || cpu >= count) return -EINVAL;
    mask = CPU_ALLOC(count);
    if (!mask) return -ENOMEM;
    bytes = CPU_ALLOC_SIZE(count);
    CPU_ZERO_S(bytes, mask);
    CPU_SET_S(cpu, bytes, mask);
    result = sched_setaffinity(0, bytes, mask);
    error = errno;
    if (result == 0) {
        CPU_ZERO_S(bytes, mask);
        result = sched_getaffinity(0, bytes, mask);
        error = errno;
        if (result == 0 && (CPU_COUNT_S(bytes, mask) != 1 || !CPU_ISSET_S(cpu, bytes, mask))) {
            result = -1;
            error = EINVAL;
        }
    }
    CPU_FREE(mask);
    return result == 0 ? 0 : -error;
}
