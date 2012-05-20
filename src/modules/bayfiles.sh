#!/bin/bash
#
# bayfiles.com module
# Copyright (c) 2012 Plowshare team
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

MODULE_BAYFILES_REGEXP_URL="https\?://\(www\.\)\?bayfiles\.com/"

MODULE_BAYFILES_DOWNLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account"
MODULE_BAYFILES_DOWNLOAD_RESUME=yes
MODULE_BAYFILES_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no

MODULE_BAYFILES_UPLOAD_OPTIONS="
AUTH,a:,auth:,USER:PASSWORD,User account"
MODULE_BAYFILES_UPLOAD_REMOTE_SUPPORT=no

MODULE_BAYFILES_DELETE_OPTIONS=""

# Static function. Proceed with login (free or premium)
# Uses official API: http://bayfiles.com/api
bayfiles_login() {
    local AUTH=$1
    local API_URL=$2
    local LOGIN_JSON_DATA SESSID ERR

    # Must be tested with premium account
    IFS=":" read USER PASSWORD <<< "$AUTH"
    if [ -z "$PASSWORD" ]; then
        PASSWORD=$(prompt_for_password) || return $ERR_LOGIN_FAILED
    fi

    LOGIN_JSON_DATA=$(curl "${API_URL}/account/login/${USER}/${PASSWORD}") || return

    # {"error":"","session":"947qfkvd0eqvohb1sif3hcl0d2"}]
    SESSID=$(echo "$LOGIN_JSON_DATA" | parse_json_quiet 'session')
    if [ -z "$SESSID" ]; then
        ERR=$(echo "$LOGIN_JSON_DATA" | parse_json 'error')
        log_debug "Remote error: $ERR"
        return $ERR_LOGIN_FAILED
    fi

    log_debug "sessid: $SESSID"
    echo "$SESSID"
    return 0
}

# Output a bayiles file download URL
# $1: cookie file (for account only)
# $2: bayfiles url
# stdout: real file download link
# Same for free-user and anonymous user, not tested with premium
bayfiles_download() {
    eval "$(process_options bayfiles "$MODULE_BAYFILES_DOWNLOAD_OPTIONS" "$@")"

    local COOKIE_FILE=$1
    local URL=$2
    local API_URL='http://api.bayfiles.com/v1'
    local AJAX_URL='http://bayfiles.com/ajax_download'
    local PAGE FILE_URL FILENAME SESSION OPT_SESSION

    if [ -n "$AUTH" ]; then
        SESSION=$(bayfiles_login "$AUTH" "$API_URL") || return
        OPT_SESSION="-b SESSID=$SESSION"
        PAGE=$(curl -c "$COOKIE_FILE" $OPT_SESSION "$URL") || return
    else
        PAGE=$(curl -c "$COOKIE_FILE" -b "$COOKIE_FILE" "$URL") || return
    fi

    if match 'The link is incorrect' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    # <h3 class="comparison">What are the benefits for <strong>premium</strong> members?</h3>
    if match 'comparison\|benefits' "$PAGE"; then
        # Big files case
        local VFID DELAY TOKEN JSON_COUNT DATA_DL

        # Upgrade to premium or wait 5 minutes.
        if match 'Upgrade to premium or wait' "$PAGE"; then
            DELAY=$(echo "$PAGE" | parse 'premium or wait' \
                'wait[[:space:]]\([[:digit:]]\+\)[[:space:]]*minute')
            echo $((DELAY * 60))
            return $ERR_LINK_TEMP_UNAVAILABLE
        fi

        VFID=$(echo "$PAGE" | parse 'var vfid = ' '= \([[:digit:]]\+\);') || return

        # If no delay were found, we try without
        DELAY=$(echo "$PAGE" | parse_quiet 'var delay = ' '= \([[:digit:]]\+\);')

        JSON_COUNT=$(curl --get -b "$COOKIE_FILE" \
            --data "action=startTimer&vfid=$VFID" \
            "$AJAX_URL") || return

        TOKEN=$(echo "$JSON_COUNT" | parse_json token) || return

        wait $((DELAY)) || return

        DATA_DL=$(curl -b "$COOKIE_FILE" \
            $OPT_SESSION \
            --data "action=getLink&vfid=$VFID&token=$TOKEN" \
            "$AJAX_URL") || return

        FILE_URL=$(echo "$DATA_DL" | \
            parse 'onclick' "\(http[^']*\)") || return

    # Premium account
    else
        FILE_URL=$(echo "$PAGE" | parse_attr 'class="highlighted-btn' 'href') || return
    fi

    # Extract filename from $PAGE, work for both cases
    FILENAME=$(echo "$PAGE" | parse_attr_quiet 'title="' 'title')

    echo "$FILE_URL"
    echo "$FILENAME"
}

# Upload a file to bayfiles.com
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: download link + delete link + admin link
bayfiles_upload() {
    eval "$(process_options bayfiles "$MODULE_BAYFILES_UPLOAD_OPTIONS" "$@")"

    local FILE=$2
    local DESTFILE=$3
    local API_URL='http://api.bayfiles.com/v1'
    local SESSION_GET JSON UPLOAD_URL FILE_URL DELETE_URL ADMIN_URL

    # Account users (free or premium) have a session id
    if [ -n "$AUTH" ]; then
        SESSION_GET='?session='$(bayfiles_login "$AUTH" "$API_URL") || return
    else
        SESSION_GET=''
    fi

    JSON=$(curl "${API_URL}/file/uploadUrl${SESSION_GET}") || return

    # {"error":"","uploadUrl":"http ..","progressUrl":"http .."}
    UPLOAD_URL=$(echo "$JSON" | parse_json 'uploadUrl') || return

    JSON=$(curl_with_log -F "file=@$FILE;filename=$DESTFILE" \
        "$UPLOAD_URL") || return

    # {"error":"","fileId":"abK1","size":"123456","sha1":"6f ..", ..}
    FILE_URL=$(echo "$JSON" | parse_json 'downloadUrl') || return
    DELETE_URL=$(echo "$JSON" | parse_json 'deleteUrl') || return
    ADMIN_URL=$(echo "$JSON" | parse_json 'linksUrl') || return

    echo "$FILE_URL"
    echo "$DELETE_URL"
    echo "$ADMIN_URL"
}

# Delete a file on bayfiles
# $1: cookie file (unused here)
# $2: delete link
bayfiles_delete() {
    eval "$(process_options bayfiles "$MODULE_BAYFILES_DELETE_OPTIONS" "$@")"

    local URL=$2
    local PAGE CONFIRM

    PAGE=$(curl "$URL") || return

    # Are you sure you want to <strong>delete</strong> this file?
    if match 'Confirm Deletion' "$PAGE"; then
        CONFIRM=$(echo "$PAGE" | parse_attr 'Confirm' href) || return
        PAGE=$(curl "$URL$CONFIRM") || return

        # File successfully deleted.
        match 'successfully deleted' "$PAGE" && return 0

    # The requested file could not be found.
    elif match 'file could not be found' "$PAGE"; then
        return $ERR_LINK_DEAD

    fi

    # Invalid security token. Please check your link.
    return $ERR_FATAL
}
