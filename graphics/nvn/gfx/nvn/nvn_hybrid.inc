// 混合管线：首遇没有精确管线的绘制不等编译器（照上游参考实现（MIT）hybrid pipelines / dmsh_pull，S2Arm 改写；nvn_mtl.m 内含）。
//   顶点着色器另有拉取式库 <key>_bp（Pull.cs）：入口不带 [[stage_in]]，从槽 16 的布局块（pull_layout，按笔填）自己读顶点流，位级等同 Metal 顶点抓取。
//   用它的管线没有顶点描述，一对着色器的所有顶点布局共用一条「拉取基础管线」：颜色状态留空（Unspecialized），用 Metal 4 编译器后台建一次；
//   之后每种颜色状态按本笔特化（newRenderPipelineStateBySpecializationWithDescriptor，不进着色器编译）。精确管线不在的首遇（不论能不能跳）改用它先画，
//   精确管线照旧后台编（pso_pend_kick），编好后下一笔起换回精确的。拉取基础管线还没建好就照旧走跳过 / 现编等待，并在后台建它，下一次首遇就用上。
//   只在 Metal 4 后端（Metal 4 编译器的特化）；片元只用 main0 本身（带透明测试 / 输出类型 / 采样模拟常量的变体先不走）；合并遍、可读瓦片、顶点补齐变体、
//   写层顶点、曲面细分、变换反馈不走。DM_PSO_HYBRID=0 关
enum { PULL_SLOT = 16 };   // = Pull.cs SLOT：顶点缓冲槽 VB_SLOT(0)，没有顶点描述的管线不用它
_Static_assert(PULL_SLOT == VB_SLOT(0), "Pull.cs SLOT is the first vertex buffer slot (pull_refl_ok)");
typedef struct { uint64_t base; uint32_t stride, divisor; } pull_stream;
typedef struct { pull_stream s[16]; uint32_t attr[32]; } pull_layout;   // = Pull.cs dm_vlayout（流基址 / 步长 / 实例除数；属性字 = va_st 位段：格式 8、偏移 19、流 5）
_Static_assert(sizeof(pull_layout) == 384, "Pull.cs dm_vlayout");
_Static_assert(sizeof(va_st) == 4, "pull_layout attr word");

static int hybrid_on(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("DM_PSO_HYBRID"); int os26 = 0; if (@available(macOS 26.0, iOS 26.0, *)) os26 = 1;
        v = os26 && !g_m3 && !(e && !strcmp(e, "0"));
        MLOG("hybrid pipelines %s", v ? "on: a first use that cannot be skipped draws with its pair's pulling pipeline while its own compiles" : "off: a first use that cannot be skipped waits for its pipeline"); }
    return v;
}
static os_unfair_lock g_pull_lock = OS_UNFAIR_LOCK_INIT;
static _Atomic uint64_t g_pull_loaded, g_pull_failed;
static id<MTLFunction> pull_fn(NvShader *vs) {   // 拉取入口（与 vs->ventry 同名：main0 / main0_z），第一次要时载入；不可用是定局（这对的首遇照旧等）
    if (!vs || !vs->has_pull || vs->layer_out) return nil;
    os_unfair_lock_lock(&g_pull_lock);
    if (!vs->pfn_state) {
        vs->pfn_state = 2;
        size_t kl = strlen(vs->key); NSString *path = [NSString stringWithFormat:@"%.*s_bp", (int)(kl > 2 ? kl - 2 : kl), vs->key];
        // _bp 逐键编（Build.cs PullBuild），不进合批库：入口就叫 main0 / main0_z，不带 _b 合批的 fn_prefix（fnn）
        NSError *e = nil; id<MTLLibrary> lib = lib_from_pack(path.UTF8String, &e); id<MTLFunction> f = lib_entry(lib, vs->ventry);
        const char *why = !lib ? "no library" : !f ? "no entry point" : NULL;
        if (f && vs->rf.nb && argcheck_on() && [f newArgumentEncoderWithBufferIndex:vs->rf.abi].encodedLength != vs->arg_len) { why = "its argument buffer differs from the base library's"; f = nil; }
        if (f) { vs->pfn = f; vs->pull_lib = lib; vs->pfn_state = 1; g_pull_loaded++; }
        else if (g_pull_failed++ < 8) MLOG("【红】 pulling library of %s not usable (%s%s%s): its first uses wait for their pipelines", vs->key, why, e ? ": " : "", e ? e.localizedDescription.UTF8String : "");
    }
    id<MTLFunction> f = vs->pfn_state == 1 ? vs->pfn : nil;
    os_unfair_lock_unlock(&g_pull_lock);
    return f;
}

