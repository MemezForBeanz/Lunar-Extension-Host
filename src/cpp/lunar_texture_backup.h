// Lossless recovery storage. GPU uploads stay RGBA; only the CPU backup is packed.
#pragma once
#include <cstdint>
#include <cstring>
#include <vector>

namespace lunar_backup {
inline bool same(const unsigned char *a, const unsigned char *b) { return std::memcmp(a,b,4)==0; }
inline void word(std::vector<unsigned char> &out, uint32_t n) {
    for (int k=0;k<4;++k) out.push_back((unsigned char)(n>>(k*8)));
}
inline std::vector<unsigned char> pack(const unsigned char *data, size_t bytes, bool &packed) {
    packed=false;
    if (!bytes) return {};
    if (bytes<256 || bytes%4) return {data,data+bytes};
    const size_t count=bytes/4;
    std::vector<unsigned char> out;
    out.reserve(bytes/4);
    size_t i=0;
    while (i<count) {
        size_t run=1;
        while (i+run<count && run<0x7fffffff && same(data+i*4,data+(i+run)*4)) ++run;
        if (run>=3) { word(out,0x80000000u|(uint32_t)run);out.insert(out.end(),data+i*4,data+i*4+4);i+=run; }
        else {
            const size_t first=i; i+=run;
            while (i<count && i-first<0x7fffffff) {
                if (i+2<count && same(data+i*4,data+(i+1)*4) && same(data+i*4,data+(i+2)*4)) break;
                ++i;
            }
            word(out,(uint32_t)(i-first));out.insert(out.end(),data+first*4,data+i*4);
        }
        // Incompressible content never needs a second full encoded allocation.
        if (out.size()>=bytes-bytes/8) return {data,data+bytes};
    }
    packed=true; out.shrink_to_fit();return out;
}
inline bool unpack(const std::vector<unsigned char> &data, size_t bytes, std::vector<unsigned char> &out) {
    out.clear();out.reserve(bytes);
    size_t i=0;
    while (i<data.size()) {
        if (data.size()-i<4) return false;
        uint32_t n=0;for(int k=0;k<4;++k)n|=(uint32_t)data[i++]<<(k*8);
        const size_t count=n&0x7fffffffu;
        if (!count || count>(bytes-out.size())/4) return false;
        if (n&0x80000000u) {
            if(data.size()-i<4)return false;
            const size_t start=out.size();out.resize(start+count*4);
            for(size_t k=0;k<count;++k)std::memcpy(out.data()+start+k*4,data.data()+i,4);
            i+=4;
        } else {
            if(count>(data.size()-i)/4)return false;
            out.insert(out.end(),data.begin()+i,data.begin()+i+count*4);i+=count*4;
        }
    }
    return out.size()==bytes;
}
}
