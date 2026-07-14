# shellcheck shell=bash
register_temp() {
    local f
    f=$(mktemp 2>/dev/null) || f=$(mktemp -t latency_XXXXXX)
    _TEMP_FILES+=("$f")
    echo "$f"
}

# 全局退出清理

cleanup() {
    for f in "${_TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null
    done
    for f in "${_TEMP_DIRS[@]}"; do
        rm -rf "$f" 2>/dev/null
    done
    rm -f /tmp/fping_*_$$ /tmp/download_*_$$ /tmp/dns_*_$$ /tmp/result_*_$$ 2>/dev/null
}
trap cleanup EXIT

# 浮点转 MB/s（优先用 awk，无 bc 时降级）

to_mb() {
    local bytes=$1
    awk "BEGIN {printf \"%.2f\", $bytes / 1048576}" 2>/dev/null || \
    echo "scale=2; $bytes / 1048576" | bc -l 2>/dev/null || echo "0"
}

# 获取毫秒时间戳的跨平台函数

get_timestamp_ms() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import time; print(int(time.time() * 1000))"
    elif command -v python >/dev/null 2>&1; then
        python -c "import time; print(int(time.time() * 1000))"
    elif [[ "$(uname)" == "Darwin" ]]; then
        # macOS fallback: 使用秒*1000
        echo $(($(date +%s) * 1000))
    else
        # Linux with nanosecond support
        local ns=$(date +%s%N 2>/dev/null)
        if [[ "$ns" =~ N$ ]]; then
            # %N not supported, use seconds
            echo $(($(date +%s) * 1000))
        else
            echo $((ns / 1000000))
        fi
    fi
}

# 计算字符串显示宽度（考虑中文字符占2个位置）

detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS_TYPE="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="macos"
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "cygwin" ]] || [[ -n "$WSL_DISTRO_NAME" ]]; then
        OS_TYPE="wsl"
    else
        OS_TYPE="unknown"
    fi
}

# 获取适当的ping命令和参数

get_timeout_cmd() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        # macOS可能需要安装coreutils或使用其他方法
        if command -v gtimeout >/dev/null 2>&1; then
            echo "gtimeout"
        else
            echo ""  # 返回空表示不使用timeout
        fi
    else
        if command -v timeout >/dev/null 2>&1; then
            echo "timeout"
        else
            echo ""
        fi
    fi
}

detect_os

# 依赖检测辅助函数

dependency_is_missing() {
    local expected="$1"
    shift

    local dependency
    for dependency in "$@"; do
        if [[ "$dependency" == "$expected" ]]; then
            return 0
        fi
    done

    return 1
}

run_package_command() {
    local description="$1"
    shift

    if "$@" >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}⚠️  ${description}失败${NC}"
    return 1
}

