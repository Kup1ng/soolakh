#!/bin/bash
SCRIPT_VERSION="v1"
service_dir="/etc/systemd/system"
config_dir="/root/soolakh-core"
CERT_DIR="/root/soolakh-core/cert_files"
CERT_FILE="$CERT_DIR/cert.crt"
KEY_FILE="$CERT_DIR/cert.key"
mkdir -p "$CERT_DIR"
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    sleep 1
    exit 1
fi
colorize() {
    local color="$1"
    local text="$2"
    local style="${3:-normal}"
    local black="\033[30m" red="\033[31m" green="\033[32m" yellow="\033[33m"
    local blue="\033[34m" magenta="\033[35m" cyan="\033[36m" white="\033[37m"
    local gray="\033[90m" bcyan="\033[96m" bgreen="\033[92m" bmagenta="\033[95m"
    local reset="\033[0m" normal="\033[0m" bold="\033[1m" underline="\033[4m"
    local color_code
    case $color in
        black) color_code=$black ;; red) color_code=$red ;;
        green) color_code=$green ;; yellow) color_code=$yellow ;;
        blue) color_code=$blue ;; magenta) color_code=$magenta ;;
        cyan) color_code=$cyan ;; white) color_code=$white ;;
        gray | grey) color_code=$gray ;; bcyan) color_code=$bcyan ;;
        bgreen) color_code=$bgreen ;; bmagenta) color_code=$bmagenta ;;
        *) color_code=$reset ;;
    esac
    local style_code
    case $style in
        bold) style_code=$bold ;; underline) style_code=$underline ;;
        normal | *) style_code=$normal ;;
    esac
    echo -e "${style_code}${color_code}${text}${reset}"
}
UI_WIDTH=58
hr() {
    local color="${1:-blue}"
    local char="${2:-─}"
    local line
    printf -v line '%*s' "$UI_WIDTH" ''
    line=${line// /"$char"}
    colorize "$color" "$line"
}
section() {
    local title="$1"
    local line
    printf -v line '%*s' "$((UI_WIDTH - 2))" ''
    line=${line// /─}
    echo
    printf '  \033[1;96m◆\033[0m \033[1;97m%s\033[0m\n' "$title"
    printf '  \033[36m%s\033[0m\n' "$line"
}
ok()   { printf '  \033[1;92m✔\033[0m  \033[32m%s\033[0m\n' "$1"; }
err()  { printf '  \033[1;91m✖\033[0m  \033[31m%s\033[0m\n' "$1"; }
warn() { printf '  \033[1;93m▲\033[0m  \033[33m%s\033[0m\n' "$1"; }
info() { printf '  \033[1;96m•\033[0m  \033[36m%s\033[0m\n' "$1"; }
hint() { printf '     \033[90m%s\033[0m\n' "$1"; }
menu_item() {
    local num="$1" label="$2" color="${3:-white}"
    printf '   \033[1;95m[%s]\033[0m \033[90m›\033[0m ' "$num"
    colorize "$color" "$label"
}
press_key() {
    echo
    read -r -p $'\033[90m   Press Enter to continue...\033[0m'
}
prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local input
    echo -ne "[-] $prompt (default: $default): "
    read -r input
    eval "$var_name=\"${input:-$default}\""
}
prompt_boolean() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    while true; do
        prompt_with_default "$prompt [true/false]" "$default" "$var_name"
        local value="${!var_name}"
        if [[ "$value" == "true" || "$value" == "false" ]]; then
            break
        fi
        colorize red "Invalid input. Please enter 'true' or 'false'."
    done
}
validate_cidr() {
    local cidr="$1"
    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
        return 1
    fi
    IFS='/' read -r ip mask <<<"$cidr"
    IFS='.' read -r a b c d <<<"$ip"
    if ((a < 0 || a > 255 || b < 0 || b > 255 || c < 0 || c > 255 || d < 0 || d > 255)); then
        return 1
    fi
    if ((mask < 1 || mask > 32)); then
        return 1
    fi
    local ip_int=$(((a << 24) | (b << 16) | (c << 8) | d))
    local mask_int
    if ((mask == 32)); then
        mask_int=0xFFFFFFFF
    else
        mask_int=$(((0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF))
    fi
    local net_int=$((ip_int & mask_int))
    local broadcast_int=$((net_int | (~mask_int & 0xFFFFFFFF)))
    if ((ip_int == net_int)); then
        return 1
    fi
    if ((ip_int == broadcast_int)); then
        return 1
    fi
    return 0
}
validate_ipv4() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    IFS='.' read -r a b c d <<<"$ip"
    if ((a < 0 || a > 255 || b < 0 || b > 255 || c < 0 || c > 255 || d < 0 || d > 255)); then
        return 1
    fi
    return 0
}
install_jq() {
    if ! command -v jq &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            colorize yellow "Installing jq..."
            sudo apt-get update && sudo apt-get install -y jq
        else
            colorize red "Error: Unsupported package manager. Please install jq manually."
            press_key
            exit 1
        fi
    fi
}
download_and_extract_soolakh() {
    if [[ "$1" == "menu" ]]; then
        rm -rf "${config_dir}/soolakh_premium" >/dev/null 2>&1
        colorize cyan "Restart all services after updating to new core" bold
        sleep 2
    fi
    [[ -f "${config_dir}/soolakh_premium" ]] && return 1
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            PRIMARY_URL="https://raw.githubusercontent.com/Kup1ng/soolakh/main/soolakh_premium_amd64.tar.gz"
            ;;
        arm64 | aarch64)
            PRIMARY_URL="https://raw.githubusercontent.com/Kup1ng/soolakh/main/soolakh_premium_arm64.tar.gz"
            ;;
        *)
            colorize red "Unsupported architecture: $ARCH."
            exit 1
            ;;
    esac
    DOWNLOAD_DIR=$(mktemp -d)
    echo "Downloading Soolakh..."
    if ! curl -sSL --max-time 30 -o "$DOWNLOAD_DIR/soolakh.tar.gz" "$PRIMARY_URL"; then
        colorize red "Download failed."
        rm -rf "$DOWNLOAD_DIR"
        exit 1
    fi
    mkdir -p "$config_dir"
    tar -xzf "$DOWNLOAD_DIR/soolakh.tar.gz" -C "$config_dir"
    chmod u+x "${config_dir}/soolakh_premium"
    ok "Soolakh installation completed."
}
install_jq
download_and_extract_soolakh
declare -A CONFIG
reset_config() {
    CONFIG=()
}
prompt_connection_section() {
    local mode="$1" # server or client
    section "Connection Configuration"
    if [[ "$mode" == "server" ]]; then
        prompt_with_default "Bind Address" ":8443" CONFIG[bind_addr]
        if [[ -n "${CONFIG[bind_addr]}" && "${CONFIG[bind_addr]}" != *:* ]]; then
            CONFIG[bind_addr]=":${CONFIG[bind_addr]}"
        fi
    else
        while true; do
            echo -ne "[*] IRAN Server Address [IP:Port] or [Domain:Port]: "
            read -r CONFIG[remote_addr]
            if [[ -z "${CONFIG[remote_addr]}" ]]; then
                colorize red "Server address cannot be empty."
                continue
            fi
            if [[ "${CONFIG[remote_addr]}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ||
                "${CONFIG[remote_addr]}" =~ ^[a-zA-Z0-9.-]+:[0-9]{1,5}$ ]]; then
                break
            else
                colorize red "Invalid format. Use IP:Port or Domain:Port."
            fi
        done
        if [[ "${CONFIG[transport_type]}" == "ws" || "${CONFIG[transport_type]}" == "wss" || "${CONFIG[transport_type]}" == "wsmux" || "${CONFIG[transport_type]}" == "wssmux" || "${CONFIG[transport_type]}" == "xwsmux" ]]; then
            echo -ne "[-] Edge IP/Domain (optional, press Enter to skip): "
            read -r CONFIG[edge_ip]
        fi
        CONFIG[dial_timeout]="10"
        CONFIG[retry_interval]="3"
    fi
    echo ""
}
VALID_ALGORITHMS=("aes-256-gcm" "chacha20-poly1305" "aes-128-gcm")
is_valid_algorithm() {
    local input="$1"
    for alg in "${VALID_ALGORITHMS[@]}"; do
        if [[ "$input" == "$alg" ]]; then
            return 0
        fi
    done
    return 1
}
prompt_security_section() {
    local is_ipx="$1"
    section "Security Configuration"
    if [[ "$is_ipx" == "true" ]]; then
        prompt_boolean "Enable Encryption" "true" CONFIG[enable_encryption]
        if [[ "${CONFIG[enable_encryption]}" == "true" ]]; then
            echo
            while true; do
                colorize magenta "Available algorithms: aes-256-gcm, chacha20-poly1305, aes-128-gcm"
                prompt_with_default "Algorithm" "aes-256-gcm" CONFIG[algorithm]
                if is_valid_algorithm "${CONFIG[algorithm]}"; then
                    break
                else
                    colorize red "Invalid algorithm selected. Please choose one from the list."
                    echo
                fi
            done
            prompt_with_default "PSK (32-char base64)" "pN9m6m0tH3nE3V8xKZ6Lq5yYcW2K1S7QG9u4cF0A8M4=" CONFIG[psk]
            prompt_with_default "KDF Iterations" "100000" CONFIG[kdf_iterations]
        fi
    else
        prompt_with_default "Security Token" "your_token" CONFIG[token]
        CONFIG[enable_encryption]="false"
    fi
    echo ""
}
prompt_transport_section() {
    local mode="$1"
    local is_ipx="false"
    section "Transport Configuration"
    local valid_transports=(tcp tcpmux xtcpmux ws wss wsmux wssmux xwsmux anytls tun)
    echo "Available transports:"
    printf '  • %s\n' "${valid_transports[@]}"
    while true; do
        echo -ne "Select transport: "
        read -r CONFIG[transport_type]
        [[ " ${valid_transports[*]} " =~ " ${CONFIG[transport_type]} " ]] && break
        colorize red "Invalid transport."
    done
    if [[ "${CONFIG[transport_type]}" == "tun" ]]; then
        echo
        local encapsulations=(tcp ipx)
        echo "Available encapsulations:"
        printf '  • %s\n' "${encapsulations[@]}"
        while true; do
            echo -ne "Select encapsulation: "
            read -r CONFIG[tun_encapsulation]
            [[ " ${encapsulations[*]} " =~ " ${CONFIG[tun_encapsulation]} " ]] && break
            colorize red "Invalid encapsulation."
        done
    fi
    echo
    if [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]]; then
        is_ipx="true"
    fi
    if [[ "$is_ipx" != "true" ]]; then
        prompt_boolean "Enable TCP_NODELAY" "true" CONFIG[nodelay]
    fi
    if [[ "$mode" == "server" ]]; then
        if [[ "${CONFIG[transport_type]}" == "tcp" ]]; then
            prompt_boolean "Accept UDP over TCP" "false" CONFIG[accept_udp]
        fi
        if [[ ! "${CONFIG[transport_type]}" =~ ^(tun|ws)$ ]] && [[ "$is_ipx" != "true" ]]; then
            prompt_boolean "Enable Proxy Protocol" "false" CONFIG[proxy_protocol]
        fi
    else
        if [[ "${CONFIG[transport_type]}" != "tun" ]]; then
            prompt_with_default "Connection Pool" "8" CONFIG[connection_pool]
        fi
    fi
    CONFIG[heartbeat_interval]="10"
    CONFIG[heartbeat_timeout]="25"
    if [[ "$is_ipx" != "true" ]]; then
        CONFIG[keepalive_period]="40"
    fi
    echo ""
}
prompt_mux_section() {
    local transport="$1"
    if [[ ! "$transport" =~ mux$ ]]; then
        return
    fi
    section "Mux Configuration"
    prompt_with_default "Mux Version [1 or 2]" "2" CONFIG[mux_version]
    prompt_with_default "Mux Concurrency" "8" CONFIG[mux_concurrency]
    CONFIG[mux_framesize]="32768"
    CONFIG[mux_recievebuffer]="4194304"
    CONFIG[mux_streambuffer]="2097152"
    echo ""
}
prompt_tun_section() {
    local transport="$1"
    local mode="$2"
    local is_ipx="$3"
    [[ "$transport" != "tun" ]] && return
    section "TUN Configuration"
    prompt_with_default "TUN Device Name" "soolakh" CONFIG[tun_name]
    local default_local default_remote
    if [[ "$mode" == "server" ]]; then
        default_local="10.10.10.1/24"
        default_remote="10.10.10.2/24"
    else
        default_local="10.10.10.2/24"
        default_remote="10.10.10.1/24"
    fi
    while true; do
        prompt_with_default "TUN Local Address (CIDR)" "$default_local" CONFIG[tun_local_addr]
        if validate_cidr "${CONFIG[tun_local_addr]}"; then
            break
        fi
        local suggested=$(validate_cidr "${CONFIG[tun_local_addr]}" 2>&1)
        colorize red "Invalid CIDR. Network address should be: $suggested"
    done
    while true; do
        prompt_with_default "TUN Remote Address (CIDR)" "$default_remote" CONFIG[tun_remote_addr]
        if validate_cidr "${CONFIG[tun_remote_addr]}"; then
            break
        fi
        colorize red "Invalid CIDR format."
    done
    prompt_with_default "Health Port" "1234" CONFIG[tun_health_port]
    if [[ "$is_ipx" == "true" ]]; then
        prompt_with_default "MTU" "1320" CONFIG[tun_mtu]
    else
        prompt_with_default "MTU" "1500" CONFIG[tun_mtu]
    fi
    echo ""
}
prompt_tls_section() {
    local mode="$1"
    local transport="$2"
    if [[ ! "$transport" =~ ^(anytls|wss|wssmux)$ ]]; then
        return
    fi
    section "TLS Configuration"
    if [[ "$transport" == "anytls" ]]; then
        prompt_with_default "SNI" "www.digikala.com" CONFIG[tls_sni]
    fi
    if [[ "$mode" == "client" ]]; then
        echo
        return
    fi
    if [[ ! -f "$CERT_FILE" || ! -f "$KEY_FILE" ]]; then
        colorize red "[*] TLS certificate or key missing, generating self-signed Ed25519 cert..."
        openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -x509 -days 365 -sha256 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=soolakh.com"
        colorize green "[*] Generated $CERT_FILE and $KEY_FILE"
        echo
    fi
    prompt_with_default "TLS Certificate Path" "$CERT_FILE" CONFIG[tls_cert]
    prompt_with_default "TLS Key Path" "$KEY_FILE" CONFIG[tls_key]
    echo ""
}
prompt_tuning_section() {
    local is_ipx="$1"
    local is_tun="$2"
    section "Tuning Configuration"
    prompt_boolean "Enable Auto Tuning" "true" CONFIG[auto_tuning]
    echo
    colorize magenta "Profiles: balanced, fast, latency, resource" normal
    prompt_with_default "Kernel Tuning Profile" "balanced" CONFIG[tuning_profile]
    prompt_with_default "Workers (0 = auto)" "0" CONFIG[workers]
    if [[ "$is_tun" != "true" ]]; then
        prompt_with_default "Channel Size" "4096" CONFIG[channel_size]
    fi
    if [[ "$is_tun" == "true" ]]; then
        CONFIG[channel_size]="10_000"
    fi
    if [[ "$is_ipx" == "true" ]]; then
        prompt_with_default "Batch Size" "2048" CONFIG[batch_size]
        prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
    else
        prompt_with_default "TCP MSS (0 = auto)" "0" CONFIG[tcp_mss]
        prompt_with_default "SO_RCVBUF (0 = auto)" "0" CONFIG[so_rcvbuf]
        prompt_with_default "SO_SNDBUF (0 = auto)" "0" CONFIG[so_sndbuf]
    fi
    if [[ "$is_tun" != "true" ]] && [[ "$is_ipx" != "true" ]]; then
        echo
        colorize magenta "Buffer Profiles: extreme_low_cpu, ultra_low_cpu, low_cpu, balanced, low_memory" normal
        prompt_with_default "Buffer Profile" "balanced" CONFIG[buffer_profile]
        prompt_with_default "Read Timeout" "120" CONFIG[read_timeout]
    fi
    echo ""
}
prompt_logging_section() {
    section "Logging Configuration"
    colorize magenta "Levels: panic, fatal, error, warn, info, debug, trace"
    prompt_with_default "Log Level" "info" CONFIG[log_level]
    echo ""
}
prompt_accept_udp_section() {
    local accept_udp="$1"
    [[ "$accept_udp" != "true" ]] && return
    CONFIG[ring_size]="64"
    CONFIG[frame_size]="2048"
    CONFIG[peer_idle_timeout_s]="120"
    CONFIG[write_timeout_ms]="3"
}
prompt_ports_section() {
    local mode="$1"
    local is_tun="$2"
    [[ "$mode" != "server" ]] && return
    if [[ "$is_tun" != "true" ]]; then
        section "Port Mapping Configuration"
        colorize green "Supported formats:"
        echo "  1. 443           - Listen on 443, forward to 443"
        echo "  2. 443=5000      - Listen on 443, forward to 5000"
        echo "  3. 443-600       - Listen on range 443-600"
        echo "  4. 443-600:5201  - Range forwarding to 5201"
        echo ""
        echo -ne "Enter port mappings (comma-separated): "
        read -r CONFIG[ports_mapping]
        echo ""
    else
        section "Port Mapping Configuration (TUN helper)"
        colorize magenta "Forwarder: use 'soolakh' for TCP support only, or 'iptables' for TCP + UDP support"
        prompt_with_default "Forwarder (soolakh/iptables)" "soolakh" CONFIG[forwarder]
        echo ""
        colorize green "Supported formats:"
        echo "  1. 443           - Listen on 443, forward to 443"
        echo "  2. 443=5000      - Listen on 443, forward to 5000"
        echo ""
        echo -ne "Enter port mappings (comma-separated): "
        read -r CONFIG[ports_mapping]
        echo ""
    fi
}
prompt_ipx_section() {
    local is_ipx="$1"
    local mode="$2"
    [[ "$is_ipx" != "true" ]] && return
    section "IPX Configuration"
    CONFIG[ipx_mode]="$mode"
    AVAILABLE_PROFILES=("icmp" "ipip" "udp" "tcp" "gre" "bip")
    colorize magenta "Available profiles: ${AVAILABLE_PROFILES[*]}"
    while true; do
        prompt_with_default "Profile" "tcp" CONFIG[ipx_profile]
        CONFIG[ipx_profile]="${CONFIG[ipx_profile],,}"
        for profile in "${AVAILABLE_PROFILES[@]}"; do
            if [[ "${CONFIG[ipx_profile]}" == "$profile" ]]; then
                break 2
            fi
        done
        colorize red "Invalid profile: ${CONFIG[ipx_profile]}"
        echo
        colorize yellow "Please choose one of: ${AVAILABLE_PROFILES[*]}"
    done
    prompt_with_default "Listen IP" "$SERVER_IP" CONFIG[ipx_listen_ip]
    while :; do
        prompt_with_default "Destination IP" "" CONFIG[ipx_dst_ip]
        if [[ -n "${CONFIG[ipx_dst_ip]}" ]]; then
            break
        fi
        colorize red "Destination IP cannot be empty."
    done
    interface=$(ip route show default | awk '{print $5}')
    prompt_with_default "Network Interface" "$interface" CONFIG[ipx_interface]
    if [[ "${CONFIG[ipx_profile]}" == "icmp" ]]; then
        prompt_with_default "ICMP Type" "0" CONFIG[ipx_icmp_type]
        prompt_with_default "ICMP Code" "0" CONFIG[ipx_icmp_code]
    fi
    echo
    prompt_boolean "Enable Spoof Mode" "false" CONFIG[ipx_spoof_mode]
    if [[ "${CONFIG[ipx_spoof_mode]}" == "true" ]]; then
        colorize magenta "Spoof IPs must be IPv4 addresses."
        while true; do
            prompt_with_default "Spoof Source IP (IPv4)" "" CONFIG[ipx_spoof_src_ip]
            if validate_ipv4 "${CONFIG[ipx_spoof_src_ip]}"; then
                break
            fi
            colorize red "Invalid IPv4 address. Please enter a valid IPv4 (e.g. 1.2.3.4)."
        done
        while true; do
            prompt_with_default "Spoof Destination IP (IPv4)" "" CONFIG[ipx_spoof_dst_ip]
            if validate_ipv4 "${CONFIG[ipx_spoof_dst_ip]}"; then
                break
            fi
            colorize red "Invalid IPv4 address. Please enter a valid IPv4 (e.g. 1.2.3.4)."
        done
    fi
    echo ""
}
generate_toml_config() {
    local mode="$1"
    local output_file="$2"
    local is_tun="$3"
    local is_ipx="$4"
    {
        if [[ "$mode" == "server" ]] && [[ "$is_ipx" == "false" ]]; then
            echo "[listener]"
            echo "bind_addr = \"${CONFIG[bind_addr]}\""
            echo ""
        elif [[ "$is_ipx" == "false" ]]; then
            echo "[dialer]"
            echo "remote_addr = \"${CONFIG[remote_addr]}\""
            [[ -n "${CONFIG[edge_ip]}" ]] && echo "edge_ip = \"${CONFIG[edge_ip]}\""
            echo "dial_timeout = ${CONFIG[dial_timeout]}"
            echo "retry_interval = ${CONFIG[retry_interval]}"
            echo ""
        fi
        echo "[transport]"
        echo "type = \"${CONFIG[transport_type]}\""
        [[ -n "${CONFIG[nodelay]}" ]] && echo "nodelay = ${CONFIG[nodelay]}"
        [[ -n "${CONFIG[keepalive_period]}" ]] && echo "keepalive_period = ${CONFIG[keepalive_period]}"
        if [[ "$mode" == "server" ]]; then
            [[ -n "${CONFIG[accept_udp]}" ]] && echo "accept_udp = ${CONFIG[accept_udp]}"
            [[ -n "${CONFIG[proxy_protocol]}" ]] && echo "proxy_protocol = ${CONFIG[proxy_protocol]}"
        else
            [[ -n "${CONFIG[connection_pool]}" ]] && [[ "${CONFIG[connection_pool]}" != "0" ]] \
                && echo "connection_pool = ${CONFIG[connection_pool]}"
        fi
        [[ -n "${CONFIG[heartbeat_interval]}" ]] && echo "heartbeat_interval = ${CONFIG[heartbeat_interval]}"
        [[ -n "${CONFIG[heartbeat_timeout]}" ]] && echo "heartbeat_timeout = ${CONFIG[heartbeat_timeout]}"
        echo ""
        if [[ "$is_tun" == "true" ]]; then
            echo "[tun]"
            echo "encapsulation = \"${CONFIG[tun_encapsulation]}\""
            echo "name = \"${CONFIG[tun_name]}\""
            echo "local_addr = \"${CONFIG[tun_local_addr]}\""
            echo "remote_addr = \"${CONFIG[tun_remote_addr]}\""
            echo "health_port = ${CONFIG[tun_health_port]}"
            echo "mtu = ${CONFIG[tun_mtu]}"
            echo ""
        fi
        if [[ "$is_ipx" == "true" ]]; then
            echo "[ipx]"
            echo "mode = \"${CONFIG[ipx_mode]}\""
            echo "profile = \"${CONFIG[ipx_profile]}\""
            echo "listen_ip = \"${CONFIG[ipx_listen_ip]}\""
            echo "dst_ip = \"${CONFIG[ipx_dst_ip]}\""
            echo "interface = \"${CONFIG[ipx_interface]}\""
            [[ -n "${CONFIG[ipx_icmp_type]}" ]] && echo "icmp_type = ${CONFIG[ipx_icmp_type]}"
            [[ -n "${CONFIG[ipx_icmp_code]}" ]] && echo "icmp_code = ${CONFIG[ipx_icmp_code]}"
            [[ "${CONFIG[ipx_spoof_mode]}" == "true" ]] && {
                echo "spoof_src_ip = \"${CONFIG[ipx_spoof_src_ip]}\""
                echo "spoof_dst_ip = \"${CONFIG[ipx_spoof_dst_ip]}\""
            }
            echo ""
        fi
        if [[ "${CONFIG[transport_type]}" =~ mux$ ]]; then
            echo "[mux]"
            echo "mux_version = ${CONFIG[mux_version]}"
            echo "mux_framesize = ${CONFIG[mux_framesize]}"
            echo "mux_recievebuffer = ${CONFIG[mux_recievebuffer]}"
            echo "mux_streambuffer = ${CONFIG[mux_streambuffer]}"
            [[ -n "${CONFIG[mux_concurrency]}" ]] && echo "mux_concurrency = ${CONFIG[mux_concurrency]}"
            echo ""
        fi
        echo "[security]"
        if [[ "$is_ipx" == "true" ]]; then
            echo "enable_encryption = ${CONFIG[enable_encryption]}"
            [[ "${CONFIG[enable_encryption]}" == "true" ]] && {
                echo "algorithm = \"${CONFIG[algorithm]}\""
                echo "psk = \"${CONFIG[psk]}\""
                echo "kdf_iterations = ${CONFIG[kdf_iterations]}"
            }
        else
            echo "token = \"${CONFIG[token]}\""
        fi
        echo ""
        if [[ -n "${CONFIG[tls_sni]}" || -n "${CONFIG[tls_cert]}" ]]; then
            echo "[tls]"
            [[ -n "${CONFIG[tls_sni]}" ]] && echo "sni = \"${CONFIG[tls_sni]}\""
            [[ -n "${CONFIG[tls_cert]}" ]] && echo "tls_cert = \"${CONFIG[tls_cert]}\""
            [[ -n "${CONFIG[tls_key]}" ]] && echo "tls_key = \"${CONFIG[tls_key]}\""
            echo ""
        fi
        echo "[tuning]"
        [[ -n "${CONFIG[auto_tuning]}" ]] && echo "auto_tuning = ${CONFIG[auto_tuning]}"
        [[ -n "${CONFIG[tuning_profile]}" ]] && echo "tuning_profile = \"${CONFIG[tuning_profile]}\""
        [[ -n "${CONFIG[workers]}" ]] && echo "workers = ${CONFIG[workers]}"
        [[ -n "${CONFIG[channel_size]}" ]] && echo "channel_size = ${CONFIG[channel_size]}"
        [[ -n "${CONFIG[tcp_mss]}" ]] && echo "tcp_mss = ${CONFIG[tcp_mss]}"
        [[ -n "${CONFIG[so_rcvbuf]}" ]] && echo "so_rcvbuf = ${CONFIG[so_rcvbuf]}"
        [[ -n "${CONFIG[so_sndbuf]}" ]] && echo "so_sndbuf = ${CONFIG[so_sndbuf]}"
        [[ -n "${CONFIG[buffer_profile]}" ]] && echo "buffer_profile = \"${CONFIG[buffer_profile]}\""
        [[ -n "${CONFIG[batch_size]}" ]] && echo "batch_size = ${CONFIG[batch_size]}"
        [[ -n "${CONFIG[read_timeout]}" ]] && echo "read_timeout = ${CONFIG[read_timeout]}"
        echo ""
        if [[ "${CONFIG[accept_udp]}" == "true" ]]; then
            echo "[accept_udp]"
            echo "ring_size = ${CONFIG[ring_size]}"
            echo "frame_size = ${CONFIG[frame_size]}"
            echo "peer_idle_timeout_s = ${CONFIG[peer_idle_timeout_s]}"
            echo "write_timeout_ms = ${CONFIG[write_timeout_ms]}"
            echo ""
        fi
        echo "[logging]"
        echo "log_level = \"${CONFIG[log_level]}\""
        echo ""
        if [[ "$mode" == "server" ]]; then
            echo "[ports]"
            [[ -n "${CONFIG[forwarder]}" ]] && echo "forwarder = \"${CONFIG[forwarder]}\""
            echo "mapping = ["
            IFS=',' read -r -a ports <<<"${CONFIG[ports_mapping]}"
            for port in "${ports[@]}"; do
                [[ -n "$port" ]] && echo "    \"${port// /}\","
            done
            echo "]"
        fi
    } >"$output_file"
}
configure_server() {
    local mode="$1" # server or client
    local mode_name
    if [[ "$mode" == "server" ]]; then
        mode_name="IRAN (Server)"
    else
        mode_name="KHAREJ (Client)"
    fi
    clear
    colorize cyan "Configuring $mode_name" bold
    echo ""
    reset_config
    prompt_transport_section "$mode"
    local is_tun="false"
    local is_ipx="false"
    [[ "${CONFIG[transport_type]}" == "tun" ]] && is_tun="true"
    [[ "${CONFIG[tun_encapsulation]}" == "ipx" ]] && is_ipx="true"
    prompt_tun_section "${CONFIG[transport_type]}" "$mode" "$is_ipx"
    prompt_ipx_section "$is_ipx" "$mode"
    if [[ "$is_ipx" != "true" ]]; then
        prompt_connection_section "$mode"
    fi
    prompt_security_section "$is_ipx"
    prompt_accept_udp_section "${CONFIG[accept_udp]}"
    prompt_mux_section "${CONFIG[transport_type]}"
    prompt_tls_section "$mode" "${CONFIG[transport_type]}"
    prompt_tuning_section "$is_ipx" "$is_tun"
    prompt_logging_section
    prompt_ports_section "$mode" "$is_tun"
    local tunnel_port
    if [[ "$mode" == "server" ]]; then
        tunnel_port=$(echo "${CONFIG[bind_addr]}" | grep -oP ':\K[0-9]+$')
    else
        tunnel_port=$(echo "${CONFIG[remote_addr]}" | grep -oP ':\K[0-9]+$')
    fi
    if [[ -z "$tunnel_port" ]]; then
        tunnel_port=$(echo "${CONFIG[tun_health_port]}")
    fi
    local config_file
    if [[ "$mode" == "server" ]]; then
        config_file="${config_dir}/iran${tunnel_port}.toml"
    else
        config_file="${config_dir}/kharej${tunnel_port}.toml"
    fi
    generate_toml_config "$mode" "$config_file" "$is_tun" "$is_ipx"
    local service_type
    [[ "$mode" == "server" ]] && service_type="iran" || service_type="kharej"
    create_systemd_service "$service_type" "$tunnel_port" "$config_file"
    echo ""
    ok "Configuration completed successfully!"
    echo ""
    press_key
}
create_systemd_service() {
    local type="$1"
    local port="$2"
    local config_file="$3"
    local service_file="${service_dir}/soolakh-${type}${port}.service"
    local desc_type="$(tr '[:lower:]' '[:upper:]' <<<"${type:0:1}")${type:1}"
    cat >"$service_file" <<EOF
[Unit]
Description=Soolakh $desc_type Port $port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${config_dir}/soolakh_premium -c $config_file
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "soolakh-${type}${port}.service" >/dev/null 2>&1
    ok "Service soolakh-${type}${port} created and started"
}
SERVER_IP=$(hostname -I | awk '{print $1}')
display_logo() {
    echo -e "\033[96m"
    cat <<"EOF"
███████╗ ██████╗  ██████╗ ██╗      █████╗ ██╗  ██╗██╗  ██╗
██╔════╝██╔═══██╗██╔═══██╗██║     ██╔══██╗██║ ██╔╝██║  ██║
███████╗██║   ██║██║   ██║██║     ███████║█████╔╝ ███████║
╚════██║██║   ██║██║   ██║██║     ██╔══██║██╔═██╗ ██╔══██║
███████║╚██████╔╝╚██████╔╝███████╗██║  ██║██║  ██╗██║  ██║
╚══════╝ ╚═════╝  ╚═════╝ ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝
EOF
    echo -e "\033[0m"
    printf '\033[90m%s\033[0m\n' "Directed by @Kup1ng_org"
}
display_server_info() {
    echo
    hr blue
    printf '   \033[36m%-14s\033[90m: \033[97m%s\033[0m\n' "Server IP" "${SERVER_IP:-unknown}"
}
display_soolakh_core_status() {
    if [[ -f "${config_dir}/soolakh_premium" ]]; then
        printf '   \033[36m%-14s\033[90m: \033[92m%s\033[0m\n' "Soolakh Core" "Installed"
    else
        printf '   \033[36m%-14s\033[90m: \033[91m%s\033[0m\n' "Soolakh Core" "Not installed"
    fi
    hr blue
}
check_config_backup() {
    missing_services=()
    for config in "${config_dir}"/iran*.toml "${config_dir}"/kharej*.toml; do
        [ -e "$config" ] || continue
        fname=$(basename "$config")
        if [[ "$fname" =~ ^(iran|kharej)([0-9]+)\.toml$ ]]; then
            location="${BASH_REMATCH[1]}"
            tunnel_port="${BASH_REMATCH[2]}"
            service_file="${service_dir}/soolakh-${location}${tunnel_port}.service"
            if [[ ! -f "$service_file" ]]; then
                missing_services+=("$service_file:$location:$tunnel_port")
            fi
        fi
    done
    [[ ${#missing_services[@]} -eq 0 ]] && return 0
    echo
    colorize red "Missing service files:" bold
    for entry in "${missing_services[@]}"; do
        service_file="${entry%%:*}"
        location="${entry#*:}"
        location="${location%%:*}"
        tunnel_port="${entry##*:}"
        echo "- $service_file (type: $location, port: $tunnel_port)"
    done
    echo
    read -r -p "Do you want to create missing service files? (y/n): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        for entry in "${missing_services[@]}"; do
            service_file="${entry%%:*}"
            location="${entry#*:}"
            location="${location%%:*}"
            tunnel_port="${entry##*:}"
            config_file="${config_dir}/${location}${tunnel_port}.toml"
            desc_loc="$(tr '[:lower:]' '[:upper:]' <<<"${location:0:1}")${location:1}"
            cat >"$service_file" <<EOF
[Unit]
Description=Soolakh $desc_loc Port $tunnel_port
After=network.target
[Service]
Type=simple
User=root
ExecStart=${config_dir}/soolakh_premium -c $config_file
Restart=always
RestartSec=3
LimitNOFILE=1048576
TasksMax=infinity
LimitMEMLOCK=infinity
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF
            sudo systemctl daemon-reload
            sudo systemctl enable --now "$(basename "$service_file")"
            echo "Created and started $(basename "$service_file")"
        done
    fi
    sleep 2
}
check_config_backup
check_tunnel_status() {
    if ! ls "$config_dir"/*.toml 1>/dev/null 2>&1; then
        err "No config files found."
        press_key
        return 1
    fi
    clear
    section "Tunnel Status"
    info "Checking all services..."
    sleep 1
    echo
    for config_path in "$config_dir"/{iran,kharej}*.toml; do
        [ -f "$config_path" ] || continue
        config_name=$(basename "$config_path")
        config_name="${config_name%.toml}"
        service_name="soolakh-${config_name}.service"
        if [[ "$config_name" =~ ^iran([0-9]+)$ ]]; then
            port="${BASH_REMATCH[1]}"
            if systemctl is-active --quiet "$service_name"; then
                ok "Iran service (port $port) is running"
            else
                err "Iran service (port $port) is not running"
            fi
        elif [[ "$config_name" =~ ^kharej([0-9]+)$ ]]; then
            port="${BASH_REMATCH[1]}"
            if systemctl is-active --quiet "$service_name"; then
                ok "Kharej service (port $port) is running"
            else
                err "Kharej service (port $port) is not running"
            fi
        fi
    done
    echo
    press_key
}
tunnel_management() {
    if ! ls "$config_dir"/*.toml 1>/dev/null 2>&1; then
        err "No config files found."
        press_key
        return 1
    fi
    clear
    section "Existing Tunnels"
    echo
    local index=1
    declare -a configs
    for config_path in "$config_dir"/{iran,kharej}*.toml; do
        [ -f "$config_path" ] || continue
        config_name=$(basename "$config_path")
        if [[ "$config_name" =~ ^iran([0-9]+)\.toml$ ]]; then
            port="${BASH_REMATCH[1]}"
            configs+=("$config_path")
            printf '   \033[1;95m%2s)\033[0m \033[92m%-8s\033[0m \033[90mport\033[0m \033[33m%s\033[0m\n' "$index" "Iran" "$port"
            ((index++))
        elif [[ "$config_name" =~ ^kharej([0-9]+)\.toml$ ]]; then
            port="${BASH_REMATCH[1]}"
            configs+=("$config_path")
            printf '   \033[1;95m%2s)\033[0m \033[96m%-8s\033[0m \033[90mport\033[0m \033[33m%s\033[0m\n' "$index" "Kharej" "$port"
            ((index++))
        fi
    done
    echo
    echo -ne "\033[1;95m ➜\033[0m Enter your choice \033[90m(0 to return)\033[0m: "
    read -r choice
    [[ "$choice" == "0" ]] && return
    while ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#configs[@]})); do
        err "Invalid choice."
        echo -ne "\033[1;95m ➜\033[0m Enter your choice \033[90m(0 to return)\033[0m: "
        read -r choice
        [[ "$choice" == "0" ]] && return
    done
    selected_config="${configs[$((choice - 1))]}"
    config_name=$(basename "${selected_config%.toml}")
    service_name="soolakh-${config_name}.service"
    clear
    section "Manage  $config_name"
    echo
    menu_item 1 "Remove this tunnel"  red
    menu_item 2 "Restart this tunnel" yellow
    menu_item 3 "View service logs"   white
    menu_item 4 "View service status" white
    echo
    menu_item 0 "Back" gray
    echo
    echo -ne "\033[1;95m ➜\033[0m Enter your choice \033[90m(0 to return)\033[0m: "
    read -r choice
    case $choice in
        1) destroy_tunnel "$selected_config" ;;
        2) restart_service "$service_name" ;;
        3) view_service_logs "$service_name" ;;
        4) view_service_status "$service_name" ;;
        0) return ;;
        *) err "Invalid option!" && sleep 1 ;;
    esac
}
destroy_tunnel() {
    config_path="$1"
    config_name=$(basename "${config_path%.toml}")
    service_name="soolakh-${config_name}.service"
    service_path="$service_dir/$service_name"
    [ -f "$config_path" ] && rm -f "$config_path"
    if [[ -f "$service_path" ]]; then
        systemctl is-active --quiet "$service_name" && systemctl disable --now "$service_name" >/dev/null 2>&1
        rm -f "$service_path"
    fi
    systemctl daemon-reload
    echo
    ok "Tunnel destroyed successfully!"
    echo
    press_key
}
restart_service() {
    echo
    colorize yellow "Restarting $1" bold
    if systemctl list-units --type=service | grep -q "$1"; then
        systemctl restart "$1"
        ok "Service restarted successfully"
        echo
    else
        colorize red "Service not found"
    fi
    press_key
}
view_service_logs() {
    clear
    journalctl -eu "$1" -f -o cat
}
view_service_status() {
    clear
    systemctl status "$1"
    press_key
}
remove_core() {
    if find "$config_dir" -type f -name "*.toml" | grep -q .; then
        colorize red "Delete all services first."
        sleep 3
        return 1
    fi
    colorize yellow "Remove Soolakh-Core? (y/n)"
    read -r confirm
    if [[ $confirm == [yY] ]]; then
        [[ -d "$config_dir" ]] && rm -rf "$config_dir"
        ok "Soolakh-Core removed."
    fi
    press_key
}
update_script() {
    return
    DEST_DIR="/usr/bin/"
    SOOLAKH_SCRIPT="soolakh"
    SCRIPT_URL="http://ir.soolakh-dev.com:2095/soolakh.sh"
    [ -f "$DEST_DIR/$SOOLAKH_SCRIPT" ] && rm "$DEST_DIR/$SOOLAKH_SCRIPT"
    if curl -s -L -o "$DEST_DIR/$SOOLAKH_SCRIPT" "$SCRIPT_URL"; then
        chmod +x "$DEST_DIR/$SOOLAKH_SCRIPT"
        colorize yellow "Type 'soolakh' to run the script." bold
        exit 0
    else
        colorize red "Download failed."
    fi
    press_key
}
configure_tunnel() {
    [[ ! -d "$config_dir" ]] && {
        err "Install Soolakh-Core first."
        press_key
        return 1
    }
    clear
    section "New Tunnel"
    echo
    menu_item 1 "Configure IRAN  (Server)" bgreen
    menu_item 2 "Configure KHAREJ (Client)" bmagenta
    echo
    menu_item 0 "Back" gray
    echo
    echo -ne "\033[1;95m ➜\033[0m Enter your choice: "
    read -r configure_choice
    case "$configure_choice" in
        1) configure_server "server" ;;
        2) configure_server "client" ;;
        0) return ;;
        *) err "Invalid option!" && sleep 1 ;;
    esac
}
display_menu() {
    clear
    display_logo
    display_server_info
    display_soolakh_core_status
    echo
    menu_item 1 "Configure a new tunnel" bgreen
    menu_item 2 "Tunnel management"      cyan
    menu_item 3 "Check tunnel status"    cyan
    echo
    menu_item 4 "Update Soolakh Core"    white
    menu_item 5 "Update script"          white
    menu_item 6 "Remove Soolakh Core"    red
    echo
    menu_item 0 "Exit"                   gray
    echo
    hr blue
}
read_option() {
    echo -ne "\033[1;95m ➜\033[0m Enter your choice \033[90m[0-6]\033[0m: "
    read -r choice
    case $choice in
        1) configure_tunnel ;;
        2) tunnel_management ;;
        3) check_tunnel_status ;;
        4) download_and_extract_soolakh "menu" ;;
        5) update_script ;;
        6) remove_core ;;
        0) exit 0 ;;
        *) err "Invalid option!" && sleep 1 ;;
    esac
}
while true; do
    display_menu
    read_option
done
