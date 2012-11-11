#!/bin/bash
#
# dl.free.fr module
# Copyright (c) 2010-2012 Plowshare team
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

MODULE_DL_FREE_FR_REGEXP_URL="http://dl.free.fr/"

MODULE_DL_FREE_FR_DOWNLOAD_OPTIONS=""
MODULE_DL_FREE_FR_DOWNLOAD_RESUME=yes
MODULE_DL_FREE_FR_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=yes
MODULE_DL_FREE_FR_DOWNLOAD_SUCCESSIVE_INTERVAL=

MODULE_DL_FREE_FR_UPLOAD_OPTIONS=""
MODULE_DL_FREE_FR_UPLOAD_REMOTE_SUPPORT=no

MODULE_DL_FREE_FR_DELETE_OPTIONS=""

AYL_SERVER='http://api.adyoulike.com/'
# Adyoulike decoding function
# Main engine: http://api-ayl.appspot.com/static/js/ayl_lib.js
#
# $1: AYL site public key
# $2 (optional): env value (default is "prod")
# stdout: On 4 lines: <word> \n <challenge> \n <token_id> \n <transaction_id>
captcha_ayl_process() {
    local ENV=${2:-prod}
    local URL="${AYL_SERVER}challenge?key=${1}&env=$ENV"
    local TRY VARS TYPE WORDS RESPONSE TOKEN TOKEN_ID TID

    TRY=0
    # Arbitrary 100 limit is safer
    while (( TRY++ < 100 )) || return $ERR_MAX_TRIES_REACHED; do
        log_debug "Adyoulike loop $TRY"

        VARS=$(curl -L "$URL") || return

        if [ -z "$VARS" ]; then
            return $ERR_CAPTCHA
        fi

        WORDS=$(echo "$VARS" | parse_json_quiet 'instructions_visual' | tr -d '\302')
        TOKEN=$(echo "$VARS" | parse_json 'token') || return
        TOKEN_ID=$(echo "$VARS" | parse_json 'tid') || return
        TYPE=$(echo "$VARS" | parse_json 'medium_type' | replace '/' '_') || return

        log_debug "Adyoulike challenge: $TOKEN"

        # Easy case, captcha answer is written plain text :)
        # UTF-8 characters: � (\uC2AB), � (\uC2BB)
        if [ -n "$WORDS" -a "$TYPE" = 'image_adyoulike' ]; then
            # FIXME: Don't use \xHH in basic POSIX regexp
            RESPONSE=$(echo "$WORDS" | parse_quiet . '\xAB \([^ ]*\) \xBB')
            [ -n "$RESPONSE" ] && break

        #elif [ "$TYPE" = 'video_youtube' ];
        else
            log_error "$FUNCNAME: $TYPE not handled, skipping"
        fi

        # Maybe we'll need this later?
        # curl -b "ayl_tid=$TOKEN_ID" "${AYL_SERVER}iframe?iframe_type=${TYPE}&token=${TOKEN}&env=$ENV"

        FILENAME=$(create_tempfile '.ayl.jpg') || return
        curl -b "ayl_tid=$TOKEN_ID" -o "$FILENAME" \
            "${AYL_SERVER}resource?token=${TOKEN}&env=$ENV" || return

        WORDS=$(captcha_process "$FILENAME" prompt) || return
        rm -f "$FILENAME"

        { read RESPONSE; read TID; } <<<"$WORDS"

        [ -n "$RESPONSE" ] && break

        # Reload image
        log_debug "empty, request another image"
    done

    echo "$RESPONSE"
    echo "$TOKEN"
    echo "$TOKEN_ID"
    echo ${TID:-0}
}

# Output a dl.free.fr file download URL (anonymous)
# $1: cookie file
# $2: dl.free.fr url
# stdout: real file download link
dl_free_fr_download() {
    local COOKIE_FILE=$1
    local URL=$2
    local PAGE FORM_HTML FORM_ACTION FORM_FILE FORM_SUBM SESSID

    # Notes:
    # - "curl -I" (HTTP HEAD request) is ignored (returns 404 error)
    # - Range request is ignored for non Free ISP users (due to redir?)
    PAGE=$(curl -L -i -r 0-1024 "$URL") || return

    # Free is your ISP, this is direct download
    if match '^HTTP/1.1 206' "$PAGE"; then
        test "$CHECK_LINK" && return 0

        FILENAME=$(echo "$PAGE" | grep_http_header_content_disposition) || return
        echo "$URL"
        echo "$FILENAME"
        return 0
    fi

    local ERR1="erreur 500 - erreur interne du serveur"
    local ERR2="erreur 404 - document non trouv."
    if matchi "$ERR1\|$ERR2" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    FILENAME=$(echo "$PAGE" | parse 'Fichier:' '">\([^<]*\)' 1) || return

    FORM_HTML=$(grep_form_by_order "$PAGE" 2) || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return
    FORM_FILE=$(echo "$FORM_HTML" | parse_form_input_by_name 'file' | uri_encode_strict)
    FORM_SUBM=$(echo "$FORM_HTML" | parse_form_input_by_type 'submit' | uri_encode_strict)

    local PUBKEY WTTI WORD TOKEN TKID ID
    PUBKEY='P~zQ~O0zV0WTiAzC-iw0navWQpCLoYEP'
    WTTI=$(captcha_ayl_process $PUBKEY) || return
    { read WORD; read TOKEN; read TKID; read ID; } <<<"$WTTI"

    PAGE=$(curl -c "$COOKIE_FILE" \
        -d "file=$FORM_FILE" \
        -d "submit=$FORM_SUBM" \
        -d "_ayl_response=$WORD" \
        -d "_ayl_token_challenge=$TOKEN" \
        -d '_ayl_captcha_engine=adyoulike' \
        -d '_ayl_utf8_ie_fix=%E2%98%83' \
        -d "_ayl_tid=$TKID" \
        -d '_ayl_env=prod' \
        --referer "$URL" \
        "http://dl.free.fr/$FORM_ACTION") || return

    # Could also check for "Code incorrect" in $PAGE
    SESSID=$(parse_cookie_quiet 'getfile' < "$COOKIE_FILE")
    if [ -z "$SESSID" ]; then
        captcha_nack $ID
        return $ERR_CAPTCHA
    fi

    captcha_ack $ID
    log_debug "correct captcha"

    echo "$URL"
    echo "$FILENAME"
}

