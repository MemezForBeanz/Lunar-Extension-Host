#include "../src/cpp/lunar_texture_backup.h"
#include <cassert>
#include <cstdio>
#include <random>

int main() {
    std::mt19937 rng(72341);
    for(int mode=0;mode<4;++mode)for(int count=0;count<150;++count) {
        const size_t bytes=(size_t)count*count*4;
        std::vector<unsigned char> pixels(bytes);
        for(size_t i=0;i<bytes;++i)pixels[i]=mode==0 ? 0 : mode==1 ? (unsigned char)(i%4)
            : mode==2 ? (unsigned char)rng() : (unsigned char)((i/128)%7);
        bool packed=false;auto stored=lunar_backup::pack(pixels.data(),bytes,packed);
        if(packed) { std::vector<unsigned char> out;assert(lunar_backup::unpack(stored,bytes,out));assert(out==pixels); }
        else assert(stored==pixels);
        assert(stored.size()<=pixels.size());
    }
    std::vector<unsigned char> out;
    assert(!lunar_backup::unpack({1},4,out));
    assert(!lunar_backup::unpack({1,0,0,128},4,out));
    assert(!lunar_backup::unpack({0,0,0,0},4,out));
    assert(!lunar_backup::unpack({255,255,255,127,1,2,3,4},4,out));
    std::puts("600 texture backup roundtrips and malformed inputs passed");
}
