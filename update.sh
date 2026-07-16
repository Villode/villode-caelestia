#!/usr/bin/env bash
set -euo pipefail

remote="${VILLODE_UPDATE_REMOTE:-https://github.com/u0n0u/villode-caelestia.git}"
cache_home="${XDG_CACHE_HOME:-$HOME/.cache}/villode-caelestia/update-channel"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}/villode-caelestia"
user_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
data_home="$user_data_home/villode-caelestia"
shell_state_home="${XDG_STATE_HOME:-$HOME/.local/state}/villode-caelestia-shell"
mode=update
network_override=""
install_missing=no
channel_source="" # online-mirror | online-github | offline-cache | offline-release | stale-cache
update_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
resolve_git_net_lib() {
    local candidate
    for candidate in \
        "$update_script_dir/lib/git-net.sh" \
        "$data_home/release/lib/git-net.sh" \
        "$data_home/lib/git-net.sh" \
        "${XDG_DATA_HOME:-$HOME/.local/share}/villode-caelestia/release/lib/git-net.sh"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}
git_net_lib="$(resolve_git_net_lib || true)"
if [[ -n "$git_net_lib" ]]; then
    # shellcheck disable=SC1090
    source "$git_net_lib"
else
    echo "缺少 lib/git-net.sh，无法处理 GitHub 访问回退。" >&2
    exit 69
fi

# Older release channels may predate lib/git-net.sh. Inject the helper and, when
# needed, a modern install.sh so component fetches still get mirror/timeout
# behaviour even if the cached channel tree is from an older release.
ensure_channel_git_net() {
    local channel="$1" dest lib_src install_src
    [[ -n "$channel" && -d "$channel" ]] || return 0
    dest="$channel/lib/git-net.sh"
    lib_src="$(resolve_git_net_lib || true)"
    [[ -n "$lib_src" ]] || return 0
    if [[ ! -f "$dest" ]]; then
        install -Dm644 "$lib_src" "$dest"
    fi
    # Prefer install.sh that already sources git-net.
    if [[ -f "$channel/install.sh" ]] && grep -q 'git-net\.sh' "$channel/install.sh" 2>/dev/null; then
        return 0
    fi
    # Only upgrade known Villode installers — never overwrite stubs/tests.
    if [[ -f "$channel/install.sh" ]] &&
       ! grep -qE 'prefetch_component|villode-caelestia|acquire_operation_lock' \
            "$channel/install.sh" 2>/dev/null; then
        return 0
    fi
    install_src=""
    if [[ -f "$update_script_dir/install.sh" ]] && grep -q 'git-net\.sh' "$update_script_dir/install.sh" 2>/dev/null; then
        install_src="$update_script_dir/install.sh"
    elif [[ -f "$data_home/release/install.sh" ]] && grep -q 'git-net\.sh' "$data_home/release/install.sh" 2>/dev/null; then
        install_src="$data_home/release/install.sh"
    fi
    if [[ -n "$install_src" ]]; then
        install -Dm755 "$install_src" "$channel/install.sh"
        install -Dm644 "$lib_src" "$dest"
    fi
}


acquire_operation_lock() {
    local lock_file="$state_home/operation.lock" rc
    [[ "${VILLODE_OPERATION_LOCK_HELD:-}" == 1 ]] && return 0
    command -v flock >/dev/null 2>&1 || {
        echo "缺少更新器并发保护所需的 flock。" >&2
        exit 69
    }
    install -d -m700 "$state_home"
    : > "$lock_file"
    chmod 600 "$lock_file"
    if flock --exclusive --nonblock --close --conflict-exit-code 75 \
        "$lock_file" env VILLODE_OPERATION_LOCK_HELD=1 "$0" "$@"; then
        exit 0
    else
        rc=$?
    fi
    [[ "$rc" == 75 ]] && echo "另一个 Villode 安装、更新或卸载操作正在进行。" >&2
    exit "$rc"
}

acquire_operation_lock "$@"

usage() {
    cat <<'EOF'
用法：villode-caelestia-update [--check|--check-json] [--online|--offline] [--install-missing]

  --check       仅检查，不安装（制表符摘要）
  --check-json  仅检查，输出详细 JSON（供设置页展示）
  --online      本次允许联网（执行安装时会保存在线更新模式）
  --offline     仅使用已缓存的发布渠道和组件源码，绝不联网或安装依赖
  --install-missing  同时安装尚未安装的可选组件（默认只同步已安装组件）
EOF
}

