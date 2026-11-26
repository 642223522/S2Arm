#include <napi/native_api.h>
#include "controller_ohos.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_window/external_window.h>
#include <hilog/log.h>
#include <dlfcn.h>
#include <pthread.h>
#include <atomic>
#include <mutex>
#include <string>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <cerrno>
#include <unistd.h>
#include <chrono>
#include <fcntl.h>
#include <sys/stat.h>
#include <ctime>

struct RuntimeStatus { uint64_t session; uint32_t state; int32_t error, services_error; uint32_t phase; };
struct Api {
    void *owner{};
    int (*init)(void *,const char *,const char *,const char *){};
    int (*window)(void *,int,int,float){}; int (*detach)(){};
    void (*foreground)(int){}; void (*input)(uint32_t,int32_t,int32_t,int32_t,int32_t){};
    int (*run)(const char *,const char *,const char *,const char *,uint64_t){};
    int (*status)(RuntimeStatus *){}; int (*stop)(){};
    int (*take_stop)(uint32_t *,char *,size_t){};
    void (*shutdown)(const char *){};
    int (*ui_available)(int){};
    int (*ui_take)(uint64_t *,char *,size_t,size_t *){};
    int (*ui_reply)(uint64_t,const char *){};
    int (*ui_cancel)(uint64_t){};
} g;
static OHNativeWindow *g_window;
static OH_NativeXComponent *g_rate_component;
static int g_requested_fps;
static bool g_rate_configured;

static void apply_requested_fps() {
    if (!g_rate_component || !g_requested_fps) return;
    OH_NativeXComponent_ExpectedRateRange range{g_requested_fps,g_requested_fps,g_requested_fps};
    int rc=OH_NativeXComponent_SetExpectedFrameRateRange(g_rate_component,&range);
    fprintf(stderr,"[OHOS xcomponent-rate] min=%d max=%d expected=%d result=%d\n",
            range.min,range.max,range.expected,rc);
}

