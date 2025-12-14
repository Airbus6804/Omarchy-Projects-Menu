#!/bin/bash
# Project creation functionality

get_project_name() {
    local name
    name=$(echo "" | walker --dmenu -p "Project name:")
    [[ -z "$name" ]] && return 1
    
    name=$(echo "$name" | sed 's/[\/\\:*?"<>|]//g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$name" ]] && { echo "Invalid project name." >&2; return 1; }
    
    echo "$name"
}

get_project_locations() {
    local projects_data="$1"
    local home="${HOME}"
    local locations=()
    
    # Extract most used project locations
    if [[ -n "$projects_data" ]]; then
        local parent_dirs=$(echo "$projects_data" | cut -d'|' -f2 | \
            while IFS= read -r path; do
                [[ -n "$path" ]] && dirname "$path" 2>/dev/null
            done | grep -v '^$' | sort | uniq -c | sort -rn | head -n 10 | awk '{print $2}')
        
        while IFS= read -r dir; do
            [[ -n "$dir" ]] && [[ -d "$dir" ]] && locations+=("$dir")
        done <<< "$parent_dirs"
    fi
    
    # Add default location if not already present
    local default_loc="${home}/Projects"
    local found=0
    for loc in "${locations[@]}"; do
        [[ "$loc" == "$default_loc" ]] && found=1 && break
    done
    [[ $found -eq 0 ]] && locations+=("$default_loc")
    
    # Add custom path option
    [[ ${#locations[@]} -gt 0 ]] && locations+=("")
    locations+=("✏️  Enter custom path...")
    
    printf '%s\n' "${locations[@]}"
}

get_project_location() {
    local projects_data="$1"
    local home="${HOME}"
    
    local location_options=$(get_project_locations "$projects_data")
    local selected=$(echo "$location_options" | walker --dmenu -p "Select location:")
    [[ -z "$selected" ]] && return 1
    
    if [[ "$selected" == "✏️  Enter custom path..." ]]; then
        selected=$(echo "" | walker --dmenu -p "Enter full path:")
        [[ -z "$selected" ]] && return 1
        selected="${selected/#\~/$home}"
        has_command realpath && selected=$(realpath -m "$selected" 2>/dev/null || echo "$selected")
    else
        [[ -z "$selected" ]] && return 1
    fi
    
    echo "$selected"
}

select_editor() {
    local default_filter="$1"
    local editors=()
    local default_cmd=""
    
    while IFS='|' read -r name config_path cmd editor_type; do
        editors+=("${name}|${cmd}")
        
        if [[ -n "$default_filter" ]] && [[ "$default_filter" != "all" ]]; then
            local filter_lower="${default_filter,,}"
            local name_lower="${name,,}"
            local cmd_lower="${cmd,,}"
            if [[ "$name_lower" == *"$filter_lower"* ]] || [[ "$cmd_lower" == *"$filter_lower"* ]]; then
                default_cmd="$cmd"
            fi
        fi
    done < <(get_installed_editors)
    
    [[ ${#editors[@]} -eq 0 ]] && { echo "No editors found." >&2; return 1; }
    
    # Use default if available
    [[ -n "$default_cmd" ]] && { echo "$default_cmd"; return 0; }
    
    # Show selection menu
    local editor_options=$(printf '%s\n' "${editors[@]}" | cut -d'|' -f1)
    local selected=$(echo "$editor_options" | walker --dmenu -p "Select editor:")
    [[ -z "$selected" ]] && return 1
    
    printf '%s\n' "${editors[@]}" | awk -F'|' -v sel="$selected" '$1 == sel {print $2; exit}'
}

create_project_directory() {
    local project_path="$1"
    local parent_dir=$(dirname "$project_path")
    
    if [[ ! -d "$parent_dir" ]]; then
        local create_parent=$(echo -e "Yes\nNo" | walker --dmenu -p "Parent directory doesn't exist. Create it?")
        [[ "$create_parent" != "Yes" ]] && return 1
        mkdir -p "$parent_dir" || { echo "Failed to create parent directory." >&2; return 1; }
    fi
    
    if [[ -d "$project_path" ]]; then
        local use_existing=$(echo -e "Yes\nNo" | walker --dmenu -p "Directory already exists. Use it?")
        [[ "$use_existing" != "Yes" ]] && return 1
    else
        mkdir -p "$project_path" || { echo "Failed to create project directory." >&2; return 1; }
    fi
    
    echo "$project_path"
}

create_new_project() {
    local editor_filter="$1"
    local projects_data="$2"
    
    local project_name
    project_name=$(get_project_name) || exit 0
    
    local base_location
    base_location=$(get_project_location "$projects_data") || exit 0
    
    local project_path="${base_location}/${project_name}"
    project_path=$(create_project_directory "$project_path") || exit 0
    
    local editor_cmd
    editor_cmd=$(select_editor "$editor_filter") || exit 0
    
    "$editor_cmd" "$project_path"
}

browse_directory() {
    local current_dir="$1"
    [[ -z "$current_dir" ]] && current_dir="${HOME}"
    
    # Resolve and normalize the path
    if has_command realpath; then
        current_dir=$(realpath "$current_dir" 2>/dev/null || echo "$current_dir")
    fi
    
    [[ ! -d "$current_dir" ]] && { echo "Invalid directory: $current_dir" >&2; return 1; }
    
    local items=()
    local item
    local home="${HOME}"
    
    # Add "Select this folder" at the top
    items+=("✓ Select this folder")
    
    # Add directories (sorted alphabetically)
    local dirs=()
    shopt -s nullglob
    for item in "$current_dir"/*; do
        [[ -d "$item" ]] && dirs+=("📁 $(basename "$item")")
    done
    shopt -u nullglob
    
    # Sort directories and add them
    if [[ ${#dirs[@]} -gt 0 ]]; then
        IFS=$'\n' sorted_dirs=($(printf '%s\n' "${dirs[@]}" | sort))
        items+=("${sorted_dirs[@]}")
    fi

    # Add navigation options at the end
    [[ "$current_dir" != "$home" ]] && items+=("🏠 Go to home")

    # Check for projects directory (try Work/Projects first, then Projects)
    local projects_dir=""
    if [[ -d "${home}/Work/Projects" ]]; then
        projects_dir="${home}/Work/Projects"
    elif [[ -d "${home}/work/Projects" ]]; then
        projects_dir="${home}/work/Projects"
    elif [[ -d "${home}/Projects" ]]; then
        projects_dir="${home}/Projects"
    fi
    [[ -n "$projects_dir" ]] && [[ "$current_dir" != "$projects_dir" ]] && items+=("📂 Go to Projects")

    [[ -d "${home}/Documents" ]] && [[ "$current_dir" != "${home}/Documents" ]] && items+=("📄 Go to Documents")
    
    # Show menu with current path (shortened if in home)
    local display_path="${current_dir/#$HOME/~}"
    local selected=$(printf '%s\n' "${items[@]}" | walker --dmenu -p "Browse: $display_path")
    [[ -z "$selected" ]] && return 1
    
    # Handle special options
    case "$selected" in
        "✓ Select this folder")
            echo "$current_dir"
            return 0
            ;;
        "🏠 Go to home")
            browse_directory "$home"
            return $?
            ;;
        "📂 Go to Projects")
            # Determine the actual projects directory
            local projects_dir=""
            if [[ -d "${home}/Work/Projects" ]]; then
                projects_dir="${home}/Work/Projects"
            elif [[ -d "${home}/work/Projects" ]]; then
                projects_dir="${home}/work/Projects"
            elif [[ -d "${home}/Projects" ]]; then
                projects_dir="${home}/Projects"
            fi
            browse_directory "$projects_dir"
            return $?
            ;;
        "📄 Go to Documents")
            browse_directory "${home}/Documents"
            return $?
            ;;
    esac
    
    # Remove emoji prefix and get the name
    local item_name="${selected#📁 }"
    local new_path="${current_dir}/${item_name}"
    
    # Resolve path
    if has_command realpath; then
        new_path=$(realpath "$new_path" 2>/dev/null || echo "$new_path")
    fi
    
    # If it's a directory, browse into it
    if [[ -d "$new_path" ]]; then
        browse_directory "$new_path"
        return $?
    else
        # Shouldn't happen, but return current dir if it does
        echo "$current_dir"
        return 0
    fi
}

pick_folder() {
    local home="${HOME}"
    local projects_dir="${home}/Work/Projects"

    [[ ! -d "$projects_dir" ]] && projects_dir="${home}/work/Projects"
    [[ ! -d "$projects_dir" ]] && projects_dir="${home}/Projects"
    [[ ! -d "$projects_dir" ]] && { echo "Projects directory not found" >&2; return 1; }

    local folders=()
    shopt -s nullglob
    for dir in "$projects_dir"/*; do
        [[ -d "$dir" ]] && folders+=("$(basename "$dir")")
    done
    shopt -u nullglob

    [[ ${#folders[@]} -eq 0 ]] && { echo "No folders found" >&2; return 1; }

    local selected=$(printf '%s\n' "${folders[@]}" | sort | walker --dmenu -p "Select folder:")
    [[ -z "$selected" ]] && return 1

    echo "${projects_dir}/${selected}"
}

open_existing_project() {
    local folder_path
    folder_path=$(pick_folder) || exit 0

    xdg-open "$folder_path"
}

