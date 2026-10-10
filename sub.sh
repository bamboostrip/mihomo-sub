#!/bin/sh

# ---------------------------
# 路径与变量
# ---------------------------
CONFIG_DIR="/root/.config/mihomo"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
GOOD_FILE="${CONFIG_DIR}/config.yaml.good"
OVERLAY_FILE="${CONFIG_DIR}/overlay.yaml"
SECRET_FILE="${CONFIG_DIR}/.secret"
LOG_FILE="${CONFIG_DIR}/log.txt"
SUB_URLS_FILE="${CONFIG_DIR}/sub_urls.txt"
SCHEDULE_FILE="${CONFIG_DIR}/schedule.conf"
GROUP_MODE_FILE="${CONFIG_DIR}/group_mode.conf"
LAST_RUN_FILE="${CONFIG_DIR}/last_run"
UA_FILE="${CONFIG_DIR}/user_agent.txt"
TEMP_DIR="/tmp/mihomo_sub"

CR=$(printf '\r')
TAB=$(printf '\t')
log=""
refresh_time=$(date +"%Y-%m-%d %H:%M:%S %z")

# User-Agent: 从文件读取，默认使用 mihomo 版本号
if [ -f "${UA_FILE}" ] && [ -s "${UA_FILE}" ]; then
    SUB_UA=$(head -1 "${UA_FILE}")
else
    SUB_UA="clash-verge/v2.5.1"
fi

# API 密钥：环境变量 > 数据卷持久化文件 > 空（无密码，保持旧行为）
# 由 init.sh 在启动时写入 .secret，此处只做读取，支持容器重启后保持一致
if [ -z "${SECRET}" ] && [ -f "${SECRET_FILE}" ]; then
    SECRET=$(tr -d '[:space:]' < "${SECRET_FILE}" 2>/dev/null)
fi

# 策略组合并模式（管理页面可切换）：
#   merge   （默认）别名只改节点名；同名策略组合并成员（多账号节点同池），规则去重留一份
#   isolate          别名同时改策略组名与引用；各账号策略组独立，规则也分别保留
GROUP_MODE=$(head -1 "${GROUP_MODE_FILE}" 2>/dev/null)
case "${GROUP_MODE}" in
    isolate) GROUP_MODE="isolate" ;;
    *) GROUP_MODE="merge" ;;
esac

# YAML 双引号转义（secret 写入配置时用）
yaml_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# 直连下载：绕开代理（避免经由自身 7890 循环）+ 重试
# --connect-timeout 10 让建连阶段（DNS/TCP/TLS）卡住时快速失败，
# 死链单次最多烧 ~10s×重试，而不是每次都吃满 30s 总超时
curl_direct() {
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl -sL --connect-timeout 10 --retry 2 --retry-delay 2 --max-time 30 "$@"
}

# 本机请求：同样绕开代理，避免 HEALTHCHECK/热重载被代理劫持
curl_local() {
    env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
        curl -s "$@"
}

# 回滚上一份可用配置（移植自上游 3.0.0：失败保留上一份可用配置）
restore_good_config() {
    if [ -f "${GOOD_FILE}" ]; then
        cp -f "${GOOD_FILE}" "${CONFIG_FILE}"
        log="${log}已恢复上一份可用配置\n\t"
    fi
}

# ---------------------------
# 检查是否为手动触发
# ---------------------------
FORCE=false
if [ "$1" = "--now" ]; then
    FORCE=true
fi

# 进度输出：仅手动/启动触发（--now）时打印到 stdout（docker logs 可见），
# 定时任务输出重定向到了日志文件，靠文件日志即可，避免重复
say() {
    if $FORCE; then
        echo "$1"
    fi
}

# ---------------------------
# 流量信息：解析订阅响应头 subscription-userinfo 存档，
# 供管理页展示各账号剩余额度（upload/download/total/expire）
# ---------------------------
parse_usage() {
    hdr="$1"
    url="$2"
    [ -f "${hdr}" ] || return 0
    info=$(grep -i '^subscription-userinfo:' "${hdr}" 2>/dev/null | head -1 | cut -d: -f2-)
    [ -z "${info}" ] && return 0
    u_up=$(printf '%s' "${info}" | grep -io 'upload=[0-9]*' | head -1 | cut -d= -f2)
    u_down=$(printf '%s' "${info}" | grep -io 'download=[0-9]*' | head -1 | cut -d= -f2)
    u_total=$(printf '%s' "${info}" | grep -io 'total=[0-9]*' | head -1 | cut -d= -f2)
    u_exp=$(printf '%s' "${info}" | grep -io 'expire=[0-9]*' | head -1 | cut -d= -f2)
    if [ -z "${u_up}${u_down}${u_total}" ]; then
        return 0
    fi
    ukey=$(printf '%s' "${url}" | md5sum 2>/dev/null | cut -c1-12)
    [ -z "${ukey}" ] && return 0
    mkdir -p "${CONFIG_DIR}/usage"
    printf '%s\t%s\t%s\t%s\n' "${u_up:-0}" "${u_down:-0}" "${u_total:-0}" "${u_exp:-0}" > "${CONFIG_DIR}/usage/${ukey}.dat"
    used=$(( ${u_up:-0} + ${u_down:-0} ))
    if [ "${u_total:-0}" -gt 0 ]; then
        log="${log}流量统计：已用 $(hum "${used}") / 共 $(hum "${u_total}")\n\t"
    else
        log="${log}流量统计：已用 $(hum "${used}")（不限量）\n\t"
    fi
}

