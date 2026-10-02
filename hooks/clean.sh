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
# is unavailable or torrent cleanup is disabled. Without this, DOWNLOAD_DIR
# stayed empty and DELETE_EMPTY_DIR refused to run (correctly, but uselessly).
if [[ -z "${DOWNLOAD_DIR}" || -z "${TASK_PATH}" ]]; then
    READ_ARIA2_CONF
    DOWNLOAD_DIR="${ARIA2_DOWNLOAD_DIR}"
    RELATIVE_PATH="${FILE_PATH#"${ARIA2_DOWNLOAD_DIR}/"}"
    TASK_FILE_NAME="${RELATIVE_PATH%%/*}"
    [[ -n "${TASK_FILE_NAME}" ]] && TASK_PATH="${ARIA2_DOWNLOAD_DIR}/${TASK_FILE_NAME}"
fi

DELETE_DOT_ARIA2
DELETE_EXCLUDE_FILE
DELETE_EMPTY_DIR
info "Cleanup finished."
exit 0