while (($#)); do
    case "$1" in
        --check) mode=check ;;
        --check-json) mode=check-json ;;
        --online) network_override=online ;;
        --offline) network_override=offline ;;
        --install-missing) install_missing=yes ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 64 ;;
    esac
    shift
done

option_value() {
    local key="$1" default="$2" file="$state_home/install-options" value
    if [[ -f "$file" ]]; then
        value="$(awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$file")"
    fi
    printf '%s\n' "${value:-$default}"
}

legacy_session_default() {
    if [[ -f "$state_home/session-managed" ||
          -f "$HOME/.config/villode-hyprland/hyprland.conf" ]]; then
        echo yes
    else
        echo no
    fi
}

legacy_hyprland_default() {
    if [[ -f "$state_home/session-managed" ||
          -f "$HOME/.config/villode-hyprland/hyprland.conf" ||
          -f "$HOME/.config/hypr/config/villode-suite.lua" ||
          -f "$HOME/.config/hypr/config/villode-launcher.lua" ]]; then
        echo yes
    else
        echo no
    fi
}

offline_mode="$(option_value offline no)"
case "$network_override" in
    online) offline_mode=no ;;
    offline) offline_mode=yes ;;
esac

# Restore install-time GitHub channel preference (speed-test choice).
# Explicit process env wins over install-options.
_saved_source="$(option_value github_source "")"
_saved_mirrors="$(option_value github_mirrors "")"
_saved_prefer="$(option_value github_prefer_direct "")"
if [[ -n "${VILLODE_GITHUB_SOURCE:-}" && "${VILLODE_GITHUB_SOURCE}" != auto ]]; then
    villode_apply_github_source "$VILLODE_GITHUB_SOURCE" \
        "${VILLODE_GITHUB_MIRRORS:-${_saved_mirrors//,/ }}"
elif [[ -n "$_saved_source" ]]; then
    export VILLODE_GITHUB_MIRRORS="${VILLODE_GITHUB_MIRRORS:-$_saved_mirrors}"
    export VILLODE_PREFER_GITHUB_DIRECT="${VILLODE_PREFER_GITHUB_DIRECT:-${_saved_prefer:-0}}"
    villode_apply_github_source "$_saved_source" "${_saved_mirrors//,/ }"
else
    villode_apply_github_source auto
fi
unset _saved_source _saved_mirrors _saved_prefer

validate_channel() {
    local dir="$1"
    [[ -f "$dir/components.tsv" && -x "$dir/install.sh" ]]
}

use_local_channel_fallback() {
    local installed_release="$data_home/release" reason="${1:-}"
    if validate_channel "$cache_home"; then
        channel_dir="$cache_home"
        channel_source="stale-cache"
        [[ -n "$reason" ]] && echo "$reason；改用本地更新渠道缓存。" >&2
        return 0
    fi
    if validate_channel "$installed_release"; then
        channel_dir="$installed_release"
        channel_source="offline-release"
        [[ -n "$reason" ]] && echo "$reason；改用已安装的发布渠道。" >&2
        return 0
    fi
    return 1
}

