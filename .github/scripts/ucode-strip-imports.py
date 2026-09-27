#!/usr/bin/env python3
"""剥离 ucode 源码里的 import / export，用于在缺少 LuCI / uci / ubus 模块的环境里做纯语法检查。

裸 ucode（源码编译版）只有内建模块，遇到 `from 'luci.http'`、`from 'homeproxy'`、
`from 'uci'` 这类 import 会直接报 "Unable to resolve path for module ..." 而无法进入
语法检查。剥离 import 后 `ucode -c` 仍会完整校验函数体语法（正是补丁改动所在），
未定义的标识符只是运行期问题，不影响编译期检查。

同理，import 被移除后文件不再是模块，残留的 `export` 会报
"Exports may only appear at top level of a module"，故一并剥离。

用法: ucode-strip-imports.py <输入.uc> <输出.uc>
"""
import re
import sys

# 同时覆盖单行与跨多行的 import 语句：
#   import { md5 } from 'digest';
#   import {
#       validation, HP_DIR, RUN_DIR
#   } from 'homeproxy';
IMPORT_RE = re.compile(r"^import\s+.*?\s+from\s+'[^']+';\s*$", re.S | re.M)

# `export const X = ...` / `export function f() {}` -> 去掉 export 前缀
EXPORT_RE = re.compile(r"^\s*export\s+", re.M)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2

    with open(sys.argv[1], encoding='utf-8') as fh:
        src = fh.read()

    stripped = EXPORT_RE.sub('', IMPORT_RE.sub('', src))

    with open(sys.argv[2], 'w', encoding='utf-8') as fh:
        fh.write(stripped)

    return 0


if __name__ == '__main__':
    sys.exit(main())
