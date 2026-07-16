# Shared GitHub access helpers for Villode install/update.
# Source from install.sh / update.sh. Safe to source multiple times.

# Prefer reachable mirrors first: github.com is often slow or blocked.
# Override with space/comma-separated list, e.g.:
#   VILLODE_GITHUB_MIRRORS="kkgithub.com,ghproxy.net"
# Prefer direct GitHub first:
#   VILLODE_PREFER_GITHUB_DIRECT=1
# Per-attempt timeout seconds (default 12):
#   VILLODE_GIT_TIMEOUT=12
# Force a single channel remote (update channel only):
#   VILLODE_UPDATE_REMOTE=https://kkgithub.com/u0n0u/villode-caelestia.git
# Preferred source key from install-time speed test (github.com|kkgithub.com|...|auto):
#   VILLODE_GITHUB_SOURCE=kkgithub.com
# Probe timeout per candidate (default 8):
#   VILLODE_PROBE_TIMEOUT=8

: "${VILLODE_GIT_TIMEOUT:=12}"
: "${VILLODE_PREFER_GITHUB_DIRECT:=0}"
: "${VILLODE_PROBE_TIMEOUT:=8}"
: "${VILLODE_GITHUB_SOURCE:=auto}"
# Canonical repo used only for speed probes (shallow ls-remote).
: "${VILLODE_PROBE_REPO:=u0n0u/villode-caelestia}"

villode_git_timeout() {
    local secs="${1:-$VILLODE_GIT_TIMEOUT}"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --signal=TERM --kill-after=3 "$secs" "$@"
    else
        "$@"
    fi
}

# Apply soft hang guards for git HTTPS transfers.
villode_git_env() {
    export GIT_TERMINAL_PROMPT=0
    export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1024}"
    export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-15}"
}