refresh_channel() {
    local installed_release="$data_home/release" err
    if [[ "$offline_mode" == yes ]]; then
        if validate_channel "$cache_home"; then
            channel_dir="$cache_home"
            channel_source="offline-cache"
        elif validate_channel "$installed_release"; then
            channel_dir="$installed_release"
            channel_source="offline-release"
        else
            echo "离线模式下没有可用的发布渠道缓存。" >&2
            exit 69
        fi
        return
    fi

    command -v git >/dev/null 2>&1 || {
        if use_local_channel_fallback "未安装 git，无法在线检查更新"; then
            return
        fi
        echo "检查在线更新需要 git。" >&2
        exit 69
    }
    mkdir -p "$(dirname "$cache_home")"
    err="$(mktemp)"
    if [[ ! -d "$cache_home/.git" ]]; then
        rm -rf "$cache_home"
        if ! villode_git_clone_shallow "$remote" "$cache_home" 2>"$err"; then
            rm -rf "$cache_home"
            if use_local_channel_fallback "无法从 GitHub/镜像拉取更新渠道"; then
                rm -f "$err"
                return
            fi
            echo "无法从 GitHub 或镜像获取更新渠道（网络超时或不可达）。" >&2
            [[ -s "$err" ]] && sed 's/^/  /' "$err" >&2
            rm -f "$err"
            exit 69
        fi
    else
        if ! villode_git_fetch_ref "$cache_home" "$remote" main 2>"$err"; then
            if use_local_channel_fallback "在线刷新更新渠道失败"; then
                rm -f "$err"
                return
            fi
            echo "无法刷新更新渠道（GitHub/镜像均不可达）。" >&2
            [[ -s "$err" ]] && sed 's/^/  /' "$err" >&2
            rm -f "$err"
            exit 69
        fi
        git -C "$cache_home" reset -q --hard FETCH_HEAD
    fi
    rm -f "$err"
    validate_channel "$cache_home" || {
        echo "更新渠道内容不完整，拒绝继续。" >&2
        exit 66
    }
    channel_dir="$cache_home"
    # Prefer "github" only for the canonical host; proxy URLs also contain
    # the substring github.com (e.g. ghproxy.net/https://github.com/...).
    if git -C "$cache_home" remote get-url origin 2>/dev/null | grep -Eq '^https?://github\.com/'; then
        channel_source="online-github"
    else
        channel_source="online-mirror"
    fi
}

state_commit() {
    local file="$state_home/$1.tsv"
    if [[ -f "$file" ]]; then
        awk -F '\t' 'NR == 1 { print $2 }' "$file"
    fi
    return 0
}

installed_manifest_commit() {
    local id="$1" manifest="$data_home/components.tsv"
    if [[ -f "$manifest" ]]; then
        awk -F '\t' -v id="$id" '$1 == id { print $3; exit }' "$manifest"
    fi
    return 0
}

component_evidence() {
    case "$1" in
        shell)
            [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/caelestia/.villode-managed" ]]
            ;;
        zh)
            [[ -x "$HOME/.local/bin/caelestia-zh-apply" &&
               -f "$user_data_home/caelestia-zh-cn/i18n/qml_zh_CN.qm" ]] &&
                "$HOME/.local/bin/caelestia-zh-apply" --check >/dev/null 2>&1
            ;;
        dock) [[ -x "$HOME/.local/bin/villode-dock" ]] ;;
        desktop) [[ -x "$HOME/.local/bin/villode-desktop" ]] ;;
        launcher) [[ -x "$HOME/.local/bin/villode-launcher" ]] ;;
        cursor) [[ -x "$HOME/.local/bin/villode-cursor-shake" ]] ;;
        *) return 1 ;;
    esac
}