static uint64_t g_width, g_height;
static float g_hz = 60;
static std::string g_resolution_scale="1", g_scaling_filter="Bilinear", g_widen_mode="off";
static std::atomic<bool> g_started{false}, g_finished{false}, g_stop_started{false};
static bool g_initialized=false, g_bound=false, g_log_ready=false;
static std::mutex g_text_mutex;
static std::string g_detail;
static std::string g_game, g_state, g_modules, g_names;
static uint64_t g_program;
static void detail(std::string s) {
    OH_LOG_Print(LOG_APP,LOG_INFO,0x5a5a,"S2Arm","%{public}s",s.c_str());
    std::lock_guard<std::mutex> lock(g_text_mutex); g_detail=std::move(s);
}
static napi_value str(napi_env env,const std::string &s) { napi_value v; napi_create_string_utf8(env,s.c_str(),s.size(),&v); return v; }
static std::string argstr(napi_env env,napi_value v,size_t limit=4096) {
    size_t n=0; if(napi_get_value_string_utf8(env,v,nullptr,0,&n)!=napi_ok || n>limit) return {};
    std::string s(n+1,'\0'); if(napi_get_value_string_utf8(env,v,s.data(),s.size(),&n)!=napi_ok) return {};
    s.resize(n); return s;
}
template<class T> static bool sym(T &out,const char *name) { out=reinterpret_cast<T>(dlsym(g.owner,name)); return out!=nullptr; }
static std::string load(const std::string &lang,const std::string &region,const std::string &zone) {
    if(g_initialized) {
        int rc=g_window?g.window(g_window,(int)g_width,(int)g_height,g_hz):0;
        return rc?"窗口接入失败，错误码 "+std::to_string(rc):std::string{};
    }
    if(!g.owner) g.owner=dlopen("libS2AEngine.so",RTLD_NOW|RTLD_LOCAL);
    if(!g.owner) return std::string("运行库加载失败：")+dlerror();
    bool ok=sym(g.init,"s2a_ohos_shell_init") && sym(g.window,"s2a_ohos_shell_window") && sym(g.detach,"s2a_ohos_shell_detach") &&
        sym(g.foreground,"s2a_ohos_shell_foreground") && sym(g.input,"s2a_ohos_shell_input") && sym(g.run,"s2a_ohos_shell_run") &&
        sym(g.status,"s2a_ohos_shell_status") && sym(g.stop,"s2a_ohos_shell_stop") && sym(g.take_stop,"s2a_ohos_shell_take_stop") && sym(g.shutdown,"s2a_host_shutdown") &&
        sym(g.ui_available,"s2a_ohos_ui_available") && sym(g.ui_take,"s2a_ohos_ui_take") &&
        sym(g.ui_reply,"s2a_ohos_ui_reply") && sym(g.ui_cancel,"s2a_ohos_ui_cancel");
    if(!ok) return "运行库 ABI 不完整，禁止启动";
    g_bound=true;
    int rc=g.init(g.owner,lang.c_str(),region.c_str(),zone.c_str());
    if(rc) return "宿主初始化失败，错误码 "+std::to_string(rc);
    rc=g.ui_available(1);
    if(rc) return "输入对话服务初始化失败："+std::to_string(rc);
    g_initialized=true;
    ohos_controller_init(g.owner,g.input);
    if(g_window) { rc=g.window(g_window,(int)g_width,(int)g_height,g_hz); if(rc) return "窗口接入失败，错误码 "+std::to_string(rc); }
    return {};
}
// Optional local diagnostic controls, read before the NativeAOT DSO loads.
// Only named boolean diagnostics are accepted; no general environment import.
static std::string load_diagnostics(const std::string &files) {
    const char *keys[10] = {"S2A_SHADER_OFFSET_TRACE", "S2A_SEGCHECK", "S2A_DISPLAY_TRACE", "S2A_VK_DRAW_AUDIT", "S2A_VK_FRAME_AUDIT", "S2A_VK_LOOP_AUDIT", "S2A_FIFO_WAKE_ON_FRAME", "S2A_TRACK_REUSE_READ_ALIAS", "S2A_DEMAND_SHADER_MATERIALIZATION", "S2A_OHOS_GUEST_READ_BATCH"};
    int values[10] = {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1};
    int fd = open((files+"/diagnostics.env").c_str(), O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if (fd < 0) return errno == ENOENT ? std::string{} : "无法读取诊断设置";
    struct stat st{};
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size < 0 || st.st_size > 1024) {
        close(fd); return "诊断设置格式无效";
    }
    std::string text((size_t)st.st_size, '\0');
    size_t done = 0;
    while (done < text.size()) {
        ssize_t count = read(fd, text.data()+done, text.size()-done);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); return "诊断设置读取不完整"; }
        done += (size_t)count;
    }
    close(fd);
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find('\n', pos);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(pos, end-pos); pos = end+1;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line.front() == '#') continue;
        size_t eq = line.find('=');
        if (eq == std::string::npos) return "诊断设置必须为名称=0或1";
        int selected = -1;
        for (int i=0; i<10; ++i) if (line.substr(0, eq) == keys[i]) selected=i;
        std::string value = line.substr(eq+1);
        if (selected < 0 || values[selected] >= 0 || (value != "0" && value != "1"))
            return "诊断设置包含未知、重复或无效项";
        values[selected] = value == "1";
    }
    for (int i=0; i<10; ++i)
        if (values[i] >= 0 && setenv(keys[i], values[i] ? "1" : "0", 1)) return "无法应用诊断设置";
    return {};
}

