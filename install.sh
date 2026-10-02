#!/usr/bin/env bash
#
# aria2-pro — 一键安装脚本
#
# 用法:
#   bash install.sh                    # 交互式安装
#   bash install.sh --conf-dir /root/.aria2 --downloads /root/downloads
#
# 环境变量:
#   ARIA2_CONF_DIR    配置/数据目录(默认 /root/.aria2)
#   DOWNLOAD_PATH     下载目录(默认 /root/downloads)
#   ARIA2C            aria2c 安装路径(默认 /usr/local/bin/aria2c)
#

set -euo pipefail
GREEN='\033[32m'; RED='\033[31m'; NC='\033[0m'
info() { echo -e "${GREEN}[信息]${NC} $*"; }
err()  { echo -e "${RED}[错误]${NC} $*" >&2; }


ARIA2_CONF_DIR="${ARIA2_CONF_DIR:-/root/.aria2}"
DOWNLOAD_PATH="${DOWNLOAD_PATH:-/root/downloads}"
ARIA2C="${ARIA2C:-/usr/local/bin/aria2c}"
FALLBACK_VER="1.37.0"
INSTALL_SRC="${INSTALL_SRC:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)          INSTALL_SRC="$2"; shift 2 ;;
        --conf-dir)     ARIA2_CONF_DIR="$2"; shift 2 ;;
        --downloads)    DOWNLOAD_PATH="$2"; shift 2 ;;
        --aria2c)       ARIA2C="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

