#!/usr/bin/env bash
#
# Common set of functions used by modules
# Copyright (c) 2010-2013 Plowshare team
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

# Make pipes fail on the first failed command (requires Bash 3+)
set -o pipefail

# Global error codes
# 0 means success or link alive
declare -r ERR_FATAL=1                    # Unexpected result (upstream site updated, etc)
declare -r ERR_NOMODULE=2                 # No module found for processing request
declare -r ERR_NETWORK=3                  # Generic network error (socket failure, curl, firewall, etc)
declare -r ERR_LOGIN_FAILED=4             # Correct login/password argument is required
declare -r ERR_MAX_WAIT_REACHED=5         # Wait timeout (see -t/--timeout command line option)
declare -r ERR_MAX_TRIES_REACHED=6        # Max tries reached (see -r/--max-retries command line option)
declare -r ERR_CAPTCHA=7                  # Captcha solving failure
declare -r ERR_SYSTEM=8                   # System failure (missing executable, local filesystem, wrong behavior, etc)
declare -r ERR_LINK_TEMP_UNAVAILABLE=10   # plowdown: Link alive but temporarily unavailable
                                          # plowup: Feature (upload service) seems temporarily unavailable from upstream
                                          # plowlist: Links are temporarily unavailable. Upload still pending?
declare -r ERR_LINK_PASSWORD_REQUIRED=11  # Link alive but requires a password
declare -r ERR_LINK_NEED_PERMISSIONS=12   # plowdown: Link alive but requires some authentication (private or premium link)
                                          # plowup, plowdel: Operation not allowed for anonymous users
declare -r ERR_LINK_DEAD=13               # plowdel: File not found or previously deleted
                                          # plowlist: Remote folder does not exist or is empty
declare -r ERR_SIZE_LIMIT_EXCEEDED=14     # plowdown: Can't download link because file is too big (need permissions)
                                          # plowup: Can't upload too big file (need permissions)
declare -r ERR_BAD_COMMAND_LINE=15        # Unknown command line parameter or incompatible options
declare -r ERR_FATAL_MULTIPLE=100         # 100 + (n) with n = first error code (when multiple arguments)

# Global variables used (defined in other .sh)
#   - VERBOSE          Verbose log level (0=none, 1, 2, 3, 4)
#   - LIBDIR           Absolute path to plowshare's libdir
#   - INTERFACE        Network interface (used by curl)
#   - MAX_LIMIT_RATE   Network maximum speed (used by curl)
#   - MIN_LIMIT_RATE   Network minimum speed (used by curl)
#   - NO_CURLRC        Do not read of use curlrc config
#   - CAPTCHA_METHOD   (plowdown) User-specified captcha method
#   - CAPTCHA_ANTIGATE (plowdown) Antigate.com captcha key
#   - CAPTCHA_9KWEU    (plowdown) 9kw.eu captcha key
#   - CAPTCHA_BHOOD    (plowdown) Captcha Brotherhood account
#   - CAPTCHA_DEATHBY  (plowdown) DeathByCaptcha account
#   - MODULE           Module name (don't include .sh)
#
# Global variables defined here:
#   - PS_TIMEOUT       (plowdown, plowup) Timeout (in seconds) for one item
#
# Logs are sent to stderr stream.
# Policies:
# - error: modules errors (when return 1), lastest plowdown curl call
# - notice: core messages (wait, timeout, retries), lastest plowdown curl call
# - debug: modules messages, curl (intermediate) calls
# - report: debug plus curl content (html pages, cookies)

# log_report for a file
# $1: filename
logcat_report() {
    if test -s "$1"; then
        test $VERBOSE -ge 4 && \
            stderr "$(sed -e 's/^/rep:/' "$1")"
    fi
    return 0
}

# This should not be called within modules
log_report() {
    test $VERBOSE -ge 4 && stderr "rep: $@"
    return 0
}

log_debug() {
    test $VERBOSE -ge 3 && stderr "dbg: $@"
    return 0
}

# This should not be called within modules
log_notice() {
    test $VERBOSE -ge 2 && stderr "$@"
    return 0
}

log_error() {
    test $VERBOSE -ge 1 && stderr "$@"
    return 0
}

## ----------------------------------------------------------------------------

##
## All helper functions below can be called by modules
## (see documentation...)
##

# Wrapper for curl: debug and infinite loop control
# $1..$n are curl arguments
# Important note: -D/--dump-header or -o/--output temporary files are deleted in case of error
curl() {
    local -a CURL_ARGS=("$@")
    local -a OPTIONS=(--insecure --compressed --speed-time 600 --connect-timeout 240)
    local -r CURL_PRG=$(type -P curl)
    local DRETVAL=0

    # Check if caller has specified a User-Agent, if so, don't put one
    if ! find_in_array CURL_ARGS[@] '-A' '--user-agent'; then
        OPTIONS+=(--user-agent \
            'Mozilla/5.0 (X11; Linux x86_64; rv:6.0) Gecko/20100101 Firefox/6.0')
    fi

    # If caller has allowed redirection but did not limit it, do it now
    if find_in_array CURL_ARGS[@] '-L' '--location'; then
        find_in_array CURL_ARGS[@] '--max-redirs' || OPTIONS+=(--max-redirs 5)
    fi

    test -n "$NO_CURLRC" && OPTIONS[${#OPTIONS[@]}]='-q'

    # No verbose unless debug level; don't show progress meter for report level too
    if [ "${FUNCNAME[1]}" = 'curl_with_log' ]; then
        test $VERBOSE -eq 0 && OPTIONS[${#OPTIONS[@]}]='--silent'
    else
        test $VERBOSE -ne 3 && OPTIONS[${#OPTIONS[@]}]='--silent'
    fi

    if test -n "$INTERFACE"; then
        OPTIONS+=(--interface $INTERFACE)
    fi
    if test -n "$MAX_LIMIT_RATE"; then
        OPTIONS+=(--limit-rate $MAX_LIMIT_RATE)
    fi
    if test -n "$MIN_LIMIT_RATE"; then
        OPTIONS+=(--speed-time 30 --speed-limit $MIN_LIMIT_RATE)
    fi

    if test $VERBOSE -lt 4; then
        "$CURL_PRG" "${OPTIONS[@]}" "${CURL_ARGS[@]}" || DRETVAL=$?
    else
        local TEMPCURL=$(create_tempfile)
        log_report "${OPTIONS[@]}" "${CURL_ARGS[@]}"
        "$CURL_PRG" --show-error --silent "${OPTIONS[@]}" "${CURL_ARGS[@]}" 2>&1 >"$TEMPCURL" || DRETVAL=$?
        FILESIZE=$(get_filesize "$TEMPCURL")
        log_report "Received $FILESIZE bytes. DRETVAL=$DRETVAL"
        log_report "=== CURL BEGIN ==="
        logcat_report "$TEMPCURL"
        log_report "=== CURL END ==="
        cat "$TEMPCURL"
        rm -f "$TEMPCURL"
    fi

    if [ "$DRETVAL" != 0 ]; then
        local INDEX FILE

        if INDEX=$(index_in_array CURL_ARGS[@] '-D' '--dump-header'); then
            FILE=${OPTIONS[$INDEX]}
            if [ -f "$FILE" ]; then
                log_debug "deleting temporary HTTP header file: $FILE"
                rm -f "$FILE"
            fi
        fi

        if INDEX=$(index_in_array CURL_ARGS[@] '-o' '--output'); then
            FILE=${OPTIONS[$INDEX]}
            # Test to reject "-o /dev/null" and final plowdown call
            if [ -f "$FILE" ] && ! find_in_array OPTIONS[@] '--globoff'; then
                log_debug "deleting temporary output file: $FILE"
                rm -f "$FILE"
            fi
        fi

        case $DRETVAL in
            # Failed to initialize.
            2|27)
                log_error "$FUNCNAME: out of memory?"
                return $ERR_SYSTEM
                ;;
            # Couldn't resolve host. The given remote host was not resolved.
            6)
                log_notice "$FUNCNAME: couldn't resolve host"
                return $ERR_NETWORK
                ;;
            # Failed to connect to host.
            7)
                log_notice "$FUNCNAME: couldn't connect to host"
                return $ERR_NETWORK
                ;;
            # Partial file
            18)
                return $ERR_LINK_TEMP_UNAVAILABLE
                ;;
            # HTTP retrieve error / Operation timeout
            22|28)
                log_error "$FUNCNAME: HTTP retrieve error"
                return $ERR_NETWORK
                ;;
            # Write error
            23)
                log_error "$FUNCNAME: write failed, disk full?"
                return $ERR_SYSTEM
                ;;
            # Too many redirects
            47)
                if ! find_in_array CURL_ARGS[@] '--max-redirs'; then
                    log_error "$FUNCNAME: too many redirects"
                    return $ERR_FATAL
                fi
                ;;
            *)
                log_error "$FUNCNAME: failed with exit code $DRETVAL"
                return $ERR_NETWORK
                ;;
        esac
    fi
    return 0
}

# Force debug verbose level (unless -v0/-q specified)
curl_with_log() {
    curl "$@"
}