// Explicit session settings; no title-id rules and no arbitrary env import.
static napi_value display_settings(napi_env env,napi_callback_info info) {
    size_t n=3; napi_value a[3];
    if(napi_get_cb_info(env,info,&n,a,nullptr,nullptr)!=napi_ok || n!=3)
        return str(env,"缺少画面设置");
    if(g.owner || g_started.load()) return str(env,"画面设置已锁定，请重启应用后调整");
    std::string scale=argstr(env,a[0],8), filter=argstr(env,a[1],16), widen=argstr(env,a[2],16);
    if(scale!="1" && scale!="1.5" && scale!="2") return str(env,"不支持的清晰度设置");
    if(filter!="Bilinear" && filter!="Nearest") return str(env,"不支持的缩放滤镜");
    if(widen!="off" && widen!="experimental") return str(env,"不支持的画幅设置");
    g_resolution_scale=std::move(scale); g_scaling_filter=std::move(filter); g_widen_mode=std::move(widen);
    return str(env,"");
}
static std::string apply_display_settings() {
    if(!g_window || !g_width || !g_height || g_width>INT32_MAX || g_height>INT32_MAX)
        return "游戏窗口尚未就绪";
    // Freeze a single even 1080-high width before dlopen/native module loading.
    // ScreenW is cached by the real native provider on its first read.
    // Games run landscape; the window can still be portrait when the session starts
    // (Mate90: 1320x2848), which would read as a tall screen and pin the width at 1920.
    const uint64_t lw=g_width>g_height?g_width:g_height, lh=g_width>g_height?g_height:g_width;
    uint64_t normalized=((lw*1080+lh)/(2*lh))*2;
    bool wide=g_widen_mode=="experimental";
    // 比 16:9 方的屏幕（Pura X 约 1.6）：宽固定 1920，把高放出来，多显示上下的内容。
    uint64_t tall_height=((lh*1920+lw)/(2*lw))*2;
    bool tall=wide && normalized<1920 && tall_height>1080 && tall_height<=8192;
    if(tall && !getenv("S2A_NO_TALL")){ if(setenv("S2A_SCREEN_H",std::to_string(tall_height).c_str(),1)) return "无法应用画面设置"; normalized=1920; }
    else { tall=false; unsetenv("S2A_SCREEN_H"); }
    if(wide && !tall && (normalized<=1920 || normalized>8192)){ wide=false; g_widen_mode="off"; }
    // The real screen width always goes to the runtime (as on iOS); whether a title widens is the
    // native gate's call (widen_verified.tsv from the pack). "experimental" only forces it open.
    uint64_t screen_width=!tall && normalized>1920 && normalized<=8192?normalized:1920;
    std::string screen=std::to_string(screen_width);
    if(setenv("S2A_RES_SCALE",g_resolution_scale.c_str(),1) ||
       setenv("S2A_SCALING_FILTER",g_scaling_filter.c_str(),1) ||
       setenv("S2A_SCREEN_W",screen.c_str(),1) ||
       setenv("S2A_OHOS_WIDEN",g_widen_mode.c_str(),1)) return "无法应用画面设置";
    // Opt-in: open the native widen gate even for titles not on the verified list.
    if(wide && (setenv("S2A_WIDESCREEN","1",1) || setenv("S2A_WIDEN_VERIFIED","1",1))) return "无法应用画面设置";
    if(const char *trace=getenv("S2A_DISPLAY_TRACE"); trace && std::string(trace)=="1")
        fprintf(stderr,"[OHOS display input] pixels=%llux%llu normalized1080=%llu screenW=%llu aspectMode=%s scale=%s filter=%s refreshHz=%.3f\n",
            (unsigned long long)g_width,(unsigned long long)g_height,(unsigned long long)normalized,
            (unsigned long long)screen_width,g_widen_mode.c_str(),g_resolution_scale.c_str(),g_scaling_filter.c_str(),g_hz);
    return {};
}