# 人性化字节数（GB/MB），用于日志
hum() {
    awk -v b="${1:-0}" 'BEGIN { if (b>=1073741824) printf "%.1fGB", b/1073741824; else printf "%.1fMB", b/1048576 }'
}

# ---------------------------
# 输出日志并退出
# ---------------------------
sub_end() {
    exit_code="${1:-0}"
    log="${log}\n"
    printf "%b" "${log}" >> "${LOG_FILE}"
    # 日志超过 1MB 时只保留最后 50KB
    if [ -f "${LOG_FILE}" ]; then
        log_size=$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)
        if [ "${log_size}" -gt 1048576 ]; then
            tail -c 51200 "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null
            mv "${LOG_FILE}.tmp" "${LOG_FILE}"
        fi
    fi
    # 清理临时目录
    rm -rf "${TEMP_DIR}"
    exit "${exit_code}"
}

# ---------------------------
# 检查调度时间
# ---------------------------
check_schedule() {
    if $FORCE; then
        return 0
    fi

    schedule=$(cat "${SCHEDULE_FILE}" 2>/dev/null | head -1)
    case "${schedule}" in
        "15min") interval=900 ;;
        "hourly") interval=3600 ;;
        "daily"|"") interval=86400 ;;
        *) interval=86400 ;;
    esac

    if [ -f "${LAST_RUN_FILE}" ]; then
        last=$(cat "${LAST_RUN_FILE}" 2>/dev/null)
        now=$(date +%s)
        if [ -n "${last}" ] && [ $((now - last)) -lt "${interval}" ]; then
            exit 0
        fi
    fi
    return 0
}

# ---------------------------
# 提取 YAML 区块
# ---------------------------
extract_section() {
    file="$1"
    section="$2"
    awk -v sec="${section}" '
        $0 ~ "^"sec":" { in_sec=1; next }
        in_sec && /^[a-z-]+:/ { exit }
        in_sec { print }
    ' "${file}"
}

# ---------------------------
# YAML 规范化：把各种手搓格式（flow 单行、顶格、 CRLF 等）统一为标准块样式
# 后续的提取/重命名/去重全部基于规范化文本，不再需要猜缩进。
# yq 失败（非法 YAML）则保留原文并告警，由后续逻辑按老行为处理。
# ---------------------------
normalize_yaml() {
    file="$1"
    command -v yq >/dev/null 2>&1 || return 0
    yq -P -i '.' "${file}" 2>/dev/null || log="${log}Warning: YAML 规范化失败，沿用原文\n\t"
}

