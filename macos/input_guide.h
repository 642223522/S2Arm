#import <AppKit/AppKit.h>

// Mac-only UI. The caller passes the same immutable dictionary used by HID.
NSArray<NSArray<NSString *> *> *s2a_mac_guide_rows(NSDictionary *mapping);
NSString *s2a_mac_guide_preference_key(NSString *gameID);
NSDictionary *s2a_mac_guide_identity(void);
BOOL s2a_mac_guide_show_again(NSString *gameID, NSString *path);
NSImage *s2a_mac_guide_status_image(void);

// Small, mouse-transparent in-game face-button reference. The game window owns
// the view; mapping is the exact packed permutation used by its input adapter.
@interface S2AControllerFaceOverlay : NSVisualEffectView
@property(nonatomic, copy) NSString *family;
@property(nonatomic) int mapping;
- (NSArray<NSString *> *)rows;
@end

@interface S2AMacInputGuide : NSObject <NSWindowDelegate>
@property(nonatomic, readonly) NSWindow *window;
@property(nonatomic, readonly) NSString *selectedTarget;
- (instancetype)initWithName:(NSString *)name gameID:(NSString *)gameID
                     mapping:(NSDictionary *)mapping gameWindow:(NSWindow *)gameWindow;
- (void)show;
- (void)selectTarget:(NSString *)target;
- (void)returnToGame;
@end
