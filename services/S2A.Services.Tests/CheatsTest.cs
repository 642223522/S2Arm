using System;
using System.Collections.Generic;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Tamper;

namespace S2A.Services.Tests
{
    // 金手指（Cheats.cs）：期望按 Atmosphere 金手指格式手写，不跑被测实现推期望
    public static class CheatsTest
    {
        private sealed class Fake : ITamperedProcess
        {
            public readonly List<(ulong va, ulong v)> Writes = new();
            public ProcessState State => ProcessState.Started;
            public bool TamperedCodeMemory { get; set; }
            public T ReadMemory<T>(ulong va) where T : unmanaged => default;
            public void WriteMemory<T>(ulong va, T value) where T : unmanaged => Writes.Add((va, Convert.ToUInt64(value)));
            public void PauseProcess() { }
            public void ResumeProcess() { }
        }

        public static void Run(Action<string, object, object> check)
        {
            const string text = "{主代码}\n580F0000 01234567\n\n[无限金钱]\n04000000 00000010 0000002A\n[ 跳高 ]\n04000000 00000020 00000001\n04000000 00000024 00000002\n";
            var e = Cheats.Parse("0123456789ABCDEF.txt", text);
            check("金手指 解析：三段（主代码 + 两条）", 3, e.Count);
            check("金手指 解析：主代码段名 / 标记", ("主代码", true), (e[0].Name, e[0].Master));
            check("金手指 解析：条目名去空白、键 = 文件名/条目名", "0123456789ABCDEF.txt/跳高", e[2].Key);
            check("金手指 解析：第三段两行指令", 2, e[2].Lines.Count);
            check("金手指 解析：方括号不闭合整份作废", true, Cheats.Parse("a.txt", "[坏\n04000000 00000010 00000001\n") == null);
            check("金手指 解析：段外开头的指令归「未命名」", "未命名", Cheats.Parse("a.txt", "04000000 00000010 00000001\n")[0].Name);

            check("金手指 构建号：16 位十六进制名与主程序前 16 位一致（大小写不敏感）", true, Cheats.BuildMatches("0123456789abcdef", "0123456789ABCDEF00112233"));
            check("金手指 构建号：16 位十六进制名不一致 → 不符", false, Cheats.BuildMatches("0123456789ABCDEE", "0123456789ABCDEF00112233"));
            check("金手指 构建号：拿不到主程序构建号 → 不符", false, Cheats.BuildMatches("0123456789ABCDEF", ""));
            check("金手指 构建号：玩家自起的文件名不判", true, Cheats.BuildMatches("塞满金币", "0123456789ABCDEF"));

            // 指令 0（存常量）：04000000 00000010 0000002A = 4 字节、main 区、偏移 0x10、值 0x2A → 写到 主程序基址 + 0x10
            var fake = new Fake();
            const ulong exe = 0x8000000000UL;
            ITamperProgram p = new AtmosphereCompiler(exe, 0x9000000000UL, 0, 0, fake).Compile("t", e[1].Lines);
            check("金手指 编译：存常量指令编译成功", true, p != null);
            p.IsEnabled = true;
            p.Execute((ControllerKeys)0);
            check("金手指 执行：写到主程序基址 + 0x10、值 42", "8000000010=42", fake.Writes.Count == 1 ? $"{fake.Writes[0].va:X}={fake.Writes[0].v}" : $"写了 {fake.Writes.Count} 次");
            check("金手指 编译：坏指令回 null（界面显示「指令有误」）", true,
                new AtmosphereCompiler(exe, 0, 0, 0, fake).Compile("bad", new[] { "ZZZZ" }) == null);
        }
    }
}
