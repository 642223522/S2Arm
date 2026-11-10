// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2Arm.Launcher.Protocol;

// 作业层文字的英文显示（#361：Windows 英文界面下作业消息仍是中文）：期望按手写对照表逐条算，规则同 Mac BackendText.swift
public static class BackendTextCases
{
    public static void Run(Action<bool, string> check)
    {
        const string table = """
[{"source":"操作完成","en":"Done"},
 {"source":"推 {0} 个文件 {1} MB","en":"Pushed {0} files, {1} MB"},
 {"source":"{0}失败","en":"{0} failed"},
 {"source":"解包","en":"Unpack"},
 {"source":"手机解锁后再点一次","en":"Unlock the phone and try again"}]
""";
        const string spec = """
{"states":[{"id":"running","title":{"zh-Hans":"进行中","en":"Running"}},{"id":"idle","title":{"zh-Hans":"空闲","en":"Idle"}}],
 "event_map":{"terminal_results":{"job.succeeded":{"title":{"zh-Hans":"已完成","en":"Completed"}}}},
 "stage_labels":{"pack":{"zh-Hans":"出包","en":"Package"}}}
""";
        var b = new BackendText(table, spec);
        check(b.English("操作完成") == "Done", "backend text: whole sentence");
        check(b.English("推 735 个文件 240 MB") == "Pushed 735 files, 240 MB", "backend text: pattern keeps the values");
        check(b.English("解包失败") == "Unpack failed", "backend text: value inside a pattern is translated too");
        check(b.English("操作完成；手机解锁后再点一次") == "Done; Unlock the phone and try again", "backend text: joined sentences split on ；");
        check(b.English("进行中") == "Running" && b.English("已完成") == "Completed" && b.English("出包") == "Package", "backend text: shared spec states / results / stages");
        check(b.English("空闲") == "空闲", "backend text: only running / failed states join the table (same as Mac)");
        check(b.English("没见过的一句") == "没见过的一句", "backend text: unknown Chinese shown as is");
        check(b.English("Already English") == "Already English" && b.English("") == "", "backend text: text without Chinese untouched");
    }
}