// 本笔的布局块：流基址按 4 字节对齐、低位并进属性偏移（dm_fetch 在元素对齐时按整字读）；没落在任何池里的流，它的属性读 0（同零缓冲）。只填本笔顶点着色器读的流
static void pull_layout_fill(pull_layout *L, NvShader *vs) {
    memset(L, 0, sizeof *L); uint32_t lo[16] = {0};
    for (int st = 0; st < 16; st++) {
        uint64_t addr = S.vbuf[st].address, gpu, pav; void *mb; uint64_t mo;
        if (!addr || !gpu_addr_want(addr, 1, S.vbuf[st].size, &mb, &mo, &gpu, &pav)) continue;
        L->s[st].base = gpu & ~3ull; lo[st] = (uint32_t)(gpu & 3); L->s[st].stride = S.stream[st].stride; L->s[st].divisor = S.stream[st].divisor;
    }
    (void)vs;
    for (int a = 0; a < 16 && a < S.nattr; a++) {
        va_st v = S.attr[a];
        if (!v.fmt || v.stream >= 16 || !L->s[v.stream].base) continue;
        v.offset += lo[v.stream]; memcpy(&L->attr[a], &v, 4);
    }
}
static void pull_bind(id en, NvShader *vs) {   // en：Metal 4 渲染编码器（变量用 id，tools/mtl4_baseline.txt 棘轮）
    pull_layout L; pull_layout_fill(&L, vs);
    __unsafe_unretained id<MTLBuffer> ab; size_t off = arena_alloc_u(sizeof L, &ab);
    memcpy((uint8_t *)ab.contents + off, &L, sizeof L);
    enc_r_vbuf(en, PULL_SLOT, ab.gpuAddress + off);
}

