/**
 * Copyright (c) 2023 Cyber (See LICENSE)
 */

// Build: clang -shared -o macos_lib.dylib macos_lib.c -arch arm64 -arch x86_64

#include <string.h>
#include <stdlib.h>

#define bool _Bool
#define int64_t long long
#define uint64_t unsigned long long
#define int8_t signed char
#define uint8_t unsigned char
#define int16_t short
#define uint16_t unsigned short
#define uint32_t unsigned int

int testAdd(int a, int b) {
    return a + b;
}
int8_t testI8(int8_t n) {
    return n;
}
uint8_t testU8(uint8_t n) {
    return n;
}
int16_t testI16(int16_t n) {
    return n;
}
uint16_t testU16(uint16_t n) {
    return n;
}
int testI32(int n) {
    return n;
}
uint32_t testU32(uint32_t n) {
    return n;
}
int64_t testI64(int64_t n) {
    return n;
}
uint64_t testU64(uint64_t n) {
    return n;
}
size_t testUSize(size_t n) {
    return n;
}
float testF32(float n) {
    return n;
}
double testF64(double n) {
    return n;
}
char buf[1024];
char* testCharPtrZ(char* ptr) {
    strcpy(buf, ptr);
    return &buf[0];
}
char* testDupeCharPtrZ(char* ptr) {
    strcpy(buf, ptr);
    free(ptr);
    return &buf[0];
}
void* testPtr(void* ptr) {
    return ptr;
}
void testVoid() {
}
bool testBool(bool b) {
    return b;
}

typedef struct MyObject{
    double a;
    int b;
    char* c;
    bool d;
} MyObject;

MyObject testObject(MyObject o) {
    strcpy(buf, o.c);
    MyObject new = {
        .a = o.a,
        .b = o.b,
        .c = (char*)&buf,
        .d = o.d,
    };
    return new;
}

MyObject temp;
MyObject* testRetObjectPtr(MyObject o) {
    strcpy(buf, o.c);
    temp.a = o.a;
    temp.b = o.b;
    temp.c = (char*)&buf;
    temp.d = o.d;
    return &temp;
}