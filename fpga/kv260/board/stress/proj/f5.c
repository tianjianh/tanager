unsigned long f5(unsigned long x){unsigned long s=x;for(int i=0;i<2000000;i++)s=s*6364136223846793005UL+11UL;return s^(s>>29);}
