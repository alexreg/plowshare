#!/usr/bin/env bash
#
# Delete files from file sharing websites
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

declare -r VERSION='GIT-snapshot'

declare -r EARLY_OPTIONS="
HELP,h,help,,Show help info
GETVERSION,,version,,Return plowdel version
NO_PLOWSHARERC,,no-plowsharerc,,Do not use plowshare.conf config file"

declare -r MAIN_OPTIONS="
VERBOSE,v,verbose,V=LEVEL,Set output verbose level: 0=none, 1=err, 2=notice (default), 3=dbg, 4=report
QUIET,q,quiet,,Alias for -v0
INTERFACE,i,interface,s=IFACE,Force IFACE network interface"


# This function is duplicated from download.sh
absolute_path() {
    local SAVED_PWD=$PWD
    local TARGET=$1

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

# Print usage (on stdout)
# Note: $MODULES is a multi-line list
usage() {
    echo 'Usage: plowdel [OPTIONS] [MODULE_OPTIONS] URL...'
    echo
    echo '  Delete a file-link from a file sharing site.'
    echo '  Available modules:' $MODULES
    echo
    echo 'Global options:'
    echo
    print_options "$EARLY_OPTIONS$MAIN_OPTIONS"
    print_module_options "$MODULES" DELETE
}

#
# Main
#

# Get library directory
LIBDIR=$(absolute_path "$0")

set -e # enable exit checking

source "$LIBDIR/core.sh"
MODULES=$(grep_list_modules 'delete') || exit
for MODULE in $MODULES; do
    source "$LIBDIR/modules/$MODULE.sh"
done

# Process command-line (plowdel early options)
eval "$(process_core_options 'plowdel' "$EARLY_OPTIONS" "$@")" || exit

test "$HELP" && { usage; exit 0; }
test "$GETVERSION" && { echo "$VERSION"; exit 0; }

# Get configuration file options. Command-line is partially parsed.
test -z "$NO_PLOWSHARERC" && \
    process_configfile_options '[Pp]lowdel' "$MAIN_OPTIONS"

declare -a COMMAND_LINE_MODULE_OPTS COMMAND_LINE_ARGS RETVALS
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}")

# Process command-line (plowdel options).
# Note: Ignore returned UNUSED_ARGS[@], it will be empty.
eval "$(process_core_options 'plowdel' "$MAIN_OPTIONS" "${UNUSED_OPTS[@]}")" || exit

# Verify verbose level
if [ -n "$QUIET" ]; then
    declare -r VERBOSE=0
elif [ -z "$VERBOSE" ]; then
    declare -r VERBOSE=2
fi

if [ $# -lt 1 ]; then
    log_error "plowdel: no URL specified!"
    log_error "plowdel: try \`plowdel --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

MODULE_OPTIONS=$(get_all_modules_options "$MODULES" DELETE)

# Process command-line (all module options)
eval "$(process_all_modules_options 'plowdel' "$MODULE_OPTIONS" \
    "${UNUSED_OPTS[@]}")" || exit

# Prepend here to keep command-line order
COMMAND_LINE_ARGS=("${UNUSED_ARGS[@]}" "${COMMAND_LINE_ARGS[@]}")
COMMAND_LINE_MODULE_OPTS=("${UNUSED_OPTS[@]}")

if [ ${#COMMAND_LINE_ARGS[@]} -eq 0 ]; then
    log_error "plowdel: no URL specified!"
    log_error "plowdel: try \`plowdel --help' for more information."
    exit $ERR_BAD_COMMAND_LINE
fi

# Sanity check
for MOD in $MODULES; do
    if ! declare -f "${MOD}_delete" > /dev/null; then
        log_error "plowdel: module \`${MOD}_delete' function was not found"
        exit $ERR_BAD_COMMAND_LINE
    fi
done

set_exit_trap

DCOOKIE=$(create_tempfile) || exit

for URL in "${COMMAND_LINE_ARGS[@]}"; do
    DRETVAL=0

    MODULE=$(get_module "$URL" "$MODULES") || DRETVAL=$?
    if [ $DRETVAL -ne 0 ]; then
        if ! match_remote_url "$URL"; then
            log_error "Skip: not an URL ($URL)"
        else
            log_error "Skip: no module for URL ($(basename_url "$URL")/)"
        fi
        RETVALS=(${RETVALS[@]} $DRETVAL)
        continue
    fi

    # Get configuration file module options
    test -z "$NO_PLOWSHARERC" && \
        process_configfile_module_options '[Pp]lowdel' "$MODULE" DELETE

    eval "$(process_module_options "$MODULE" DELETE \
        "${COMMAND_LINE_MODULE_OPTS[@]}")" || true

    FUNCTION=${MODULE}_delete
    log_notice "Starting delete ($MODULE): $URL"

    :> "$DCOOKIE"

    ${MODULE}_vars_set
    $FUNCTION "${UNUSED_OPTIONS[@]}" "$DCOOKIE" "$URL" || DRETVAL=$?
    ${MODULE}_vars_unset

    if [ $DRETVAL -eq 0 ]; then
        log_notice "File removed successfully"
    elif [ $DRETVAL -eq $ERR_LINK_NEED_PERMISSIONS ]; then
        log_error "Anonymous users cannot delete links"
    elif [ $DRETVAL -eq $ERR_LINK_DEAD ]; then
        log_error "Not found or already deleted"
    elif [ $DRETVAL -eq $ERR_LOGIN_FAILED ]; then
        log_error "Login process failed. Bad username/password or unexpected content"
    else
        log_error "Failed inside ${FUNCTION}() [$DRETVAL]"
    fi
    RETVALS=(${RETVALS[@]} $DRETVAL)
done

rm -f "$DCOOKIE"

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
