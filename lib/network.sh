# shellcheck shell=bash
get_ping_cmd() {
    local version=${1:-"4"}  # 默认IPv4
    local host=$2
    
    if [[ "$version" == "6" ]]; then
        if command -v ping6 >/dev/null 2>&1; then
            echo "ping6"
        elif [[ "$OS_TYPE" == "linux" ]]; then
            echo "ping -6"
        elif [[ "$OS_TYPE" == "macos" ]]; then
            echo "ping6"
        else
            echo "ping -6"
        fi
    else
        if [[ "$OS_TYPE" == "linux" ]]; then
            echo "ping -4"
        else
            echo "ping"
        fi
    fi
}

# 获取适当的ping间隔参数

get_ping_interval() {
    if [[ "$OS_TYPE" == "macos" ]]; then
        echo ""  # macOS ping默认间隔1秒，不需要-i参数
    else
        echo "-i 0.5"  # Linux支持0.5秒间隔
    fi
}

ping_latency_summary() {
    local host="$1"
    local count="${2:-3}"
    local version="${3:-4}"
    local ping_cmd interval timeout_cmd ping_result avg_latency packet_loss

    ping_cmd=$(get_ping_cmd "$version" "$host")
    interval=$(get_ping_interval)
    timeout_cmd=$(get_timeout_cmd)

    if [[ -n "$timeout_cmd" ]]; then
        if [[ -n "$interval" ]]; then
            ping_result=$($timeout_cmd 10 $ping_cmd -c "$count" $interval "$host" 2>/dev/null || true)
        else
            ping_result=$($timeout_cmd 10 $ping_cmd -c "$count" "$host" 2>/dev/null || true)
        fi
    elif [[ -n "$interval" ]]; then
        ping_result=$($ping_cmd -c "$count" $interval "$host" 2>/dev/null || true)
    else
        ping_result=$($ping_cmd -c "$count" "$host" 2>/dev/null || true)
    fi

    avg_latency=$(echo "$ping_result" | sed -n 's/.*= [0-9.]*\/\([0-9.]*\)\/.*/\1/p' | head -n1)
    packet_loss=$(echo "$ping_result" | sed -n 's/.* \([0-9][0-9.]*\)% packet loss.*/\1/p' | head -n1)
    packet_loss=${packet_loss%.*}

    if [[ ! "$avg_latency" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        return 1
    fi

    printf '%s|%s\n' "$avg_latency" "${packet_loss:-0}"
}

# 获取超时命令

detect_proxy() {
    PROXY_DETECTED=false
    PROXY_REASON=""
    PROXY_SHARED_IP=""

    # 检测1: 环境变量代理
    if [[ -n "${http_proxy:-}${https_proxy:-}${all_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}" ]]; then
        PROXY_DETECTED=true
        PROXY_REASON="检测到代理环境变量 (http_proxy/https_proxy/all_proxy)"
        return
    fi

    # 检测2: 解析站点IP，检查同IP多域名和Fake-IP段
    local -A _proxy_ip_count
    local -A _proxy_ip_domains

    for service in "${!FULL_SITES[@]}"; do
        local host="${FULL_SITES[$service]}"
        [[ "$host" == "telegram_dc_test" ]] && continue
        [[ -z "$host" || "$host" == *".sh" || "$host" == ./* || "$host" == /* ]] && continue
        [[ "$host" == -* || "$host" =~ [[:space:]] ]] && continue

        local ip=""
        if command -v dig >/dev/null 2>&1; then
            ip=$(dig +short +time=2 +tries=1 +noedns "$host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
        fi
        if [[ -z "$ip" ]] && command -v nslookup >/dev/null 2>&1; then
            ip=$(nslookup "$host" 2>/dev/null | grep "Address:" | tail -n +2 | head -n1 | awk '{print $2}' | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
        fi

        [[ -z "$ip" ]] && continue

        # 检查Fake-IP段和非公网保留段
        if [[ "$ip" =~ ^198\.(18|19)\. ]] || \
           [[ "$ip" =~ ^10\. ]] || \
           [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] || \
           [[ "$ip" =~ ^192\.168\. ]] || \
           [[ "$ip" =~ ^127\. ]] || \
           [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] || \
           [[ "$ip" =~ ^169\.254\. ]] || \
           [[ "$ip" =~ ^0\. ]] || \
           [[ "$ip" =~ ^(192\.0\.0\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.) ]] || \
           [[ "$ip" =~ ^(22[4-9]|23[0-9]|24[0-9]|25[0-5])\. ]]; then
            PROXY_DETECTED=true
            PROXY_REASON="域名 ${host} 解析到内网/Fake-IP段 (${ip})"
            return
        fi

        # 统计同IP出现次数
        _proxy_ip_count["$ip"]=$(( ${_proxy_ip_count["$ip"]:-0} + 1 ))
        if [[ -n "${_proxy_ip_domains[$ip]:-}" ]]; then
            _proxy_ip_domains["$ip"]="${_proxy_ip_domains[$ip]}, ${service}"
        else
            _proxy_ip_domains["$ip"]="$service"
        fi
    done

    # 检查是否有>=3个不同域名解析到同一IP
    for ip in "${!_proxy_ip_count[@]}"; do
        if [[ ${_proxy_ip_count[$ip]} -ge 3 ]]; then
            PROXY_DETECTED=true
            PROXY_SHARED_IP="$ip"
            PROXY_REASON="多个不同域名解析到同一IP ${ip} (${_proxy_ip_domains[$ip]})"
            return
        fi
    done
}

# 解析命令行参数

test_batch_latency_fping() {
    local hosts=("$@")
    local temp_file
    local temp_results
    temp_file=$(register_temp)
    temp_results=$(register_temp)
    
    # 创建主机列表文件
    printf '%s\n' "${hosts[@]}" > "$temp_file"
    
    # 根据IP版本和系统选择fping命令
    local fping_cmd=""
    if command -v fping >/dev/null 2>&1; then
        if [[ "$IP_VERSION" == "6" ]]; then
            if command -v fping6 >/dev/null 2>&1; then
                fping_cmd="fping6"
            else
                fping_cmd="fping -6"
            fi
        elif [[ "$IP_VERSION" == "4" ]]; then
            fping_cmd="fping -4"
        else
            fping_cmd="fping"
        fi
        
        # 执行fping批量测试
        $fping_cmd -c $PING_COUNT -q -f "$temp_file" 2>"$temp_results" || true
    else
        # 如果没有fping，回退到标准ping
        while IFS= read -r host; do
            local summary avg_latency packet_loss
            summary=$(ping_latency_summary "$host" "$PING_COUNT" "$IP_VERSION" || true)
            IFS='|' read -r avg_latency packet_loss <<< "$summary"

            if [[ -n "$avg_latency" ]]; then
                echo "$host : $avg_latency ms, ${packet_loss:-0}% loss" >> "$temp_results"
            else
                echo "$host : timeout" >> "$temp_results"
            fi
        done < "$temp_file"
    fi
    
    # 清理临时文件
    rm -f "$temp_file"
    
    echo "$temp_results"
}

# 在快速 Ping 阶段测试 Telegram 并缓存结果

test_telegram_in_fping() {
    # 检查Python环境
    if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
        TELEGRAM_BEST_IP=""
        TELEGRAM_BEST_DC=""
        TELEGRAM_BEST_LATENCY="N/A"
        TELEGRAM_BEST_LOSS="0%"
        return
    fi
    
    local python_cmd="python3"
    if ! command -v python3 >/dev/null 2>&1; then
        python_cmd="python"
    fi
    
    # 获取所有Telegram DC节点IP
    local tg_nodes=$($python_cmd - <<'PYTHON_EOF'
import re
try:
    import urllib.request
    url = "https://core.telegram.org/getProxyConfig"
    data = urllib.request.urlopen(url, timeout=5).read().decode("utf-8")
    pattern = re.compile(r'proxy_for\s+(-?\d+)\s+([\d.]+):(\d+);')
    entries = pattern.findall(data)
    
    seen_ips = set()
    for dc, ip, port in entries:
        if ip not in seen_ips:
            dc_id = abs(int(dc))
            print(f"{ip}|DC{dc_id}")
            seen_ips.add(ip)
except:
    pass
PYTHON_EOF
)
    
    if [[ -z "$tg_nodes" ]]; then
        TELEGRAM_BEST_IP=""
        TELEGRAM_BEST_DC=""
        TELEGRAM_BEST_LATENCY="N/A"
        TELEGRAM_BEST_LOSS="0%"
        return
    fi
    
    # 提取所有IP并准备fping测试
    local ips=()
    declare -A ip_to_dc
    
    while IFS='|' read -r ip dc; do
        if [[ -n "$ip" ]]; then
            ips+=("$ip")
            ip_to_dc["$ip"]="$dc"
        fi
    done <<< "$tg_nodes"
    
    if [[ ${#ips[@]} -eq 0 ]]; then
        TELEGRAM_BEST_IP=""
        TELEGRAM_BEST_DC=""
        TELEGRAM_BEST_LATENCY="N/A"
        TELEGRAM_BEST_LOSS="0%"
        return
    fi
    
    # 优先使用 fping；未安装时使用系统 ping。
    local best_ip=""
    local best_latency=999999
    local best_dc=""
    local best_loss="0%"
    
    if command -v fping >/dev/null 2>&1; then
        local fping_output=$(fping -c 3 -t 1000 -q "${ips[@]}" 2>&1)
        
        for ip in "${ips[@]}"; do
            local result=$(echo "$fping_output" | grep "^$ip")
            if [[ -n "$result" ]]; then
                local avg=""
                local loss=""
                
                # 提取平均延迟
                if echo "$result" | grep -q "min/avg/max"; then
                    avg=$(echo "$result" | sed -n 's/.*min\/avg\/max = [0-9.]*\/\([0-9.]*\)\/.*/\1/p')
                else
                    avg=$(echo "$result" | sed -n 's/.*avg\/max = [0-9.]*\/[0-9.]*\/\([0-9.]*\).*/\1/p')
                fi
                
                # 提取丢包率
                if echo "$result" | grep -q "xmt/rcv"; then
                    local xmt=$(echo "$result" | sed -n 's/.*xmt\/rcv\/%loss = \([0-9]*\)\/.*/\1/p')
                    local rcv=$(echo "$result" | sed -n 's/.*xmt\/rcv\/%loss = [0-9]*\/\([0-9]*\)\/.*/\1/p')
                    if [[ -n "$xmt" && -n "$rcv" && $xmt -gt 0 ]]; then
                        local loss_num=$(( (xmt - rcv) * 100 / xmt ))
                        loss="${loss_num}%"
                    fi
                fi
                
                if [[ -n "$avg" ]]; then
                    local avg_int=${avg%.*}
                    if [[ $avg_int -lt $best_latency ]]; then
                        best_latency=$avg_int
                        best_ip="$ip"
                        best_dc="${ip_to_dc[$ip]}"
                        best_loss="${loss:-0%}"
                    fi
                fi
            fi
        done
    else
        local summary avg loss avg_int
        for ip in "${ips[@]}"; do
            summary=$(ping_latency_summary "$ip" 3 "4" || true)
            IFS='|' read -r avg loss <<< "$summary"

            if [[ "$avg" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                avg_int=${avg%.*}
                if [[ $avg_int -lt $best_latency ]]; then
                    best_latency=$avg_int
                    best_ip="$ip"
                    best_dc="${ip_to_dc[$ip]}"
                    best_loss="${loss:-0}%"
                fi
            fi
        done
    fi
    
    # 缓存结果
    if [[ -n "$best_ip" && $best_latency -lt 999999 ]]; then
        TELEGRAM_BEST_IP="$best_ip"
        TELEGRAM_BEST_DC="$best_dc"
        TELEGRAM_BEST_LATENCY="${best_latency}.0"
        TELEGRAM_BEST_LOSS="$best_loss"
    else
        TELEGRAM_BEST_IP=""
        TELEGRAM_BEST_DC=""
        TELEGRAM_BEST_LATENCY="N/A"
        TELEGRAM_BEST_LOSS="0%"
    fi
}

# 使用fping显示所有网站的快速延迟测试

show_fping_results() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}📡 快速Ping延迟测试${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    
    # 先测试Telegram获取最佳IP
    test_telegram_in_fping

    if ! command -v fping >/dev/null 2>&1; then
        echo -e "${YELLOW}💡 未安装 fping，跳过快速批量测试；后续真实连接测试将使用系统 ping${NC}"
        echo ""
        echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
        return
    fi
    
    # 收集所有主机
    local hosts=()
    local valid_hosts=()
    for service in "${!FULL_SITES[@]}"; do
        local host="${FULL_SITES[$service]}"
        # 过滤掉空值、脚本文件、本地路径
        # 移除可能的 ./ 前缀
        local clean_host="${host#./}"
        
        # 检查是否是有效的主机名或域名
        if [[ -n "$host" && 
              "$host" != "latency.sh" && 
              "$clean_host" != *".sh" && 
              "$host" != ./* && 
              "$host" != /* &&
              "$host" =~ ^[a-zA-Z0-9].*$ ]]; then
            hosts+=("$host")
            valid_hosts+=("$service|$host")
        fi
    done
    
    # 创建主机列表文件
    local temp_file
    local temp_results
    temp_file=$(register_temp)
    temp_results=$(register_temp)
    
    # 根据IP版本选择fping命令
    local fping_cmd=""
    local version_info=""
    
    echo -e "测试版本: "
    
    if [[ "$IP_VERSION" == "6" ]]; then
        echo -e "(IPv6优先) | 测试网站: ${#valid_hosts[@]}个"
        echo ""
        echo "⚡ 正在使用fping进行快速批量测试..."
        
        # IPv6模式：分别处理IPv6和IPv4主机
        local ipv6_hosts=()
        local ipv4_hosts=()
        
        echo -n "检测IPv6支持..."
        for host in "${hosts[@]}"; do
            # 快速检查是否有IPv6地址（dig内置超时1秒）
            if dig +short +time=1 +tries=1 AAAA "$host" 2>/dev/null | grep -q ":" ; then
                ipv6_hosts+=("$host")
            else
                # 没有IPv6则fallback到IPv4
                ipv4_hosts+=("$host")
            fi
        done
        echo " 完成 (IPv6: ${#ipv6_hosts[@]}个, IPv4: ${#ipv4_hosts[@]}个)"
        
        # 测试IPv6主机
        if [[ ${#ipv6_hosts[@]} -gt 0 ]]; then
            echo -n "测试IPv6主机..."
            for host in "${ipv6_hosts[@]}"; do
                echo "$host" >> "${temp_file}_v6"
            done
            
            if command -v fping6 >/dev/null 2>&1; then
                fping6 -c 10 -q -f "${temp_file}_v6" 2>"${temp_results}_v6" || true
            else
                fping -6 -c 10 -q -f "${temp_file}_v6" 2>"${temp_results}_v6" || true
            fi
            echo " 完成"
        fi
        
        # 测试IPv4主机（fallback）
        if [[ ${#ipv4_hosts[@]} -gt 0 ]]; then
            echo -n "测试IPv4主机 (fallback)..."
            for host in "${ipv4_hosts[@]}"; do
                echo "$host" >> "${temp_file}_v4"
            done
            fping -4 -c 10 -q -f "${temp_file}_v4" 2>"${temp_results}_v4" || true
            echo " 完成"
        fi
        
        # 合并结果
        cat "${temp_results}_v6" "${temp_results}_v4" 2>/dev/null > "$temp_results" || true
        rm -f "${temp_file}_v6" "${temp_file}_v4" "${temp_results}_v6" "${temp_results}_v4" 2>/dev/null
        
    elif [[ "$IP_VERSION" == "4" ]]; then
        echo -e "(IPv4) | 测试网站: ${#valid_hosts[@]}个"
        echo ""
        echo "⚡ 正在使用fping进行快速批量测试..."
        fping_cmd="fping -4"
        
        # IPv4模式：直接测试所有主机
        for host in "${hosts[@]}"; do
            echo "$host" >> "$temp_file"
        done
        $fping_cmd -c 10 -q -f "$temp_file" 2>"$temp_results" || true
        
    else
        echo -e "(Auto) | 测试网站: ${#valid_hosts[@]}个"
        echo ""
        echo "⚡ 正在使用fping进行快速批量测试..."
        fping_cmd="fping"
        
        # Auto模式：直接测试所有主机
        for host in "${hosts[@]}"; do
            echo "$host" >> "$temp_file"
        done
        $fping_cmd -c 10 -q -f "$temp_file" 2>"$temp_results" || true
    fi
    
    # 解析并显示结果
    if command -v fping >/dev/null 2>&1; then
        if [[ -s "$temp_results" ]]; then
            echo ""
            format_row "排名:4:right" "网站:14:left" "域名:20:left" "延迟:10:right" "丢包率:10:right"
            echo "───────────────────────────────────────────────────────────────────────────"
            
            local count=1
            declare -a results_array=()
            
            # 解析fping结果
            while IFS= read -r line; do
                if [[ "$line" =~ ([^[:space:]]+)[[:space:]]*:[[:space:]]*(.+) ]]; then
                    local host="${BASH_REMATCH[1]}"
                    local result="${BASH_REMATCH[2]}"
                    
                    # 查找对应的服务名
                    local service_name=""
                    for service in "${!FULL_SITES[@]}"; do
                        if [[ "${FULL_SITES[$service]}" == "$host" ]]; then
                            service_name="$service"
                            break
                        fi
                    done
                    
                    if [[ -z "$service_name" ]]; then
                        service_name="$host"
                    fi
                    
                    # 提取延迟和丢包率信息
                    local latency=""
                    local packet_loss="100%"
                    
                    if echo "$result" | grep -q "min/avg/max"; then
                        latency=$(echo "$result" | grep -o 'min/avg/max = [0-9.]*\/[0-9.]*\/[0-9.]*' | cut -d'=' -f2 | cut -d'/' -f2 | tr -d ' ')
                        # 提取丢包率 (格式: xmt/rcv/%loss = 10/10/0%)
                        if echo "$result" | grep -q "%loss"; then
                            packet_loss=$(echo "$result" | grep -o '%loss = [^,]*' | cut -d'=' -f2 | tr -d ' ' | cut -d'/' -f3)
                        else
                            packet_loss="0%"
                        fi
                        
                        if [[ -n "$latency" ]] && [[ "$latency" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                            results_array+=("$latency|$service_name|$host|$packet_loss")
                        else
                            results_array+=("999999|$service_name|$host|100%")
                        fi
                    else
                        results_array+=("999999|$service_name|$host|100%")
                    fi
                fi
            done < "$temp_results"
            
            # 排序结果（按延迟排序）
            IFS=$'\n' sorted_results=($(sort -t'|' -k1 -n <<< "${results_array[*]}"))
            
            # 显示排序后的结果
            for result in "${sorted_results[@]}"; do
                IFS='|' read -r latency service_name host packet_loss <<< "$result"
                if [[ "$latency" == "999999" ]]; then
                    echo -e "$(printf "%-15s %-20s %-25s" "$count." "$service_name" "$host") ${RED}超时/失败 ❌${NC}    ${RED}${packet_loss}${NC}"
                else
                    local latency_color=""
                    local loss_color=""
                    
                    # 延迟着色 (使用纯bash整数比较，兼容macOS和Linux)
                    local latency_int=$(echo "$latency" | cut -d'.' -f1)
                    if [[ "$latency_int" -lt 50 ]]; then
                        latency_color="${GREEN}"
                    elif [[ "$latency_int" -lt 150 ]]; then
                        latency_color="${YELLOW}"
                    else
                        latency_color="${RED}"
                    fi
                    
                    # 丢包率着色
                    local loss_num=$(echo "$packet_loss" | sed 's/%//')
                    if [[ "$loss_num" == "0" ]]; then
                        loss_color="${GREEN}"
                    elif [[ "$loss_num" -le "5" ]]; then
                        loss_color="${YELLOW}"
                    else
                        loss_color="${RED}"
                    fi
                    
                    # 格式化延迟显示 (兼容macOS和Linux)
                    local latency_display=""
                    if command -v bc >/dev/null 2>&1; then
                        latency_display=$(printf "%.1f" "$latency" 2>/dev/null || echo "$latency")
                    else
                        latency_display="$latency"
                    fi
                    
                    # 使用printf格式化，延迟右对齐8字符宽度（不含颜色代码）
                    local formatted_latency=$(printf "%8s" "${latency_display}ms")
                    echo -e "$(printf "%-15s %-20s %-25s" "$count." "$service_name" "$host") ${latency_color}${formatted_latency}${NC} ✅    ${loss_color}${packet_loss}${NC}"
                fi
                ((++count))
            done
            
            # 显示Telegram结果（如果已测试）
            if [[ -n "$TELEGRAM_BEST_IP" ]]; then
                local tg_latency_color=""
                local tg_latency_int=${TELEGRAM_BEST_LATENCY%.*}
                local tg_loss_color=""
                
                # 延迟着色
                if [[ "$tg_latency_int" -lt 50 ]]; then
                    tg_latency_color="${GREEN}"
                elif [[ "$tg_latency_int" -lt 150 ]]; then
                    tg_latency_color="${YELLOW}"
                else
                    tg_latency_color="${RED}"
                fi
                
                # 丢包率着色
                local tg_loss_num=$(echo "$TELEGRAM_BEST_LOSS" | sed 's/%//')
                if [[ "$tg_loss_num" == "0" ]]; then
                    tg_loss_color="${GREEN}"
                elif [[ "$tg_loss_num" -le "5" ]]; then
                    tg_loss_color="${YELLOW}"
                else
                    tg_loss_color="${RED}"
                fi
                
                # 使用printf格式化，延迟右对齐8字符宽度（与其他行一致）
                local tg_formatted_latency=$(printf "%8s" "${TELEGRAM_BEST_LATENCY}ms")
                echo -e "$(printf "%-15s %-20s %-25s" "$count." "Telegram" "Telegram_DC") ${tg_latency_color}${tg_formatted_latency}${NC} ✅    ${tg_loss_color}${TELEGRAM_BEST_LOSS}${NC}"
                ((++count))
            fi
        else
            echo "❌ fping测试失败或无结果"
        fi
    else
        echo "❌ fping命令不可用，跳过批量测试"
    fi
    
    # 清理临时文件
    rm -f "$temp_file" "$temp_results"
    
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

# 解析IPv6地址

get_ipv6_address() {
    local domain=$1
    local ipv6=""
    
    # 尝试使用dig获取IPv6
    if command -v dig >/dev/null 2>&1; then
        ipv6=$(dig +short AAAA "$domain" 2>/dev/null | grep -E '^[0-9a-f:]+$' | head -n1)
    fi
    
    # 如果dig失败，尝试使用nslookup
    if [ -z "$ipv6" ] && command -v nslookup >/dev/null 2>&1; then
        ipv6=$(nslookup -type=AAAA "$domain" 2>/dev/null | grep "Address:" | tail -n1 | awk '{print $2}' | grep -E '^[0-9a-f:]+$')
    fi
    
    echo "$ipv6"
}

# 获取域名的IP地址

get_ip_address() {
    local domain=$1
    local ip=""
    
    # 如果用户选择了特定的DNS服务器，使用该DNS服务器解析
    if [[ -n "$SELECTED_DNS_SERVER" && "$SELECTED_DNS_SERVER" != "system" ]]; then
        # 尝试使用dig获取IP（指定DNS服务器）
        if command -v dig >/dev/null 2>&1; then
            ip=$(dig +short @"$SELECTED_DNS_SERVER" "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        
        # 如果dig失败，尝试使用nslookup（指定DNS服务器）
        if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
            ip=$(nslookup "$domain" "$SELECTED_DNS_SERVER" 2>/dev/null | grep -A 1 "Name:" | grep "Address:" | head -n1 | awk '{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        fi
    else
        # 使用系统默认DNS或未选择DNS时的默认行为
        # 尝试使用dig获取IP
        if command -v dig >/dev/null 2>&1; then
            ip=$(dig +short "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        
        # 如果dig失败，尝试使用nslookup
        if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
            ip=$(nslookup "$domain" 2>/dev/null | grep -A 1 "Name:" | grep "Address:" | head -n1 | awk '{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        fi
    fi
    
    # 如果还是失败，尝试使用ping获取IP
    if [ -z "$ip" ]; then
        ip=$(ping -c 1 "$domain" 2>/dev/null | grep "PING" | sed -n 's/.*(\([0-9.]*\)).*/\1/p' | head -n1)
    fi
    
    echo "$ip"
}

# 测试DNS解析速度（支持测试多个域名）

test_packet_loss() {
    local host=$1
    local service=$2
    
    echo -n -e "📡 测试 ${CYAN}${service}${NC} 丢包率... "
    
    local ping_result
    local timeout_cmd=$(get_timeout_cmd)
    local ping_cmd=$(get_ping_cmd "4" "$host")
    local interval=$(get_ping_interval)
    
    if [[ -n "$timeout_cmd" ]]; then
        if [[ -n "$interval" ]]; then
            ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || echo "")
        else
            ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT "$host" 2>/dev/null || echo "")
        fi
    else
        # macOS没有timeout命令时，直接使用ping
        if [[ -n "$interval" ]]; then
            ping_result=$($ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || echo "")
        else
            ping_result=$($ping_cmd -c $PING_COUNT "$host" 2>/dev/null || echo "")
        fi
    fi
    
    if [ -n "$ping_result" ]; then
        # 提取丢包率
        local packet_loss
        packet_loss=$(echo "$ping_result" | grep "packet loss" | sed -n 's/.*\([0-9]\+\)% packet loss.*/\1/p')
        
        if [ -n "$packet_loss" ]; then
            if [ "$packet_loss" -eq 0 ]; then
                echo -e "${GREEN}${packet_loss}% 🟢${NC}"
            elif [ "$packet_loss" -lt 5 ]; then
                echo -e "${YELLOW}${packet_loss}% 🟡${NC}"
            else
                echo -e "${RED}${packet_loss}% 🔴${NC}"
            fi
            return "$packet_loss"
        else
            echo -e "${RED}无法检测 ❌${NC}"
            return 100
        fi
    else
        echo -e "${RED}测试失败 ❌${NC}"
        return 100
    fi
}

# 显示欢迎界面

test_tcp_latency() {
    local host=$1
    local port=$2
    local count=${3:-3}

    if [[ ! "$host" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || \
       [[ ! "$port" =~ ^[0-9]+$ ]] || \
       [[ $port -lt 1 || $port -gt 65535 ]]; then
        echo "999999"
        return
    fi

    local total_time=0
    local successful_connects=0

    for ((i=1; i<=count; i++)); do
        local start_time
        start_time=$(get_timestamp_ms)

        if command -v nc >/dev/null 2>&1; then
            if nc -z -w 5 "$host" "$port" 2>/dev/null; then
                local end_time
                end_time=$(get_timestamp_ms)
                local connect_time=$((end_time - start_time))
                total_time=$((total_time + connect_time))
                ((++successful_connects))
            fi
        else
            local timeout_cmd
            timeout_cmd=$(get_timeout_cmd)
            if [[ -n "$timeout_cmd" ]]; then
                if $timeout_cmd 5 bash -c "exec 3<>/dev/tcp/$host/$port 3<&- 3>&-" 2>/dev/null; then
                    local end_time
                    end_time=$(get_timestamp_ms)
                    local connect_time=$((end_time - start_time))
                    total_time=$((total_time + connect_time))
                    ((++successful_connects))
                fi
            fi
        fi
    done

    if [[ $successful_connects -gt 0 ]]; then
        echo $((total_time / successful_connects))
    else
        echo "999999"
    fi
}

# Telegram DC检测 - 使用官方API获取节点并测试TCP连接

test_telegram_connectivity() {
    local service=$1
    
    # 使用fping阶段缓存的最佳IP进行TCP连接测试
    if [[ -z "$TELEGRAM_BEST_IP" || "$TELEGRAM_BEST_LATENCY" == "N/A" ]]; then
        echo -n -e "🔍 ${CYAN}$(printf "%-12s" "$service")${NC} "
        echo -e "$(printf "%-8s %-15s %-8s" "IPv4" "N/A" "超时") ${RED}❌ 失败${NC}"
        RESULTS+=("$service|Telegram_DC|超时|失败|N/A|N/A|N/A|N/A")
        return
    fi
    
    # 使用TCP连接测试443端口（Telegram标准端口）
    echo -n -e "🔍 ${CYAN}$(printf "%-12s" "$service")${NC} "
    
    local tcp_latency=$(test_tcp_latency "$TELEGRAM_BEST_IP" 443 3)
    
    if [[ "$tcp_latency" != "999999" ]]; then
        local status_text=""
        local tcp_latency_int=${tcp_latency%.*}
        
        if [[ $tcp_latency_int -lt 50 ]]; then
            status_text="优秀"
            echo -e "$(printf "%-8s %-15s %-8s" "IPv4" "${TELEGRAM_BEST_IP}" "${tcp_latency}ms") ${GREEN}🟢 优秀${NC}"
        elif [[ $tcp_latency_int -lt 150 ]]; then
            status_text="良好"
            echo -e "$(printf "%-8s %-15s %-8s" "IPv4" "${TELEGRAM_BEST_IP}" "${tcp_latency}ms") ${YELLOW}🟡 良好${NC}"
        elif [[ $tcp_latency_int -lt 300 ]]; then
            status_text="一般"
            echo -e "$(printf "%-8s %-15s %-8s" "IPv4" "${TELEGRAM_BEST_IP}" "${tcp_latency}ms") ${PURPLE}⚠️  一般${NC}"
        else
            status_text="较差"
            echo -e "$(printf "%-8s %-15s %-8s" "IPv4" "${TELEGRAM_BEST_IP}" "${tcp_latency}ms") ${RED}❌ 较差${NC}"
        fi
        
        RESULTS+=("$service|Telegram_DC|${tcp_latency}ms|$status_text|$TELEGRAM_BEST_IP|N/A|0%|$TELEGRAM_BEST_DC")
    else
        echo -e "$(printf "%-8s %-15s %-8s" "IPv4" "${TELEGRAM_BEST_IP}" "超时") ${RED}❌ 失败${NC}"
        RESULTS+=("$service|Telegram_DC|超时|失败|$TELEGRAM_BEST_IP|N/A|N/A|$TELEGRAM_BEST_DC")
    fi
}

# 测试HTTP连接延迟
# 代理环境下使用TTFB(time_starttransfer)代替time_connect

test_http_latency() {
    local host=$1
    local count=${2:-3}
    
    local total_time=0
    local successful_requests=0
    
    local time_metric='%{time_connect}'
    if [[ "$PROXY_DETECTED" == "true" ]]; then
        time_metric='%{time_starttransfer}'
    fi
    
    for ((i=1; i<=count; i++)); do
        local timeout_cmd=$(get_timeout_cmd)
        local connect_time
        
        if [[ -n "$timeout_cmd" ]]; then
            connect_time=$($timeout_cmd 8 curl -o /dev/null -s -w "$time_metric" --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
        else
            connect_time=$(curl -o /dev/null -s -w "$time_metric" --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
        fi
        
        if [[ "$connect_time" =~ ^[0-9]+\.?[0-9]*$ ]] && [ "$(echo "$connect_time < 10" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
            local time_ms=$(echo "$connect_time * 1000" | bc -l 2>/dev/null | cut -d'.' -f1)
            total_time=$((total_time + time_ms))
            ((++successful_requests))
        fi
    done
    
    if [ $successful_requests -gt 0 ]; then
        echo $((total_time / successful_requests))
    else
        echo "999999"
    fi
}

# 将延迟毫秒值转换为现有报告状态标签

latency_status_from_ms() {
    local latency_ms="$1"
    local latency_int="${latency_ms%.*}"

    if [[ ! "$latency_int" =~ ^[0-9]+$ ]]; then
        echo "失败"
    elif [[ "$latency_int" -lt 50 ]]; then
        echo "优秀"
    elif [[ "$latency_int" -lt 150 ]]; then
        echo "良好"
    elif [[ "$latency_int" -lt 500 ]]; then
        echo "较差"
    else
        echo "很差"
    fi
}

telegram_latency_record() {
    local service="$1"

    if [[ -z "$TELEGRAM_BEST_IP" || "$TELEGRAM_BEST_LATENCY" == "N/A" ]]; then
        printf '%s|Telegram_DC|超时|失败|N/A|N/A|N/A|N/A\n' "$service"
        return
    fi

    local tcp_latency
    tcp_latency=$(test_tcp_latency "$TELEGRAM_BEST_IP" 443 3)

    if [[ "$tcp_latency" != "999999" ]]; then
        local status_text
        status_text=$(latency_status_from_ms "$tcp_latency")
        printf '%s|Telegram_DC|%sms|%s|%s|N/A|0%%|%s\n' "$service" "$tcp_latency" "$status_text" "$TELEGRAM_BEST_IP" "$TELEGRAM_BEST_DC"
    else
        printf '%s|Telegram_DC|超时|失败|%s|N/A|N/A|%s\n' "$service" "$TELEGRAM_BEST_IP" "$TELEGRAM_BEST_DC"
    fi
}

site_latency_record() {
    local host=$1
    local service=$2

    local test_version="4"
    local version_label="IPv4"
    local target_ip=""
    local ip_addr=""
    local ipv6_addr=""

    if [[ "$IP_VERSION" == "6" ]]; then
        ipv6_addr=$(get_ipv6_address "$host")
        if [[ -n "$ipv6_addr" && "$ipv6_addr" != "N/A" ]]; then
            test_version="6"
            version_label="IPv6"
            target_ip="$ipv6_addr"
        else
            test_version="4"
            version_label="IPv4(fallback)"
            ip_addr=$(get_ip_address "$host")
            target_ip="$ip_addr"
        fi
    elif [[ "$IP_VERSION" == "4" ]]; then
        test_version="4"
        version_label="IPv4"
        ip_addr=$(get_ip_address "$host")
        target_ip="$ip_addr"
    else
        test_version="4"
        version_label="IPv4"
        ip_addr=$(get_ip_address "$host")
        target_ip="$ip_addr"
    fi

    local ping_result=""
    local ping_ms=""
    local latency_ms=""
    local packet_loss=0
    local timeout_cmd
    timeout_cmd=$(get_timeout_cmd)

    if command -v fping >/dev/null 2>&1; then
        local fping_cmd=""
        if [[ "$test_version" == "6" && -n "$ipv6_addr" ]]; then
            if command -v fping6 >/dev/null 2>&1; then
                fping_cmd="fping6"
            else
                fping_cmd="fping -6"
            fi
        elif [[ "$test_version" == "4" && -n "$ip_addr" ]]; then
            fping_cmd="fping -4"
        else
            fping_cmd="fping"
        fi

        if [[ -n "$timeout_cmd" ]]; then
            ping_result=$($timeout_cmd 15 $fping_cmd -c "$PING_COUNT" -q "$host" 2>&1 || true)
        else
            ping_result=$($fping_cmd -c "$PING_COUNT" -q "$host" 2>&1 || true)
        fi

        if [[ -n "$ping_result" ]]; then
            if echo "$ping_result" | grep -q "avg"; then
                ping_ms=$(echo "$ping_result" | grep -o '[0-9.]*ms' | head -n1 | sed 's/ms//')
            else
                ping_ms=$(echo "$ping_result" | grep -o '[0-9.]*\/[0-9.]*\/[0-9.]*' | cut -d'/' -f2 || echo "")
            fi

            if echo "$ping_result" | grep -q "loss"; then
                packet_loss=$(echo "$ping_result" | grep -o '[0-9]*% loss' | sed 's/% loss//' || echo "0")
            else
                packet_loss=$(echo "$ping_result" | grep -o '[0-9]*%' | sed 's/%//' || echo "0")
            fi

            if [[ "$ping_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                latency_ms="$ping_ms"
            fi
        fi
    else
        local ping_cmd
        local interval
        ping_cmd=$(get_ping_cmd "$test_version" "$host")
        interval=$(get_ping_interval)

        if [[ -n "$timeout_cmd" ]]; then
            if [[ -n "$interval" ]]; then
                ping_result=$($timeout_cmd 15 $ping_cmd -c "$PING_COUNT" $interval "$host" 2>/dev/null || true)
            else
                ping_result=$($timeout_cmd 15 $ping_cmd -c "$PING_COUNT" "$host" 2>/dev/null || true)
            fi
        else
            if [[ -n "$interval" ]]; then
                ping_result=$($ping_cmd -c "$PING_COUNT" $interval "$host" 2>/dev/null || true)
            else
                ping_result=$($ping_cmd -c "$PING_COUNT" "$host" 2>/dev/null || true)
            fi
        fi

        if [[ -n "$ping_result" ]]; then
            if [[ "$OS_TYPE" == "macos" ]]; then
                ping_ms=$(echo "$ping_result" | grep 'round-trip' | cut -d'=' -f2 | cut -d'/' -f2 2>/dev/null || echo "")
            else
                ping_ms=$(echo "$ping_result" | grep 'rtt min/avg/max/mdev' | cut -d'/' -f5 | cut -d' ' -f1 2>/dev/null || echo "")
            fi
            packet_loss=$(echo "$ping_result" | grep -o '[0-9]*% packet loss' | sed 's/% packet loss//' 2>/dev/null || echo "0")
            if [[ "$ping_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                latency_ms="$ping_ms"
            fi
        fi
    fi

    if [[ -z "$latency_ms" ]]; then
        case "$service" in
            "Netflix"|"NodeSeek")
                local connect_time
                local curl_metric='%{time_connect}'
                if [[ "$PROXY_DETECTED" == "true" ]]; then
                    curl_metric='%{time_starttransfer}'
                fi
                if [[ -n "$timeout_cmd" ]]; then
                    connect_time=$($timeout_cmd 8 curl -o /dev/null -s -w "$curl_metric" --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
                else
                    connect_time=$(curl -o /dev/null -s -w "$curl_metric" --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
                fi
                if [[ "$connect_time" =~ ^[0-9]+\.?[0-9]*$ ]] && (( $(awk "BEGIN {print ($connect_time < 10)}" 2>/dev/null || echo 0) )); then
                    latency_ms="$(awk "BEGIN {printf \"%d.0\", $connect_time * 1000}" 2>/dev/null || echo "")"
                fi
                ;;
            *)
                local http_latency
                http_latency=$(test_http_latency "$host" 2)
                if [[ "$http_latency" != "999999" ]]; then
                    latency_ms="$http_latency.0"
                fi
                ;;
        esac
    fi

    local result_ipv4="N/A"
    local result_ipv6="N/A"
    if [[ "$test_version" == "6" ]]; then
        result_ipv6="${ipv6_addr:-N/A}"
    elif [[ "$test_version" == "4" ]]; then
        result_ipv4="${ip_addr:-N/A}"
    fi

    if [[ -n "$latency_ms" && "$latency_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        local status
        status=$(latency_status_from_ms "$latency_ms")
        packet_loss="${packet_loss:-0}"
        printf '%s|%s|%sms|%s|%s|%s|%s%%|%s\n' "$service" "$host" "$latency_ms" "$status" "$result_ipv4" "$result_ipv6" "$packet_loss" "$version_label"
        return
    fi

    local curl_success=false
    if [[ -n "$timeout_cmd" ]]; then
        if $timeout_cmd 5 curl -s --connect-timeout 3 "https://$host" >/dev/null 2>&1; then
            curl_success=true
        fi
    else
        if curl -s --max-time 5 --connect-timeout 3 "https://$host" >/dev/null 2>&1; then
            curl_success=true
        fi
    fi

    if $curl_success; then
        printf '%s|%s|连通|连通但测不出延迟|%s|%s|N/A|%s\n' "$service" "$host" "$result_ipv4" "$result_ipv6" "$version_label"
    else
        printf '%s|%s|超时|失败|N/A|N/A|N/A|%s\n' "$service" "$host" "$version_label"
    fi
}

site_latency_record_worker() {
    local item="$1"
    local out="$2"
    local log="$3"
    local order service host
    IFS='|' read -r order service host <<< "$item"

    {
        if [[ "$host" == "telegram_dc_test" ]]; then
            printf '%s|' "$order"
            telegram_latency_record "$service"
        else
            printf '%s|' "$order"
            site_latency_record "$host" "$service"
        fi
    } > "$out" 2>"$log" || {
        printf '%s|%s|%s|超时|失败|N/A|N/A|N/A|IPv4\n' "$order" "$service" "$host" > "$out"
    }
}

collect_parallel_site_results() {
    local jobs=()
    local order=0
    local service

    while IFS= read -r service; do
        [[ -z "$service" ]] && continue
        ((++order))
        jobs+=("$order|$service|${FULL_SITES[$service]}")
    done < <(printf '%s\n' "${!FULL_SITES[@]}" | LC_ALL=C sort)

    RESULTS=()
    parallel_run_records site_latency_record_worker "真实连接测试" "${jobs[@]}"

    local ordered_records=()
    local i
    for i in "${!jobs[@]}"; do
        local job="${jobs[$i]}"
        local out="${PARALLEL_OUTPUT_FILES[$i]:-}"
        local job_order job_service job_host
        IFS='|' read -r job_order job_service job_host <<< "$job"

        if [[ -n "$out" && -s "$out" ]]; then
            local line
            line=$(head -n1 "$out")
            if [[ "$line" == "$job_order|"* ]]; then
                ordered_records+=("$line")
            else
                ordered_records+=("$job_order|$job_service|$job_host|超时|失败|N/A|N/A|N/A|IPv4")
            fi
        else
            ordered_records+=("$job_order|$job_service|$job_host|超时|失败|N/A|N/A|N/A|IPv4")
        fi
    done

    local record
    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        RESULTS+=("${record#*|}")
    done < <(printf '%s\n' "${ordered_records[@]}" | LC_ALL=C sort -t'|' -k1,1n)
}

# 测试单个网站延迟（跨平台兼容的fping优化）

test_site_latency() {
    local host=$1
    local service=$2
    local show_ip=${3:-true}
    
    # 确定要测试的IP版本并显示相应提示
    local test_version="4"  # 默认IPv4
    local version_label="IPv4"
    local target_ip=""
    local fallback_needed=false
    
    if [[ "$IP_VERSION" == "6" ]]; then
        # IPv6优先：先尝试IPv6，如果没有则fallback到IPv4
        ipv6_addr=$(get_ipv6_address "$host")
        if [[ -n "$ipv6_addr" && "$ipv6_addr" != "N/A" ]]; then
            test_version="6"
            version_label="IPv6"
            target_ip="$ipv6_addr"
        else
            # IPv6不可用，fallback到IPv4
            test_version="4"
            version_label="IPv4(fallback)"
            ip_addr=$(get_ip_address "$host")
            target_ip="$ip_addr"
            fallback_needed=true
        fi
    elif [[ "$IP_VERSION" == "4" ]]; then
        test_version="4" 
        version_label="IPv4"
        ip_addr=$(get_ip_address "$host")
        target_ip="$ip_addr"
    else
        # 自动选择：优先IPv4，如果IPv4不可用则使用IPv6
        test_version="4"
        version_label="IPv4"
        ip_addr=$(get_ip_address "$host")
        target_ip="$ip_addr"
    fi
    
    echo -n -e "🔍 ${CYAN}$(printf "%-12s" "$service")${NC} "
    
    local ping_result=""
    local ping_ms=""
    local status=""
    local latency_ms=""
    local packet_loss=0
    
    # 使用fping进行测试（如果可用且跨平台兼容）
    if command -v fping >/dev/null 2>&1; then
        local fping_cmd=""
        local timeout_cmd=$(get_timeout_cmd)
        
        if [[ "$test_version" == "6" ]] && [[ -n "$ipv6_addr" ]]; then
            if command -v fping6 >/dev/null 2>&1; then
                fping_cmd="fping6"
            else
                fping_cmd="fping -6"
            fi
            if [[ -n "$timeout_cmd" ]]; then
                ping_result=$($timeout_cmd 15 $fping_cmd -c $PING_COUNT -q "$host" 2>&1 || true)
            else
                ping_result=$($fping_cmd -c $PING_COUNT -q "$host" 2>&1 || true)
            fi
        elif [[ "$test_version" == "4" ]] && [[ -n "$ip_addr" ]]; then
            fping_cmd="fping -4"
            if [[ -n "$timeout_cmd" ]]; then
                ping_result=$($timeout_cmd 15 $fping_cmd -c $PING_COUNT -q "$host" 2>&1 || true)
            else
                ping_result=$($fping_cmd -c $PING_COUNT -q "$host" 2>&1 || true)
            fi
        else
            # 如果指定版本的IP不可用，回退到默认fping
            if [[ -n "$timeout_cmd" ]]; then
                ping_result=$($timeout_cmd 15 fping -c $PING_COUNT -q "$host" 2>&1 || true)
            else
                ping_result=$(fping -c $PING_COUNT -q "$host" 2>&1 || true)
            fi
        fi
        
        if [[ -n "$ping_result" ]]; then
            # 解析fping结果 - 兼容不同版本的fping输出格式
            if echo "$ping_result" | grep -q "avg"; then
                ping_ms=$(echo "$ping_result" | grep -o '[0-9.]*ms' | head -n1 | sed 's/ms//')
            else
                ping_ms=$(echo "$ping_result" | grep -o '[0-9.]*\/[0-9.]*\/[0-9.]*' | cut -d'/' -f2 || echo "")
            fi
            
            # 提取丢包率
            if echo "$ping_result" | grep -q "loss"; then
                packet_loss=$(echo "$ping_result" | grep -o '[0-9]*% loss' | sed 's/% loss//' || echo "0")
            else
                packet_loss=$(echo "$ping_result" | grep -o '[0-9]*%' | sed 's/%//' || echo "0")
            fi
            
            if [[ "$ping_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                latency_ms="$ping_ms"
            fi
        fi
    else
        # 回退到标准ping（跨平台兼容）
        local ping_cmd=$(get_ping_cmd "$test_version" "$host")
        local interval=$(get_ping_interval)
        local timeout_cmd=$(get_timeout_cmd)
        
        if [[ -n "$timeout_cmd" ]]; then
            if [[ -n "$interval" ]]; then
                ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || true)
            else
                ping_result=$($timeout_cmd 15 $ping_cmd -c $PING_COUNT "$host" 2>/dev/null || true)
            fi
        else
            # macOS没有timeout命令时，直接使用ping
            if [[ -n "$interval" ]]; then
                ping_result=$($ping_cmd -c $PING_COUNT $interval "$host" 2>/dev/null || true)
            else
                ping_result=$($ping_cmd -c $PING_COUNT "$host" 2>/dev/null || true)
            fi
        fi
        
        if [[ -n "$ping_result" ]]; then
            # 兼容不同系统的ping输出格式
            if [[ "$OS_TYPE" == "macos" ]]; then
                ping_ms=$(echo "$ping_result" | grep 'round-trip' | cut -d'=' -f2 | cut -d'/' -f2 2>/dev/null || echo "")
            else
                ping_ms=$(echo "$ping_result" | grep 'rtt min/avg/max/mdev' | cut -d'/' -f5 | cut -d' ' -f1 2>/dev/null || echo "")
            fi
            
            # 提取丢包率
            packet_loss=$(echo "$ping_result" | grep -o '[0-9]*% packet loss' | sed 's/% packet loss//' 2>/dev/null || echo "0")
            
            if [[ "$ping_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                latency_ms="$ping_ms"
            fi
        fi
    fi
    
    # 如果ping失败，尝试HTTP连接测试
    if [[ -z "$latency_ms" ]]; then
        case "$service" in
            "Telegram")
                local tcp_latency=$(test_tcp_latency "$host" 443 2)
                if [[ "$tcp_latency" != "999999" ]]; then
                    latency_ms="$tcp_latency.0"
                fi
                ;;
            "Netflix"|"NodeSeek")
                local timeout_cmd=$(get_timeout_cmd)
                local connect_time
                local _curl_metric='%{time_connect}'
                if [[ "$PROXY_DETECTED" == "true" ]]; then
                    _curl_metric='%{time_starttransfer}'
                fi
                
                if [[ -n "$timeout_cmd" ]]; then
                    connect_time=$($timeout_cmd 8 curl -o /dev/null -s -w "$_curl_metric" --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
                else
                    connect_time=$(curl -o /dev/null -s -w "$_curl_metric" --max-time 6 --connect-timeout 4 "https://$host" 2>/dev/null || echo "999")
                fi
                
                if [[ "$connect_time" =~ ^[0-9]+\.?[0-9]*$ ]] && (( $(echo "$connect_time < 10" | bc -l 2>/dev/null || echo 0) )); then
                    local time_ms=$(echo "$connect_time * 1000" | bc -l 2>/dev/null | cut -d'.' -f1)
                    latency_ms="$time_ms.0"
                fi
                ;;
            *)
                local http_latency=$(test_http_latency "$host" 2)
                if [[ "$http_latency" != "999999" ]]; then
                    latency_ms="$http_latency.0"
                fi
                ;;
        esac
    fi
    
    # 根据延迟结果显示状态
    if [[ -n "$latency_ms" ]] && [[ "$latency_ms" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        local latency_int=$(echo "$latency_ms" | cut -d'.' -f1)
        
        # 构建状态信息
        local loss_info=""
        if [[ "$packet_loss" -gt 0 ]]; then
            loss_info=" 丢包${packet_loss}%"
        fi
        
        # 只显示实际测试的IP版本信息
        local ip_display=""
        if [[ "$test_version" == "6" ]] && [[ -n "$ipv6_addr" ]]; then
            ip_display="${ipv6_addr}"
        elif [[ "$test_version" == "4" ]] && [[ -n "$ip_addr" ]]; then
            ip_display="${ip_addr}"
        elif [[ -n "$target_ip" ]]; then
            ip_display="${target_ip}"
        else
            ip_display="N/A"
        fi
        
        if [[ "$latency_int" -lt 50 ]]; then
            status="优秀"
            echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${GREEN}🟢 优秀${NC}"
        elif [[ "$latency_int" -lt 150 ]]; then
            status="良好"
            echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${YELLOW}🟡 良好${NC}"
        elif [[ "$latency_int" -lt 500 ]]; then
            status="较差"
            echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${RED}🔴 较差${NC}"
        else
            status="很差"
            echo -e "$(printf "%-8s %-15s %-8s" "${version_label}" "${ip_display}" "${latency_ms}ms") ${RED}💀 很差${NC}"
        fi
        
        # 根据实际测试的版本存储相应的IP地址信息
        local result_ipv4="N/A"
        local result_ipv6="N/A"
        
        if [[ "$test_version" == "6" ]]; then
            result_ipv6="${ipv6_addr:-N/A}"
        elif [[ "$test_version" == "4" ]]; then
            result_ipv4="${ip_addr:-N/A}"
        fi
        
        RESULTS+=("$service|$host|${latency_ms}ms|$status|$result_ipv4|$result_ipv6|${packet_loss}%|${version_label}")
    else
        # 最后尝试简单连通性测试
        local timeout_cmd=$(get_timeout_cmd)
        local curl_success=false
        
        if [[ -n "$timeout_cmd" ]]; then
            if $timeout_cmd 5 curl -s --connect-timeout 3 "https://$host" >/dev/null 2>&1; then
                curl_success=true
            fi
        else
            # macOS没有timeout时，使用curl自带的超时
            if curl -s --max-time 5 --connect-timeout 3 "https://$host" >/dev/null 2>&1; then
                curl_success=true
            fi
        fi
        
        if $curl_success; then
            status="连通但测不出延迟"
            local ip_display=""
            if [[ "$test_version" == "6" ]] && [[ -n "$ipv6_addr" ]]; then
                ip_display="${ipv6_addr}"
            elif [[ "$test_version" == "4" ]] && [[ -n "$ip_addr" ]]; then
                ip_display="${ip_addr}"
            elif [[ -n "$target_ip" ]]; then
                ip_display="${target_ip}"
            else
                ip_display="N/A"
            fi
            printf "%-8s %-15s %-8s %s连通%s\n" "${version_label}" "${ip_display}" "N/A" "${YELLOW}🟡 " "${NC}"
            
            local result_ipv4="N/A"
            local result_ipv6="N/A"
            if [[ "$test_version" == "6" ]]; then
                result_ipv6="${ipv6_addr:-N/A}"
            elif [[ "$test_version" == "4" ]]; then
                result_ipv4="${ip_addr:-N/A}"
            fi
            
            RESULTS+=("$service|$host|连通|连通但测不出延迟|$result_ipv4|$result_ipv6|N/A|${version_label}")
        else
            status="失败"
            printf "%-8s %-15s %-8s %s失败%s\n" "${version_label}" "N/A" "超时" "${RED}❌ " "${NC}"
            RESULTS+=("$service|$host|超时|失败|N/A|N/A|N/A|${version_label}")
        fi
    fi
}

# 执行完整网站测试

run_test() {
    command clear 2>/dev/null || true
    show_welcome
    
    echo -e "${CYAN}🌐 开始Ping/真连接测试 (${#FULL_SITES[@]}个网站)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "测试参数: ${YELLOW}${#FULL_SITES[@]}个网站${NC} | Ping次数: ${YELLOW}${PING_COUNT}${NC}"
    if [ -n "$IP_VERSION" ]; then
        echo -e "IP版本: ${YELLOW}IPv${IP_VERSION}优先${NC}"
    fi
    if [[ -n "$SELECTED_DNS_SERVER" && "$SELECTED_DNS_SERVER" != "system" ]]; then
        echo -e "DNS解析: ${YELLOW}${SELECTED_DNS_NAME} (${SELECTED_DNS_SERVER})${NC}"
    else
        echo -e "DNS解析: ${YELLOW}系统默认${NC}"
    fi
    
    # 代理/VPN检测
    echo -n -e "${CYAN}🔍 检测网络环境...${NC} "
    detect_proxy
    if [[ "$PROXY_DETECTED" == "true" ]]; then
        echo -e "${YELLOW}检测到代理/VPN${NC}"
        echo ""
        echo -e "${YELLOW}⚠️  代理/VPN环境提示:${NC}"
        echo -e "${YELLOW}   ${PROXY_REASON}${NC}"
        echo -e "${YELLOW}   真实连接延迟将使用TTFB(首字节时间)作为端到端体验延迟指标${NC}"
        echo -e "${YELLOW}   如需测试直连延迟，请关闭代理后重试${NC}"
        echo ""
    else
        echo -e "${GREEN}直连环境${NC}"
    fi
    
    # 第一步：使用fping进行快速批量测试
    show_fping_results
    
    echo ""
    echo -e "${CYAN}🔗 开始真实连接延迟测试...${NC}"
    if [[ "$PROXY_DETECTED" == "true" ]]; then
        echo -e "${YELLOW}   (代理环境: 延迟为端到端TTFB体验延迟，非直连延迟)${NC}"
    fi
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 重置结果数组
    RESULTS=()
    local start_time=$(date +%s)
    
    collect_parallel_site_results
    
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    
    # 显示结果
    show_results "$total_time"
}

# DNS服务器延迟测试（fping批量测所有DNS服务器的延迟）

run_ip_version_test() {
    command clear 2>/dev/null || true
    show_welcome
    
    ui_section "IPv4/IPv6优先设置"
    echo ""
    echo -e "${YELLOW}说明: 这只是测试时的IP协议优先设置，不会更改系统网络配置${NC}"
    echo ""
    echo -e "${YELLOW}选择测试协议优先级:${NC}"
    ui_menu_item "${GREEN}1${NC}" "IPv4优先测试" "优先使用IPv4地址"
    ui_menu_item "${GREEN}2${NC}" "IPv6优先测试" "优先使用IPv6地址"
    ui_menu_item "${GREEN}3${NC}" "自动选择" "系统默认"
    ui_menu_item "${GREEN}4${NC}" "查看当前设置"
    ui_menu_item "${RED}0${NC}" "返回主菜单"
    echo ""
    
    # 显示当前设置
    case $IP_VERSION in
        "4")
            ui_notice info "当前设置: IPv4优先"
            ;;
        "6")
            ui_notice info "当前设置: IPv6优先"
            ;;
        "")
            ui_notice info "当前设置: 自动选择"
            ;;
    esac
    echo ""
    
    ui_prompt "请选择 (0-4): "
    read -r ip_choice
    
    case $ip_choice in
        1)
            IP_VERSION="4"
            ui_notice ok "已设置为IPv4优先模式"
            ui_notice warn "设置已保存，返回主菜单后可进行测试"
            sleep 2
            run_ip_version_test
            ;;
        2)
            IP_VERSION="6"
            ui_notice ok "已设置为IPv6优先模式"
            ui_notice warn "设置已保存，返回主菜单后可进行测试"
            sleep 2
            run_ip_version_test
            ;;
        3)
            IP_VERSION=""
            ui_notice ok "已设置为自动选择模式"
            ui_notice warn "设置已保存，返回主菜单后可进行测试"
            sleep 2
            run_ip_version_test
            ;;
        4)
            echo ""
            ui_section "当前IP协议设置详情"
            case $IP_VERSION in
                "4")
                    echo -e "优先级: ${GREEN}IPv4优先${NC}"
                    echo -e "说明: 测试时优先尝试IPv4地址连接"
                    ;;
                "6")
                    echo -e "优先级: ${GREEN}IPv6优先${NC}"
                    echo -e "说明: 测试时优先尝试IPv6地址连接"
                    ;;
                "")
                    echo -e "优先级: ${GREEN}自动选择${NC}"
                    echo -e "说明: 使用系统默认IP协议栈"
                    ;;
            esac
            echo ""
            ui_prompt "按 Enter 键继续..."
            read -r
            run_ip_version_test
            ;;
        0)
            return
            ;;
        *)
            ui_notice error "无效选择"
            sleep 2
            run_ip_version_test
            ;;
    esac
}
# 综合测试模式
