// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 大内存池按块用到才包（马车世界缺口 ②，nvn_mtl.m big_pool / big_lookup，照上游参考实现（MIT））。期望按块的规则手算（BIG_S 16 MB、不知道长度给 64 MB、块盖到要读的末尾向上取步长再多一个步长），不由被测实现推出：
//   ① 640 MB 的池登记后：没有任何缓冲条目（大池记录 1 个）
//   ② GPU 查 100 MB + 16 起 64 字节：建 [96, 128) MB 的块，缓冲长 32 MB，偏移 4 MB + 16
//   ③ 同一步长查 100 MB 起 40 MB：同一条目加长到 [96, 160) MB（缓冲 64 MB），被替下的旧缓冲 1 个
//   ④ 查 300 MB 起长度 1（不知道读多远）：[288, 384) MB，96 MB
//   ⑤ CPU 读 500 MB 处（addr_cpu）：给游戏地址本身、不建块（条目数不变）
//   ⑥ 内容：CPU 在 100 MB + 16 写的 16 字节，GPU 经块的缓冲拷出来一样
//   ⑦ 池注销：当时照旧可查（记录 1、块 2、别名 1）；过两次提交（提交序号 +2、pool_reap）后大池记录、块条目、指着旧块的别名都没了
//   ⑩ 池表下标：④ 之前登记一个小池，④ 的块排在池表末尾；删掉小池（末尾那条挪进空位）、再登记一个小池占住块原来的下标后，再查 300 MB 处仍是 ④ 那块缓冲（块表下标跟着改）
//   ⑨ 虚拟池地址别名到块（#1143 nvn_be_pool_alias）：登记 1 条；块被 ③ 加长替换、池注销后这条也没了（旧块缓冲要算进「被放掉的」）
//   ⑧ DM_NVN_POOL_CHUNKS=0（子进程，对照）：登记即建整池一个缓冲，长 640 MB
//   ⑪ ⑫ 块范围里有脏页跟踪设成只读的页时建块：GPU 经块读出 CPU 写的数据、写进的数据落到游戏内存（期望 = CPU 写的常量）
//   反证：去掉 nvn_be_pool_add_body 里登记大池那段 → ① ② ③ ④ 红（整池一个缓冲）；去掉注销时把旧块缓冲算进被放掉的那两行 → ⑨ 注销后 1 条红；去掉 big_new 建块前的 dm_guest_write_prepare → ⑫ 红
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"✓":"✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
#define MB (1ull << 20)
static int aliases(void) { int n=0; pthread_mutex_lock(&g_mu); for (int i=0;i<g_npool;i++) n+=g_pools[i].alias; pthread_mutex_unlock(&g_mu); return n; }
static int entries_of(const void *mem) { int n=0; pthread_mutex_lock(&g_mu); for (int i=0;i<g_npool;i++) n+=g_pools[i].key==mem; pthread_mutex_unlock(&g_mu); return n; }

