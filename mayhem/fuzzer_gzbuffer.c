/* Fuzzes the gzFile buffer sizing: zng_gzbuffer() with a fuzzer-chosen size, followed by a write or a read.
 *
 * Input: [0..3] little-endian buffer size, [4] mode, [5..] payload.
 * zng_gzbuffer() accepts any size whose double fits in 32 bits (< 2^31) and gz_buffer_alloc() then
 * derives the in/out buffer sizes from it.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib-ng.h>

#define SMALL_SIZE_MAX (1u << 20)
#define LARGE_SIZE_MIN 0x55555556u /* from here 3 * size no longer fits in 32 bits */
#define LARGE_SIZE_MAX 0x7fffffffu /* last size zng_gzbuffer() accepts */

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t dataLen) {
    char path[1024];
    const char *tmpdir = getenv("TMPDIR");
    uint32_t size;
    int fd, mode;
    gzFile gz;
    uint8_t buf[4096];

    if (dataLen < 5 || dataLen > (1u << 20))
        return -1;

    size = (uint32_t)data[0] | (uint32_t)data[1] << 8 | (uint32_t)data[2] << 16 | (uint32_t)data[3] << 24;
    size &= LARGE_SIZE_MAX;
    /* Sizes between 1 MiB and LARGE_SIZE_MIN only ask the allocator for gigabytes, which libFuzzer's
     * malloc limit rejects whatever the library does; fold them into the range the library must refuse. */
    if (size > SMALL_SIZE_MAX)
        size = LARGE_SIZE_MIN + (size - SMALL_SIZE_MAX) % (LARGE_SIZE_MAX - LARGE_SIZE_MIN + 1);
    mode = data[4] % 3;
    data += 5;
    dataLen -= 5;

    snprintf(path, sizeof(path), "%s/gzbufferXXXXXX", tmpdir && *tmpdir ? tmpdir : "/tmp");
    fd = mkstemp(path);
    if (fd < 0)
        return 0;
    unlink(path);

    if (mode == 0) { /* read: the payload is the (possibly invalid) gzip stream */
        if (write(fd, data, dataLen) != (ssize_t)dataLen || lseek(fd, 0, SEEK_SET) != 0) {
            close(fd);
            return 0;
        }
    }

    gz = zng_gzdopen(fd, mode == 0 ? "rb" : mode == 1 ? "wb" : "wT");
    if (gz == NULL) {
        close(fd);
        return 0;
    }
    zng_gzbuffer(gz, size);
    if (mode == 0) {
        while (zng_gzread(gz, buf, sizeof(buf)) > 0)
            ;
    } else {
        zng_gzwrite(gz, data, (uint32_t)dataLen);
    }
    zng_gzclose(gz);
    return 0;
}
