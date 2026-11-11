// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using S2Arm.Launcher.Protocol;

// 手动指定 Metal 文件夹：选安装根 / bin / 早期版本 ios 都认得，选错文件夹回 null；记下后本进程环境变量立即生效、重启后读回。
public static class MetalFolderCases
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "s2a-metal 中文 " + Guid.NewGuid().ToString("N"));
        try
        {
            string Put(params string[] parts)
            {
                var dir = Path.Combine([root, .. parts]);
                Directory.CreateDirectory(dir);
                File.WriteAllText(Path.Combine(dir, "metal.exe"), "fixture");
                return dir;
            }
            var bin = Put("装在 D 盘", "bin");
            check(MetalFolder.Resolve(Path.Combine(root, "装在 D 盘")) == bin, "metal folder: install root resolves to bin");
            check(MetalFolder.Resolve(bin) == bin, "metal folder: bin itself");
            var ios = Put("早期", "ios", "bin");
            check(MetalFolder.Resolve(Path.Combine(root, "早期")) == ios, "metal folder: old ios\\bin layout");
            Directory.CreateDirectory(Path.Combine(root, "选错了"));
            check(MetalFolder.Resolve(Path.Combine(root, "选错了")) is null, "metal folder: wrong folder is null");
            check(MetalFolder.Candidates("X").Length == 3, "metal folder: three places listed for the player");

            var priv = Path.Combine(root, "private");
            Environment.SetEnvironmentVariable(MetalFolder.Variable, null);
            MetalFolder.Save(priv, bin);
            check(Environment.GetEnvironmentVariable(MetalFolder.Variable) == bin, "metal folder: save sets process env for children");
            Environment.SetEnvironmentVariable(MetalFolder.Variable, null);
            MetalFolder.Load(priv);
            check(Environment.GetEnvironmentVariable(MetalFolder.Variable) == bin, "metal folder: load restores after restart");
            Environment.SetEnvironmentVariable(MetalFolder.Variable, null);
            MetalFolder.Load(Path.Combine(root, "没有设置"));
            check(Environment.GetEnvironmentVariable(MetalFolder.Variable) is null, "metal folder: no preference leaves env unset");
        }
        finally { Directory.Delete(root, true); }
    }
}
