#!/usr/bin/env bash
#
# aria2-pro — Aria2 一键安装 / 管理脚本
#
# 基于 P3TERX/aria2.sh (v2.7.4, 上游 2020 年后停止维护) 重写。
#
# 主要变化:
#   - 支持 aria2 1.37.0(二进制源改为 abcfy2/aria2-static-build, 上游依赖的
#     P3TERX/Aria2-Pro-Core 自 2021 年起不再发布)
#   - 修正 max-connection-per-server=32 在 aria2 >=1.36 会导致拒绝启动的问题
#   - 移除 aria2 1.37 已删除的 retry-on-400/403/406/unknown
#   - init.d 服务脚本下载后自动打补丁(修僵尸进程误判 / stop 不等待 / start 轮询)
#   - check_pid 不再把僵尸进程误判为"正在运行"
#   - Add_iptables 与 Del_iptables 端口变量不一致导致旧规则删不掉
#   - 依赖新增 unzip
#   - 升级脚本改为只检查并提示手动合并(避免自动覆盖回退所有修复)
#
# System Required: CentOS/Debian/Ubuntu
# Version: 4.0.0
#

sh_ver="4.0.0"
export PATH=~/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/sbin:/bin

# ---- 可配置项(可用环境变量覆盖) -------------------------------------------
ARIA2_CONF_DIR="${ARIA2_CONF_DIR:-/root/.aria2}"
DOWNLOAD_PATH="${DOWNLOAD_PATH:-/root/downloads}"
ARIA2C="${ARIA2C:-/usr/local/bin/aria2c}"
HOOKS_DIR="${ARIA2_CONF_DIR}/hooks"
INITD_FILE="/etc/init.d/aria2"
CRONTAB_FILE="/usr/bin/crontab"
# 已知稳定版(当 GitHub latest 返回 continuous 滚动构建时使用)
ARIA2_FALLBACK_VER="1.37.0"
# 上游(已停止维护), 仅供对比参考
UPSTREAM_URL="https://github.com/P3TERX/aria2.sh"

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Green_background_prefix="\033[42;37m"
Red_background_prefix="\033[41;37m"
Font_color_suffix="\033[0m"
Info="[${Green_font_prefix}信息${Font_color_suffix}]"
Error="[${Red_font_prefix}错误${Font_color_suffix}]"
Tip="[${Green_font_prefix}注意${Font_color_suffix}]"

check_root() {
    if [[ $EUID != 0 ]]; then
        echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。"
        exit 1
    fi
}

# 检查系统
check_sys() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif grep -qs -E -i "debian" /etc/issue; then
        release="debian"
    elif grep -qs -E -i "ubuntu" /etc/issue; then
        release="ubuntu"
    elif grep -qs -E -i "centos|red hat|redhat" /proc/version; then
        release="centos"
    elif grep -qs -E -i "debian" /proc/version; then
        release="debian"
    elif grep -qs -E -i "ubuntu" /proc/version; then
        release="ubuntu"
    fi
    ARCH=$(uname -m)
    command -v dpkg >/dev/null && dpkgARCH=$(dpkg --print-architecture | awk -F- '{ print $NF }')
}

check_installed_status() {
    [[ ! -e ${ARIA2C} ]] && echo -e "${Error} Aria2 没有安装，请检查 !" && exit 1
    [[ ! -e ${ARIA2_CONF_DIR}/aria2.conf ]] && echo -e "${Error} Aria2 配置文件不存在，请检查 !" && [[ $1 != "un" ]] && exit 1
}

check_crontab_installed_status() {
    if [[ ! -e ${CRONTAB_FILE} ]]; then
        echo -e "${Error} Crontab 没有安装，开始安装..."
        if [[ ${release} == "centos" ]]; then
            yum install crond -y
        else
            apt-get install cron -y
        fi
        if [[ ! -e ${CRONTAB_FILE} ]]; then
            echo -e "${Error} Crontab 安装失败，请检查！" && exit 1
        else
            echo -e "${Info} Crontab 安装成功！"
        fi
    fi
}

# 只统计真实运行的 aria2c 进程。
# 上游用 `ps -ef | grep aria2c`, 会把僵尸(Z)进程也算成"正在运行",
# 导致 kill -9 无效、restart 后 init.d 误判而拒绝启动(实测复现)。
check_pid() {
    PID=""
    local p comm
    while read -r p comm; do
        [[ -z "${p}" || -z "${comm}" ]] && continue
        # 排除僵尸
        if [[ -r /proc/${p}/stat ]]; then
            local state
            state=$(awk '{print $3}' /proc/${p}/stat 2>/dev/null)
            [[ "${state}" == "Z" ]] && continue
        fi
        # 确认是 aria2c 本体
        if [[ -r /proc/${p}/cmdline ]] && tr '\0' ' ' </proc/${p}/cmdline 2>/dev/null | grep -q "aria2c"; then
            PID="${PID} ${p}"
        fi
    done < <(ps -eo pid,comm | awk -v n="aria2c" '$2==n {print $1" "$2}')
    PID="${PID# }"
    [[ -z ${PID} ]] && return 1
    return 0
}