# ---------------------------
# 别名前缀（两种模式，由 GROUP_MODE 决定）：
#   merge  ：只把节点名改写为 "别名 | 原名"，策略组名不改。各账号节点全部保留，
#            不同账号的节点可落进同名策略组（组由后续“同名结合并成员”步骤合成
#            公共组）；规则里的策略组引用不带前缀，同机场两账号的相同规则天然去重。
#   isolate：节点名 + 策略组名 + 所有引用统一加前缀，各账号策略组/规则完全独立。
# 输入必须是 normalize_yaml 规范化后的文件：块样式、2 格缩进。
# 规范化时非 ASCII 会被 yq 写成 "..." 包裹的转义序列，原样保留即可
# （YAML 会正确解码）；只有用户输入的别名前缀需要转义。
# 两遍扫描：第一遍建节点/策略组名字映射，第二遍只改节点定义与“指向节点”
# 的引用（组成员、规则策略），保证引用一致。无别名时不调用，保持原行为。
# ---------------------------
apply_alias_prefix() {
    file="$1"
    prefix="$2"
    mode="${3:-merge}"
    tmp_renamed="${file}.renamed"
    # 前缀用环境变量传入：awk -v 会解释 \n 等转义序列，会把别名里的反斜杠吞掉
    PRE="${prefix}" MODE="${mode}" awk '
        function hexval(h,   n,i,c,d) {
            n = 0
            for (i = 1; i <= length(h); i++) {
                c = tolower(substr(h, i, 1))
                d = index("0123456789abcdef", c) - 1
                if (d < 0) return -1
                n = n * 16 + d
            }
            return n
        }
        function utf8(cp) {
            if (cp < 0) return ""
            if (cp < 128) return sprintf("%c", cp)
            if (cp < 2048) return sprintf("%c%c", 192 + int(cp/64), 128 + (cp % 64))
            if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp/4096), 128 + (int(cp/64) % 64), 128 + (cp % 64))
            return sprintf("%c%c%c%c", 240 + int(cp/262144), 128 + (int(cp/4096) % 64), 128 + (int(cp/64) % 64), 128 + (cp % 64))
        }
        function yqdec(s,   out,i,c,e,hex,cp,lo) {
            out = ""
            i = 1
            while (i <= length(s)) {
                c = substr(s, i, 1)
                if (c == "\\") {
                    e = substr(s, i+1, 1)
                    if (e == "n") { out = out "\n"; i += 2 }
                    else if (e == "t") { out = out "\t"; i += 2 }
                    else if (e == "r") { out = out "\r"; i += 2 }
                    else if (e == "a") { out = out "\a"; i += 2 }
                    else if (e == "b") { out = out "\b"; i += 2 }
                    else if (e == "v") { out = out "\v"; i += 2 }
                    else if (e == "f") { out = out "\f"; i += 2 }
                    else if (e == "e") { out = out "\033"; i += 2 }
                    else if (e == "U") {
                        cp = hexval(substr(s, i+2, 8))
                        if (cp < 0) { out = out c; i++ }
                        else { out = out utf8(cp); i += 10 }
                    }
                    else if (e == "u") {
                        cp = hexval(substr(s, i+2, 4))
                        if (cp < 0) { out = out c; i++ }
                        else {
                            lo = 0
                            if (cp >= 55296 && cp <= 56319 && substr(s, i+6, 2) == "\\u") {
                                lo = hexval(substr(s, i+8, 4))
                            }
                            if (lo >= 56320 && lo <= 57343) {
                                out = out utf8(65536 + (cp - 55296) * 1024 + (lo - 56320))
                                i += 12
                            } else { out = out utf8(cp); i += 6 }
                        }
                    }
                    else if (e == "x") {
                        cp = hexval(substr(s, i+2, 2))
                        if (cp < 0) { out = out c; i++ }
                        else { out = out utf8(cp); i += 4 }
                    }
                    else { out = out e; i += 2 }
                } else { out = out c; i++ }
            }
            return out
        }
        function esc(s,   t) {
            t = s
            gsub(/\\/, "\\\\", t)
            gsub(/["]/, "\\\"", t)
            gsub(/\n/, "\\n", t)
            gsub(/\t/, "\\t", t)
            gsub(/\r/, "\\r", t)
            return t
        }
        function norm(v,   k,q,o,rest,p) {
            k = v
            gsub(/^[ \t\r]+|[ \t\r]+$/, "", k)
            q = substr(k, 1, 1)
            if (length(k) >= 2 && (q == "\"" || q == SQ) && substr(k, length(k), 1) == q) {
                k = substr(k, 2, length(k) - 2)
                if (q == "\"") k = yqdec(k)
                else {
                    o = ""
                    rest = k
                    while ((p = index(rest, SQ SQ)) > 0) {
                        o = o substr(rest, 1, p - 1) SQ
                        rest = substr(rest, p + 2)
                    }
                    k = o rest
                }
            }
            gsub(/^[ \t\r]+|[ \t\r]+$/, "", k)
            return k
        }
        function is_top(key) { return (key ~ /^[A-Za-z][A-Za-z0-9_-]*:[ \t]*$/) }
        function entry_ind(s,   t) { t=s; sub(/- name:.*$/, "", t); return t }
        BEGIN { pre = ENVIRON["PRE"]; md = ENVIRON["MODE"]; SQ = sprintf("%c", 39); SQSQ = SQ SQ }
        NR==FNR {
            if ($0 ~ /^proxies:[ \t]*$/) { sec="proxies"; next }
            if ($0 ~ /^proxy-groups:[ \t]*$/) { sec="groups"; next }
            if (is_top($0)) { sec=""; next }
            if ((sec=="proxies" || sec=="groups") && $0 ~ /^[ \t]{0,2}- name: /) {
                v=$0; sub(/^[ \t]{0,2}- name: /, "", v)
                k=norm(v)
                if (k == "") next
                if (sec=="proxies") nm[k]=1
                else gm[k]=1
            }
            next
        }
        FNR==1 { sec="" }
        $0 ~ /^proxies:[ \t]*$/ { sec="proxies"; print; next }
        $0 ~ /^proxy-groups:[ \t]*$/ { sec="groups"; print; next }
        $0 ~ /^rules:[ \t]*$/ { sec="rules"; print; next }
        is_top($0) { sec=""; print; next }
        sec=="proxies" && /^[ \t]{0,2}- name: / {
            ind=entry_ind($0)
            v=$0; sub(/^[ \t]{0,2}- name: /, "", v)
            k=norm(v)
            printf "%s- name: \"%s | %s\"\n", ind, esc(pre), esc(k)
            next
        }
        sec=="groups" && /^[ \t]{0,2}- name: / {
            # isolate 模式策略组名也加前缀（各账号组独立）；merge 模式保持组名共享
            if (md == "isolate") {
                ind=entry_ind($0)
                v=$0; sub(/^[ \t]{0,2}- name: /, "", v)
                k=norm(v)
                printf "%s- name: \"%s | %s\"\n", ind, esc(pre), esc(k)
            } else print
            next
        }
        sec=="groups" && /^[ \t]*- / {
            ind=$0; sub(/-.*$/, "- ", ind)
            ref=$0; sub(/^[ \t]*- +/, "", ref)
            k=norm(ref)
            if (k in nm || (md == "isolate" && k in gm)) printf "%s\"%s | %s\"\n", ind, esc(pre), esc(k)
            else print
            next
        }
        sec=="rules" && /^[ \t]*- / {
            # 整行解开外层引号后切分（规则整体被引号包裹时直接 split 会引号失衡），
            # 双引号行剥壳后必须用 yqdec 解码 \U/\u/\x 等转义（yq 会把 emoji
            # 写成 "\U0001F6D1..."，不解码则字段与 nm 里已解码的名字比对不上，
            # 指向节点的策略不会被加别名前缀，重载直接 400）；
            # 只有策略是“本订阅节点名”时才加前缀，指向策略组的保持原名（组名不改，
            # 同机场两账号的相同规则因此完全一致，后续整行去重自动合并为一份）
            ind=$0; sub(/[^ \t].*$/, "", ind)
            rb=$0; sub(/^[ \t]*- +/, "", rb)
            gsub(/^[ \t]+|[ \t]+$/, "", rb)
            q=substr(rb, 1, 1)
            if (length(rb) >= 2 && (q == "\"" || q == SQ) && substr(rb, length(rb), 1) == q) {
                rb = substr(rb, 2, length(rb) - 2)
                if (q == SQ) gsub(SQSQ, SQ, rb)
                else rb = yqdec(rb)
            }
            n=split(rb, f, ",")
            idx=n
            if (norm(f[n])=="no-resolve" && n>=3) idx=n-1
            key=norm(f[idx])
            if (key in nm || (md == "isolate" && key in gm)) {
                for (i=1;i<=n;i++) f[i]=esc(norm(f[i]))
                f[idx]=esc(pre) " | " f[idx]
                out=f[1]
                for (i=2;i<=n;i++) out=out "," f[i]
                print ind "- \"" out "\""
            }
            else print
            next
        }
        { print }
    ' "${file}" "${file}" > "${tmp_renamed}" 2>/dev/null && mv "${tmp_renamed}" "${file}"
}

