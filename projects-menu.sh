#!/bin/bash

EDITOR_FILTER="$1"

has_command() {
    command -v "$1" >/dev/null 2>&1
}

has_command walker || { echo "walker is required (dmenu-compatible)"; exit 1; }

get_mtime() {
    stat -c "%y" "$1" 2>/dev/null | sed 's/ /T/; s/\..*//' || date -u +"%Y-%m-%dT%H:%M:%S"
}

get_codium_workspaces() {
    local name="$1" config_path="$2" cmd="$3"
    [[ ! -d "$config_path" ]] && return
    shopt -s nullglob
    for dir in "$config_path"/*/; do
        [[ ! -f "${dir}workspace.json" ]] && continue
        
        local folder
        if has_command jq; then
            folder=$(jq -r '.folder // empty' "${dir}workspace.json" 2>/dev/null)
        else
            folder=$(grep -o '"folder"[[:space:]]*:[[:space:]]*"[^"]*"' "${dir}workspace.json" 2>/dev/null | \
                     sed 's/.*"folder"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -n1)
            [[ -z "$folder" ]] && echo "jq not found; falling back to grep/sed." >&2
        fi
        
        [[ -z "$folder" ]] && continue
        folder="${folder#file://}"
        [[ ! -d "$folder" ]] && continue
        
        echo "$(basename "$folder")|${folder}|$(get_mtime "$dir")|${name}|${cmd}"
    done
    shopt -u nullglob
}

get_zed_workspaces() {
    local config_path="$1"
    [[ ! -d "$config_path" ]] && return
    if ! has_command sqlite3; then
        echo "sqlite3 not found; skipping Zed workspaces." >&2
        return
    fi
    
    local query="SELECT paths, timestamp FROM workspaces WHERE paths IS NOT NULL AND paths != '' ORDER BY timestamp DESC;"
    shopt -s nullglob
    local zed_dirs=("$config_path"/0-*/)
    [[ ${#zed_dirs[@]} -eq 0 ]] && { shopt -u nullglob; return; }
    for dir in "${zed_dirs[@]}"; do
        [[ "$(basename "$dir")" == "0-global" ]] && continue
        [[ ! -f "${dir}db.sqlite" ]] && continue
        
        sqlite3 "${dir}db.sqlite" "$query" 2>/dev/null | while IFS='|' read -r paths_str mtime; do
            [[ -z "$paths_str" ]] && continue
            
            local folder_path
            if [[ "$paths_str" =~ ^\[ ]]; then
                folder_path=$(has_command jq && echo "$paths_str" | jq -r '.[0] // empty' 2>/dev/null || \
                             echo "$paths_str" | sed -n 's/.*"\([^"]*\)".*/\1/p' | head -n1)
            else
                folder_path=$(has_command jq && echo "$paths_str" | jq -r '. // empty' 2>/dev/null || echo "$paths_str")
                [[ -z "$folder_path" ]] && folder_path="$paths_str"
            fi
            
            [[ -z "$folder_path" ]] || [[ ! -d "$folder_path" ]] && continue
            
            local timestamp=$(date -u -d "@$mtime" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || \
                              date -u -d "$mtime" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || \
                              date -u +"%Y-%m-%dT%H:%M:%S")
            
            echo "$(basename "$folder_path")|${folder_path}|${timestamp}|Zed|zeditor"
        done
    done
    shopt -u nullglob
}

get_workspaces() {
    case "$4" in
        codium) get_codium_workspaces "$1" "$2" "$3" ;;
        zed) get_zed_workspaces "$2" ;;
    esac
}

get_installed_editors() {
    local home="${HOME}"
    
    [[ -d "${home}/.config/Cursor/User/workspaceStorage" ]] && has_command cursor && \
        echo "Cursor|${home}/.config/Cursor/User/workspaceStorage|cursor|codium"
    
    [[ -d "${home}/.config/Code/User/workspaceStorage" ]] && has_command code && \
        echo "VS Code|${home}/.config/Code/User/workspaceStorage|code|codium"
    
    [[ -d "${home}/.config/VSCodium/User/workspaceStorage" ]] && has_command codium && \
        echo "VSCodium|${home}/.config/VSCodium/User/workspaceStorage|codium|codium"
    
    if [[ -d "${home}/.local/share/zed/db" ]] && has_command zeditor; then
        if find "${home}/.local/share/zed/db" -mindepth 1 -maxdepth 1 -type d -name "0-*" ! -name "0-global" -quit 2>/dev/null; then
            echo "Zed|${home}/.local/share/zed/db|zeditor|zed"
        fi
    fi
}

get_tabs() {
    all_count=0
    
    while IFS='|' read -r name config_path cmd editor_type; do
        count=$(get_workspaces "$name" "$config_path" "$cmd" "$editor_type" | grep -c . || echo "0")
        all_count=$((all_count + count))
        echo "${name} (${count})|${name}"
    done < <(get_installed_editors)
    
    echo "All (${all_count})|all"
    echo "───|divider"
    echo "➕ Create New Project|create"
}

get_projects() {
    local filter="${1,,}"
    [[ -z "$filter" ]] && filter="all"
    
    all_workspaces=()
    while IFS='|' read -r name config_path cmd editor_type; do
        [[ "$filter" != "all" ]] && \
            [[ ! "${name,,}" == *"$filter"* ]] && \
            [[ ! "${cmd,,}" == *"$filter"* ]] && continue
        
        while IFS= read -r workspace; do
            [[ -n "$workspace" ]] && all_workspaces+=("$workspace")
        done < <(get_workspaces "$name" "$config_path" "$cmd" "$editor_type")
    done < <(get_installed_editors)
    
    printf '%s\n' "${all_workspaces[@]}" | \
        awk -F'|' '{
            split($3, dt, "T")
            split(dt[1], date, "-")
            split(dt[2], time, ":")
            print date[1] date[2] date[3] time[1] time[2] time[3] "|" $0
        }' | \
        sort -t'|' -k1 -r | \
        sed 's/^[^|]*|//' | \
        awk -F'|' -v filter="$filter" '{
            if (filter == "all")
                print $1 " (" $4 ")|" $2 "|" $3 "|" $4 "|" $5
            else
                print $1 "|" $2 "|" $3 "|" $4 "|" $5
        }'
}