# aria2-pro 的 aria2.conf 钩子路径为 /root/.aria2/hooks/..., 与上游
# /root/.aria2/ 不同, 因此安装目录换成 /root/.aria2 以保持一致。
check_new_ver() {
    aria2_new_ver=$(
        {
            wget -t2 -T10 -qO- "https://api.github.com/repos/abcfy2/aria2-static-build/releases/latest" ||
                wget -t2 -T10 -qO- "https://gh-api.p3terx.com/repos/abcfy2/aria2-static-build/releases/latest"
        } | grep -o '"tag_name": *"[^"]*"' | head -n 1 | cut -d'"' -f4
    )
    # 'continuous' 是滚动构建, 无对应版本号, 回退到已知稳定版
    [[ -z ${aria2_new_ver} || ${aria2_new_ver} == "continuous" ]] && aria2_new_ver="${ARIA2_FALLBACK_VER}"
    if [[ -z ${aria2_new_ver} ]]; then
        echo -e "${Error} Aria2 最新版本获取失败，请手动获取最新版本号[ https://github.com/abcfy2/aria2-static-build/releases ]"
        read -e -p "请输入版本号:" aria2_new_ver
        [[ -z "${aria2_new_ver}" ]] && echo "取消..." && exit 1
    fi
}

check_ver_comparison() {
    read -e -p "是否更新(会中断当前下载任务) ? [Y/n] :" yn
    [[ -z "${yn}" ]] && yn="y"
    if [[ ${yn} == [Yy] ]]; then
        check_pid
        [[ ! -z ${PID} ]] && kill -9 ${PID}
        check_sys
        Download_aria2 "update"
        Start_aria2
    fi
}

map_arch() {
    # 与 abcfy2/aria2-static-build 的资产命名保持一致
    if [[ $ARCH == i*86 || $dpkgARCH == i*86 ]]; then
        MAPPED_ARCH="i686"
    elif [[ $ARCH == "x86_64" || $dpkgARCH == "amd64" ]]; then
        MAPPED_ARCH="x86_64"
    elif [[ $ARCH == "aarch64" || $dpkgARCH == "arm64" ]]; then
        MAPPED_ARCH="aarch64"
    elif [[ $ARCH == "armv7l" || $dpkgARCH == "armhf" ]]; then
        MAPPED_ARCH="armv7"
    elif [[ $ARCH == "loongarch64" ]]; then
        MAPPED_ARCH="loongarch64"
    else
        echo -e "${Error} 不支持此 CPU 架构。"
        exit 1
    fi
}

Download_aria2() {
    update_dl=$1
    check_sys
    map_arch
    while command -v aria2c >/dev/null 2>&1; do
        echo -e "${Info} 删除旧版 Aria2 二进制文件..."
        rm -vf "$(command -v aria2c)"
    done
    CREATE_TMP=$(mktemp -d)
    DOWNLOAD_URL="https://github.com/abcfy2/aria2-static-build/releases/download/${aria2_new_ver}/aria2-${MAPPED_ARCH}-linux-musl_static.zip"
    {
        wget -t2 -T10 -qO "${CREATE_TMP}/aria2.zip" "${DOWNLOAD_URL}" ||
            wget -t2 -T10 -qO "${CREATE_TMP}/aria2.zip" "https://gh-acc.p3terx.com/${DOWNLOAD_URL}"
    }
    if [[ ! -s "${CREATE_TMP}/aria2.zip" ]]; then
        rm -rf "${CREATE_TMP}"
        echo -e "${Error} Aria2 下载失败 !"
        exit 1
    fi
    unzip -o -q "${CREATE_TMP}/aria2.zip" -d "${CREATE_TMP}"
    if [[ ! -s "${CREATE_TMP}/aria2c" ]]; then
        rm -rf "${CREATE_TMP}"
        echo -e "${Error} Aria2 压缩包内未找到 aria2c，可能该架构暂无构建。"
        exit 1
    fi
    [[ ${update_dl} = "update" ]] && rm -f "${ARIA2C}"
    mv -f "${CREATE_TMP}/aria2c" "${ARIA2C}"
    rm -rf "${CREATE_TMP}"
    [[ ! -e ${ARIA2C} ]] && echo -e "${Error} Aria2 主程序安装失败！" && exit 1
    chmod +x ${ARIA2C}

    # 修正旧配置里 1.37 不再接受的参数, 否则升级后 aria2 直接拒绝启动:
    #   - max-connection-per-server 上限在 >=1.36 收紧为 16 (上游写 32)
    #   - retry-on-400/403/406/unknown 在 1.37 已删除
    if [[ -e ${ARIA2_CONF_DIR}/aria2.conf ]]; then
        cp -f "${ARIA2_CONF_DIR}/aria2.conf" "${ARIA2_CONF_DIR}/aria2.conf.bak.$(date +%Y%m%d%H%M%S)"
        sed -i 's/^\(max-connection-per-server=\).*/\116/' "${ARIA2_CONF_DIR}/aria2.conf"
        sed -i '/^retry-on-400=/d;/^retry-on-403=/d;/^retry-on-406=/d;/^retry-on-unknown=/d' "${ARIA2_CONF_DIR}/aria2.conf"
    fi
    echo -e "${Info} Aria2 主程序安装完成！$(${ARIA2C} --version | head -n 1)"
}

