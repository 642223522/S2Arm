#import <UIKit/UIKit.h>
// 资源替换类 mod 页（11-15 维护者「咱们也可以支持 mod 导入」）：本款文档根（s2a_docs.h）/mods/<名字>/romfs，服务层 RomFsMods.cs 起局叠上。
//   列出、左滑删除、导入文件夹（找出里面的 romfs/，同电脑端 pack/jobs/mods.py 的认法）；改了下次进游戏生效
UIViewController *s2a_mods_controller(void);
NSInteger s2a_mods_count(void);
