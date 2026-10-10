#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# 颜色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# 固定官方版本与校验值，避免在低内存机器上调用包管理器或现场编译。
SINGBOX_VERSION="1.13.12"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_BIN_SRC="${SINGBOX_BIN_SRC:-/root/sing-box}"
SINGBOX_TMP=""
SINGBOX_STAGE=""
SINGBOX_SERVICE_WAS_RUNNING="0"

cleanup() {
    [ -z "$SINGBOX_STAGE" ] || rm -f -- "$SINGBOX_STAGE"
    [ -z "$SINGBOX_TMP" ] || rm -rf -- "$SINGBOX_TMP"
    if [ "$SINGBOX_SERVICE_WAS_RUNNING" = "1" ]; then
        if command -v rc-service >/dev/null 2>&1; then
            rc-service sing-box status >/dev/null 2>&1 || rc-service sing-box start >/dev/null 2>&1 || true
        elif command -v systemctl >/dev/null 2>&1; then
            systemctl is-active --quiet sing-box || systemctl start sing-box >/dev/null 2>&1 || true
        fi
    fi
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限运行"
        err "请使用: sudo bash -c \"\$(curl -fsSL ...)\" 或切换到 root 用户"
        exit 1
    fi
}

check_root

quiesce_existing_service() {
    # 先释放旧 sing-box 进程占用的内存，给依赖检查和安装过程留出空间。
    if command -v rc-service >/dev/null 2>&1 && rc-service sing-box status >/dev/null 2>&1; then
        info "停止现有 sing-box 服务以释放安装内存..."
        SINGBOX_SERVICE_WAS_RUNNING="1"
        rc-service sing-box stop
    elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet sing-box; then
        info "停止现有 sing-box 服务以释放安装内存..."
        SINGBOX_SERVICE_WAS_RUNNING="1"
        systemctl stop sing-box
    fi
}

quiesce_existing_service

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."
    
    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc || {
                err "依赖安装失败"
                exit 1
            }
            
            # 确保 OpenRC 运行
            if ! rc-service --list 2>/dev/null | grep -q "^openrc"; then
                rc-update add openrc boot >/dev/null 2>&1 || true
                rc-service openrc start >/dev/null 2>&1 || true
            fi
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        *)
            warn "未识别的系统类型，尝试继续..."
            ;;
    esac
    
    info "依赖安装完成"
}

install_deps

for required_cmd in awk curl sha256sum tar; do
    command -v "$required_cmd" >/dev/null 2>&1 || {
        err "缺少安装所需命令: $required_cmd"
        exit 1
    }
done

# -----------------------
# 端口和密码输入（支持环境变量）
get_config() {
    # 支持通过环境变量传参，方便自动化部署
    if [ -n "${SINGBOX_PORT:-}" ]; then
        PORT="$SINGBOX_PORT"
        info "使用环境变量端口: $PORT"
    else
        echo ""
        read -p "请输入端口（留空则随机 10000-60000）: " USER_PORT
        if [ -z "$USER_PORT" ]; then
            PORT=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)))
            info "使用随机端口: $PORT"
        else
            if ! [[ "$USER_PORT" =~ ^[0-9]+$ ]] || [ "$USER_PORT" -lt 1 ] || [ "$USER_PORT" -gt 65535 ]; then
                err "端口必须为 1-65535 的数字"
                exit 1
            fi
            PORT="$USER_PORT"
        fi
    fi

    if [ -n "${SINGBOX_PASSWORD:-}" ]; then
        USER_PWD="$SINGBOX_PASSWORD"
        info "使用环境变量密码"
    else
        echo ""
        read -p "请输入密码（留空则自动生成 Base64 密钥）: " USER_PWD
    fi
}

get_config

