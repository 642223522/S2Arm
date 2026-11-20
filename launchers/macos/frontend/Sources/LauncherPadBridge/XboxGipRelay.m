// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 启动器常驻独占 Xbox 有线手柄（USB GIP）并通过本机 Unix 域套接字转发给 s2arm-host。
// 切换游戏时只断开 / 重连本机套接字，不释放 USB 独占权，防止后台 Chromium 系浏览器
// （Chrome / 115Browser / Electron 等）的 XboxDataFetcherMac 在切游戏空档抢占设备。
#import "LauncherPadBridge.h"
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#define S2A_XBOX_GIP_IOKIT 1
#include "../../../../../macos/xbox_gip_relay.h"
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

enum { S2A_XBOX_RELAY_MAX_CLIENTS = 4 };

typedef struct {
    int active;
    int connected;
    uint64_t entry;
    uint32_t vid, pid;
    uint32_t buttons;
    int16_t ax[4];
    char name[96];
    IOUSBInterfaceInterface **intf;
    int in_pipe;
} relay_slot;

static pthread_mutex_t g_relay_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_send_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_running = 0;
static int g_usb_enabled = 0;
static int g_listen_fd = -1;
static int g_clients[S2A_XBOX_RELAY_MAX_CLIENTS];
static char g_socket_path[104];
static relay_slot g_slots[S2A_XBOX_GIP_RELAY_MAX];
static s2a_xbox_gip_status_cb g_status_cb = NULL;
static void *g_status_ctx = NULL;
static pthread_t g_accept_th;
static int g_accept_th_valid = 0;
static pthread_t g_usb_th;
static int g_usb_th_valid = 0;
static CFRunLoopRef g_usb_rl = NULL;

static void notify_status(const char *name, int connected, const char *blocked_by) {
    pthread_mutex_lock(&g_relay_mu);
    s2a_xbox_gip_status_cb cb = g_status_cb;
    void *ctx = g_status_ctx;
    pthread_mutex_unlock(&g_relay_mu);
    if (cb) cb(name ? name : "Xbox Controller", connected, blocked_by ? blocked_by : "", ctx);
}

static void broadcast_packet(const s2a_xbox_gip_relay_packet *pkt) {
    pthread_mutex_lock(&g_send_mu);
    for (int i = 0; i < S2A_XBOX_RELAY_MAX_CLIENTS; i++) {
        int fd = g_clients[i];
        if (fd < 0) continue;
        if (s2a_xbox_gip_write_all(fd, pkt, sizeof(*pkt)) != 0) {
            shutdown(fd, SHUT_RDWR);
            close(fd);
            g_clients[i] = -1;
        }
    }
    pthread_mutex_unlock(&g_send_mu);
}

static s2a_xbox_gip_relay_packet make_slot_packet(int idx, const relay_slot *s, int connected) {
    s2a_xbox_gip_relay_packet pkt;
    memset(&pkt, 0, sizeof(pkt));
    pkt.magic = S2A_XBOX_GIP_RELAY_MAGIC;
    pkt.version = S2A_XBOX_GIP_RELAY_VERSION;
    pkt.flags = connected ? S2A_XBOX_GIP_FLAG_CONNECTED : 0;
    pkt.slot = (uint8_t)idx;
    pkt.vid = s->vid;
    pkt.pid = s->pid;
    pkt.buttons = connected ? s->buttons : 0;
    if (connected) memcpy(pkt.ax, s->ax, sizeof(pkt.ax));
    strlcpy(pkt.name, s->name[0] ? s->name : "Xbox Controller", sizeof(pkt.name));
    return pkt;
}

static int xbox_is_gc_listed(void) {
    for (GCController *gc in [GCController controllers]) {
        NSString *prod = [gc.productCategory lowercaseString];
        NSString *vend = [gc.vendorName lowercaseString];
        if ([prod containsString:@"xbox"] || [vend containsString:@"microsoft"] || [vend containsString:@"xbox"]) {
            return 1;
        }
    }
    return 0;
}

