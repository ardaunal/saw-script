#include <stdint.h>
#include <stdio.h>
#include <inttypes.h>
#include <math.h>

int8_t minmax(uint64_t *x, uint64_t *y) {
    if (*x > *y) {
        uint64_t tmp = *x;
        *x = *y;
        *y = tmp;
        return 1;
    }
    else {
        return -(*x != *y);
    }
}

int8_t minmax_xor(uint64_t *x, uint64_t *y) {
    if (*x > *y) {
        *x = *x ^ *y;
        *y = *y ^ *x;
        *x = *x ^ *y;
        return 1;
    } else {
        return -(*x != *y);
    }
}


int8_t minmax_ternary(uint64_t *x, uint64_t *y) {
    uint64_t xv = *x, yv = *y;
    *x = xv < yv ? xv : yv;
    *y = xv < yv ? yv : xv;
    return xv < yv ? -1 : xv == yv ? 0 : 1;
}

int main() {
    for (uint64_t i = -5; i < 5; i++) {
        for (uint64_t j = -5; j < 5; j++) {
            uint64_t x = i, y = j;
            int out = minmax(&x, &y);
            printf("%" PRId64 " %" PRId64 " --> %" PRId64 " %" PRId64 " (%i)\n", i, j, x, y, out);
        }
    }
}