# 解析脚本真实路径(兼容软链与从别处调用), 否则 conf/ 与 hooks/ 会找不到。
# 显式 --src / INSTALL_SRC 优先。
if [[ -z "${INSTALL_SRC}" ]]; then
_src="${BASH_SOURCE[0]}"
while [[ -L "${_src}" ]]; do
    _dir="$(cd "$(dirname "${_src}")" && pwd)"
    _src="$(readlink "${_src}")"
    [[ "${_src}" != /* ]] && _src="${_dir}/${_src}"
done
INSTALL_SRC="$(cd "$(dirname "${_src}")" && pwd)"
unset _src _dir
fi

# 校验项目完整性,  Fail fast 而不是在 install 时才报 "cannot stat"
if [[ ! -d "${INSTALL_SRC}/conf" || ! -d "${INSTALL_SRC}/hooks" ]]; then
    err "未在 ${INSTALL_SRC} 找到 conf/ 与 hooks/ 目录。"
    err "请从 aria2-pro 项目根目录运行 install.sh, 或用 --src 指定源目录。"
    exit 1
fi
[[ $EUID -eq 0 ]] || { err "请以 root 运行。"; exit 1; }

# ---- 发行版/架构 ----------------------------------------------------------
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif grep -qs -E -i "debian|ubuntu" /etc/issue 2>/dev/null || grep -qs -E -i "debian|ubuntu" /proc/version 2>/dev/null; then
    release="debian"
else
    release="debian"
fi

ARCH_RAW="$(uname -m)"
case "${ARCH_RAW}" in
    i*86)            MAPPED_ARCH="i686" ;;
    x86_64)          MAPPED_ARCH="x86_64" ;;
    aarch64|arm64)   MAPPED_ARCH="aarch64" ;;
    armv7l|armhf)    MAPPED_ARCH="armv7" ;;
    loongarch64)     MAPPED_ARCH="loongarch64" ;;
    *) err "不支持的 CPU 架构: ${ARCH_RAW}"; exit 1 ;;
esac
info "检测到架构: ${ARCH_RAW} -> ${MAPPED_ARCH}"

command -v dpkg >/dev/null && dpkgARCH=$(dpkg --print-architecture | awk -F- '{ print $NF }')
case "${dpkgARCH:-}" in
    i386)     MAPPED_ARCH="i686" ;;
    amd64)    MAPPED_ARCH="x86_64" ;;
    arm64)    MAPPED_ARCH="aarch64" ;;
    armhf)    MAPPED_ARCH="armv7" ;;
esac

# ---- 安装依赖 -------------------------------------------------------------
info "安装依赖 ..."
if [[ ${release} == "centos" ]]; then
    yum install -y wget curl ca-certificates findutils jq tar gzip unzip || true
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y wget curl ca-certificates findutils jq tar gzip unzip
fi

# ---- aria2 二进制 ---------------------------------------------------------
if [[ -x "${ARIA2C}" ]]; then
    info "检测到已安装: $(${ARIA2C} --version | head -n 1)"
    read -e -p "是否重新安装/更新 aria2 ? [y/N]: " yn
    [[ "${yn}" != [Yy]* ]] && skip_bin=1 || skip_bin=0
else
    skip_bin=0
fi

if [[ ${skip_bin:-0} -eq 0 ]]; then
    info "查询最新版本 ..."
    NEW_VER="$(wget -t2 -T10 -qO- "https://api.github.com/repos/abcfy2/aria2-static-build/releases/latest" \
        | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)"
    [[ -z "${NEW_VER}" || "${NEW_VER}" == "continuous" ]] && NEW_VER="${FALLBACK_VER}"
    info "目标版本: ${NEW_VER}"
    TMP="$(mktemp -d)"
    URL="https://github.com/abcfy2/aria2-static-build/releases/download/${NEW_VER}/aria2-${MAPPED_ARCH}-linux-musl_static.zip"
    info "下载 ${URL}"
    wget -t2 -T20 -qO "${TMP}/a.zip" "${URL}" \
        || curl -fsSL --retry 2 --max-time 90 -o "${TMP}/a.zip" "${URL}"
    [[ -s "${TMP}/a.zip" ]] || { err "aria2 二进制下载失败"; rm -rf "${TMP}"; exit 1; }
    unzip -o -q "${TMP}/a.zip" -d "${TMP}"
    [[ -s "${TMP}/aria2c" ]] || { err "压缩包内未找到 aria2c"; rm -rf "${TMP}"; exit 1; }
    # 覆盖前备份
    [[ -f "${ARIA2C}" ]] && cp -a "${ARIA2C}" "${ARIA2C}.bak.$(date +%Y%m%d%H%M%S)"
    install -m 0755 "${TMP}/aria2c" "${ARIA2C}"
    rm -rf "${TMP}"
    info "已安装: $(${ARIA2C} --version | head -n 1)"
fi

# ---- 配置与钩子 -----------------------------------------------------------
info "部署配置到 ${ARIA2_CONF_DIR}"
mkdir -p "${ARIA2_CONF_DIR}/hooks"

install -m 0644 "${INSTALL_SRC}/conf/aria2.conf" \
                "${INSTALL_SRC}/conf/script.conf" \
                "${INSTALL_SRC}/conf/rclone.env" "${ARIA2_CONF_DIR}/"
install -m 0755 "${INSTALL_SRC}"/hooks/*.sh "${ARIA2_CONF_DIR}/hooks/"
install -m 0644 "${INSTALL_SRC}/hooks/core" "${ARIA2_CONF_DIR}/hooks/core"

# 按用户参数改写配置
sed -i "s@^\(dir=\).*@\1${DOWNLOAD_PATH}@" "${ARIA2_CONF_DIR}/aria2.conf"
sed -i "s@^\(log=\).*@\1${ARIA2_CONF_DIR}/aria2.log@" "${ARIA2_CONF_DIR}/aria2.conf"
sed -i "s@^\(save-session=\).*@\1${ARIA2_CONF_DIR}/aria2.session@" "${ARIA2_CONF_DIR}/aria2.conf"
sed -i "s@^on-download-complete=.*@on-download-complete=${ARIA2_CONF_DIR}/hooks/clean.sh@" "${ARIA2_CONF_DIR}/aria2.conf"
sed -i "s@^on-bt-download-complete=.*@on-bt-download-complete=${ARIA2_CONF_DIR}/hooks/clean.sh@" "${ARIA2_CONF_DIR}/aria2.conf"
sed -i "s@^on-download-stop=.*@on-download-stop=${ARIA2_CONF_DIR}/hooks/delete.sh@" "${ARIA2_CONF_DIR}/aria2.conf"
sed -i "s@^on-download-error=.*@on-download-error=${ARIA2_CONF_DIR}/hooks/delete.sh@" "${ARIA2_CONF_DIR}/aria2.conf"
sed -i "s@^\(dest-dir=\).*@\1${DOWNLOAD_PATH}/completed@" "${ARIA2_CONF_DIR}/script.conf"

# RPC 密钥: 保留已有值, 首次安装则随机生成
if grep -q '^rpc-secret=' "${ARIA2_CONF_DIR}/aria2.conf"; then
    cur="$(grep '^rpc-secret=' "${ARIA2_CONF_DIR}/aria2.conf" | cut -d= -f2)"
    if [[ "${cur}" == "changeme" || -z "${cur}" ]]; then
        sed -i "s@^\(rpc-secret=\).*@\1$(date +%s%N | md5sum | head -c 20)@" "${ARIA2_CONF_DIR}/aria2.conf"
        info "已生成随机 RPC 密钥"
    else
        info "保留现有 RPC 密钥"
    fi
fi

# DHT 数据文件(缺失时才下载)
# dht.dat / dht6.dat 不再预置: 它们是 DHT 路由表的运行时数据, aria2 官方
# 从不分发, 第三方快照来源不可控。aria2 启动后自行填充并保存到该路径。

# tracker 更新工具(独立文件, 不再内嵌 heredoc, 避免两处实现不一致)
install -m 0755 "${INSTALL_SRC}/bin/tracker-update.sh" "${ARIA2_CONF_DIR}/tracker-update.sh"

mkdir -p "${DOWNLOAD_PATH}" "${DOWNLOAD_PATH}/completed"
touch "${ARIA2_CONF_DIR}/aria2.session"

# ---- init.d 服务 ----------------------------------------------------------
# 安装 init.d 并按实际路径改写 CONFIG/LOG/ARIA2C(脚本内默认值是 /root/.aria2,
# 用户用 --conf-dir 指定别处时必须同步, 否则服务会指向不存在的配置)。
install_initd() {
    local src="$1" dst="${INITD_FILE:-/etc/init.d/aria2}"
    if [[ ! -s "${src}" ]]; then
        err "未找到 init.d 脚本: ${src}"
        return 1
    fi
    install -m 0755 "${src}" "${dst}"
    # 按实际安装路径改写这三行(脚本内默认 /root/.aria2)。
    # 整行替换而非 sed 捕获组, 避免路径中的特殊字符干扰。
    sed -i \
        -e "s|^ARIA2C=.*|ARIA2C=\"${ARIA2C}\"|" \
        -e "s|^CONFIG=.*|CONFIG=\"${ARIA2_CONF_DIR}/aria2.conf\"|" \
        -e "s|^LOG=.*|LOG=\"${ARIA2_CONF_DIR}/aria2.log\"|" \
        "${dst}"
    return 0
}

info "安装 systemd/init.d 服务 ..."
UNIT=/etc/systemd/system/aria2.service
# 若已存在 SysV init 脚本(systemd 通过 generator 接管), 继续用 init.d + 热补丁,
# 不要另建 systemd unit, 否则会出现两个相互竞争的服务定义。
HAVE_INITD=0
[[ -x /etc/init.d/aria2 ]] && HAVE_INITD=1

if [[ ${HAVE_INITD} -eq 1 ]]; then
    info "检测到现有 /etc/init.d/aria2, 替换为 aria2-pro 版本(已内置修复)"
    install_initd "${INSTALL_SRC}/service/aria2_debian"
    update-rc.d -f aria2 defaults >/dev/null 2>&1 || true
elif command -v systemctl >/dev/null 2>&1 && [[ -d /etc/systemd/system ]]; then
    cat > "${UNIT}" <<UNIT_EOF
[Unit]
Description=Aria2 Download Manager (aria2-pro)
After=network.target

[Service]
Type=simple
ExecStart=${ARIA2C} --conf-path=${ARIA2_CONF_DIR}/aria2.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT_EOF
    systemctl daemon-reload
    systemctl enable aria2 >/dev/null 2>&1 || true
    info "已安装 systemd 单元: ${UNIT}"
else
    # 无 systemd: 安装项目自带的 init.d 脚本(已内置全部修复)
    install_initd "${INSTALL_SRC}/service/aria2_debian"
    update-rc.d -f aria2 defaults >/dev/null 2>&1 || true
    info "已安装 init.d 脚本"
fi

info ""
info "安装完成！目录结构："
info "  配置/数据: ${ARIA2_CONF_DIR}"
info "  钩子脚本: ${ARIA2_CONF_DIR}/hooks"
info "  下载目录: ${DOWNLOAD_PATH}"
info ""
info "启动:      systemctl start aria2"
info "自启:      systemctl enable aria2"
info "状态:      systemctl status aria2"
info "管理面板:  bash ${INSTALL_SRC}/bin/aria2.sh"