static int sleep_interruptible_ms(int total_ms) {
    int elapsed = 0;
    while (elapsed < total_ms) {
        pthread_mutex_lock(&g_relay_mu);
        int run = g_running;
        pthread_mutex_unlock(&g_relay_mu);
        if (!run) return 0;
        int step = (total_ms - elapsed) < 100 ? (total_ms - elapsed) : 100;
        usleep((useconds_t)step * 1000u);
        elapsed += step;
    }
    return 1;
}

typedef struct {
    io_service_t dev;
    int slot;
    uint32_t vid, pid;
} xbox_relay_worker_ctx;

static void *xbox_relay_usb_worker(void *arg) {
    xbox_relay_worker_ctx *ctx = (xbox_relay_worker_ctx *)arg;
    io_service_t dev = ctx->dev;
    int slot = ctx->slot;
    uint32_t vid = ctx->vid, pid = ctx->pid;
    free(ctx);

    char name[96] = "Xbox Controller";
    pthread_mutex_lock(&g_relay_mu);
    strlcpy(name, g_slots[slot].name, sizeof(name));
    pthread_mutex_unlock(&g_relay_mu);

    if (s2a_xbox_usb_has_hid_child(dev) || xbox_is_gc_listed()) {
        fprintf(stderr, "[输入] Xbox GIP 中继 %s：系统已识别该手柄（HID / GameController），不独占抢占\n", name);
        goto cleanup_slot;
    }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(dev, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    if (kr != KERN_SUCCESS || !plug) {
        fprintf(stderr, "[输入] Xbox GIP 中继 %s：IOCreatePlugInInterfaceForService 失败 0x%x\n", name, kr);
        goto cleanup_slot;
    }

    IOUSBDeviceInterface **devIntf = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&devIntf);
    (*plug)->Release(plug);
    if (!devIntf) {
        fprintf(stderr, "[输入] Xbox GIP 中继 %s：QueryInterface kIOUSBDeviceInterfaceID 失败\n", name);
        goto cleanup_slot;
    }

    int opened = 0;
    int logged_busy = 0;
    char last_owner[128] = "";
    for (;;) {
        pthread_mutex_lock(&g_relay_mu);
        int run = g_running;
        pthread_mutex_unlock(&g_relay_mu);
        if (!run) break;

        if (s2a_xbox_usb_has_hid_child(dev) || xbox_is_gc_listed()) {
            fprintf(stderr, "[输入] Xbox GIP 中继 %s：系统已识别该手柄（HID / GameController），放弃独占\n", name);
            kr = kIOReturnSuccess;
            break;
        }

        kr = (*devIntf)->USBDeviceOpenSeize(devIntf);
        if (kr != kIOReturnSuccess) kr = (*devIntf)->USBDeviceOpen(devIntf);
        if (kr == kIOReturnSuccess) {
            opened = 1;
            break;
        }
        if (kr == kIOReturnExclusiveAccess) {
            char owner[128] = "";
            s2a_xbox_usb_exclusive_owner(dev, owner, sizeof(owner));
            if (!logged_busy || strcmp(owner, last_owner) != 0) {
                if (owner[0]) {
                    fprintf(stderr, "[输入] Xbox GIP 中继 %s：USB 接口正被 %s 占用，等待释放（关闭该进程后自动接管）...\n", name, owner);
                } else {
                    fprintf(stderr, "[输入] Xbox GIP 中继 %s：USB 接口被外部进程占用，等待释放...\n", name);
                }
                strlcpy(last_owner, owner, sizeof(last_owner));
                logged_busy = 1;
                notify_status(name, 0, owner);
            }
            uint64_t check_entry = 0;
            if (IORegistryEntryGetRegistryEntryID(dev, &check_entry) != KERN_SUCCESS) {
                kr = kIOReturnNoDevice;
                break;
            }
            if (!sleep_interruptible_ms(1000)) break;
        } else {
            break;
        }
    }

    if (!opened) {
        if (kr != kIOReturnSuccess) {
            fprintf(stderr, "[输入] Xbox GIP 中继 %s：打开 USB 设备失败 0x%08x\n", name, kr);
        }
        (*devIntf)->Release(devIntf);
        goto cleanup_slot;
    }

    (*devIntf)->SetConfiguration(devIntf, 1);

    IOUSBFindInterfaceRequest intfReq = {
        .bInterfaceClass = 0xFF,
        .bInterfaceSubClass = 0x47,
        .bInterfaceProtocol = 0xD0,
        .bAlternateSetting = kIOUSBFindInterfaceDontCare
    };
    io_iterator_t intfIter = 0;
    kr = (*devIntf)->CreateInterfaceIterator(devIntf, &intfReq, &intfIter);
    if (kr != kIOReturnSuccess || !intfIter) {
        (*devIntf)->USBDeviceClose(devIntf);
        (*devIntf)->Release(devIntf);
        goto cleanup_slot;
    }

    io_service_t intfService = 0;
    IOUSBInterfaceInterface **intf = NULL;
    int inPipe = -1, outPipe = -1;
    while ((intfService = IOIteratorNext(intfIter)) != 0) {
        IOCFPlugInInterface **intfPlug = NULL;
        kr = IOCreatePlugInInterfaceForService(intfService, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &intfPlug, &score);
        IOObjectRelease(intfService);
        if (kr != KERN_SUCCESS || !intfPlug) continue;

        IOUSBInterfaceInterface **candidate = NULL;
        (*intfPlug)->QueryInterface(intfPlug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)&candidate);
        (*intfPlug)->Release(intfPlug);
        if (!candidate) continue;

        kr = (*candidate)->USBInterfaceOpen(candidate);
        if (kr != kIOReturnSuccess) {
            (*candidate)->Release(candidate);
            continue;
        }

        UInt8 numPipes = 0;
        (*candidate)->GetNumEndpoints(candidate, &numPipes);
        int curIn = -1, curOut = -1;
        for (int p = 1; p <= numPipes; p++) {
            UInt8 direction = 0, number = 0, transferType = 0, interval = 0;
            UInt16 maxPacketSize = 0;
            (*candidate)->GetPipeProperties(candidate, p, &direction, &number, &transferType, &maxPacketSize, &interval);
            if (direction == kUSBIn && transferType == kUSBInterrupt) curIn = p;
            if (direction == kUSBOut && transferType == kUSBInterrupt) curOut = p;
        }

        if (curIn > 0 && curOut > 0) {
            intf = candidate;
            inPipe = curIn;
            outPipe = curOut;
            break;
        }
        (*candidate)->USBInterfaceClose(candidate);
        (*candidate)->Release(candidate);
    }
    IOObjectRelease(intfIter);

    if (!intf) {
        fprintf(stderr, "[输入] Xbox GIP 中继 %s：未找到匹配 GIP (0xFF/0x47/0xD0) 且具备端点的接口\n", name);
        (*devIntf)->USBDeviceClose(devIntf);
        (*devIntf)->Release(devIntf);
        goto cleanup_slot;
    }

    if (outPipe > 0) {
        static const uint8_t init_power[] = { 0x05, 0x20, 0x00, 0x01, 0x00 };
        static const uint8_t init_wake[]  = { 0x05, 0x20, 0x00, 0x0f, 0x06 };
        (*intf)->WritePipe(intf, outPipe, (void *)init_power, sizeof(init_power));
        (*intf)->WritePipe(intf, outPipe, (void *)init_wake, sizeof(init_wake));
    }

    s2a_xbox_gip_relay_packet online_pkt;
    pthread_mutex_lock(&g_relay_mu);
    g_slots[slot].connected = 1;
    g_slots[slot].intf = intf;
    g_slots[slot].in_pipe = inPipe;
    online_pkt = make_slot_packet(slot, &g_slots[slot], 1);
    pthread_mutex_unlock(&g_relay_mu);

    fprintf(stderr, "[输入] Xbox GIP 中继 %s（厂商 / 产品号 0x%04x / 0x%04x）：已由 S2Arm 独占接管并完成 GIP 唤醒，切换游戏不释放 USB\n",
            name, vid, pid);
    broadcast_packet(&online_pkt);
    notify_status(name, 1, "");

    uint8_t report[64];
    for (;;) {
        pthread_mutex_lock(&g_relay_mu);
        int run = g_running;
        pthread_mutex_unlock(&g_relay_mu);
        if (!run) break;

        UInt32 size = sizeof(report);
        kr = (*intf)->ReadPipe(intf, inPipe > 0 ? inPipe : 1, report, &size);
        if (kr != kIOReturnSuccess) break;

        uint8_t ack[13];
        int ack_len = s2a_xbox_gip_build_ack(report, size, ack);
        if (ack_len > 0 && outPipe > 0) {
            (*intf)->WritePipe(intf, outPipe, ack, (UInt32)ack_len);
        }

        uint32_t bt = 0;
        int16_t ax[4] = {0};
        if (s2a_xbox_gip_parse_report(report, size, &bt, ax)) {
            s2a_xbox_gip_relay_packet pkt;
            pthread_mutex_lock(&g_relay_mu);
            g_slots[slot].buttons = bt;
            memcpy(g_slots[slot].ax, ax, sizeof(g_slots[slot].ax));
            pkt = make_slot_packet(slot, &g_slots[slot], 1);
            pthread_mutex_unlock(&g_relay_mu);
            broadcast_packet(&pkt);
        }
    }

    s2a_xbox_gip_relay_packet off_pkt;
    pthread_mutex_lock(&g_relay_mu);
    g_slots[slot].intf = NULL;
    g_slots[slot].in_pipe = 0;
    g_slots[slot].connected = 0;
    off_pkt = make_slot_packet(slot, &g_slots[slot], 0);
    pthread_mutex_unlock(&g_relay_mu);

    fprintf(stderr, "[输入] Xbox GIP 中继：断开 %s\n", name);
    broadcast_packet(&off_pkt);
    notify_status(name, 0, "");

    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
    (*devIntf)->USBDeviceClose(devIntf);
    (*devIntf)->Release(devIntf);