check_dependencies() {
    echo -e "${CYAN}🔧 检查系统依赖...${NC}"
    echo -e "系统类型: ${YELLOW}$OS_TYPE${NC} | Bash版本: ${YELLOW}${BASH_VERSION%%.*}${NC}"
    
    local missing_deps=()
    local install_cmd=""
    
    # 检测系统类型和包管理器
    if command -v apt-get >/dev/null 2>&1; then
        install_cmd="apt-get"
    elif command -v yum >/dev/null 2>&1; then
        install_cmd="yum"
    elif command -v dnf >/dev/null 2>&1; then
        install_cmd="dnf"
    elif command -v apk >/dev/null 2>&1; then
        install_cmd="apk"
    elif command -v brew >/dev/null 2>&1; then
        install_cmd="brew"
    elif command -v pacman >/dev/null 2>&1; then
        install_cmd="pacman"
    fi
    
    # 检查必要的依赖
    if ! command -v ping >/dev/null 2>&1; then
        missing_deps+=("ping")
    fi
    
    if ! command -v curl >/dev/null 2>&1; then
        missing_deps+=("curl")
    fi
    
    if ! command -v bc >/dev/null 2>&1; then
        missing_deps+=("bc")
    fi
    
    # nslookup通常是内置的，但检查一下
    if ! command -v nslookup >/dev/null 2>&1; then
        missing_deps+=("nslookup")
    fi
    
    # timeout命令检查（某些系统可能没有）
    if ! command -v timeout >/dev/null 2>&1; then
        if [[ "$OS_TYPE" == "macos" ]]; then
            echo -e "${YELLOW}💡 macOS建议安装coreutils以获得timeout命令: brew install coreutils${NC}"
        fi
    fi
    
    # fping是可选的，但强烈推荐
    if ! command -v fping >/dev/null 2>&1; then
        echo -e "${YELLOW}💡 建议安装 fping 以获得更好的性能${NC}"
    fi
    
    # 如果有缺失的依赖，尝试自动安装
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${YELLOW}⚠️  发现缺失依赖: ${missing_deps[*]}${NC}"
        
        if [ -n "$install_cmd" ] && [ "$(id -u)" = "0" ]; then
            echo -e "${CYAN}🚀 正在自动安装依赖...${NC}"
            
            case $install_cmd in
                "apt-get")
                    run_package_command "更新 APT 软件包索引" apt-get update -qq || true
                    if dependency_is_missing "ping" "${missing_deps[@]}"; then
                        run_package_command "安装 ping" apt-get install -y iputils-ping || true
                    fi
                    if dependency_is_missing "curl" "${missing_deps[@]}"; then
                        run_package_command "安装 curl" apt-get install -y curl || true
                    fi
                    if dependency_is_missing "bc" "${missing_deps[@]}"; then
                        run_package_command "安装 bc" apt-get install -y bc || true
                    fi
                    if dependency_is_missing "nslookup" "${missing_deps[@]}"; then
                        run_package_command "安装 nslookup" apt-get install -y dnsutils || true
                    fi
                    ;;
                "yum"|"dnf")
                    if dependency_is_missing "ping" "${missing_deps[@]}"; then
                        run_package_command "安装 ping" "$install_cmd" install -y iputils || true
                    fi
                    if dependency_is_missing "curl" "${missing_deps[@]}"; then
                        run_package_command "安装 curl" "$install_cmd" install -y curl || true
                    fi
                    if dependency_is_missing "bc" "${missing_deps[@]}"; then
                        run_package_command "安装 bc" "$install_cmd" install -y bc || true
                    fi
                    if dependency_is_missing "nslookup" "${missing_deps[@]}"; then
                        run_package_command "安装 nslookup" "$install_cmd" install -y bind-utils || true
                    fi
                    ;;
                "apk")
                    run_package_command "更新 APK 软件包索引" apk update || true
                    if dependency_is_missing "ping" "${missing_deps[@]}"; then
                        run_package_command "安装 ping" apk add iputils || true
                    fi
                    if dependency_is_missing "curl" "${missing_deps[@]}"; then
                        run_package_command "安装 curl" apk add curl || true
                    fi
                    if dependency_is_missing "bc" "${missing_deps[@]}"; then
                        run_package_command "安装 bc" apk add bc || true
                    fi
                    if dependency_is_missing "nslookup" "${missing_deps[@]}"; then
                        run_package_command "安装 nslookup" apk add bind-tools || true
                    fi
                    ;;
                "brew")
                    if dependency_is_missing "curl" "${missing_deps[@]}"; then
                        run_package_command "安装 curl" brew install curl || true
                    fi
                    if dependency_is_missing "bc" "${missing_deps[@]}"; then
                        run_package_command "安装 bc" brew install bc || true
                    fi
                    # macOS通常已有ping和nslookup
                    ;;
                "pacman")
                    if dependency_is_missing "ping" "${missing_deps[@]}"; then
                        run_package_command "安装 ping" pacman -S --noconfirm iputils || true
                    fi
                    if dependency_is_missing "curl" "${missing_deps[@]}"; then
                        run_package_command "安装 curl" pacman -S --noconfirm curl || true
                    fi
                    if dependency_is_missing "bc" "${missing_deps[@]}"; then
                        run_package_command "安装 bc" pacman -S --noconfirm bc || true
                    fi
                    if dependency_is_missing "nslookup" "${missing_deps[@]}"; then
                        run_package_command "安装 nslookup" pacman -S --noconfirm bind-tools || true
                    fi
                    ;;
            esac
            
            # 再次检查安装结果
            local still_missing=()
            for dep in "${missing_deps[@]}"; do
                case $dep in
                    "ping")
                        if ! command -v ping >/dev/null 2>&1; then
                            still_missing+=("ping")
                        fi
                        ;;
                    "curl")
                        if ! command -v curl >/dev/null 2>&1; then
                            still_missing+=("curl")
                        fi
                        ;;
                    "bc")
                        if ! command -v bc >/dev/null 2>&1; then
                            still_missing+=("bc")
                        fi
                        ;;
                    "nslookup")
                        if ! command -v nslookup >/dev/null 2>&1; then
                            still_missing+=("nslookup")
                        fi
                        ;;
                esac
            done
            
            if [ ${#still_missing[@]} -eq 0 ]; then
                echo -e "${GREEN}✅ 所有依赖安装成功！${NC}"
            else
                echo -e "${RED}❌ 部分依赖安装失败: ${still_missing[*]}${NC}"
                show_manual_install_instructions
                return 1
            fi
            
        else
            echo -e "${RED}❌ 无法自动安装依赖${NC}"
            if [ "$(id -u)" != "0" ]; then
                echo -e "${YELLOW}💡 提示: 请使用 root 权限运行脚本以自动安装依赖${NC}"
            fi
            show_manual_install_instructions
            return 1
        fi
    else
        echo -e "${GREEN}✅ 所有必要依赖已安装${NC}"
    fi
    
    echo ""
}

# 显示手动安装说明

show_manual_install_instructions() {
    echo ""
    echo -e "${CYAN}📝 手动安装说明:${NC}"
    echo ""
    echo "🐧 Ubuntu/Debian:"
    echo "   sudo apt update && sudo apt install curl iputils-ping bc dnsutils fping"
    echo ""
    echo "🎩 CentOS/RHEL/Fedora:"
    echo "   sudo yum install curl iputils bc bind-utils fping"
    echo "   # 或者: sudo dnf install curl iputils bc bind-utils fping"
    echo ""
    echo "🏔️  Alpine Linux:"
    echo "   sudo apk update && sudo apk add curl iputils bc bind-tools fping"
    echo ""
    echo "🍎 macOS:"
    echo "   brew install curl bc fping"
    echo "   # ping 和 nslookup 通常已预装"
    echo ""
}

# 主循环

trap cleanup EXIT
