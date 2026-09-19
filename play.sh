#!/usr/bin/env bash

set -euo pipefail

################################# play.sh #####################################

# Persistent state
#
# play.sh stores its persistent state in:
#
#     ${XDG_STATE_HOME:-$HOME/.local/state}/play.sh/
#
# The state directory contains small files describing the user's progress
# through the collection. It does not modify the directories containing the
# videos.
#
# state.json
#     The path of the video that should be played next. When a video reaches
#     the end normally, this is advanced to the next video in the collection.
#     If playback is interrupted, the current video remains unchanged so that
#     mpv can resume it from its saved playback position.
#
# screen
#     The user's preferred mpv display mode. This file will contain either
#     "yes" or "no". It is used when neither --full nor --window is specified,
#     allowing play.sh to restore the display mode used during the previous
#     invocation.
#
# mpv.lua
#     The Lua script used by mpv to communicate playback events back to
#     play.sh. This is an implementation file rather than playback state.
#
# mpv also maintains its own watch-later data separately. This stores the
# playback position of individual videos and is what allows an interrupted
# video to resume from where it was left off.
#
# Thus play.sh remembers which video is current, while mpv remembers the
# playback position within that video.

############################## help message ###################################

usage() {
    cat <<EOF
Play a video in a series and binge watch with mpv.
Usage: $0 DIRECTORY [OPTIONS]

Options:
    --continue          Play subsequent videos after normal completion
    --start-over        Start the series from its first video
    --title TITLE       Select a video by fuzzy title
    -s, --select        Select an episode to play from a list.
    -r, --random        Select random episode
    --restart           Start episode from the beginning
    --resume            Resume episode from where we left off
    --window            Start in windowed mode.
    --full              Start in fullscreen.
    --screen            choose which screen to play in by number.
    -h, --help          Show this help
EOF
}

version() {
    cat <<EOF
play.sh version 1.0.0
EOF
}

############################## read options ###################################

directory=
title=
continue=false
start_over=false
restart=false
resume=false
select=false
random=false
window=false
fullscreen=false
screen_ID=

while (($#)); do
    case "$1" in
        -h|--help)
            usage
            exit
            ;;
        -v|--version)
            version
            exit
            ;;
        --title|--name)
            if (($# < 2)); then
                echo "error: --title requires an argument" >&2
                exit 2
            fi
            title=$2
            echo "title set as $title"
            shift 2
            ;;
        --continue)
            continue=true
            shift
            ;;
        --start-over)
            start_over=true
            shift
            ;;
        --restart)
            restart=true
            shift
            ;;
        --resume)
            resume=true
            shift
            ;;
        -r|--random)
            random=true
            shift
            ;;
        -s|--select)
            select=true
            shift
            ;;
        --window)
            window=true
            shift
            ;;
        --full)
            fullscreen=true
            shift
            ;;
        --screen)
            if (($# < 2)); then
                echo "error: --title requires an argument" >&2
                exit 2
            fi
            screen_ID=$2
            shift 2
            ;;
        -*)
            echo "error: unknown option: $1" >&2
            exit 2
            ;;
        *)
            if [[ -n $directory ]]; then
                echo "error: only one directory may be specified" >&2
                exit 2
            fi

            # Canonicalize the directory so the state remains stable if the script is
            # called with different spellings of the same directory.
            directory=$(realpath "$1") || exit 1
            shift
            ;;
    esac
done

# check dependencies
if ! command -v mpv >/dev/null 2>&1; then
    echo "error: mpv is not installed" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is not installed" >&2
    exit 1
fi

if [[ -z $directory ]]; then
    echo "error: no directory specified" >&2
    usage >&2
    exit 2
fi

if [[ ! -d $directory ]]; then
    echo "error: not a directory: $directory" >&2
    exit 1
fi

if [[ -n $title && $start_over == true ]]; then
    echo "error: --title and --start-over are mutually exclusive" >&2
    exit 2
fi

if [[ $resume == true && $restart == true ]]; then
    echo "error: --restart and --resume are mutually exclusive" >&2
    exit 2
fi

