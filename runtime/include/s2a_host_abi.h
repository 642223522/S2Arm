// 宿主读产物的约定号（单一来源）：宿主（手机 / Mac）读每款产物的方式——改写器与运行时的约定（跳板 / 虚拟寄存器槽 / 门控表）、
//   *.fixups / *.sites / *.gates / addr_need.tsv 等表的格式、镜像 / 程序目录布局——变了就把它加 1；只修宿主自身的 bug 不动它。
//   电脑侧（pack/jobs/host_update.py HOST_ABI）从本文件机械读出，写进每款产物（s2a_catalogue.json 的 host_abi、Mac 镜像 manifest.json 的 hostAbi）；
//   宿主载入一款时拿产物上记的号和这里比，不等就不载入（产物没记 = 本字段之前出的包，按 1）。
#pragma once
#define S2A_HOST_ABI 2