cleanup_slot:
    IOObjectRelease(dev);
    pthread_mutex_lock(&g_relay_mu);
    memset(&g_slots[slot], 0, sizeof(g_slots[slot]));
    pthread_mutex_unlock(&g_relay_mu);
    return NULL;
}

static void xbox_relay_device_matched(void *refcon, io_iterator_t iterator) {
    (void)refcon;
    io_service_t dev;
    while ((dev = IOIteratorNext(iterator)) != 0) {
        int vid = 0, pid = 0;
        CFNumberRef nVid = (CFNumberRef)IORegistryEntryCreateCFProperty(dev, CFSTR(kUSBVendorID), kCFAllocatorDefault, 0);
        CFNumberRef nPid = (CFNumberRef)IORegistryEntryCreateCFProperty(dev, CFSTR(kUSBProductID), kCFAllocatorDefault, 0);
        if (nVid) { CFNumberGetValue(nVid, kCFNumberIntType, &vid); CFRelease(nVid); }
        if (nPid) { CFNumberGetValue(nPid, kCFNumberIntType, &pid); CFRelease(nPid); }

        if (!s2a_xbox_gip_is_device(vid, pid)) {
            IOObjectRelease(dev);
            continue;
        }
        if (s2a_xbox_usb_has_hid_child(dev) || xbox_is_gc_listed()) {
            fprintf(stderr, "[输入] Xbox GIP 中继：发现 Xbox 手柄（0x%04x:0x%04x），系统已有 HID / GameController 驱动挂载，交由原生路径\n", vid, pid);
            IOObjectRelease(dev);
            continue;
        }

        uint64_t entry = 0;
        IORegistryEntryGetRegistryEntryID(dev, &entry);

        pthread_mutex_lock(&g_relay_mu);
        if (!g_running) {
            pthread_mutex_unlock(&g_relay_mu);
            IOObjectRelease(dev);
            continue;
        }
        int dup = 0, slot = -1;
        for (int i = 0; i < S2A_XBOX_GIP_RELAY_MAX; i++) {
            if (g_slots[i].active && entry && g_slots[i].entry == entry) { dup = 1; break; }
            if (!g_slots[i].active && slot < 0) slot = i;
        }
        if (dup || slot < 0) {
            pthread_mutex_unlock(&g_relay_mu);
            IOObjectRelease(dev);
            continue;
        }
        memset(&g_slots[slot], 0, sizeof(g_slots[slot]));
        g_slots[slot].active = 1;
        g_slots[slot].entry = entry;
        g_slots[slot].vid = (uint32_t)vid;
        g_slots[slot].pid = (uint32_t)pid;
        strlcpy(g_slots[slot].name, "Xbox Controller", sizeof(g_slots[slot].name));
        CFStringRef pn = (CFStringRef)IORegistryEntryCreateCFProperty(dev, CFSTR(kUSBProductString), kCFAllocatorDefault, 0);
        if (pn) {
            CFStringGetCString(pn, g_slots[slot].name, sizeof(g_slots[slot].name), kCFStringEncodingUTF8);
            CFRelease(pn);
        }
        pthread_mutex_unlock(&g_relay_mu);

        xbox_relay_worker_ctx *ctx = (xbox_relay_worker_ctx *)malloc(sizeof(*ctx));
        if (!ctx) {
            pthread_mutex_lock(&g_relay_mu);
            memset(&g_slots[slot], 0, sizeof(g_slots[slot]));
            pthread_mutex_unlock(&g_relay_mu);
            IOObjectRelease(dev);
            continue;
        }
        ctx->dev = dev;
        ctx->slot = slot;
        ctx->vid = (uint32_t)vid;
        ctx->pid = (uint32_t)pid;
        pthread_t th;
        if (pthread_create(&th, NULL, xbox_relay_usb_worker, ctx) != 0) {
            free(ctx);
            pthread_mutex_lock(&g_relay_mu);
            memset(&g_slots[slot], 0, sizeof(g_slots[slot]));
            pthread_mutex_unlock(&g_relay_mu);
            IOObjectRelease(dev);
        } else {
            pthread_detach(th);
        }
    }
}

