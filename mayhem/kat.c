/* Known-answer probe: fixed input -> asserted value, printed for test.sh to diff. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include "zlib-ng.h"

static const uint8_t zstream[] = {
    0x78, 0xda, 0x0b, 0xc9, 0x48, 0x55, 0x28, 0x2c, 0xcd, 0x4c, 0xce, 0x56, 0x48, 0x2a, 0xca, 0x2f,
    0xcf, 0x53, 0x48, 0xcb, 0xaf, 0x50, 0xc8, 0x2a, 0xcd, 0x2d, 0x28, 0x56, 0xc8, 0x2f, 0x4b, 0x2d,
    0x52, 0x28, 0x01, 0x4a, 0xe7, 0x24, 0x56, 0x55, 0x2a, 0xa4, 0xe4, 0xa7, 0xeb, 0x29, 0x84, 0xd0,
    0x4c, 0x31, 0x00, 0xf9, 0x3c, 0x30, 0x76
};

int main(void) {
    const char *nine = "123456789";
    uint8_t out[512], rt[512];
    size_t outlen = sizeof(out), rtlen = sizeof(rt), clen = sizeof(out);
    uint8_t comp[512];
    int i;

    printf("adler32(123456789)=%08x\n", (unsigned)zng_adler32_z(1, (const uint8_t *)nine, 9));
    printf("crc32(123456789)=%08x\n", (unsigned)zng_crc32_z(0, (const uint8_t *)nine, 9));

    if (zng_uncompress(out, &outlen, zstream, sizeof(zstream)) != Z_OK) return 1;
    printf("inflate_len=%u\n", (unsigned)outlen);
    printf("inflate_crc32=%08x\n", (unsigned)zng_crc32_z(0, out, outlen));
    printf("inflate_adler32=%08x\n", (unsigned)zng_adler32_z(1, out, outlen));
    printf("inflate_head=%.19s\n", (const char *)out);

    for (i = 0; i <= 9; i++) {
        clen = sizeof(comp);
        rtlen = sizeof(rt);
        if (zng_compress2(comp, &clen, out, outlen, i) != Z_OK) return 1;
        if (zng_uncompress(rt, &rtlen, comp, clen) != Z_OK) return 1;
        if (rtlen != outlen || memcmp(rt, out, outlen) != 0) return 1;
    }
    printf("roundtrip_levels_0_9=ok\n");
    return 0;
}