# Sets: installed, repair_needed, component_present.
resolve_installed() {
    local id="$1" recorded="" actual="" marker="" fallback="" managed_revision=""
    installed=""
    repair_needed=false
    component_present=false
    recorded="$(state_commit "$id")"

    if [[ "$id" == shell ]]; then
        marker="$shell_state_home/revision"
    else
        marker="$data_home/components/$id/revision"
    fi
    [[ -f "$marker" ]] && actual="$(sed -n '1p' "$marker")"

    if [[ "$id" == shell ]]; then
        managed_revision="$(awk -F ': *' '$1 == "Revision" { print $2; exit }' \
            "${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/caelestia/.villode-managed" \
            2>/dev/null || true)"
    fi

    evidence_present=false
    if component_evidence "$id"; then
        evidence_present=true
    fi
    if $evidence_present || [[ -n "$actual" ]]; then
        component_present=true
    fi
    if [[ -n "$actual" ]]; then
        installed="$actual"
        if [[ -z "$recorded" || "$recorded" != "$actual" ]] || ! $evidence_present; then
            repair_needed=true
        fi
        if [[ "$id" == shell && "$managed_revision" != "$actual" ]]; then
            repair_needed=true
        fi
    elif $component_present; then
        fallback="${recorded:-$(installed_manifest_commit "$id")}"
        installed="$fallback"
        # Legacy installs did not have an independently verifiable component
        # revision. Reinstall once to establish one.
        repair_needed=true
    elif [[ -n "$recorded" ]]; then
        installed="$recorded"
        component_present=true
        repair_needed=true
    fi
}

component_source_dir() {
    local id="$1"
    local candidates=(
        "${XDG_CACHE_HOME:-$HOME/.cache}/villode-caelestia/sources/$id"
        "$data_home/components/$id"
        "$cache_home/components/$id"
    )
    local dir
    for dir in "${candidates[@]}"; do
        if [[ -d "$dir/.git" || -d "$dir" ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done
    return 1
}

sources_home="${XDG_CACHE_HOME:-$HOME/.cache}/villode-caelestia/sources"

# Ensure local component git cache has the commits needed for dates/changelog.
# Without this, shallow installs only contain the previously installed tip, so
# "latest" metadata and f941..36d9 changelogs show up empty in the UI.
ensure_component_git_meta() {
    local id="$1" repo_url="$2" installed="$3" latest="$4"
    local src="$sources_home/$id"

    [[ -n "$repo_url" ]] || return 0
    # Use caller's offline_mode (do not local-shadow it).
    [[ "${offline_mode:-no}" == yes ]] && return 0
    # When the channel itself already fell back to local cache, skip extra
    # GitHub traffic for changelog metadata so the settings page stays snappy.
    case "${channel_source:-}" in
        stale-cache|offline-cache|offline-release) return 0 ;;
    esac
    command -v git >/dev/null 2>&1 || return 0

    mkdir -p "$sources_home"
    if [[ ! -d "$src/.git" ]]; then
        villode_git_clone_shallow "$repo_url" "$src" 2>/dev/null || return 0
    fi

    # Prefer fetching the pinned latest (and installed base for ranges).
    if [[ -n "$latest" ]] && ! git -C "$src" cat-file -e "${latest}^{commit}" 2>/dev/null; then
        villode_git_fetch_commit "$src" "$repo_url" "$latest" 2>/dev/null || true
    fi
    if [[ -n "$installed" && "$installed" != "$latest" ]] &&
       ! git -C "$src" cat-file -e "${installed}^{commit}" 2>/dev/null; then
        villode_git_fetch_commit "$src" "$repo_url" "$installed" 2>/dev/null || true
    fi
    # Deepen so ${installed}..${latest} can be walked when both tips exist.
    if [[ -n "$installed" && -n "$latest" && "$installed" != "$latest" ]]; then
        villode_git_env
        villode_git_timeout "$VILLODE_GIT_TIMEOUT" \
            git -C "$src" fetch -q --deepen=80 origin 2>/dev/null || true
    fi
    return 0
}

# Prints "ISO8601|subject" for a commit, or empty.
git_commit_meta() {
    local repo="$1" commit="$2"
    [[ -n "$repo" && -n "$commit" && -d "$repo/.git" ]] || return 0
    if git -C "$repo" cat-file -e "${commit}^{commit}" 2>/dev/null; then
        git -C "$repo" log -1 --format='%cI|%s' "$commit" 2>/dev/null || true
    fi
    return 0
}

# Prints up to 12 subject lines of commits in (from, to].
git_changelog_lines() {
    local repo="$1" from="$2" to="$3"
    [[ -n "$repo" && -n "$to" && -d "$repo/.git" ]] || return 0
    if [[ -n "$from" ]] && git -C "$repo" cat-file -e "${from}^{commit}" 2>/dev/null &&
       git -C "$repo" cat-file -e "${to}^{commit}" 2>/dev/null; then
        git -C "$repo" log --format='%s' --no-merges "${from}..${to}" 2>/dev/null | head -n 12 || true
    elif git -C "$repo" cat-file -e "${to}^{commit}" 2>/dev/null; then
        git -C "$repo" log -1 --format='%s' "$to" 2>/dev/null || true
    fi
    return 0
}

state_mtime_iso() {
    local file="$state_home/$1.tsv"
    if [[ -f "$file" ]]; then
        date -d "@$(stat -c '%Y' "$file")" --iso-8601=seconds 2>/dev/null ||
            date -r "$(stat -c '%Y' "$file")" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || true
    fi
    return 0
}

refresh_channel
ensure_channel_git_net "$channel_dir"
manifest="$channel_dir/components.tsv"
actionable=()
missing=()
declare -A action_status
# JSON rows collected as tab-separated payload for python encoder
json_rows_file="$(mktemp)"
trap 'rm -f "$json_rows_file"' EXIT

while IFS=$'\t' read -r id repo latest name; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    resolve_installed "$id"
    if ! $component_present; then
        status="未安装"
        # A plain update must only sync what the user already chose to have;
        # installing missing optional components is an explicit opt-in.
        missing+=("$id")
        if [[ "$install_missing" == yes ]]; then
            actionable+=("$id")
        fi
    elif [[ -n "$installed" && -n "$latest" && "$installed" != "$latest" ]]; then
        status="有更新"
        actionable+=("$id")
    elif $repair_needed; then
        status="需要修复"
        actionable+=("$id")
    else
        status="已是最新"
    fi
    action_status["$id"]="$status"
    if [[ "$mode" != check-json ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$name" "${installed:0:7}" "${latest:0:7}" "$status"
    fi

    if [[ "$mode" == check-json ]]; then
        ensure_component_git_meta "$id" "$repo" "$installed" "$latest"
        src_dir="$(component_source_dir "$id" || true)"
        # Prefer the canonical sources cache after ensure_component_git_meta.
        [[ -d "$sources_home/$id/.git" ]] && src_dir="$sources_home/$id"
        installed_meta="$(git_commit_meta "$src_dir" "$installed")"
        latest_meta="$(git_commit_meta "$src_dir" "$latest")"
        installed_at="${installed_meta%%|*}"
        installed_subject=""
        if [[ "$installed_meta" == *"|"* ]]; then
            installed_subject="${installed_meta#*|}"
        fi
        latest_at="${latest_meta%%|*}"
        latest_subject=""
        if [[ "$latest_meta" == *"|"* ]]; then
            latest_subject="${latest_meta#*|}"
        fi
        # Prefer commit author date; fall back to local install state mtime.
        if [[ -z "$installed_at" ]]; then
            installed_at="$(state_mtime_iso "$id")"
        fi
        changes=""
        if [[ "$status" == "有更新" || "$status" == "需要修复" ]]; then
            changes="$(git_changelog_lines "$src_dir" "$installed" "$latest" | paste -sd '|' -)"
        elif [[ -n "$latest_subject" ]]; then
            changes="$latest_subject"
        elif [[ -n "$installed_subject" ]]; then
            changes="$installed_subject"
        fi
        # Helpful fallbacks when git range is empty / objects still missing.
        if [[ -z "$changes" ]]; then
            if [[ "$status" == "有更新" && -n "$latest_subject" ]]; then
                changes="$latest_subject"
            elif [[ "$status" == "未安装" ]]; then
                case "$id" in
                    cursor)
                        changes="Mac 风格晃动定位指针；未安装时可在此安装"
                        ;;
                    zh)
                        changes="Caelestia 界面简体中文翻译包"
                        ;;
                    dock)
                        changes="底部 Dock 栏"
                        ;;
                    desktop)
                        changes="动态壁纸 / 桌面"
                        ;;
                    launcher)
                        changes="应用启动器"
                        ;;
                    shell)
                        changes="桌面 Shell（面板、通知、设置）"
                        ;;
                    *)
                        changes="可安装此组件"
                        ;;
                esac
            elif [[ "$status" == "需要修复" ]]; then
                case "$id" in
                    zh)
                        changes="中文翻译包或 Shell 翻译框架不完整，需要重新安装"
                        ;;
                    shell)
                        changes="本地 Shell 安装标记不一致，请重新安装以修复"
                        ;;
                    *)
                        changes="本地安装状态不完整，请重新安装以修复"
                        ;;
                esac
            fi
        fi
        # row: id name installed_short latest_short status installed_full latest_full installed_at latest_at changes_pipe
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$name" "${installed:0:7}" "${latest:0:7}" "$status" \
            "${installed:-}" "${latest:-}" "${installed_at:-}" "${latest_at:-}" "${changes:-}" \
            >> "$json_rows_file"
    fi
