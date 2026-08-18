/* Минимальная замена libstdc++: QuickNES не использует ни исключений, ни
   контейнеров - ему нужны только выделение памяти и заглушка чисто виртуального
   вызова. Так мы не тащим в образ библиотеку почти на мегабайт. */
#include <stdlib.h>

void* operator new(unsigned int n)        { return malloc(n ? n : 1); }
void* operator new[](unsigned int n)      { return malloc(n ? n : 1); }
void  operator delete(void* p)            { free(p); }
void  operator delete[](void* p)          { free(p); }
void  operator delete(void* p, unsigned int)   { free(p); }
void  operator delete[](void* p, unsigned int) { free(p); }

extern "C" void __cxa_pure_virtual(void) { abort(); }