Download_aria2_conf() {
    PROFILE_LIST="aria2.conf script.conf rclone.env core upload.sh move.sh delete.sh clean.sh dht.dat dht6.dat LICENSE"
    mkdir -p "${ARIA2_CONF_DIR}" "${HOOKS_DIR}"
    local src="${ARIA2_PRO_SRC:-}"
    if [[ -z "${src}" ]]; then
        # 未指定源时, 用当前脚本所在目录的 conf/hooks(本地安装)
        src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [[ ! -d "${src}/conf" || ! -d "${src}/hooks" ]]; then
        echo -e "${Error} 找不到 aria2-pro 源目录(需要 conf/ 与 hooks/): ${src}"
        exit 1
    fi
    cp -f "${src}/conf/aria2.conf" "${src}/conf/script.conf" "${src}/conf/rclone.env" "${ARIA2_CONF_DIR}/"
    cp -f "${src}/hooks/"* "${HOOKS_DIR}/"
    chmod +x "${HOOKS_DIR}/"*.sh
    sed -i "s@^\(dir=\).*@\1${DOWNLOAD_PATH}@" "${ARIA2_CONF_DIR}/aria2.conf"
    sed -i "s@^\(log=\).*@\1${ARIA2_CONF_DIR}/aria2.log@" "${ARIA2_CONF_DIR}/aria2.conf"
    sed -i "s@^\(save-session=\).*@\1${ARIA2_CONF_DIR}/aria2.session@" "${ARIA2_CONF_DIR}/aria2.conf"
    sed -i "s@^on-download-complete=.*@on-download-complete=${HOOKS_DIR}/clean.sh@" "${ARIA2_CONF_DIR}/aria2.conf"
    sed -i "s@^on-bt-download-complete=.*@on-bt-download-complete=${HOOKS_DIR}/clean.sh@" "${ARIA2_CONF_DIR}/aria2.conf"
    sed -i "s@^on-download-stop=.*@on-download-stop=${HOOKS_DIR}/delete.sh@" "${ARIA2_CONF_DIR}/aria2.conf"
    sed -i "s@^on-download-error=.*@on-download-error=${HOOKS_DIR}/delete.sh@" "${ARIA2_CONF_DIR}/aria2.conf"
    sed -i "s@^\(rpc-secret=\).*@\1$(date +%s%N | md5sum | head -c 20)@" "${ARIA2_CONF_DIR}/aria2.conf"
    sed -i "s@^\(dest-dir=\).*@\1${DOWNLOAD_PATH}/completed@" "${ARIA2_CONF_DIR}/script.conf"
    if [[ ! -e "${ARIA2_CONF_DIR}/dht.dat" ]]; then
        wget -N -t2 -T10 -q "https://raw.githubusercontent.com/P3TERX/aria2.conf/master/dht.dat" -O "${ARIA2_CONF_DIR}/dht.dat"
        wget -N -t2 -T10 -q "https://raw.githubusercontent.com/P3TERX/aria2.conf/master/dht6.dat" -O "${ARIA2_CONF_DIR}/dht6.dat"
    fi
    touch "${ARIA2_CONF_DIR}/aria2.session"
    echo -e "${Info} Aria2 配置文件安装完成！"
}

# 上游 service/aria2_debian 自 2020 年后未更新, 存在三个缺陷, 下载后就地热修。
Patch_initd() {
    # 优先使用随项目发布的 service/patch_initd.py; 找不到时降级为跳过
    # (不再内嵌一份, 避免两处逻辑不一致)。
    local patcher
    patcher="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/service/patch_initd.py"
    [[ -s "${patcher}" ]] || return 1
    python3 "${patcher}" "${INITD_FILE}"
}

Service_aria2() {
    if [[ ${release} = "centos" ]]; then
        wget -N -t2 -T10 "https://raw.githubusercontent.com/P3TERX/aria2.sh/master/service/aria2_centos" -O "${INITD_FILE}" ||
            wget -N -t2 -T10 "https://cdn.jsdelivr.net/gh/P3TERX/aria2.sh@master/service/aria2_centos" -O "${INITD_FILE}" ||
            wget -N -t2 -T10 "https://gh-raw.p3terx.com/P3TERX/aria2.sh/master/service/aria2_centos" -O "${INITD_FILE}"
        SVC_REGISTER="chkconfig --add aria2 && chkconfig aria2 on"
    else
        wget -N -t2 -T10 "https://raw.githubusercontent.com/P3TERX/aria2.sh/master/service/aria2_debian" -O "${INITD_FILE}" ||
            wget -N -t2 -T10 "https://cdn.jsdelivr.net/gh/P3TERX/aria2.sh@master/service/aria2_debian" -O "${INITD_FILE}" ||
            wget -N -t2 -T10 "https://gh-raw.p3terx.com/P3TERX/aria2.sh/master/service/aria2_debian" -O "${INITD_FILE}"
        SVC_REGISTER="update-rc.d -f aria2 defaults"
    fi
    [[ ! -s "${INITD_FILE}" ]] && {
        echo -e "${Error} Aria2服务 管理脚本下载失败 !"
        exit 1
    }
    chmod +x "${INITD_FILE}"
    if command -v python3 >/dev/null 2>&1; then
        Patch_initd || echo -e "${Tip} init.d 热补丁未应用(结构已变化), 启动/停止功能不受影响。"
    fi
    eval ${SVC_REGISTER}
    echo -e "${Info} Aria2服务 管理脚本下载完成 !"
}

Installation_dependency() {
    if [[ ${release} = "centos" ]]; then
        yum update -y
        yum install -y wget curl nano ca-certificates findutils jq tar gzip unzip dpkg
    else
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl nano ca-certificates findutils jq tar gzip unzip dpkg
    fi
    # python3 仅用于 init.d 热补丁; 缺失时降级为不修补, 不影响主流程
    if ! command -v python3 >/dev/null 2>&1; then
        if [[ ${release} = "centos" ]]; then
            yum install -y python3 || true
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y python3 || true
        fi
    fi
    if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
        wget -qO- git.io/ca-certificates.sh | bash
    fi
}