done < "$manifest"

if [[ "$mode" == check ]]; then
    exit 0
fi

if [[ "$mode" == check-json ]]; then
    python3 - "$json_rows_file" "${channel_source:-}" "${offline_mode:-no}" <<'PY'
import json, sys
from datetime import datetime

path = sys.argv[1]
channel_source = sys.argv[2] if len(sys.argv) > 2 else ""
offline_mode = sys.argv[3] if len(sys.argv) > 3 else "no"
components = []
with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        while len(parts) < 10:
            parts.append("")
        (cid, name, inst_s, lat_s, status, inst_f, lat_f, inst_at, lat_at, changes) = parts[:10]
        change_list = [c for c in changes.split("|") if c.strip()] if changes else []
        components.append({
            "id": cid,
            "name": name,
            "installed": inst_s or "—",
            "latest": lat_s or "—",
            "installedFull": inst_f or "",
            "latestFull": lat_f or "",
            "status": status,
            "installedAt": inst_at or "",
            "releasedAt": lat_at or "",
            "changes": change_list,
        })

source_notes = {
    "online-github": "online-github",
    "online-mirror": "online-mirror",
    "stale-cache": "stale-cache",
    "offline-cache": "offline-cache",
    "offline-release": "offline-release",
}
out = {
    "checkedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
    "components": components,
    # Only states a plain update will act on; "未安装" needs --install-missing.
    "updateCount": sum(1 for c in components if c["status"] in ("有更新", "需要修复")),
    "channelSource": source_notes.get(channel_source, channel_source or "unknown"),
    "offline": offline_mode == "yes",
    "networkDegraded": channel_source in ("stale-cache", "offline-cache", "offline-release"),
}
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
    exit 0
