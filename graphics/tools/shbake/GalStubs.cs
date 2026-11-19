// 渲染器 / 程序 / 管线的手写替身（取代 System.Reflection.DispatchProxy）：S2A.ShBake 随 Mac 发版预编为 NativeAOT 单文件，
//   DispatchProxy 要在运行时生成类型（Reflection.Emit），AOT 下 Create 直接抛 PlatformNotSupportedException（烘焙的 BakeRenderer、selftest-vtg / matwait 全挂）。
// 语义与原代理一致：每个接口成员都转到 Missing（名字 = 原代理 MethodInfo.Name，属性 / 事件同 get_X / add_X 写法）；缺省返回该类型缺省值（原代理的
//   「值类型 Activator.CreateInstance、引用类型 null」），子类按需覆盖具体成员或覆盖 Missing（烘焙渲染器：除能力表外一律抛异常）。
// 只实现接口里没有缺省实现的成员；带缺省实现的（TryMakeThreaded、RunLoop、CreateTexture(info, scale) 等）照接口原样。
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using System;
using System.Threading;

namespace S2A.ShBake
{
    public abstract class StubRenderer : IRenderer
    {
        protected virtual T Missing<T>(string member) => default;
        void Call(string member) => Missing<object>(member);

        public event EventHandler<ScreenCaptureImageInfo> ScreenCaptured { add => Call("add_ScreenCaptured"); remove => Call("remove_ScreenCaptured"); }
        public virtual bool PreferThreading => Missing<bool>("get_PreferThreading");
        public virtual IPipeline Pipeline => Missing<IPipeline>("get_Pipeline");
        public virtual IWindow Window => Missing<IWindow>("get_Window");
        public virtual uint ProgramCount => Missing<uint>("get_ProgramCount");
        public virtual void BackgroundContextAction(Action action, bool alwaysBackground = false) => Call(nameof(BackgroundContextAction));
        public virtual BufferHandle CreateBuffer(int size, BufferAccess access = BufferAccess.Default) => Missing<BufferHandle>(nameof(CreateBuffer));
        public virtual BufferHandle CreateBuffer(nint pointer, int size) => Missing<BufferHandle>(nameof(CreateBuffer));
        public virtual BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers) => Missing<BufferHandle>(nameof(CreateBufferSparse));
        public virtual IImageArray CreateImageArray(int size, bool isBuffer) => Missing<IImageArray>(nameof(CreateImageArray));
        public virtual IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info) => Missing<IProgram>(nameof(CreateProgram));
        public virtual ISampler CreateSampler(SamplerCreateInfo info) => Missing<ISampler>(nameof(CreateSampler));
        public virtual ITexture CreateTexture(TextureCreateInfo info) => Missing<ITexture>(nameof(CreateTexture));
        public virtual ITextureArray CreateTextureArray(int size, bool isBuffer) => Missing<ITextureArray>(nameof(CreateTextureArray));
        public virtual bool PrepareHostMapping(nint address, ulong size) => Missing<bool>(nameof(PrepareHostMapping));
        public virtual void CreateSync(ulong id, bool strict) => Call(nameof(CreateSync));
        public virtual void DeleteBuffer(BufferHandle buffer) => Call(nameof(DeleteBuffer));
        public virtual PinnedSpan<byte> GetBufferData(BufferHandle buffer, int offset, int size) => Missing<PinnedSpan<byte>>(nameof(GetBufferData));
        public virtual Capabilities GetCapabilities() => Missing<Capabilities>(nameof(GetCapabilities));
        public virtual ulong GetCurrentSync() => Missing<ulong>(nameof(GetCurrentSync));
        public virtual HardwareInfo GetHardwareInfo() => Missing<HardwareInfo>(nameof(GetHardwareInfo));
        public virtual IProgram LoadProgramBinary(byte[] programBinary, bool hasFragmentShader, ShaderInfo info) => Missing<IProgram>(nameof(LoadProgramBinary));
        public virtual void SetBufferData(BufferHandle buffer, int offset, ReadOnlySpan<byte> data) => Call(nameof(SetBufferData));
        public virtual void UpdateCounters() => Call(nameof(UpdateCounters));
        public virtual void PreFrame() => Call(nameof(PreFrame));
        public virtual ICounterEvent ReportCounter(CounterType type, EventHandler<ulong> resultHandler, float divisor, bool hostReserved) => Missing<ICounterEvent>(nameof(ReportCounter));
        public virtual void ResetCounter(CounterType type) => Call(nameof(ResetCounter));
        public virtual void WaitSync(ulong id) => Call(nameof(WaitSync));
        public virtual void Initialize(GraphicsDebugLevel logLevel) => Call(nameof(Initialize));
        public virtual void SetInterruptAction(Action<Action> interruptAction) => Call(nameof(SetInterruptAction));
        public virtual void Screenshot() => Call(nameof(Screenshot));
        public virtual void Dispose() => Call(nameof(Dispose));
    }

    public abstract class StubProgram : IProgram
    {
        protected virtual T Missing<T>(string member) => default;
        public virtual ProgramLinkStatus CheckProgramLink(bool blocking) => Missing<ProgramLinkStatus>(nameof(CheckProgramLink));
        public virtual byte[] GetBinary() => Missing<byte[]>(nameof(GetBinary));
        public virtual void Dispose() => Missing<object>(nameof(Dispose));
    }

    /// <summary>空管线：每个成员什么都不做、返回缺省值（原 MwNoop 代理）</summary>
    public sealed class NoopPipeline : IPipeline
    {
        public void Barrier() { }
        public void BeginTransformFeedback(PrimitiveTopology topology) { }
        public void ClearBuffer(BufferHandle destination, int offset, int size, uint value) { }
        public void ClearRenderTargetColor(int index, int layer, int layerCount, uint componentMask, ColorF color) { }
        public void ClearRenderTargetDepthStencil(int layer, int layerCount, float depthValue, bool depthMask, int stencilValue, int stencilMask) { }
        public void CommandBufferBarrier() { }
        public void CopyBuffer(BufferHandle source, BufferHandle destination, int srcOffset, int dstOffset, int size) { }
        public void DispatchCompute(int groupsX, int groupsY, int groupsZ) { }
        public void Draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance) { }
        public void DrawIndexed(int indexCount, int instanceCount, int firstIndex, int firstVertex, int firstInstance) { }
        public void DrawIndexedIndirect(BufferRange indirectBuffer) { }
        public void DrawIndexedIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride) { }
        public void DrawIndirect(BufferRange indirectBuffer) { }
        public void DrawIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride) { }
        public void DrawTexture(ITexture texture, ISampler sampler, Extents2DF srcRegion, Extents2DF dstRegion) { }
        public void EndTransformFeedback() { }
        public void SetAlphaTest(bool enable, float reference, CompareOp op) { }
        public void SetBlendState(AdvancedBlendDescriptor blend) { }
        public void SetBlendState(int index, BlendDescriptor blend) { }
        public void SetDepthBias(PolygonModeMask enables, float factor, float units, float clamp) { }
        public void SetDepthClamp(bool clamp) { }
        public void SetDepthMode(DepthMode mode) { }
        public void SetDepthTest(DepthTestDescriptor depthTest) { }
        public void SetFaceCulling(bool enable, Face face) { }
        public void SetFrontFace(FrontFace frontFace) { }
        public void SetIndexBuffer(BufferRange buffer, IndexType type) { }
        public void SetImage(ShaderStage stage, int binding, ITexture texture) { }
        public void SetImageArray(ShaderStage stage, int binding, IImageArray array) { }
        public void SetImageArraySeparate(ShaderStage stage, int setIndex, IImageArray array) { }
        public void SetLineParameters(float width, bool smooth) { }
        public void SetLogicOpState(bool enable, LogicalOp op) { }
        public void SetMultisampleState(MultisampleDescriptor multisample) { }
        public void SetPatchParameters(int vertices, ReadOnlySpan<float> defaultOuterLevel, ReadOnlySpan<float> defaultInnerLevel) { }
        public void SetPointParameters(float size, bool isProgramPointSize, bool enablePointSprite, Origin origin) { }
        public void SetPolygonMode(PolygonMode frontMode, PolygonMode backMode) { }
        public void SetPrimitiveRestart(bool enable, int index) { }
        public void SetPrimitiveTopology(PrimitiveTopology topology) { }
        public void SetProgram(IProgram program) { }
        public void SetRasterizerDiscard(bool discard) { }
        public void SetRenderTargetColorMasks(ReadOnlySpan<uint> componentMask) { }
        public void SetRenderTargets(Span<ITexture> colors, ITexture depthStencil) { }
        public void SetScissors(ReadOnlySpan<Rectangle<int>> regions) { }
        public void SetStencilTest(StencilTestDescriptor stencilTest) { }
        public void SetStorageBuffers(ReadOnlySpan<BufferAssignment> buffers) { }
        public void SetTextureAndSampler(ShaderStage stage, int binding, ITexture texture, ISampler sampler) { }
        public void SetTextureArray(ShaderStage stage, int binding, ITextureArray array) { }
        public void SetTextureArraySeparate(ShaderStage stage, int setIndex, ITextureArray array) { }
        public void SetTransformFeedbackBuffers(ReadOnlySpan<BufferRange> buffers) { }
        public void SetUniformBuffers(ReadOnlySpan<BufferAssignment> buffers) { }
        public void SetUserClipDistance(int index, bool enableClip) { }
        public void SetVertexAttribs(ReadOnlySpan<VertexAttribDescriptor> vertexAttribs) { }
        public void SetVertexBuffers(ReadOnlySpan<VertexBufferDescriptor> vertexBuffers) { }
        public void SetViewports(ReadOnlySpan<Viewport> viewports) { }
        public void TextureBarrier() { }
        public void TextureBarrierTiled() { }
        public bool TryHostConditionalRendering(ICounterEvent value, ulong compare, bool isEqual) => false;
        public bool TryHostConditionalRendering(ICounterEvent value, ICounterEvent compare, bool isEqual) => false;
        public void EndHostConditionalRendering() { }
    }
}