Install_aria2() {
    check_root
    [[ -e ${ARIA2C} ]] && echo -e "${Error} Aria2 已安装，请检查 !" && exit 1
    check_sys
    echo -e "${Info} 开始安装/配置 依赖..."
    Installation_dependency
    echo -e "${Info} 开始下载/安装 主程序..."
    check_new_ver
    Download_aria2
    echo -e "${Info} 开始下载/安装 配置文件..."
    Download_aria2_conf
    echo -e "${Info} 开始下载/安装 服务脚本(init)..."
    Service_aria2
    Read_config
    aria2_RPC_port=${aria2_port}
    Set_iptables
    Add_iptables
    Save_iptables
    echo -e "${Info} 开始创建 下载目录..."
    mkdir -p "${DOWNLOAD_PATH}"
    echo -e "${Info} 所有步骤 安装完毕，开始启动..."
    Start_aria2
}

Start_aria2() {
    check_installed_status
    check_pid
    [[ ! -z ${PID} ]] && echo -e "${Error} Aria2 正在运行，请检查 !" && exit 1
    ${INITD_FILE} start
}

Stop_aria2() {
    check_installed_status
    check_pid
    [[ -z ${PID} ]] && echo -e "${Error} Aria2 没有运行，请检查 !" && exit 1
    ${INITD_FILE} stop
}

Restart_aria2() {
    check_installed_status
    check_pid
    [[ ! -z ${PID} ]] && ${INITD_FILE} stop
    ${INITD_FILE} start
}

Set_aria2() {
    check_installed_status
    echo -e "
${Green_font_prefix}1.${Font_color_suffix} 修改 Aria2 RPC 密钥
${Green_font_prefix}2.${Font_color_suffix} 修改 Aria2 RPC 端口
${Green_font_prefix}3.${Font_color_suffix} 修改 Aria2 下载目录
${Green_font_prefix}4.${Font_color_suffix} 修改 Aria2 密钥 + 端口 + 下载目录
${Green_font_prefix}5.${Font_color_suffix} 手动 打开配置文件修改
————————————
${Green_font_prefix}0.${Font_color_suffix} 重置/更新 Aria2 配置文件
"
    read -e -p " 请输入数字 [0-5]:" aria2_modify
    if [[ ${aria2_modify} == "1" ]]; then
        Set_aria2_RPC_passwd
    elif [[ ${aria2_modify} == "2" ]]; then
        Set_aria2_RPC_port
    elif [[ ${aria2_modify} == "3" ]]; then
        Set_aria2_RPC_dir
    elif [[ ${aria2_modify} == "4" ]]; then
        Set_aria2_RPC_passwd_port_dir
    elif [[ ${aria2_modify} == "5" ]]; then
        Set_aria2_vim_conf
    elif [[ ${aria2_modify} == "0" ]]; then
        Reset_aria2_conf
    else
        echo
        echo -e " ${Error} 请输入正确的数字"
        exit 1
    fi
}

Set_aria2_RPC_passwd() {
    read_123=$1
    if [[ ${read_123} != "1" ]]; then
        Read_config
    fi
    if [[ -z "${aria2_passwd}" ]]; then
        aria2_passwd_1="空(没有检测到配置，可能手动删除或注释了)"
    else
        aria2_passwd_1=${aria2_passwd}
    fi
    echo -e "
${Tip} Aria2 RPC 密钥不要包含等号(=)和井号(#)，留空为随机生成。

 当前 RPC 密钥为: ${Green_font_prefix}${aria2_passwd_1}${Font_color_suffix}
"
    read -e -p " 请输入新的 RPC 密钥: " aria2_RPC_passwd
    echo
    [[ -z "${aria2_RPC_passwd}" ]] && aria2_RPC_passwd=$(date +%s%N | md5sum | head -c 20)
    if [[ "${aria2_passwd}" != "${aria2_RPC_passwd}" ]]; then
        if [[ -z "${aria2_passwd}" ]]; then
            echo -e "\nrpc-secret=${aria2_RPC_passwd}" >>"${ARIA2_CONF_DIR}/aria2.conf"
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} RPC 密钥修改成功！新密钥为：${Green_font_prefix}${aria2_RPC_passwd}${Font_color_suffix}(配置文件中缺少相关选项参数，已自动加入配置文件底部)"
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} RPC 密钥修改失败！旧密钥为：${Green_font_prefix}${aria2_passwd}${Font_color_suffix}"
            fi
        else
            # 用固定字符串匹配, 避免密钥中的正则元字符导致 sed 匹配失败
            awk -v old="${aria2_passwd}" -v new="${aria2_RPC_passwd}" \
                'BEGIN{FS=OFS="="} $1=="rpc-secret"{$2=new; print; next} {print}' \
                "${ARIA2_CONF_DIR}/aria2.conf" >"${ARIA2_CONF_DIR}/aria2.conf.tmp" &&
                mv -f "${ARIA2_CONF_DIR}/aria2.conf.tmp" "${ARIA2_CONF_DIR}/aria2.conf"
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} RPC 密钥修改成功！新密钥为：${Green_font_prefix}${aria2_RPC_passwd}${Font_color_suffix}"
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} RPC 密钥修改失败！旧密钥为：${Green_font_prefix}${aria2_passwd}${Font_color_suffix}"
            fi
        fi
    else
        echo -e "${Error} 与旧配置一致，无需修改..."
    fi
}