# -----------------------
# 安装官方 sing-box musl 二进制
install_singbox() {
    local machine arch expected_archive expected_binary archive_name archive_url archive_dir archive_path actual existing_bin candidate memory_limit

    info "开始安装官方 sing-box v${SINGBOX_VERSION} musl 二进制..."

    # 检查是否已安装
    if [ -x "$SINGBOX_BIN" ] || command -v sing-box >/dev/null 2>&1; then
        existing_bin="$SINGBOX_BIN"
        [ -x "$existing_bin" ] || existing_bin=$(command -v sing-box)
        CURRENT_VERSION=$("$existing_bin" version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        read -p "是否用官方 musl 二进制重新安装？(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "已取消安装，未修改配置和服务"
            exit 0
        fi
    fi

    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)
            arch="amd64"
            expected_archive="43258b1c8ae25c01f41135056a2b6fb464329ded344658a2a68a852113b7ea63"
            expected_binary="2b41c625ef6e21bda71e435abab9c74e831e2fe81800f05322fa149737fa663e"
            ;;
        aarch64|arm64)
            arch="arm64"
            expected_archive="23b814f5416d379b9d67eef3605b45280376267b39517c35d20957eb1e53376b"
            expected_binary="c524021b02327693631f4c054303da8f900b9d1858976a0213c7b8067cc6f736"
            ;;
        i386|i486|i586|i686)
            arch="386"
            expected_archive="051974e725608d9cfebd6b0903aa6bded9e6df4fe0931fedc37bfae51a0f751f"
            expected_binary="5852ac2370f5b4bb39bc1fc7ca5f343671c0be4ed207910d005a1b111743716c"
            ;;
        armv7|armv7l)
            arch="armv7"
            expected_archive="b1699052ec047c5dee0474c8107e7dd9ebf69948e43e044ce132e836040b8cc2"
            expected_binary="e6d8efb79e4e88a35b974ee42539a1a826317e802a4e3ec307765eb8fbbdbc14"
            ;;
        *)
            err "暂不支持此 CPU 架构: $machine"
            exit 1
            ;;
    esac

    # 降低当前安装脚本和 SSH 守护进程被 OOM killer 优先终止的概率。
    printf '%s\n' -1000 > "/proc/$$/oom_score_adj" 2>/dev/null || true
    if command -v pgrep >/dev/null 2>&1; then
        while IFS= read -r ssh_pid; do
            [ -z "$ssh_pid" ] || printf '%s\n' -1000 > "/proc/${ssh_pid}/oom_score_adj" 2>/dev/null || true
        done < <(pgrep -x sshd 2>/dev/null || true)
    fi

    if [ -f "$SINGBOX_BIN_SRC" ]; then
        info "使用已上传的 musl 二进制: $SINGBOX_BIN_SRC"
        actual=$(sha256sum "$SINGBOX_BIN_SRC" | awk '{print $1}')
        [ "$actual" = "$expected_binary" ] || {
            err "上传的二进制 SHA-256 不匹配，请确认版本和 CPU 架构"
            exit 1
        }
        candidate="$SINGBOX_BIN_SRC"
    else
        memory_limit=""
        if [ -r /sys/fs/cgroup/memory.max ]; then
            memory_limit=$(cat /sys/fs/cgroup/memory.max)
        elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
            memory_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)
        fi
        case "$memory_limit" in
            ''|max|*[!0-9]*) ;;
            *)
                if [ "$memory_limit" -le 100663296 ]; then
                    err "检测到内存限制不超过 96 MiB，服务器端解压可能触发 OOM。"
                    err "请先在本地解压 ${SINGBOX_VERSION} 的 ${arch} musl 包，并上传二进制到 $SINGBOX_BIN_SRC。"
                    exit 1
                fi
                ;;
        esac

        # 内存充足时才允许服务器下载并解压官方发布包。
        mkdir -p /var/tmp
        SINGBOX_TMP=$(mktemp -d /var/tmp/singbox-musl.XXXXXX)
        archive_name="sing-box-${SINGBOX_VERSION}-linux-${arch}-musl.tar.gz"
        archive_url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${archive_name}"
        archive_dir="sing-box-${SINGBOX_VERSION}-linux-${arch}-musl"
        archive_path="${SINGBOX_TMP}/${archive_name}"

        info "下载 ${archive_name}..."
        curl --fail --location --retry 3 --connect-timeout 15 \
            --proto '=https' --tlsv1.2 \
            --output "$archive_path" "$archive_url" || {
            err "musl 二进制下载失败，请检查网络连接"
            exit 1
        }

        actual=$(sha256sum "$archive_path" | awk '{print $1}')
        [ "$actual" = "$expected_archive" ] || {
            err "压缩包 SHA-256 校验失败，已拒绝安装"
            exit 1
        }

        tar -tzf "$archive_path" "${archive_dir}/sing-box" >/dev/null 2>&1 || {
            err "发布包内未找到 sing-box 二进制"
            exit 1
        }
        info "校验通过，正在解压二进制..."
        tar -xzf "$archive_path" -C "$SINGBOX_TMP" "${archive_dir}/sing-box"
        candidate="${SINGBOX_TMP}/${archive_dir}/sing-box"
        actual=$(sha256sum "$candidate" | awk '{print $1}')
        [ "$actual" = "$expected_binary" ] || {
            err "解压后的二进制 SHA-256 校验失败"
            exit 1
        }
    fi

    chmod 0755 "$candidate"
    env GOMEMLIMIT=32MiB GOGC=25 "$candidate" version | grep -F "sing-box version ${SINGBOX_VERSION}" >/dev/null || {
        err "二进制版本验证失败"
        exit 1
    }

    mkdir -p "$(dirname "$SINGBOX_BIN")"
    SINGBOX_STAGE="${SINGBOX_BIN}.$$.new"
    cp "$candidate" "$SINGBOX_STAGE"
    chmod 0755 "$SINGBOX_STAGE"
    mv -f "$SINGBOX_STAGE" "$SINGBOX_BIN"
    SINGBOX_STAGE=""

    INSTALLED_VERSION=$(env GOMEMLIMIT=32MiB GOGC=25 "$SINGBOX_BIN" version 2>/dev/null | head -1 || echo "unknown")
    info "sing-box 安装成功: $INSTALLED_VERSION"
}

install_singbox

# -----------------------
# 生成密码
KEY_BYTES=16
METHOD="2022-blake3-aes-128-gcm"

