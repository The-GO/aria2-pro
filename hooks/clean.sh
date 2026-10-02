#!/usr/bin/env bash
#
# File name: clean.sh
# Description: Post-download cleanup (.aria2 / .torrent / filters / empty dirs).
# Version: 4.0.0
#
# Version 4 change: upstream clean.sh called GET_TASK_INFO but never used the
# result; the RPC round-trip added latency to every completed download and could
# fail the hook when aria2 was busy. We now only query the RPC when a hook
# actually needs .torrent handling (infoHash), and failure to reach it is a
# warning rather than a hard error.
#

source "$(dirname "${BASH_SOURCE[0]}")/core"

CHECK_CORE_FILE() { :; }

CHECK_PARAMETER "$@"
CHECK_FILE_NUM
CHECK_SCRIPT_CONF

# Only hit the RPC when torrent cleanup is enabled; otherwise derive the task
# path directly from the arguments aria2 gave us.
if [[ "${DELETE_DOT_TORRENT}" =~ ^(true|normal|enhanced)$ ]]; then
    if GET_TASK_INFO && [[ -n "${RPC_RESULT}" ]]; then
        GET_DOWNLOAD_DIR
        CONVERSION_PATH
        DELETE_DOT_TORRENT
    else
        warn "RPC unavailable, skipping .torrent cleanup this run."
    fi
fi

# Derive the paths locally so every other cleanup step still works when the RPC
# is unavailable or torrent cleanup is disabled.
#
# 注意: 不能假设 ${FILE_PATH} 一定在 ${ARIA2_DOWNLOAD_DIR} 下。通过 RPC/AriaNg
# 添加任务时可以指定任意 --dir, 此时按 aria2.conf 的 dir 去剥离前缀会得到错误
# 路径(实测会塌缩成 "/data/dl/" 这种带尾斜杠的危险形态)。因此直接以
# ${FILE_PATH} 自身为任务根, 再由 DELETE_* 系列自行校验。
if [[ -z "${TASK_PATH}" ]]; then
    if [[ -n "${FILE_PATH}" ]]; then
        TASK_PATH="${FILE_PATH}"
        DOWNLOAD_DIR="${FILE_PATH%/*}"
        [[ -z "${DOWNLOAD_DIR}" ]] && DOWNLOAD_DIR="/"
    else
        READ_ARIA2_CONF
        DOWNLOAD_DIR="${ARIA2_DOWNLOAD_DIR}"
    fi
    # 推导结果必须过安全校验, 否则后续 rm -rf 会作用在错误路径上
    require_path "${TASK_PATH}" "derived task path" || exit 1
fi

DELETE_DOT_ARIA2
DELETE_EXCLUDE_FILE
DELETE_EMPTY_DIR
info "Cleanup finished."
exit 0