Set_aria2_RPC_port() {
    read_123=$1
    if [[ ${read_123} != "1" ]]; then
        Read_config
    fi
    if [[ -z "${aria2_port}" ]]; then
        aria2_port_1="空(没有检测到配置，可能手动删除或注释了)"
    else
        aria2_port_1=${aria2_port}
    fi
    echo -e "
 当前 RPC 端口为: ${Green_font_prefix}${aria2_port_1}${Font_color_suffix}
"
    read -e -p " 请输入新的 RPC 端口(默认: 6800): " aria2_RPC_port
    echo
    [[ -z "${aria2_RPC_port}" ]] && aria2_RPC_port="6800"
    if [[ ! "${aria2_RPC_port}" =~ ^[0-9]+$ ]]; then
        echo -e "${Error} 端口必须是数字，取消操作。"
        exit 1
    fi
    if [[ "${aria2_port}" != "${aria2_RPC_port}" ]]; then
        if [[ -z "${aria2_port}" ]]; then
            echo -e "\nrpc-listen-port=${aria2_RPC_port}" >>"${ARIA2_CONF_DIR}/aria2.conf"
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} RPC 端口修改成功！新端口为：${Green_font_prefix}${aria2_RPC_port}${Font_color_suffix}(配置文件中缺少相关选项参数，已自动加入配置文件底部)"
                Del_iptables
                Add_iptables
                Save_iptables
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} RPC 端口修改失败！旧端口为：${Green_font_prefix}${aria2_port}${Font_color_suffix}"
            fi
        else
            awk -v new="${aria2_RPC_port}" 'BEGIN{FS=OFS="="} $1=="rpc-listen-port"{$2=new; print; next} {print}' \
                "${ARIA2_CONF_DIR}/aria2.conf" >"${ARIA2_CONF_DIR}/aria2.conf.tmp" &&
                mv -f "${ARIA2_CONF_DIR}/aria2.conf.tmp" "${ARIA2_CONF_DIR}/aria2.conf"
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} RPC 端口修改成功！新端口为：${Green_font_prefix}${aria2_RPC_port}${Font_color_suffix}"
                Del_iptables
                Add_iptables
                Save_iptables
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} RPC 端口修改失败！旧端口为：${Green_font_prefix}${aria2_port}${Font_color_suffix}"
            fi
        fi
    else
        echo -e "${Error} 与旧配置一致，无需修改..."
    fi
}

Set_aria2_RPC_dir() {
    read_123=$1
    if [[ ${read_123} != "1" ]]; then
        Read_config
    fi
    if [[ -z "${aria2_dir}" ]]; then
        aria2_dir_1="空(没有检测到配置，可能手动删除或注释了)"
    else
        aria2_dir_1=${aria2_dir}
    fi
    echo -e "
 当前下载目录为: ${Green_font_prefix}${aria2_dir_1}${Font_color_suffix}
"
    read -e -p " 请输入新的下载目录(默认: ${DOWNLOAD_PATH}): " aria2_RPC_dir
    [[ -z "${aria2_RPC_dir}" ]] && aria2_RPC_dir="${DOWNLOAD_PATH}"
    mkdir -p "${aria2_RPC_dir}"
    echo
    if [[ "${aria2_dir}" != "${aria2_RPC_dir}" ]]; then
        if [[ -z "${aria2_dir}" ]]; then
            echo -e "\ndir=${aria2_RPC_dir}" >>"${ARIA2_CONF_DIR}/aria2.conf"
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} 下载目录修改成功！新位置为：${Green_font_prefix}${aria2_RPC_dir}${Font_color_suffix}(配置文件中缺少相关选项参数，已自动加入配置文件底部)"
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} 下载目录修改失败！旧位置为：${Green_font_prefix}${aria2_dir}${Font_color_suffix}"
            fi
        else
            awk -v new="${aria2_RPC_dir}" 'BEGIN{FS=OFS="="} $1=="dir"{$2=new; print; next} {print}' \
                "${ARIA2_CONF_DIR}/aria2.conf" >"${ARIA2_CONF_DIR}/aria2.conf.tmp" &&
                mv -f "${ARIA2_CONF_DIR}/aria2.conf.tmp" "${ARIA2_CONF_DIR}/aria2.conf"
            if [[ $? -eq 0 ]]; then
                echo -e "${Info} 下载目录修改成功！新位置为：${Green_font_prefix}${aria2_RPC_dir}${Font_color_suffix}"
                if [[ ${read_123} != "1" ]]; then
                    Restart_aria2
                fi
            else
                echo -e "${Error} 下载目录修改失败！旧位置为：${Green_font_prefix}${aria2_dir}${Font_color_suffix}"
            fi
        fi
    else
        echo -e "${Error} 与旧配置一致，无需修改..."
    fi
}

Set_aria2_RPC_passwd_port_dir() {
    Read_config
    Set_aria2_RPC_passwd "1"
    Set_aria2_RPC_port "1"
    Set_aria2_RPC_dir "1"
    Restart_aria2
}

Set_aria2_vim_conf() {
    Read_config
    aria2_port_old=${aria2_port}
    aria2_dir_old=${aria2_dir}
    echo -e "
 配置文件位置：${Green_font_prefix}${ARIA2_CONF_DIR}/aria2.conf${Font_color_suffix}

${Tip} 手动修改配置文件须知：

 ${Green_font_prefix}1.${Font_color_suffix} 默认使用 nano 文本编辑器打开
 ${Green_font_prefix}2.${Font_color_suffix} 退出并保存文件：按 ${Green_font_prefix}Ctrl+X${Font_color_suffix} 组合键，输入 ${Green_font_prefix}y${Font_color_suffix} ，按 ${Green_font_prefix}Enter${Font_color_suffix} 键
 ${Green_font_prefix}3.${Font_color_suffix} 退出不保存文件：按 ${Green_font_prefix}Ctrl+X${Font_color_suffix} 组合键，输入 ${Green_font_prefix}n${Font_color_suffix}
 ${Green_font_prefix}4.${Font_color_suffix} nano 详细使用教程：${Green_font_prefix}https://p3terx.com/archives/linux-nano-tutorial.html${Font_color_suffix}
 ${Green_font_prefix}5.${Font_color_suffix} 配置文件有中文注释，若语言设置有问题会导致中文乱码
"
    read -e -p "按任意键继续，按 Ctrl+C 组合键取消" var
    nano "${ARIA2_CONF_DIR}/aria2.conf"
    Read_config
    if [[ "${aria2_port_old}" != "${aria2_port}" ]]; then
        aria2_RPC_port=${aria2_port}
        aria2_port=${aria2_port_old}
        Del_iptables
        Add_iptables
        Save_iptables
    fi
    if [[ "${aria2_dir_old}" != "${aria2_dir}" ]]; then
        mkdir -p ${aria2_dir}
    fi
    Restart_aria2
}

