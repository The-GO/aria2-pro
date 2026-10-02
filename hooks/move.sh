#!/usr/bin/env bash
#
# File name: move.sh
# Description: Move completed downloads to another local directory.
# Version: 4.0.0
#
# ---------------------------------------------------------------------------
# Changes vs upstream move.sh (v3.0):
#   FIX  `mv` without `--` breaks on paths starting with '-'; added `--`.
#   FIX  No existence check before mv; on failure the script still reported
#        success-ish state. Now verifies the source exists and re-checks rc.
#   FIX  `=~` with a quoted RHS (literal match). Now uses core's path_is_under.
#   FIX  DELETE_EMPTY_DIR ran even when the move failed, potentially pruning
#        directories that still held data. Now only on success.
#   OPT  Logs the destination and keeps a move log.
# ---------------------------------------------------------------------------

source "$(dirname "${BASH_SOURCE[0]}")/core"

CHECK_CORE_FILE() { :; }

DEFINITION_PATH() {
    # 先校验再使用: 原实现在用过 ${DEST_DIR} 之后才检查它为空。
    require_path "${TASK_PATH}" "source task path" || exit 1
    if [[ -z "${DEST_DIR}" ]]; then
        err "dest-dir is not set in script.conf."
        exit 1
    fi
    # 目标不能包含源本身, 否则 mv 会把数据移回下载目录
    if path_is_under "${TASK_PATH}" "${DEST_DIR%/}"; then
        err "Refusing to move: destination '${DEST_DIR}' contains the source '${TASK_PATH}'."
        exit 1
    fi
    SOURCE_PATH="${TASK_PATH}"
    local dest_dir="${DEST_DIR%/}"
    if [[ "${DOWNLOAD_DIR}" != "${ARIA2_DOWNLOAD_DIR}" ]] \
        && path_is_under "${DOWNLOAD_DIR}" "${ARIA2_DOWNLOAD_DIR}"; then
        DEST_PATH="${dest_dir}${DEST_PATH_SUFFIX%/*}"
        # 空后缀时塌缩为 dest_dir 本身
        if [[ -z "${DEST_PATH_SUFFIX}" || "${DEST_PATH_SUFFIX}" == "/" ]]; then
            DEST_PATH="${dest_dir}"
        fi
    else
        DEST_PATH="${dest_dir}"
    fi
}

TASK_INFO() {
    echo -e "\n-------------------------- [Task Information] --------------------------"
    printf '%s\n' "Task GID:           ${TASK_GID}"
    printf '%s\n' "Number of Files:    ${FILE_NUM}"
    printf '%s\n' "Source Path:        ${SOURCE_PATH}"
    printf '%s\n' "Destination Path:   ${DEST_PATH}"
    printf '%s\n' "------------------------------------------------------------------------"
}

MOVE_FILE() {
    info "Start move ..."
    TASK_INFO
    if [[ ! -e "${SOURCE_PATH}" ]]; then
        LOG="$(date_time) ${ERROR} Move failed, source missing: ${SOURCE_PATH}"
        OUTPUT_LOG
        exit 1
    fi
    mkdir -p "${DEST_PATH}" || {
        LOG="$(date_time) ${ERROR} Move failed, cannot create target dir: ${DEST_PATH}"
        OUTPUT_LOG
        exit 1
    }
    mv -v -- "${SOURCE_PATH}" "${DEST_PATH}"
    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        # FIX: upstream logged DEST_PATH, but `mv dir dest/` lands at
        # dest/dir. Report where the data actually is.
        local base final
        base="$(basename "${SOURCE_PATH}")"
        final="${DEST_PATH%/}/${base}"
        [[ -d "${final}" || -f "${final}" ]] && REAL_DEST="${final}" || REAL_DEST="${DEST_PATH}"
        LOG="$(date_time) ${INFO} Move done: ${SOURCE_PATH} -> ${REAL_DEST}"
        OUTPUT_LOG
        DELETE_EMPTY_DIR
    else
        LOG="$(date_time) ${ERROR} Move failed (rc=${rc}): ${SOURCE_PATH}"
        OUTPUT_LOG
        exit 1
    fi
}

CHECK_PARAMETER "$@"
CHECK_FILE_NUM
CHECK_SCRIPT_CONF
GET_TASK_INFO
GET_DOWNLOAD_DIR
CONVERSION_PATH
DEFINITION_PATH
CLEAN_UP
MOVE_FILE
exit 0