# Source project creation functionality
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/create-project.sh"

if [[ -z "$EDITOR_FILTER" ]]; then
    tabs=$(get_tabs)
    tab_count=$(echo "$tabs" | grep -v '|divider$' | grep -v '|create$' | wc -l)
    
    if [[ $tab_count -eq 1 ]]; then
        EDITOR_FILTER=$(echo "$tabs" | grep -v '|divider$' | grep -v '|create$' | awk -F'|' '{print $2}')
    else
        selected_tab=$(echo "$tabs" | cut -d'|' -f1 | walker --dmenu -p "Select IDE…")
        [[ -z "$selected_tab" ]] && exit 0
        
        # Check if "Create New Project" was selected
        if [[ "$selected_tab" == "➕ Create New Project" ]]; then
            all_projects=$(get_projects "all")
            create_new_project "" "$all_projects"
            exit 0
        fi
        
        # Skip divider
        [[ "$selected_tab" == "───" ]] && exit 0
        
        # Match by display name and get the filter value
        EDITOR_FILTER=$(echo "$tabs" | awk -F'|' -v sel="$selected_tab" '$1 == sel {print $2; exit}')
        [[ -z "$EDITOR_FILTER" ]] && exit 0
    fi
fi

projects=$(get_projects "$EDITOR_FILTER")
if [[ -z "$projects" ]]; then
    echo "No projects found." >&2
    exit 0
fi

case "$EDITOR_FILTER" in
    all|"") prompt="All Projects…" ;;
    cursor) prompt="Cursor Projects…" ;;
    "VS Code") prompt="VS Code Projects…" ;;
    VSCodium) prompt="VSCodium Projects…" ;;
    Zed|zeditor) prompt="Zed Projects…" ;;
    *) prompt="Projects…" ;;
esac

selected=$(echo "$projects" | cut -d'|' -f1 | walker --dmenu -p "$prompt")
[[ -z "$selected" ]] && exit 0

project_line=$(echo "$projects" | awk -F'|' -v sel="$selected" '$1 == sel')
[[ -z "$project_line" ]] && exit 0

folder=$(echo "$project_line" | cut -d'|' -f2)
cmd=$(echo "$project_line" | cut -d'|' -f5)

if [[ -z "$cmd" ]]; then
    echo "No launch command found for selection." >&2
    exit 1
fi

"$cmd" "$folder"