static void *xbox_relay_usb_runloop_thread(void *arg) {
    (void)arg;
    CFRunLoopRef rl = CFRunLoopGetCurrent();
    pthread_mutex_lock(&g_relay_mu);
    if (!g_running) {
        pthread_mutex_unlock(&g_relay_mu);
        return NULL;
    }
    g_usb_rl = (CFRunLoopRef)CFRetain(rl);
    pthread_mutex_unlock(&g_relay_mu);

    IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
    io_iterator_t iter = 0;
    if (port) {
        CFRunLoopSourceRef src = IONotificationPortGetRunLoopSource(port);
        CFRunLoopAddSource(rl, src, kCFRunLoopDefaultMode);
        CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
        if (IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, match, xbox_relay_device_matched, NULL, &iter) == KERN_SUCCESS) {
            xbox_relay_device_matched(NULL, iter);
            CFRunLoopRun();
        }
        if (iter) IOObjectRelease(iter);
        IONotificationPortDestroy(port);
    }

    pthread_mutex_lock(&g_relay_mu);
    if (g_usb_rl) {
        CFRelease(g_usb_rl);
        g_usb_rl = NULL;
    }
    pthread_mutex_unlock(&g_relay_mu);
    return NULL;
}

static void *xbox_relay_accept_thread(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&g_relay_mu);
        int run = g_running;
        int lfd = g_listen_fd;
        pthread_mutex_unlock(&g_relay_mu);
        if (!run || lfd < 0) break;

        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            break;
        }

        int one = 1;
        setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        struct timeval tv = {.tv_sec = 0, .tv_usec = 50000}; /* 50 ms 发送超时：避免卡死客户端拖慢读线程 */
        setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        s2a_xbox_gip_relay_packet snaps[S2A_XBOX_GIP_RELAY_MAX];
        int nsnaps = 0;
        pthread_mutex_lock(&g_relay_mu);
        for (int i = 0; i < S2A_XBOX_GIP_RELAY_MAX; i++) {
            if (g_slots[i].active && g_slots[i].connected) {
                snaps[nsnaps++] = make_slot_packet(i, &g_slots[i], 1);
            }
        }
        pthread_mutex_unlock(&g_relay_mu);

        pthread_mutex_lock(&g_send_mu);
        int ok = 1;
        for (int i = 0; i < nsnaps; i++) {
            if (s2a_xbox_gip_write_all(cfd, &snaps[i], sizeof(snaps[i])) != 0) {
                ok = 0;
                break;
            }
        }
        if (!ok) {
            shutdown(cfd, SHUT_RDWR);
            close(cfd);
        } else {
            int placed = 0;
            for (int i = 0; i < S2A_XBOX_RELAY_MAX_CLIENTS; i++) {
                if (g_clients[i] < 0) { g_clients[i] = cfd; placed = 1; break; }
            }
            if (!placed) {
                shutdown(g_clients[0], SHUT_RDWR);
                close(g_clients[0]);
                g_clients[0] = cfd;
            }
        }
        pthread_mutex_unlock(&g_send_mu);
    }
    return NULL;
}

