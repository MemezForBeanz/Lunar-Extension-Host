// Platform-independent arithmetic kernel for IUP-compatible box layout.
// Algorithms mirror core.imgui.widgets.boxes and Lunar's min-content shrink rule.
// Lua owns the tree/callbacks. Calls never pump messages, allocate, or enter Lua.
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>

extern "C" {
struct LunarLayoutNode {
    double nw, nh, minw, minh, maxw, maxh, weight, content_min;
    double x, y, w, h;
    uint32_t expand, flags, limits;
};
struct LunarLayoutBox {
    double x, y, w, h, mx, my, gap, total, align;
    uint32_t expand, vertical, homogeneous, shrink;
};
int lunar_layout_abi() { return 1; }
size_t lunar_layout_node_size() { return sizeof(LunarLayoutNode); }
size_t lunar_layout_box_size() { return sizeof(LunarLayoutBox); }

// flags: container=1, fill=2, floating=4, weight present=8.
int lunar_layout_natural(LunarLayoutNode* nodes, size_t count, LunarLayoutBox* box,
                         uint32_t normalize, int expand_override, double* out) {
    if (!nodes || !box || !out || count > 1000000) return 0;
    double mw=0, mh=0, along=0; size_t active=0; uint32_t expand=0;
    for (size_t i=0;i<count;++i) {
        auto& n=nodes[i];
        if (expand_override>=0) n.expand=(uint32_t)expand_override;
        if (n.flags & 4) continue;
        mw=std::max(mw,n.nw); mh=std::max(mh,n.nh); expand|=n.expand; ++active;
    }
    for (size_t i=0;i<count;++i) {
        auto& n=nodes[i]; if (n.flags & 4) continue;
        if (!(n.flags & 2)) {
            if (normalize & 1) n.nw=mw;
            if (normalize & 2) n.nh=mh;
        }
        along+=box->vertical ? n.nh : n.nw;
    }
    if (box->homogeneous) along=(box->vertical ? mh : mw)*active;
    box->total=along+(active ? active-1 : 0)*box->gap+2*(box->vertical ? box->my : box->mx);
    double cross=(box->vertical ? mw : mh)+2*(box->vertical ? box->mx : box->my);
    out[0]=box->vertical ? cross : box->total;
    out[1]=box->vertical ? box->total : cross;
    out[2]=(double)expand;
    return 1;
}

static void current(const LunarLayoutNode& n, bool shrink, double w, double h, double& cw, double& ch) {
    if ((n.flags & 1) && !shrink) { w=std::max(w,n.nw); h=std::max(h,n.nh); }
    bool ew=(n.expand & (0x0c|0x20))!=0, eh=(n.expand & (0x03|0x10))!=0;
    cw=ew ? w : n.nw; ch=eh ? h : n.nh;
    if (ew || eh) {
        if (n.limits & 1) cw=std::max(cw,n.minw);
        if (n.limits & 2) ch=std::max(ch,n.minh);
        if (n.limits & 4) cw=std::min(cw,n.maxw);
        if (n.limits & 8) ch=std::min(ch,n.maxh);
    }
    cw=std::max(0.0,std::floor(cw)); ch=std::max(0.0,std::floor(ch));
}

int lunar_layout_place(LunarLayoutNode* nodes, size_t count, const LunarLayoutBox* b) {
    if (!nodes || !b || count > 1000000) return 0;
    uint32_t one=b->vertical ? 2 : 8, zero=b->vertical ? 1 : 4;
    size_t active=0, count_one=0, count_zero=0;
    double current_along=b->vertical ? b->h : b->w, slack=0;
    for (size_t i=0;i<count;++i) {
        const auto& n=nodes[i]; if (n.flags & 4) continue;
        ++active; if (n.expand & one) ++count_one; if (n.expand & zero) ++count_zero;
    }
    double homogeneous=active ? std::max(0.0,std::floor((current_along-(active-1)*b->gap-2*(b->vertical ? b->my : b->mx))/active)) : 0;
    double empty_one=0, empty_zero=0;
    if (b->expand & one) {
        if (count_one) empty_one=std::max(0.0,std::floor((current_along-b->total)/count_one));
    } else if ((b->expand & zero) && count_zero) {
        empty_zero=std::max(0.0,std::floor((current_along-b->total)/count_zero));
    }
    double deficit=b->shrink ? b->total-current_along : 0;
    if (deficit>0 && !b->homogeneous) {
        for (size_t i=0;i<count;++i) {
            const auto& n=nodes[i];
            if (!(n.flags & 4) && (n.expand & one)) slack+=(b->vertical ? n.nh : n.nw)-n.content_min;
        }
    }
    double cross=std::max(0.0,(b->vertical ? b->w : b->h)-2*(b->vertical ? b->mx : b->my));
    double pos=b->vertical ? b->y+b->my : b->x+b->mx;
    double cross0=b->vertical ? b->x+b->mx : b->y+b->my;
    for (size_t i=0;i<count;++i) {
        auto& n=nodes[i]; if (n.flags & 4) continue;
        double along=homogeneous;
        if (!b->homogeneous) {
            double extra=(n.expand & one) ? empty_one : (n.expand & zero) ? empty_zero : 0;
            if (n.flags & 8) extra=std::floor(extra*n.weight+0.5);
            if (deficit>0 && slack>0 && (n.expand & one)) {
                double available=(b->vertical ? n.nh : n.nw)-n.content_min;
                extra=-std::min(available,std::floor(deficit*available/slack));
            }
            along=(b->vertical ? n.nh : n.nw)+extra;
        }
        current(n,b->shrink!=0,b->vertical ? cross : along,b->vertical ? along : cross,n.w,n.h);
        double offset=std::max(0.0,std::floor((cross-(b->vertical ? n.w : n.h))*b->align));
        n.x=b->vertical ? cross0+offset : pos; n.y=b->vertical ? pos : cross0+offset;
        pos+=(b->homogeneous ? homogeneous : b->vertical ? n.h : n.w)+b->gap;
    }
    return 1;
}
} // extern C
