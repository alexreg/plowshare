#!/bin/bash
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

MODULE_DATA_HU_REGEXP_URL="http://\(www\.\)\?data.hu/get/"
MODULE_DATA_HU_DOWNLOAD_OPTIONS=
MODULE_DATA_HU_UPLOAD_OPTIONS=
MODULE_DATA_HU_DOWNLOAD_CONTINUE=yes

# Output a data_hu file download URL
#
# $1: A data_hu URL
#
data_hu_download() {
    eval "$(process_options data_hu "$MODULE_DATA_HU_DOWNLOAD_OPTIONS" "$@")"
    URL=$1

    PAGE=$(curl -L "$URL") || return 1
    match "/missing.php" "$PAGE" &&
        { log_debug "file not found"; return 254; }
    FILE_URL=$(echo "$PAGE" | parse_attr "download_it" "href") ||
      { log_error "download link not found"; return 1; }
    test "$CHECK_LINK" && return 255

    echo $FILE_URL
}
