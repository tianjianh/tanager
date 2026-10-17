#include <stdio.h>
unsigned long f0(unsigned long),f1(unsigned long),f2(unsigned long),f3(unsigned long),f4(unsigned long),f5(unsigned long),f6(unsigned long),f7(unsigned long);
int main(void){unsigned long r=f0(1)^f1(2)^f2(3)^f3(4)^f4(5)^f5(6)^f6(7)^f7(8);printf("%lu\n",r);return 0;}
