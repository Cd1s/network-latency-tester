# shellcheck shell=bash
print_usage() {
    echo "网络延迟检测工具 - 使用说明"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --output-file <path>     指定输出文件路径"
    echo "  --no-output              禁用文件输出"
    echo "  --single-result-page     生成单页结果（HTML/Markdown）"
    echo "  --format <type>          输出格式: text/markdown/html/json"
    echo "  --help, -h               显示此帮助信息"
    echo ""
}

validate_output_format() {
    case "$1" in
        text|markdown|html|json) return 0 ;;
        *)
            echo "错误: 不支持的输出格式 '$1'，可选: text/markdown/html/json" >&2
            exit 1
            ;;
    esac
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --output-file)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "错误: --output-file 需要路径参数" >&2
                    exit 1
                fi
                OUTPUT_FILE="$2"
                ENABLE_OUTPUT=true
                # 根据文件扩展名自动检测格式
                case "$OUTPUT_FILE" in
                    *.md) OUTPUT_FORMAT="markdown" ;;
                    *.html) OUTPUT_FORMAT="html" ;;
                    *.json) OUTPUT_FORMAT="json" ;;
                    *) OUTPUT_FORMAT="text" ;;
                esac
                shift 2
                ;;
            --no-output)
                ENABLE_OUTPUT=false
                shift
                ;;
            --single-result-page)
                SINGLE_RESULT_PAGE=true
                shift
                ;;
            --format)
                if [[ $# -lt 2 || "$2" == --* ]]; then
                    echo "错误: --format 需要格式参数: text/markdown/html/json" >&2
                    exit 1
                fi
                validate_output_format "$2"
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                echo "未知参数: $1" >&2
                echo "使用 --help 查看帮助" >&2
                exit 1
                ;;
        esac
    done
}

# 生成输出文件

main() {
    # 检查依赖
    check_dependencies
    
    while true; do
        show_welcome
        show_menu
        
        # 读取用户输入，确保等待输入
        echo -n -e "${YELLOW}请选择 (0-6): ${NC}"
        read -r choice
        
        # 处理空输入
        if [ -z "$choice" ]; then
            continue
        fi
        
        case $choice in
            1)
                run_test
                ;;
            2)
                run_dns_test
                ;;
            3)
                run_comprehensive_test
                ;;
            4)
                run_ip_version_test
                ;;
            5)
                run_dns_management
                ;;
            6)
                run_output_settings
                ;;
            0)
                echo ""
                echo -e "${GREEN}👋 感谢使用网络延迟检测工具！${NC}"
                echo -e "${CYAN}🌟 项目地址: https://github.com/Cd1s/network-latency-tester${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ 无效选择，请输入 0-6${NC}"
                if [[ -t 0 ]]; then
                    echo -n -e "${YELLOW}按 Enter 键继续...${NC}"
                    read -r
                else
                    echo -e "${YELLOW}程序结束${NC}"
                    exit 1
                fi
                ;;
        esac
    done
}

# 结果文件输出设置

run_output_settings() {
    command clear 2>/dev/null || true
    show_welcome
    
    ui_section "结果文件输出设置"
    echo ""
    echo -e "${YELLOW}当前状态:${NC} $(if [[ "$ENABLE_OUTPUT" == "true" ]]; then echo -e "${GREEN}已启用${NC}"; else echo -e "${YELLOW}已禁用${NC}"; fi)"
    if [[ "$ENABLE_OUTPUT" == "true" ]] && [[ -n "$OUTPUT_FILE" ]]; then
        echo -e "${YELLOW}输出路径:${NC} $OUTPUT_FILE"
        echo -e "${YELLOW}输出格式:${NC} $OUTPUT_FORMAT"
    fi
    echo ""
    echo -e "${YELLOW}选择操作:${NC}"
    ui_menu_item "${GREEN}1${NC}" "启用结果文件输出"
    ui_menu_item "${GREEN}2${NC}" "禁用结果文件输出"
    ui_menu_item "${GREEN}3${NC}" "设置输出路径和格式"
    ui_menu_item "${RED}0${NC}" "返回主菜单"
    echo ""
    ui_prompt "请选择 (0-3): "
    read -r output_choice
    
    case $output_choice in
        1)
            ENABLE_OUTPUT=true
            if [[ -z "$OUTPUT_FILE" ]]; then
                OUTPUT_FILE="latency_results_$(date +%Y%m%d_%H%M%S).html"
                OUTPUT_FORMAT="html"
            fi
            echo ""
            ui_notice ok "已启用结果文件输出"
            ui_notice info "结果将保存到: $OUTPUT_FILE"
            echo ""
            ;;
        2)
            ENABLE_OUTPUT=false
            echo ""
            ui_output_disabled
            echo ""
            ;;
        3)
            echo ""
            echo -e "${YELLOW}选择输出格式:${NC}"
            ui_menu_item "${GREEN}1${NC}" "HTML格式" "推荐"
            ui_menu_item "${GREEN}2${NC}" "Markdown格式" "适合GitHub/文档"
            ui_menu_item "${GREEN}3${NC}" "纯文本格式"
            ui_menu_item "${GREEN}4${NC}" "JSON格式" "适合程序处理"
            echo ""
            ui_prompt "请选择格式 (1-4): "
            read -r format_choice
            
            local file_ext="html"
            case $format_choice in
                1) OUTPUT_FORMAT="html"; file_ext="html" ;;
                2) OUTPUT_FORMAT="markdown"; file_ext="md" ;;
                3) OUTPUT_FORMAT="text"; file_ext="txt" ;;
                4) OUTPUT_FORMAT="json"; file_ext="json" ;;
                *) OUTPUT_FORMAT="html"; file_ext="html" ;;
            esac
            
            OUTPUT_FILE="latency_results_$(date +%Y%m%d_%H%M%S).$file_ext"
            ENABLE_OUTPUT=true
            
            echo ""
            ui_notice ok "输出格式设置完成"
            ui_notice info "格式: $OUTPUT_FORMAT"
            ui_notice info "文件: $OUTPUT_FILE"
            echo ""
            ;;
        0)
            return
            ;;
        *)
            echo ""
            ui_notice error "无效选择"
            echo ""
            ;;
    esac
    
    ui_prompt "按 Enter 键返回主菜单..."
    read -r
}

# DNS设置管理功能