int s2a_xbox_gip_relay_start_ex(const char *socket_path, int enable_usb, s2a_xbox_gip_status_cb cb, void *ctx) {
    if (!socket_path || !socket_path[0]) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(socket_path) >= sizeof(addr.sun_path)) return -1;
    strlcpy(addr.sun_path, socket_path, sizeof(addr.sun_path));

    pthread_mutex_lock(&g_relay_mu);
    if (g_running) {   // 已在跑：同一路径算成功；别的路径不是这次要的服务，如实回失败（原先一律回 0，调用方以为在新路径上听着）
        int same = strcmp(g_socket_path, socket_path) == 0;
        pthread_mutex_unlock(&g_relay_mu);
        return same ? 0 : -1;
    }
    pthread_mutex_unlock(&g_relay_mu);

    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0) return -1;
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    unlink(socket_path);
    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(lfd);
        return -1;
    }
    chmod(socket_path, 0600);
    if (listen(lfd, 4) != 0) {
        close(lfd);
        unlink(socket_path);
        return -1;
    }

    pthread_mutex_lock(&g_send_mu);
    for (int i = 0; i < S2A_XBOX_RELAY_MAX_CLIENTS; i++) g_clients[i] = -1;
    pthread_mutex_unlock(&g_send_mu);

    pthread_mutex_lock(&g_relay_mu);
    memset(g_slots, 0, sizeof(g_slots));
    g_listen_fd = lfd;
    strlcpy(g_socket_path, socket_path, sizeof(g_socket_path));
    g_status_cb = cb;
    g_status_ctx = ctx;
    g_usb_enabled = enable_usb ? 1 : 0;
    g_running = 1;
    g_accept_th_valid = 0;
    g_usb_th_valid = 0;
    pthread_mutex_unlock(&g_relay_mu);

    if (pthread_create(&g_accept_th, NULL, xbox_relay_accept_thread, NULL) == 0) {
        g_accept_th_valid = 1;
    } else {
        s2a_xbox_gip_relay_stop();
        return -1;
    }
    if (enable_usb) {
        if (pthread_create(&g_usb_th, NULL, xbox_relay_usb_runloop_thread, NULL) == 0) {
            g_usb_th_valid = 1;
        }
    }
    fprintf(stderr, "[输入] Xbox GIP 中继服务已启动：%s\n", socket_path);
    return 0;
}

