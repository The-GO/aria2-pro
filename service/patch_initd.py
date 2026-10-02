#!/usr/bin/env python3
"""就地修补 P3TERX/aria2.sh 下载的 init.d 服务脚本(上游自 2020 年未更新)。

修三类问题:
1. check_running 用 `ps -ef | grep` 会把僵尸(Z)进程判成"正在运行"
   -> kill 不掉、restart 后拒绝启动(aria2 实际已死)
2. do_stop 只 kill 不等待退出 -> 紧接着 start 会端口/会话冲突
3. do_start 固定 sleep 2s 判成败 -> 慢机/ARM 上误报启动失败

用法: patch_initd.py <init.d 路径>
"""
import re
import sys

CHECK_RUNNING_NEW = (
    "check_running() {\n"
    "\t# 排除僵尸(Z)进程: 僵尸无法 kill, 也导致 restart 后误判[running]而拒绝启动\n"
    "\tPID=$(ps -eo pid,stat,comm | awk -v n=\"${NAME_BIN}\" '$3==n && $2 !~ /Z/ {print $1}')\n"
    "\t[[ -z ${PID} ]] && return 1\n"
    "\tlocal real=\"\"\n"
    "\tfor _p in ${PID}; do\n"
    "\t\t[[ -r /proc/${_p}/cmdline ]] && tr '\\0' ' ' </proc/${_p}/cmdline | grep -q \"${NAME_BIN}\" && real=\"${real} ${_p}\"\n"
    "\tdone\n"
    "\tPID=${real# }\n"
    "\t[[ -z ${PID} ]] && return 1\n"
    "\treturn 0\n"
    "}"
)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_initd.py <path>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    try:
        with open(path, "r", encoding="utf-8") as fh:
            src = fh.read()
    except OSError as exc:
        print(f"cannot read {path}: {exc}", file=sys.stderr)
        return 2

    if "排除僵尸" in src:
        print("already-patched")
        return 0

    pat = re.compile(r"check_running\(\) \{.*?\n\}", re.S)
    if not pat.search(src):
        print("check_running not found", file=sys.stderr)
        return 3
    src = pat.sub(lambda _m: CHECK_RUNNING_NEW, src, count=1)

    old_stop = "kill -9 ${PID}\n\t\tRETVAL=$?"
    new_stop = (
        "kill -9 ${PID}\n"
        "\t\t# 等待进程真正退出，否则紧接着 start 会因端口/会话占用失败\n"
        "\t\tfor _i in {1..30}; do\n"
        "\t\t\tcheck_running || break\n"
        "\t\t\tsleep 0.2\n"
        "\t\tdone\n"
        "\t\tRETVAL=$?"
    )
    if old_stop in src:
        src = src.replace(old_stop, new_stop, 1)

    old_start = (
        'nohup /usr/local/bin/aria2c --conf-path="${CONFIG}" >>"${LOG}" 2>&1 &\n'
        "\t\tsleep 2s\n"
        "\t\tcheck_running\n"
        "\t\tif [[ $? -eq 0 ]]; then"
    )
    new_start = (
        'nohup /usr/local/bin/aria2c --conf-path="${CONFIG}" >>"${LOG}" 2>&1 &\n'
        "\t\t# 轮询等待就绪，固定 sleep 在慢机/ARM 上会误报失败\n"
        "\t\tlocal ok=0\n"
        "\t\tfor _i in {1..25}; do\n"
        "\t\t\tsleep 0.4\n"
        "\t\t\tcheck_running && { ok=1; break; }\n"
        "\t\tdone\n"
        "\t\tif [[ ${ok} -eq 1 ]]; then"
    )
    if old_start in src:
        src = src.replace(old_start, new_start, 1)

    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(src)
    except OSError as exc:
        print(f"cannot write {path}: {exc}", file=sys.stderr)
        return 2
    print("patched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
