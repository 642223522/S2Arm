// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Real production power policy + raw reader; audit only this process's HID writes.
#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDManager.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static unsigned raw_config_writes;
static IOReturn audited_output(IOHIDDeviceRef d, IOHIDReportType type, CFIndex id, const uint8_t *p, CFIndex n) {
    int pid=0; CFTypeRef value=IOHIDDeviceGetProperty(d,CFSTR(kIOHIDProductIDKey));
    if (value && CFGetTypeID(value)==CFNumberGetTypeID()) CFNumberGetValue(value,kCFNumberIntType,&pid);
    if (pid==0x2009 && id == 1 && n >= 12 && (p[10] == 0x40 || p[10] == 0x03)) {
        raw_config_writes++;
        fprintf(stderr,"[pro-motion] event=raw_configuration cmd=0x%02x arg=0x%02x\n",p[10],p[11]);
    }
    return IOHIDDeviceSetReport(d,type,id,p,n);
}
#define IOHIDDeviceSetReport audited_output
#include "joycon_imu.m"
#undef IOHIDDeviceSetReport
#include "motion_power.h"

static GCMotion *probe_motion(void) {
    for (GCController *c in GCController.controllers) {
        NSString *category=c.productCategory;
        if (s2a_pad_kind(category.UTF8String,0,0)==S2A_PAD_KIND_NINTENDO && !s2a_pad_is_ns2(category.UTF8String) &&
            [category rangeOfString:@"pro" options:NSCaseInsensitiveSearch].location!=NSNotFound) return c.motion;
    }
    return nil;
}

static volatile sig_atomic_t stopped;
static void interrupt_probe(int sig) { (void)sig; stopped=1; }
int main(int argc, char **argv) { @autoreleasepool {
    if (argc == 2 && (!strcmp(argv[1],"--help") || !strcmp(argv[1],"-h"))) {
        puts("Usage: pro_motion_probe [seconds, default 20, maximum 30]\nUses public GameController sensor power and passive Pro HID samples. No game build.\nTilt, dock, undock and tilt again. Do not send manual IMU commands."); return 0;
    }
    char *tail=NULL; long seconds=argc==2?strtol(argv[1],&tail,10):20;
    if (argc>2 || seconds<1 || seconds>30 || (tail && (*tail || tail==argv[1]))) { fputs("Duration must be 1..30 seconds.\n",stderr); return 2; }
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    GCController.shouldMonitorBackgroundEvents=YES;
    signal(SIGINT,interrupt_probe); signal(SIGTERM,interrupt_probe);
    GCMotion *controlled=nil; s2a_motion_power_select(&controlled,probe_motion(),nil);
    s2a_joycon_imu_set_enabled(1);
    printf("Running for %ld seconds. Tilt, dock until disconnected, undock/reconnect, and tilt. No i command.\n",seconds); fflush(stdout);
    uint64_t start=clock_gettime_nsec_np(CLOCK_UPTIME_RAW), until=start+(uint64_t)seconds*1000000000, next=start;
    unsigned samples=0, connections=0; BOOL saw_native=NO, healthy=NO; uint64_t last=0;
    GCMotion *last_profile=nil;
    while (!stopped && clock_gettime_nsec_np(CLOCK_UPTIME_RAW)<until) {
        NSEvent *e=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:.02] inMode:NSDefaultRunLoopMode dequeue:YES];
        if (e) [NSApp sendEvent:e];
        s2a_motion_power_select(&controlled,probe_motion(),nil);
        GCMotion *m=controlled;
        if (m!=last_profile) { if (m) connections++; last_profile=m; }
        s2a_pad_motion sample={0}; s2a_joycon_info list[16]; int n=s2a_joycon_list(list,16), known=0;
        for (int i=0;i<n;i++) if (list[i].pid==0x2009 && s2a_joycon_imu_read_id(list[i].id,&sample)) { known=1; break; }
        if (known && sample.host_timestamp_us!=last) { last=sample.host_timestamp_us; samples++; }
        healthy=known && (sample.acceleration_x || sample.acceleration_y || sample.acceleration_z || sample.gyro_x || sample.gyro_y || sample.gyro_z);
        uint64_t now=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now>=next) {
            saw_native |= m!=nil;
            fprintf(stderr,"[pro-motion] elapsed_ms=%llu connection=%u profiles=%d manual=%d active=%d rotation=%d separated_gravity=%d known=%d samples=%u raw_config_writes=%u accel_g=%.3f,%.3f,%.3f gyro_deg_s=%.3f,%.3f,%.3f public_accel_g=%.3f,%.3f,%.3f\n",
                    (unsigned long long)((now-start)/1000000),connections,m!=nil,m.sensorsRequireManualActivation,m.sensorsActive,m.hasRotationRate,m.hasGravityAndUserAcceleration,
                    known,samples,raw_config_writes,sample.acceleration_x,sample.acceleration_y,sample.acceleration_z,sample.gyro_x,sample.gyro_y,sample.gyro_z,
                    m.acceleration.x,m.acceleration.y,m.acceleration.z);
            next=now+1000000000;
        }
    }
    s2a_joycon_imu_set_enabled(0); s2a_motion_power_select(&controlled,nil,nil);
    fprintf(stderr,"[pro-motion] event=end connection=%u samples=%u healthy=%d saw_native=%d raw_config_writes=%u\n",connections,samples,healthy,saw_native,raw_config_writes);
    puts("Probe finished; installed S2Arm and game data were not changed.");
    return !samples || !healthy || (saw_native && raw_config_writes) ? 1 : 0;
} }
