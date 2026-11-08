#!/usr/bin/env python3
"""Exercise the actual bundled runtime without Homebrew or a .NET SDK; Metal uses external Xcode.

The tiny shader and filesystem inputs are tool probes, not game compatibility
fixtures. Run on a Mac with GPU access. No downloads or player files are used.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--runtime', type=Path, required=True)
    p.add_argument('--tools', type=Path, required=True)
    p.add_argument('--developer-dir',default=None)   # 不给 = xcode-select 当前指向（10-25：不写死 Xcode.app）
    args=p.parse_args()
    runtime, tools=args.runtime.resolve(), args.tools.resolve()
    env=dict(os.environ, PATH=os.pathsep.join([str(runtime/'bin'),str(runtime/'python/bin'),'/usr/bin','/bin','/usr/sbin','/sbin']),
             DEVELOPER_DIR=args.developer_dir or subprocess.run(['/usr/bin/xcode-select','-p'],capture_output=True,text=True).stdout.strip(), DOTNET_ROOT=str(runtime/'dotnet'), DOTNET_MULTILEVEL_LOOKUP='0',
             PYTHONNOUSERSITE='1', PYTHONDONTWRITEBYTECODE='1', DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_NOLOGO='1')
    def run(command):
        r=subprocess.run(list(map(str,command)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        if r.returncode:raise RuntimeError(str(command)+'\n'+r.stdout[-4000:])
        return r.stdout.strip()
    assert run([runtime/'bin/dotnet','--list-sdks']) == '', 'Probe must not have an SDK'
    assert 'Microsoft.NETCore.App 10.' in run([runtime/'bin/dotnet','--list-runtimes'])
    run([runtime/'python/bin/python3','-B','-I','-c',
         "import capstone,lz4.block,numpy; assert lz4.block.decompress(lz4.block.compress(b'S2Arm'))==b'S2Arm'; print('Python OK')"])
    version={'macosSDK':run(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-version'])}
    with tempfile.TemporaryDirectory(prefix='s2arm-runtime-smoke-') as raw:
        root=Path(raw)
        (root/'romfs').mkdir();(root/'romfs/probe.txt').write_text('S2Arm runtime probe')
        run([runtime/'bin/dotnet',tools/'romfs/romfs_index.dll',root])
        assert (root/'romfs.s2aidx').stat().st_size > 0
        assembly=root/'probe.spvasm';spv=root/'spv';spv.mkdir()
        assembly.write_text('OpCapability Shader\nOpMemoryModel Logical GLSL450\nOpEntryPoint GLCompute %main "main"\nOpExecutionMode %main LocalSize 1 1 1\n%void = OpTypeVoid\n%fn = OpTypeFunction %void\n%main = OpFunction %void None %fn\n%entry = OpLabel\nOpReturn\nOpFunctionEnd\n')
        run([runtime/'bin/spirv-as','--target-env','vulkan1.0',assembly,'-o',spv/'0000000000000001.spv'])
        run([runtime/'bin/spirv-val','--target-env','vulkan1.0',spv/'0000000000000001.spv'])
        translated=root/'translated'
        run([tools/'gal/gal_xc',spv,translated,'1'])
        assert (translated/'gal.idx').stat().st_size > 24
        assert list((translated/'msl').glob('*.metal'))
        # 内置 s2a-devpush（Mac 推资源包流式写手机，tools/push_pack.py 用；11-06）：本地打一个 pax tar 再核完整性，不连手机
        (root/'dp').mkdir(); (root/'dp/a.bin').write_bytes(b'S2Arm devpush probe'); (root/'dp.lst').write_text('a.bin\n')
        run([tools/'devpush/s2a-devpush','-','-','tar-local',root/'dp.lst',root/'dp',root/'dp.tar'])
        assert run([tools/'devpush/s2a-devpush','-','-','tar-ok-local',root/'dp.tar']).strip()=='ok'
        src=root/'probe.metal'; air=root/'probe.air'; lib=root/'probe.metallib'
        src.write_text('#include <metal_stdlib>\nusing namespace metal;\nkernel void copy_value(device uint *v [[buffer(0)]], uint i [[thread_position_in_grid]]) { v[i]=i; }\n')
        run(['/usr/bin/xcrun','-sdk','macosx','metal','-mmacosx-version-min=15.0','-c',src,'-o',air])
        run(['/usr/bin/xcrun','-sdk','macosx','metallib',air,'-o',lib])
        assert lib.stat().st_size > 0
        arch=run([tools/'shbake/gpu_arch'])
        nt=Path(run(['/usr/bin/xcrun','-f','metal-tt'])).parent/'../metal/current/bin/applegpu-nt'
        sdk=run(['/usr/bin/xcrun','--sdk','macosx','--show-sdk-path'])
        if not arch:raise RuntimeError('A Metal device is required for the archive probe')
        descriptor=dict(version=dict(major=0,minor=1,sub_minor=0),generator='MetalFramework',
                        libraries=[dict(label='probe',path=str(lib))],
                        function_descriptors=dict(library_function_descriptors=[dict(label='copy',name='copy_value',library='probe')]),
                        pipeline_descriptors=dict(render_pipeline_descriptors=[],compute_pipeline_descriptors=[dict(compute_function_descriptor='fnd:copy')]))
        job=root/'probe.mtl4-json';job.write_text(json.dumps(descriptor))
        archive=root/'probe.bin'
        run([nt,'-arch',arch,'-platform_version','macos',version['macosSDK'],version['macosSDK'],
             '-sysroot',sdk,'-j','1','-N',job,'-o',archive])
        assert archive.stat().st_size > 0
    print('Bundled Python, .NET (no SDK), RomFS index, SPIR-V/GAL translation passed; external Xcode Metal compilation/link and GPU archive passed')


if __name__=='__main__':main()
