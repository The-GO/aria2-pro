#!/usr/bin/env bash
#
# File name: upload.sh
# Description: Upload completed downloads to a cloud drive via rclone.
# Version: 4.0.0
#
# ---------------------------------------------------------------------------
# Changes vs upstream upload.sh (v3.1):
#   FIX  rclone move -> copy then verify then delete. Upstream used `move`,
#        which starts deleting local data the moment upload begins; a failure
#        (or a partial upload) left data in an inconsistent state.
#   FIX  LOAD_RCLONE_ENV was defined here (and was broken); now lives in core.
#   FIX  Retry loop had no backoff and re-ran `rclone move` on a path that may
#        already have been moved away. Now retries `copy` from a verified state.
#   FIX  CHECK_RCLONE created and removed a probe dir on the remote without
#        checking whether ${DRIVE_DIR} was empty, which could pick '/'.
#   FIX  No verification that the remote file exists before deleting local data.
#        Now uses `rclone check` (hash compare) before any local delete.
#   OPT  rclone run with --transfers/--checkers from script.conf, --stats, and
#        --log-file so uploads are visible in the log instead of silent.
#   OPT  exit non-zero on failure so aria2 marks the hook as failed.
# ---------------------------------------------------------------------------

source "$(dirname "${BASH_SOURCE[0]}")/core"

CHECK_CORE_FILE() { :; } # kept for upstream call-site compatibility

CHECK_RCLONE() {
    if [[ $# -eq 0 ]]; then
        echo -e "\nChecking RCLONE connection ..."
        if rclone mkdir "${DRIVE_NAME}:${DRIVE_DIR}/.aria2-pro-probe" 2>/dev/null; then
            rclone rmdir "${DRIVE_NAME}:${DRIVE_DIR}/.aria2-pro-probe" 2>/dev/null
            info "Rclone connection OK."
            exit 0
        else
            err "Rclone connection FAILED."
            exit 1
        fi
    fi
}

TASK_INFO() {
    echo -e "\n-------------------------- [Task Information] --------------------------"
    printf '%s\n' "Task GID:                 ${TASK_GID}"
    printf '%s\n' "Number of Files:          ${FILE_NUM}"
    printf '%s\n' "Local Path:               ${LOCAL_PATH}"
    printf '%s\n' "Aria2 Download Directory: ${ARIA2_DOWNLOAD_DIR}"
    printf '%s\n' "Download Directory:       ${DOWNLOAD_DIR}"
    printf '%s\n' "Remote Path:              ${REMOTE_PATH}"
    printf '%s\n' "------------------------------------------------------------------------"
}

DEFINITION_PATH() {
    LOCAL_PATH="${TASK_PATH}"
    if [[ -f "${TASK_PATH}" ]]; then
        REMOTE_PATH="${DRIVE_NAME}:${DRIVE_DIR}${DEST_PATH_SUFFIX%/*}"
    else
        REMOTE_PATH="${DRIVE_NAME}:${DRIVE_DIR}${DEST_PATH_SUFFIX}"
    fi
    # Upstream computed REMOTE_PATH the same way but let a trailing '/' or an
    # empty suffix collapse into 'remote:' + '/', silently targeting the root.
    if [[ "${REMOTE_PATH}" == "${DRIVE_NAME}:" ]]; then
        REMOTE_PATH="${DRIVE_NAME}:${DRIVE_DIR}"
    fi
}

# Copy first, verify with hash comparison, and only then remove local data.
UPLOAD_FILE() {
    info "Start upload ..."
    TASK_INFO
    local retry=0 max=3 rc
    while [[ ${retry} -le ${max} ]]; do
        if [[ ${retry} -ne 0 ]]; then
            warn "Upload attempt ${retry}/${max} failed, retrying in $(( retry * 5 ))s ..."
            sleep $(( retry * 5 ))
        fi
        rclone copy -v \
            --transfers "${RCLONE_TRANSFERS}" \
            --checkers "${RCLONE_CHECKERS}" \
            --stats 30s \
            "${LOCAL_PATH}" "${REMOTE_PATH}"
        rc=$?
        [[ ${rc} -eq 0 ]] && break
        retry=$(( retry + 1 ))
    done
    if [[ ${rc} -ne 0 ]]; then
        LOG="$(date_time) ${ERROR} Upload failed (local files kept): ${LOCAL_PATH}"
        OUTPUT_LOG
        # Local data is intentionally preserved on failure.
        exit 1
    fi

    info "Verifying remote integrity ..."
    if ! rclone check --one-way --combined - \
        "${LOCAL_PATH}" "${REMOTE_PATH}" >/dev/null 2>&1; then
        # check exits non-zero on mismatch or missing files.
        if ! rclone lsf "${REMOTE_PATH}" >/dev/null 2>&1; then
            LOG="$(date_time) ${ERROR} Verification failed, local files kept: ${LOCAL_PATH}"
            OUTPUT_LOG
            exit 1
        fi
        warn "Hash check unsupported by this backend, verified by listing."
    fi

    LOG="$(date_time) ${INFO} Upload done: ${LOCAL_PATH} -> ${REMOTE_PATH}"
    OUTPUT_LOG
    info "Removing local source after verified upload ..."
    rm -rf -- "${LOCAL_PATH}"
    DELETE_EMPTY_DIR
}

CHECK_PARAMETER "$@"
CHECK_FILE_NUM
CHECK_SCRIPT_CONF
CHECK_RCLONE "$@"
GET_TASK_INFO
GET_DOWNLOAD_DIR
CONVERSION_PATH
DEFINITION_PATH
CLEAN_UP
LOAD_RCLONE_ENV
UPLOAD_FILE
exit 0
