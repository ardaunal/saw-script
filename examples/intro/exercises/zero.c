#include <stdlib.h>
#include <time.h>
#include <assert.h>

#include <stdint.h>
#include <stdio.h>
#include <stdbool.h>

void zero(uint32_t *x) {
  *x = 0;
}

bool zero_spec(uint32_t x) {
    zero(&x);
    return x == 0;
}
