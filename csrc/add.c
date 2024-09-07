#include "add.h"
#include <stdio.h>

int add(int a, int b) {
  return a + b;
}

int square(int n) {
    return n * n;
}

int n_or_default(int n) {
    if(n) return n;
    return 10;
}

void hello() {
    printf("Hello World!\n");
}