# ---------------------------
# 日志输出辅助
# ---------------------------
check_schedule

# 清除 subconverter 缓存
for d in /subconverter/cache /tmp/.subconverter_cache; do
    [ -d "${d}" ] && rm -rf "${d}"/* 2>/dev/null || true
done

log="${log}[${refresh_time}] \n\t订阅文件更新...\n\t"

# ---------------------------
# 读取订阅列表
# ---------------------------
if [ ! -f "${SUB_URLS_FILE}" ] || [ ! -s "${SUB_URLS_FILE}" ]; then
    # 回退到环境变量
    if [ -n "${sub_url}" ]; then
        echo "${sub_url}" > "${SUB_URLS_FILE}"
    else
        log="${log}Error: 无订阅地址，请通过管理页面添加\n\t"
        sub_end 1
    fi
fi

# ---------------------------
# 创建临时目录
# ---------------------------
mkdir -p "${TEMP_DIR}"

# ---------------------------
# 处理每个订阅 URL
# ---------------------------
all_proxies=""
all_rules=""
all_groups=""
sub_count=0
success_count=0

while IFS= read -r line || [ -n "${line}" ]; do
    # 去除 Windows 换行符 \r
    line="${line%"${CR}"}"
    # 跳过空行；"#" 开头的行是注释，但含 TAB 说明是“别名以 # 开头”的订阅行，不能跳过
    case "${line}" in
        "") continue ;;
        "#"*)
            case "${line}" in
                *"${TAB}"*) ;;
                *) continue ;;
            esac
            ;;
    esac

    # 订阅行格式：纯 URL，或 "别名<TAB>URL"，第三列 "off" 表示已停用
    #（TAB 不可能出现在 URL 里；无 TAB 即老格式，保持兼容）
    _f1=$(printf '%s' "${line}" | cut -f1)
    _f2=$(printf '%s' "${line}" | cut -f2)
    _f3=$(printf '%s' "${line}" | cut -f3)
    if [ "${_f2}" = "${line}" ]; then
        SUB_ALIAS=""
        sub_url="${line}"
    else
        SUB_ALIAS=$(printf '%s' "${_f1}" | tr -d '\000-\010\013\014\016-\037\177\r\n')
        sub_url="${_f2}"
    fi
    if [ -z "${sub_url}" ]; then
        log="${log}Error: 订阅地址为空，已跳过\n\t"
        continue
    fi
    # 已停用（管理页「切换」会把其他订阅置为 off）：不下载、不合并
    if [ "${_f3}" = "off" ]; then
        log="${log}订阅 [${SUB_ALIAS}] 已停用，跳过\n\t"
        say "⏸ 订阅 [${SUB_ALIAS}] 已停用，跳过"
        continue
    fi
    sub_count=$((sub_count + 1))
    if [ -n "${SUB_ALIAS}" ]; then
        log_tag=" [${SUB_ALIAS}]"
    else
        log_tag=""
    fi
    raw_file="${TEMP_DIR}/raw_${sub_count}.txt"
    temp_file="${TEMP_DIR}/sub_${sub_count}.yml"

    log="${log}第 ${sub_count} 个订阅${log_tag}获取中...\n\t"
    say "➡️ 订阅 ${sub_count}${log_tag}开始获取..."

    # curl 直接下载原始订阅，正确设置 User-Agent
    # 绕开代理 + 跟随跳转 + 检查 HTTP 状态码（移植自上游 3.0.0 的健壮下载）
    # -D 存响应头，用于解析 subscription-userinfo 流量信息
    curl_exit=0
    hdr_file="${TEMP_DIR}/hdr_${sub_count}.txt"
    http_code=$(curl_direct -D "${hdr_file}" -w "%{http_code}" -H "User-Agent: ${SUB_UA}" -o "${raw_file}" "${sub_url}" 2>/dev/null) || curl_exit=$?

    if [ "${curl_exit}" -ne 0 ]; then
        log="${log}Error: 订阅 ${sub_count}${log_tag} 下载失败，退出码: ${curl_exit}\n\t"
        say "❌ 订阅 ${sub_count}${log_tag}下载失败（退出码 ${curl_exit}）"
        continue
    fi

    if [ "${http_code:-0}" -ne 200 ]; then
        log="${log}Error: 订阅 ${sub_count}${log_tag} 下载失败，响应码: ${http_code}\n\t"
        say "❌ 订阅 ${sub_count}${log_tag}下载失败（HTTP ${http_code}）"
        continue
    fi

    if [ ! -s "${raw_file}" ]; then
        log="${log}Error: 订阅 ${sub_count}${log_tag} 返回空内容\n\t"
        say "❌ 订阅 ${sub_count}${log_tag}返回空内容"
        continue
    fi

    # 解析流量信息存档（管理页展示剩余额度），无头则跳过
    parse_usage "${hdr_file}" "${sub_url}"

    # 判断原始内容格式：如果已经是 clash YAML 则直接使用（允许行首空格）
    if grep -qE '^[[:space:]]*proxies:' "${raw_file}" 2>/dev/null; then
        cp "${raw_file}" "${temp_file}"
        log="${log}订阅 ${sub_count}${log_tag} 已为 Clash 格式\n\t"
    else
        # 非 Clash 格式，通过 subconverter 转换（本机请求同样绕开代理）
        encoded_sub_url=$(jq -rn --arg x "${sub_url}" '$x|@uri' 2>/dev/null)
        encoded_ua=$(jq -rn --arg x "${SUB_UA}" '$x|@uri' 2>/dev/null)
        http_code=$(curl_local --max-time 30 -w "%{http_code}" -o "${temp_file}" "http://127.0.0.1:25500/sub?target=clash&url=${encoded_sub_url}&ua=${encoded_ua}")
        curl_exit=$?

        if [ "${curl_exit}" -ne 0 ]; then
            log="${log}Error: 订阅 ${sub_count}${log_tag} 转换失败，退出码: ${curl_exit}\n\t"
            continue
        elif [ "${http_code:-0}" -ne 200 ]; then
            log="${log}Error: 订阅 ${sub_count}${log_tag} 转换失败，响应码: ${http_code}\n\t"
            continue
        fi
    fi

    if [ ! -s "${temp_file}" ]; then
        log="${log}Error: 订阅 ${sub_count}${log_tag} 处理后为空\n\t"
        continue
    fi

    # 先规范化为标准块样式（flow/顶格/CRLF 等手搓格式统一），
    # 后续提取/重命名/去重全部基于规范文本
    normalize_yaml "${temp_file}"

    # 有别名则加前缀（merge 只改节点名；isolate 连策略组名/引用一起改）
    if [ -n "${SUB_ALIAS}" ]; then
        apply_alias_prefix "${temp_file}" "${SUB_ALIAS}" "${GROUP_MODE}"
        if [ "${GROUP_MODE}" = "isolate" ]; then
            log="${log}订阅 ${sub_count}${log_tag}已添加别名前缀（策略组隔离）\n\t"
        else
            log="${log}订阅 ${sub_count}${log_tag}已添加别名前缀（策略组合并）\n\t"
        fi
    fi

    # 提取代理列表
    proxies=$(extract_section "${temp_file}" "proxies")
    if [ -n "${proxies}" ]; then
        all_proxies="${all_proxies}${proxies}
"
    fi

    # 提取规则
    rules=$(extract_section "${temp_file}" "rules")
    if [ -n "${rules}" ]; then
        all_rules="${all_rules}${rules}
"
    fi

    # 合并所有订阅的 proxy-groups（后续按组名并成员：同机场多账号合入同一公共组）
    groups=$(extract_section "${temp_file}" "proxy-groups")
    if [ -n "${groups}" ]; then
        all_groups="${all_groups}${groups}
"
    fi

    # 只有实际提取到代理或规则才算成功
    if [ -n "${proxies}" ] || [ -n "${rules}" ]; then
        success_count=$((success_count + 1))
        log="${log}订阅 ${sub_count}${log_tag} 更新成功\n\t"
        say "✅ 订阅 ${sub_count}${log_tag}更新成功"
    else
        log="${log}订阅 ${sub_count}${log_tag} 无有效节点\n\t"
        say "⚠️ 订阅 ${sub_count}${log_tag}无有效节点"
    fi

done < "${SUB_URLS_FILE}"

if [ "${sub_count}" -eq 0 ]; then
    log="${log}Error: 没有启用的订阅，保留现有配置\n\t"
    say "⏸ 没有启用的订阅，已保留原配置"
    sub_end 1
fi

if [ "${success_count}" -eq 0 ]; then
    log="${log}Error: 所有订阅均失败，保留现有配置\n\t"
    say "❌ 所有订阅均失败，已保留原配置"
    restore_good_config
    sub_end 1
fi

# ---------------------------
# 构建最终配置文件（printf %s 不解释转义，订阅数据安全）
# secret 为空时写入空字符串 = 无密码（保持旧行为）；设置后面板与 API 需要鉴权
# ---------------------------
# 多订阅合并去重：同名节点只保留第一次出现
# （mihomo 要求 proxies 内 name 唯一，重名会导致重载 400 被拒）
if [ -n "${all_proxies}" ]; then
    proxy_before=$(printf '%s' "${all_proxies}" | grep -cE '^[ \t]{0,2}- name: ' || true)
    all_proxies=$(printf '%s' "${all_proxies}" | awk '
        /^[ \t]{0,2}- name: / {
            nm=$0
            sub(/^[ \t]{0,2}- name: /, "", nm)
            gsub(/^["]|["]$/, "", nm)
            gsub(/^ +| +$/, "", nm)
            if (nm in seen) { skip=1; next }
            seen[nm]=1; skip=0; print; next
        }
        skip { next }
        { print }
    ')
    proxy_after=$(printf '%s' "${all_proxies}" | grep -cE '^[ \t]{0,2}- name: ' || true)
    # $() 会剥掉末尾换行，补回来（否则 proxies 块与下一节粘连）
    all_proxies="${all_proxies}
"
    proxy_dedup=$((proxy_before - proxy_after))
    if [ "${proxy_dedup}" -gt 0 ]; then
        log="${log}已去除 ${proxy_dedup} 个重名节点\n\t"
    fi
fi

# 多订阅策略组合并：同名组保留第一次出现的属性（type/url 等），成员取并集。
# 同机场多账号的节点加别名前缀后名字不同，两个账号的同名组在这里合成一个
# 公共组（两个账号的节点都在里面），规则只需保留一份即可引用到全部节点。
# （mihomo 要求 proxy-groups 内 name 唯一）
if [ -n "${all_groups}" ]; then
    groups_before=$(printf '%s' "${all_groups}" | grep -cE '^[ \t]{0,2}- name: ' || true)
    all_groups=$(printf '%s' "${all_groups}" | awk '
        {
            if ($0 ~ /^[ \t]{0,2}- name: /) {
                k=$0
                sub(/^[ \t]{0,2}- name: /, "", k)
                gsub(/^["]|["]$/, "", k)
                gsub(/^[ \t]+|[ \t]+$/, "", k)
                if (k in seen) { dup=1; cur=k; next }
                seen[k]=1; dup=0; cur=k
                n++; order[n]=k; gi[k]=n; cnt[n]=0
                cnt[n]++; L[n,cnt[n]]=$0
                next
            }
            if (cur == "") { print; next }
            if (dup) {
                # 同名组：只收集成员行（6 格缩进序列项），稍后并入首个同名组
                if ($0 ~ /^[ \t]{4,}- /) {
                    v=$0
                    sub(/^[ \t]*-[ \t]+/, "", v)
                    gsub(/^[ \t]+|[ \t]+$/, "", v)
                    extra[cur, ++nex[cur]]=v
                }
                next
            }
            cnt[gi[cur]]++; L[gi[cur],cnt[gi[cur]]]=$0
            next
        }
        END {
            for (i = 1; i <= n; i++) {
                k=order[i]
                # 首个同名组已有的成员值（新成员先和它去重）
                for (j = 1; j <= cnt[i]; j++) {
                    if (L[i,j] ~ /^[ \t]{4,}- /) {
                        v=L[i,j]
                        sub(/^[ \t]*-[ \t]+/, "", v)
                        gsub(/^[ \t]+|[ \t]+$/, "", v)
                        bmem[i,v]=1
                    }
                }
                ne=0
                for (e = 1; e <= nex[k]; e++) {
                    v=extra[k,e]
                    if ((i,v) in bmem || (i,v) in newm) continue
                    newm[i,v]=1
                    neword[++ne]=v
                }
                # 插入点：首个组的最后一条成员行；没有成员行则找 proxies: 行
                sp=0; pp=0
                for (j = 1; j <= cnt[i]; j++) {
                    if (L[i,j] ~ /^[ \t]{4,}- /) sp=j
                    if (L[i,j] ~ /^[ \t]*proxies:[ \t]*$/) pp=j
                }
                for (j = 1; j <= cnt[i]; j++) {
                    print L[i,j]
                    if (ne > 0 && ((sp > 0 && j == sp) || (sp == 0 && j == pp))) {
                        for (e = 1; e <= ne; e++) print "      - " neword[e]
                    }
                }
                if (ne > 0 && sp == 0 && pp == 0) {
                    # 首个组原本没有 proxies 列表：补一个（极少数手搓配置）
                    print "    proxies:"
                    for (e = 1; e <= ne; e++) print "      - " neword[e]
                }
            }
        }
    ')
    groups_after=$(printf '%s' "${all_groups}" | grep -cE '^[ \t]{0,2}- name: ' || true)
    # $() 会剥掉末尾换行，补回来
    all_groups="${all_groups}
"
    groups_dedup=$((groups_before - groups_after))
    if [ "${groups_dedup}" -gt 0 ]; then
        log="${log}已合并 ${groups_dedup} 个同名策略组（成员取并集）\n\t"
    fi
fi

# 规则完全相同的行去重（多订阅常带同样的直连/广告规则）
if [ -n "${all_rules}" ]; then
    rules_before=$(printf '%s' "${all_rules}" | grep -c . || true)
    all_rules=$(printf '%s' "${all_rules}" | awk '!seen[$0]++')
    all_rules="${all_rules}
"
    rules_after=$(printf '%s' "${all_rules}" | grep -c . || true)
    rules_dedup=$((rules_before - rules_after))
    if [ "${rules_dedup}" -gt 0 ]; then
        log="${log}已去除 ${rules_dedup} 条重复规则\n\t"
    fi
fi
SECRET_ESC=$(yaml_escape "${SECRET}")
{
    printf '%s\n' 'mixed-port: 7890'
    printf '%s\n' 'external-ui: /root/.config/mihomo/ui'
    printf '%s\n' 'allow-lan: true'
    printf '%s\n' "secret: \"${SECRET_ESC}\""

    if [ -n "${all_proxies}" ]; then
        printf '%s\n' 'proxies:'
        printf '%s' "${all_proxies}"
    fi

    if [ -n "${all_groups}" ]; then
        printf '%s\n' 'proxy-groups:'
        printf '%s' "${all_groups}"
        echo
    else
        printf '%s\n' 'proxy-groups:'
        printf '%s\n' '  - name: Proxy'
        printf '%s\n' '    type: select'
        printf '%s\n' '    proxies:'
        printf '%s' "${all_proxies}" | awk '/^[[:space:]]*- name:/{ sub(/^[[:space:]]*- name:[[:space:]]*/, ""); print "      - " $0}'
        printf '%s\n' '      - DIRECT'
    fi

    if [ -n "${all_rules}" ]; then
        printf '%s\n' 'rules:'
        printf '%s' "${all_rules}"
    else
        printf '%s\n' 'rules:'
        printf '%s\n' '  - MATCH,DIRECT'
    fi

    printf '%s\n' 'external-controller: 0.0.0.0:9090'
} > "${CONFIG_FILE}.new"