static int child(int chunks) {
    alarm(60); unsetenv("NXGAL_BE");
    if (chunks) unsetenv("DM_NVN_POOL_CHUNKS"); else setenv("DM_NVN_POOL_CHUNKS","0",1);
    mtl_init();
    const uint64_t SZ = 640 * MB; uint8_t *mem = NULL; REQUIRE(!posix_memalign((void **)&mem, 16*MB, SZ));   // 16 MB 对齐：块按绝对地址取步长，期望好手算
    nvn_be_pool_add(mem, SZ);
    if (!chunks) {
        pthread_mutex_lock(&g_mu); uint64_t len = 0; int n = 0; for (int i=0;i<g_npool;i++) if (g_pools[i].key==mem) { n++; len = g_pools[i].buf.length; } int nb = g_nbig; pthread_mutex_unlock(&g_mu);
        CHECK(nb==0 && n==1 && len==SZ,"⑧ DM_NVN_POOL_CHUNKS=0：大池记录 %d（期望 0）、整池缓冲 %d 个长 %llu MB（期望 1 个 640）",nb,n,(unsigned long long)(len/MB));
        printf("%s t_nvn_big_pool 子进程（DM_NVN_POOL_CHUNKS=0）：%u 项，%u 项失败\n",failures?"✗":"✓",checks,failures); return failures!=0;
    }
    { pthread_mutex_lock(&g_mu); int nb = g_nbig; pthread_mutex_unlock(&g_mu);
      CHECK(nb==1 && entries_of(mem)==0,"① 640 MB 池登记后：大池记录 %d（期望 1）、缓冲条目 %d（期望 0）",nb,entries_of(mem)); }
    void *bp; uint64_t off, gpu;
    REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)mem + 100*MB + 16, 64, &bp, &off, &gpu));
    id<MTLBuffer> b1 = (__bridge id<MTLBuffer>)bp;
    CHECK(b1.length==32*MB && off==4*MB+16 && entries_of(mem)==1,"② 查 100 MB+16 起 64 字节：块缓冲 %llu MB（期望 32）、偏移 %#llx（期望 %#llx）、条目 %d（期望 1）",(unsigned long long)(b1.length/MB),(unsigned long long)off,(unsigned long long)(4*MB+16),entries_of(mem));
    const uint64_t VA = 0x10000100000ull; int aok = nvn_be_pool_alias(VA, 64, (uint64_t)(uintptr_t)mem + 100*MB + 16);   // ⑨ 虚拟池地址别名到 ② 的块（#1143）
    CHECK(aok && aliases()==1,"⑨ 虚拟池地址别名到 ② 的块：登记 %d、别名条目 %d（期望 1、1）",aok,aliases());
    REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)mem + 100*MB, 40*MB, &bp, &off, &gpu));
    id<MTLBuffer> b2 = (__bridge id<MTLBuffer>)bp; int nold; pthread_mutex_lock(&g_mu); nold = (int)g_big[0].old.count; pthread_mutex_unlock(&g_mu);
    CHECK(b2.length==64*MB && off==4*MB && entries_of(mem)==1 && nold==1,"③ 同步长查 100 MB 起 40 MB：缓冲 %llu MB（期望 64）、偏移 %#llx（期望 %#llx）、条目 %d（期望 1）、旧缓冲 %d（期望 1）",(unsigned long long)(b2.length/MB),(unsigned long long)off,(unsigned long long)(4*MB),entries_of(mem),nold);
    uint8_t *small = NULL; REQUIRE(!posix_memalign((void **)&small, 16384, 65536)); nvn_be_pool_add(small, 65536);   // ⑩：块建在它之后、排在末尾
    REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)mem + 300*MB, 1, &bp, &off, &gpu));
    id<MTLBuffer> b3 = (__bridge id<MTLBuffer>)bp;
    CHECK(b3.length==96*MB && off==12*MB && entries_of(mem)==2,"④ 查 300 MB 起长度 1：缓冲 %llu MB（期望 96）、偏移 %#llx（期望 %#llx）、条目 %d（期望 2）",(unsigned long long)(b3.length/MB),(unsigned long long)off,(unsigned long long)(12*MB),entries_of(mem));
    { pthread_mutex_lock(&g_mu); int is = -1, last_is_b3 = g_npool > 0 && g_pools[g_npool - 1].buf == b3; for (int i = 0; i < g_npool; i++) if (g_pools[i].key == small) is = i;
      REQUIRE(is >= 0 && last_is_b3); pool_remove_at(is); pthread_mutex_unlock(&g_mu);
      uint8_t *small2 = NULL; REQUIRE(!posix_memalign((void **)&small2, 16384, 65536)); nvn_be_pool_add(small2, 65536);   // 新池占住块原来的下标（末尾）
      REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)mem + 300*MB, 1, &bp, &off, &gpu));
      CHECK((__bridge id<MTLBuffer>)bp == b3 && off == 12*MB && entries_of(mem) == 2, "⑩ 删掉排在前面的小池（④ 的块挪进它的位置）后再查 300 MB 处：同一块缓冲 %d、偏移 %#llx（期望 1、%#llx）、条目 %d（期望 2，不另建）",
            (__bridge id<MTLBuffer>)bp == b3, (unsigned long long)off, (unsigned long long)(12*MB), entries_of(mem)); }
    const uint8_t *c = addr_cpu((uint64_t)(uintptr_t)mem + 500*MB, 4);
    CHECK(c==mem+500*MB && entries_of(mem)==2,"⑤ CPU 读 500 MB 处：给游戏地址本身 %d、条目 %d（期望 2，不建块）",c==mem+500*MB,entries_of(mem));
    { uint32_t pat[4]={0x11223344,0x55667788,0x99aabbcc,0xddeeff00}; memcpy(mem+100*MB+16,pat,16);
      REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)mem + 100*MB + 16, 16, &bp, &off, &gpu)); id<MTLBuffer> src=(__bridge id<MTLBuffer>)bp;
      id<MTLBuffer> dst=[g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; id<MTLCommandQueue> q=[g_dev newCommandQueue];
      id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> be=[cb blitCommandEncoder];
      [be copyFromBuffer:src sourceOffset:off toBuffer:dst destinationOffset:0 size:16]; [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
      CHECK(!memcmp(dst.contents,pat,16),"⑥ GPU 经块的缓冲拷出 CPU 写的 16 字节：一致 %d",!memcmp(dst.contents,pat,16)); }
    // ⑪ ⑫ 块范围里有被脏页跟踪设成只读的页（上传过的贴图存储）时建块：GPU 读、写这块缓冲都要落到游戏内存（11-19：建块时范围里有只读页，GPU 写整块无声丢失）
    { nvn_dirty_add_range(mem, SZ); uint8_t *ro = mem + 196*MB, *in = mem + 200*MB, *outp = mem + 204*MB;   // 同在 [192, 208) MB 这一步长
      const uint32_t pin[4]={0x0badf00d,0x12345678,0x9abcdef0,0x0f1e2d3c}, pout[4]={0xcafebabe,0x31415926,0x27182818,0x16180339}; memcpy(in,pin,16); memset(outp,0,16);
      nvn_dirty_protect(ro, nvn_dirty_page_size());
      CHECK(nvn_dirty_page_armed(nvn_dirty_span(ro, 1), ro),"⑪ 前提：196 MB 那页已设只读（脏页跟踪）");
      REQUIRE(mtl_gpu_addr((uint64_t)(uintptr_t)in, 16, &bp, &off, &gpu)); id<MTLBuffer> ch=(__bridge id<MTLBuffer>)bp; uint64_t base=(uint64_t)((uintptr_t)in - off);
      CHECK(base <= (uint64_t)(uintptr_t)ro && (uint64_t)(uintptr_t)ro < base + ch.length,"⑪ 前提：新建的块盖住那页只读页（块 [%+lld, +%llu MB)）",(long long)(base - (uint64_t)(uintptr_t)mem)/(long long)MB,(unsigned long long)(ch.length/MB));
      id<MTLBuffer> dst=[g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared], src=[g_dev newBufferWithBytes:pout length:16 options:MTLResourceStorageModeShared];
      id<MTLCommandQueue> q=[g_dev newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer]; id<MTLBlitCommandEncoder> be=[cb blitCommandEncoder];
      [be copyFromBuffer:ch sourceOffset:off toBuffer:dst destinationOffset:0 size:16];
      [be copyFromBuffer:src sourceOffset:0 toBuffer:ch destinationOffset:off + 4*MB size:16]; [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
      CHECK(cb.status==MTLCommandBufferStatusCompleted && !memcmp(dst.contents,pin,16),"⑪ GPU 经这块读 CPU 写的 16 字节：一致 %d（命令缓冲状态 %ld）",!memcmp(dst.contents,pin,16),(long)cb.status);
      CHECK(!memcmp(outp,pout,16),"⑫ GPU 经这块写的 16 字节落到游戏内存：一致 %d（读回 %08x…，期望 %08x…）",!memcmp(outp,pout,16),((uint32_t *)outp)[0],pout[0]);
      nvn_dirty_remove_range(mem); }
    nvn_be_pool_del(mem);
    { pthread_mutex_lock(&g_mu); int nb = g_nbig; pthread_mutex_unlock(&g_mu);   // 注销按回放顺序：游戏释放后再过两次提交才回收（pool_reap），期间照旧可查
      CHECK(nb==1 && entries_of(mem)==3 && aliases()==1,"⑦ 刚注销：大池记录 %d、块条目 %d、别名 %d（期望 1、3、1：[96, 160)、[288, 384)、⑪ 的 [192, 224) 三块，到期前照旧可查）",nb,entries_of(mem),aliases()); }
    pthread_mutex_lock(&g_mu); g_sub_serial += 2; pool_reap(0, 0); pthread_mutex_unlock(&g_mu);   // 过两次提交：nvn_be_sub_begin 里回收的那一步（它本身要配对的提交收尾，这里直接走回收）
    { pthread_mutex_lock(&g_mu); int nb = g_nbig; pthread_mutex_unlock(&g_mu);
      CHECK(nb==0 && entries_of(mem)==0,"⑦ 池注销：大池记录 %d、块条目 %d（期望都 0）",nb,entries_of(mem)); }
    CHECK(aliases()==0,"⑨ 池注销后：指着被 ③ 加长替下的旧块缓冲的别名条目 %d（期望 0；旧块不在池表里，原先留下指向已放缓冲的条目）",aliases());
    printf("%s t_nvn_big_pool 子进程（缺省）：%u 项，%u 项失败\n",failures?"✗":"✓",checks,failures);
    return failures!=0;
}
int main(int argc, char **argv) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    if (argc==3 && !strcmp(argv[1],"--child")) return child(atoi(argv[2]));
    unsigned bad=0; static const char *const modes[2]={"1","0"};
    for (int m=0; m<2; m++) {
        fflush(NULL); pid_t pid=fork(); REQUIRE(pid>=0);
        if (!pid) { execl(argv[0],argv[0],"--child",modes[m],(char *)NULL); _exit(127); }
        int st=0; pid_t w; do { w=waitpid(pid,&st,0); } while (w<0 && errno==EINTR); REQUIRE(w==pid);
        bad+=!(WIFEXITED(st) && WEXITSTATUS(st)==0);
    }
    printf("%s t_nvn_big_pool：缺省 / DM_NVN_POOL_CHUNKS=0 两个子进程，%u 个不过（大内存池按块用到才包）\n",bad?"✗":"✓",bad);
    return bad!=0;
} }