int s2a_xbox_gip_relay_start(const char *socket_path, s2a_xbox_gip_status_cb cb, void *ctx) {
    return s2a_xbox_gip_relay_start_ex(socket_path, 1, cb, ctx);
}

int s2a_xbox_gip_relay_publish_for_test(const void *raw, size_t len) {
    if (!raw || len != sizeof(s2a_xbox_gip_relay_packet)) return 0;
    s2a_xbox_gip_relay_packet pkt;
    memcpy(&pkt, raw, sizeof(pkt));
    if (!s2a_xbox_gip_relay_packet_valid(&pkt)) return 0;

    pthread_mutex_lock(&g_relay_mu);
    if (!g_running) {
        pthread_mutex_unlock(&g_relay_mu);
        return 0;
    }
    relay_slot *s = &g_slots[pkt.slot];
    if (pkt.flags & S2A_XBOX_GIP_FLAG_CONNECTED) {
        s->active = 1;
        s->connected = 1;
        s->vid = pkt.vid;
        s->pid = pkt.pid;
        s->buttons = pkt.buttons;
        memcpy(s->ax, pkt.ax, sizeof(s->ax));
        strlcpy(s->name, pkt.name[0] ? pkt.name : "Xbox Controller", sizeof(s->name));
    } else {
        memset(s, 0, sizeof(*s));
    }
    pthread_mutex_unlock(&g_relay_mu);
    broadcast_packet(&pkt);
    return 1;
}

