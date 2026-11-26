#include "controller_ohos.h"
#include <GameControllerKit/game_pad.h>
#include <GameControllerKit/game_device.h>
#include <sensors/vibrator.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <mutex>
#include <atomic>
#include <cstdlib>

namespace {
std::mutex mu, vibrator_mu;
std::atomic<bool> vibration_allowed{false};
struct OwnedText { char *value=nullptr; ~OwnedText() {std::free(value);} };
void cancel_vibrator() {std::lock_guard<std::mutex> lock(vibrator_mu);OH_Vibrator_Cancel();}
void (*send_input)(uint32_t,int32_t,int32_t,int32_t,int32_t);
void (*feedback_state)(int,int);
float (*feedback_read)();
uint32_t touch_bits, pad_bits;
int32_t touch_axes[4]{},pad_axes[4]{};
bool available, connected, blocked, foreground=true, neutral_required, feedback_enabled;
bool initialized, feedback_started;
std::string selected_id, device_name, status_detail="尚未初始化";
int32_t axis(double v) {
    if(!std::isfinite(v)||std::abs(v)<0.14) return 0;
    double a=(std::min(1.0,std::abs(v))-0.14)/0.86;
    return (int32_t)std::lround(std::copysign(a,v)*32767);
}
void publish() { // mu held; touch and physical controller are independent sources.
    if(!send_input) return;
    bool neutral=pad_bits==0;
    for(int i=0;i<4;i++) neutral=neutral&&pad_axes[i]==0;
    if(neutral) neutral_required=false;
    if(blocked||!foreground) { send_input(0,0,0,0,0); return; }
    int32_t a[4];
    for(int stick=0;stick<2;stick++) {int i=stick*2;bool touch=touch_axes[i]||touch_axes[i+1];a[i]=touch?touch_axes[i]:(neutral_required?0:pad_axes[i]);a[i+1]=touch?touch_axes[i+1]:(neutral_required?0:pad_axes[i+1]);}
    send_input(touch_bits|(neutral_required?0:pad_bits),a[0],a[1],a[2],a[3]);
}
bool device_matches(const GamePad_ButtonEvent *event) {
    OwnedText id;
    return OH_GamePad_ButtonEvent_GetDeviceId(event,&id.value)==GAME_CONTROLLER_SUCCESS && id.value && selected_id==id.value;
}
template<unsigned Bit> void button(const GamePad_ButtonEvent *event) {
    std::lock_guard<std::mutex> lock(mu);
    GamePad_Button_ActionType action;
    if(!connected||!device_matches(event)||OH_GamePad_ButtonEvent_GetButtonAction(event,&action)!=GAME_CONTROLLER_SUCCESS) return;
    if(action==DOWN) pad_bits|=1u<<Bit; else if(action==UP) pad_bits&=~(1u<<Bit);
    publish();
}
void axes(const GamePad_AxisEvent *event) {
    std::lock_guard<std::mutex> lock(mu);
    OwnedText id; GamePad_AxisSourceType source;
    if(!connected||OH_GamePad_AxisEvent_GetDeviceId(event,&id.value)!=GAME_CONTROLLER_SUCCESS||!id.value||selected_id!=id.value||
       OH_GamePad_AxisEvent_GetAxisSourceType(event,&source)!=GAME_CONTROLLER_SUCCESS) return;
    double x=0,y=0;
    if(source==LEFT_THUMBSTICK) {
        if(OH_GamePad_AxisEvent_GetXAxisValue(event,&x)!=0||OH_GamePad_AxisEvent_GetYAxisValue(event,&y)!=0) return;
        pad_axes[0]=axis(x); pad_axes[1]=-axis(y);
    } else if(source==RIGHT_THUMBSTICK) {
        if(OH_GamePad_AxisEvent_GetZAxisValue(event,&x)!=0||OH_GamePad_AxisEvent_GetRZAxisValue(event,&y)!=0) return;
        pad_axes[2]=axis(x); pad_axes[3]=-axis(y);
    } else if(source==DPAD) {
        if(OH_GamePad_AxisEvent_GetHatXAxisValue(event,&x)!=0||OH_GamePad_AxisEvent_GetHatYAxisValue(event,&y)!=0) return;
        pad_bits&=~(15u<<12);
        if(x<-.5)pad_bits|=1u<<12; if(x>.5)pad_bits|=1u<<14;
        if(y<-.5)pad_bits|=1u<<13; if(y>.5)pad_bits|=1u<<15;
    } else if(source==LEFT_TRIGGER||source==RIGHT_TRIGGER) {
        int rc=source==LEFT_TRIGGER?OH_GamePad_AxisEvent_GetBrakeAxisValue(event,&x):OH_GamePad_AxisEvent_GetGasAxisValue(event,&x);
        if(rc) return;
        uint32_t bit=1u<<(source==LEFT_TRIGGER?8:9);
        if(x>.25)pad_bits|=bit; else if(x<.15)pad_bits&=~bit;
    }
    publish();
}
void read_device(GameDevice_DeviceInfo *info,bool online) { // mu held
    OwnedText id,name; GameDevice_DeviceType type;
    if(OH_GameDevice_DeviceInfo_GetDeviceType(info,&type)!=0||type!=GAME_PAD||
       OH_GameDevice_DeviceInfo_GetDeviceId(info,&id.value)!=0||!id.value) return;
    if(online && (!connected||selected_id==id.value)) {
        if(selected_id!=id.value) { pad_bits=0; std::fill(pad_axes,pad_axes+4,0); neutral_required=true; }
        selected_id=id.value; connected=true;
        OH_GameDevice_DeviceInfo_GetName(info,&name.value); device_name=name.value?name.value:"实体手柄";
    } else if(!online&&selected_id==id.value) {
        connected=false; selected_id.clear(); device_name.clear(); pad_bits=0; std::fill(pad_axes,pad_axes+4,0);
    }
    publish();
}
void device_event(const GameDevice_DeviceEvent *event) {
    GameDevice_StatusChangedType status; GameDevice_DeviceInfo *info=nullptr;
    if(OH_GameDevice_DeviceEvent_GetChangedType(event,&status)!=0||OH_GameDevice_DeviceEvent_GetDeviceInfo(event,&info)!=0) return;
    { std::lock_guard<std::mutex> lock(mu); read_device(info,status==ONLINE); }
    OH_GameDevice_DestroyDeviceInfo(&info);
}
void *feedback_worker(void *) {
    bool vibrating=false;
    for(;;) {
        std::unique_lock<std::mutex> vibration_lock(vibrator_mu);
        float amount=vibration_allowed.load()&&feedback_read?feedback_read():0;
        if(amount>0.01f) {
            // Phone motor is a bounded approximation, not dual-frequency controller HD rumble.
            Vibrator_Attribute attr{0,VIBRATOR_USAGE_PHYSICAL_FEEDBACK};
            int rc=OH_Vibrator_PlayVibration((int32_t)(12+std::min(1.f,amount)*32),attr);
            if(rc!=0) { static bool logged=false; if(!logged) { fprintf(stderr,"[OHOS rumble] phone vibrator unavailable rc=%d\n",rc);logged=true; } }
            vibrating=rc==0;
        } else if(vibrating) { OH_Vibrator_Cancel(); vibrating=false; }
        vibration_lock.unlock();
        usleep(50000);
    }
    return nullptr;
}
void refresh_feedback() { vibration_allowed=feedback_enabled&&foreground&&!blocked; if(feedback_state)feedback_state(feedback_enabled,foreground&&!blocked); }
}
void ohos_controller_init(void *engine,void (*input)(uint32_t,int32_t,int32_t,int32_t,int32_t)) {
    if(engine) {
        std::lock_guard<std::mutex> lock(mu);
        send_input=input;
        feedback_state=reinterpret_cast<void(*)(int,int)>(dlsym(engine,"s2a_ohos_feedback_state"));
        feedback_read=reinterpret_cast<float(*)()>(dlsym(engine,"s2a_ohos_feedback_read"));
        refresh_feedback();
        if(feedback_read&&!feedback_started) {pthread_t thread;int rc=pthread_create(&thread,nullptr,feedback_worker,nullptr);if(!rc){pthread_detach(thread);feedback_started=true;}else fprintf(stderr,"[OHOS rumble] worker failed rc=%d\n",rc);}
    }
    if(initialized)return;
    initialized=true;
    int errors=OH_GameDevice_RegisterDeviceMonitor(device_event)!=0?1:0;
#define REG(name,bit) if(OH_GamePad_##name##_RegisterButtonInputMonitor(button<bit>)!=0)errors++
    REG(ButtonA,0);REG(ButtonB,1);REG(ButtonX,2);REG(ButtonY,3);
    REG(LeftThumbstick,4);REG(RightThumbstick,5);REG(LeftShoulder,6);REG(RightShoulder,7);
    REG(LeftTrigger,8);REG(RightTrigger,9);REG(ButtonMenu,10);REG(ButtonHome,11);
    REG(Dpad_LeftButton,12);REG(Dpad_UpButton,13);REG(Dpad_RightButton,14);REG(Dpad_DownButton,15);
#undef REG
#define AXIS(name) if(OH_GamePad_##name##_RegisterAxisInputMonitor(axes)!=0)errors++
    AXIS(LeftThumbstick);AXIS(RightThumbstick);AXIS(Dpad);AXIS(LeftTrigger);AXIS(RightTrigger);
#undef AXIS
    available=errors==0; status_detail=available?"支持实体手柄按键与摇杆；手柄马达震动尚不支持":"手柄服务注册不完整";
    GameDevice_AllDeviceInfos *all=nullptr;
    if(OH_GameDevice_GetAllDeviceInfos(&all)==0) {
        int32_t count=0; OH_GameDevice_AllDeviceInfos_GetCount(all,&count);
        for(int32_t i=0;i<count&&i<32;i++) {
            GameDevice_DeviceInfo *info=nullptr;
            if(OH_GameDevice_AllDeviceInfos_GetDeviceInfo(all,i,&info)==0) {
                {std::lock_guard<std::mutex>lock(mu);read_device(info,true);}
                OH_GameDevice_DestroyDeviceInfo(&info);
            }
        }
        OH_GameDevice_DestroyAllDeviceInfos(&all);
    }
    refresh_feedback();
    fprintf(stderr,"[OHOS controller] registered=%d errors=%d connected=%d; independent touch/pad sources\n",available,errors,connected);
}
void ohos_controller_touch(uint32_t b,int32_t lx,int32_t ly,int32_t rx,int32_t ry) {
    std::lock_guard<std::mutex>lock(mu);touch_bits=(blocked||!foreground)?0:b;
    int32_t values[]={lx,ly,rx,ry};
    for(int i=0;i<4;i++)touch_axes[i]=(blocked||!foreground)?0:std::clamp(values[i],-32768,32767);
    publish();
}
void ohos_controller_block(bool value) {
    std::lock_guard<std::mutex>lock(mu);blocked=value;touch_bits=0;std::fill(touch_axes,touch_axes+4,0);neutral_required=true;
    publish();refresh_feedback();if(value)cancel_vibrator();
}
void ohos_controller_foreground(bool value) {
    std::lock_guard<std::mutex>lock(mu);foreground=value;touch_bits=0;std::fill(touch_axes,touch_axes+4,0);neutral_required=true;
    publish();refresh_feedback();if(!value)cancel_vibrator();
}
void ohos_controller_game_feedback(bool value) {
    std::lock_guard<std::mutex>lock(mu);feedback_enabled=value;refresh_feedback();if(!value)cancel_vibrator();
}
void ohos_controller_stop_feedback() {
    std::lock_guard<std::mutex>lock(mu);vibration_allowed=false;if(feedback_state)feedback_state(0,0);cancel_vibrator();
}
OhosControllerStatus ohos_controller_status() {
    std::lock_guard<std::mutex>lock(mu);return {available,connected,device_name,status_detail};
}
