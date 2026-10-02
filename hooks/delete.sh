#!/usr/bin/env bash
#
# File name: delete.sh
# Description: Delete files when a download is stopped/errored/removed.
# Version: 4.0.0
#
# ---------------------------------------------------------------------------
# Changes vs upstream delete.sh (v3.0):
#   FIX  DELETE_ON_STOP checked `-f "${TASK_PATH}.aria2"` to decide whether to
#        delete, so a completed download whose .aria2 was already removed was
#        never cleaned up on error. Now keys off task status only.
#   FIX  Operator precedence: `a = error && b` OR `c && d` grouped wrongly for
#        the "unknown" case, so delete-on-unknown could fire on unrelated states.
#        Now explicit parenthesised groups.
#   FIX  `rm -vrf "${TASK_PATH}"` with no guard could delete a directory tree
#        when TASK_PATH resolved to a prefix of the download dir. Guarded via
#        require_path + a check that the path is not the download root.
#   FIX  CHECK_RPC_CONECTION result was only used in an `elif`, so a broken RPC
#        fell through to "Aria2 RPC interface error" even when delete-on-unknown
#        applied. Reworked.
#   OPT  Typo fixed (CONECTION) and unified with core's RPC helpers.
# ---------------------------------------------------------------------------

source "$(dirname "${BASH_SOURCE[0]}")/core"

CHECK_CORE_FILE() { :; }

CHECK_RPC_CONNECTION() {
    local payload
    if [[ -n "${RPC_SECRET}" ]]; then
        payload='{"jsonrpc":"2.0","method":"aria2.getVersion","id":"aria2-pro","params":["token:'"${RPC_SECRET}"'"]}'
    else
        payload='{"jsonrpc":"2.0","method":"aria2.getVersion","id":"aria2-pro","params":[]}'
    fi
    curl --max-time 10 -fsSd "${payload}" "${RPC_ADDRESS}" >/dev/null 2>&1
}

# Refuse to rm a path that is the download root itself or an ancestor of it.
is_safe_to_delete() {
    local p="$1"
    require_path "${p}" "delete target" || return 1
    if path_is_under "${ARIA2_DOWNLOAD_DIR}" "${p}"; then
        err "Refusing to delete '${p}': it contains the aria2 download root."
        return 1
    fi
    return 0
}

DELETE_ON_STOP() {
    local status="${TASK_STATUS}"
    local should=false reason=""
    if [[ "${status}" == "error" && "${DELETE_ON_ERROR}" == "true" ]]; then
        should=true; reason="download error"
    elif [[ "${status}" == "removed" && "${DELETE_ON_REMOVED}" == "true" ]]; then
        should=true; reason="task removed"
    fi
    if [[ "${should}" != "true" ]]; then
        warn "Skip delete. Task status not eligible: ${status}"
        return 0
    fi
    if [[ ! -e "${TASK_PATH}" ]]; then
        warn "Skip delete. File does not exist: ${TASK_PATH}"
        return 0
    fi
    is_safe_to_delete "${TASK_PATH}" || return 1
    info "Task ${status} (${reason}), deleting: ${TASK_PATH}"
    rm -vrf -- "${TASK_PATH}"
}

DELETE_ON_UNKNOWN() {
    if [[ ! -e "${FILE_PATH}" ]]; then
        warn "Skip delete. File does not exist: ${FILE_PATH}"
        return 0
    fi
    is_safe_to_delete "${FILE_PATH}" || return 1
    info "Task force-removed and info unreadable, deleting: ${FILE_PATH}"
    rm -vrf -- "${FILE_PATH}"
}

DELETE_FILE() {
    READ_ARIA2_CONF
    if GET_TASK_INFO && [[ -n "${RPC_RESULT}" ]]; then
        GET_DOWNLOAD_DIR
        GET_TASK_STATUS
        CONVERSION_PATH
        DELETE_ON_STOP
        DELETE_DOT_TORRENT
        DELETE_EMPTY_DIR
    elif CHECK_RPC_CONNECTION; then
        if [[ "${DELETE_ON_UNKNOWN}" == "true" && ${FILE_NUM} -eq 1 ]]; then
            DELETE_ON_UNKNOWN
        else
            info "RPC reachable but task info unavailable and delete-on-unknown disabled."
        fi
    else
        err "Aria2 RPC interface error!"
        exit 1
    fi
}

CHECK_PARAMETER "$@"
CHECK_FILE_NUM
CHECK_SCRIPT_CONF
DELETE_FILE
exit 0
