#!/bin/bash -e
#
# Download files from file sharing servers
# Copyright (c) 2010-2012 Plowshare team
#
# Output filenames are printed on standard output (one per line).
#
# This file is part of Plowshare.
#
# Plowshare is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Plowshare is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Plowshare.  If not, see <http://www.gnu.org/licenses/>.


VERSION="GIT-snapshot"
OPTIONS="
HELP,h,help,,Show help info
GETVERSION,,version,,Return plowdown version
VERBOSE,v:,verbose:,LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
CHECK_LINK,c,check-link,,Check if a link exists and return
MARK_DOWN,m,mark-downloaded,,Mark downloaded links (useful for file list arguments)
NOOVERWRITE,x,no-overwrite,,Do not overwrite existing files
OUTPUT_DIR,o:,output-directory:,DIRECTORY,Directory where files will be saved
TEMP_DIR,,temp-directory:,DIRECTORY,Directory where files are temporarily downloaded
MAX_LIMIT_RATE,,max-rate:,SPEED,Limit maximum speed to bytes/sec (suffixes: k=Kb, m=Mb, g=Gb)
INTERFACE,i:,interface:,IFACE,Force IFACE network interface
TIMEOUT,t:,timeout:,SECS,Timeout after SECS seconds of waits
MAXRETRIES,r:,max-retries:,N,Set maximum retries for captcha solving. 0 means no retry. Default is infinite.
CAPTCHA_METHOD,,captchamethod:,METHOD, Force specific captcha solving method. Available: prompt, none.
CAPTCHA_TRADER,,captchatrader:,USER:PASSWORD,CaptchaTrader account
CAPTCHA_ANTIGATE,,antigate:,KEY,Antigate.com captcha key
NOEXTRAWAIT,,no-extra-wait,,Do not wait on uncommon events (unavailable file, unallowed parallel downloads, ...)
GLOBAL_COOKIES,,cookies:,FILE,Force using specified cookies file
GET_MODULE,,get-module,,Don't process initial link, echo module name only and return
PRINTF_FORMAT,,printf:,FORMAT,Don't process final link, print results in a given format (for each link)
EXEC_COMMAND,,exec:,COMMAND,Don't process final link, execute command (for each link)
NO_MODULE_FALLBACK,,fallback,,If no module is found for link, simply download it (HTTP GET)
NO_CURLRC,,no-curlrc,,Do not use curlrc config file
NO_PLOWSHARERC,,no-plowsharerc,,Do not use plowshare.conf config file
"


# - Results are similar to "readlink -f" (available on GNU but not BSD)
# - If '-P' flags (of cd) are removed directory symlinks won't be
#   translated (but results are correct too)
# - Assume that $1 is correct (don't check for infinite loop)
absolute_path() {
    local SAVED_PWD=$PWD
    TARGET="$1"

    while [ -L "$TARGET" ]; do
        DIR=$(dirname "$TARGET")
        TARGET=$(readlink "$TARGET")
        cd -P "$DIR"
        DIR=$PWD
    done

    if [ -f "$TARGET" ]; then
        DIR=$(dirname "$TARGET")
    else
        DIR=$TARGET
    fi

    cd -P "$DIR"
    TARGET=$PWD
    cd "$SAVED_PWD"
    echo "$TARGET"
}

# Guess if item is a generic URL (a simple link string) or a text file with links.
# $1: single URL or file (containing links)
process_item() {
    local ITEM=$1

    if match_remote_url "$ITEM"; then
        echo 'url'
        echo "$ITEM" | strip
    elif [ -f "$ITEM" ]; then
        case "${ITEM##*.}" in
          zip|rar|tar|gz|7z|bz2|mp3|avi)
              log_error "Skip: '$ITEM' seems to be a binary file, not a list of links"
              ;;
          *)
              # Discard empty lines and comments
              echo 'file'
              sed -ne "s,^[[:space:]]*\([^#].*\)$,\1,p" "$ITEM" | strip
              ;;
        esac
    else
        log_error "Skip: cannot stat '$ITEM': No such file or directory"
    fi
}

# Print usage
# Note: $MODULES is a multi-line list
usage() {
    echo 'Usage: plowdown [OPTIONS] [MODULE_OPTIONS] URL|FILE [URL|FILE ...]'
    echo
    echo '  Download files from file sharing servers.'
    echo '  Available modules:' $MODULES
    echo
    echo 'Global options:'
    echo
    print_options "$OPTIONS" '  '
    print_module_options "$MODULES" 'DOWNLOAD'
}