static napi_value configure(napi_env env,napi_callback_info info) {
    size_t n=5; napi_value a[5]; napi_get_cb_info(env,info,&n,a,nullptr,nullptr);
    if(n!=5) return str(env,"缺少系统语言或窗口信息");
    double hz=0; napi_get_value_double(env,a[3],&hz); if(hz<1 || hz>1000) return str(env,"无效刷新率"); g_hz=(float)hz;
    if(!g_log_ready) {
        std::string files=argstr(env,a[4]);
        if(files.empty() || files.front()!='/') return str(env,"无效日志目录");
        auto diagnostics = load_diagnostics(files);
        if (!diagnostics.empty()) return str(env,diagnostics);
        std::string path=files+"/runtime-"+std::to_string(time(nullptr))+"-"+std::to_string(getpid())+".log";
        int fd=open(path.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);
        if(fd<0) return str(env,"创建诊断日志失败："+std::to_string(errno));
        if(dup2(fd,STDOUT_FILENO)<0 || dup2(fd,STDERR_FILENO)<0) { close(fd); return str(env,"诊断日志接入失败"); }
        close(fd);setvbuf(stdout,nullptr,_IONBF,0);setvbuf(stderr,nullptr,_IONBF,0);g_log_ready=true;
        detail("运行日志："+path);
        fprintf(stderr,"[OHOS diagnostics] shader_offset_trace=%s segcheck=%s\n",
            getenv("S2A_SHADER_OFFSET_TRACE") ? getenv("S2A_SHADER_OFFSET_TRACE") : "unset",
            getenv("S2A_SEGCHECK") ? getenv("S2A_SEGCHECK") : "unset");
    }
    auto display=apply_display_settings(); if(!display.empty()) return str(env,display);
    auto result=load(argstr(env,a[0]),argstr(env,a[1]),argstr(env,a[2])); if(!result.empty()) detail(result);
    return str(env,result);
}
// Mirrors the shared Android lifetime contract: a stop request does not prove
// guest threads have stopped. Only the run worker may clean up a failed loader.
static void *stop_worker(void *) {
    auto end=std::chrono::steady_clock::now()+std::chrono::milliseconds(1500);
    while(std::chrono::steady_clock::now()<end) {
        if(g_finished.load()) return nullptr;
        RuntimeStatus s{};
        if(g.status(&s)==0 && s.phase==4) { g.shutdown("OHOS host stop"); return nullptr; }
        usleep(10000);
    }
    detail("初始化期间停止超时，结束进程；未声称完成清理");_exit(124);
}
static void request_stop() {
    if(!g_started.load() || g_stop_started.exchange(true)) return;
    g.stop();
    pthread_t thread;
    if(pthread_create(&thread,nullptr,stop_worker,nullptr)!=0) _exit(125);
    pthread_detach(thread);
}
static void *watch_stop(void *) {
    while(!g_finished.load() && !g_stop_started.load()) {
        uint32_t reason=0; char message[512]={0};
        if(g.take_stop(&reason,message,sizeof message)) {
            detail(std::string("会话停止请求：")+message);request_stop();return nullptr;
        }
        usleep(10000);
    }
    return nullptr;
}
static void *worker(void *) {
    int rc=g.run(g_game.c_str(),g_state.c_str(),g_modules.c_str(),g_names.c_str(),g_program);
    detail("运行线程已返回，错误码 "+std::to_string(rc)+"；结束本次会话"); g_finished=true; g.shutdown("OHOS game runtime returned"); return nullptr;
}
static napi_value start(napi_env env,napi_callback_info info) {
    size_t n=5; napi_value a[5]; napi_get_cb_info(env,info,&n,a,nullptr,nullptr);
    if(n!=5 || !g_initialized || !g_window) return str(env,"运行库或显示窗口尚未就绪");
    if(g_started.load()) return str(env,"本进程已有启动任务，请重开应用再试");
    g_game=argstr(env,a[0]); g_state=argstr(env,a[1]); g_modules=argstr(env,a[2]); g_names=argstr(env,a[3]);
    std::string id=argstr(env,a[4]); char *end=nullptr; g_program=strtoull(id.c_str(),&end,16);
    if(id.size()!=16 || !end || *end || !g_program) { detail("无效游戏身份"); return str(env,"无效游戏身份"); }
    if(g_started.exchange(true)) return str(env,"本进程已有启动任务，请重开应用再试");
    // OHOS musl's default worker stack is only 128 KiB on the emulator.
    // NativeAOT service startup needs the same 8 MiB budget as the main thread.
    pthread_t thread; pthread_attr_t attr;
    int rc=pthread_attr_init(&attr);
    if(!rc) {
        rc=pthread_attr_setstacksize(&attr,8u<<20);
        if(!rc) rc=pthread_create(&thread,&attr,worker,nullptr);
        pthread_attr_destroy(&attr);
    }
    if(rc) { g_started=false;return str(env,"无法创建游戏线程："+std::to_string(rc)); }
    pthread_detach(thread);
    rc=pthread_create(&thread,nullptr,watch_stop,nullptr);
    if(rc) { detail("无法创建停止请求接收线程");request_stop();return str(env,"无法创建停止请求接收线程"); }
    pthread_detach(thread); detail("开始加载游戏"); return str(env,"");
}
static napi_value status(napi_env env,napi_callback_info) {
    napi_value out; napi_create_object(env,&out); RuntimeStatus s{}; if(g.status && g_started) g.status(&s);
    // The worker imports debug-env before entering the running state. Apply on the UI thread.
    if (!g_rate_configured && s.state == 4) {
        g_rate_configured = true;
        const char *value = std::getenv("DEBUG_S2A_XCOMPONENT_FPS");
        if (value && (!std::strcmp(value,"30") || !std::strcmp(value,"60"))) {
            g_requested_fps = std::atoi(value);
            apply_requested_fps();
        }
    }
    auto number=[&](const char *k,int32_t n){napi_value v;napi_create_int32(env,n,&v);napi_set_named_property(env,out,k,v);};
    number("state",s.state); number("phase",s.phase); number("error",s.error); number("servicesError",s.services_error);
    {std::lock_guard<std::mutex> lock(g_text_mutex);napi_set_named_property(env,out,"detail",str(env,g_detail));}
    napi_value done;napi_get_boolean(env,g_finished,&done);napi_set_named_property(env,out,"finished",done);return out;
}
static napi_value input(napi_env env,napi_callback_info info) {
    size_t n=5;napi_value a[5];napi_get_cb_info(env,info,&n,a,nullptr,nullptr);int32_t v[5]={0};
    if(n==5 && g.input) {for(int i=0;i<5;i++) if(napi_get_value_int32(env,a[i],&v[i])!=napi_ok)return str(env,"无效输入");ohos_controller_touch((uint32_t)v[0],v[1],v[2],v[3],v[4]);}
    return str(env,"");
}
static napi_value foreground(napi_env env,napi_callback_info info) {
    size_t n=1;napi_value a;bool yes=false;napi_get_cb_info(env,info,&n,&a,nullptr,nullptr);
    if(n==1 && napi_get_value_bool(env,a,&yes)==napi_ok) { ohos_controller_foreground(yes); if(g.foreground)g.foreground(yes?1:0); }return str(env,"");
}
static napi_value controller_status(napi_env env,napi_callback_info) {
    ohos_controller_init(nullptr,nullptr);auto status=ohos_controller_status();napi_value out,v;napi_create_object(env,&out);
    napi_get_boolean(env,status.available,&v);napi_set_named_property(env,out,"available",v);
    napi_get_boolean(env,status.connected,&v);napi_set_named_property(env,out,"connected",v);
    napi_set_named_property(env,out,"name",str(env,status.name));napi_set_named_property(env,out,"detail",str(env,status.detail));return out;
}
static napi_value input_blocked(napi_env env,napi_callback_info info) {
    size_t n=1;napi_value a;bool value=false;napi_get_cb_info(env,info,&n,&a,nullptr,nullptr);
    if(n==1&&napi_get_value_bool(env,a,&value)==napi_ok)ohos_controller_block(value);return str(env,"");
}
static napi_value game_feedback(napi_env env,napi_callback_info info) {
    size_t n=1;napi_value a;bool value=false;napi_get_cb_info(env,info,&n,&a,nullptr,nullptr);
    if(n!=1||napi_get_value_bool(env,a,&value)!=napi_ok)return str(env,"震动设置无效");
    ohos_controller_game_feedback(value);return str(env,value?"手机游戏震动已开启":"游戏震动已关闭");
}
static napi_value power_save(napi_env env,napi_callback_info info) {
    size_t n=1;napi_value a;bool value=false;napi_get_cb_info(env,info,&n,&a,nullptr,nullptr);
    if(n==1&&napi_get_value_bool(env,a,&value)==napi_ok){ if(value) setenv("S2A_FPS_CAP","30",1); else unsetenv("S2A_FPS_CAP"); }
    return str(env,"");
}
static napi_value allow_tall(napi_env env,napi_callback_info info) {
    size_t n=1;napi_value a;bool value=false;napi_get_cb_info(env,info,&n,&a,nullptr,nullptr);
    if(n==1&&napi_get_value_bool(env,a,&value)==napi_ok){ if(value) unsetenv("S2A_NO_TALL"); else setenv("S2A_NO_TALL","1",1); }
    return str(env,"");
}
static napi_value stop_feedback(napi_env env,napi_callback_info) {ohos_controller_stop_feedback();return str(env,"");}
// Frames the engine actually handed to the window (both graphics paths), for the optional FPS readout.
static napi_value present_count(napi_env env,napi_callback_info) {
    static uint64_t (*count)(void);
    if(!count && g.owner) count=reinterpret_cast<uint64_t(*)(void)>(dlsym(g.owner,"s2a_ohos_present_count"));
    napi_value v;napi_create_double(env,count?(double)count():-1.0,&v);return v;
}
static napi_value stop(napi_env env,napi_callback_info) {request_stop();return str(env,g_started?"已请求停止":"尚未启动");}
static uint64_t ui_id(napi_env env,napi_value value) {
    std::string text=argstr(env,value,20);
    if(text.empty() || text.size()>20 || text.front()=='0') return 0;
    for(char c:text) if(c<'0' || c>'9') return 0;
    char *end=nullptr;errno=0;
    uint64_t id=strtoull(text.c_str(),&end,10);
    return errno || !end || *end ? 0 : id;
}
static napi_value ui_take(napi_env env,napi_callback_info) {
    napi_value out; napi_create_object(env,&out);
    uint64_t id=0;size_t length=0;char request[4097]={0};
    int rc=g.ui_take && g_started && !g_finished && !g_stop_started
        ? g.ui_take(&id,request,sizeof request,&length) : -6;
    napi_value code;napi_create_int32(env,rc,&code);napi_set_named_property(env,out,"error",code);
    napi_set_named_property(env,out,"id",str(env,rc==0?std::to_string(id):""));
    napi_set_named_property(env,out,"request",str(env,rc==0?std::string(request,length):""));
    return out;
}
static napi_value ui_reply(napi_env env,napi_callback_info info) {
    size_t n=2;napi_value a[2];napi_get_cb_info(env,info,&n,a,nullptr,nullptr);
    uint64_t id=n==2?ui_id(env,a[0]):0;std::string reply=n==2?argstr(env,a[1],8192):"";
    int rc=id && !reply.empty() && g.ui_reply && !g_finished && !g_stop_started
        ? g.ui_reply(id,reply.c_str()) : -1;
    napi_value code;napi_create_int32(env,rc,&code);return code;
}
static napi_value ui_cancel(napi_env env,napi_callback_info info) {
    size_t n=1;napi_value value;napi_get_cb_info(env,info,&n,&value,nullptr,nullptr);
    uint64_t id=n==1?ui_id(env,value):0;int rc=id && g.ui_cancel?g.ui_cancel(id):-1;
    napi_value code;napi_create_int32(env,rc,&code);return code;
}
static void created(OH_NativeXComponent *c,void *w) {
    g_rate_component = c;
    apply_requested_fps();
    g_window=static_cast<OHNativeWindow *>(w);OH_NativeWindow_NativeObjectReference(g_window);
    OH_NativeXComponent_GetXComponentSize(c,w,&g_width,&g_height);
    if(g_initialized){int rc=g.window(w,(int)g_width,(int)g_height,g_hz);if(rc)detail("窗口创建失败："+std::to_string(rc));}
}
static void changed(OH_NativeXComponent *c,void *w) {
    OH_NativeXComponent_GetXComponentSize(c,w,&g_width,&g_height);
    if(g_initialized)g.window(w,(int)g_width,(int)g_height,g_hz);
}
static void destroyed(OH_NativeXComponent *c,void *) {
    if (g_rate_component == c) g_rate_component = nullptr;
    int rc=g_initialized?g.detach():0;
    if(rc){detail("窗口回收超时，结束本调试进程以保护已被销毁的表面");_exit(70);}
    if(g_window)OH_NativeWindow_NativeObjectUnreference(g_window);g_window=nullptr;
}
static void touch(OH_NativeXComponent *,void *) {}
static OH_NativeXComponent_Callback callbacks={created,changed,destroyed,touch};
static napi_value init(napi_env env,napi_value exports) {
    napi_property_descriptor p[]={
        {"configure",nullptr,configure,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"displaySettings",nullptr,display_settings,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"start",nullptr,start,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"status",nullptr,status,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"input",nullptr,input,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"foreground",nullptr,foreground,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"stop",nullptr,stop,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"controllerStatus",nullptr,controller_status,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"inputBlocked",nullptr,input_blocked,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"gameFeedback",nullptr,game_feedback,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"powerSave",nullptr,power_save,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"allowTall",nullptr,allow_tall,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"stopFeedback",nullptr,stop_feedback,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"uiTake",nullptr,ui_take,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"uiReply",nullptr,ui_reply,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"uiCancel",nullptr,ui_cancel,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"presentCount",nullptr,present_count,nullptr,nullptr,nullptr,napi_default,nullptr}};
    napi_define_properties(env,exports,sizeof p/sizeof p[0],p);
    napi_value value;OH_NativeXComponent *c=nullptr;
    if(napi_get_named_property(env,exports,OH_NATIVE_XCOMPONENT_OBJ,&value)==napi_ok && napi_unwrap(env,value,(void **)&c)==napi_ok && c)
        OH_NativeXComponent_RegisterCallback(c,&callbacks);
    return exports;
}
static napi_module module={1,0,nullptr,init,"s2aprobehost",nullptr,{0}};
extern "C" __attribute__((constructor)) void RegisterS2Arm() { napi_module_register(&module); }
