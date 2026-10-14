#pragma once
#include <cstdint>
#include <array>
using u32=uint32_t;
template<typename T> constexpr unsigned BIT(T value,int bit){return (uint64_t(value)>>bit)&1;}
constexpr uint32_t rotl_32(uint32_t v,unsigned r){return r ? ((v<<r)|(v>>(32-r))) : v;}
template<unsigned N,typename T,typename... B> constexpr uint32_t bitswap(T value,B... indices) {
    static_assert(sizeof...(indices)==N);
    std::array<int,N> order{indices...};
    uint32_t out=0;
    for(unsigned i=0;i<N;++i)out=(out<<1)|BIT(value,order[i]);
    return out;
}