if [ ! -s "${CONFIG_FILE}.new" ]; then
    log="${log}Error: 配置文件生成失败\n\t"
    restore_good_config
    sub_end 1
fi

# 可选 overlay.yaml 深合并（移植自上游 3.0.0，不存在则跳过，不影响原有多订阅流程）
if [ -f "${OVERLAY_FILE}" ] && [ -s "${OVERLAY_FILE}" ]; then
    if command -v yq > /dev/null 2>&1; then
        if yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' \
            "${CONFIG_FILE}.new" "${OVERLAY_FILE}" > "${CONFIG_FILE}.merged" 2>/dev/null; then
            yq -i '
                .rules = ((.["rules-prepend"] // []) + (.rules // []) + (.["rules-append"] // [])) |
                del(.["rules-prepend"]) | del(.["rules-append"])
            ' "${CONFIG_FILE}.merged" 2>/dev/null
            # 强制受管字段，避免 overlay 覆盖端口、面板与密钥
            yq -i '
                ."mixed-port" = 7890 |
                ."allow-lan" = true |
                ."external-controller" = "0.0.0.0:9090" |
                ."external-ui" = "/root/.config/mihomo/ui"
            ' "${CONFIG_FILE}.merged" 2>/dev/null
            mv "${CONFIG_FILE}.merged" "${CONFIG_FILE}.new"
            log="${log}已合并 overlay.yaml\n\t"
        else
            log="${log}Warning: overlay.yaml 合并失败，沿用转换结果\n\t"
        fi
    else
        log="${log}Warning: 未安装 yq，跳过 overlay.yaml\n\t"
    fi
fi

# secret 由脚本强制写入，不允许 overlay 覆盖
if command -v yq > /dev/null 2>&1; then
    yq -i ".secret = \"${SECRET_ESC}\"" "${CONFIG_FILE}.new" 2>/dev/null || true
fi

mv "${CONFIG_FILE}.new" "${CONFIG_FILE}"

if [ ! -s "${CONFIG_FILE}" ]; then
    log="${log}Error: 配置文件生成失败\n\t"
    restore_good_config
    sub_end 1
fi

log="${log}配置文件生成成功 (${success_count}/${sub_count} 个订阅) ✅\n\t"
say "✅ 配置文件生成成功 (${success_count}/${sub_count} 个订阅)"

# ---------------------------
# 配置重新加载（带 SECRET 鉴权 + 失败回滚，移植自上游 3.0.0）
# ---------------------------
log="${log}配置重新加载...\n\t"
reload_body="${TEMP_DIR}/reload_body.txt"
if [ -n "${SECRET}" ]; then
    reload_response=$(curl_local --max-time 15 -w "%{http_code}" -o "${reload_body}" -X PUT "http://127.0.0.1:9090/configs?force=true" -H "Content-Type: application/json" -H "Authorization: Bearer ${SECRET}" -d '{"path":"","payload":""}')
else
    reload_response=$(curl_local --max-time 15 -w "%{http_code}" -o "${reload_body}" -X PUT "http://127.0.0.1:9090/configs?force=true" -H "Content-Type: application/json" -d '{"path":"","payload":""}')
fi
reload_exit_code=$?

if [ "${reload_exit_code}" -ne 0 ]; then
    log="${log}Warning: mihomo 服务未启动，跳过热重载（启动后会读取新配置）\n\t"
    cp -f "${CONFIG_FILE}" "${GOOD_FILE}"
elif [ "${reload_response:-0}" -ne 204 ] && [ "${reload_response:-0}" -ne 200 ]; then
    reload_msg=$(head -c 300 "${reload_body}" 2>/dev/null | tr '\n' ' ')
    log="${log}Error: 配置重新加载失败，响应码: ${reload_response} ${reload_msg}，尝试回滚\n\t"
    cp -f "${CONFIG_FILE}" "${CONFIG_FILE}.bad"
    log="${log}失败配置已另存为 config.yaml.bad 供排查\n\t"
    if [ -f "${GOOD_FILE}" ]; then
        cp -f "${GOOD_FILE}" "${CONFIG_FILE}"
        if [ -n "${SECRET}" ]; then
            curl_local --max-time 15 -o /dev/null -X PUT "http://127.0.0.1:9090/configs?force=true" -H "Content-Type: application/json" -H "Authorization: Bearer ${SECRET}" -d '{"path":"","payload":""}' >/dev/null 2>&1 || true
        else
            curl_local --max-time 15 -o /dev/null -X PUT "http://127.0.0.1:9090/configs?force=true" -H "Content-Type: application/json" -d '{"path":"","payload":""}' >/dev/null 2>&1 || true
        fi
        log="${log}已回滚上一份可用配置\n\t"
    fi
    sub_end 1
else
    cp -f "${CONFIG_FILE}" "${GOOD_FILE}"
fi

# 记录最后运行时间
date +%s > "${LAST_RUN_FILE}"

log="${log}配置重新加载完成 ✅\n\t"
sub_end 0
