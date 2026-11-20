using Ryujinx.Graphics.Device;
using System;
using System.Collections.Generic;

namespace Ryujinx.Graphics.Gpu.Engine.MME
{
    /// <summary>
    /// Represents a execution engine that uses a Just-in-Time compiler for fast execution.
    /// </summary>
    [System.Diagnostics.CodeAnalysis.RequiresDynamicCode("S2A：宏 JIT 用 Reflection.Emit 现生成方法；没有动态代码（NativeAOT）时由 Macro.cs 走 S2AMacroAot / 解释器")]
    class MacroJit : IMacroEE
    {
        private readonly MacroJitContext _context = new();

        /// <summary>
        /// Arguments FIFO.
        /// </summary>
        public Queue<FifoWord> Fifo => _context.Fifo;

        private MacroJitCompiler.MacroExecute _execute;

        /// <summary>
        /// Executes a macro program until it exits.
        /// </summary>
        /// <param name="code">Code of the program to execute</param>
        /// <param name="state">Current GPU state</param>
        /// <param name="arg0">Optional argument passed to the program, 0 if not used</param>
        public void Execute(ReadOnlySpan<int> code, IDeviceState state, int arg0)
        {
            if (_execute == null)
            {
                MacroJitCompiler compiler = new();

                _execute = compiler.Compile(code);
            }

            _execute(_context, state, arg0);
        }
    }
}
