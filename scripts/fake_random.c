#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdarg.h>

// Seed for the pseudo-random number generator
// Should be stable across different runs
static unsigned int fake_random_seed = 0;
// Fake file descriptor for /dev/random and /dev/urandom
static int fake_random_fd = -1;
static int random_ref_cnt = 0;

// Function pointer types for the original functions
typedef int (*orig_open_f_type)(const char *pathname, int flags, ...);
typedef ssize_t (*orig_read_f_type)(int fd, void *buf, size_t count);
typedef int (*orig_close_f_type)(int fd);

// Static variables to hold the original function pointers
static orig_open_f_type orig_open = NULL;
static orig_read_f_type orig_read = NULL;
static orig_close_f_type orig_close = NULL;

// Function to check DEBUG environment variable and print debug information
static void debug(const char *format, ...) {
    #ifdef FAKE_RANDOM_DEBUG
        va_list args;
        va_start(args, format);
        vfprintf(stdout, format, args);
        va_end(args);
    #endif
}

static void error(const char *format, ...) {
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

int open(const char *pathname, int oflag, ...)
{
    debug("[FAKE_RANDOM] open(%s, %d)\n", pathname, oflag);
    if (orig_open == NULL)
    {
        orig_open = (orig_open_f_type)dlsym(RTLD_NEXT, "open");
        if (orig_open == NULL)
        {
            error("[FAKE_RANDOM] Error in dlsym: %s\n", dlerror());
            return -1;
        }
    }

    if (getenv("FAKE_RANDOM") != NULL && (strcmp(pathname, "/dev/random") == 0 || strcmp(pathname, "/dev/urandom") == 0))
    {
        // Return a fake file descriptor
        if (random_ref_cnt == 0)
        {
            random_ref_cnt += 1;
            if (__OPEN_NEEDS_MODE(oflag))
            {
                int mode = 0;
                va_list arg;
                va_start(arg, oflag);
                mode = va_arg(arg, int);
                va_end(arg);
                fake_random_fd = orig_open(pathname, oflag, mode);
            }
            else
            {
                fake_random_fd = orig_open(pathname, oflag);
            }
        }

        debug("[FAKE_RANDOM] fake_random_fd: %d\n", fake_random_fd);
        debug("[FAKE_RANDOM] fake_random_seed: %u\n", fake_random_seed);

        return fake_random_fd;
    }

    if (__OPEN_NEEDS_MODE(oflag))
    {
        int mode = 0;
        va_list arg;
        va_start(arg, oflag);
        mode = va_arg(arg, int);
        va_end(arg);
        return orig_open(pathname, oflag, mode);
    }
    else
    {
        return orig_open(pathname, oflag);
    }
}

ssize_t read(int fd, void *buf, size_t count)
{
    debug("[FAKE_RANDOM] read(%d, %p, %zu)\n", fd, buf, count);
    if (orig_read == NULL)
    {
        orig_read = (orig_read_f_type)dlsym(RTLD_NEXT, "read");
        if (orig_read == NULL)
        {
            error("[FAKE_RANDOM] Error in dlsym: %s\n", dlerror());
            return -1;
        }
    }

    if (getenv("FAKE_RANDOM") != NULL && fd == fake_random_fd)
    {
        debug("[FAKE_RANDOM] fake_random_seed: %u\n", fake_random_seed);
        debug("[FAKE_RANDOM] output buf: ");
        for (size_t i = 0; i < count; i++)
        {
            ((unsigned char *)buf)[i] = rand_r(&fake_random_seed) % 256;
            debug("%02x", ((unsigned char *)buf)[i]);
        }
        debug("\n");
        return count;
    }

    return orig_read(fd, buf, count);
}

int close(int fd)
{
    debug("close(%d)\n", fd);
    if (orig_close == NULL)
    {
        orig_close = (orig_close_f_type)dlsym(RTLD_NEXT, "close");
        if (orig_close == NULL)
        {
            error("Error in dlsym: %s\n", dlerror());
            return -1;
        }
    }
    if (getenv("FAKE_RANDOM") != NULL && fake_random_fd == fd)
    {
        random_ref_cnt -= 1;
        if (random_ref_cnt == 0)
        {
            return orig_close(fd);
        }
        return 0;
    }

    return orig_close(fd);
}