void s2a_xbox_gip_relay_stop(void) {
    CFRunLoopRef rl = NULL;
    int lfd = -1;
    char path[104] = "";

    pthread_mutex_lock(&g_relay_mu);
    if (!g_running && g_listen_fd < 0) {
        pthread_mutex_unlock(&g_relay_mu);
        return;
    }
    g_running = 0;
    lfd = g_listen_fd;
    g_listen_fd = -1;
    strlcpy(path, g_socket_path, sizeof(path));
    g_socket_path[0] = '\0';
    rl = g_usb_rl ? (CFRunLoopRef)CFRetain(g_usb_rl) : NULL;
    for (int i = 0; i < S2A_XBOX_GIP_RELAY_MAX; i++) {
        if (g_slots[i].intf && g_slots[i].in_pipe > 0) {
            (*g_slots[i].intf)->AbortPipe(g_slots[i].intf, (UInt8)g_slots[i].in_pipe);
        }
    }
    pthread_mutex_unlock(&g_relay_mu);

    if (lfd >= 0) {
        shutdown(lfd, SHUT_RDWR);
        close(lfd);
    }
    if (path[0]) unlink(path);
    if (rl) {
        CFRunLoopStop(rl);
        CFRelease(rl);
    }

    pthread_mutex_lock(&g_send_mu);
    for (int i = 0; i < S2A_XBOX_RELAY_MAX_CLIENTS; i++) {
        if (g_clients[i] >= 0) {
            shutdown(g_clients[i], SHUT_RDWR);
            close(g_clients[i]);
            g_clients[i] = -1;
        }
    }
    pthread_mutex_unlock(&g_send_mu);

    if (g_accept_th_valid) {
        pthread_join(g_accept_th, NULL);
        g_accept_th_valid = 0;
    }
    if (g_usb_th_valid) {
        pthread_join(g_usb_th, NULL);
        g_usb_th_valid = 0;
    }
}
