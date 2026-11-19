#pragma once
#import <Foundation/Foundation.h>
// 诊断包收成员（ios/diagcollect.m）：Documents 根 D 下该收的文件收进工作目录 W，files / sessions 追加 manifest 用的条目，crash / hang / exits 记 MetricKit 份数。
//   redact：文本脱敏（返回 nil = 失败）；summary：一份会话日志的摘要（nil = 不记）。返回 NO = 有文本文件脱敏或写出失败
BOOL s2a_diag_collect(NSString *D, NSString *W, NSUInteger cap, BOOL slim, NSString *(^redact)(NSString *),
                      NSDictionary *(^summary)(NSString *path, NSString *name, BOOL current),
                      NSMutableArray *files, NSMutableArray *sessions, int *crash, int *hang, int *exits);