Reset_aria2_conf() {
    Read_config
    aria2_port_old=${aria2_port}
    echo
    echo -e "${Tip} 此操作将重新下载 Aria2 配置文件，所有已设定的配置将丢失。"
    echo
    read -e -p "按任意键继续，按 Ctrl+C 组合键取消" var
    Download_aria2_conf
    Read_config
    if [[ "${aria2_port_old}" != "${aria2_port}" ]]; then
        aria2_RPC_port=${aria2_port}
        aria2_port=${aria2_port_old}
        Del_iptables
        Add_iptables
        Save_iptables
    fi
    Restart_aria2
}

Read_config() {
    status_type=$1
    if [[ ! -e ${ARIA2_CONF_DIR}/aria2.conf ]]; then
        if [[ ${status_type} != "un" ]]; then
            echo -e "${Error} Aria2 配置文件不存在 !" && exit 1
        fi
    else
        conf_text=$(grep -v '^#' "${ARIA2_CONF_DIR}/aria2.conf")
        aria2_dir=$(grep "^dir=" <<<"${conf_text}" | awk -F "=" '{print $NF}')
        aria2_port=$(grep "^rpc-listen-port=" <<<"${conf_text}" | awk -F "=" '{print $NF}')
        aria2_passwd=$(grep "^rpc-secret=" <<<"${conf_text}" | awk -F "=" '{print $NF}')
        aria2_bt_port=$(grep "^listen-port=" <<<"${conf_text}" | awk -F "=" '{print $NF}')
        aria2_dht_port=$(grep "^dht-listen-port=" <<<"${conf_text}" | awk -F "=" '{print $NF}')
    fi
}

View_Aria2() {
    check_installed_status
    Read_config
    IPV4=$(
        wget -qO- -t1 -T2 -4 api.ip.sb/ip ||
            wget -qO- -t1 -T2 -4 ifconfig.io/ip ||
            wget -qO- -t1 -T2 -4 www.trackip.net/ip
    )
    IPV6=$(
        wget -qO- -t1 -T2 -6 api.ip.sb/ip ||
            wget -qO- -t1 -T2 -6 ifconfig.io/ip ||
            wget -qO- -t1 -T2 -6 www.trackip.net/ip
    )
    [[ -z "${IPV4}" ]] && IPV4="IPv4 地址检测失败"
    [[ -z "${IPV6}" ]] && IPV6="IPv6 地址检测失败"
    [[ -z "${aria2_dir}" ]] && aria2_dir="找不到配置参数"
    [[ -z "${aria2_port}" ]] && aria2_port="找不到配置参数"
    [[ -z "${aria2_passwd}" ]] && aria2_passwd="找不到配置参数(或无密钥)"
    if [[ -z "${IPV4}" || -z "${aria2_port}" ]]; then
        AriaNg_URL="null"
    else
        AriaNg_API="/#!/settings/rpc/set/ws/${IPV4}/${aria2_port}/jsonrpc/$(echo -n ${aria2_passwd} | base64)"
        AriaNg_URL="http://ariang.js.org${AriaNg_API}"
    fi
    clear
    echo -e "\nAria2 简单配置信息：\n\n IPv4 地址\t: ${Green_font_prefix}${IPV4}${Font_color_suffix}
 IPv6 地址\t: ${Green_font_prefix}${IPV6}${Font_color_suffix}
 RPC 端口\t: ${Green_font_prefix}${aria2_port}${Font_color_suffix}
 RPC 密钥\t: ${Green_font_prefix}${aria2_passwd}${Font_color_suffix}
 下载目录\t: ${Green_font_prefix}${aria2_dir}${Font_color_suffix}
 AriaNg 链接\t: ${Green_font_prefix}${AriaNg_URL}${Font_color_suffix}\n"
}

View_Log() {
    [[ ! -e ${ARIA2_CONF_DIR}/aria2.log ]] && echo -e "${Error} Aria2 日志文件不存在 !" && exit 1
    echo && echo -e "${Tip} 按 ${Red_font_prefix}Ctrl+C${Font_color_suffix} 终止查看日志" && echo -e "如果需要查看完整日志内容，请用 ${Red_font_prefix}cat ${ARIA2_CONF_DIR}/aria2.log${Font_color_suffix} 命令。" && echo
    tail -f "${ARIA2_CONF_DIR}/aria2.log"
}

Clean_Log() {
    [[ ! -e ${ARIA2_CONF_DIR}/aria2.log ]] && echo -e "${Error} Aria2 日志文件不存在 !" && exit 1
    : >"${ARIA2_CONF_DIR}/aria2.log"
    echo -e "${Info} Aria2 日志已清空 !"
}