// 拉取基础管线：按（拉取入口、片元函数、样本数、alpha 覆盖、拓扑类）认；颜色状态留空。后台串行队列建，建过的（成败）不再建
typedef struct { const void *vf, *ff; uint32_t samples, a2c, a21, topo; } pbase_key;
static nvn_hmap g_pbase = {.klen = sizeof(pbase_key)};   // → id<MTLRenderPipelineState>，失败 NSNull
static nvn_hmap g_pso_hy = {.klen = sizeof(pso_key)};   // 特化好的拉取管线，按它顶替的精确管线的键（提交线程）
static os_unfair_lock g_pbase_lock = OS_UNFAIR_LOCK_INIT;
static id g_hy_comp;   // Metal 4 编译器（m4_compiler）
static int g_pso_pull;   // pso_get_ 这次返回的是拉取管线（绘制改绑布局块，不做 CPU 顶点转换）
static _Atomic uint64_t g_hy_draws, g_hy_made, g_hy_none, g_hy_kicked, g_hy_bases, g_hy_base_fail, g_hy_spec_ns;
static id hybrid_comp(void) API_AVAILABLE(macos(26.0), ios(26.0)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_hy_comp = m4_compiler("hybrid pipelines (first uses wait for their pipelines)"); });
    return g_hy_comp;
}
// 精确管线的描述 d → 拉取版的 Metal 4 描述：顶点换拉取入口、不带顶点描述；unspec：颜色状态留空（基础管线）
static id pull_desc4(MTLRenderPipelineDescriptor *d, NvShader *vs, NvShader *fs, int unspec) API_AVAILABLE(macos(26.0), ios(26.0)) {
    return m4_render_desc(d, spec_probe_fn(vs->pull_lib, vs->pfn), spec_probe_fn(fs->plib, fs->fn), nil, unspec);
}
// 这一笔能不能用拉取管线：Metal 4、普通绘制（vs 是 sh[0]、不是合并遍 / 可读瓦片 / 诊断片元），精确描述的顶点是 vs->fn 或影子输入入口（拉取版两者都替），片元是 fs->fn 本身
static int hybrid_fits(MTLRenderPipelineDescriptor *d, NvShader *vs, NvShader *fs) {
    return d && fs && fs->plib && d.rasterizationEnabled && d.fragmentFunction == fs->fn && (d.vertexFunction == vs->fn || (vs->vfn && d.vertexFunction == vs->vfn)) && pull_fn(vs);
}
// 顶替 k 的拉取管线：特化过就直接给；基础管线在 → 按本笔颜色状态特化（提交线程，不进着色器编译）；不在 → 后台建、这次给 nil（照旧等）
static __unsafe_unretained id<MTLRenderPipelineState> hybrid_get(const pso_key *k, NvShader *vs, NvShader *fs) {
    __unsafe_unretained id h = hm_get_id(&g_pso_hy, k);
    if (h) return h == (id)NSNull.null ? nil : h;   // NSNull：特化失败过，这个键不再试
    if (@available(macOS 26.0, iOS 26.0, *)) {
        if (!hybrid_comp()) return nil;
        MTLRenderPipelineDescriptor *d = pso_desc(k, vs, fs, nil, 0);
        if (!hybrid_fits(d, vs, fs)) return nil;
        pbase_key bk; memset(&bk, 0, sizeof bk); bk.vf = (__bridge const void *)vs->pfn; bk.ff = (__bridge const void *)fs->fn;
        bk.samples = (uint32_t)d.rasterSampleCount; bk.a2c = d.alphaToCoverageEnabled; bk.a21 = d.alphaToOneEnabled; bk.topo = (uint32_t)d.inputPrimitiveTopology;
        os_unfair_lock_lock(&g_pbase_lock); id base = hm_get_id(&g_pbase, &bk); if (!base) hm_put_id(&g_pbase, &bk, NSNull.null); os_unfair_lock_unlock(&g_pbase_lock);
        if (!base) {   // 第一次：后台建基础管线（占位 NSNull 防重复踢；建成换成管线）
            id bd = pull_desc4(d, vs, fs, 1); g_hy_kicked++;
            static dispatch_queue_t q; static dispatch_once_t once;
            dispatch_once(&once, ^{ q = dispatch_queue_create("dm.nvn.hybrid", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0)); });
            dispatch_async(q, ^{ @autoreleasepool { NSError *e = nil; id<MTLRenderPipelineState> ps = [g_hy_comp newRenderPipelineStateWithDescriptor:bd compilerTaskOptions:nil error:&e];
                if (ps) { os_unfair_lock_lock(&g_pbase_lock); hm_put_id(&g_pbase, &bk, ps); os_unfair_lock_unlock(&g_pbase_lock); g_hy_bases++; }
                else { uint64_t n = ++g_hy_base_fail; if (n <= 8) MLOG("【红】 hybrid pipelines: pulling base for vertex %s fragment %s failed: %s (that pair's first uses wait)", vs->key, fs->key, e.localizedDescription.UTF8String); } } });
            g_hy_none++; return nil;
        }
        if (base == NSNull.null) { g_hy_none++; return nil; }   // 还在建，或建不出
        NSError *e = nil; uint64_t t0 = bp_now();
        id<MTLRenderPipelineState> ps = [g_hy_comp newRenderPipelineStateBySpecializationWithDescriptor:pull_desc4(d, vs, fs, 0) pipeline:base error:&e];
        g_hy_spec_ns += bp_now() - t0;
        if (!ps) { static int n; if (n++ < 8) MLOG("【红】 hybrid pipelines: specializing the pulling base for vertex %s fragment %s failed: %s", vs->key, fs->key, e.localizedDescription.UTF8String); hm_put_id(&g_pso_hy, k, NSNull.null); return nil; }
        uint64_t m = ++g_hy_made; hm_put_id(&g_pso_hy, k, ps);
        if (!(m & (m - 1))) MLOG("hybrid pipelines: %llu made by specializing a pulling base (mean %.2f ms), %llu draws with them; %llu first uses found no base ready (%llu bases built, %llu failed)",
                                 (unsigned long long)m, g_hy_spec_ns / 1e6 / m, (unsigned long long)g_hy_draws, (unsigned long long)g_hy_none, (unsigned long long)g_hy_bases, (unsigned long long)g_hy_base_fail);
        return ps;
    }
    return nil;
}
