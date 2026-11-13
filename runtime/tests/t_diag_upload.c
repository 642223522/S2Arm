// 诊断一键上传：纯判断 ios/diag_upload.h 的决策表 + ios/diag.m 接线断言（UIKit / NSURLSession 在 Mac 宿主上编不了，行为靠决策表、接线靠文本断言）。
#include "../../ios/diag_upload.h"
#include <stdio.h>
#include <stdlib.h>

static int failures, checks;
static void check(int ok, const char *what) { checks++; if (!ok) { failures++; fprintf(stderr, "✗ %s\n", what); } }
static int count_in(const char *text, const char *needle) {
    int n = 0; size_t len = strlen(needle);
    for (const char *p = text; (p = strstr(p, needle)) != NULL; p += len) n++;
    return n;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "用法：t_diag_upload <diag.m 路径>\n"); return 2; }
    // 短码格式：D- + 4 位，字符集去掉 0 1 I L O U
    check(s2a_diag_code_ok("D-7K3Q"), "D-7K3Q 合格");
    check(s2a_diag_code_ok("D-2ZZ9"), "D-2ZZ9 合格（字符集两端）");
    check(!s2a_diag_code_ok("D-7K3"), "3 位不合格");
    check(!s2a_diag_code_ok("D-7K3QX"), "5 位不合格");
    check(!s2a_diag_code_ok("D-7K0Q"), "含 0 不合格");
    check(!s2a_diag_code_ok("D-7KIQ"), "含 I 不合格");
    check(!s2a_diag_code_ok("D-7kq3"), "小写不合格");
    check(!s2a_diag_code_ok("X-7K3Q"), "前缀不是 D- 不合格");
    check(!s2a_diag_code_ok(NULL), "空不合格");
    // 判定
    check(s2a_diag_up_verdict(200, false, 0, "D-7K3Q") == S2A_UP_OK, "200 + 合格短码：成功");
    check(s2a_diag_up_verdict(200, false, 0, "oops") == S2A_UP_FAIL, "200 + 短码不合格式：失败（不给对不上的码）");
    check(s2a_diag_up_verdict(0, true, 0, NULL) == S2A_UP_RETRY, "第一次网络不通：重试");
    check(s2a_diag_up_verdict(0, true, 1, NULL) == S2A_UP_FAIL, "第二次网络不通：失败退回导出");
    check(s2a_diag_up_verdict(503, false, 0, NULL) == S2A_UP_RETRY, "第一次 5xx：重试");
    check(s2a_diag_up_verdict(500, false, 1, NULL) == S2A_UP_FAIL, "第二次 5xx：失败");
    check(s2a_diag_up_verdict(429, false, 0, NULL) == S2A_UP_FAIL, "429 限频：不马上重试，提示稍后再试");
    check(s2a_diag_up_verdict(400, false, 0, NULL) == S2A_UP_FAIL, "400 不合规：不重试");
    check(s2a_diag_up_verdict(413, false, 0, NULL) == S2A_UP_FAIL, "413 太大：不重试");
    // 接线：diag.m 按这套判断走、只用 diag.s2arm.com
    FILE *f = fopen(argv[1], "rb"); if (!f) { fprintf(stderr, "读不到 %s\n", argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *src = malloc((size_t)n + 1); if (!src || fread(src, 1, (size_t)n, f) != (size_t)n) return 2; src[n] = 0; fclose(f);
    check(count_in(src, "s2a_diag_up_verdict(") == 1, "diag.m 的上传结果走 s2a_diag_up_verdict（一处）");
    check(count_in(src, "https://diag.s2arm.com/v1/upload") == 1, "上传地址是 https://diag.s2arm.com/v1/upload");
    check(count_in(src, "@\"https://") == 1, "diag.m 只有这一个上传地址字面量（不用 *.workers.dev：国内不通）");
    check(count_in(src, "UIPasteboard.generalPasteboard.string = code") == 1, "「复制」只复制短码");
    free(src);
    if (failures) { fprintf(stderr, "t_diag_upload：%d/%d 项不符\n", failures, checks); return 1; }
    printf("✓ t_diag_upload：%d 项（短码格式；网络 / 5xx 重试一次、429 / 400 / 413 不重试；地址与只复制短码的接线）\n", checks);
    return 0;
}
