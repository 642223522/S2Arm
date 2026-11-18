// Metal 稀疏贴图（11-16，一款 Switch 2 赛车游戏 0400C3F00006E000：9 张 NVN 稀疏贴图数组 8192x8192x68 层 12 级，标称 5.8 / 1.45 GB，Mac 驻留 31 GB、iPhone 内存告警被杀）。
//   NVN 稀疏贴图挂在虚拟池上，只有游戏 MapVirtual 过的 64 KB 页有物理内存。原先 pkg_upload_ 按标称全尺寸建私有 Metal 贴图，且在 CPU 上
//   malloc 一份全尺寸副本（nvn_sparse_copy）整张去混排上传——一张就要 6 GB 内存。这里改为 Metal 稀疏贴图：建一个刚够大小的稀疏堆，
//   只映射游戏映射了的页对应的 Metal 块，逐页去混排上传。
//   页与块：NVN 页 64 KB = 块线性一段连续存储（宽 nvn_tex_sparse_layout tile[1] 像素、高 tile[2] 像素，块高 = 本级块高），页起点 =
//   层起点 + 级起点 + (页行 × 每行页数 + 页列) × 64 KB（tests：t_nvn_sparse_tex 逐页对整级去混排逐字节核过）。Metal 块 16 KB，NVN 页正好是它的整数倍。
//   尾级：NVN 按页铺的级之后、或 Metal firstMipmapInTail 之后的级都小，整级映射、整级上传（Metal 尾每层一块）。
//   映射变了（vgen）照旧整张重传：按新的已映射页重建堆与贴图（只花已映射的那些页）；增量映射以后再做。
//   不走这里（照旧全尺寸）：设备没有稀疏贴图、不是 2D / 2D 数组、多重采样、要 CPU 改格式（fmt_unpack）、NVN 页不是 Metal 块的整数倍、
//   标称不到 DM_NVN_SPARSE_METAL_MB（缺省 64 MB），或 DM_NVN_SPARSE_METAL=0
uint64_t nvn_sparse_map_bits(const void *pool, uint64_t a, uint64_t n, uint8_t *bits);
static id<MTLCommandQueue> g_sp_q; static int g_sp_res; static id<MTLSharedEvent> g_sp_ev; static uint64_t g_sp_v;   // 映射与上传用的独立队列，同步等完（只在首传 / 映射变了的重传时走，按已映射页计）
static _Atomic uint64_t g_sp_n, g_sp_nominal, g_sp_heap_bytes, g_sp_pages;   // 读数：建过几张、标称合计、堆合计、上传页数
static id<MTLHeap> sp_heap_of(id r) { return objc_getAssociatedObject(r, &g_sp_heap_key); }
// 两套接法（本机实测：老式稀疏堆的贴图交给 Metal 4 队列画，所有页都映射了照样 GPU 缺页）：
//   Metal 4 队列（g_q4）：放置式稀疏贴图——描述带 placementSparsePageSize（64 KB 页，同 NVN 页）、背后是放置堆，映射走 g_q4 updateTextureMappings；
//   Metal 3（g_m3，iOS 26 以下）：老式稀疏堆（MTLHeapTypeSparse）+ resourceStateEncoder 映射
static int sp_m4(void) { if (@available(macOS 26.0, iOS 26.0, *)) return !g_m3 && g_q4 != nil; return 0; }
static MTLSize sp_tile(MTLTextureType type, MTLPixelFormat pf, uint64_t *bytes) {
    if (@available(macOS 26.0, iOS 26.0, *)) if (sp_m4()) { if (bytes) *bytes = 0x10000; return [g_dev sparseTileSizeWithTextureType:type pixelFormat:pf sampleCount:1 sparsePageSize:MTLSparsePageSize64]; }
    if (bytes) *bytes = g_dev.sparseTileSizeInBytes;
    return [g_dev sparseTileSizeWithTextureType:type pixelFormat:pf sampleCount:1];
}
static int sp_eligible(const tex_t *t, MTLTextureDescriptor *d) {
    static int on = -1; static uint64_t min_bytes;
    if (on < 0) { const char *e = getenv("DM_NVN_SPARSE_METAL"), *m = getenv("DM_NVN_SPARSE_METAL_MB");
        // Metal 3（g_m3）走老式稀疏堆：堆不进驻留集（进了 AGX 驱动 commit 崩），由 nvn_mtl.m m3_wait 在每个渲染 / 计算编码器上 useHeaps（不声明就 GPU 缺页，本机 NXGAL_BE=mtl3 实测）
        on = !(e && *e == '0') && ([g_dev supportsFamily:MTLGPUFamilyApple6] || [g_dev supportsFamily:MTLGPUFamilyMac2]);
        min_bytes = (uint64_t)(m ? strtoull(m, NULL, 10) : 64) << 20;
        MLOG("Metal sparse textures for NVN sparse textures: %s (from %llu MB nominal; DM_NVN_SPARSE_METAL / DM_NVN_SPARSE_METAL_MB)", on ? "on" : "off", (unsigned long long)(min_bytes >> 20)); }
    if (!on || !(t->d.flags & NVN_TEXTURE_FLAGS_SPARSE) || t->L.size < min_bytes || d.sampleCount > 1) return 0;
    if (d.textureType != MTLTextureType2D && d.textureType != MTLTextureType2DArray) return 0;
    uint32_t upf; int ubpp; if (fmt_unpack(t->d.format, &upf, &ubpp)) return 0;
    uint32_t tl[4]; nvn_tex_sparse_layout(&t->d, tl); if (!tl[0]) return 0;
    MTLSize ts = sp_tile(d.textureType, d.pixelFormat, NULL);
    return ts.width && ts.height && tl[1] % ts.width == 0 && tl[2] % ts.height == 0;
}
// 一个上传活：tiled = 1 页（合成描述去混排），否则整级（虚拟池局部拷贝 + 原描述去混排）
typedef struct { uint32_t level, slice, x, y, w, h; int page; uint64_t addr, bytes; } sp_job;
static id<MTLTexture> sp_upload(const tex_t *t, MTLTextureDescriptor *d0) {
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!g_sp_q) { static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; pthread_mutex_lock(&mu); if (!g_sp_q) g_sp_q = [g_dev newCommandQueue]; pthread_mutex_unlock(&mu); }
    MTLTextureDescriptor *d = [d0 copy]; d.storageMode = MTLStorageModePrivate; d.hazardTrackingMode = MTLHazardTrackingModeTracked;
    uint32_t tl[4]; nvn_tex_sparse_layout(&t->d, tl);
    int m4 = sp_m4(); uint64_t tile_b = 0;
    if (@available(macOS 26.0, iOS 26.0, *)) if (m4) d.placementSparsePageSize = MTLSparsePageSize64;
    MTLSize ts = sp_tile(d.textureType, d.pixelFormat, &tile_b);
    int bw, bh, bpb = nvn_fmt_bpb(t->d.format, &bw, &bh);
    unsigned layers = d.textureType == MTLTextureType2DArray ? (unsigned)d.arrayLength : 1, levels = (unsigned)d.mipmapLevelCount;
    unsigned nvn_tiled = MIN(tl[0], levels);
    // Metal 的尾从哪一级起：建一张不占物理页的探针贴图读 firstMipmapInTail（堆只要一块大）
    unsigned mtail;
    uint64_t tail_tiles = 1;
    { id<MTLTexture> pt = nil;
      if (m4) pt = [g_dev newTextureWithDescriptor:d];   // 放置式：建贴图不占内存，映射时才给
      else { MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.type = MTLHeapTypeSparse; hd.storageMode = MTLStorageModePrivate; hd.size = tile_b;
             pt = [[g_dev newHeapWithDescriptor:hd] newTextureWithDescriptor:d]; }
      if (!pt) return nil;
      mtail = (unsigned)MIN(pt.firstMipmapInTail, (NSUInteger)levels);
      if (pt.tailSizeInBytes) tail_tiles = (pt.tailSizeInBytes + tile_b - 1) / tile_b; }
    unsigned paged = MIN(nvn_tiled, mtail);   // 逐页的级 [0, paged)；[paged, mtail) 整级逐块；[mtail, levels) Metal 尾
    uint8_t *bits = NULL; size_t njob = 0, cap = 0; sp_job *jobs = NULL; uint64_t tiles = 0, mapped_pages = 0;
    #define SP_PUSH(J) do { if (njob == cap) { cap = cap ? cap * 2 : 256; sp_job *nj = realloc(jobs, cap * sizeof *jobs); if (!nj) { free(jobs); free(bits); return nil; } jobs = nj; } jobs[njob++] = (J); } while (0)
    for (unsigned y = 0; y < layers; y++)
        for (unsigned l = 0; l < levels; l++) {
            uint32_t w = MAX(t->d.width >> l, 1u), h = MAX(t->d.height >> l, 1u);
            uint64_t lo = (uint64_t)y * t->L.layer_size + nvn_tex_level_offset(&t->d, l);
            if (l < paged) {
                uint32_t ppr = (w + tl[1] - 1) / tl[1], ppc = (h + tl[2] - 1) / tl[2]; uint64_t np = (uint64_t)ppr * ppc;
                uint8_t *nb = realloc(bits, (size_t)((np + 7) >> 3)); if (!nb) { free(bits); free(jobs); return nil; } bits = nb;
                mapped_pages += nvn_sparse_map_bits(t->pool, (uint64_t)(uintptr_t)t->mem + lo, np << 16, bits);
                for (uint32_t py = 0; py < ppc; py++) for (uint32_t px = 0; px < ppr; px++) {
                    uint64_t k = (uint64_t)py * ppr + px; if (!(bits[k >> 3] >> (k & 7) & 1)) continue;
                    uint32_t x0 = px * tl[1], y0 = py * tl[2], cw = MIN(tl[1], w - x0), ch = MIN(tl[2], h - y0);
                    SP_PUSH(((sp_job){l, y, x0, y0, cw, ch, 1, (uint64_t)(uintptr_t)t->mem + lo + (k << 16), 0x10000}));
                    tiles += (uint64_t)((cw + ts.width - 1) / ts.width) * ((ch + ts.height - 1) / ts.height);
                }
            } else {
                uint64_t ln = (l + 1 < levels ? nvn_tex_level_offset(&t->d, l + 1) : t->L.layer_size) - nvn_tex_level_offset(&t->d, l);
                SP_PUSH(((sp_job){l, y, 0, 0, w, h, 0, (uint64_t)(uintptr_t)t->mem + lo, ln}));
                if (l < mtail) tiles += (uint64_t)((w + ts.width - 1) / ts.width) * ((h + ts.height - 1) / ts.height);
            }
        }
    if (mtail < levels) tiles += (uint64_t)layers * tail_tiles;   // Metal 尾：每层 tailSizeInBytes（本机实测 16 KB 页下一块）
    free(bits);
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.storageMode = MTLStorageModePrivate; hd.size = (tiles + 1) * tile_b;
    if (m4) { if (@available(macOS 26.0, iOS 26.0, *)) { hd.type = MTLHeapTypePlacement; hd.maxCompatiblePlacementSparsePageSize = MTLSparsePageSize64; } }
    else hd.type = MTLHeapTypeSparse;
    id<MTLHeap> heap = [g_dev newHeapWithDescriptor:hd];
    id<MTLTexture> mt = !heap ? nil : m4 ? [g_dev newTextureWithDescriptor:d] : [heap newTextureWithDescriptor:d];
    if (!mt) { free(jobs); RED_ONCE(198, "Metal sparse texture: heap of %llu tiles or texture not made (ser=%llu %ux%ux%u format %#x); falling back to a full-size texture",
                                   (unsigned long long)tiles, (unsigned long long)t->serial, t->d.width, t->d.height, t->d.depth, t->d.format); return nil; }
    objc_setAssociatedObject(mt, &g_sp_heap_key, heap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!m4) { pthread_mutex_lock(&g_sp_live_mu); if (!g_sp_live_heaps) g_sp_live_heaps = [NSHashTable weakObjectsHashTable]; [g_sp_live_heaps addObject:heap]; pthread_mutex_unlock(&g_sp_live_mu); atomic_store(&g_sp_live_any, 1); }   // Metal 3：编码器逐个 useHeaps（m3_use_sparse_heaps）
    // 映射
    if (!g_sp_res) { [g_sp_q addResidencySet:g_res]; g_sp_res = 1; }   // 上传队列也要看到堆（驻留集收的是堆）
    id<MTLCommandBuffer> cb = [g_sp_q commandBuffer];
    if (m4) {
        if (@available(macOS 26.0, iOS 26.0, *)) {
            size_t nops = 0; MTL4UpdateSparseTextureMappingOperation *ops = calloc(njob + layers + 1, sizeof *ops); uint64_t ho = 0;
            if (!ops) { free(jobs); return nil; }
            for (size_t i = 0; i < njob; i++) { const sp_job *j = &jobs[i]; if (j->level >= mtail) continue;
                MTLRegion r = MTLRegionMake2D(j->x / ts.width, j->y / ts.height, (j->w + ts.width - 1) / ts.width, (j->h + ts.height - 1) / ts.height);
                ops[nops++] = (MTL4UpdateSparseTextureMappingOperation){MTLSparseTextureMappingModeMap, r, j->level, j->slice, ho}; ho += r.size.width * r.size.height; }
            if (mtail < levels) for (unsigned y = 0; y < layers; y++) { ops[nops++] = (MTL4UpdateSparseTextureMappingOperation){MTLSparseTextureMappingModeMap, MTLRegionMake2D(0, 0, 1, 1), mtail, y, ho}; ho += tail_tiles; }
            [g_q4 updateTextureMappings:mt heap:heap operations:ops count:nops];
            free(ops);
            if (!g_sp_ev) g_sp_ev = [g_dev newSharedEvent];
            uint64_t v = ++g_sp_v; [g_q4 signalEvent:g_sp_ev value:v];   // 映射在主队列上排；上传缓冲等它
            [cb encodeWaitForEvent:g_sp_ev value:v];
        }
    } else {
        id<MTLResourceStateCommandEncoder> re = [cb resourceStateCommandEncoder];
        for (size_t i = 0; i < njob; i++) {
            const sp_job *j = &jobs[i];
            if (j->level >= mtail) continue;
            MTLRegion r = MTLRegionMake2D(j->x / ts.width, j->y / ts.height, (j->w + ts.width - 1) / ts.width, (j->h + ts.height - 1) / ts.height);
            [re updateTextureMapping:mt mode:MTLSparseTextureMappingModeMap region:r mipLevel:j->level slice:j->slice];
        }
        if (mtail < levels) for (unsigned y = 0; y < layers; y++) [re updateTextureMapping:mt mode:MTLSparseTextureMappingModeMap region:MTLRegionMake2D(0, 0, 1, 1) mipLevel:mtail slice:y];
        [re endEncoding];
    }
    res_add(mt); res_commit();   // 上传前就驻留（res_add_at_body 按 g_sp_heap_key 登记堆 / 放置式还登记贴图），上传队列也挂着同一个驻留集
    // 诊断 DM_NVN_SPARSE_METAL_CHECK=N：前 N 张贴图上传后，把每批至多 8 页从 Metal 贴图读回、与 CPU 去混排的同一页逐字节比（映射位置 + 上传位置一起核）
    static int chk = -1; static _Atomic int chk_done; if (chk < 0) { const char *e = getenv("DM_NVN_SPARSE_METAL_CHECK"); chk = e ? atoi(e) : 0; }
    int do_chk = chk > 0 && atomic_fetch_add(&chk_done, 1) < chk; uint64_t chk_pages = 0, chk_bad = 0;
    // 上传：按暂存批次（≤ 64 MB 一批）去混排进共享缓冲再 blit；整级活走虚拟池局部拷贝
    const size_t batch_cap = 64u << 20; size_t i = 0; uint64_t up_pages = 0; uint8_t *pg = malloc(0x10000);   // 一页的原始存储（不放栈上：提交线程栈不大）
    if (!pg) { free(jobs); return nil; }
    while (i < njob) {
        size_t need = 0, i1 = i, i0 = i;
        for (; i1 < njob; i1++) { const sp_job *j = &jobs[i1]; uint32_t w = j->page ? tl[1] : j->w, h = j->page ? tl[2] : j->h;
            size_t b = (size_t)((w + bw - 1) / bw) * bpb * ((h + bh - 1) / bh); if (need && need + b > batch_cap) break; need += b; }
        id<MTLBuffer> stg = [g_dev newBufferWithLength:need ? need : 16 options:MTLResourceStorageModeShared];
        if (!stg) { cb = nil; break; }
        id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder]; size_t off = 0;
        for (; i < i1; i++) {
            const sp_job *j = &jobs[i]; uint8_t *dst = (uint8_t *)stg.contents + off;
            if (j->page) {
                unsigned tH, tD; nvn_tex_level_tiles(&t->d, j->level, &tH, &tD);
                nvn_texdesc pd = {0}; pd.target = 1; pd.format = t->d.format; pd.width = tl[1]; pd.height = tl[2]; pd.depth = 1; pd.levels = 1; pd.pkg_layout = (int)(tH | (tD << 4)) + 1;
                size_t pitch = (size_t)(tl[1] / bw) * bpb, rows = tl[2] / bh;
                if (nvn_sparse_copy(t->pool, pg, j->addr, 0x10000) == 0x10000) memset(dst, 0, pitch * rows);   // 刚好被解除映射：读 0（同 GPU 读未映射块）
                else if (nvn_deswizzle(&pd, 0, 0, pg, dst, pitch)) { RED_ONCE(199, "Metal sparse texture: page deswizzle failed (format %#x)", t->d.format); memset(dst, 0, pitch * rows); }
                [be copyFromBuffer:stg sourceOffset:off sourceBytesPerRow:pitch sourceBytesPerImage:pitch * rows sourceSize:MTLSizeMake(j->w, j->h, 1)
                         toTexture:mt destinationSlice:j->slice destinationLevel:j->level destinationOrigin:MTLOriginMake(j->x, j->y, 0)];
                off += pitch * rows; up_pages++;
            } else {
                size_t pitch = (size_t)((j->w + bw - 1) / bw) * bpb, rows = (j->h + bh - 1) / bh;
                uint8_t *part = malloc(j->bytes ? j->bytes : 1); if (!part) { memset(dst, 0, pitch * rows); off += pitch * rows; continue; }
                nvn_sparse_copy(t->pool, part, j->addr, j->bytes);
                // nvn_deswizzle 按整张存储取址：把这一级这一层的局部副本当作「从存储起点偏移 (级起点 + 层起点) 处」交进去
                uint64_t lo = (uint64_t)j->slice * t->L.layer_size + nvn_tex_level_offset(&t->d, j->level);
                if (nvn_deswizzle(&t->d, j->level, j->slice, part - lo, dst, pitch)) { RED_ONCE(200, "Metal sparse texture: level deswizzle failed (format %#x)", t->d.format); memset(dst, 0, pitch * rows); }
                free(part);
                [be copyFromBuffer:stg sourceOffset:off sourceBytesPerRow:pitch sourceBytesPerImage:pitch * rows sourceSize:MTLSizeMake(j->w, j->h, 1)
                         toTexture:mt destinationSlice:j->slice destinationLevel:j->level destinationOrigin:MTLOriginMake(0, 0, 0)];
                off += pitch * rows;
            }
        }
        [be endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        if (cb.error) { RED_ONCE(201, "Metal sparse texture: map / upload command buffer failed: %s", cb.error.localizedDescription.UTF8String); free(jobs); free(pg); return nil; }
        if (do_chk) {   // 读回比对：本批前 8 个页活
            size_t o2 = 0; int nc = 0;
            for (size_t k = i0; k < i && nc < 8; k++) { const sp_job *j = &jobs[k];
                size_t pitch = j->page ? (size_t)(tl[1] / bw) * bpb : (size_t)((j->w + bw - 1) / bw) * bpb, rows = j->page ? tl[2] / bh : (j->h + bh - 1) / bh;
                if (j->page) { size_t cr = (j->h + bh - 1) / bh, cbytes = (size_t)((j->w + bw - 1) / bw) * bpb;
                    id<MTLBuffer> rb = [g_dev newBufferWithLength:pitch * rows options:MTLResourceStorageModeShared]; id<MTLCommandBuffer> c2 = [g_sp_q commandBuffer]; id<MTLBlitCommandEncoder> b2 = [c2 blitCommandEncoder];
                    [b2 copyFromTexture:mt sourceSlice:j->slice sourceLevel:j->level sourceOrigin:MTLOriginMake(j->x, j->y, 0) sourceSize:MTLSizeMake(j->w, j->h, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:pitch destinationBytesPerImage:pitch * rows];
                    [b2 endEncoding]; [c2 commit]; [c2 waitUntilCompleted];
                    const uint8_t *want = (const uint8_t *)stg.contents + o2, *got = rb.contents; int same = 1;
                    for (size_t r = 0; r < cr && same; r++) same = !memcmp(want + r * pitch, got + r * pitch, cbytes);
                    chk_pages++; chk_bad += !same; nc++;
                    if (!same && chk_bad <= 4) MLOG("【红】 Metal sparse texture check: ser=%llu level %u slice %u page at %u,%u read back differs from its upload", (unsigned long long)t->serial, j->level, j->slice, j->x, j->y); }
                o2 += pitch * rows; } }
        cb = nil; if (i < njob) cb = [g_sp_q commandBuffer];
    }
    free(pg);
    if (i < njob) { free(jobs); return nil; }
    if (cb) { [cb commit]; [cb waitUntilCompleted]; if (cb.error) { free(jobs); return nil; } }   // 没有上传活（只有映射）：映射也要等完再用
    free(jobs);
    if (do_chk) MLOG("Metal sparse texture check ser=%llu: %llu pages read back, %llu differ", (unsigned long long)t->serial, (unsigned long long)chk_pages, (unsigned long long)chk_bad);
    atomic_fetch_add(&g_sp_n, 1); atomic_fetch_add(&g_sp_nominal, t->L.size); atomic_fetch_add(&g_sp_heap_bytes, hd.size); atomic_fetch_add(&g_sp_pages, up_pages);
    { static _Atomic int said; if (atomic_fetch_add(&said, 1) < 24)
        MLOG("Metal sparse texture ser=%llu %ux%ux%u levels %u format %#x: nominal %llu MB → heap %llu MB (%llu tiles; %llu of the NVN pages mapped, %llu uploaded; NVN tiled levels %u, Metal tail from %u), %.1f ms",
             (unsigned long long)t->serial, t->d.width, t->d.height, layers, levels, t->d.format, (unsigned long long)(t->L.size >> 20), (unsigned long long)(hd.size >> 20), (unsigned long long)tiles,
             (unsigned long long)mapped_pages, (unsigned long long)up_pages, nvn_tiled, mtail, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6); }
    #undef SP_PUSH
    return mt;
}
