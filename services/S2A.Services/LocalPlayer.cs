using Ryujinx.HLE;
using System;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using AccUserId = Ryujinx.HLE.HOS.Services.Account.Acc.UserId;
using AccountManager = Ryujinx.HLE.HOS.Services.Account.Acc.AccountManager;

namespace S2A.Services
{
    // 本地玩家（#623，维护者 11-11）：同一台设备几个人轮流玩，游戏库里选「谁在玩」，同一款游戏的存档跟着玩家走（同 Switch 选用户）。
    //   存档本来就按用户号隔离（账号存档 = 程序号 + 用户号，Saves / SaveFolder / 选用户小程序都按当前用户），这里只决定这一局用哪个用户号。平台在起局环境里给：
    //   S2A_PLAYER_USER = first           第一个玩家（升级前那份进度的主人）：存档位置 SaveData 里记了用户号就用它（旧规则，SaveFolder.SelectUser），
    //                                     没记 = Ryujinx 缺省用户 00000000000000010000000000000000——不沿用数据根里「上次打开的用户」，那可能是上一局别的玩家
    //                   = <32 位十六进制>  另一个玩家：没有这个用户就建（Ryujinx 写进数据根 system/Profiles.json，下次起局还在）、切成当前用户；
    //                                     不认存档位置里记的用户号（玩家选的是谁就是谁，别人的存档拷进这个玩家的文件夹也读进这个玩家名下）
    //                   不给 / 空          旧行为原样（Mac 启动器、开发起局、单款包没建过玩家）
    //   S2A_PLAYER_NAME = 名字（可空）：写进当前用户的资料（游戏里显示的昵称），截到 32 字节 UTF-8 以内
    //   存档位置「上次读写摘要」与「没读进来的原因」两个文件按玩家分（SaveFolder.StatePath / ProblemPath，第一个玩家仍是原文件名）；
    //   各玩家的 SaveData 文件夹路径由平台给 S2A_SAVE_FOLDER（共享层不判平台）
    public static class LocalPlayer
    {
        public const string First = "first";
        static readonly Regex Hex32 = new("^[0-9a-f]{32}$");

        /// <summary>这一局的玩家：First、32 位小写十六进制用户号，或 null（没给 = 旧行为）。给了认不出的值报红、按旧行为</summary>
        public static string Requested()
        {
            string v = Environment.GetEnvironmentVariable("S2A_PLAYER_USER")?.Trim().ToLowerInvariant();
            if (string.IsNullOrEmpty(v)) return null;
            if (v == First) return First;
            if (Hex32.IsMatch(v) && v.Any(c => c != '0')) return v;
            Red.Report("S2A_PLAYER_USER 不是 first 也不是 32 位十六进制用户号，按没给处理", v);
            return null;
        }

        /// <summary>按玩家分开的文件名后缀：另一个玩家 = "-&lt;用户号&gt;"；第一个玩家与旧行为 = ""（原文件名不变，升级后接着用）</summary>
        public static string FileSuffix() => Requested() is string u && u != First ? "-" + u : "";

        /// <summary>建存档之前调（Application.Register，EnsureSaveData 之前）：按 S2A_PLAYER_USER 定当前用户。
        ///   返回 true = 已按玩家定好（调用方不再套存档位置里的用户号）；false = 没给玩家，调用方走旧规则</summary>
        public static bool Select(Switch device, ulong programId)
        {
            string want = Requested();
            if (want == null) return false;
            var accounts = device.System.AccountManager;
            string name = Name();
            if (want == First)
            {
                // 旧规则先走：存档位置里记的用户号（P1-162，游戏按建档用户号认人）；没记就回缺省用户
                if (!SaveFolder.SelectUser(device, programId)) Open(accounts, AccountManager.DefaultUserId, name);
            }
            else Open(accounts, new AccUserId(want), name);
            var current = accounts.LastOpenedUser;
            if (name != null && current.Name != name) accounts.SetUserName(current.UserId, name);
            Console.Error.WriteLine($"S2A 本地玩家：{(want == First ? "第一个玩家" : "玩家 " + want)}，当前用户 {current.UserId}（{current.Name}）");
            return true;
        }

        // 没有这个用户就建（缺省头像；名字没给用 Player），再切成当前用户。AccountManager.OpenUser 对不存在的用户号什么都不做，所以先建
        static void Open(AccountManager accounts, AccUserId id, string name)
        {
            if (!accounts.GetAllUsers().Any(u => u.UserId == id))
            {
                accounts.AddUser(name ?? "Player", Ryujinx.Common.EmbeddedResources.Read("Ryujinx.HLE/HOS/Services/Account/Acc/DefaultUserImage.jpg"), id);
                Console.Error.WriteLine($"S2A 本地玩家：新建用户 {id}");
            }
            if (accounts.LastOpenedUser.UserId != id) accounts.OpenUser(id);
        }

        // 名字：去掉首尾空白，截到 32 字节 UTF-8 以内（Switch 用户资料的昵称上限），不截半个字；空 = 不改
        internal static string Name()
        {
            string v = Environment.GetEnvironmentVariable("S2A_PLAYER_NAME")?.Trim();
            if (string.IsNullOrEmpty(v)) return null;
            var sb = new StringBuilder();
            int bytes = 0;
            foreach (var rune in v.EnumerateRunes())
            {
                bytes += rune.Utf8SequenceLength;
                if (bytes > 32) break;
                sb.Append(rune.ToString());
            }
            return sb.ToString();
        }
    }
}