generate_psk() {
    if [ -n "${USER_PWD:-}" ]; then
        PSK="$USER_PWD"
        info "使用指定密码"
    else
        info "自动生成密码..."
        
        # 优先使用 sing-box
        if [ -x "$SINGBOX_BIN" ]; then
            PSK=$(env GOMEMLIMIT=32MiB GOGC=25 "$SINGBOX_BIN" generate rand --base64 "$KEY_BYTES" 2>/dev/null | tr -d '\n\r' || true)
        fi
        
        # 备选: openssl
        if [ -z "${PSK:-}" ] && command -v openssl >/dev/null 2>&1; then
            PSK=$(openssl rand -base64 "$KEY_BYTES" | tr -d '\n\r')
        fi
        
        # 最后备选: /dev/urandom
        if [ -z "${PSK:-}" ]; then
            PSK=$(head -c "$KEY_BYTES" /dev/urandom | base64 | tr -d '\n\r')
        fi
        
        if [ -z "${PSK:-}" ]; then
            err "密码生成失败"
            exit 1
        fi
        
        info "密码生成成功"
    fi
}

generate_psk

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"
    
    mkdir -p "$(dirname "$CONFIG_PATH")"
    
    cat > "$CONFIG_PATH" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "listen": "::",
      "listen_port": $PORT,
      "method": "$METHOD",
      "password": "$PSK",
      "tag": "ss2022-in"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
EOF

    # 验证配置
    if [ -x "$SINGBOX_BIN" ]; then
        if env GOMEMLIMIT=32MiB GOGC=25 "$SINGBOX_BIN" check -c "$CONFIG_PATH" >/dev/null 2>&1; then
            info "配置文件验证通过"
        else
            warn "配置文件验证失败，但将继续..."
        fi
    fi
}

create_config

# -----------------------
# 设置服务
setup_service() {
    info "配置系统服务..."
    
    if [ "$OS" = "alpine" ]; then
        # Alpine OpenRC 服务
        SERVICE_PATH="/etc/init.d/sing-box"
        
        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"
export GOMEMLIMIT="32MiB"
export GOGC="25"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}

start_post() {
    sleep 1
    if [ -f "$pidfile" ]; then
        einfo "Sing-box started successfully (PID: $(cat $pidfile))"
    else
        ewarn "Sing-box may not have started correctly"
    fi
}
OPENRC
        
        chmod +x "$SERVICE_PATH"
        
        # 添加到开机自启
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        
        # 启动服务
        rc-service sing-box restart || {
            err "服务启动失败，查看日志："
            tail -20 /var/log/sing-box.err 2>/dev/null || tail -20 /var/log/sing-box.log 2>/dev/null || true
            exit 1
        }
        
        sleep 2
        
        if rc-service sing-box status >/dev/null 2>&1; then
            info "✅ OpenRC 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
        
    else
        # Systemd 服务
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        
        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Environment=GOMEMLIMIT=32MiB
Environment=GOGC=25
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD
        
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败，查看日志："
            journalctl -u sing-box -n 30 --no-pager
            exit 1
        }
        
        sleep 2
        
        if systemctl is-active sing-box >/dev/null 2>&1; then
            info "✅ Systemd 服务已启动"
        else
            err "服务状态异常"
            systemctl status sing-box --no-pager
            exit 1
        fi
    fi
    
    info "服务配置完成: $SERVICE_PATH"
}

setup_service

# -----------------------
# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
    warn "无法获取公网 IP，请手动替换"
else
    info "检测到公网 IP: $PUB_IP"
fi

# -----------------------
# 生成 SS URI
generate_uri() {
    local host="$PUB_IP"
    local tag="singbox-ss2022"
    local userinfo="${METHOD}:${PSK}"
    
    # SIP002 格式 (URL编码)
    local encoded_userinfo
    if command -v python3 >/dev/null 2>&1; then
        encoded_userinfo=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$userinfo', safe=''))" 2>/dev/null || echo "$userinfo")
    else
        encoded_userinfo=$(printf "%s" "$userinfo" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
    fi
    
    # Base64 格式
    local base64_userinfo=$(printf "%s" "$userinfo" | base64 -w0 2>/dev/null || printf "%s" "$userinfo" | base64 | tr -d '\n')
    
    echo "ss://${encoded_userinfo}@${host}:${PORT}#${tag}"
    echo "ss://${base64_userinfo}@${host}:${PORT}#${tag}"
}

# -----------------------
# 最终输出
echo ""
echo "=========================================="
info "🎉 Sing-box 部署完成！"
echo "=========================================="
echo ""
info "📋 配置信息："
echo "   端口: $PORT"
echo "   方法: $METHOD"
echo "   密码: $PSK"
echo "   服务器: $PUB_IP"
echo ""
info "📁 文件位置："
echo "   配置: $CONFIG_PATH"
echo "   服务: $SERVICE_PATH"
echo ""
info "🔗 客户端链接："
generate_uri | while IFS= read -r line; do
    echo "   $line"
done
echo ""
info "🔧 管理命令："
if [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    echo "   日志: tail -f /var/log/sing-box.log"
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    echo "   日志: journalctl -u sing-box -f"
fi
echo ""
echo "=========================================="
