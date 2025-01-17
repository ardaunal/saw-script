#include <stdbool.h>
#include <stdint.h>

void swap(uint32_t *x, uint32_t *y) {
    uint32_t tmp = *x;
    *x = *y;
    *y = tmp;
}

void rotr3(uint32_t *x, uint32_t *y, uint32_t *z) {
    uint32_t tmp = *x;
    *x = *z;
    *y = *x;
    *z = tmp;
}

void rotr3_fixed(uint32_t *x, uint32_t *y, uint32_t *z) {
    uint32_t tmp_x = *x;
    uint32_t tmp_y = *y;
    *x = *z;
    *y = tmp_x;
    *z = tmp_y;
}

bool rotr3_spec(uint32_t x, uint32_t y, uint32_t z) {
    uint32_t a = x, b = y, c = z;
    rotr3_fixed(&a, &b, &c);
    return a == z && b == x && c == y;
}