# True if URL points at github.com (including mirror-wrapped forms we rewrite).
villode_is_github_url() {
    local url="${1:-}"
    [[ "$url" == *github.com* || "$url" == *kkgithub.com* || "$url" == *ghproxy.net*/*github.com* ]]
}

# Extract canonical https://github.com/owner/repo(.git) form when possible.
villode_canonical_github_url() {
    local url="${1:-}" path
    if [[ "$url" =~ github\.com[:/]+([^/]+/[^/]+) ]]; then
        path="${BASH_REMATCH[1]}"
        path="${path%.git}"
        printf 'https://github.com/%s.git\n' "$path"
        return 0
    fi
    if [[ "$url" =~ kkgithub\.com[:/]+([^/]+/[^/]+) ]]; then
        path="${BASH_REMATCH[1]}"
        path="${path%.git}"
        printf 'https://github.com/%s.git\n' "$path"
        return 0
    fi
    printf '%s\n' "$url"
}

# Build a fetch URL for a known source key + github path (owner/repo).
villode_source_url_for() {
    local key="$1" path="$2"
    path="${path%.git}"
    case "$key" in
        github.com|direct)
            printf 'https://github.com/%s.git\n' "$path"
            ;;
        kkgithub.com)
            printf 'https://kkgithub.com/%s.git\n' "$path"
            ;;
        ghproxy.net)
            printf 'https://ghproxy.net/https://github.com/%s.git\n' "$path"
            ;;
        mirror.ghproxy.com)
            printf 'https://mirror.ghproxy.com/https://github.com/%s.git\n' "$path"
            ;;
        gitclone.com)
            printf 'https://gitclone.com/github.com/%s.git\n' "$path"
            ;;
        *)
            printf 'https://%s/%s.git\n' "$key" "$path"
            ;;
    esac
}

# Default probe candidate keys (order is display order before speed sort).
villode_default_source_keys() {
    printf '%s\n' kkgithub.com ghproxy.net github.com
}

# Human label for a source key.
villode_source_label() {
    case "$1" in
        github.com|direct) echo "github.com（直连）" ;;
        kkgithub.com) echo "kkgithub.com（镜像）" ;;
        ghproxy.net) echo "ghproxy.net（代理）" ;;
        mirror.ghproxy.com) echo "mirror.ghproxy.com（代理）" ;;
        gitclone.com) echo "gitclone.com（镜像）" ;;
        auto) echo "自动（按速度排序，失败切换）" ;;
        *) echo "$1" ;;
    esac
}

# Print candidate clone/fetch URLs (one per line), preferred order first.
villode_github_url_candidates() {
    local url="${1:-}" canon mirrors m host path
    local -a ordered=()
    local key seen=""
    canon="$(villode_canonical_github_url "$url")"

    if [[ "$canon" != https://github.com/* ]]; then
        printf '%s\n' "$url"
        return 0
    fi

    path="${canon#https://github.com/}"
    path="${path%.git}"

    mirrors="${VILLODE_GITHUB_MIRRORS:-kkgithub.com,ghproxy.net}"
    mirrors="${mirrors//,/ }"

    # Preferred single source (from install-time choice) goes first.
    key="${VILLODE_GITHUB_SOURCE:-auto}"
    case "$key" in
        ""|auto) ;;
        github.com|direct)
            ordered+=("$(villode_source_url_for github.com "$path")")
            seen=" github.com "
            ;;
        *)
            ordered+=("$(villode_source_url_for "$key" "$path")")
            seen=" $key "
            ;;
    esac

    if [[ "${VILLODE_PREFER_GITHUB_DIRECT}" == 1 && "$seen" != *" github.com "* ]]; then
        ordered+=("$canon")
        seen+="github.com "
    fi

    for m in $mirrors; do
        m="${m//[[:space:]]/}"
        [[ -n "$m" ]] || continue
        case "$m" in
            kkgithub.com|https://kkgithub.com|http://kkgithub.com) key=kkgithub.com ;;
            ghproxy.net|https://ghproxy.net|http://ghproxy.net) key=ghproxy.net ;;
            mirror.ghproxy.com|https://mirror.ghproxy.com) key=mirror.ghproxy.com ;;
            gitclone.com|https://gitclone.com) key=gitclone.com ;;
            github.com|https://github.com) key=github.com ;;
            *)
                host="${m#https://}"
                host="${host#http://}"
                host="${host%%/*}"
                key="$host"
                ;;
        esac
        [[ "$seen" == *" $key "* ]] && continue
        ordered+=("$(villode_source_url_for "$key" "$path")")
        seen+="$key "
    done

    if [[ "$seen" != *" github.com "* ]]; then
        ordered+=("$canon")
    fi

    # De-dup while preserving order.
    seen=""
    for m in "${ordered[@]}"; do
        [[ -n "$m" ]] || continue
        [[ "$seen" == *" $m "* ]] && continue
        printf '%s\n' "$m"
        seen+="$m "
    done
}

# Milliseconds since epoch (best-effort).
villode_now_ms() {
    local t
    t="$(date +%s%3N 2>/dev/null || true)"
    if [[ "$t" =~ ^[0-9]{13,}$ ]]; then
        printf '%s\n' "$t"
        return
    fi
    # Fallback: seconds → ms (coarser).
    printf '%s000\n' "$(date +%s)"
}

# Probe one source key. Prints: key<TAB>ms_or_-1<TAB>ok|fail
villode_probe_source_once() {
    local key="$1" path="${2:-$VILLODE_PROBE_REPO}" url start end ms rc=0
    url="$(villode_source_url_for "$key" "$path")"
    villode_git_env
    start="$(villode_now_ms)"
    if villode_git_timeout "$VILLODE_PROBE_TIMEOUT" \
        git ls-remote "$url" HEAD >/dev/null 2>&1; then
        rc=0
    else
        rc=1
    fi
    end="$(villode_now_ms)"
    ms=$(( end - start ))
    (( ms < 0 )) && ms=0
    if [[ $rc -eq 0 ]]; then
        printf '%s\t%s\tok\n' "$key" "$ms"
    else
        printf '%s\t-1\tfail\n' "$key"
    fi
}

# Probe all default (or provided) sources. Prints TSV lines: key ms status
# Args: optional list of keys.
villode_probe_github_sources() {
    local -a keys=("$@")
    local key
    if ((${#keys[@]} == 0)); then
        mapfile -t keys < <(villode_default_source_keys)
    fi
    villode_git_env
    for key in "${keys[@]}"; do
        villode_probe_source_once "$key"
    done
}

# Format ms for display: "0.8s" / "超时" / "3s"
villode_format_probe_ms() {
    local ms="$1" status="${2:-ok}"
    if [[ "$status" != ok || "$ms" == -1 ]]; then
        echo "超时"
        return
    fi
    # integer ms → seconds with 1 decimal when < 10s
    if (( ms < 1000 )); then
        printf '%dms\n' "$ms"
    elif (( ms < 10000 )); then
        awk -v m="$ms" 'BEGIN { printf "%.1fs\n", m/1000 }'
    else
        awk -v m="$ms" 'BEGIN { printf "%.0fs\n", m/1000 }'
    fi
}

# Apply a user/source preference to env used by fetch helpers.
# Args: source_key (auto|github.com|kkgithub.com|...)
#        optional ordered_keys (space-separated) for auto fallback list
villode_apply_github_source() {
    local source="${1:-auto}" ordered="${2:-}"
    local -a list=()
    local k

    VILLODE_GITHUB_SOURCE="$source"
    export VILLODE_GITHUB_SOURCE

    if [[ -n "$ordered" ]]; then
        # shellcheck disable=SC2206
        list=($ordered)
    else
        mapfile -t list < <(villode_default_source_keys)
    fi

    case "$source" in
        auto)
            VILLODE_PREFER_GITHUB_DIRECT=0
            # Keep ordered list as mirrors (exclude pure github.com entry;
            # direct is appended by candidates helper).
            local mirrors=()
            for k in "${list[@]}"; do
                [[ "$k" == github.com || "$k" == direct ]] && continue
                mirrors+=("$k")
            done
            if ((${#mirrors[@]})); then
                VILLODE_GITHUB_MIRRORS="$(IFS=,; echo "${mirrors[*]}")"
            else
                VILLODE_GITHUB_MIRRORS="kkgithub.com,ghproxy.net"
            fi
            ;;
        github.com|direct)
            VILLODE_GITHUB_SOURCE=github.com
            VILLODE_PREFER_GITHUB_DIRECT=1
            # Still keep mirrors as fallback after direct.
            local mirrors=()
            for k in "${list[@]}"; do
                [[ "$k" == github.com || "$k" == direct ]] && continue
                mirrors+=("$k")
            done
            VILLODE_GITHUB_MIRRORS="$(IFS=,; echo "${mirrors[*]:-kkgithub.com,ghproxy.net}")"
            ;;
        *)
            VILLODE_PREFER_GITHUB_DIRECT=0
            # Chosen first, then other working keys.
            local mirrors=("$source")
            for k in "${list[@]}"; do
                [[ "$k" == "$source" || "$k" == github.com || "$k" == direct ]] && continue
                mirrors+=("$k")
            done
            VILLODE_GITHUB_MIRRORS="$(IFS=,; echo "${mirrors[*]}")"
            ;;
    esac
    export VILLODE_PREFER_GITHUB_DIRECT VILLODE_GITHUB_MIRRORS
}

# Interactive / non-interactive speed test + selection.
# Sets: VILLODE_GITHUB_SOURCE, VILLODE_GITHUB_MIRRORS, VILLODE_PREFER_GITHUB_DIRECT
# Prints a short summary to stderr.
# Env:
#   VILLODE_GITHUB_SOURCE_FORCE  if set, skip prompt and apply that key
#   VILLODE_SKIP_PROBE=1         skip probe, keep current env
villode_select_github_source() {
    local force="${VILLODE_GITHUB_SOURCE_FORCE:-}"
    local skip="${VILLODE_SKIP_PROBE:-0}"
    local interactive=0
    local line key ms status label disp i answer
    local -a keys=() results_key=() results_ms=() results_status=()
    local -a working_keys=() working_ms=()
    local -a menu_keys=() # parallel to display numbers
    local best_key="" best_ms=999999999

    [[ -t 0 && -t 1 ]] && interactive=1

    if [[ "$skip" == 1 ]]; then
        villode_apply_github_source "${VILLODE_GITHUB_SOURCE:-auto}"
        return 0
    fi

    if [[ -n "$force" && "$force" != probe && "$force" != auto ]]; then
        villode_apply_github_source "$force"
        echo "已使用指定更新通道：$(villode_source_label "$force")" >&2
        return 0
    fi

    echo >&2
    echo "正在测试 GitHub 访问通道（每个最多 ${VILLODE_PROBE_TIMEOUT}s）…" >&2
    echo >&2

    mapfile -t keys < <(villode_default_source_keys)
    i=0
    for key in "${keys[@]}"; do
        line="$(villode_probe_source_once "$key")"
        ms="$(cut -f2 <<< "$line")"
        status="$(cut -f3 <<< "$line")"
        results_key+=("$key")
        results_ms+=("$ms")
        results_status+=("$status")
        label="$(villode_source_label "$key")"
        disp="$(villode_format_probe_ms "$ms" "$status")"
        if [[ "$status" == ok ]]; then
            printf '  %s  %-28s  %s\n' "✓" "$label" "$disp" >&2
            working_keys+=("$key")
            working_ms+=("$ms")
            if (( ms < best_ms )); then
                best_ms=$ms
                best_key="$key"
            fi
        else
            printf '  %s  %-28s  %s\n' "✗" "$label" "超时/失败" >&2
        fi
        i=$((i + 1))
    done
    echo >&2

    if ((${#working_keys[@]} == 0)); then
        echo "所有通道均不可达。将保留自动回退；安装可能失败或仅能用本地缓存。" >&2
        villode_apply_github_source auto
        return 0
    fi

    # Sort working keys by ms ascending (stable simple sort).
    local -a sorted_keys=() sorted_ms=()
    local j min_i
    local -a left_keys=("${working_keys[@]}") left_ms=("${working_ms[@]}")
    while ((${#left_keys[@]})); do
        min_i=0
        for j in "${!left_keys[@]}"; do
            if (( left_ms[j] < left_ms[min_i] )); then
                min_i=$j
            fi
        done
        sorted_keys+=("${left_keys[min_i]}")
        sorted_ms+=("${left_ms[min_i]}")
        unset "left_keys[min_i]" "left_ms[min_i]"
        left_keys=("${left_keys[@]}")
        left_ms=("${left_ms[@]}")
    done

    # Non-interactive or force=auto/probe without TTY: pick fastest.
    if [[ "$interactive" != 1 || "$force" == auto || "$force" == probe ]]; then
        if [[ "$force" == auto || "$interactive" != 1 ]]; then
            villode_apply_github_source auto "${sorted_keys[*]}"
            echo "已自动选择最快通道优先：$(villode_source_label "${sorted_keys[0]}")（${sorted_ms[0]}ms 级，失败自动切换）" >&2
            return 0
        fi
    fi

    echo "请选择之后安装/更新使用的通道：" >&2
    echo "  a. 自动（按速度排序，失败自动切换）  [推荐，最快 $(villode_source_label "${sorted_keys[0]}")]" >&2
    menu_keys=()
    i=1
    for j in "${!sorted_keys[@]}"; do
        key="${sorted_keys[j]}"
        disp="$(villode_format_probe_ms "${sorted_ms[j]}" ok)"
        printf '  %d. 仅优先 %s（%s，失败仍尝试其他）\n' "$i" "$(villode_source_label "$key")" "$disp" >&2
        menu_keys+=("$key")
        i=$((i + 1))
    done
    echo >&2
    read -r -p "输入编号（默认 a）：" answer || answer=a
    answer="${answer:-a}"
    answer="${answer//[[:space:]]/}"

    if [[ "$answer" == "a" || "$answer" == "A" ]]; then
        villode_apply_github_source auto "${sorted_keys[*]}"
        echo "已选择：自动（优先 $(villode_source_label "${sorted_keys[0]}")）" >&2
        return 0
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#menu_keys[@]} )); then
        key="${menu_keys[answer - 1]}"
        villode_apply_github_source "$key" "${sorted_keys[*]}"
        echo "已选择：$(villode_source_label "$key")" >&2
        return 0
    fi
    echo "无效输入，改用自动。" >&2
    villode_apply_github_source auto "${sorted_keys[*]}"
}

# Run a git network op against the first working candidate URL.
# Usage: villode_git_with_mirrors <base-url> <git-args-with-URL-placeholder...>
# Put the token __URL__ where the remote URL should be substituted.
# Prints the successful URL on stdout when VILLODE_GIT_PRINT_URL=1.
# Returns 0 on first success, non-zero if all candidates fail.
villode_git_with_mirrors() {
    local base_url="$1"
    shift
    local -a template=("$@")
    local candidate rc=1 used=""
    local -a cmd

    villode_git_env

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        cmd=()
        for part in "${template[@]}"; do
            if [[ "$part" == __URL__ ]]; then
                cmd+=("$candidate")
            else
                cmd+=("$part")
            fi
        done
        if villode_git_timeout "$VILLODE_GIT_TIMEOUT" git "${cmd[@]}"; then
            used="$candidate"
            rc=0
            break
        fi
    done < <(villode_github_url_candidates "$base_url")

    if [[ $rc -eq 0 && "${VILLODE_GIT_PRINT_URL:-0}" == 1 && -n "$used" ]]; then
        printf '%s\n' "$used" >&2
    fi
    return $rc
}

# Clone shallow channel/repo into dest using mirrors.
villode_git_clone_shallow() {
    local url="$1" dest="$2"
    shift 2
    villode_git_with_mirrors "$url" clone -q --filter=blob:none --depth=1 "$@" __URL__ "$dest"
}

# Fetch into an existing git dir (cwd or -C handled by caller via args).
# Example: villode_git_fetch_into /path/to/repo https://github.com/o/r.git --depth=1 origin main
# Actually we need remote URL set. Better:
# villode_git_fetch_ref <repo_dir> <url> <ref>
villode_git_fetch_ref() {
    local repo_dir="$1" url="$2" ref="$3"
    local candidate
    villode_git_env
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        git -C "$repo_dir" remote set-url origin "$candidate" 2>/dev/null || {
            git -C "$repo_dir" remote remove origin 2>/dev/null || true
            git -C "$repo_dir" remote add origin "$candidate" 2>/dev/null || continue
        }
        if villode_git_timeout "$VILLODE_GIT_TIMEOUT" \
            git -C "$repo_dir" fetch -q --depth=1 origin "$ref"; then
            return 0
        fi
    done < <(villode_github_url_candidates "$url")
    return 1
}

# Fetch a commit/object into repo_dir from url (for changelog meta).
villode_git_fetch_commit() {
    local repo_dir="$1" url="$2" commit="$3"
    local candidate
    [[ -n "$commit" ]] || return 0
    villode_git_env
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        git -C "$repo_dir" remote set-url origin "$candidate" 2>/dev/null || {
            git -C "$repo_dir" remote remove origin 2>/dev/null || true
            git -C "$repo_dir" remote add origin "$candidate" 2>/dev/null || continue
        }
        if villode_git_timeout "$VILLODE_GIT_TIMEOUT" \
            git -C "$repo_dir" fetch -q --depth=1 origin "$commit"; then
            return 0
        fi
    done < <(villode_github_url_candidates "$url")
    return 1
}