# Mark status of link (inside file or to stdout). See --mark-downloaded switch.
# $1: type (file or url)
# $2: MARK_DOWN option flag
mark_queue() {
    local FILELIST=$3
    local URL=$4
    local TEXT=$5
    local TAIL=$6

    if [ -n "$2" ]; then
        if [ 'file' = "$1" ]; then
            if test -w "$FILELIST"; then
                TAIL=${TAIL//,/\\,}
                URL=${URL//,/\\,}

                sed -i -e "s,^[[:space:]]*\($URL\)[[:space:]]*$,#$TEXT \1$TAIL," "$FILELIST" &&
                    log_notice "link marked in file: $FILELIST (#$TEXT)" ||
                    log_error "failed marking link in file: $FILELIST (#$TEXT)"
            else
                log_notice "error: can't mark link, no write permission ($FILELIST)"
            fi
        else
            echo "#${TEXT} $URL"
        fi
    fi
}

# Create an alternative filename
# Pattern is filename.1
#
# $1: filename (with or without path)
# stdout: non existing filename
create_alt_filename() {
    local FILENAME=$1
    local COUNT=1

    while [ "$COUNT" -le 99 ]; do
        if [ ! -f "${FILENAME}.$COUNT" ]; then
            FILENAME="${FILENAME}.$COUNT"
            break
        fi
        (( ++COUNT ))
    done
    echo "$FILENAME"
}

# Example: "MODULE_FILESONIC_DOWNLOAD_RESUME=no"
# $1: module name
module_config_resume() {
    local VAR="MODULE_$(uppercase "$1")_DOWNLOAD_RESUME"
    test "${!VAR}" = 'yes'
}

# Example: "MODULE_FILESONIC_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no"
# $1: module name
module_config_need_cookie() {
    local VAR="MODULE_$(uppercase "$1")_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE"
    test "${!VAR}" = 'yes'
}

# Fake download module function. See --fallback switch.
# $1: cookie file (unused here)
# $2: unknown url
# stdout: $2
module_null_download() {
    echo "$2"
}

# Note: $ITEM, $NOOVERWRITE, $CAPTCHA_METHOD, $GLOBAL_COOKIES, $PRINTF_FORMAT,
#       $EXEC_COMMAND should not be used directly.
download() {
    local MODULE=$1
    local URL_RAW=$2
    local TYPE=$3
    local MARK_DOWN=$4
    local TEMP_DIR=$5
    local OUTPUT_DIR=$6
    local CHECK_LINK=$7
    local TIMEOUT=$8
    local MAXRETRIES=$9
    local NOEXTRAWAIT=${10}
    shift 10

    local URL_ENCODED=$(echo "$URL_RAW" | uri_encode)

    FUNCTION=${MODULE}_download
    log_notice "Starting download ($MODULE): $URL_ENCODED"
    timeout_init $TIMEOUT

    while :; do
        local DRETVAL=0
        local DCOOKIE=$(create_tempfile)

        # Use provided cookie
        if [ -s "$GLOBAL_COOKIES" ]; then
            cat "$GLOBAL_COOKIES" > "$DCOOKIE"
        fi

        if test -z "$CHECK_LINK"; then
            local DRESULT=$(create_tempfile)
            local TRY=0

            while :; do
                $FUNCTION "$@" "$DCOOKIE" "$URL_ENCODED" >"$DRESULT" || DRETVAL=$?

                if [ $DRETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
                    read AWAIT <"$DRESULT"

                    # --no-extra-wait option specified
                    test -n "$NOEXTRAWAIT" && break

                    if [ -z "$AWAIT" ]; then
                        log_debug "arbitrary wait"
                    fi
                    wait ${AWAIT:-60} seconds || {
                        DRETVAL=$?;
                        break;
                    }

                elif [ $DRETVAL -ne $ERR_CAPTCHA ]; then
                    break
                # [ $DRETVAL -eq $ERR_CAPTCHA ]
                elif [ "$CAPTCHA_METHOD" = 'none' ]; then
                    log_debug "captcha method set to none, abort"
                    break
                fi

                (( ++TRY ))
                if [ -n "$MAXRETRIES" ]; then
                    if [[ $MAXRETRIES -eq 0 ]]; then
                        log_debug "no retry explicitly requested"
                        break
                    elif [ "$MAXRETRIES" -lt "$TRY" ]; then
                        DRETVAL=$ERR_MAX_TRIES_REACHED
                        break
                    fi
                    log_notice "Starting download ($MODULE): retry ${TRY}/$MAXRETRIES"
                else
                    log_notice "Starting download ($MODULE): retry $TRY"
                fi
                DRETVAL=0
            done

            { read FILE_URL; read FILENAME; } <"$DRESULT" || true
            rm -f "$DRESULT"
        else
            $FUNCTION "$@" "$DCOOKIE" "$URL_ENCODED" >/dev/null || DRETVAL=$?

            if [ $DRETVAL -eq 0 -o \
                    $DRETVAL -eq $ERR_LINK_TEMP_UNAVAILABLE -o \
                    $DRETVAL -eq $ERR_LINK_NEED_PERMISSIONS -o \
                    $DRETVAL -eq $ERR_LINK_PASSWORD_REQUIRED ]; then
                log_notice "Link active: $URL_ENCODED"
                echo "$URL_ENCODED"
                rm -f "$DCOOKIE"
                break
            fi
        fi

        case "$DRETVAL" in
            0)
                ;;
            $ERR_LOGIN_FAILED)
                log_notice "Login process failed. Bad username/password or unexpected content"
                rm -f "$DCOOKIE"
                return $DRETVAL
                ;;
            $ERR_LINK_TEMP_UNAVAILABLE)
                log_notice "Warning: file link is alive but not currently available, try later"
                rm -f "$DCOOKIE"
                return $DRETVAL
                ;;
            $ERR_LINK_PASSWORD_REQUIRED)
                log_notice "You must provide a valid password"
                mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL_RAW" 'PASSWORD'
                rm -f "$DCOOKIE"
                return $DRETVAL
                ;;
            $ERR_LINK_NEED_PERMISSIONS)
                log_notice "Insufficient permissions (premium link?)"
                rm -f "$DCOOKIE"
                return $DRETVAL
                ;;
            $ERR_LINK_DEAD)
                log_notice "Link is not alive: file not found"
                mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL_RAW" 'NOTFOUND'
                rm -f "$DCOOKIE"
                return $DRETVAL
                ;;
            $ERR_MAX_WAIT_REACHED)
                log_notice "Delay limit reached (${FUNCTION})"
                rm -f "$DCOOKIE"
                return $DRETVAL
                ;;
            $ERR_MAX_TRIES_REACHED)
                log_notice "Retry limit reached (${FUNCTION})"
                rm -f "$DCOOKIE"
                return $DRETVAL
                ;;
            $ERR_CAPTCHA)
                log_notice "Error: decoding captcha (${FUNCTION})"
                rm -f "$DCOOKIE"
                return $DRETVAL
                ;;
            $ERR_SYSTEM)
                log_notice "System failure (${FUNCTION})"
                rm -f "$DCOOKIE"
                return $DRETVAL
                ;;
            *)
                log_error "failed inside ${FUNCTION}() [$DRETVAL]"
                rm -f "$DCOOKIE"
                return $ERR_FATAL
                ;;
        esac

        # Sanity check
        if test -z "$FILE_URL"; then
            log_error "Output URL expected"
            rm -f "$DCOOKIE"
            return $ERR_FATAL
        fi

        # Sanity check 2
        if [ "$FILE_URL" = "$FILENAME" ]; then
            log_error "Output filename is wrong, check module download function"
            FILENAME=""
        fi

        if test -z "$FILENAME"; then
            if [ '/' = "${FILE_URL:(-1):1}" ]; then
                log_error "Output filename not specified, module download function must be wrong"
                FILENAME="dummy-$$"
            else
                FILENAME=$(basename_file "${FILE_URL%%\?*}" | tr -d '\r\n' | \
                    html_to_utf8 | uri_decode)
            fi
        fi

        # On most filesystems, maximum filename length is 255
        # http://en.wikipedia.org/wiki/Comparison_of_file_systems
        if [ "${#FILENAME}" -ge 255 ]; then
            FILENAME="${FILENAME:0:254}"
            log_debug "filename is too long, truncating it"
        fi

        log_notice "File URL: $FILE_URL"
        log_notice "Filename: $FILENAME"

        # Process "final download link"
        # First (usual) way: invoke curl
        if [ -z "$PRINTF_FORMAT" -a -z "$EXEC_COMMAND" ]; then
            local FILENAME_TMP FILENAME_OUT

            # Temporary download path
            if test "$TEMP_DIR"; then
                FILENAME_TMP="$TEMP_DIR/$FILENAME"
            elif test "$OUTPUT_DIR"; then
                FILENAME_TMP="$OUTPUT_DIR/$FILENAME"
            else
                FILENAME_TMP=$FILENAME
            fi

            # Final path
            if test "$OUTPUT_DIR"; then
                FILENAME_OUT="$OUTPUT_DIR/$FILENAME"
            else
                FILENAME_OUT=$FILENAME
            fi

            CURL_ARGS=()
            FILE_URL=$(echo "$FILE_URL" | uri_encode)

            [ -z "$NOOVERWRITE" ] && \
                module_config_resume "$MODULE" && CURL_ARGS=("${CURL_ARGS[@]}" "-C -")
            module_config_need_cookie "$MODULE" && CURL_ARGS=("${CURL_ARGS[@]}" "-b $DCOOKIE")

            if [ -f "$FILENAME_OUT" ]; then
                if [ -n "$NOOVERWRITE" ]; then
                    if [ "$FILENAME_OUT" = "$FILENAME_TMP" ]; then
                        FILENAME_OUT=$(create_alt_filename "$FILENAME_OUT")
                        FILENAME_TMP=$FILENAME_OUT
                    else
                        FILENAME_OUT=$(create_alt_filename "$FILENAME_OUT")
                    fi
                else
                    # Can we overwrite destination file?
                    if [ ! -w "$FILENAME_OUT" ]; then
                        module_config_resume "$MODULE" && \
                            log_error "error: no write permission, cannot resume" || \
                            log_error "error: no write permission, cannot overwrite"
                        return $ERR_SYSTEM
                    fi
                fi
            fi

            DRETVAL=0
            CODE=$(curl_with_log ${CURL_ARGS[@]} -w '%{http_code}' --fail --globoff \
                    -o "$FILENAME_TMP" "$FILE_URL") || DRETVAL=$?

            rm -f "$DCOOKIE"

            if [ "$DRETVAL" -eq $ERR_LINK_TEMP_UNAVAILABLE ]; then
                # Obtained HTTP return status are 200 and 206
                if module_config_resume "$MODULE"; then
                    log_notice "Partial content downloaded, recall download function"
                    continue
                fi
                DRETVAL=$ERR_NETWORK

            elif [ "$DRETVAL" -eq $ERR_NETWORK ]; then
                if [ "$CODE" = 503 ]; then
                    log_error "Unexpected HTTP code ${CODE}, retry after a safety wait"
                    wait 120 seconds || return
                    continue
                fi
            fi

            if [ "$DRETVAL" -ne 0 ]; then
                return $DRETVAL
            fi

            if [ "$CODE" = 416 ]; then
                # If module can resume transfer, we assume here that this error
                # means that file have already been downloaded earlier.
                # We should do a HTTP HEAD request to check file length but
                # a lot of hosters do not allow it.
                if module_config_resume "$MODULE"; then
                    log_error "Resume error (bad range), skip download"
                else
                    log_error "Resume error (bad range), restart download"
                    rm -f "$FILENAME_TMP"
                    continue
                fi
            elif [ "${CODE:0:2}" != 20 ]; then
                log_error "Unexpected HTTP code ${CODE}, restart download"
                continue
            fi

            if test "$FILENAME_TMP" != "$FILENAME_OUT"; then
                log_notice "Moving file to output directory: ${OUTPUT_DIR:-.}"
                mv -f "$FILENAME_TMP" "$FILENAME_OUT"
            fi

            # Echo downloaded file (local) path
            echo "$FILENAME_OUT"

        # Second (custom) way: pretty print and/or external command
        else
            log_debug "don't use regular curl command to download final link"
            local DATA=("$MODULE" "$FILENAME" "$OUTPUT_DIR" "$DCOOKIE" \
                        "$URL_ENCODED" "$FILE_URL")

            # Pretty print requested
            if test "$PRINTF_FORMAT"; then
                pretty_print DATA[@] "$PRINTF_FORMAT"
            fi

            # External download requested
            if test "$EXEC_COMMAND"; then
                local CMD=$(pretty_print DATA[@] "$EXEC_COMMAND")

                DRETVAL=0
                eval "$CMD" || DRETVAL=$?

                if [ $DRETVAL -ne 0 ]; then
                    log_error "Command exited with retcode: $DRETVAL"
                    rm -f "$DCOOKIE"
                    return $ERR_FATAL
                fi
            fi

            rm -f "$DCOOKIE"
        fi

        mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL_RAW" "" "|$FILENAME_OUT"
        break
    done
    return 0
}

