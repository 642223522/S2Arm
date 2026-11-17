// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import <AppKit/AppKit.h>
#include <stdint.h>

// SwiftUI accessibility elements implement these public selectors without always
// declaring conformance to the complete NSAccessibility protocol.
@interface S2ALauncherAX : NSObject
+ (NSArray *)children:(id)element;
+ (NSString *)role:(id)element;
+ (NSString *)identifier:(id)element;
+ (NSString *)label:(id)element;
+ (NSRect)frame:(id)element;
+ (BOOL)enabled:(id)element;
+ (id)value:(id)element;
+ (BOOL)secure:(id)element;
+ (void)setValue:(id)value element:(id)element;
+ (void)focus:(id)element;
+ (BOOL)press:(id)element;
+ (BOOL)adjust:(id)element step:(NSInteger)step;
+ (BOOL)pick:(id)element;
+ (BOOL)cancel:(id)element;
@end

typedef struct s2a_launcher_pad_client s2a_launcher_pad_client;
typedef struct {
    uint64_t buttons, epoch;
    float x, y, right_y;
    uint8_t ready;
} s2a_launcher_pad_sample;
s2a_launcher_pad_client *s2a_launcher_pad_open(const char *path);
// Nonblocking. 1 = sample, 0 = no new packet, -1 = connection ended/invalid.
int s2a_launcher_pad_poll(s2a_launcher_pad_client *client, s2a_launcher_pad_sample *sample);
void s2a_launcher_pad_close(s2a_launcher_pad_client *client);
int s2a_launcher_pad_decode(const void *bytes, size_t length, s2a_launcher_pad_sample *sample);
int s2a_launcher_face_valid(int map);
int s2a_launcher_face_source(int map, int target);
uint64_t s2a_launcher_face_apply(uint64_t buttons, int map);