fi

if ((${#actionable[@]} == 0)); then
    echo
    echo "所有已安装的 Villode 组件都是最新版本。"
    if ((${#missing[@]})) && [[ "$install_missing" == no ]]; then
        echo "尚未安装的可选组件：${missing[*]}"
        echo "使用 villode-caelestia-update --install-missing 或重新运行安装器来安装。"
    fi
    exit 0
fi

optional=()
for id in "${actionable[@]}"; do
    [[ "$id" != shell ]] && optional+=("$id")
done
args=(--keep-existing)
if [[ " ${actionable[*]} " != *" shell "* ]] &&
   grep -q -- '--skip-shell' "$channel_dir/install.sh"; then
    args+=(--skip-shell)
fi
if ((${#optional[@]})); then
    components="$(IFS=,; echo "${optional[*]}")"
    args+=(--components "$components")
else
    args+=(--components shell)
fi

if [[ "$offline_mode" == yes ]]; then
    args+=(--offline --no-deps)
else
    # Older installations have no options file. Use conservative defaults so
    # a component update cannot unexpectedly install system packages.
    case "$(option_value dependencies without)" in
        without) args+=(--no-deps) ;;
        *) args+=(--with-deps) ;;
    esac
fi
[[ "$(option_value start yes)" == no ]] && args+=(--no-start)
if [[ "$(option_value hyprland "$(legacy_hyprland_default)")" == no ]]; then
    args+=(--no-hyprland)
elif [[ "$(option_value session "$(legacy_session_default)")" == no ]]; then
    args+=(--no-session)
fi
[[ "$(option_value native_build yes)" == no ]] && args+=(--no-native-build)

echo
syncing=()
if [[ " ${actionable[*]} " == *" shell "* ]]; then
    syncing+=(shell)
fi
syncing+=("${optional[@]}")
echo "即将同步 ${#syncing[@]} 个 Villode 组件：${syncing[*]}"
if ((${#missing[@]})) && [[ "$install_missing" == no ]]; then
    echo "跳过尚未安装的可选组件：${missing[*]}（可用 --install-missing 安装）"
fi
if [[ "$offline_mode" == yes ]]; then
    echo "更新源：本地缓存（离线）"
elif [[ "$channel_source" == online-mirror ]]; then
    echo "更新源：GitHub 镜像（$remote）"
elif [[ "$channel_source" == stale-cache || "$channel_source" == offline-release ]]; then
    echo "更新源：本地发布渠道（GitHub 不可达，使用已缓存版本）"
else
    echo "更新源：$remote"
fi
echo

"$channel_dir/install.sh" "${args[@]}"