# Plowdown printf format
# ---
# Interpreted sequences are:
# %c: final cookie file (with full path)
# %C: %c or empty string if module does not require it
# %d: download (final) url
# %f: destination (local) filename
# %F: destination (local) filename (with output directory)
# %m: module name
# %u: download (source) url
# and also:
# %n: newline
# %t: tabulation
# %%: raw %
# ---
#
# Check user given format
# $1: format string
pretty_check() {
    # This must be non greedy!
    local S TOKEN
    S=${1//%[cdfmuCFnt%]}
    TOKEN=$(parse_quiet . '\(%.\)' <<<"$S")
    if [ -n "$TOKEN" ]; then
        log_error "Bad format string: unknown sequence << $TOKEN >>"
        return $ERR_FATAL
    fi
}

# Note: don't use printf (coreutils).
# $1: array[@] (module, dfile, ddir, cfile, dls, dlf)
# $2: format string
pretty_print() {
    local -a A=("${!1}")
    local FMT=$2
    local COOKIE_FILE

    test "${FMT#*%m}" != "$FMT" && FMT=$(replace '%m' "${A[0]}" <<< "$FMT")
    test "${FMT#*%f}" != "$FMT" && FMT=$(replace '%f' "${A[1]}" <<< "$FMT")

    if test "${FMT#*%F}" != "$FMT"; then
        if test "${A[2]}"; then
            FMT=$(replace '%F' "${A[2]}/${A[1]}" <<< "$FMT")
        else
            FMT=$(replace '%F' "${A[1]}" <<< "$FMT")
        fi
    fi

    test "${FMT#*%u}" != "$FMT" && FMT=$(replace '%u' "${A[4]}" <<< "$FMT")
    test "${FMT#*%d}" != "$FMT" && FMT=$(replace '%d' "${A[5]}" <<< "$FMT")

    if test "${FMT#*%c}" != "$FMT"; then
        COOKIE_FILE="$(dirname "${A[3]}")/$(basename_file $0).cookies.$$.txt"
        cp "${A[3]}" "$COOKIE_FILE"
        FMT=$(replace '%c' "$COOKIE_FILE" <<< "$FMT")
    fi
    if test "${FMT#*%C}" != "$FMT"; then
        if module_config_need_cookie "${A[0]}"; then
            COOKIE_FILE="$(dirname "${A[3]}")/$(basename_file $0).cookies.$$.txt"
            cp "${A[3]}" "$COOKIE_FILE"
        else
            COOKIE_FILE=""
        fi
        FMT=$(replace '%C' "$COOKIE_FILE" <<< "$FMT")
    fi

    test "${FMT#*%n}" != "$FMT" && FMT=$(replace '%n' $'\n' <<< "$FMT")
    test "${FMT#*%t}" != "$FMT" && FMT=$(replace '%t' '	'   <<< "$FMT")
    test "${FMT#*%%}" != "$FMT" && FMT=$(replace '%%' '%'   <<< "$FMT")

    echo "$FMT"
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

source "$LIBDIR/core.sh"
MODULES=$(grep_list_modules 'download') || exit
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Get configuration file options. Command-line is not parsed yet.
match '--no-plowsharerc' "$*" || \
    process_configfile_options 'Plowdown' "$OPTIONS"

MODULE_OPTIONS=$(get_all_modules_options "$MODULES" DOWNLOAD)
eval "$(process_options 'plowdown' "$OPTIONS$MODULE_OPTIONS" "$@")"

# Verify verbose level
if [ -n "$QUIET" ]; then
    VERBOSE=0
elif [ -n "$VERBOSE" ]; then
    [ "$VERBOSE" -gt "4" ] && VERBOSE=4
else
    VERBOSE=2
fi

test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }
test $# -lt 1 && { usage; exit $ERR_FATAL; }

log_report_info
log_report "plowdown version $VERSION"

if [ -n "$TEMP_DIR" ]; then
    TEMP_DIR=$(echo "$TEMP_DIR" | sed -e "s/\/$//")
    log_notice "Temporary directory: $TEMP_DIR"
    mkdir -p "$TEMP_DIR"
    if [ ! -w "$TEMP_DIR" ]; then
        log_error "error: no write permission"
        exit $ERR_SYSTEM
    fi
fi

if [ -n "$OUTPUT_DIR" ]; then
    OUTPUT_DIR=$(echo "$OUTPUT_DIR" | sed -e "s/\/$//")
    log_notice "Output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    if [ ! -w "$OUTPUT_DIR" ]; then
        log_error "error: no write permission"
        exit $ERR_SYSTEM
    fi
fi

if [ -n "$GLOBAL_COOKIES" ]; then
    if [ ! -f "$GLOBAL_COOKIES" ]; then
        log_error "error: can't find cookies file"
        exit $ERR_SYSTEM
    fi
    log_notice "plowdown: using provided cookies file"
fi

if [ -n "$PRINTF_FORMAT" ]; then
    pretty_check "$PRINTF_FORMAT" || exit
fi
if [ -n "$EXEC_COMMAND" ]; then
    pretty_check "$EXEC_COMMAND" || exit
fi

# Print chosen options
[ -n "$NOOVERWRITE" ] && log_debug "plowdown: --no-overwrite selected"
[ -n "$NOEXTRAWAIT" ] && log_debug "plowdown: --no-extra-wait selected"

if [ -n "$CAPTCHA_METHOD" ]; then
    if ! captcha_method_translate "$CAPTCHA_METHOD"; then
        log_error "error: unknown captcha method: $CAPTCHA_METHOD"
        exit $ERR_FATAL
    fi
    log_notice "plowdown: force captcha method ($CAPTCHA_METHOD)"
else
    [ -n "$CAPTCHA_TRADER" ] && log_debug "plowdown: --captchatrader selected"
    [ -n "$CAPTCHA_ANTIGATE" ] && log_debug "plowdown: --antigate selected"
fi

set_exit_trap

RETVALS=()
for ITEM in "$@"; do
    OLD_IFS=$IFS
    IFS=$'\n'
    ELEMENTS=( $(process_item "$ITEM") )
    IFS=$OLD_IFS

    TYPE="${ELEMENTS[0]}"
    unset ELEMENTS[0]

    for URL in "${ELEMENTS[@]}"; do
        MODULE=$(get_module "$URL" "$MODULES")

        if [ -z "$MODULE" ]; then
            if match_remote_url "$URL"; then
                # Test for simple HTTP 30X redirection
                # (disable User-Agent because some proxy can fake it)
                log_debug "No module found, try simple redirection"

                URL_ENCODED=$(echo "$URL" | uri_encode)
                URL_TEMP=$(curl --user-agent '' -i "$URL_ENCODED" | grep_http_header_location) || true

                if [ -n "$URL_TEMP" ]; then
                    MODULE=$(get_module "$URL_TEMP" "$MODULES")
                    test "$MODULE" && URL="$URL_TEMP"
                elif test "$NO_MODULE_FALLBACK"; then
                    log_notice "No module found, do a simple HTTP GET as requested"
                    MODULE='module_null'
                fi
            fi
        fi

        if [ -z "$MODULE" ]; then
            log_error "Skip: no module for URL ($URL)"
            RETVALS=(${RETVALS[@]} $ERR_NOMODULE)
            mark_queue "$TYPE" "$MARK_DOWN" "$ITEM" "$URL" 'NOMODULE'
        elif test "$GET_MODULE"; then
            RETVALS=(${RETVALS[@]} 0)
            echo "$MODULE"
        else
            # Get configuration file module options
            test -z "$NO_PLOWSHARERC" && \
                process_configfile_module_options 'Plowdown' "$MODULE" 'DOWNLOAD'

            DRETVAL=0
            download "$MODULE" "$URL" "$TYPE" "$MARK_DOWN" "$TEMP_DIR" \
                "$OUTPUT_DIR" "$CHECK_LINK" "$TIMEOUT" "$MAXRETRIES"   \
                "$NOEXTRAWAIT" "${UNUSED_OPTIONS[@]}"  || DRETVAL=$?
            RETVALS=(${RETVALS[@]} $DRETVAL)
        fi
    done
done

if [ ${#RETVALS[@]} -eq 0 ]; then
    exit 0
elif [ ${#RETVALS[@]} -eq 1 ]; then
    exit ${RETVALS[0]}
else
    log_debug "retvals:${RETVALS[@]}"
    # Drop success values
    RETVALS=(${RETVALS[@]/#0*} -$ERR_FATAL_MULTIPLE)

    exit $((ERR_FATAL_MULTIPLE + ${RETVALS[0]}))
fi