if [[ $select == true && $random == true ]]; then
    echo "error: --select and --random are mutually exclusive" >&2
    exit 2
fi

if [[ $window == true && $fullscreen == true ]]; then
    echo "error: --window and --full are mutually exclusive" >&2
    exit 2
fi

# If we are selecting a specific video, the default is to restart
# otherwise we resume where we left off.
if [[ $resume == false && $restart == false ]]; then
    if [[ $start_over == true || -n $title || $select == true || $random == true ]]; then
        restart=true
    else
        resume=true
    fi
fi

# mpv has a property called screen-name which we can read on video completed
# that is supposed to tell us which screen the video is playing on. However,
# mpv doesn't really seem to know. We want to make it so that the next video
# continues playing on the same screen as the previous, but this is an
# incomplete feature at the moment.
screenname=

screenmode=window

if [[ $fullscreen == true ]]; then
    screenmode=full
fi

############################ check video files ################################

is_video() {
    case "${1,,}" in
        *.avi|*.divx|*.m2ts|*.m4v|*.mkv|*.mov|*.mp4|*.mpeg|*.mpg|*.ogm|*.ogv|*.ts|*.webm|*.wmv)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Find videos recursively and sort them naturally.
mapfile -d '' videos < <(
    find "$directory" -type f -print0 |
        while IFS= read -r -d '' file; do
            is_video "$file" && printf '%s\0' "$file"
        done |
        sort -z -V
)

