using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using Ryujinx.HLE.FileSystem;
using Path = System.IO.Path;

namespace S2A.Services;

// 回到上一份存档：每次存档提交换下来的旧版本留在 <存档>/.s2a_prev（S2ASaveTransaction.PreviousDir，APFS 克隆、只留一份）。
//   previous         只读：这款哪几棵存档有上一份（起局前提示 / 齿轮页入口按它决定显示不显示）
//   restorePrevious  起局前（游戏没在跑，Execute 已拒）：每棵有上一份的存档调 RestorePrevious 与已提交版本原子交换；再调一次就换回来。
//                    一棵失败就把这次已换过的几棵换回去，整次报失败——不留「一半新一半旧」
public static partial class SaveTransfer
{
    private static List<string> PreviousSaveDirs(Context c)
    {
        string root = Path.Combine(c.Root, "bis", "user", "save");
        var dirs = new List<string>();
        if (!Directory.Exists(root)) return dirs;
        CheckLinks(root);
        foreach (string dir in Directory.EnumerateDirectories(root).OrderBy(d => d, StringComparer.Ordinal))
        {
            if (!Hex(Path.GetFileName(dir), 16)) continue;
            if (Directory.Exists(Path.Combine(dir, "0")) && Directory.Exists(Path.Combine(dir, S2ASaveTransaction.PreviousDir)))
                dirs.Add(dir);
        }
        return dirs;
    }

    private static JsonObject PreviousSaves(Context c)
    {
        var dirs = PreviousSaveDirs(c);
        return new() { ["hasPrevious"] = dirs.Count != 0, ["saveIds"] = new JsonArray(dirs.Select(d => (JsonNode)Path.GetFileName(d)).ToArray()) };
    }

    private static JsonObject RestorePreviousSaves(Context c)
    {
        var dirs = PreviousSaveDirs(c);
        Require(dirs.Count != 0, T("这款游戏没有上一份存档。", "This game has no previous save."), "save_no_previous");
        var done = new List<string>();
        foreach (string dir in dirs)
        {
            string why = S2ASaveTransaction.RestorePrevious(dir);
            if (why == null) { done.Add(dir); continue; }
            System.Console.Error.WriteLine("回到上一份存档失败：" + Path.GetFileName(dir) + "：" + why);
            var stuck = new List<string>();
            foreach (string back in done)
                if (S2ASaveTransaction.RestorePrevious(back) is string undo) { stuck.Add(Path.GetFileName(back)); System.Console.Error.WriteLine("换回失败：" + Path.GetFileName(back) + "：" + undo); }
            throw new Failure("save_previous_failed", stuck.Count == 0
                ? T("没能回到上一份存档，存档保持原样。", "Couldn’t go back to the previous save. Your save is unchanged.")
                : T("没能回到上一份存档，而且有存档没能换回原样，请导出诊断包。", "Couldn’t go back to the previous save, and some saves couldn’t be switched back. Please export a diagnostic report."));
        }
        return new() { ["restored"] = done.Count, ["saveIds"] = new JsonArray(done.Select(d => (JsonNode)Path.GetFileName(d)).ToArray()) };
    }
}