crontab_update_status() {
    crontab -l 2>/dev/null | grep "# aria2-pro:tracker-update"
}

Update_bt_tracker_cron() {
    check_installed_status
    check_crontab_installed_status
    if [[ -z $(crontab_update_status) ]]; then
        echo
        echo -e " 是否开启 ${Green_font_prefix}自动更新 BT-Tracker${Font_color_suffix} 功能？(可能会增强 BT 下载速率)[Y/n] \c"
        read -e crontab_update_status_ny
        [[ -z "${crontab_update_status_ny}" ]] && crontab_update_status_ny="y"
        if [[ ${crontab_update_status_ny} == [Yy] ]]; then
            crontab_update_start
        else
            echo && echo " 已取消..."
        fi
    else
        echo
        echo -e " 是否关闭 ${Red_font_prefix}自动更新 BT-Tracker${Font_color_suffix} 功能？[y/N] \c"
        read -e crontab_update_status_ny
        [[ -z "${crontab_update_status_ny}" ]] && crontab_update_status_ny="n"
        if [[ ${crontab_update_status_ny} == [Yy] ]]; then
            crontab_update_stop
        else
            echo && echo " 已取消..."
        fi
    fi
}

crontab_update_start() {
    crontab -l >"/tmp/crontab.bak" 2>/dev/null
    # 只删本脚本写入的行(带 aria2-pro 标记), 避免误删用户其他含
    # "tracker-update.sh" 字样的 crontab 条目
    sed -i "/# aria2-pro:tracker-update/d" "/tmp/crontab.bak"
    echo -e "\n0 7 * * * /bin/bash ${ARIA2_CONF_DIR}/tracker-update.sh 2>&1 | tee ${ARIA2_CONF_DIR}/tracker.log # aria2-pro:tracker-update" >>"/tmp/crontab.bak"
    crontab "/tmp/crontab.bak"
    rm -f "/tmp/crontab.bak"
    if [[ -z $(crontab_update_status) ]]; then
        echo && echo -e "${Error} 自动更新 BT-Tracker 开启失败 !" && exit 1
    else
        Update_bt_tracker
        echo && echo -e "${Info} 自动更新 BT-Tracker 开启成功 !"
    fi
}

crontab_update_stop() {
    crontab -l >"/tmp/crontab.bak" 2>/dev/null
    sed -i "/# aria2-pro:tracker-update/d" "/tmp/crontab.bak"
    crontab "/tmp/crontab.bak"
    rm -f "/tmp/crontab.bak"
    if [[ -n $(crontab_update_status) ]]; then
        echo && echo -e "${Error} 自动更新 BT-Tracker 关闭失败 !" && exit 1
    else
        echo && echo -e "${Info} 自动更新 BT-Tracker 关闭成功 !"
    fi
}

Update_bt_tracker() {
    check_installed_status
    # tracker-update.sh 由 install.sh 安装, 是唯一实现(不再从 P3TERX 下载旧脚本)。
    # 缺失时尝试从本项目的 bin/ 目录复制, 避免降级到已过时的上游版本。
    local script="${ARIA2_CONF_DIR}/tracker-update.sh"
    local src
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/tracker-update.sh"
    if [[ ! -s "${script}" ]]; then
        if [[ -s "${src}" ]]; then
            install -m 0755 "${src}" "${script}"
        else
            echo -e "${Error} tracker-update.sh 不存在: ${script}"
            echo -e "${Tip} 请从 aria2-pro 项目 bin/ 目录复制, 或重新运行 install.sh。"
            exit 1
        fi
    fi
    check_pid
    if [[ -z ${PID} ]]; then
        bash "${script}" "${ARIA2_CONF_DIR}/aria2.conf"
    else
        bash "${script}" "${ARIA2_CONF_DIR}/aria2.conf" RPC
    fi
}

Update_aria2() {
    check_installed_status
    check_new_ver
    check_ver_comparison
}

Uninstall_aria2() {
    check_installed_status "un"
    echo "确定要卸载 Aria2 ? (y/N)"
    echo
    read -e -p "(默认: n):" unyn
    [[ -z ${unyn} ]] && unyn="n"
    if [[ ${unyn} == [Yy] ]]; then
        crontab -l >"/tmp/crontab.bak" 2>/dev/null
        sed -i "/# aria2-pro:tracker-update/d" "/tmp/crontab.bak"
        crontab "/tmp/crontab.bak"
        rm -f "/tmp/crontab.bak"
        check_pid
        [[ ! -z ${PID} ]] && kill -9 ${PID}
        Read_config "un"
        Del_iptables
        Save_iptables
        rm -rf "${ARIA2C}"
        rm -rf "${ARIA2_CONF_DIR}"
        if [[ ${release} = "centos" ]]; then
            chkconfig --del aria2
        else
            update-rc.d -f aria2 remove
        fi
        rm -rf "${INITD_FILE}"
        systemctl daemon-reload 2>/dev/null
        echo && echo "Aria2 卸载完成 !" && echo
    else
        echo && echo "卸载已取消..." && echo
    fi
}

# 原版 Add_iptables 用 ${aria2_RPC_port} 而 Del_iptables 用 ${aria2_port},
# 两者在不同调用路径下不一致, 导致改端口后旧放行规则永远删不掉。
Add_iptables() {
    iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport ${aria2_RPC_port} -j ACCEPT
    iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport ${aria2_bt_port} -j ACCEPT
    iptables -I INPUT -m state --state NEW -m udp -p udp --dport ${aria2_dht_port} -j ACCEPT
}

