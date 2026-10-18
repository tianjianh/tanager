#include <stdio.h>
int main(void){unsigned long s=0;for(unsigned long i=0;i<100000000UL;i++)s+=i^(i>>3);printf("%lu\n",s);return 0;}
