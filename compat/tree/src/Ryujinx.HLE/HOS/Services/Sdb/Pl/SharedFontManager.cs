using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.FsSystem;
using LibHac.Ncm;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using Microsoft.IO;
using Ryujinx.Common.Memory;
using Ryujinx.HLE.Exceptions;
using Ryujinx.HLE.FileSystem;
using Ryujinx.HLE.HOS.Kernel.Memory;
using Ryujinx.HLE.HOS.Services.Sdb.Pl.Types;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace Ryujinx.HLE.HOS.Services.Sdb.Pl
{
    class SharedFontManager
    {
        private const uint FontKey = 0x06186249;
        private const uint BFTTFMagic = 0x18029a7f;

        private readonly Switch _device;
        private readonly SharedMemoryStorage _storage;

        private struct FontInfo
        {
            public int Offset;
            public int Size;

            public FontInfo(int offset, int size)
            {
                Offset = offset;
                Size = size;
            }
        }

        private Dictionary<SharedFontType, FontInfo> _fontData;
        private uint _fontEnd; // S2Arm：字体区已用长度（最后一个字体正文的末尾）

        public SharedFontManager(Switch device, SharedMemoryStorage storage)
        {
            _device = device;
            _storage = storage;
        }

        public void Initialize()
        {
            _fontData?.Clear();
            _fontData = null;

        }

        public void EnsureInitialized(ContentManager contentManager)
        {
            if (_fontData == null)
            {
                _storage.ZeroFill();

                uint fontOffset = 0;

                FontInfo CreateFont(string name)
                {
                    if (contentManager.TryGetFontTitle(name, out ulong fontTitle) && contentManager.TryGetFontFilename(name, out string fontFilename))
                    {
                        // S2Arm: no firmware NCAs; the same .bfttf files can come from a directory (S2AHooks.SharedFontDir)
                        if (S2AHooks.SharedFontDir != null)
                        {
                            string file = System.IO.Path.Combine(S2AHooks.SharedFontDir, fontFilename);

                            if (!File.Exists(file))
                            {
                                S2AHooks.Red?.Invoke($"共享字体：{name}（{fontTitle:x16}）缺 {fontFilename}");

                                throw new InvalidSystemResourceException($"{name} ({fontTitle:x16}) {fontFilename} not found in {S2AHooks.SharedFontDir}");
                            }

                            byte[] fileData;

                            using (FileStream fs = File.OpenRead(file))
                            {
                                fileData = DecryptFont(fs);
                            }

                            FontInfo fileInfo = new((int)fontOffset, fileData.Length);

                            PutFont(ref fontOffset, fileData);

                            return fileInfo;
                        }

                        string contentPath = contentManager.GetInstalledContentPath(fontTitle, StorageId.BuiltInSystem, NcaContentType.Data);
                        string fontPath = VirtualFileSystem.SwitchPathToSystemPath(contentPath);

                        if (!string.IsNullOrWhiteSpace(fontPath))
                        {
                            byte[] data;

                            using (IStorage ncaFileStream = new LocalStorage(fontPath, FileAccess.Read, FileMode.Open))
                            {
                                Nca nca = new(_device.System.KeySet, ncaFileStream);
                                IFileSystem romfs = nca.OpenFileSystem(NcaSectionType.Data, _device.System.FsIntegrityCheckLevel);

                                using UniqueRef<IFile> fontFile = new();

                                romfs.OpenFile(ref fontFile.Ref, ("/" + fontFilename).ToU8Span(), OpenMode.Read).ThrowIfFailure();

                                data = DecryptFont(fontFile.Get.AsStream());
                            }

                            FontInfo info = new((int)fontOffset, data.Length);

                            PutFont(ref fontOffset, data);

                            return info;
                        }
                        else
                        {
                            if (!contentManager.TryGetSystemTitlesName(fontTitle, out string titleName))
                            {
                                titleName = "Unknown";
                            }

                            S2AHooks.Red?.Invoke($"共享字体：缺系统数据 {titleName}（{fontTitle:x16}）");

                            throw new InvalidSystemResourceException($"{titleName} ({fontTitle:x8}) system title not found! This font will not work, provide the system archive to fix this error.");
                        }
                    }
                    else
                    {
                        throw new ArgumentException($"Unknown font \"{name}\"!");
                    }
                }

                _fontData = new Dictionary<SharedFontType, FontInfo>
                {
                    { SharedFontType.JapanUsEurope,       CreateFont("FontStandard")                  },
                    { SharedFontType.SimplifiedChinese,   CreateFont("FontChineseSimplified")         },
                    { SharedFontType.SimplifiedChineseEx, CreateFont("FontExtendedChineseSimplified") },
                    { SharedFontType.TraditionalChinese,  CreateFont("FontChineseTraditional")        },
                    { SharedFontType.Korean,              CreateFont("FontKorean")                    },
                    { SharedFontType.NintendoEx,          CreateFont("FontNintendoExtended")          },
                };

                if (fontOffset > Horizon.FontSize)
                {
                    throw new InvalidSystemResourceException("The sum of all fonts size exceed the shared memory size. " +
                                                             $"Please make sure that the fonts don't exceed {Horizon.FontSize} bytes in total. (actual size: {fontOffset} bytes).");
                }

                _fontEnd = fontOffset;
            }
        }

        private void WriteMagicAndSize(ulong offset, int size)
        {
            const int Key = 0x49621806;

            int encryptedSize = BinaryPrimitives.ReverseEndianness(size ^ Key);

            _storage.GetRef<int>(offset + 0) = (int)BFTTFMagic;
            _storage.GetRef<int>(offset + 4) = encryptedSize;
        }

        public int GetFontSize(SharedFontType fontType)
        {
            EnsureInitialized(_device.System.ContentManager);

            return _fontData[fontType].Size;
        }

        public int GetSharedMemoryAddressOffset(SharedFontType fontType)
        {
            EnsureInitialized(_device.System.ContentManager);

            return _fontData[fontType].Offset + 8;
        }

        // S2Arm：pl:u 2100 RequestLoadNxFont 把字体区 [0, 已用长度) 原样写进游戏递来的传输内存：每个字体 8 字节头 + 解密后的正文，
        //   正文偏移 / 长度与 GetSharedMemoryAddressOffset / GetFontSize 同口径
        public ReadOnlySpan<byte> GetFontRegion()
        {
            EnsureInitialized(_device.System.ContentManager);

            return MemoryMarshal.CreateReadOnlySpan(ref _storage.GetRef<byte>(0), (int)_fontEnd);
        }

        // S2Arm（11-17 D-FCMF：Switch 2 游戏取内置字体 2010 等了 190 秒、黑屏）：一个字体 = 8 字节头 + 解密后的正文，整块写进字体共享内存。
        //   上游逐字节 GetRef 写 1700 多万次；写之前先核放得下（上游写完全部字体才核总长，超了已经写出字体区）
        private void PutFont(ref uint fontOffset, byte[] data)
        {
            if ((ulong)fontOffset + 8 + (ulong)data.Length > (ulong)Horizon.FontSize)
            {
                throw new InvalidSystemResourceException("The sum of all fonts size exceed the shared memory size. " +
                                                         $"Please make sure that the fonts don't exceed {Horizon.FontSize} bytes in total. (actual size: {(ulong)fontOffset + 8 + (ulong)data.Length} bytes so far).");
            }

            WriteMagicAndSize(fontOffset, data.Length);

            fontOffset += 8;

            data.AsSpan().CopyTo(MemoryMarshal.CreateSpan(ref _storage.GetRef<byte>(fontOffset), data.Length));

            fontOffset += (uint)data.Length;
        }

        // S2Arm（同上）：上游循环条件每圈取一次 bfttfStream.Length——文件流上每次都是一次 fstat（约 17.5 MB 字体 = 440 万次）；游戏库在外接盘 / 网络盘上时
        //   一次 fstat 慢一个数量级，字体初始化拖到几分钟，游戏一直等字体、黑屏（玩家现场栈正停在 fstat）。改为整份读进来一次、在内存里逐字异或（小端，同上游 BinaryReader / BinaryWriter）
        private static byte[] DecryptFont(Stream bfttfStream)
        {
            static uint KXor(uint data) => data ^ FontKey;

            long length = bfttfStream.Length;

            if (length < 8)
            {
                throw new InvalidDataException("Error: Input file is not in BFTTF format!");
            }

            byte[] raw = new byte[length];

            bfttfStream.ReadExactly(raw);

            if (KXor(BinaryPrimitives.ReadUInt32LittleEndian(raw)) != BFTTFMagic)
            {
                throw new InvalidDataException("Error: Input file is not in BFTTF format!");
            }

            int words = (int)((length - 8) / 4);
            byte[] ttf = new byte[words * 4];
            ReadOnlySpan<uint> src = MemoryMarshal.Cast<byte, uint>(raw.AsSpan(8, words * 4));
            Span<uint> dst = MemoryMarshal.Cast<byte, uint>(ttf.AsSpan());

            for (int i = 0; i < words; i++)
            {
                dst[i] = BitConverter.IsLittleEndian ? KXor(src[i]) : BinaryPrimitives.ReverseEndianness(KXor(BinaryPrimitives.ReverseEndianness(src[i])));
            }

            return ttf;
        }
    }
}