Del_iptables() {
    local del_port=${aria2_port:-${aria2_RPC_port}}
    iptables -D INPUT -m state --state NEW -m tcp -p tcp --dport ${del_port} -j ACCEPT 2>/dev/null
    iptables -D INPUT -m state --state NEW -m tcp -p tcp --dport ${aria2_bt_port} -j ACCEPT 2>/dev/null
    iptables -D INPUT -m state --state NEW -m udp -p udp --dport ${aria2_dht_port} -j ACCEPT 2>/dev/null
}

Save_iptables() {
    if [[ ${release} == "centos" ]]; then
        service iptables save
    else
        iptables-save >/etc/iptables.up.rules
    fi
}

Set_iptables() {
    # Oracle/容器环境常无 iptables 或无权限, 原版遇错即中断安装。
    if ! command -v iptables >/dev/null 2>&1; then
        echo -e "${Tip} 未检测到 iptables, 跳过防火墙配置。"
        return 0
    fi
    if [[ ${release} == "centos" ]]; then
        service iptables save
        chkconfig --level 2345 iptables on
    else
        iptables-save >/etc/iptables.up.rules 2>/dev/null
        echo -e '#!/bin/bash\n/sbin/iptables-restore < /etc/iptables.up.rules' >/etc/network/if-pre-up.d/iptables
        chmod +x /etc/network/if-pre-up.d/iptables
    fi
}

# 只检查更新并提示手动合并。
# 上游 P3TERX/aria2.sh 自 2020 年(v2.7.4)起停止维护, 自动拉取覆盖会抹掉
# 本版本对 aria2 1.37 的支持与全部修复。
Update_Shell() {
    sh_new_ver=$(wget -qO- -t1 -T10 "https://raw.githubusercontent.com/P3TERX/aria2.sh/master/aria2.sh" 2>/dev/null | grep 'sh_ver="' | awk -F "=" '{print $NF}' | sed 's/"//g' | head -1)
    if [[ -z ${sh_new_ver} ]]; then
        echo -e "${Error} 无法链接到 Github，检查更新失败 !" && exit 0
    fi
    if [[ "${sh_new_ver}" == "${sh_ver}" ]]; then
        echo -e "${Info} 当前已是最新版本[ ${sh_ver} ]。"
        exit 0
    fi
    echo -e "${Info} 检测到上游版本[ ${sh_new_ver} ]，当前版本[ ${sh_ver} ]。"
    echo -e "${Tip} 上游长期未维护, 自动覆盖会丢失 aria2 1.37 支持与全部修复。"
    echo -e "${Tip} 请访问 ${UPSTREAM_URL} 手动比对差异。"
    exit 0
}

echo && echo -e " Aria2 一键安装管理脚本 ${Red_font_prefix}增强版${Font_color_suffix} ${Red_font_prefix}[v${sh_ver}]${Font_color_suffix} by \033[1;35mP3TERX.COM\033[0m

 ${Green_font_prefix} 0.${Font_color_suffix} 升级脚本
———————————————————————
 ${Green_font_prefix} 1.${Font_color_suffix} 安装 Aria2
 ${Green_font_prefix} 2.${Font_color_suffix} 更新 Aria2
 ${Green_font_prefix} 3.${Font_color_suffix} 卸载 Aria2
———————————————————————
 ${Green_font_prefix} 4.${Font_color_suffix} 启动 Aria2
 ${Green_font_prefix} 5.${Font_color_suffix} 停止 Aria2
 ${Green_font_prefix} 6.${Font_color_suffix} 重启 Aria2
———————————————————————
 ${Green_font_prefix} 7.${Font_color_suffix} 修改 配置
 ${Green_font_prefix} 8.${Font_color_suffix} 查看 配置
 ${Green_font_prefix} 9.${Font_color_suffix} 查看 日志
 ${Green_font_prefix}10.${Font_color_suffix} 清空 日志
———————————————————————
 ${Green_font_prefix}11.${Font_color_suffix} 手动更新 BT-Tracker
 ${Green_font_prefix}12.${Font_color_suffix} 自动更新 BT-Tracker
———————————————————————" && echo
if [[ -e ${ARIA2C} ]]; then
    check_pid
    if [[ ! -z "${PID}" ]]; then
        echo -e " Aria2 状态: ${Green_font_prefix}已安装${Font_color_suffix} | ${Green_font_prefix}已启动${Font_color_suffix}  $(${ARIA2C} --version 2>/dev/null | head -n 1)"
    else
        echo -e " Aria2 状态: ${Green_font_prefix}已安装${Font_color_suffix} | ${Red_font_prefix}未启动${Font_color_suffix}"
    fi
    if [[ -n $(crontab_update_status) ]]; then
        echo
        echo -e " 自动更新 BT-Tracker: ${Green_font_prefix}已开启${Font_color_suffix}"
    else
        echo
        echo -e " 自动更新 BT-Tracker: ${Red_font_prefix}未开启${Font_color_suffix}"
    fi
else
    echo -e " Aria2 状态: ${Red_font_prefix}未安装${Font_color_suffix}"
fi
echo
read -e -p " 请输入数字 [0-12]:" num
case "$num" in
0) Update_Shell ;;
1) Install_aria2 ;;
2) Update_aria2 ;;
3) Uninstall_aria2 ;;
4) Start_aria2 ;;
5) Stop_aria2 ;;
6) Restart_aria2 ;;
7) Set_aria2 ;;
8) View_Aria2 ;;
9) View_Log ;;
10) Clean_Log ;;
11) Update_bt_tracker ;;
12) Update_bt_tracker_cron ;;
*)
    echo
    echo -e " ${Error} 请输入正确的数字"
    ;;
esac