# Upload a file to dl.free.fr
# $1: cookie file (unused here)
# $2: input file (with full path)
# $3: remote filename
# stdout: dl.free.fr download + del link
dl_free_fr_upload() {
    local FILE=$2
    local DESTFILE=$3
    local UPLOADURL='http://dl.free.fr'
    local PAGE FORM_HTML FORM_ACTION HEADERS MON_PL WAIT_TIME DL_URL DEL_URL

    PAGE=$(curl "$UPLOADURL") || return

    FORM_HTML=$(grep_form_by_order "$PAGE" 2) || return
    FORM_ACTION=$(echo "$FORM_HTML" | parse_form_action) || return

    # <input> markers are: ufile, mail1, mail2, mail3, mail4, message, password
    # Returns 302. Answer headers are not returned with -i switch, I must
    # use -D. This should be reported to cURL bug tracker.
    HEADERS=$(create_tempfile) || return
    PAGE=$(curl_with_log -D "$HEADERS" \
        --referer "$UPLOADURL/index_nojs.pl" \
        -F "ufile=@$FILE;filename=$DESTFILE" \
        -F "mail1=" \
        -F "mail2=" \
        -F "mail3=" \
        -F "mail4=" \
        -F "message=test" \
        -F "password=" \
        "$UPLOADURL$FORM_ACTION") || return

    MON_PL=$(cat "$HEADERS" | grep_http_header_location) || return
    rm -f "$HEADERS"

    log_debug "Monitoring page: $MON_PL"

    WAIT_TIME=5
    while [ $WAIT_TIME -lt 320 ] ; do
        PAGE=$(curl "$MON_PL") || return

        if match 'En attente de traitement...' "$PAGE"; then
            log_debug "please wait"
            ((WAIT_TIME += 4))
        elif match 'Test antivirus...' "$PAGE"; then
            log_debug "antivirus test"
            WAIT_TIME=3
        elif match 'Mise en ligne du fichier...' "$PAGE"; then
            log_debug "nearly online!"
            WAIT_TIME=2
        elif match 'Erreur de traitement...' "$PAGE"; then
            log_error "process failed, you may try again"
            break
        # Fichier "foo" en ligne, proc�dure termin�e avec succ�s...
        elif match 'Le fichier sera accessible' "$PAGE"; then
            DL_URL=$(echo "$PAGE" | parse 'en ligne' \
                "window\.open('\(http://dl.free.fr/[^?]*\)')" | html_to_utf8)
            DEL_URL=$(echo "$PAGE" | parse 'en ligne' \
                "window\.open('\(http://dl.free.fr/rm\.pl[^']*\)" | html_to_utf8)

            echo "$DL_URL"
            echo "$DEL_URL"
            return 0
        else
            log_error "unknown state, abort"
            break
        fi

        wait $WAIT_TIME seconds
    done
    return $ERR_FATAL
}

# Delete a file from dl.free.fr
# $1: cookie file (unused here)
# $2: dl.free.fr (delete) link
dl_free_fr_delete() {
    local URL=$2
    local -r BASE_URL='http://dl.free.fr'
    local PAGE

    PAGE=$(curl "$URL") || return

    # Fichier perim� ou d�j� supprim�
    match 'Fichier perim&eacute ou d&eacute;j&agrave; supprim&eacute;' \
        "$PAGE" && return $ERR_LINK_DEAD

    # Si vous souhaitez r�element supprimer le fichier nomm� [<FILE_NAME>] cliquez ici
    if match 'Si vous souhaitez r&eacute;element supprimer' "$PAGE"; then
        URL=$(echo "$PAGE" | parse_attr 'Si vous souhaitez' 'href') || return
        PAGE=$(curl "$BASE_URL$URL") || return

        # Le fichier nomm� [<FILE_NAME>] a �t� supprim� avec succ�s.
        match 'supprim&eacute; avec succ&egrave;s' "$PAGE" && return 0
    fi

    log_error 'Unexpected content. Site updated?'
    return $ERR_FATAL
}
