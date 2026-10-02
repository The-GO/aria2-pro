#!/usr/bin/env bash
#
# aria2-pro — BT Tracker 更新工具
#
# 用法:
#   bash tracker-update.sh [aria2.conf 路径]      # 更新配置文件中的 bt-tracker
#   bash tracker-update.sh --test                 # 只测速各源, 不写入配置
#
# 主源: https://cf.trackerslist.com/best.txt  (Cloudflare CDN, 最快)
#
# 说明: 该文件由 install.sh 以 heredoc 形式安装到 <conf-dir>/tracker-update.sh,
#       同时作为独立文件存在于仓库 bin/ 目录, 便于单独测试。
#

set -uo pipefail

# 源列表, 按优先级排列。第一个为主源, 其余为备用。
# 实测(2026-10, aarch64): cf.trackerslist.com 与 XIU2 源内容一致(71 条),
# ngosang 源已过时(仅 20 条), 故降为最低优先级备用。
TRACKER_SOURCES=(
    "https://cf.trackerslist.com/best.txt"
    "https://cf.trackerslist.com/all.txt"
    "https://raw.githubusercontent.com/XIU2/TrackersListCollection/master/best.txt"
    "https://trackerslist.com/best.txt"
    "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt"
)

TIMEOUT="${TRACKER_TIMEOUT:-15}"
USER_AGENT="Mozilla/5.0 (compatible; aria2-pro-tracker-updater)"

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

# 抓取并规范化 tracker 列表: 去空行/空白/前后缀, 只保留合法协议
fetch_list() {
    local url="$1" raw
    raw="$(wget -t2 -T"${TIMEOUT}" -qO- --user-agent="${USER_AGENT}" "${url}" 2>/dev/null || true)"
    [[ -z "${raw}" ]] && return 1
    # 源文件可能是 "一行一个" 或 "逗号分隔", 统一拆成一行一个
    printf '%s\n' "${raw}" \
        | tr -s ', \t\r' '\n\n\n\n\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -E '^(udp|http|https|wss?|tcp)://' \
        | grep -vE '^[a-z]+://[[:space:]]*$'
}

if [[ "${1:-}" == "--test" || "${1:-}" == "-t" ]]; then
    echo "各 tracker 源测速:"
    printf '%-62s %-6s %-8s %s\n' "URL" "HTTP" "耗时" "条数"
    for u in "${TRACKER_SOURCES[@]}"; do
        m="$(curl -s -o /tmp/.tr_probe.$$ -w '%{http_code} %{time_total}' \
            -A "${USER_AGENT}" --max-time "${TIMEOUT}" "${u}" 2>/dev/null || echo "000 0")"
        code="${m%% *}"; secs="${m##* }"
        n="$(fetch_list "${u}" | grep -c . || true)"
        printf '%-62s %-6s %-8s %s\n' "${u:0:60}" "${code}" "${secs}" "${n:-0}"
    done
    rm -f "/tmp/.tr_probe.$$"
    exit 0
fi

CONF="${1:-/root/.aria2/aria2.conf}"
if [[ ! -f "${CONF}" ]]; then
    echo "配置文件不存在: ${CONF}" >&2
    echo "用法: bash tracker-update.sh [aria2.conf 路径]" >&2
    exit 1
fi

# 依次尝试各源, 收集所有成功结果后合并去重(主源优先)
ALL=""
GOT=0
for u in "${TRACKER_SOURCES[@]}"; do
    if t="$(fetch_list "${u}")" && [[ -n "${t}" ]]; then
        ALL="${ALL}"$'\n'"${t}"
        GOT=$(( GOT + 1 ))
    fi
done

[[ ${GOT} -eq 0 ]] && { echo "所有 tracker 源均获取失败" >&2; exit 1; }

LIST="$(printf '%s\n' "${ALL}" | awk 'NF && !seen[$0]++' | paste -sd, -)"
COUNT="$(printf '%s\n' "${ALL}" | awk 'NF && !seen[$0]++' | grep -c . || true)"

if grep -q '^bt-tracker=' "${CONF}"; then
    # 用 awk 而非 sed: tracker 列表含大量正则元字符(/ : . -), sed 会解析失败
    awk -v v="${LIST}" 'BEGIN{FS=OFS="="} $1=="bt-tracker"{$2=v; print; next} {print}' \
        "${CONF}" >"${CONF}.tracker.tmp" && mv -f "${CONF}.tracker.tmp" "${CONF}"
else
    printf '\nbt-tracker=%s\n' "${LIST}" >>"${CONF}"
fi

echo "已从 ${GOT} 个源更新 ${COUNT} 个 tracker → ${CONF}"