# Substring replacement (replace all matches)
#
# stdin: input string
# $1: substring to find (this is not a regexp)
# $2: replacement string (this is not a regexp)
replace() {
    # Using $(< /dev/stdin) gives same results
    local S=$(cat)
    # We must escape '\' character
    local FROM=${1//\\/\\\\}
    echo "${S//$FROM/$2}"
}

# Delete leading and trailing whitespace.
# stdin: input string (can be multiline)
# stdout: result string
strip() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Return uppercase string
# $*: input string(s)
uppercase() {
    echo "${*^^}"
}

# Return lowercase string
# $*: input string(s)
lowercase() {
    echo "${*,,}"
}

# Grep first line of a text
# stdin: input string (multiline)
first_line() {
    # equivalent to `sed -ne 1p` or `sed -e q` or `sed -e 1q`
    head -n1
}

# Grep last line of a text
# stdin: input string (multiline)
last_line() {
    # equivalent to `sed -ne '$p'` or `sed -e '$!d'`
    tail -n1
}

# Grep nth line of a text
# stdin: input string (multiline)
# $1: line number (start at index 1)
nth_line() {
   # equivalent to `sed -e "${1}q;d"` or `sed -e "${1}!d"`
   sed -ne "${1}p"
}

# Delete fist line(s) of a buffer
# $1: (optional) How many head lines to delete (default is 1)
# stdin: input string (multiline)
delete_first_line() {
    local -r N=${1:-1}

    if (( N < 1 )); then
        return $ERR_FATAL
    fi

    # equivalent to `tail -n +2` (if $1=1)
    sed -ne "$((N+1)),\$p"
}

# Delete last line of a text
# stdin: input string (multiline)
delete_last_line() {
    sed -e '$d'
}

# Check if a string ($2) matches a regexp ($1)
# This is case sensitive.
#
# $? is zero on success
match() {
    grep -q -- "$1" <<< "$2"
}

# Check if a string ($2) matches a regexp ($1)
# This is not case sensitive.
#
# $? is zero on success
matchi() {
    grep -iq -- "$1" <<< "$2"
}

# Check if URL is suitable for remote upload
#
# $1: string (URL or anything)
match_remote_url() {
    [[ $1 =~ ^[[:space:]]*https?:// ]]
}

# Get lines that match filter+parse regular expressions and extract string from it.
#
# $1: regexp to filter (take lines matching $1 pattern; "." or "" disable filtering).
# $2: regexp to parse (must contain parentheses to capture text). Example: "url:'\(http.*\)'"
# $3: (optional) how many lines to skip (default is 0: filter and match regexp on same line).
#     Note: $3 may only be used if line filtering is active ($1 != ".")
#     Example ($3=1): get lines matching filter regexp, then apply parse regexp on the line after.
#     Example ($3=-1): get lines matching filter regexp, then apply parse regexp on the line before.
# stdin: text data
# stdout: result
parse_all() {
    local PARSE=$2
    local N=${3:-0}
    local -r D=$'\001' # Change sed separator to allow '/' characters in regexp
    local STRING FILTER

    if [ -n "$1" -a "$1" != '.' ]; then
        FILTER="\\${D}$1${D}" # /$1/
    else
        [ $N -eq 0 ] || return $ERR_FATAL
    fi

    [ '^' = "${PARSE:0:1}" ] || PARSE="^.*$PARSE"
    [ '$' = "${PARSE:(-1):1}" ] || PARSE="$PARSE.*$"
    PARSE="s${D}$PARSE${D}\1${D}p" # s/$PARSE/\1/p;

    if [ $N -eq 0 ]; then
        # STRING=$(sed -ne "/$1/ s/$2/\1/p")
        STRING=$(sed -ne "$FILTER $PARSE")

    elif [ $N -eq 1 ]; then
        # Note: Loop is required for consecutive matches
        # STRING=$(sed -ne ":a /$1/ {n;h; s/$2/\1/p; g;b a;}")
        STRING=$(sed -ne ":a $FILTER {n;h; $PARSE; g;b a;}")

    elif [ $N -eq -1 ]; then
        # STRING=$(sed -ne "/$1/ {x; s/$2/\1/p; b;}" -e 'h')
        STRING=$(sed -ne "$FILTER {x; $PARSE; b;}" -e 'h')

    else
        local -r FIRST_LINE='^\([^\n]*\).*$'
        local -r LAST_LINE='^.*\n\(.*\)$'
        local N_ABS=$(( N < 0 ? -N : N ))
        local I=$(( N_ABS - 2 )) # Note: N_ABS >= 2 due to "elif" above
        local LINES='.*'
        local INIT='N'
        local FILTER_LINE PARSE_LINE

        [ $N_ABS -gt 10 ] &&
            log_notice "$FUNCNAME: are you sure you want to skip $N lines?"

        while (( I-- )); do
            INIT="$INIT;N"
        done

        while (( N_ABS-- )); do
            LINES="$LINES\\n.*"
        done

        if [ $N -gt 0 ]; then
            FILTER_LINE=$FIRST_LINE
            PARSE_LINE=$LAST_LINE
        else
            FILTER_LINE=$LAST_LINE
            PARSE_LINE=$FIRST_LINE
        fi

        STRING=$(sed -ne "1 {$INIT;h;n}" \
            -e "H;g;s/^.*\\n\\($LINES\)$/\\1/;h" \
            -e "s/$FILTER_LINE/\1/" \
            -e "$FILTER {g;s/$PARSE_LINE/\1/;$PARSE }")

        # Explanation: [1], [2] let hold space always contain the current line
        #                       as well as the previous N lines
        # [3] let pattern space contain only the line we test filter regex
        #     on (i.e. first buffered line on skip > 0, last line on skip < 0)
        # [4] if filter regex matches, let pattern space contain the line to
        #     be parsed and apply parse command
    fi

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"/$1/ ${PARSE//$D//}\" (skip $N)"
        log_notice_stack
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Like parse_all, but hide possible error
parse_all_quiet() {
    parse_all "$@" 2>/dev/null
    return 0
}

# Like parse_all, but get only first match
parse() {
    parse_all "$@" | head -n1
}

# Like parse, but hide possible error
parse_quiet() {
    parse "$@" 2>/dev/null
    return 0
}

# Like parse_all, but get only last match
parse_last() {
    parse_all "$@" | tail -n1
}

# Simple and limited JSON parsing
#
# Notes:
# - Single line parsing oriented (user should strip newlines first): no tree model
# - Array and Object types: no support
# - String type: no support for escaped unicode characters (\uXXXX)
# - No non standard C/C++ comments handling (like in JSONP)
# - If several entries exist on same line: last occurrence is taken, but:
#   consider precedence (order of priority): number, boolean/empty, string.
# - If several entries exist on different lines: all are returned (it's a parse_all_json)
#
# $1: variable name (string)
# $2: (optional) preprocess option. Accepted values are:
#     - "join": make a single line of input stream.
#     - "split": split input buffer on comma character (,).
# stdin: JSON data
# stdout: result
parse_json() {
    local STRING PRE
    local -r END='\([,}[:space:]].*\)\?$'

    if [ "$2" = 'join' ]; then
        PRE="tr -d '\n\r'"
    elif [ "$2" = 'split' ]; then
        PRE=sed\ -e\ 's/,[[:space:]]*"/\n"/g'
    else
        PRE='cat'
    fi

    STRING=$($PRE | sed \
        -ne "s/^.*\"$1\"[[:space:]]*:[[:space:]]*\(-\?\(0\|[1-9][[:digit:]]*\)\(\.[[:digit:]]\+\)\?\([eE][-+]\?[[:digit:]]\+\)\?\)$END/\1/p" \
        -ne "s/^.*\"$1\"[[:space:]]*:[[:space:]]*\(true\|false\|null\)$END/\1/p" \
        -ne "s/\\\\\"/\\\\q/g;s/^.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"$END/\1/p")

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (json): \"$1\""
        log_notice_stack
        return $ERR_FATAL
    fi

    # Translate two-character sequence escape representations
    STRING=${STRING//\\\//\/}
    STRING=${STRING//\\\\/\\}
    STRING=${STRING//\\q/\"}
    STRING=${STRING//\\b/$'\b'}
    STRING=${STRING//\\f/$'\f'}
    STRING=${STRING//\\n/$'\n'}
    STRING=${STRING//\\r/$'\r'}
    STRING=${STRING//\\t/	}

    echo "$STRING"
}

# Like parse_json, but hide possible error
parse_json_quiet() {
    parse_json "$@" 2>/dev/null
    return 0
}

# Check if JSON variable is true
#
# $1: JSON variable name
# $2: JSON data
# $? is zero on success
match_json_true() {
    grep -q "\"$1\"[[:space:]]*:[[:space:]]*true" <<< "$2"
}

# Grep "Xxx" HTTP header. Can be:
# - Location
# - Content-Location
# - Content-Type
#
# Notes:
# - This is using parse_all, so result can be multiline
#   (rare usage is: curl -I -L ...).
# - Use [:cntrl:] intead of \r because Busybox sed <1.19
#   does not support it.
#
# stdin: result of curl request (with -i/--include, -D/--dump-header
#        or -I/--head flag)
# stdout: result
grep_http_header_location() {
    parse_all '^[Ll]ocation:' 'n:[[:space:]]\+\(.*\)[[:cntrl:]]$'
}
grep_http_header_location_quiet() {
    parse_all '^[Ll]ocation:' 'n:[[:space:]]\+\(.*\)[[:cntrl:]]$' 2>/dev/null
    return 0
}
grep_http_header_content_location() {
    parse_all '^[Cc]ontent-[Ll]ocation:' 'n:[[:space:]]\+\(.*\)[[:cntrl:]]$'
}
grep_http_header_content_type() {
    parse_all '^[Cc]ontent-[Tt]ype:' 'e:[[:space:]]\+\(.*\)[[:cntrl:]]$'
}

# Grep "Content-Disposition" HTTP header
# See RFC5987 and RFC2183.
#
# stdin: HTTP response headers (see below)
# stdout: attachement filename
grep_http_header_content_disposition() {
    parse_all '^[Cc]ontent-[Dd]isposition:' "filename\*\?=[\"']\?\([^\"'[:cntrl:]]*\)"
}

# Extract a named form from a HTML content.
# Notes:
# - if several forms (with same name) are available: return all of them
# - start marker <form> and end marker </form> must be on separate lines
# - HTML comments are just ignored
#
# $1: (X)HTML data
# $2: (optional) "name" attribute of <form> marker.
#     If not specified: take forms having any "name" attribute (empty or not)
# stdout: result
grep_form_by_name() {
    local -r A=${2:-'.*'}
    local STRING=$(sed -ne \
        "/<[Ff][Oo][Rr][Mm][[:space:]].*name[[:space:]]*=[[:space:]]*[\"']\?$A[\"']\?/,/<\/[Ff][Oo][Rr][Mm]>/p" <<< "$1")

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"name=$A\""
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Extract a id-specified form from a HTML content.
# Notes:
# - if several forms (with same name) are available: return all of them
# - start marker <form> and end marker </form> must be on separate lines
# - HTML comments are just ignored
#
# $1: (X)HTML data
# $2: (optional) "id" attribute of <form> marker.
#     If not specified: take forms having any "id" attribute (empty or not)
# stdout: result
grep_form_by_id() {
    local -r A=${2:-'.*'}
    local STRING=$(sed -ne \
        "/<[Ff][Oo][Rr][Mm][[:space:]].*id[[:space:]]*=[[:space:]]*[\"']\?$A[\"']\?/,/<\/[Ff][Oo][Rr][Mm]>/p" <<< "$1")

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"id=$A\""
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Extract a specific FORM block from a HTML content.
# $1: (X)HTML data
# $2: (optional) Nth <form> block
grep_form_by_order() {
    grep_block_by_order '[Ff][Oo][Rr][Mm]' "$@"
}

# Extract a specific SCRIPT block from a HTML content.
# $1: (X)HTML data
# $2: (optional) Nth <script> block
grep_script_by_order() {
    grep_block_by_order '[Ss][Cc][Rr][Ii][Pp][Tt]' "$@"
}

# Split into several lines html markers.
# Insert a new line after ending marker.
#
# stdin: (X)HTML data
# stdout: result
break_html_lines() {
    sed -e 's/<\/[^>]*>/&\n/g'
}

# Split into several lines html markers.
# Insert a new line after each (beginning or ending) marker.
#
# stdin: (X)HTML data
# stdout: result
break_html_lines_alt() {
    sed -e 's/<[^>]*>/&\n/g'
}

# Parse single named HTML marker content
# <tag>..</tag>
# <tag attr="x">..</tag>
# Notes:
# - beginning and ending tag are on the same line
# - this is non greedy, first occurrence is taken
# - marker is case sensitive, it should not
# - "parse_xxx tag" is a shortcut for "parse_xxx tag tag"
#
# $1: (optional) regexp to filter (take lines matching $1 pattern)
# $2: tag name. Example: "span"
# stdin: (X)HTML data
# stdout: result
parse_all_tag() {
    local -r T=${2:-"$1"}
    local -r D=$'\001'
    local STRING=$(sed -ne "\\${D}$1${D}s${D}</$T>.*${D}${D}p" | \
                   sed -e "s/^.*<$T\(>\|[[:space:]][^>]*>\)//")

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"/$1/ <$T>\""
        log_notice_stack
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Like parse_all_tag, but hide possible error
parse_all_tag_quiet() {
    parse_all_tag "$@" 2>/dev/null
    return 0
}

# Like parse_all_tag, but get only first match
parse_tag() {
    parse_all_tag "$@" | head -n1
}

# Like parse_tag, but hide possible error
parse_tag_quiet() {
    parse_tag "$@" 2>/dev/null
    return 0
}

# Parse HTML attribute content
# http://www.w3.org/TR/html-markup/syntax.html#syntax-attributes
# Notes:
# - empty attribute syntax is not supported (ex: <input disabled>)
# - this is greedy, last occurrence is taken
# - attribute is case sensitive, it should not
# - "parse_xxx attr" is a shortcut for "parse_xxx attr attr"
#
# $1: (optional) regexp to filter (take lines matching $1 pattern)
# $2: attribute name. Examples: "href" or "b\|i\|u"
# stdin: (X)HTML data
# stdout: result
parse_all_attr() {
    local -r A=${2:-"$1"}
    local -r D=$'\001'
    local STRING=$(sed \
        -ne "\\${D}$1${D}s${D}.*[[:space:]]\($A\)[[:space:]]*=[[:space:]]*[\"']\([^\"'>]*\).*${D}\2${D}p" \
        -ne "\\${D}$1${D}s${D}.*[[:space:]]\($A\)[[:space:]]*=[[:space:]]*\([^[:space:]\"'<=>/]\+\).*${D}\2${D}p")

    if [ -z "$STRING" ]; then
        log_error "$FUNCNAME failed (sed): \"/$1/ $A=\""
        log_notice_stack
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Like parse_all_attr, but hide possible error
parse_all_attr_quiet() {
    parse_all_attr "$@" 2>/dev/null
    return 0
}

# Return value of html attribute
parse_attr() {
    parse_all_attr "$@" | head -n1
}

# Like parse_attr, but hide possible error
parse_attr_quiet() {
    parse_attr "$@" 2>/dev/null
    return 0
}

# Retrieve "action" attribute (URL) from a <form> marker
#
# stdin: (X)HTML data (idealy, call grep_form_by_xxx before)
# stdout: result
parse_form_action() {
    parse_attr '<[Ff][Oo][Rr][Mm]' 'action'
}

# Retrieve "value" attribute from an <input> marker with "name" attribute
# Note: "value" attribute must be on same line as "name" attribute.
#
# $1: name attribute of <input> marker
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_name() {
    parse_attr "<[Ii][Nn][Pp][Uu][Tt][^>]*name=[\"']\?$1[\"']\?" 'value'
}

# Like parse_form_input_by_name, but hide possible error
parse_form_input_by_name_quiet() {
    parse_form_input_by_name "$@" 2>/dev/null
    return 0
}

# Retrieve "value" attribute from an <input> marker with "type" attribute
# Note: "value" attribute must be on same line as "type" attribute.
#
# $1: type attribute of <input> marker (for example: "submit")
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_type() {
    parse_attr "<[Ii][Nn][Pp][Uu][Tt][^>]*type=[\"']\?$1[\"']\?" 'value'
}

# Like parse_form_input_by_type, but hide possible error
parse_form_input_by_type_quiet() {
    parse_form_input_by_type "$@" 2>/dev/null
    return 0
}

# Retrieve "value" attribute from an <input> marker with "id" attribute
# Note: "value" attribute must be on same line as "id" attribute.
#
# $1: id attribute of <input> marker
# stdin: (X)HTML data
# stdout: result (can be null string if <input> has no value attribute)
parse_form_input_by_id() {
    parse_attr "<[Ii][Nn][Pp][Uu][Tt][^>]*id=[\"']\?$1[\"']\?" 'value'
}

# Like parse_form_input_by_id, but hide possible error
parse_form_input_by_id_quiet() {
    parse_form_input_by_id "$@" 2>/dev/null
    return 0
}

# Get specific entry (value) from cookie
#
# $1: entry name (example: "lang")
# stdin: cookie data (netscape/mozilla cookie file format)
# stdout: result (can be null string no suck entry exists)
parse_cookie() {
    parse_all "\t$1\t[^\t]*\$" "\t$1\t\(.*\)"
}
parse_cookie_quiet() {
    parse_all "\t$1\t[^\t]*\$" "\t$1\t\(.*\)" 2>/dev/null
    return 0
}

# Return base of URL
# Examples:
# - http://www.host.com => http://www.host.com
# - http://www.host.com/a/b/c/d => http://www.host.com
# - http://www.host.com?sid=123 => http://www.host.com
# Note: Don't use `expr` (GNU coreutils) for portability purposes.
#
# $1: URL
basename_url() {
    if [[ $1 =~ https?://[^/?#]* ]]; then
        echo "${BASH_REMATCH[0]}"
    else
        echo "$1"
    fi
}

# Return basename of file path
# Example: /usr/bin/foo.bar => foo.bar
#
# $1: filename
basename_file() {
    # `basename -- "$1"` may be screwed on some BusyBox versions
    echo "${1##*/}"
}

# HTML entities will be translated
#
# stdin: data
# stdout: data (converted)
html_to_utf8() {
    if check_exec 'recode'; then
        log_report "$FUNCNAME: use recode"
        recode html..utf8
    elif check_exec 'perl'; then
        log_report "$FUNCNAME: use perl"
        perl -n -mHTML::Entities \
            -e 'BEGIN { eval { binmode(STDOUT,q[:utf8]); }; } \
                print HTML::Entities::decode_entities($_);' 2>/dev/null || { \
            log_debug "$FUNCNAME failed (perl): HTML::Entities missing ?";
            cat;
        }
    else
        log_notice "recode binary not found, pass-through"
        cat
    fi
}

# Encode a text to include into an url.
# - Reserved Characters (18): !*'();:@&=+$,/?#[]
# - Check for percent (%) and space character
#
# - Unreserved Characters: ALPHA / DIGIT / "-" / "." / "_" / "~"
# - Unsafe characters (RFC2396) should not be percent-encoded anymore: <>{}|\^`
#
# stdin: data (example: relative URL)
# stdout: data (should be compliant with RFC3986)
uri_encode_strict() {
    sed -e 's/\%/%25/g' -e 's/ /%20/g' \
        -e 's/!/%21/g' -e 's/*/%2A/g' -e 's/'\''/%27/g' \
        -e 's/(/%28/g' -e 's/)/%29/g' -e 's/;/%3B/g'    \
        -e 's/:/%3A/g' -e 's/@/%40/g' -e 's/&/%26/g'    \
        -e 's/=/%3D/g' -e 's/+/%2B/g' -e 's/\$/%24/g'   \
        -e 's/,/%2C/g' -e 's|/|%2F|g' -e 's/?/%3F/g'    \
        -e 's/#/%23/g' -e 's/\[/%5B/g' -e 's/\]/%5D/g'
}

# Encode a complete url.
# - check for space character and squares brackets
# - do not check for "reserved characters" (use "uri_encode_strict" for that)
#
# Bad encoded URL request can lead to HTTP error 400.
# curl doesn't do any checks, whereas wget convert provided url.
#
# stdin: data (example: absolute URL)
# stdout: data (nearly compliant with RFC3986)
uri_encode() {
    sed -e 's/ /%20/g' -e 's/\[/%5B/g' -e 's/\]/%5D/g'
}

# Decode a complete url.
# - Reserved characters (9): ():&=+,/[]
# - Check for space character
#
# stdin: data (example: absolute URL)
# stdout: data (nearly compliant with RFC3986)
uri_decode() {
    sed -e 's/%20/ /g' -e 's/%26/\&/g' -e 's/%2C/,/g' -e 's/%28/(/g' \
        -e 's/%29/)/g' -e 's/%2B/+/g' -e 's/%3D/=/g' -e 's/%5B/\[/g' \
        -e 's/%5D/\]/g' -e 's/%3A/:/g' -e 's|%2F|/|g' -e 's|%40|@|g'
}

# Retrieves size of file
#
# $1: filename
# stdout: file length (in bytes)
get_filesize() {
    local FILE_SIZE=$(stat -c %s "$1" 2>/dev/null)
    if [ -z "$FILE_SIZE" ]; then
        FILE_SIZE=$(ls -l "$1" 2>/dev/null | cut -d' ' -f5)
        if [ -z "$FILE_SIZE" ]; then
            log_error "can't get file size"
            echo '-1'
            return $ERR_SYSTEM
        fi
    fi
    echo "$FILE_SIZE"
}

# Create a tempfile and return path
# Note for later: use mktemp (GNU coreutils)
#
# $1: Suffix
create_tempfile() {
    local -r SUFFIX=$1
    local FILE="${TMPDIR:-/tmp}/$(basename_file "$0").$$.$RANDOM$SUFFIX"
    :> "$FILE" || return $ERR_SYSTEM
    echo "$FILE"
}

# User password entry
#
# stdout: entered password (can be null string)
# $? is non zero if no password
prompt_for_password() {
    local PASSWORD

    log_notice "No password specified, enter it now"

    # Unset IFS to consider trailing and leading spaces
    IFS= read -s -r -p 'Enter password: ' PASSWORD

    # Add missing trailing newline (see read -p)
    stderr

    test -z "$PASSWORD" && return $ERR_LINK_PASSWORD_REQUIRED
    echo "$PASSWORD"
}

# Login and return cookie.
# A non empty cookie file does not means that login is successful.
#
# $1: String 'username:password' (password can contain semicolons)
# $2: Cookie filename (see create_tempfile() modules)
# $3: Postdata string (ex: 'user=$USER&password=$PASSWORD')
# $4: URL to post
# $5, $6, ...: Additional curl arguments (optional)
# stdout: html result (can be null string)
# $? is zero on success
post_login() {
    local -r AUTH=$1
    local -r COOKIE=$2
    local -r POSTDATA=$3
    local -r LOGIN_URL=$4
    shift 4
    local -a CURL_ARGS=("$@")
    local USER PASSWORD DATA RESULT

    if [ -z "$AUTH" ]; then
        log_error "$FUNCNAME: authentication string is empty"
        return $ERR_LOGIN_FAILED
    fi

    if [ -z "$COOKIE" ]; then
        log_error "$FUNCNAME: cookie file expected"
        return $ERR_LOGIN_FAILED
    fi

    # Seem faster than
    # IFS=":" read USER PASSWORD <<< "$AUTH"
    USER=$(echo "${AUTH%%:*}" | uri_encode_strict)
    PASSWORD=$(echo "${AUTH#*:}" | uri_encode_strict)

    if [ -z "$PASSWORD" -o "$AUTH" = "${AUTH#*:}" ]; then
        PASSWORD=$(prompt_for_password) || true
    fi

    log_notice "Starting login process: $USER/${PASSWORD//?/*}"

    DATA=$(eval echo "${POSTDATA//&/\\&}")
    RESULT=$(curl --cookie-jar "$COOKIE" --data "$DATA" "${CURL_ARGS[@]}" \
        "$LOGIN_URL") || return

    # "$RESULT" can be empty, this is not necessarily an error
    if [ ! -s "$COOKIE" ]; then
        log_debug "$FUNCNAME: no entry was set (empty cookie file)"
        return $ERR_LOGIN_FAILED
    fi

    log_report "=== COOKIE BEGIN ==="
    logcat_report "$COOKIE"
    log_report "=== COOKIE END ==="

    if ! find_in_array CURL_ARGS[@] '-o' '--output'; then
        echo "$RESULT"
    fi
}

# Detect if a JavaScript interpreter is installed
#
# $1: (optional) Print flag
# stdout: path of executable (if $1 is a non empty string)
detect_javascript() {
    if ! check_exec 'js'; then
        log_notice "Javascript interpreter not found"
        return $ERR_SYSTEM
    fi
    test -n "$1" && type -P 'js'
    return 0
}

# Execute javascript code
#
# stdin: js script
# stdout: script result
javascript() {
    local JS_PRG TEMPSCRIPT

    JS_PRG=$(detect_javascript 1) || return
    TEMPSCRIPT=$(create_tempfile '.js') || return

    cat > "$TEMPSCRIPT"

    log_report "interpreter:$JS_PRG"
    log_report "=== JAVASCRIPT BEGIN ==="
    logcat_report "$TEMPSCRIPT"
    log_report "=== JAVASCRIPT END ==="

    $JS_PRG "$TEMPSCRIPT"
    rm -f "$TEMPSCRIPT"
    return 0
}

# Wait some time
# Related to -t/--timeout command line option
#
# $1: Sleep duration
# $2: Unit (seconds | minutes)
wait() {
    local -r VALUE=$1
    local -r UNIT=$2
    local UNIT_STR TOTAL_SECS

    if test "$VALUE" = '0'; then
        log_debug "wait called with null duration"
        return 0
    fi

    if [ "$UNIT" = 'minutes' ]; then
        UNIT_STR=minutes
        TOTAL_SECS=$((VALUE * 60))
    else
        UNIT_STR=seconds
        TOTAL_SECS=$((VALUE))
    fi

    timeout_update $TOTAL_SECS || return

    local REMAINING=$TOTAL_SECS
    local MSG="Waiting $VALUE $UNIT_STR..."
    local CLEAR="     \b\b\b\b\b"
    if test -t 2; then
      while [ "$REMAINING" -gt 0 ]; do
          log_notice -ne "\r$MSG $(splitseconds $REMAINING) left$CLEAR"
          sleep 1
          (( --REMAINING ))
      done
      log_notice -e "\r$MSG done$CLEAR"
    else
      log_notice "$MSG"
      sleep $TOTAL_SECS
    fi
}

# $1: local image filename (with full path). No specific image format expected.
# $2: captcha type or hint
# $3: (optional) minimal captcha length
# $4: (optional) maximal captcha length (unused)
# stdout: On 2 lines: <word> \n <transaction_id>
#         nothing is echoed in case of error
#
# Important note: input image ($1) is deleted in case of error
captcha_process() {
    local -r CAPTCHA_TYPE=$2
    local METHOD_SOLVE METHOD_VIEW FILENAME RESPONSE WORD I
    local TID=0

    if [ -f "$1" ]; then
        FILENAME=$1
    elif match_remote_url "$1"; then
        FILENAME=$(create_tempfile '.captcha') || return
        curl -o "$FILENAME" "$1" || return
    else
        log_error "$FUNCNAME: image file not found"
        return $ERR_FATAL
    fi

    if [ ! -s "$FILENAME" ]; then
        log_error "$FUNCNAME: empty image file"
        return $ERR_FATAL
    fi

    # plowdown --captchaprogram
    if [ -n "$CAPTCHA_PROGRAM" ]; then
        local RET=0

        WORD=$(exec "$CAPTCHA_PROGRAM" "$MODULE" "$FILENAME" "${CAPTCHA_TYPE}-$3") || RET=$?
        if [ $RET -eq 0 ]; then
            echo "$WORD"
            echo $TID
            return 0
        elif [ $RET -ne $ERR_NOMODULE ]; then
            log_error "captchaprogram exit with status $RET"
            return $RET
        fi
    fi

    # plowdown --captchamethod
    if [ -n "$CAPTCHA_METHOD" ]; then
        captcha_method_translate "$CAPTCHA_METHOD" METHOD_SOLVE METHOD_VIEW
    fi

    # Auto (guess) mode
    if [ -z "$METHOD_SOLVE" ]; then
        if [ -n "$CAPTCHA_ANTIGATE" ]; then
            METHOD_SOLVE=antigate
            METHOD_VIEW=none
        elif [ -n "$CAPTCHA_9KWEU" ]; then
            METHOD_SOLVE=9kweu
            METHOD_VIEW=none
        elif [ -n "$CAPTCHA_BHOOD" ]; then
            METHOD_SOLVE=captchabrotherhood
            METHOD_VIEW=none
        elif [ -n "$CAPTCHA_DEATHBY" ]; then
            METHOD_SOLVE=deathbycaptcha
            METHOD_VIEW=none
        else
            METHOD_SOLVE=prompt
        fi
    fi

    if [ -z "$METHOD_VIEW" ]; then
        # X11 server installed ?
        if [ "$METHOD_SOLVE" != 'prompt-nox' -a -n "$DISPLAY" ]; then
            if check_exec 'display'; then
                METHOD_VIEW=X-display
            elif check_exec 'feh'; then
                METHOD_VIEW=X-feh
            elif check_exec 'sxiv'; then
                METHOD_VIEW=X-sxiv
            elif check_exec 'qiv'; then
                METHOD_VIEW=X-qiv
            else
                log_notice "No X11 image viewer found, to display captcha image"
            fi
        fi
        if [ -z "$METHOD_VIEW" ]; then
            # libcaca
            if check_exec img2txt; then
                METHOD_VIEW=img2txt
            # terminal image view (perl script using Image::Magick)
            elif check_exec tiv; then
                METHOD_VIEW=tiv
            # libaa
            elif check_exec aview && check_exec convert; then
                METHOD_VIEW=aview
            else
                log_notice "No ascii viewer found to display captcha image"
                METHOD_VIEW=none
            fi
        fi
    fi

    # Try to maximize the image size on terminal
    local MAX_OUTPUT_WIDTH MAX_OUTPUT_HEIGHT
    if [ "$METHOD_VIEW" != 'none' -a "${METHOD_VIEW:0:1}" != 'X' ]; then
        if check_exec tput; then
            MAX_OUTPUT_WIDTH=$(tput cols)
            MAX_OUTPUT_HEIGHT=$(tput lines)
        else
            # Try environment variables
            MAX_OUTPUT_WIDTH=${COLUMNS:-150}
            MAX_OUTPUT_HEIGHT=${LINES:-57}
        fi

        if check_exec identify; then
            local DIMENSION=$(identify -quiet "$FILENAME" | cut -d' ' -f3)
            local W=${DIMENSION%x*}
            local H=${DIMENSION#*x}
            [ "$W" -lt "$MAX_OUTPUT_WIDTH" ] && MAX_OUTPUT_WIDTH=$W
            [ "$H" -lt "$MAX_OUTPUT_HEIGHT" ] && MAX_OUTPUT_HEIGHT=$H
        fi
    fi

    local IMG_HASH PRG_PID IMG_PNM

    # How to display image
    case $METHOD_VIEW in
        none)
            log_notice "Local image: $FILENAME"
            ;;
        aview)
            local -r FF=$'\f'
            # aview can only display files in PNM file format
            IMG_PNM=$(create_tempfile '.pnm') || return
            convert "$FILENAME" -negate -depth 8 pnm:$IMG_PNM && \
                aview -width $MAX_OUTPUT_WIDTH -height $MAX_OUTPUT_HEIGHT \
                    -kbddriver stdin -driver stdout "$IMG_PNM" 2>/dev/null <<<'q' | \
                        sed -e "1d;/$FF/,/$FF/d;/^[[:space:]]*$/d" 1>&2
            rm -f "$IMG_PNM"
            ;;
        tiv)
            tiv -a -w $MAX_OUTPUT_WIDTH -h $MAX_OUTPUT_HEIGHT "$FILENAME" 1>&2
            ;;
        img2txt)
            img2txt -W $MAX_OUTPUT_WIDTH -H $MAX_OUTPUT_HEIGHT "$FILENAME" 1>&2
            ;;
        X-display)
            display "$FILENAME" &
            PRG_PID=$!
            ;;
        X-feh)
            feh "$FILENAME" &
            PRG_PID=$!
            ;;
        X-qiv)
            qiv "$FILENAME" &
            PRG_PID=$!
            ;;
        X-sxiv)
            # open a 640x480 window
            sxiv -q -s "$FILENAME" &
            [ $? -eq 0 ] && PRG_PID=$!
            ;;
        imgur)
            IMG_HASH=$(image_upload_imgur "$FILENAME") || true
            ;;
        *)
            log_error "unknown view method: $METHOD_VIEW"
            rm -f "$FILENAME"
            return $ERR_FATAL
            ;;
    esac

    local TEXT1='Leave this field blank and hit enter to get another captcha image'
    local TEXT2='Enter captcha response (drop punctuation marks, case insensitive): '

    # How to solve captcha
    case $METHOD_SOLVE in
        none)
            rm -f "$FILENAME"
            return $ERR_CAPTCHA
            ;;
        9kweu)
            if ! service_9kweu_ready "$CAPTCHA_9KWEU"; then
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            log_notice 'Using 9kw.eu captcha recognition system'

            # Note for later: extra params can be supplied: min_len & max_len & phrase & numeric
            RESPONSE=$(curl -F 'method=post' \
                -F 'action=usercaptchaupload' \
                -F "apikey=$CAPTCHA_9KWEU" \
                -F "file-upload-01=@$FILENAME;filename=file.jpg" \
                'http://www.9kw.eu/index.cgi') || return

            if [ -z "$RESPONSE" ]; then
                log_error "9kw.eu empty answer"
                rm -f "$FILENAME"
                return $ERR_NETWORK
            # Error range: 0001..0015. German language.
            elif [[ $RESPONSE = 00[01][[:digit:]][[:space:]]* ]]; then
                log_error "9kw.eu error: ${RESPONSE:5}"
                rm -f "$FILENAME"
                return $ERR_FATAL
            fi

            TID=$RESPONSE

            for I in 8 5 5 6 6 7 7 8 9 9; do
                wait $I seconds
                RESPONSE=$(curl --get --data 'action=usercaptchacorrectdata' \
                    --data "apikey=$CAPTCHA_9KWEU" --data "id=$TID" \
                    --data 'info=1' 'http://www.9kw.eu/index.cgi') || return

                if [ 'NO DATA' = "$RESPONSE" ]; then
                    continue
                elif [ -z "$RESPONSE" ]; then
                    continue
                elif [ -n "$RESPONSE" ]; then
                    WORD=$RESPONSE
                    break
                else
                    log_error "9kw.eu error: $RESPONSE"
                    rm -f "$FILENAME"
                    return $ERR_FATAL
                fi
            done

            if [ -z "$WORD" ]; then
                log_error "9kw.eu error: service not unavailable"
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            # Result on two lines
            echo "$WORD"
            echo "9$TID"
            ;;
        antigate)
            if ! service_antigate_ready "$CAPTCHA_ANTIGATE"; then
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            log_notice "Using antigate captcha recognition system"

            # Note for later: extra params can be supplied: min_len & max_len
            RESPONSE=$(curl -F 'method=post' \
                -F "file=@$FILENAME;filename=file.jpg" \
                -F "key=$CAPTCHA_ANTIGATE" \
                -F 'is_russian=0' \
                'http://antigate.com/in.php') || return

            if [ -z "$RESPONSE" ]; then
                log_error "antigate empty answer"
                rm -f "$FILENAME"
                return $ERR_NETWORK
            elif [ 'ERROR_IP_NOT_ALLOWED' = "$RESPONSE" ]; then
                log_error "antigate error: IP not allowed"
                rm -f "$FILENAME"
                return $ERR_FATAL
            elif [ 'ERROR_ZERO_BALANCE' = "$RESPONSE" ]; then
                log_error "antigate error: no credits"
                rm -f "$FILENAME"
                return $ERR_FATAL
            elif [ 'ERROR_NO_SLOT_AVAILABLE' = "$RESPONSE" ]; then
                log_error "antigate error: no slot available"
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            elif match 'ERROR_' "$RESPONSE"; then
                log_error "antigate error: $RESPONSE"
                rm -f "$FILENAME"
                return $ERR_FATAL
            fi

            TID=$(echo "$RESPONSE" | parse_quiet . 'OK|\(.*\)')

            for I in 8 5 5 6 6 7 7 8; do
                wait $I seconds
                RESPONSE=$(curl --get \
                    --data "key=${CAPTCHA_ANTIGATE}&action=get&id=$TID" \
                    'http://antigate.com/res.php') || return

                if [ 'CAPCHA_NOT_READY' = "$RESPONSE" ]; then
                    continue
                elif match '^OK|' "$RESPONSE"; then
                    WORD=$(echo "$RESPONSE" | parse_quiet . 'OK|\(.*\)')
                    break
                else
                    log_error "antigate error: $RESPONSE"
                    rm -f "$FILENAME"
                    return $ERR_FATAL
                fi
            done

            if [ -z "$WORD" ]; then
                log_error "antigate error: service not unavailable"
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            # result on two lines
            echo "$WORD"
            echo "a$TID"
            ;;
        captchabrotherhood)
            local USERNAME=${CAPTCHA_BHOOD%%:*}
            local PASSWORD=${CAPTCHA_BHOOD#*:}

            if ! service_captchabrotherhood_ready "$USERNAME" "$PASSWORD"; then
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            log_notice "Using captcha brotherhood bypass service ($USERNAME)"

            # Content-Type is mandatory.
            # timeout parameter has no effect
            RESPONSE=$(curl --data-binary "@$FILENAME" \
                --header 'Content-Type: text/html'     \
                "http://www.captchabrotherhood.com/sendNewCaptcha.aspx?username=$USERNAME&password=$PASSWORD&captchaSource=plowshare&timeout=30&captchaSite=-1") || return

            if [ "${RESPONSE:0:3}" = 'OK-' ]; then
                TID=${RESPONSE:3}
                if [ -n "$TID" ]; then
                    for I in 6 5 5 6 6 7 7 8; do
                        wait $I seconds
                        RESPONSE=$(curl --get -d "username=$USERNAME"   \
                            -d "password=$PASSWORD" -d "captchaID=$TID" \
                            'http://www.captchabrotherhood.com/askCaptchaResult.aspx') || return

                        if [ "${RESPONSE:0:12}" = 'OK-answered-' ]; then
                            WORD=${RESPONSE:12}
                            if [ -n "$WORD" ]; then
                                # Result on two lines
                                echo "$WORD"
                                echo "b$TID"
                                return 0
                            else
                                RESPONSE='empty word?'
                            fi
                            break
                        elif [ "${RESPONSE:0:3}" != 'OK-' ]; then
                            break
                        fi

                        # OK-on user-
                    done
                else
                    RESPONSE='empty tid?'
                fi
            fi

            log_error "Captcha Brotherhood error: ${RESPONSE#Error-}"
            rm -f "$FILENAME"
            return $ERR_FATAL
            ;;
        deathbycaptcha)
            local HTTP_CODE POLL_URL
            local USERNAME=${CAPTCHA_DEATHBY%%:*}
            local PASSWORD=${CAPTCHA_DEATHBY#*:}

            if ! service_captchadeathby_ready "$USERNAME" "$PASSWORD"; then
                rm -f "$FILENAME"
                return $ERR_CAPTCHA
            fi

            log_notice "Using DeathByCaptcha service ($USERNAME)"

            # Consider HTTP headers, don't use JSON answer
            RESPONSE=$(curl --include --header 'Expect: ' \
                --header 'Accept: application/json' \
                -F "username=$USERNAME" \
                -F "password=$PASSWORD" \
                -F "captchafile=@$FILENAME" \
                'http://api.dbcapi.me/api/captcha') || return

            if [ -z "$RESPONSE" ]; then
                log_error "DeathByCaptcha empty answer"
                rm -f "$FILENAME"
                return $ERR_NETWORK
            fi

            HTTP_CODE=$(echo "$RESPONSE" | first_line | \
                parse . 'HTTP/1\.. \([[:digit:]]\+\) ')

            if [ "$HTTP_CODE" = 303 ]; then
                POLL_URL=$(echo "$RESPONSE" | grep_http_header_location) || return

                for I in 4 3 3 4 4 5 5; do
                    wait $I seconds

                    # {"status": 0, "captcha": 661085218, "is_correct": true, "text": ""}
                    RESPONSE=$(curl --header 'Accept: application/json' \
                        "$POLL_URL") || return

                    if match_json_true 'is_correct' "$RESPONSE"; then
                        WORD=$(echo "$RESPONSE" | parse_json_quiet text)
                        if [ -n "$WORD" ]; then
                            TID=$(echo "$RESPONSE" | parse_json_quiet captcha)
                            echo "$WORD"
                            echo "d$TID"
                            return 0
                        fi
                    else
                        log_error "DeathByCaptcha unknown error: $RESPONSE"
                        rm -f "$FILENAME"
                        return $ERR_CAPTCHA
                    fi
                done
                log_error "DeathByCaptcha timeout: give up!"
            else
                log_error "DeathByCaptcha wrong http answer ($HTTP_CODE)"
            fi
            rm -f "$FILENAME"
            return $ERR_CAPTCHA
            ;;
        prompt*)
            # Reload mecanism is not available for all types
            if [ "$CAPTCHA_TYPE" = 'recaptcha' -o \
                 "$CAPTCHA_TYPE" = 'solvemedia' ]; then
                log_notice "$TEXT1"
            fi

            read -r -p "$TEXT2" RESPONSE
            echo "$RESPONSE"
            echo $TID
            ;;
        *)
            log_error "unknown solve method: $METHOD_SOLVE"
            rm -f "$FILENAME"
            return $ERR_FATAL
            ;;
    esac

    # Second pass for cleaning up
    case $METHOD_VIEW in
        X-*)
            [[ $PRG_PID ]] && kill -HUP $PRG_PID 2>&1 >/dev/null
            ;;
        imgur)
            image_delete_imgur "$IMG_HASH" || true
            ;;
    esac

    # if captcha URL provided, drop temporary image file
    if [ "$1" != "$FILENAME" ]; then
        rm -f "$FILENAME"
    fi
}

# reCAPTCHA decoding function
# Main engine: http://api.recaptcha.net/js/recaptcha.js
#
# $1: reCAPTCHA site public key
# stdout: On 3 lines: <word> \n <challenge> \n <transaction_id>
recaptcha_process() {
    local -r RECAPTCHA_SERVER='http://www.google.com/recaptcha/api/'
    local URL="${RECAPTCHA_SERVER}challenge?k=${1}&ajax=1"
    local VARS SERVER TRY CHALLENGE FILENAME WORDS TID

    VARS=$(curl -L "$URL") || return

    if [ -z "$VARS" ]; then
        return $ERR_CAPTCHA
    fi

    # Load image
    SERVER=$(echo "$VARS" | parse_quiet 'server' "server[[:space:]]\?:[[:space:]]\?'\([^']*\)'") || return
    CHALLENGE=$(echo "$VARS" | parse_quiet 'challenge' "challenge[[:space:]]\?:[[:space:]]\?'\([^']*\)'") || return

    log_debug "reCaptcha server: $SERVER"

    # Image dimension: 300x57
    FILENAME=$(create_tempfile '.recaptcha.jpg') || return

    TRY=0
    # Arbitrary 100 limit is safer
    while (( TRY++ < 100 )) || return $ERR_MAX_TRIES_REACHED; do
        log_debug "reCaptcha loop $TRY"
        log_debug "reCaptcha challenge: $CHALLENGE"

        URL="${SERVER}image?c=${CHALLENGE}"

        log_debug "reCaptcha image URL: $URL"
        curl "$URL" -o "$FILENAME" || return

        WORDS=$(captcha_process "$FILENAME" recaptcha) || return
        rm -f "$FILENAME"

        { read WORDS; read TID; } <<< "$WORDS"

        [ -n "$WORDS" ] && break

        # Reload image
        log_debug "empty, request another image"

        # Result: Recaptcha.finish_reload('...', 'image');
        VARS=$(curl "${SERVER}reload?k=${1}&c=${CHALLENGE}&reason=r&type=image&lang=en") || return
        CHALLENGE=$(echo "$VARS" | parse 'finish_reload' "('\([^']*\)") || return
    done

    WORDS=$(echo "$WORDS" | uri_encode)

    echo "$WORDS"
    echo "$CHALLENGE"
    echo $TID
}

# Process captcha from "Solve Media" (http://www.solvemedia.com/)
# $1: Solvemedia site public key
# stdout: On 2 lines: <verified_challenge> \n <transaction_id>
# stdout: verified challenge
#         transaction_id
solvemedia_captcha_process() {
    local -r PUB_KEY=$1
    local -r BASE_URL='http://api.solvemedia.com/papi'
    local URL="$BASE_URL/challenge.noscript?k=$PUB_KEY"
    local HTML MAGIC CHALL IMG_FILE XY WI WORDS TID TRY

    IMG_FILE=$(create_tempfile '.solvemedia.jpg') || return

    TRY=0
    # Arbitrary 100 limit is safer
    while (( TRY++ < 100 )) || return $ERR_MAX_TRIES_REACHED; do
        log_debug "SolveMedia loop $TRY"
        XY=''

        # Get + scrape captcha iframe
        HTML=$(curl "$URL") || return
        MAGIC=$(echo "$HTML" | parse_form_input_by_name 'magic') || return
        CHALL=$(echo "$HTML" | parse_form_input_by_name \
            'adcopy_challenge') || return

        # Get actual captcha image
        curl -o "$IMG_FILE" "$BASE_URL/media?c=$CHALL" || return

        # Solve captcha
        # Note: Image is a 300x150 gif file containing text strings
        WI=$(captcha_process "$IMG_FILE" solvemedia) || return
        { read WORDS; read TID; } <<< "$WI"
        rm -f "$IMG_FILE"

        # Reload image?
        if [ -z "$WORDS" ]; then
            log_debug "empty, request another image"
            XY='-d t_img.x=23 -d t_img.y=7'
        fi

        # Verify solution/request new challenge
        HTML=$(curl --referer "$URL" \
            -d "adcopy_response=$WORDS" \
            -d "k=$PUB_KEY" \
            -d 'l=en' \
            -d 't=img' \
            -d 's=standard' \
            -d "magic=$MAGIC" \
            -d "adcopy_challenge=$CHALL" \
            $XY \
            "$BASE_URL/verify.noscript") || return

        if ! match 'Redirecting\.\.\.' "$HTML" ||
            match '&error=1&' "$HTML"; then
            captcha_nack "$TID"
            return $ERR_CAPTCHA
        fi

        URL=$(echo "$HTML" | parse 'META' 'URL=\(.\+\)">') || return

        [ -n "$WORDS" ] && break
    done

    HTML=$(curl "$URL") || return

    if ! match 'Please copy this gibberish:' "$HTML" || \
            ! match "$CHALL" "$HTML"; then
        log_debug 'Unexpected content. Site updated?'
        return $ERR_FATAL
    fi

    echo "$CHALL"
    echo "$TID"
}

# Positive acknowledge of captcha answer
# $1: id (returned by captcha_process/recaptcha_process/solvemedia_captcha_process)
captcha_ack() {
    [ "$1" = 0 ] && return

    local -r M=${1:0:1}
    local -r TID=${1:1}
    local RESPONSE STR

    if [ '9' = "$M" ]; then
        if [ -n "$CAPTCHA_9KWEU" ]; then
            RESPONSE=$(curl --get --data 'action=usercaptchacorrectback' \
                --data "apikey=$CAPTCHA_9KWEU" --data "id=$TID" \
                --data 'correct=1' 'http://www.9kw.eu/index.cgi') || return

            [ 'OK' = "$RESPONSE" ] || \
                log_error "9kw.eu error: $RESPONSE"
        else
            log_error "$FUNCNAME failed: 9kweu missing captcha key"
        fi

    elif [[ "$M" != [abd] ]]; then
        log_error "$FUNCNAME failed: unknown transaction ID: $1"
    fi
}

# Negative acknowledge of captcha answer
# $1: id (returned by captcha_process/recaptcha_process/solvemedia_captcha_process)
captcha_nack() {
    [ "$1" = 0 ] && return

    local -r M=${1:0:1}
    local -r TID=${1:1}
    local RESPONSE STR

    if [ '9' = "$M" ]; then
        if [ -n "$CAPTCHA_9KWEU" ]; then
            RESPONSE=$(curl --get --data 'action=usercaptchacorrectback' \
                --data "apikey=$CAPTCHA_9KWEU" --data "id=$TID" \
                --data 'correct=2' 'http://www.9kw.eu/index.cgi') || return

            [ 'OK' = "$RESPONSE" ] || \
                log_error "9kw.eu error: $RESPONSE"
        else
            log_error "$FUNCNAME failed: 9kweu missing captcha key"
        fi

    elif [ a = "$M" ]; then
        if [ -n "$CAPTCHA_ANTIGATE" ]; then
            RESPONSE=$(curl --get \
                --data "key=${CAPTCHA_ANTIGATE}&action=reportbad&id=$TID"  \
                'http://antigate.com/res.php') || return

            [ 'OK_REPORT_RECORDED' = "$RESPONSE" ] || \
                log_error "antigate error: $RESPONSE"
        else
            log_error "$FUNCNAME failed: antigate missing captcha key"
        fi

    elif [ b = "$M" ]; then
        if [ -n "$CAPTCHA_BHOOD" ]; then
            local USERNAME=${CAPTCHA_BHOOD%%:*}
            local PASSWORD=${CAPTCHA_BHOOD#*:}

            log_debug "captcha brotherhood report nack ($USERNAME)"

            RESPONSE=$(curl --get \
                -d "username=$USERNAME" -d "password=$PASSWORD" \
                -d "captchaID=$TID" \
                'http://www.captchabrotherhood.com/complainCaptcha.aspx') || return

            [ 'OK-Complained' = "$RESPONSE" ] || \
                log_error "$FUNCNAME FIXME cbh[$RESPONSE]"
        else
            log_error "$FUNCNAME failed: captcha brotherhood missing account data"
        fi

    elif [ d = "$M" ]; then
        if [ -n "$CAPTCHA_DEATHBY" ]; then
            local USERNAME=${CAPTCHA_DEATHBY%%:*}
            local PASSWORD=${CAPTCHA_DEATHBY#*:}

            log_debug "DeathByCaptcha report nack ($USERNAME)"

            RESPONSE=$(curl -F "username=$USERNAME" -F "password=$PASSWORD" \
                --header 'Accept: application/json' \
                "http://api.dbcapi.me/api/captcha/$TID/report") || return

            STR=$(echo "$RESPONSE" | parse_json_quiet 'status')
            [ "$STATUS" = '0' ] || \
                log_error "DeathByCaptcha: report nack error ($RESPONSE)"
        else
            log_error "$FUNCNAME failed: DeathByCaptcha missing account data"
        fi

    else
        log_error "$FUNCNAME failed: unknown transaction ID: $1"
    fi
}

# Generate a pseudo-random character sequence.
# Don't use /dev/urandom or $$ but $RANDOM (internal bash builtin,
# range 0-32767). Note: chr() is from Greg's Wiki (BashFAQ/071).
#
# $1: operation type (string)
#   - "a": alpha [0-9a-z]. Param: length.
#   - "d", "dec": positive decimal number. First digit is never 0.
#                 Param: number of digits.
#   - "h", "hex": hexadecimal number. First digit is never 0. No '0x' prefix.
#                 Param: number of digits.
#   - "H": same as "h" but in uppercases
#   - "js": Math.random() equivalent (>=0 and <1).
#           It's a double: ~15.9 number of decimal digits). No param.
#   - "l": letters [a-z]. Param: length.
#   - "L": letters [A-Z]. Param: length.
#   - "ll", "LL": letters [A-Za-z]. Param: length.
#   - "u16": unsigned short (decimal) number <=65535. Example: "352".
# $2: (optional) operation parameter
random() {
    local I=0
    local LEN=${2:-8}
    local -r SEED=$RANDOM
    local RESULT N

    # FIXME: Adding LC_CTYPE=C in front of printf is required?

    case $1 in
        d|dec)
            RESULT=$(( SEED % 9 + 1 ))
            (( ++I ))
            while (( I < $LEN )); do
                N=$(printf '%04u' $((RANDOM % 10000)))
                RESULT=$RESULT$N
                (( I += 4 ))
            done
            ;;
        h|hex)
            RESULT=$(printf '%x' $(( SEED % 15 + 1 )))
            (( ++I ))
            while (( I < $LEN )); do
                N=$(printf '%04x' $((RANDOM & 65535)))
                RESULT=$RESULT$N
                (( I += 4 ))
            done
            ;;
        H)
            RESULT=$(printf '%X' $(( SEED % 15 + 1 )))
            (( ++I ))
            while (( I < $LEN )); do
                N=$(printf '%04X' $((RANDOM & 65535)))
                RESULT=$RESULT$N
                (( I += 4 ))
            done
            ;;
        l)
            while (( I++ < $LEN )); do
                N=$(( RANDOM % 26 + 16#61))
                RESULT=$RESULT$(printf \\$(($N/64*100+$N%64/8*10+$N%8)))
            done
            ;;
        L)
            while (( I++ < $LEN )); do
                N=$(( RANDOM % 26 + 16#41))
                RESULT=$RESULT$(printf \\$(($N/64*100+$N%64/8*10+$N%8)))
            done
            ;;
        [Ll][Ll])
            while (( I++ < $LEN )); do
                N=$(( RANDOM % 52 + 16#41))
                [[ $N -gt 90 ]] && (( N += 6 ))
                RESULT=$RESULT$(printf \\$(($N/64*100+$N%64/8*10+$N%8)))
            done
            ;;
        a)
            while (( I++ < $LEN )); do
                N=$(( RANDOM % 36 + 16#30))
                [[ $N -gt 57 ]] && (( N += 39 ))
                RESULT=$RESULT$(printf \\$(($N/64*100+$N%64/8*10+$N%8)))
            done
            ;;
        js)
            LEN=$((SEED % 3 + 17))
            RESULT='0.'$((RANDOM * 69069 & 16#ffffffff))
            RESULT=$RESULT$((RANDOM * 69069 & 16#ffffffff))
            ;;
        u16)
            RESULT=$(( 256 * (SEED & 255) + (RANDOM & 255) ))
            LEN=${#RESULT}
            ;;
        *)
            log_error "$FUNCNAME: unknown operation '$1'"
            return $ERR_FATAL
            ;;
    esac
    echo ${RESULT:0:$LEN}
}

# Calculate MD5 hash (128-bit) of a string.
# See RFC1321.
#
# $1: input string
# stdout: message-digest fingerprint (32-digit hexadecimal number, lowercase letters)
# $? zero for success or $ERR_SYSTEM
md5() {
    # GNU coreutils
    if check_exec md5sum; then
        echo -n "$1" | md5sum -b 2>/dev/null | cut -d' ' -f1
    # BSD
    elif check_exec md5; then
        "$(type -P md5)" -qs "$1"
    # OpenSSL
    elif check_exec openssl; then
        echo -n "$1" | openssl dgst -md5 | cut -d' ' -f2
    # FIXME: use javascript if requested
    else
        log_error "$FUNCNAME: cannot find md5 calculator"
        return $ERR_SYSTEM
    fi
}

# Calculate MD5 hash (128-bit) of a file.
# $1: input file
# stdout: message-digest fingerprint (32-digit hexadecimal number, lowercase letters)
# $? zero for success or $ERR_SYSTEM
md5_file() {
    if [ -f "$1" ]; then
        # GNU coreutils
        if check_exec md5sum; then
            md5sum -b "$1" 2>/dev/null | cut -d' ' -f1
        # BSD
        elif check_exec md5; then
            "$(type -P md5)" -q "$1"
        # OpenSSL
        elif check_exec openssl; then
            openssl dgst -md5 "$1" | cut -d' ' -f2
        else
            log_error "$FUNCNAME: cannot find md5 calculator"
            return $ERR_SYSTEM
        fi
    else
        log_error "$FUNCNAME: cannot stat file"
        return $ERR_SYSTEM
    fi
}

# Split credentials
# $1: auth string (user:password)
# $2: variable name (user)
# $3: (optional) variable name (password)
# Note: $2 or $3 can't be named '__AUTH__' or '__STR__'
split_auth() {
    local __AUTH__=$1
    local __STR__

    if [ -z "$__AUTH__" ]; then
        log_error "$FUNCNAME: authentication string is empty"
        return $ERR_LOGIN_FAILED
    fi

    __STR__=${__AUTH__%%:*}
    if [ -z "$__STR__" ]; then
        log_error "$FUNCNAME: empty string (user)"
        return $ERR_LOGIN_FAILED
    fi

    [[ "$2" ]] && unset "$2" && eval $2=\$__STR__

    if [[ "$3" ]]; then
        # Sanity check
        if [ "$2" = "$3" ]; then
            log_error "$FUNCNAME: user and password varname must not be the same"
        else
            __STR__=${__AUTH__#*:}
            if [ -z "$__STR__" -o "$__AUTH__" = "$__STR__" ]; then
                __STR__=$(prompt_for_password) || return $ERR_LOGIN_FAILED
            fi
            unset "$3" && eval $3=\$__STR__
        fi
    fi
}

# Report list results. Only used by list module functions.
#
# $1: links list (one url per line)
# $2: (optional) name list (one filename per line)
# $3: (optional) link prefix (gets prepended to every link)
# $?: 0 for success or $ERR_LINK_DEAD
list_submit() {
    local LINE I

    test "$1" || return $ERR_LINK_DEAD

    if test "$2"; then
        local -a LINKS NAMES

        mapfile -t LINKS <<< "$1"
        mapfile -t NAMES <<< "$2"

        for I in "${!LINKS[@]}"; do
            test "${LINKS[$I]}" || continue
            echo "$3${LINKS[$I]}"
            echo "${NAMES[$I]}"
        done
    else
        while IFS= read -r LINE; do
            test "$LINE" || continue
            echo "$3$LINE"
            echo
        done <<< "$1"
    fi
}

# Return a numeric size (in bytes)
# $1: integer or floating point number (examples: "128" ; "4k" ; "5.34MiB")
#     with optional suffix (K, kB, KiB, KB, MiB, MB, GiB, GB)
# stdout: fixed point number (in bytes)
translate_size() {
    local N=${1// }
    local S T

    N=${N//	}
    if [ "$N" = '' ]; then
        log_error "$FUNCNAME: argument expected"
        return $ERR_FATAL
    fi

    S=$(sed -ne '/[.,]/{s/^\(-\?[[:digit:]]*\)[.,]\([[:digit:]]\+\).*$/\1_\2/p;b};
        s/^\(-\?[[:digit:]]\+\).*$/\1_/p' <<< "$N") || return $ERR_SYSTEM

    if [[ $S = '' || $S = '_' ]]; then
        log_error "$FUNCNAME: invalid parsed number \`$N'"
        return $ERR_FATAL
    fi

    declare -i R=10#${S%_*}
    declare -i F=0

    # Fractionnal part (consider 3 digits)
    T=${S#*_}
    if test "$T"; then
        T="1${T}00"
        F=10#${T:1:3}
        T=$(( ${#S} ))
    else
        T=$(( ${#S} - 1 ))
    fi

    S=$(sed -e "s/^\.\?\([KkMmGg]i\?[Bb]\?\)$/\1/" <<< "${N:$T}") || return $ERR_SYSTEM

    case $S in
        # kilobyte (10^3 bytes)
        k|kB)
            echo $(( 1000 * R + F))
            ;;
        # kibibyte (KiB)
        KiB|Ki|K|KB)
            echo $(( 1024 * R + F))
            ;;
        # megabyte (10^6)
        M|MB)
            echo $(( 1000000 * R + 1000 * F))
            ;;
        # mebibyte (MiB)
        MiB|Mi|m|mB)
            echo $(( 1048576 * R + 1000 * F))
            ;;
        # gigabyte (10^9)
        G|GB)
            echo $(( 1000000000 * R + 1000000 * F))
            ;;
        # gibibyte (GiB)
        GiB|Gi)
            echo $(( 1073741824 * R + 1000000 * F))
            ;;
        # bytes
        '')
            echo "$R"
            ;;
        *b)
            log_error "$FUNCNAME: unknown unit \`$S' (we don't deal with bits, use B for bytes)"
            return $ERR_FATAL
            ;;
        *)
            log_error "$FUNCNAME: unknown unit \`$S'"
            return $ERR_FATAL
            ;;
    esac
}

## ----------------------------------------------------------------------------

##
## Miscellaneous functions that can be called from core:
## download.sh, upload.sh, delete.sh, list.sh
##

# Remove all temporal files created by the script
# (with create_tempfile)
remove_tempfiles() {
    rm -f "${TMPDIR:-/tmp}/$(basename_file $0).$$".*
}

# Exit callback (task: clean temporal files)
set_exit_trap() {
    trap remove_tempfiles EXIT
}

# Check existance of executable in path
# Better than "which" (external) executable
#
# $1: Executable to check
# $?: zero means not found
check_exec() {
    type -P $1 >/dev/null || return 1 && return 0
}

# Related to -t/--timeout command line option
timeout_init() {
    PS_TIMEOUT=$1
}

# Show help info for options
#
# $1: options
# $2: indent string
print_options() {
    local -r INDENT=${2:-'  '}
    local STR VAR SHORT LONG TYPE MSG

    while read -r; do
        test "$REPLY" || continue
        IFS="," read VAR SHORT LONG TYPE MSG <<< "$REPLY"
        if [ -n "$SHORT" ]; then
            if test "$TYPE"; then
                STR="-${SHORT} ${TYPE#*=}"
                test -n "$LONG" && STR="-${SHORT}, --${LONG}=${TYPE#*=}"
            else
                STR="-${SHORT}"
                test -n "$LONG" && STR="$STR, --${LONG}"
            fi
        # long option only
        else
            if test "$TYPE"; then
                STR="    --${LONG}=${TYPE#*=}"
            else
                STR="    --${LONG}"
            fi
        fi
        printf '%-35s%s\n' "$INDENT$STR" "$MSG"
    done <<< "$1"
}

# Show usage info for modules
#
# $1: module name list (one per line)
# $2: option family name (string, example:UPLOAD)
print_module_options() {
    while read -r; do
        local OPTIONS=$(get_module_options "$REPLY" "$2")
        if test "$OPTIONS"; then
            echo
            echo "Options for module <$REPLY>:"
            echo
            print_options "$OPTIONS"
        fi
    done <<< "$1"
}

# Get all modules options with specified family name
#
# $1: module name list (one per line)
# $2: option family name (string, example:UPLOAD)
get_all_modules_options() {
    while read -r; do
        get_module_options "$REPLY" "$2"
    done <<< "$1"
}

# Get module name from URL link
#
# $1: url
# $2: module name list (one per line)
get_module() {
    while read -r; do
        local -u VAR="MODULE_${REPLY}_REGEXP_URL"
        if match "${!VAR}" "$1"; then
            echo "$REPLY"
            return 0
        fi
    done <<< "$2"
    return $ERR_NOMODULE
}

# $1: program name (used for error reporting only)
# $2: core option list (one per line)
# $3..$n: arguments
process_core_options() {
    local -r NAME=$1
    local -r OPTIONS=$(strip_and_drop_empty_lines "$2")
    shift 2
    VERBOSE=2 process_options "$NAME" "$OPTIONS" -1 "$@" || return
}

# $1: program name (used for error reporting only)
# $2: all modules option list (one per line)
# $3..$n: arguments
process_all_modules_options() {
    local -r NAME=$1
    local -r OPTIONS=$2
    shift 2
    process_options "$NAME" "$OPTIONS" 0 "$@" || return
}

# $1: module name (used for error reporting only)
# $2: option family name (string, example:UPLOAD)
# $3..$n: arguments
process_module_options() {
    local -r MODULE=$1
    local -r OPTIONS=$(get_module_options "$1" "$2")
    shift 2
    process_options "$MODULE" "$OPTIONS" 1 "$@" || return
}

# Get module list according to capability
# Note1: use global variable LIBDIR
# Note2: VERBOSE (log_debug) not initialised yet
#
# $1: feature to grep (must not contain '|' char)
# $2 (optional): feature to subtract (must not contain '|' char)
# stdout: return module list (one name per line)
grep_list_modules() {
    local -r CONFIG="$LIBDIR/modules/config"

    if [ ! -f "$CONFIG" ]; then
        stderr "can't find config file"
        return $ERR_SYSTEM
    fi

    if test "$2"; then
        sed -ne "/^[^#]/{/|[[:space:]]*$1/{/|[[:space:]]*$2/!s/^\([^[:space:]|]*\).*/\1/p}}" \
            "$CONFIG"
    else
        sed -ne "/^[^#]/{/|[[:space:]]*$1/s/^\([^[:space:]|]*\).*/\1/p}" \
            "$CONFIG"
    fi
}

# $1: section name in ini-style file ("General" will be considered too)
# $2: command-line arguments list
# Note: VERBOSE (log_debug) not initialised yet
process_configfile_options() {
    local CONFIG OPTIONS SECTION LINE NAME VALUE OPTION

    CONFIG="$HOME/.config/plowshare/plowshare.conf"
    test ! -f "$CONFIG" && CONFIG='/etc/plowshare.conf'
    test -f "$CONFIG" || return 0

    # Strip spaces in options
    OPTIONS=$(strip_and_drop_empty_lines "$2")

    SECTION=$(sed -ne "/\[$1\]/,/^\[/p" -ne "/\[General\]/,/^\[/p" "$CONFIG" | \
              sed -e '/^\(#\|\[\|[[:space:]]*$\)/d')

    if [ -n "$SECTION" -a -n "$OPTIONS" ]; then
        while read -r LINE; do
            NAME=$(strip <<< "${LINE%%=*}")
            VALUE=$(strip <<< "${LINE#*=}")

            # Look for optional double quote (protect leading/trailing spaces)
            if [ '"' = "${VALUE:0:1}" -a '"' = "${VALUE:(-1):1}" ]; then
                VALUE=${VALUE%?}
                VALUE=${VALUE:1}
            fi

            # Look for 'long_name' in options list
            OPTION=$(echo "$OPTIONS" | grep ",${NAME}:\?," | sed '1q') || true
            if [ -n "$OPTION" ]; then
                local VAR=${OPTION%%,*}
                eval "$VAR=\$VALUE"
            fi
        done <<< "$SECTION"
    fi
}

# $1: section name in ini-style file ("General" will be considered too)
# $2: module name
# $3: option family name (string, example:DOWNLOAD)
process_configfile_module_options() {
    local CONFIG OPTIONS SECTION OPTION LINE VALUE

    CONFIG="$HOME/.config/plowshare/plowshare.conf"
    if [ -f "$CONFIG" ]; then
        if [ -O "$CONFIG" ]; then
            local FILE_PERM=$(stat -c %A "$CONFIG")
            test -z "$FILE_PERM" && FILE_PERM=$(ls -l "$CONFIG" | cut -b1-10)
            if [[ ${FILE_PERM:4:6} != '------' ]]; then
                log_notice "Warning (configuration file permissions): chmod 600 $CONFIG"
            fi
        else
            log_notice "Warning (configuration file ownership): chown $USERNAME $CONFIG"
        fi
    else
        CONFIG='/etc/plowshare.conf'
        test -f "$CONFIG" || return 0
    fi

    log_report "use $CONFIG"

    OPTIONS=$(get_module_options "$2" "$3")

    SECTION=$(sed -ne "/\[$1\]/,/^\[/p" -ne "/\[General\]/,/^\[/p" "$CONFIG" | \
              sed -e '/^\(#\|\[\|[[:space:]]*$\)/d')

    if [ -n "$SECTION" -a -n "$OPTIONS" ]; then
        local -r M=$(lowercase "$2")

        # For example:
        # AUTH,a,auth,a=USER:PASSWORD,User account
        while read -r; do
            IFS="," read VAR SHORT LONG TYPE_HELP <<< "$REPLY"

            # Look for 'module/option_name' (short or long) in section list
            LINE=$(echo "$SECTION" | grep "^$M/\($SHORT\|$LONG\)[[:space:]]*=" | sed -n '$p') || true
            if [ -n "$LINE" ]; then
                VALUE=$(strip <<< "${LINE#*=}")

                # Look for optional double quote (protect leading/trailing spaces)
                if [ '"' = "${VALUE:0:1}" -a '"' = "${VALUE:(-1):1}" ]; then
                    VALUE=${VALUE%?}
                    VALUE=${VALUE:1}
                fi

                eval "$VAR=\$VALUE"
                log_notice "$M: take --$LONG option from configuration file"
            else
                unset "$VAR"
            fi
        done <<< "$OPTIONS"
    fi
}

# Get system information
log_report_info() {
    local G

    if test $VERBOSE -ge 4; then
        log_report '=== SYSTEM INFO BEGIN ==='
        log_report "[mach] $(uname -a)"
        log_report "[bash] $BASH_VERSION"
        test "$http_proxy" && log_report "[env ] http_proxy=$http_proxy"
        if check_exec 'curl'; then
            log_report "[curl] $("$(type -P curl)" --version | first_line)"
        else
            log_report '[curl] not found!'
        fi
        check_exec 'gsed' && G=g
        log_report "[sed ] $("$(type -P ${G}sed)" --version | sed -ne '/version/p')"
        log_report '=== SYSTEM INFO END ==='
    fi
}

# Translate plowdown --captchamethod argument
# to solve & view method (used by captcha_process)
# $1: method (string)
# $2 (optional): solve method (variable name)
# $3 (optional): display method (variable name)
captcha_method_translate() {
    case $1 in
        none)
            [[ $2 ]] && unset "$2" && eval $2=none
            [[ $3 ]] && unset "$3" && eval $3=none
            ;;
        imgur)
            [[ $2 ]] && unset "$2" && eval $2=prompt
            [[ $3 ]] && unset "$3" && eval $3=imgur
            ;;
        prompt)
            [[ $2 ]] && unset "$2" && eval $2=$1
            [[ $3 ]] && unset "$3" && eval $3=""
            ;;
        nox)
            [[ $2 ]] && unset "$2" && eval $2=prompt-nox
            [[ $3 ]] && unset "$3" && eval $3=""
            ;;
        online)
            local SITE
            if [ -n "$CAPTCHA_ANTIGATE" ]; then
                SITE=antigate
            elif [ -n "$CAPTCHA_9KWEU" ]; then
                SITE=9kweu
            elif [ -n "$CAPTCHA_BHOOD" ]; then
                SITE=captchabrotherhood
            elif [ -n "$CAPTCHA_DEATHBY" ]; then
                SITE=deathbycaptcha
            else
                log_error "Error: no captcha solver account provided"
                return $ERR_FATAL
            fi
            [[ $2 ]] && unset "$2" && eval $2=$SITE
            [[ $3 ]] && unset "$3" && eval $3=none
            ;;
        *)
            log_error "Error: unknown captcha method: $1"
            return $ERR_FATAL
            ;;
    esac
    return 0
}

## ----------------------------------------------------------------------------

##
## Private ('static') functions
## Can be called from this script only.
##

stderr() {
    echo "$@" >&2
}

# This function shell-quotes the argument ($1)
# Note: Taken from /etc/bash_completion
quote()
{
    echo \'${1//\'/\'\\\'\'}\' #'# Help vim syntax highlighting
}

# $1: input string (this is a comma separated list)
# stdout: quote items (one per line)
quote_array() {
    local -a ARR
    local E
    IFS="," read -r -a ARR <<< "$1"
    echo '('
    for E in "${ARR[@]}"; do
        quote "$(strip <<< "$E")"
    done
    echo ')'
}

# Check for positive speed rate
# Ki is kibi (2^10 = 1024). Alias: K
# Mi is mebi (2^20 = 1024^2 = 1048576). Alias:m
# k  is kilo (10^3 = 1000)
# M  is mega (10^6 = 1000000)
#
# $1: integer number (with or without suffix)
check_transfer_speed() {
    local N=${1// }

    # Probe for unit
    case $N in
        *Ki|*Mi)
            N=${N%??}
            ;;
        *K|*m|*k|*M)
            N=${N%?}
            ;;
        *)
            ;;
    esac

    if [[ $N = *[![:digit:]]* || $N -eq 0 ]]; then
        return 1
    fi
}

# Extract a specific block from a HTML content.
# Notes:
# - Use this function with leaf blocks (avoid <div>, <p>)
# - Two distinct blocks can't begin or end on the same line
# - HTML comments are just ignored
#
# $1: Marker regex.
# $2: (X)HTML data
# $3: (optional) Nth <tag>. Index start at 1: first block of page.
#     Negative index possible: -1 means last block of page and so on.
#     Zero or empty value means 1.
# stdout: result
grep_block_by_order() {
    local -r TAG=$1
    local DATA=$2
    local N=${3:-'1'}
    local DOT NEW

    # Check number of <tag> markers
    DOT=$(echo "$DATA" | sed -ne "/<$TAG[[:space:]>]/s/.*/./p" | tr -d '\n')
    if (( $N < 0 )); then
        N=$(( ${#DOT} + 1 + N ))
        if (( $N <= 0 )); then
            log_error "${FUNCNAME[1]} failed: negative index is too big (detected ${#DOT} forms)"
            return $ERR_FATAL
        fi
    fi

    NEW=${TAG//[}
    NEW=${NEW//]}
    while [ "$N" -gt "1" ]; do
        (( --N ))
        DATA=$(echo "$DATA" | sed -ne "/<\/$TAG>/,\$p" | \
            sed -e "1s/<\/\?$TAG[[:space:]>]/<_${NEW}_>/g")

        test -z "$DATA" && break
    done

    # Get first form only
    local STRING=$(sed -ne \
        "/<$TAG[[:space:]>]/,/<\/$TAG>/{p;/<\/$TAG/q}" <<< "$DATA")

    if [ -z "$STRING" ]; then
        log_error "${FUNCNAME[1]} failed (sed): \"n=$N\""
        return $ERR_FATAL
    fi

    echo "$STRING"
}

# Check argument type
# $1: program name (used for error reporting only)
# $2: format (a, e, l, n, N, r, s, S, V)
# $3: string
# $4: option string (used for error reporting only)
# $?: return 0 for success
check_argument_type() {
    local -r NAME=$1
    local -r TYPE=$2
    local -r VAL=$3
    local -r OPT=$4
    local RET=$ERR_BAD_COMMAND_LINE

    # a: Authentication string (user or user:password)
    if [[ $TYPE = 'a' && $VAL != *:* ]]; then
        log_debug "$NAME: missing password for credentials ($OPT)"
        RET=0
    # n: Positive integer (>0)
    elif [[ $TYPE = 'n' && ( $VAL = *[![:digit:]]* || $VAL -le 0 ) ]]; then
        log_error "$NAME: positive integer expected ($OPT)"
    # N: Positive integer or zero (>=0)
    elif [[ $TYPE = 'N' && ( $VAL = *[![:digit:]]* || $VAL = '' ) ]]; then
        log_error "$NAME: positive or zero integer expected ($OPT)"
    # s: Non empty string
    elif [[ $TYPE = 's' && $VAL = '' ]]; then
        log_error "$NAME: empty string not expected ($OPT)"
    # r: Speed rate (positive value, in bytes). Known suffixes: Ki/K/k/Mi/M/m
    elif [ "$TYPE" = 'r' ] && ! check_transfer_speed "$VAL"; then
        log_error "$NAME: positive transfer rate expected ($OPT)"
    # e: E-mail string
    elif [[ $TYPE = 'e' && "${VAL#*@*.}" = "$VAL" ]]; then
        log_error "$NAME: invalid email address ($OPT)"
    # l: List (comma-separated values), non empty
    elif [[ $TYPE = 'l' && $VAL = '' ]]; then
        log_error "$NAME: comma-separated list expected ($OPT)"
    # V: special type for verbosity (values={0,1,2,3,4})
    elif [[ $TYPE = 'V' && $VAL != [0-4] ]]; then
       log_error "$NAME: wrong verbose level \`$VAL'. Must be 0, 1, 2, 3 or 4."

    elif [[ "$TYPE" = [lsS] ]]; then
        RET=0
    elif [[ "$TYPE" = [aenNrV] ]]; then
        if [ "${VAL:0:1}" = '-' ]; then
            log_error "$NAME: missing parameter ($OPT)"
        else
            RET=0
        fi
    else
        log_error "$NAME: unknown argument type ($TYPE)"
    fi

    test $RET && echo false
    return $RET
}

# Standalone argument parsing (don't use GNU getopt or builtin getopts Bash)
# $1: program name (used for error reporting only)
# $2: option list (one per line)
# $3: step number (-1; 0 or 1)
# $4..$n: arguments
# stdout: variable=value (one per line). Content can be eval'ed.
process_options() {
    local -r NAME=$1
    local -r OPTIONS=$2
    local -r STEP=$3

    local -a RES UNUSED_OPTS UNUSED_ARGS
    local -a OPTS_VAR_LONG OPTS_NAME_LONG OPTS_TYPE_LONG
    local -a OPTS_VAR_SHORT OPTS_NAME_SHORT OPTS_TYPE_SHORT
    local ARG VAR SHORT LONG TYPE HELP SKIP_ARG FOUND FUNC

    shift 3

    if [ -z "$OPTIONS" ]; then
        if [ $STEP -gt 0 ]; then
            echo "${NAME}_vars_set() { :; }"
            echo "${NAME}_vars_unset() { :; }"
            return 0
        fi
    else
        # Populate OPTS_* vars
        while read ARG; do
            IFS="," read VAR SHORT LONG TYPE HELP <<< "$ARG"
            if [ -n "$LONG" ]; then
                OPTS_VAR_LONG[${#OPTS_VAR_LONG[@]}]=$VAR
                OPTS_NAME_LONG[${#OPTS_NAME_LONG[@]}]="--$LONG"
                OPTS_TYPE_LONG[${#OPTS_TYPE_LONG[@]}]=$TYPE
            fi
            if [ -n "$SHORT" ]; then
                OPTS_VAR_SHORT[${#OPTS_VAR_SHORT[@]}]=$VAR
                OPTS_NAME_SHORT[${#OPTS_NAME_SHORT[@]}]="-$SHORT"
                OPTS_TYPE_SHORT[${#OPTS_TYPE_SHORT[@]}]=$TYPE
            fi
        done <<< "$OPTIONS"
    fi

    for ARG in "$@"; do
        shift

        if [ -n "$SKIP_ARG" ]; then
            unset SKIP_ARG
            [ $STEP -eq 0 ] && UNUSED_OPTS[${#UNUSED_OPTS[@]}]="$ARG"
            continue
        fi

        if [ "$ARG" = '--' ]; then
            UNUSED_ARGS=("${UNUSED_ARGS[@]}" "$@")
            break
        fi

        unset FOUND

        # Long option
        if [ "${ARG:0:2}" = '--' ]; then
            for I in "${!OPTS_NAME_LONG[@]}"; do
                if [ "${OPTS_NAME_LONG[$I]}" = "${ARG%%=*}" ]; then
                    # Argument required?
                    TYPE=${OPTS_TYPE_LONG[$I]%%=*}

                    if [ "$TYPE" = 'l' ]; then
                        FUNC=quote_array
                    elif [ "$TYPE" = 'r' ]; then
                        FUNC=translate_size
                    else
                        FUNC=quote
                    fi

                    if [ -z "$TYPE" ]; then
                        RES[${#RES[@]}]="${OPTS_VAR_LONG[$I]}=1"
                        [ "${ARG%%=*}" != "$ARG" ] && \
                            log_notice "$NAME: unwanted argument for ${ARG%%=*}, ignoring"

                    # Argument with equal (ex: --timeout=60)
                    elif [ "${ARG%%=*}" != "$ARG" ]; then
                        [ $STEP -gt 0 ] || check_argument_type "$NAME" \
                            "$TYPE" "${ARG#*=}" "${ARG%%=*}" || return
                        RES[${#RES[@]}]="${OPTS_VAR_LONG[$I]}=$($FUNC "${ARG#*=}")"
                    else
                        if [ $# -eq 0 ]; then
                            log_error "$NAME: missing parameter for $ARG"
                            echo false
                            return $ERR_BAD_COMMAND_LINE
                        fi

                        [ $STEP -gt 0 ] || check_argument_type "$NAME" \
                            "$TYPE" "$1" "$ARG" || return
                        RES[${#RES[@]}]="${OPTS_VAR_LONG[$I]}=$($FUNC "$1")"
                        SKIP_ARG=1
                    fi

                    FOUND=1
                    break
                fi
            done

        # Short option
        elif [ "${ARG:0:1}" = '-' ]; then
            for I in "${!OPTS_NAME_SHORT[@]}"; do
                if [ "${OPTS_NAME_SHORT[$I]}" = "${ARG:0:2}" ]; then
                    # Argument required?
                    TYPE=${OPTS_TYPE_SHORT[$I]%%=*}

                    if [ "$TYPE" = 'l' ]; then
                        FUNC=quote_array
                    elif [ "$TYPE" = 'r' ]; then
                        FUNC=translate_size
                    else
                        FUNC=quote
                    fi

                    if [ -z "$TYPE" ]; then
                        RES[${#RES[@]}]="${OPTS_VAR_SHORT[$I]}=1"

                    # Argument without whitespace (ex: -v3)
                    elif [ ${#ARG} -gt 2 ]; then
                        [ $STEP -gt 0 ] || check_argument_type "$NAME" \
                            "$TYPE" "${ARG:2}" "${ARG:0:2}" || return
                        RES[${#RES[@]}]="${OPTS_VAR_SHORT[$I]}=$($FUNC "${ARG:2}")"
                    else
                        if [ $# -eq 0 ]; then
                            log_error "$NAME: missing parameter for $ARG"
                            echo false
                            return $ERR_BAD_COMMAND_LINE
                        fi

                        [ $STEP -gt 0 ] || check_argument_type "$NAME" \
                            "$TYPE" "$1" "$ARG" || return
                        RES[${#RES[@]}]="${OPTS_VAR_SHORT[$I]}=$($FUNC "$1")"
                        SKIP_ARG=1
                    fi

                    FOUND=1
                    break
                fi
            done
        fi

        if [ $STEP -eq 0 ]; then
            if [ -z "$FOUND" ]; then
                if [[ ${ARG:0:1} = '-' ]]; then
                    log_error "$NAME: unknown command-line option: $ARG"
                    echo false
                    return $ERR_BAD_COMMAND_LINE
                fi
                UNUSED_ARGS[${#UNUSED_ARGS[@]}]="$ARG"
            else
                UNUSED_OPTS[${#UNUSED_OPTS[@]}]="$ARG"
            fi
        elif [ -z "$FOUND" ]; then
            UNUSED_OPTS[${#UNUSED_OPTS[@]}]="$ARG"
        fi
    done

    # Declare core options as readonly
    if [ $STEP -lt 0 ]; then
        for ARG in "${RES[@]}"; do echo "declare -r $ARG"; done

    # Declare target module options: ${NAME}_vars_set/unset
    elif [ $STEP -gt 0 ]; then
        echo "${NAME}_vars_set() { :"
        for ARG in "${RES[@]}"; do echo "$ARG"; done
        echo '}'
        echo "${NAME}_vars_unset() { :"
        for ARG in "${RES[@]}"; do echo "${ARG%%=*}="; done
        echo '}'
    fi

    declare -p UNUSED_ARGS
    declare -p UNUSED_OPTS
}

# Delete leading and trailing whitespace & blank lines
# stdin: input (multiline) string
# stdout: result string
strip_and_drop_empty_lines() {
    sed -e '/^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$1"
}

# Look for a configuration module variable
# Example: MODULE_4SHARED_DOWNLOAD_OPTIONS (result can be multiline)
# $1: module name
# $2: option family name (string, example:UPLOAD)
# stdout: options list (one per line)
get_module_options() {
    local -ur VAR="MODULE_${1}_${2}_OPTIONS"
    strip_and_drop_empty_lines "${!VAR}"
}

# Example: 12345 => "3h25m45s"
# $1: duration (integer)
splitseconds() {
    local DIV_H=$(( $1 / 3600 ))
    local DIV_M=$(( ($1 % 3600) / 60 ))
    local DIV_S=$(( $1 % 60 ))

    [ "$DIV_H" -eq 0 ] || echo -n "${DIV_H}h"
    [ "$DIV_M" -eq 0 ] || echo -n "${DIV_M}m"
    [ "$DIV_S" -eq 0 ] && echo || echo "${DIV_S}s"
}

# Called by wait
# See also timeout_init()
timeout_update() {
    local WAIT=$1
    test -z "$PS_TIMEOUT" && return
    log_debug "time left to timeout: $PS_TIMEOUT secs"
    if [[ $PS_TIMEOUT -lt $WAIT ]]; then
        log_notice "Timeout reached (asked to wait $WAIT seconds, but remaining time is $PS_TIMEOUT)"
        return $ERR_MAX_WAIT_REACHED
    fi
    (( PS_TIMEOUT -= WAIT ))
}

# Look for one element in a array
# $1: array[@]
# $2: element to find
# $3: alternate element to find (can be null)
# $?: 0 for success (one element found), not found otherwise
find_in_array() {
    local ELT
    for ELT in "${!1}"; do
        [ "$ELT" = "$2" -o "$ELT" = "$3" ] && return 0
    done
    return 1
}

# Find next array index of one element
# $1: array[@]
# $2: element to find
# $3: alternate element to find (can be null)
# $?: 0 for success (one element found), not found otherwise
# stdout: array index, undefined if not found.
index_in_array() {
    local ELT I=0
    for ELT in "${!1}"; do
        (( ++I ))
        if [ "$ELT" = "$2" -o "$ELT" = "$3" ]; then
            # Note: assume that it is not last element
            echo "$I"
            return 0
        fi
    done
    return 1
}

# Verify balance (9kw.eu)
# $1: 9kw.eu captcha key
# $?: 0 for success (enough credits)
service_9kweu_ready() {
    local -r KEY=$1
    local AMOUNT

    if [ -z "$KEY" ]; then
        log_error "9kweu: missing captcha key"
        return $ERR_FATAL
    fi

    AMOUNT=$(curl --get --data 'action=usercaptchaguthaben' \
        --data "apikey=$CAPTCHA_9KWEU" 'http://www.9kw.eu/index.cgi') || { \
        log_notice '9kweu: site seems to be down'
        return $ERR_NETWORK
    }

    # 0011 Balance insufficient
    if [ "${AMOUNT:0:5}" = '0011 ' ]; then
        log_notice "9kw.eu: no more credits"
        return $ERR_FATAL
    elif [[ $AMOUNT = 00[01][[:digit:]][[:space:]]* ]]; then
        log_error "9kw.eu remote error: ${AMOUNT:5}"
        return $ERR_FATAL
    else
        log_debug "9kw.eu credits: $AMOUNT"
    fi
}

# Verify balance (antigate)
# $1: antigate.com captcha key
# $?: 0 for success (enough credits)
service_antigate_ready() {
    local -r KEY=$1
    local AMOUNT

    if [ -z "$KEY" ]; then
        log_error "antigate: missing captcha key"
        return $ERR_FATAL
    fi

    AMOUNT=$(curl --get --data "key=${CAPTCHA_ANTIGATE}&action=getbalance" \
        'http://antigate.com/res.php') || { \
        log_notice "antigate: site seems to be down"
        return $ERR_NETWORK
    }

    if match '500 Internal Server Error' "$AMOUNT"; then
        log_error "antigate: internal server error (HTTP 500)"
        return $ERR_CAPTCHA
    elif match '502 Bad Gateway' "$AMOUNT"; then
        log_error "antigate: bad gateway (HTTP 502)"
        return $ERR_CAPTCHA
    elif match '503 Service Unavailable' "$AMOUNT"; then
        log_error "antigate: service unavailable (HTTP 503)"
        return $ERR_CAPTCHA
    elif match '^ERROR' "$AMOUNT"; then
        log_error "antigate error: $AMOUNT"
        return $ERR_FATAL
    elif [ '0.0000' = "$AMOUNT" -o '-' = "${AMOUNT:0:1}" ]; then
        log_notice "antigate: no more credits (or bad key)"
        return $ERR_FATAL
    else
        log_debug "antigate credits: \$$AMOUNT"
    fi
}

# Verify balance (Captcha Brotherhood)
# $1: captcha brotherhood username
# $2: captcha brotherhood password
# $?: 0 for success (enough credits)
service_captchabrotherhood_ready() {
    local RESPONSE AMOUNT ERROR

    if [ -z "$1" -o -z "$2" ]; then
        log_error "CaptchaBrotherhood missing account data"
        return $ERR_FATAL
    fi

    RESPONSE=$(curl --get -d "username=$1" -d "password=$2" \
        'http://www.captchabrotherhood.com/askCredits.aspx') || return

    if [ "${RESPONSE:0:3}" = 'OK-' ]; then
        AMOUNT=${RESPONSE:3}

        if (( AMOUNT < 10 )); then
            log_notice "CaptchaBrotherHood: not enough credits ($1)"
            return $ERR_FATAL
        fi
    else
        ERROR=${RESPONSE#Error-}
        log_error "CaptchaBrotherHood error: $ERROR"
        return $ERR_FATAL
    fi

    log_debug "CaptchaBrotherhood credits: $AMOUNT"
}

# Verify balance (DeathByCaptcha)
# $1: death by captcha username
# $2: death by captcha password
# $?: 0 for success (enough credits)
service_captchadeathby_ready() {
    local -r USER=$1
    local JSON STATUS AMOUNT ERROR

    if [ -z "$1" -o -z "$2" ]; then
        log_error "DeathByCaptcha missing account data"
        return $ERR_FATAL
    fi

    JSON=$(curl -F "username=$USER" -F "password=$2" \
            --header 'Accept: application/json' \
            'http://api.dbcapi.me/api/user') || { \
        log_notice "DeathByCaptcha: site seems to be down"
        return $ERR_NETWORK
    }

    STATUS=$(echo "$JSON" | parse_json_quiet 'status')

    if [ "$STATUS" = 0 ]; then
        AMOUNT=$(echo "$JSON" | parse_json 'balance')

        if match_json_true 'is_banned' "$JSON"; then
            log_error "DeathByCaptcha error: $USER is banned"
            return $ERR_FATAL
        fi

        if [ "${AMOUNT%.*}" = 0 ]; then
            log_notice "DeathByCaptcha: not enough credits ($USER)"
            return $ERR_FATAL
        fi
    elif [ "$STATUS" = 255 ]; then
        ERROR=$(echo "$JSON" | parse_json_quiet 'error')
        log_error "DeathByCaptcha error: $ERROR"
        return $ERR_FATAL
    else
        log_error "DeathByCaptcha unknown error: $JSON"
        return $ERR_FATAL
    fi

    log_debug "DeathByCaptcha credits: $AMOUNT"
}

# Upload (captcha) image to Imgur (picture hosting service)
# Using official API: http://api.imgur.com/
# $1: image filename (with full path)
# stdout: delete url
# $?: 0 for success
image_upload_imgur() {
    local -r IMG=$1
    local -r BASE_API='http://api.imgur.com/2'
    local RESPONSE DIRECT_URL SITE_URL DEL_HASH

    log_debug "uploading image to Imgur.com"

    # Plowshare API key for Imgur
    RESPONSE=$(curl -F "image=@$IMG" -H 'Expect: ' \
        --form-string 'key=23d202e580c2f8f378bd2852916d8f30' \
        --form-string 'type=file' \
        --form-string 'title=Plowshare uploaded image' \
        "$BASE_API/upload.json") || return

    DIRECT_URL=$(echo "$RESPONSE" | parse_json_quiet original)
    SITE_URL=$(echo "$RESPONSE" | parse_json_quiet imgur_page)
    DEL_HASH=$(echo "$RESPONSE" | parse_json_quiet deletehash)

    if [ -z "$DIRECT_URL" -o -z "$SITE_URL" ]; then
        if match '504 Gateway Time-out' "$RESPONSE"; then
            log_error "$FUNCNAME: upload error (Gateway Time-out)"
        # <h1>Imgur is over capacity!</h1>
        elif match 'Imgur is over capacity' "$RESPONSE"; then
            log_error "$FUNCNAME: upload error (Service Unavailable)"
        else
            log_error "$FUNCNAME: upload error"
        fi
        return $ERR_FATAL
    fi

    log_error "Image: $DIRECT_URL"
    log_error "Image: $SITE_URL"
    echo "$DEL_HASH"
}

# Delete (captcha) image from Imgur (picture hosting service)
# $1: delete hash
image_delete_imgur() {
    local -r HID=$1
    local -r BASE_API='http://api.imgur.com/2'
    local RESPONSE MSG

    log_debug "deleting image from Imgur.com"
    RESPONSE=$(curl "$BASE_API/delete/$HID.json") || return
    MSG=$(echo "$RESPONSE" | parse_json_quiet message)
    if [ "$MSG" != 'Success' ]; then
        log_notice "$FUNCNAME: remote error, $MSG"
    fi
}

# Some debug information
log_notice_stack() {
    local N
    for N in "${!FUNCNAME[@]}"; do
        [ $N -le 1 ] && continue
        log_notice "failed inside ${FUNCNAME[$N]}(), line ${BASH_LINENO[$((N-1))]}, $(basename_file "${BASH_SOURCE[$N]}")"
        # quit if we go outside core.sh
        match '/core\.sh' "${BASH_SOURCE[$N]}" || break
    done
}
