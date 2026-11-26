using LibHac;
using LibHac.Common;
using LibHac.Fs;
using LibHac.Sf;
using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using Ryujinx.Memory;
using System.Threading;

namespace Ryujinx.HLE.HOS.Services.Fs.FileSystemProxy
{
    class IStorage : DisposableIpcService
    {
        private static int s_failLogged;   // S2Arm：读失败黄字只记前 32 次

        private SharedRef<LibHac.FsSrv.Sf.IStorage> _baseStorage;

        public IStorage(ref SharedRef<LibHac.FsSrv.Sf.IStorage> baseStorage)
        {
            _baseStorage = SharedRef<LibHac.FsSrv.Sf.IStorage>.CreateMove(ref baseStorage);
        }

        private const string Xc2JpTitleId = "0100f3400332c000";
        private const string Xc2GlobalTitleId = "0100e95004038000";
        private static bool IsXc2 => TitleIDs.CurrentApplication.Value.OrDefault() is Xc2GlobalTitleId or Xc2JpTitleId;

        [CommandCmif(0)]
        // Read(u64 offset, u64 length) -> buffer<u8, 0x46, 0> buffer
        public ResultCode Read(ServiceCtx context)
        {
            ulong offset = context.RequestData.ReadUInt64();
            ulong size = context.RequestData.ReadUInt64();

            if (context.Request.ReceiveBuff.Count > 0)
            {
                ulong bufferAddress = context.Request.ReceiveBuff[0].Position;
                ulong bufferLen = context.Request.ReceiveBuff[0].Size;

                // Use smaller length to avoid overflows.
                if (size > bufferLen)
                {
                    size = bufferLen;
                }

                using WritableRegion region = context.Memory.GetWritableRegion(bufferAddress, (int)bufferLen, true);
                Result result;

                try
                {
                    result = _baseStorage.Get.Read((long)offset, new OutBuffer(region.Memory.Span), (long)size);
                }
                catch (HorizonResultException hre) when (hre.IsOfResultType(ResultFs.NonRealDataVerificationFailed))
                {
                    Logger.Error?.Print(LogClass.ServiceFs, 
                        $"Encountered corrupted data in filesystem storage @ offset 0x{offset:X8}, size 0x{size:X8}. " +
                        "Please redump the current game and/or update from your console.");
                    result = ResultFs.NonRealDataVerificationFailed;
                }

                // S2Arm（11-17）：读失败原先只有数据校验失败那一种记日志，其余（宿主文件对不上 / 越界等）静默交回游戏；每次只记前 32 次
                if (result.IsFailure() && !result.Equals(ResultFs.NonRealDataVerificationFailed.Value) && System.Threading.Interlocked.Increment(ref s_failLogged) <= 32)
                {
                    Logger.Warning?.Print(LogClass.ServiceFs, $"读存储失败 @ 偏移 0x{offset:X}，请求 0x{size:X}，结果 {result.ToStringWithName()}");
                }

                // S2Arm：流式读按真机存储速度限流（S2AFsStreamPace；只记账，锁外才睡）
                if (result.IsSuccess())
                {
                    S2AFsStreamPace.Note(this, (long)offset, (long)size);
                }

                if (context.Device.DirtyHacks.IsEnabled(DirtyHack.Xc2MenuSoftlockFix) && IsXc2)
                {
                    // Add a load-bearing sleep to avoid XC2 softlock
                    // https://web.archive.org/web/20240728045136/https://github.com/Ryujinx/Ryujinx/issues/2357
                    Thread.Sleep(2);
                }

                return (ResultCode)result.Value;
            }

            return ResultCode.Success;
        }

        [CommandCmif(4)]
        // GetSize() -> u64 size
        public ResultCode GetSize(ServiceCtx context)
        {
            Result result = _baseStorage.Get.GetSize(out long size);

            context.ResponseData.Write(size);

            return (ResultCode)result.Value;
        }

        protected override void Dispose(bool isDisposing)
        {
            if (isDisposing)
            {
                _baseStorage.Destroy();
            }
        }
    }
}
