#!/bin/bash

# 仅汉化交互文案；更新状态 JSON 的键名和状态值供面板读取，保持不变。

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# Don't edit this config
b_source="${BASH_SOURCE[0]}"
while [ -h "$b_source" ]; do
    b_dir="$(cd -P "$(dirname "$b_source")" > /dev/null 2>&1 && pwd || pwd -P)"
    b_source="$(readlink "$b_source")"
    [[ $b_source != /* ]] && b_source="$b_dir/$b_source"
done
cur_dir="$(cd -P "$(dirname "$b_source")" > /dev/null 2>&1 && pwd || pwd -P)"
script_name=$(basename "$0")

# Check command exist function
_command_exists() {
    type "$1" &> /dev/null
}

# Fail, log and exit script function
_fail() {
    local msg=${1}
    echo -e "${red}${msg}${plain}"
    exit 2
}

# Records this run's outcome for the panel's web updater to poll, since it
# launches this script detached and has no other way to learn whether it
# finished. Written to a fixed path outside XUI_MAIN_FOLDER so it survives
# the update regardless of what happens to that folder. The EXIT trap below
# covers every exit path in this file, including the bare `exit 1`/`exit 2`
# calls that don't go through _fail.
xui_update_run_id="${XUI_UPDATE_RUN_ID:-0}"
[[ "${xui_update_run_id}" =~ ^[0-9]+$ ]] || xui_update_run_id="0"
xui_update_status_file="${XUI_UPDATE_STATUS_FILE:-/etc/x-ui/update-status.json}"

_write_update_status() {
    local state="$1"
    local exit_code="$2"
    local status_dir
    status_dir="$(dirname "${xui_update_status_file}")"
    mkdir -p "${status_dir}" > /dev/null 2>&1
    local tmp_file="${xui_update_status_file}.tmp.$$"
    printf '{"runId":"%s","state":"%s","exitCode":%s,"finishedAt":%s}\n' \
        "${xui_update_run_id}" "${state}" "${exit_code}" "$(date +%s)" > "${tmp_file}" 2> /dev/null
    mv -f "${tmp_file}" "${xui_update_status_file}" > /dev/null 2>&1
}

_report_update_exit() {
    local code=$?
    if [[ "${code}" -eq 0 ]]; then
        _write_update_status "success" "0"
    else
        _write_update_status "failed" "${code}"
    fi
}
trap _report_update_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# check root
[[ $EUID -ne 0 ]] && _fail "致命错误：请以 root 权限运行此脚本。"

if _command_exists curl; then
    curl_bin=$(which curl)
else
    _fail "错误：未找到 curl 命令。"
fi

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    _fail "无法识别操作系统，请联系作者！"
fi
echo "操作系统发行版：$release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${red}不支持此 CPU 架构！${plain}" && rm -f "${cur_dir}/${script_name}" > /dev/null 2>&1 && exit 2 ;;
    esac
}

echo "处理器架构：$(arch)"

# Simple helpers
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# acme.sh's standalone server binds IPv4 by default; --listen-v6 makes it
# v6-only, which breaks HTTP-01 validation when the domain's A record points
# at this host's IPv4 (#4994). Only force IPv6 when the host has no global
# IPv4 address at all.
acme_listen_flag() {
    if ip -4 addr show scope global 2> /dev/null | grep -q "inet "; then
        echo ""
    else
        echo "--listen-v6"
    fi
}

# Port helpers
is_port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat > /dev/null 2>&1; then
        netstat -lnt 2> /dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof > /dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN > /dev/null 2>&1 && return 0
    fi
    return 1
}

gen_random_string() {
    local length="$1"
    openssl rand -base64 $((length * 2)) \
        | tr -dc 'a-zA-Z0-9' \
        | head -c "$length"
}

xui_env_file_path() {
    case "${release}" in
        ubuntu | debian | armbian)
            echo "/etc/default/x-ui"
            ;;
        arch | manjaro | parch | alpine)
            echo "/etc/conf.d/x-ui"
            ;;
        *)
            echo "/etc/sysconfig/x-ui"
            ;;
    esac
}

load_xui_env() {
    local env_file
    env_file="$(xui_env_file_path)"
    if [[ -r "$env_file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
    fi
}

install_base() {
    echo -e "${green}正在更新并安装依赖软件包...${plain}"
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update > /dev/null 2>&1 && apt-get install -y -q cron curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf makecache -y > /dev/null 2>&1 && dnf install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum makecache -y > /dev/null 2>&1 && yum install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            else
                dnf makecache -y > /dev/null 2>&1 && dnf install -y -q cronie curl tar tzdata socat openssl > /dev/null 2>&1
            fi
            ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm cronie curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh > /dev/null 2>&1 && zypper -q install -y cron curl tar timezone socat openssl > /dev/null 2>&1
            ;;
        alpine)
            apk update > /dev/null 2>&1 && apk add dcron curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
        *)
            apt-get update > /dev/null 2>&1 && apt install -y -q cron curl tar tzdata socat openssl > /dev/null 2>&1
            ;;
    esac
}

install_acme() {
    echo -e "${green}正在安装 acme.sh 以管理 SSL 证书...${plain}"
    cd ~ || return 1
    curl -s https://get.acme.sh | sh > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${red}acme.sh 安装失败。${plain}"
        return 1
    else
        echo -e "${green}acme.sh 安装成功。${plain}"
    fi
    return 0
}

setup_ssl_certificate() {
    local domain="$1"
    local server_ip="$2"
    local existing_port="$3"
    local existing_webBasePath="$4"

    echo -e "${green}正在配置 SSL 证书...${plain}"

    # Check if acme.sh is installed
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${yellow}acme.sh 安装失败，跳过 SSL 配置。${plain}"
            return 1
        fi
    fi

    # Create certificate directory
    local certPath="/root/cert/${domain}"
    mkdir -p "$certPath"

    # Issue certificate
    echo -e "${green}正在为 ${domain} 签发 SSL 证书...${plain}"
    echo -e "${yellow}注意：必须开放端口 80，且能从公网访问。${plain}"

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d ${domain} $(acme_listen_flag) --standalone --httpport 80 --force

    if [ $? -ne 0 ]; then
        echo -e "${yellow}无法为 ${domain} 签发证书。${plain}"
        echo -e "${yellow}请确保端口 80 已开放，稍后运行 x-ui 重试。${plain}"
        rm -rf ~/.acme.sh/${domain} 2> /dev/null
        rm -rf "$certPath" 2> /dev/null
        return 1
    fi

    # Install certificate
    ~/.acme.sh/acme.sh --installcert --force -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem \
        --reloadcmd "systemctl restart x-ui" > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${yellow}证书安装失败。${plain}"
        return 1
    fi

    # Enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1
    chmod 600 $certPath/privkey.pem 2> /dev/null
    chmod 644 $certPath/fullchain.pem 2> /dev/null

    # Set certificate for panel
    local webCertFile="/root/cert/${domain}/fullchain.pem"
    local webKeyFile="/root/cert/${domain}/privkey.pem"

    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile" > /dev/null 2>&1
        echo -e "${green}SSL 证书安装并配置成功！${plain}"
        return 0
    else
        echo -e "${yellow}未找到证书文件。${plain}"
        return 1
    fi
}

# Issue Let's Encrypt IP certificate with shortlived profile (~6 days validity)
# Requires acme.sh and port 80 open for HTTP-01 challenge
setup_ip_certificate() {
    local ipv4="$1"
    local ipv6="$2" # optional

    echo -e "${green}正在配置 Let's Encrypt IP 证书（shortlived 短期配置）...${plain}"
    echo -e "${yellow}注意：IP 证书有效期约 6 天，将自动续期。${plain}"
    echo -e "${yellow}默认监听端口为 80；如选择其他端口，请将外部端口 80 转发至该端口。${plain}"

    # Check for acme.sh
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${red}acme.sh 安装失败。${plain}"
            return 1
        fi
    fi

    # Validate IP address
    if [[ -z "$ipv4" ]]; then
        echo -e "${red}必须提供 IPv4 地址。${plain}"
        return 1
    fi

    if ! is_ipv4 "$ipv4"; then
        echo -e "${red}IPv4 地址无效：$ipv4${plain}"
        return 1
    fi

    # Create certificate directory
    local certDir="/root/cert/ip"
    mkdir -p "$certDir"

    # Build domain arguments
    local domain_args="-d ${ipv4}"
    if [[ -n "$ipv6" ]] && is_ipv6 "$ipv6"; then
        domain_args="${domain_args} -d ${ipv6}"
        echo -e "${green}加入 IPv6 地址：${ipv6}${plain}"
    fi

    # Set reload command for auto-renewal (add || true so it doesn't fail if service stopped)
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || true"

    # Choose port for HTTP-01 listener (default 80, prompt override)
    local WebPort=""
    read -rp "ACME HTTP-01 监听端口（默认 80）：" WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        echo -e "${red}端口无效，将使用默认端口 80。${plain}"
        WebPort=80
    fi
    echo -e "${green}使用端口 ${WebPort} 进行独立验证。${plain}"
    if [[ "${WebPort}" -ne 80 ]]; then
        echo -e "${yellow}提醒：Let's Encrypt 仍连接端口 80，请将外部端口 80 转发至 ${WebPort}。${plain}"
    fi

    # Ensure chosen port is available
    while true; do
        if is_port_in_use "${WebPort}"; then
            echo -e "${yellow}端口 ${WebPort} 正在使用中。${plain}"

            local alt_port=""
            read -rp "请输入其他端口供 acme.sh 独立监听使用，留空取消：" alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                echo -e "${red}端口 ${WebPort} 已占用，无法继续。${plain}"
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                echo -e "${red}端口无效。${plain}"
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            echo -e "${green}端口 ${WebPort} 可用，可以进行独立验证。${plain}"
            break
        fi
    done

    # Issue certificate with shortlived profile
    echo -e "${green}正在为 ${ipv4} 签发 IP 证书...${plain}"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force > /dev/null 2>&1

    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        echo -e "${red}IP 证书签发失败。${plain}"
        echo -e "${yellow}请确保端口 ${WebPort} 可访问，或已从外部端口 80 转发至此端口。${plain}"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${ipv4} 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2> /dev/null
        rm -rf ${certDir} 2> /dev/null
        return 1
    fi

    echo -e "${green}证书签发成功，正在安装...${plain}"

    # Install certificate
    # Note: acme.sh may report "Reload error" and exit non-zero if reloadcmd fails,
    # but the cert files are still installed. We check for files instead of exit code.
    ~/.acme.sh/acme.sh --installcert --force -d ${ipv4} \
        --key-file "${certDir}/privkey.pem" \
        --fullchain-file "${certDir}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # Verify certificate files exist (don't rely on exit code - reloadcmd failure causes non-zero)
    if [[ ! -f "${certDir}/fullchain.pem" || ! -f "${certDir}/privkey.pem" ]]; then
        echo -e "${red}安装后未找到证书文件。${plain}"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${ipv4} 2> /dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2> /dev/null
        rm -rf ${certDir} 2> /dev/null
        return 1
    fi

    echo -e "${green}证书文件安装成功。${plain}"

    # Enable auto-upgrade for acme.sh (ensures cron job runs)
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade > /dev/null 2>&1

    chmod 600 ${certDir}/privkey.pem 2> /dev/null
    chmod 644 ${certDir}/fullchain.pem 2> /dev/null

    # Configure panel to use the certificate
    echo -e "${green}正在设置面板证书路径...${plain}"
    ${xui_folder}/x-ui cert -webCert "${certDir}/fullchain.pem" -webCertKey "${certDir}/privkey.pem"
    if [ $? -ne 0 ]; then
        echo -e "${yellow}警告：无法自动设置证书路径。${plain}"
        echo -e "${yellow}可能需要在面板设置中手动配置证书路径。${plain}"
        echo -e "${yellow}证书路径：${certDir}/fullchain.pem${plain}"
        echo -e "${yellow}私钥路径：${certDir}/privkey.pem${plain}"
    else
        echo -e "${green}证书路径设置成功！${plain}"
    fi

    echo -e "${green}IP 证书安装并配置成功！${plain}"
    echo -e "${green}证书有效期约 6 天，通过 acme.sh 定时任务自动续期。${plain}"
    echo -e "${yellow}每次续期后，面板将自动重启。${plain}"
    return 0
}

# Comprehensive manual SSL certificate issuance via acme.sh
ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep 'webBasePath:' | awk -F': ' '{print $2}' | tr -d '[:space:]' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep 'port:' | awk -F': ' '{print $2}' | tr -d '[:space:]')

    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &> /dev/null; then
        echo "未找到 acme.sh，正在安装..."
        cd ~ || return 1
        curl -s https://get.acme.sh | sh
        if [ $? -ne 0 ]; then
            echo -e "${red}acme.sh 安装失败。${plain}"
            return 1
        else
            echo -e "${green}acme.sh 安装成功。${plain}"
        fi
    fi

    # get the domain here, and we need to verify it
    local domain=""
    while true; do
        read -rp "请输入域名：" domain
        domain="${domain// /}" # Trim whitespace

        if [[ -z "$domain" ]]; then
            echo -e "${red}域名不能为空，请重试。${plain}"
            continue
        fi

        if ! is_domain "$domain"; then
            echo -e "${red}域名格式无效：${domain}。请输入有效域名。${plain}"
            continue
        fi

        break
    done
    echo -e "${green}当前域名：${domain}，正在检查...${plain}"
    SSL_ISSUED_DOMAIN="${domain}"

    # detect existing certificate and reuse it if present
    local cert_exists=0
    if ~/.acme.sh/acme.sh --list 2> /dev/null | awk '{print $1}' | grep -Fxq "${domain}"; then
        cert_exists=1
        local certInfo=$(~/.acme.sh/acme.sh --list 2> /dev/null | grep -F "${domain}")
        echo -e "${yellow}已找到 ${domain} 的现有证书，将重复使用。${plain}"
        [[ -n "${certInfo}" ]] && echo "$certInfo"
    else
        echo -e "${green}域名已就绪，可以签发证书。${plain}"
    fi

    # create a directory for the certificate
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # get the port number for the standalone server
    local WebPort=80
    read -rp "请选择要使用的端口（默认 80）：" WebPort
    if [[ -z ${WebPort} ]]; then
        WebPort=80
    elif [[ ! ${WebPort} =~ ^[1-9][0-9]*$ || ${WebPort} -gt 65535 ]]; then
        echo -e "${yellow}输入的端口 ${WebPort} 无效，将使用默认端口 80。${plain}"
        WebPort=80
    fi
    echo -e "${green}将使用端口 ${WebPort} 签发证书，请确保端口已开放。${plain}"

    # Stop panel temporarily
    echo -e "${yellow}正在暂时停止面板...${plain}"
    systemctl stop x-ui 2> /dev/null || rc-service x-ui stop 2> /dev/null

    if [[ ${cert_exists} -eq 0 ]]; then
        # issue the certificate
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
        ~/.acme.sh/acme.sh --issue -d ${domain} $(acme_listen_flag) --standalone --httpport ${WebPort} --force
        if [ $? -ne 0 ]; then
            echo -e "${red}证书签发失败，请查看日志。${plain}"
            rm -rf ~/.acme.sh/${domain}
            systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null
            return 1
        else
            echo -e "${green}证书签发成功，正在安装证书...${plain}"
        fi
    else
        echo -e "${green}使用现有证书，正在安装...${plain}"
    fi

    # Setup reload command
    reloadCmd="systemctl restart x-ui || rc-service x-ui restart"
    echo -e "${green}ACME 的默认 --reloadcmd 命令为：${yellow}systemctl restart x-ui || rc-service x-ui restart${plain}"
    echo -e "${green}每次签发或续期证书后都会执行此命令。${plain}"
    read -rp "是否修改 ACME 的 --reloadcmd 命令？（y=是/n=否）：" setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} 预设：systemctl reload nginx ; systemctl restart x-ui"
        echo -e "${green}\t2.${plain} 输入自定义命令"
        echo -e "${green}\t0.${plain} 保留默认 reloadcmd 命令"
        read -rp "请选择一项：" choice
        case "$choice" in
            1)
                echo -e "${green}reloadcmd 命令为：systemctl reload nginx ; systemctl restart x-ui${plain}"
                reloadCmd="systemctl reload nginx ; systemctl restart x-ui"
                ;;
            2)
                echo -e "${yellow}建议将 x-ui restart 放在命令末尾。${plain}"
                read -rp "请输入自定义 reloadcmd 命令：" reloadCmd
                echo -e "${green}reloadcmd 命令为：${reloadCmd}${plain}"
                ;;
            *)
                echo -e "${green}保留默认 reloadcmd 命令。${plain}"
                ;;
        esac
    fi

    # install the certificate
    local installOutput=""
    installOutput=$(~/.acme.sh/acme.sh --installcert --force -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}" 2>&1)
    local installRc=$?
    echo "${installOutput}"

    local installWroteFiles=0
    if echo "${installOutput}" | grep -q "Installing key to:" && echo "${installOutput}" | grep -q "Installing full chain to:"; then
        installWroteFiles=1
    fi

    if [[ -f "/root/cert/${domain}/privkey.pem" && -f "/root/cert/${domain}/fullchain.pem" && (${installRc} -eq 0 || ${installWroteFiles} -eq 1) ]]; then
        echo -e "${green}证书安装成功，正在启用自动续期...${plain}"
    else
        echo -e "${red}证书安装失败，正在退出。${plain}"
        if [[ ${cert_exists} -eq 0 ]]; then
            rm -rf ~/.acme.sh/${domain}
        fi
        systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null
        return 1
    fi

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        echo -e "${yellow}自动续期配置遇到问题，证书详情：${plain}"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    else
        echo -e "${green}自动续期成功，证书详情：${plain}"
        ls -lah /root/cert/${domain}/
        chmod 600 $certPath/privkey.pem
        chmod 644 $certPath/fullchain.pem
    fi

    # Restart panel
    systemctl start x-ui 2> /dev/null || rc-service x-ui start 2> /dev/null

    # Prompt user to set panel paths after successful certificate installation
    read -rp "是否将此证书用于面板？（y=是/n=否）：" setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            echo -e "${green}面板证书路径已设置。${plain}"
            echo -e "${green}证书文件：$webCertFile${plain}"
            echo -e "${green}私钥文件：$webKeyFile${plain}"
            echo ""
            echo -e "${green}访问地址：https://${domain}:${existing_port}/${existing_webBasePath}${plain}"
            echo -e "${yellow}即将重启面板以应用 SSL 证书...${plain}"
            systemctl restart x-ui 2> /dev/null || rc-service x-ui restart 2> /dev/null
        else
            echo -e "${red}错误：未找到此域名的证书或私钥文件：$domain.${plain}"
        fi
    else
        echo -e "${yellow}跳过面板证书路径设置。${plain}"
    fi

    return 0
}
# Unified interactive SSL setup (domain or IP)
# Sets global `SSL_HOST` to the chosen domain/IP
prompt_and_setup_ssl() {
    local panel_port="$1"
    local web_base_path="$2" # expected without leading slash
    local server_ip="$3"

    local ssl_choice=""

    echo -e "${yellow}请选择 SSL 证书配置方式：${plain}"
    echo -e "${green}1.${plain} Let's Encrypt 域名证书（有效期 90 天，自动续期）"
    echo -e "${green}2.${plain} Let's Encrypt IP 地址证书（有效期 6 天，自动续期）"
    echo -e "${green}3.${plain} 自定义 SSL 证书（现有文件路径）"
    echo -e "${green}4.${plain} 跳过 SSL（高级选项，仅限反向代理或 SSH 隧道之后）"
    echo -e "${blue}注意：${plain} 选项 1 和 2 要求开放端口 80，选项 3 需手动指定路径。"
    echo -e "${blue}注意：${plain} 选项 4 使用明文 HTTP，仅在 nginx/Caddy 或 SSH 隧道之后使用才安全。"
    read -rp "请选择（默认 2，申请 IP 证书）：" ssl_choice
    ssl_choice="${ssl_choice// /}" # Trim whitespace

    # Default to 2 (IP cert) if input is empty or invalid (not 1, 3 or 4)
    if [[ "$ssl_choice" != "1" && "$ssl_choice" != "3" && "$ssl_choice" != "4" ]]; then
        ssl_choice="2"
    fi

    case "$ssl_choice" in
        1)
            # User chose Let's Encrypt domain option
            echo -e "${green}正在通过 Let's Encrypt 申请域名证书...${plain}"
            if ssl_cert_issue; then
                local cert_domain="${SSL_ISSUED_DOMAIN}"
                if [[ -z "${cert_domain}" ]]; then
                    cert_domain=$(~/.acme.sh/acme.sh --list 2> /dev/null | tail -1 | awk '{print $1}')
                fi

                if [[ -n "${cert_domain}" ]]; then
                    SSL_HOST="${cert_domain}"
                    echo -e "${green}✓ 已成功配置此域名的 SSL 证书：${cert_domain}${plain}"
                else
                    echo -e "${yellow}SSL 配置可能已完成，但域名提取失败。${plain}"
                    SSL_HOST="${server_ip}"
                fi
            else
                echo -e "${red}域名模式 SSL 证书配置失败。${plain}"
                SSL_HOST="${server_ip}"
            fi
            ;;
        2)
            # User chose Let's Encrypt IP certificate option
            echo -e "${green}正在通过 Let's Encrypt 申请 IP 证书（shortlived 短期配置）...${plain}"

            # Confirm the auto-detected IP before issuing for it: with asymmetric
            # routing / multi-WAN the echo services can return a transit address.
            local ip_confirm=""
            read -rp "${server_ip} 是否为此服务器正确的入站公网 IPv4 地址？［y=是/n=否，默认 y］：" ip_confirm
            if [[ -n "$ip_confirm" && "$ip_confirm" != "y" && "$ip_confirm" != "Y" ]]; then
                server_ip=""
                while [[ -z "$server_ip" ]]; do
                    read -rp "请输入服务器的公网 IPv4 地址：" server_ip
                    server_ip="${server_ip// /}"
                    if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        echo -e "${red}IPv4 地址无效，请重试。${plain}"
                        server_ip=""
                    fi
                done
            fi

            # Ask for optional IPv6
            local ipv6_addr=""
            read -rp "是否需要加入 IPv6 地址？请输入地址，留空跳过：" ipv6_addr
            ipv6_addr="${ipv6_addr// /}" # Trim whitespace

            # Stop panel if running (port 80 needed)
            if [[ $release == "alpine" ]]; then
                rc-service x-ui stop > /dev/null 2>&1
            else
                systemctl stop x-ui > /dev/null 2>&1
            fi

            setup_ip_certificate "${server_ip}" "${ipv6_addr}"
            if [ $? -eq 0 ]; then
                SSL_HOST="${server_ip}"
                echo -e "${green}✓ Let's Encrypt IP 证书配置成功。${plain}"
            else
                echo -e "${red}✗ IP 证书配置失败，请检查端口 80 是否已开放。${plain}"
                SSL_HOST="${server_ip}"
            fi

            # Restart panel after SSL is configured (restart applies new cert settings)
            if [[ $release == "alpine" ]]; then
                rc-service x-ui restart > /dev/null 2>&1
            else
                systemctl restart x-ui > /dev/null 2>&1
            fi

            ;;
        3)
            # User chose Custom Paths (User Provided) option
            echo -e "${green}正在使用现有的自定义证书...${plain}"
            local custom_cert=""
            local custom_key=""
            local custom_domain=""

            # 3.1 Request Domain to compose Panel URL later
            read -rp "请输入此证书签发的域名：" custom_domain
            custom_domain="${custom_domain// /}" # Remove spaces

            # 3.2 Loop for Certificate Path
            while true; do
                read -rp "请输入证书路径（例如 .crt 或 fullchain 文件）：" custom_cert
                # Strip quotes if present
                custom_cert=$(echo "$custom_cert" | tr -d '"' | tr -d "'")

                if [[ -f "$custom_cert" && -r "$custom_cert" && -s "$custom_cert" ]]; then
                    break
                elif [[ ! -f "$custom_cert" ]]; then
                    echo -e "${red}错误：文件不存在，请重试！${plain}"
                elif [[ ! -r "$custom_cert" ]]; then
                    echo -e "${red}错误：文件存在但无法读取，请检查权限！${plain}"
                else
                    echo -e "${red}错误：文件为空！${plain}"
                fi
            done

            # 3.3 Loop for Private Key Path
            while true; do
                read -rp "请输入私钥路径（例如 .key 或 privatekey 文件）：" custom_key
                # Strip quotes if present
                custom_key=$(echo "$custom_key" | tr -d '"' | tr -d "'")

                if [[ -f "$custom_key" && -r "$custom_key" && -s "$custom_key" ]]; then
                    break
                elif [[ ! -f "$custom_key" ]]; then
                    echo -e "${red}错误：文件不存在，请重试！${plain}"
                elif [[ ! -r "$custom_key" ]]; then
                    echo -e "${red}错误：文件存在但无法读取，请检查权限！${plain}"
                else
                    echo -e "${red}错误：文件为空！${plain}"
                fi
            done

            # 3.4 Apply Settings via x-ui binary
            ${xui_folder}/x-ui cert -webCert "$custom_cert" -webCertKey "$custom_key" > /dev/null 2>&1

            # Set SSL_HOST for composing Panel URL
            if [[ -n "$custom_domain" ]]; then
                SSL_HOST="$custom_domain"
            else
                SSL_HOST="${server_ip}"
            fi

            echo -e "${green}✓ 自定义证书路径已应用。${plain}"
            echo -e "${yellow}注意：需要自行在外部维护并续期这些证书文件。${plain}"

            systemctl restart x-ui > /dev/null 2>&1 || rc-service x-ui restart > /dev/null 2>&1
            ;;
        4)
            echo ""
            echo -e "${red}⚠ 面板将以不启用 SSL/TLS 的方式安装。${plain}"
            echo -e "${yellow}登录凭据和 Cookie 将通过明文 HTTP 传输。${plain}"
            echo -e "${yellow}仅在以下场景使用才安全：${plain}"
            echo -e "${yellow}  • 由反向代理（nginx、Caddy、Traefik）处理 TLS，或${plain}"
            echo -e "${yellow}  • 仅通过 SSH 隧道访问面板。${plain}"
            echo ""

            SSL_SCHEME="http"
            SSL_HOST="${server_ip}"

            local bind_local=""
            read -rp "是否仅将面板绑定至 127.0.0.1？（推荐，强制通过 SSH 隧道或反向代理访问）［y=是/N=否，默认否］：" bind_local
            if [[ "$bind_local" == "y" || "$bind_local" == "Y" ]]; then
                ${xui_folder}/x-ui setting -listenIP "127.0.0.1" > /dev/null 2>&1
                SSL_HOST="127.0.0.1"
                echo -e "${green}✓ 面板已仅绑定至 127.0.0.1，无法从公网直接访问。${plain}"
                echo ""
                echo -e "${green}SSH 端口转发：在本机通过以下方式打开面板：${plain}"
                echo -e "  标准 SSH 命令："
                echo -e "  ${yellow}ssh -L 2222:127.0.0.1:${panel_port} root@${server_ip}${plain}"
                echo -e "  使用 SSH 密钥时："
                echo -e "  ${yellow}ssh -i <sshkeypath> -L 2222:127.0.0.1:${panel_port} root@${server_ip}${plain}"
                echo -e "  然后在浏览器中打开："
                echo -e "  ${yellow}http://localhost:2222/${web_base_path}${plain}"
                echo ""
                echo -e "${yellow}也可以将反向代理（nginx/Caddy）指向 127.0.0.1:${panel_port}，由其处理 TLS。${plain}"
            else
                echo -e "${yellow}面板将通过明文 HTTP 监听所有网卡，请确保前方有其他服务处理 TLS。${plain}"
            fi

            systemctl restart x-ui > /dev/null 2>&1 || rc-service x-ui restart > /dev/null 2>&1
            echo -e "${green}✓ 已跳过 SSL 配置。${plain}"
            ;;
        *)
            echo -e "${red}选项无效，跳过 SSL 配置。${plain}"
            SSL_HOST="${server_ip}"
            ;;
    esac
}

config_after_update() {
    local panel_needs_restart=0

    echo -e "${yellow}x-ui 设置：${plain}"
    ${xui_folder}/x-ui setting -show true
    ${xui_folder}/x-ui migrate

    # Properly detect empty cert by checking if cert: line exists and has content after it
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true 2> /dev/null | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##')

    # Get server IP
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2> /dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]"')
        if [[ "${http_code}" == "200" && "${ip_result}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            server_ip="${ip_result}"
            break
        fi
    done

    if [[ -z "$server_ip" ]]; then
        echo -e "${yellow}无法从任何服务商自动检测服务器 IP 地址。${plain}"
        while [[ -z "$server_ip" ]]; do
            read -rp "请输入服务器的公网 IPv4 地址：" server_ip
            server_ip="${server_ip// /}"
            if [[ ! "$server_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo -e "${red}IPv4 地址无效，请重试。${plain}"
                server_ip=""
            fi
        done
    fi

    # Handle missing/short webBasePath
    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        echo -e "${yellow}面板访问路径缺失或过短，正在生成新路径...${plain}"
        local config_webBasePath=$(gen_random_string 18)
        ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
        existing_webBasePath="${config_webBasePath}"
        panel_needs_restart=1
        echo -e "${green}新的面板访问路径：${config_webBasePath}${plain}"
    fi

    # Check and prompt for SSL if missing
    if [[ -z "$existing_cert" ]]; then
        echo ""
        echo -e "${red}═══════════════════════════════════════════${plain}"
        echo -e "${red}      ⚠ 未检测到 SSL 证书 ⚠     ${plain}"
        echo -e "${red}═══════════════════════════════════════════${plain}"
        echo -e "${yellow}为确保安全，所有面板都必须配置 SSL 证书。${plain}"
        echo -e "${yellow}Let's Encrypt 现已同时支持域名和 IP 地址！${plain}"
        echo ""

        # Prompt and setup SSL (domain or IP)
        prompt_and_setup_ssl "${existing_port}" "${existing_webBasePath}" "${server_ip}"

        echo ""
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}     面板访问信息              ${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}访问地址：https://${SSL_HOST}:${existing_port}/${existing_webBasePath}${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${yellow}⚠ SSL 证书：已启用并配置。${plain}"
    else
        echo -e "${green}SSL 证书已配置。${plain}"
        # Show access URL with existing certificate
        local cert_domain=$(basename "$(dirname "$existing_cert")")
        echo ""
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}     面板访问信息              ${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}访问地址：https://${cert_domain}:${existing_port}/${existing_webBasePath}${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
    fi

    if [[ "$panel_needs_restart" -eq 1 ]]; then
        echo -e "${yellow}正在重启面板以应用新的访问路径...${plain}"
        systemctl restart x-ui 2> /dev/null || rc-service x-ui restart 2> /dev/null
    fi
}

# setup_fail2ban auto-installs and configures fail2ban for the IP Limit feature
# by invoking the freshly downloaded x-ui CLI. IP Limit is load-bearing on
# fail2ban (without it the panel disables the limitIp field and zeroes existing
# limits), so updating an older install should make it work without a manual
# trip through the IP Limit menu. Non-fatal: a fail2ban failure must never abort
# the update. XUI_ENABLE_FAIL2BAN is honored (load_xui_env exports it from the
# persisted env file, so a deliberate opt-out survives updates).
setup_fail2ban() {
    if [[ -n "${XUI_ENABLE_FAIL2BAN+x}" && "${XUI_ENABLE_FAIL2BAN}" != "true" ]]; then
        echo -e "${yellow}XUI_ENABLE_FAIL2BAN=${XUI_ENABLE_FAIL2BAN}，跳过 Fail2ban 自动配置。${plain}"
        return 0
    fi

    if [[ ! -x /usr/bin/x-ui ]]; then
        echo -e "${yellow}未找到 x-ui 命令行工具，跳过 Fail2ban 自动配置。${plain}"
        return 0
    fi

    # Scripts older than v3.4.0 have no setup-fail2ban and exit 0 from the
    # usage banner, which would read as success here.
    if ! grep -q '"setup-fail2ban")' /usr/bin/x-ui; then
        echo -e "${yellow}此 x-ui.sh 版本不支持 'x-ui setup-fail2ban'，跳过 Fail2ban 自动配置。${plain}"
        return 0
    fi

    echo -e "${green}正在为 IP 限制功能配置 Fail2ban...${plain}"
    if /usr/bin/x-ui setup-fail2ban; then
        echo -e "${green}Fail2ban 配置完成。${plain}"
    else
        echo -e "${yellow}Fail2ban 配置未完成，IP 限制保持禁用；请运行 'x-ui' 并打开 IP 限制菜单完成配置。继续执行。${plain}"
    fi
    return 0
}

# Lands a systemd unit file at ${xui_service}/x-ui.service via a temp file +
# atomic mv, so a failed cp/curl or an interrupted mv never leaves a
# truncated unit file at the live path -- systemd would then fail to parse
# it on the next daemon-reload/start. Same pattern already used for
# /usr/bin/x-ui elsewhere in this script. source_is_url picks cp (from a
# file already extracted from the release tarball) vs curl (GitHub fallback).
_install_xui_service_unit() {
    local source="$1"
    local source_is_url="$2"
    local dest="${xui_service}/x-ui.service"
    local temp_file="${dest}.tmp.$$"

    rm -f "$temp_file"
    if [[ "$source_is_url" == "true" ]]; then
        ${curl_bin} -fLRo "$temp_file" "$source" > /dev/null 2>&1
    else
        cp -f "$source" "$temp_file" > /dev/null 2>&1
    fi
    if [[ $? -ne 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi
    if [[ ! -s "$temp_file" ]]; then
        rm -f "$temp_file"
        return 1
    fi
    mv -f "$temp_file" "$dest"
    if [[ $? -ne 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi
    return 0
}

# Older tags predate some of these files (x-ui.rc arrived in v2.8.4). Serving
# main's copy against an old binary is the mismatch this pinning exists to
# prevent, so probe before the old install is removed and refuse the tag.
require_repo_files() {
    local ref="$1" name status
    shift
    [[ "${ref}" == "main" ]] && return 0
    for name in "$@"; do
        status=$(${curl_bin} -sIL --retry 3 --connect-timeout 15 -o /dev/null -w '%{http_code}' "https://raw.githubusercontent.com/MHSanaei/3x-ui/${ref}/${name}")
        if [[ "${status}" != "200" ]]; then
            _fail "错误：${name} 不适用于 ${ref}（HTTP ${status}）。请更新至包含此文件的发行版，或使用 'dev-latest'。当前安装未被改动。"
        fi
    done
}

update_x-ui() {
    cd ${xui_folder%/x-ui}/

    load_xui_env

    if [ -f "${xui_folder}/x-ui" ]; then
        current_xui_version=$(${xui_folder}/x-ui -v)
        echo -e "${green}当前 x-ui 版本：${current_xui_version}${plain}"
    else
        _fail "错误：当前 x-ui 版本：未知"
    fi

    echo -e "${green}正在下载新版 x-ui...${plain}"

    # XUI_UPDATE_TAG lets the panel target a specific release tag (e.g. the
    # rolling dev-latest pre-release). Empty keeps the default latest-stable flow.
    if [[ -n "${XUI_UPDATE_TAG}" ]]; then
        tag_version="${XUI_UPDATE_TAG}"
        echo -e "${green}使用更新标签：${tag_version}${plain}"
    else
        tag_version=$(${curl_bin} -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" 2> /dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            _fail "错误：获取 x-ui 版本失败，可能受到 GitHub API 限制，请稍后重试。"
        fi
    fi
    echo -e "已获取 x-ui 最新版本：${tag_version}，正在开始安装..."
    # x-ui.sh, x-ui.rc and the unit files must come from the same release as
    # the binary; only the rolling dev build tracks main.
    script_ref="${tag_version}"
    if [[ "${tag_version}" == "dev-latest" ]]; then
        script_ref="main"
    fi
    # The unit files are only fetched when the release tarball lacks them, so
    # they are checked at that point instead of here.
    local required_files=("x-ui.sh")
    [[ $release == "alpine" ]] && required_files+=("x-ui.rc")
    require_repo_files "${script_ref}" "${required_files[@]}"
    ${curl_bin} -fLRo ${xui_folder}-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz 2> /dev/null
    if [[ $? -ne 0 ]]; then
        _fail "错误：下载 x-ui 失败，请确保服务器可以访问 GitHub。"
    fi
    if [[ ! -s ${xui_folder}-linux-$(arch).tar.gz ]]; then
        rm ${xui_folder}-linux-$(arch).tar.gz -f > /dev/null 2>&1
        _fail "错误：下载的 x-ui 发行压缩包为空。，请确保服务器可以访问 GitHub。"
    fi
    # Releases publish <asset>.sha256 next to each archive. A mismatch or a
    # failed sidecar download aborts the update; only a 404 (releases
    # predating the sidecar) is tolerated with a warning.
    archive="${xui_folder}-linux-$(arch).tar.gz"
    rm -f "${archive}.sha256"
    sidecar_code=$(${curl_bin} -sL --retry 3 --retry-delay 3 --connect-timeout 15 --max-time 60 -o "${archive}.sha256" -w '%{http_code}' "https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz.sha256" 2> /dev/null)
    if [[ "${sidecar_code}" == "200" ]]; then
        expected_sha256=$(awk 'NR == 1 {print $1}' "${archive}.sha256")
        actual_sha256=$(sha256sum "${archive}" | awk '{print $1}')
        rm -f "${archive}.sha256"
        if [[ ! "${expected_sha256}" =~ ^[0-9a-f]{64}$ || "${expected_sha256}" != "${actual_sha256}" ]]; then
            rm -f "${archive}"
            _fail "错误：以下文件的校验值不匹配：$(basename "${archive}")：预期 ${expected_sha256:-<none>}，实际 ${actual_sha256}"
        fi
        echo -e "${green}校验通过：${actual_sha256}${plain}"
    elif [[ "${sidecar_code}" == "404" ]]; then
        rm -f "${archive}.sha256"
        echo -e "${yellow}此版本未发布校验值，跳过校验。${plain}"
    else
        rm -f "${archive}.sha256" "${archive}"
        _fail "错误：无法下载以下文件的校验值：x-ui-linux-$(arch).tar.gz (HTTP ${sidecar_code})"
    fi

    if [[ -e ${xui_folder}/ ]]; then
        echo -e "${green}正在停止 x-ui...${plain}"
        if [[ $release == "alpine" ]]; then
            if [ -f "/etc/init.d/x-ui" ]; then
                rc-service x-ui stop > /dev/null 2>&1
                rc-update del x-ui > /dev/null 2>&1
                echo -e "${green}正在移除旧版服务单元...${plain}"
                rm -f /etc/init.d/x-ui > /dev/null 2>&1
            else
                rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
                _fail "错误：尚未安装 x-ui 服务单元。"
            fi
        else
            if [ -f "${xui_service}/x-ui.service" ]; then
                systemctl stop x-ui > /dev/null 2>&1
                systemctl disable x-ui > /dev/null 2>&1
                echo -e "${green}正在移除旧版 systemd 服务单元...${plain}"
                rm ${xui_service}/x-ui.service -f > /dev/null 2>&1
                systemctl daemon-reload > /dev/null 2>&1
            else
                rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
                _fail "错误：尚未安装 x-ui systemd 服务单元。"
            fi
        fi
        # Kill any leftover mtg (MTProto) sidecars. x-ui runs them outside its own
        # lifecycle, so on Linux a stale one can survive the stop and keep holding
        # an inbound port with an outdated secret, silently breaking new clients.
        # The new panel respawns a clean mtg per inbound on next start.
        pkill -f 'mtg-linux-[^ ]* run ' > /dev/null 2>&1 || true
        pkill -f 'tuic-server.*-c .*bin/tuic/tuic_[0-9]+\.json' > /dev/null 2>&1 || true
        echo -e "${green}正在移除旧版 x-ui...${plain}"
        rm ${xui_folder} -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.debian -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.arch -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.service.rhel -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui -f > /dev/null 2>&1
        rm ${xui_folder}/x-ui.sh -f > /dev/null 2>&1
        echo -e "${green}正在移除旧版 mtg...${plain}"
        rm ${xui_folder}/bin/mtg-linux-$(arch) -f > /dev/null 2>&1
        echo -e "${green}正在移除旧版 Xray...${plain}"
        rm ${xui_folder}/bin/xray-linux-$(arch) -f > /dev/null 2>&1
        echo -e "${green}正在移除旧版 README 和 LICENSE 文件...${plain}"
        rm ${xui_folder}/bin/README.md -f > /dev/null 2>&1
        rm ${xui_folder}/bin/LICENSE -f > /dev/null 2>&1
        rm ${xui_folder}/bin/tuic-server -f > /dev/null 2>&1
        rm ${xui_folder}/bin/tuic -rf > /dev/null 2>&1
    else
        rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
        _fail "错误：尚未安装 x-ui。"
    fi

    echo -e "${green}正在安装新版 x-ui...${plain}"
    tar zxvf x-ui-linux-$(arch).tar.gz > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
        _fail "错误：解压 x-ui 发行压缩包失败；旧安装已被移除，修复前面板无法启动，请尝试重新运行更新脚本。"
    fi
    rm x-ui-linux-$(arch).tar.gz -f > /dev/null 2>&1
    cd x-ui > /dev/null 2>&1
    if [[ $? -ne 0 || ! -s x-ui ]]; then
        _fail "错误：解压后的 x-ui 包缺少主程序；旧安装已被移除，修复前面板无法启动，请尝试重新运行更新脚本。"
    fi
    chmod +x x-ui > /dev/null 2>&1

    # Check the system's architecture and rename the file accordingly.
    # The panel binary maps GOARCH=arm to "arm32" (internal/xray/process.go),
    # so the Xray binary must be named xray-linux-arm32; mtg keeps plain "arm".
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm32 > /dev/null 2>&1
        chmod +x bin/xray-linux-arm32 > /dev/null 2>&1
        if [[ -f bin/mtg-linux-$(arch) ]]; then
            mv bin/mtg-linux-$(arch) bin/mtg-linux-arm > /dev/null 2>&1
            chmod +x bin/mtg-linux-arm > /dev/null 2>&1
        fi
    fi

    chmod +x x-ui bin/xray-linux-$(arch) > /dev/null 2>&1
    if [[ -f bin/mtg-linux-arm ]]; then
        chmod +x bin/mtg-linux-arm > /dev/null 2>&1
    elif [[ -f bin/mtg-linux-$(arch) ]]; then
        chmod +x bin/mtg-linux-$(arch) > /dev/null 2>&1
    fi

    echo -e "${green}正在下载并安装 x-ui.sh 脚本...${plain}"
    local xui_script_temp="/usr/bin/x-ui-temp.$$"
    rm -f "${xui_script_temp}"
    ${curl_bin} -fLRo "${xui_script_temp}" "https://raw.githubusercontent.com/MHSanaei/3x-ui/${script_ref}/x-ui.sh" > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        rm -f "${xui_script_temp}"
        _fail "错误：下载 x-ui.sh 脚本失败。，请确保服务器可以访问 GitHub。"
    fi
    if [[ ! -s "${xui_script_temp}" ]]; then
        rm -f "${xui_script_temp}"
        _fail "错误：下载的 x-ui.sh 脚本为空。，请确保服务器可以访问 GitHub。"
    fi
    mv -f "${xui_script_temp}" /usr/bin/x-ui
    if [[ $? -ne 0 ]]; then
        rm -f "${xui_script_temp}"
        _fail "错误：安装 x-ui.sh 脚本失败。"
    fi

    chmod +x ${xui_folder}/x-ui.sh > /dev/null 2>&1
    chmod +x /usr/bin/x-ui > /dev/null 2>&1
    mkdir -p /var/log/x-ui > /dev/null 2>&1

    echo -e "${green}正在修改文件所有者...${plain}"
    chown -R root:root ${xui_folder} > /dev/null 2>&1

    if [ -f "${xui_folder}/bin/config.json" ]; then
        echo -e "${green}正在修改配置文件权限...${plain}"
        chmod 640 ${xui_folder}/bin/config.json > /dev/null 2>&1
    fi

    if [[ $release == "alpine" ]]; then
        echo -e "${green}正在下载并安装启动服务 x-ui.rc...${plain}"
        xui_rc_temp="/etc/init.d/x-ui.tmp.$$"
        rm -f "${xui_rc_temp}"
        ${curl_bin} -fLRo "${xui_rc_temp}" "https://raw.githubusercontent.com/MHSanaei/3x-ui/${script_ref}/x-ui.rc" > /dev/null 2>&1
        if [[ $? -ne 0 ]]; then
            rm -f "${xui_rc_temp}"
            _fail "错误：下载启动服务 x-ui.rc 失败。，请确保服务器可以访问 GitHub。"
        fi
        if [[ ! -s "${xui_rc_temp}" ]]; then
            rm -f "${xui_rc_temp}"
            _fail "错误：下载的启动服务 x-ui.rc 为空。，请确保服务器可以访问 GitHub。"
        fi
        mv -f "${xui_rc_temp}" /etc/init.d/x-ui
        if [[ $? -ne 0 ]]; then
            rm -f "${xui_rc_temp}"
            _fail "错误：安装启动服务 x-ui.rc 失败。"
        fi
        chmod +x /etc/init.d/x-ui > /dev/null 2>&1
        chown root:root /etc/init.d/x-ui > /dev/null 2>&1
        rc-update add x-ui > /dev/null 2>&1
        rc-service x-ui start > /dev/null 2>&1
    else
        if [ -f "x-ui.service" ]; then
            echo -e "${green}正在安装 systemd 服务单元...${plain}"
            if ! _install_xui_service_unit "x-ui.service" "false"; then
                echo -e "${red}复制 x-ui.service 失败。${plain}"
                exit 1
            fi
        else
            service_installed=false
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}正在安装 Debian 类系统的 systemd 服务单元...${plain}"
                        if _install_xui_service_unit "x-ui.service.debian" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}正在安装 Arch 类系统的 systemd 服务单元...${plain}"
                        if _install_xui_service_unit "x-ui.service.arch" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}正在安装 RHEL 类系统的 systemd 服务单元...${plain}"
                        if _install_xui_service_unit "x-ui.service.rhel" "false"; then
                            service_installed=true
                        fi
                    fi
                    ;;
            esac

            # If service file not found in tar.gz, download from GitHub
            if [ "$service_installed" = false ]; then
                echo -e "${yellow}压缩包中未找到服务文件，正在从 GitHub 下载...${plain}"
                case "${release}" in
                    ubuntu | debian | armbian)
                        service_unit_url="https://raw.githubusercontent.com/MHSanaei/3x-ui/${script_ref}/x-ui.service.debian"
                        ;;
                    arch | manjaro | parch)
                        service_unit_url="https://raw.githubusercontent.com/MHSanaei/3x-ui/${script_ref}/x-ui.service.arch"
                        ;;
                    *)
                        service_unit_url="https://raw.githubusercontent.com/MHSanaei/3x-ui/${script_ref}/x-ui.service.rhel"
                        ;;
                esac

                if ! _install_xui_service_unit "$service_unit_url" "true"; then
                    echo -e "${red}无法从 GitHub（${script_ref}）安装 x-ui.service，发行压缩包中也未提供此文件。${plain}"
                    exit 1
                fi
            fi
        fi
        chown root:root ${xui_service}/x-ui.service > /dev/null 2>&1
        chmod 644 ${xui_service}/x-ui.service > /dev/null 2>&1
        systemctl daemon-reload > /dev/null 2>&1
        systemctl enable x-ui > /dev/null 2>&1
        systemctl start x-ui > /dev/null 2>&1
    fi

    config_after_update

    # IP Limit relies on fail2ban; install + configure it now so the feature
    # works out of the box on update too (no-op when XUI_ENABLE_FAIL2BAN=false).
    # Never fatal.
    setup_fail2ban

    echo -e "${green}x-ui ${tag_version}${plain} 更新完成，现已运行。"
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui 管理命令（子命令）：${plain}                            │
│                                                       │
│  ${blue}x-ui${plain}              - 面板管理脚本                     │
│  ${blue}x-ui start${plain}        - 启动                             │
│  ${blue}x-ui stop${plain}         - 停止                             │
│  ${blue}x-ui restart${plain}      - 重启                             │
│  ${blue}x-ui status${plain}       - 当前状态                         │
│  ${blue}x-ui settings${plain}     - 当前设置                         │
│  ${blue}x-ui enable${plain}       - 启用开机自启                     │
│  ${blue}x-ui disable${plain}      - 禁用开机自启                     │
│  ${blue}x-ui log${plain}          - 查看日志                         │
│  ${blue}x-ui banlog${plain}       - 查看 Fail2ban 封禁日志           │
│  ${blue}x-ui update${plain}       - 更新                             │
│  ${blue}x-ui legacy${plain}       - 安装历史版本                     │
│  ${blue}x-ui install${plain}      - 安装                             │
│  ${blue}x-ui uninstall${plain}    - 卸载                             │
└───────────────────────────────────────────────────────┘"
}

echo -e "${green}运行中...${plain}"
install_base
update_x-ui $1
