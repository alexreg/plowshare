#!/bin/bash
#
# 1fichier.com module
# Copyright (c) 2011 halfman <Pulpan3@gmail.com>
# Copyright (c) 2012-2013 Plowshare team
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

MODULE_1FICHIER_REGEXP_URL="http://\(.*\.\)\?\(1fichier\.\(com\|net\|org\|fr\)\|alterupload\.com\|cjoint\.\(net\|org\)\|desfichiers\.\(com\|net\|org\|fr\)\|dfichiers\.\(com\|net\|org\|fr\)\|megadl\.fr\|mesfichiers\.\(net\|org\)\|piecejointe\.\(net\|org\)\|pjointe\.\(com\|net\|org\|fr\)\|tenvoi\.\(com\|net\|org\)\|dl4free\.com\)"

MODULE_1FICHIER_DOWNLOAD_OPTIONS="
LINK_PASSWORD,p,link-password,S=PASSWORD,Used in password-protected files"
MODULE_1FICHIER_DOWNLOAD_RESUME=yes
MODULE_1FICHIER_DOWNLOAD_FINAL_LINK_NEEDS_COOKIE=no
MODULE_1FICHIER_DOWNLOAD_SUCCESSIVE_INTERVAL=300

MODULE_1FICHIER_UPLOAD_OPTIONS="
AUTH,a,auth,a=USER:PASSWORD,User account
LINK_PASSWORD,p,link-password,S=PASSWORD,Protect a link with a password
MESSAGE,d,message,S=MESSAGE,Set file message (is send with notification email)
DOMAIN,,domain,N=ID,You can set domain ID to upload (ID can be found at http://www.1fichier.com/en/api/web.html)
TOEMAIL,,email-to,e=EMAIL,<To> field for notification email"
MODULE_1FICHIER_UPLOAD_REMOTE_SUPPORT=no

MODULE_1FICHIER_DELETE_OPTIONS=""
MODULE_1FICHIER_LIST_OPTIONS=""
MODULE_1FICHIER_PROBE_OPTIONS=""

# Output a 1fichier file download URL
# $1: cookie file (unused here)
# $2: 1fichier.tld url
# stdout: real file download link
#
# Note: Consecutive HTTP requests must be delayed (>10s).
#       Otherwise you'll get the parallel download message.
1fichier_download() {
    local -r URL=$2
    local PAGE FILE_URL FILE_NAME REDIR

    PAGE=$(curl "$URL") || return

    # Location: http://www.1fichier.com/?c=SCAN
    if match 'MOVED - TEMPORARY_REDIRECT' "$PAGE"; then
        return $ERR_LINK_TEMP_UNAVAILABLE
    elif match "Le fichier demandé n'existe pas.\|file has been deleted" "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    # notice typo in 'telechargement'
    if match 'entre 2 télécharger\?ments' "$PAGE"; then
        log_error 'No parallel download allowed.'
        return $ERR_LINK_TEMP_UNAVAILABLE

    # Please wait until the file has been scanned by our anti-virus
    elif match 'Please wait until the file has been scanned' "$PAGE"; then
        log_error 'File is scanned for viruses.'
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FILE_NAME=$(echo "$PAGE" | parse_tag_quiet 'Nom du fichier' td)

    if match 'name="pass"' "$PAGE"; then
        if [ -z "$LINK_PASSWORD" ]; then
            LINK_PASSWORD=$(prompt_for_password) || return
        fi

        FILE_URL=$(curl -i -F "pass=$LINK_PASSWORD" "$URL" | \
            grep_http_header_location_quiet) || return

        test "$FILE_URL" || return $ERR_LINK_PASSWORD_REQUIRED

        echo "$FILE_URL"
        echo "$FILE_NAME"
        return 0
    fi

    PAGE=$(curl --include -d 'a=1' "$URL") || return

    # Attention ! En t�l�chargement standard, vous ne pouvez t�l�charger qu'un seul fichier
    # � la fois et vous devez attendre jusqu'� 5 minutes entre chaque t�l�chargement.
    if match 'vous devez attendre .* 5 minutes' "$PAGE"; then
        log_error 'Forced delay between downloads.'
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    FILE_URL=$(echo "$PAGE" | grep_http_header_location_quiet)

    # Note: Some files only show up as unavailable at this point :-/
    PAGE=$(curl --head "$FILE_URL") || return
    REDIR=$(echo "$PAGE" | grep_http_header_location_quiet)

    if [[ "$REDIR" = *FILENOTFOUND474 ]]; then
        return $ERR_LINK_DEAD
    fi

    test "$CHECK_LINK" && return 0

    if [ -z "$FILE_URL" ]; then
        echo 300
        return $ERR_LINK_TEMP_UNAVAILABLE
    fi

    echo "$FILE_URL"
    echo "$FILE_NAME"
}

# Upload a file to 1fichier.tld
# $1: cookie file
# $2: input file (with full path)
# $3: remote filename
# stdout: download + del link
1fichier_upload() {
    local COOKIEFILE=$1
    local FILE=$2
    local DESTFILE=$3
    local UPLOADURL='http://upload.1fichier.com'
    local LOGIN_DATA S_ID RESPONSE DOWNLOAD_ID REMOVE_ID DOMAIN_ID

    if test "$AUTH"; then
        LOGIN_DATA='mail=$USER&pass=$PASSWORD&submit=Login'
        post_login "$AUTH" "$COOKIEFILE" "$LOGIN_DATA" "https://www.1fichier.com/en/login.pl" >/dev/null || return
    fi

    # Initial js code:
    # var text = ''; var possible = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    # for(var i=0; i<5; i++) text += possible.charAt(Math.floor(Math.random() * possible.length)); print(text);
    S_ID=$(random ll 5)

    RESPONSE=$(curl_with_log -b "$COOKIEFILE" \
        --form-string "message=$MESSAGE" \
        --form-string "mail=$TOEMAIL" \
        -F "dpass=$LINK_PASSWORD" \
        -F "domain=${DOMAIN:-0}" \
        -F "file[]=@$FILE;filename=$DESTFILE" \
        "$UPLOADURL/upload.cgi?id=$S_ID") || return

    RESPONSE=$(curl --header "EXPORT:1" "$UPLOADURL/end.pl?xid=$S_ID" | sed -e 's/;/\n/g')

    DOWNLOAD_ID=$(echo "$RESPONSE" | nth_line 3)
    REMOVE_ID=$(echo "$RESPONSE" | nth_line 4)
    DOMAIN_ID=$(echo "$RESPONSE" | nth_line 5)

    local -a DOMAIN_STR=('1fichier.com' 'alterupload.com' 'cjoint.net' 'desfichiers.com' \
        'dfichiers.com' 'megadl.fr' 'mesfichiers.net' 'piecejointe.net' 'pjointe.com' \
        'tenvoi.com' 'dl4free.com' )

    if [[ $DOMAIN_ID -gt 10 || $DOMAIN_ID -lt 0 ]]; then
        log_error 'Bad domain ID response, maybe API updated?'
        return $ERR_FATAL
    fi

    echo "http://${DOWNLOAD_ID}.${DOMAIN_STR[$DOMAIN_ID]}"
    echo "http://www.${DOMAIN_STR[$DOMAIN_ID]}/remove/$DOWNLOAD_ID/$REMOVE_ID"
}

# Delete a file uploaded to 1fichier
# $1: cookie file (unused here)
# $2: delete url
1fichier_delete() {
    local URL=$2
    local PAGE

    if match '/bg/remove/' "$URL"; then
        URL=$(echo "$URL" | replace '/bg/' '/en/')
    elif ! match '/en/remove/' "$URL"; then
        URL=$(echo "$URL" | replace '/remove/' '/en/remove/')
    fi

    PAGE=$(curl "$URL") || return

    # Invalid link - File not found
    if match 'File not found' "$PAGE"; then
        return $ERR_LINK_DEAD
    fi

    PAGE=$(curl "$URL" -F "force=1") || return

    # <div style="width:250px;margin:25px;padding:25px">The file has been destroyed</div>
    if ! match 'file has been' "$PAGE"; then
        log_debug 'unexpected result, site updated?'
        return $ERR_FATAL
    fi
}

# List a 1fichier folder
# $1: 1fichier folder link
# $2: recurse subfolders (null string means not selected)
# stdout: list of links
1fichier_list() {
    local URL=$1
    local PAGE LINKS NAMES

    if ! match '/dir/' "$URL"; then
        log_error 'This is not a directory list'
        return $ERR_FATAL
    fi

    test "$2" && log_debug 'recursive folder does not exist in 1fichier.com'

    if match '/../dir/' "$URL"; then
        local BASE_URL DIR_ID
        BASE_URL=$(basename_url "$URL")
        DIR_ID=${URL##*/}
        URL="$BASE_URL/dir/$DIR_ID"
    fi

    PAGE=$(curl -L "$URL") || return
    LINKS=$(echo "$PAGE" | parse_all_attr_quiet 'T.l.chargement de' href)
    NAMES=$(echo "$PAGE" | parse_all_tag_quiet 'T.l.chargement de' a)

    test "$LINKS" || return $ERR_LINK_DEAD

    list_submit "$LINKS" "$NAMES" || return
}

# Probe a download URL
# $1: cookie file (unused here)
# $2: 1fichier url
# $3: requested capability list
1fichier_probe() {
    local URL=${2%/}
    local -r REQ_IN=$3
    local FID RESPONSE FILE_NAME FILE_SIZE

    # Try to get a "strict" url
    FID=$(echo "$URL" | parse_quiet . '://\([[:alnum:]]*\)\.')
    [ -n "$FID" ] && URL="http://$FID.1fichier.com"

    RESPONSE=$(curl --form-string "links[]=$URL" \
        'https://www.1fichier.com/check_links.pl') || return

    # Note: Password protected links return NOT FOUND
    if match '\(NOT FOUND\|BAD LINK\)$' "$RESPONSE"; then
        return $ERR_LINK_DEAD
    fi

    # url;filename;filesize
    IFS=';' read URL FILE_NAME FILE_SIZE <<< "$RESPONSE"

    REQ_OUT=c

    if [[ $REQ_IN = *f* ]]; then
        echo "$FILE_NAME"
        REQ_OUT="${REQ_OUT}f"
    fi

    if [[ $REQ_IN = *s* ]]; then
        echo "$FILE_SIZE"
        REQ_OUT="${REQ_OUT}s"
    fi

    echo $REQ_OUT
}