if ((${#videos[@]} == 0)); then
    echo "error: no video files found in $directory" >&2
    exit 1
fi

################################# database ####################################

state_directory="${XDG_STATE_HOME:-$HOME/.local/state}/play.sh"
mkdir -p "$state_directory"

# all the files that we use in this script
state_file="$state_directory/series.json"
screen_file="$state_directory/screen.json"

# register the name of the file as an env variable.
export PLAY_SH_SCREEN="$screen_file"

load_screen() {
    if [[ ! -f $screen_file ]]; then
        return
    fi

    screenmode=$(jq -r '.mode // empty' "$screen_file")
    screenname=$(jq -r '.name // empty' "$screen_file")
}

load_current() {
    local directory=$1

    if [[ ! -f $state_file ]]; then
        return
    fi

    jq -r --arg directory "$directory" \
        '.[$directory] // empty' \
        "$state_file"
}

store_current() {
    local directory=$1
    local current=$2

    local relative=${current#"$directory"/}

    local temporary=$(mktemp "$state_file.XXXXXX") || exit 1

    if [[ -f $state_file ]]; then
        jq --arg directory "$directory" \
           --arg current "$relative" \
           '.[$directory] = $current' \
           "$state_file" > "$temporary"
    else
        jq -n \
           --arg directory "$directory" \
           --arg current "$relative" \
           '{($directory): $current}' \
           > "$temporary"
    fi

    mv "$temporary" "$state_file"
}

erase_current() {
    local directory=$1

    local temporary
    temporary=$(mktemp "$state_file.XXXXXX") || exit 1

    if [[ -f $state_file ]]; then
        jq --arg directory "$directory" \
           'del(.[$directory])' \
           "$state_file" > "$temporary"

        mv "$temporary" "$state_file"
    fi
}

################################ lua script ###################################

# mpv can accept scripts to run on exit. We have
# a short lua script to detect how the program
# exited and what the screen state was.
lua_script="$state_directory/mpv.lua"

if [[ ! -f $lua_script ]]; then
    cat > "$lua_script" <<'LUA'
local mp = require 'mp'

local result_file = os.getenv("PLAY_SH_RESULT")

mp.register_event("end-file", function(event)
    local reason = event.reason or "unknown"

    local f = io.open(result_file, "w")
    if f then
        f:write(reason)
        f:close()
    end
end)

local screen_file = os.getenv("PLAY_SH_SCREEN")

local function save_screen_state()
    if not screen_file then
        return
    end

    local fullscreen = mp.get_property_bool("fullscreen", false)
    local screenname = mp.get_property("screen-name", "")

    local screenmode
    if fullscreen then
        screenmode = "full"
    else
        screenmode = "window"
    end

    local f = io.open(screen_file, "w")
    if f then
        f:write("{\n")
        f:write('    "mode": "' .. screenmode .. '",\n')
        f:write('    "name": "' .. screenname .. '"\n')
        f:write('    "id": "' .. screenname .. '"\n')
        f:write("}\n")
        f:close()
    end
end

mp.register_event("shutdown", save_screen_state)
LUA
fi

######################## determine initial position ###########################

# check for current video
last_file="$directory/$(load_current "$directory")"

if [[ -n $title || $select == true || $random == true ]]; then
    # First case: user wants to select a specific video
    matches=()

    for file in "${videos[@]}"; do
        if [[ "${file,,}" == *"${title,,}"* ]]; then
            matches+=("$file")
        fi
    done

    if ((${#matches[@]} == 0)); then
        echo "error: no video matches '$title'" >&2
        exit 1
    fi

    if ((${#matches[@]} == 1)); then
        file="${matches[0]}"

    # Locate a title using fzf if available. We search against paths relative
    # to the requested directory, which makes the resulting selector nicer.
    elif $random == true; then
        file="${matches[RANDOM % ${#matches[@]}]}"

    elif command -v fzf >/dev/null 2>&1; then
        file=$(
            printf '%s\n' "${matches[@]}" |
                sed "s#^$directory/##" |
                fzf --query="$title" --reverse --select-1 --exit-0 |
                sed "s#^#$directory/#"
        )

    else
        echo "multiple videos match '$title':" >&2
        printf '  %s\n' "${matches[@]#"$directory"/}" >&2
        echo "error: install fzf to select between multiple matches" >&2
        exit 1
    fi

elif $start_over == true; then
    file=${videos[0]}

elif [[ -f "$last_file" ]]; then
    file=$last_file

else
    #otherwise, start from the beginning.
    file=${videos[0]}
    restart=true
fi

########################### start watching videos #############################

# we repeat this with every episode but
# we can't just put it in a loop because
# we have things we need to work differently
# on the first iteration from the rest.
prepare_next_file() {
    store_current "$directory" "$file"

    result_file=$(mktemp "$state_directory/result.XXXXXX")
    rm -f "$result_file"

    # set environment variables so that we
    # can find these files with the lua script.
    export PLAY_SH_RESULT="$result_file"
}

# for the first iteration, we always play the file.
prepare_next_file

while true; do
    echo "Playing: ${file#"$directory"/}"

    mpv_args=(
        --save-position-on-quit=yes
        --script="$lua_script"
    )

    if [[ $screenmode == window ]]; then
        mpv_args+=(--fullscreen=no)
    elif [[ $screenmode == full ]]; then
        mpv_args+=(--fullscreen=yes)
    fi

    if [[ -n $screen_ID ]]; then
        mpv_args+=(--screen="$screen_ID")
    fi

    if $restart == true ; then
        mpv --no-resume-playback \
            "${mpv_args[@]}" \
            "$file"
    else
        mpv \
            "${mpv_args[@]}" \
            "$file"
    fi

    reason=
    if [[ -f $result_file ]]; then
        reason=$(<"$result_file")
    fi
    rm -f "$result_file"

    case "$reason" in
        eof)

            # Find the next file in the sorted sequence.
            next_file=
            found=false

            for candidate in "${videos[@]}"; do
                if $found; then
                    next_file=$candidate
                    break
                fi

                [[ "$candidate" == "$file" ]] && found=true
            done

            if [[ -z $next_file ]]; then
                echo
                echo "All videos have been watched."
                erase_current "$directory"
                exit 0
            fi

            file=$next_file
            ;;

        quit)
            exit 0
            ;;

        *)
            # Treat unexpected termination as a user stop rather than
            # accidentally marching through the playlist.
            exit 0
            ;;
    esac
    
    prepare_next_file

    #if --continue is not set, then we stop
    if ! $continue; then
        exit 0
    fi
         
    #if we continue, we always start the next episode from the beginnig.
    restart=true

    # load the screen state on which the last instance of mpv exited.
    # this will set screenmode and screenname.
    load_screen

    echo "screen mode is now $screenmode and screenname is $screenname"
done
