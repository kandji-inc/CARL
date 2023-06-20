#!/bin/zsh
# Created 06/01/22; NRJA
# Updated 08/15/22; NRJA
# Updated 06/02/23; NRJA
# Updated 06/13/23; NRJA
################################################################################################
# License Information
################################################################################################
#
# Copyright 2023 Kandji, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify, merge,
# publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
# to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or
# substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
# PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
# FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
################################################################################################

##############################
########## VARIABLES #########
##############################

##############################################
# PATH TO AUTOPKG RECIPES — SET BY ENV
##############################################
autopkg_recipes_dir="/tmp/${RECIPES_DIR_NAME}"

# Get directory of script execution
dir=$(dirname $ZSH_ARGZERO)

# AutoPkg download/shasum variables
autopkg_latest_url="https://api.github.com/repos/autopkg/autopkg/releases/latest"
autopkg_pinned_pkg="https://github.com/autopkg/autopkg/releases/download/v2.7.2/autopkg-2.7.2.pkg"
autopkg_pinned_shasum="2ff34daf02256ad81e2c74c83a9f4c312fa2f9dd212aba59e0cef0e6ba1be5c9"
autopkg_temp_dl="/tmp/autopkg.pkg"

# Machine info for stdout header
serial_no=$(/usr/sbin/ioreg -c IOPlatformExpertDevice -d 2 | awk -F\" '/IOPlatformSerialNumber/{print $(NF-1)}')
comp_name=$(/usr/sbin/scutil --get ComputerName)
ip_addy=$(/sbin/ifconfig | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p' | xargs)
joint_identifier="${serial_no}/${comp_name}/${ip_addy}"

# Populate logged in username
console_user=$(/usr/bin/stat -f%Su /dev/console)

# Source our Slack notification function
source "${dir}/slack_notify.zsh"

##############################
########## FUNCTIONS #########
##############################

##############################################
# Identifies and DLs latest release of AutoPkg
# Validates shasum from known good value
# If shasums differ, DLs pinned version
# Will Slack notify about newer version
# Globals:
#   slack_notify
# Outputs:
#   Installs AutoPkg to disk
# Returns:
#   Success, else exit 1 and notify on error
##############################################
function autopkg_dl_install() {
    # Grab latest release of AutoPkg
    autopkg_pkg_dl=$(/usr/bin/curl -s -L "${autopkg_latest_url}" | /usr/bin/sed -n -e 's/^.*"browser_download_url": //p' |  /usr/bin/tr -d \")

    # Download it - retry up to 3 more times if it fails
    /usr/bin/curl -s -L --retry 3 "${autopkg_pkg_dl}" -o "${autopkg_temp_dl}"

    # Check that shasum matches latest
    # Could hardcode our pinned version, but want to be alerted for new versions
    if [[ ! $(/usr/bin/shasum -a 256 "${autopkg_temp_dl}" 2>/dev/null  | /usr/bin/awk '{print $1}') == ${autopkg_pinned_shasum} ]]; then
        slack_notify --status "NOTICE" --title "Shasum mismatch for AutoPkg download" --text "Attempted download from ${autopkg_pkg_dl}; may be a newer version?\nDownloading AutoPkg from pinned URL ${autopkg_pinned_pkg}"

        # If we have a shasum mismatch, try downloading the known good package of our pinned version
        autopkg_pkg_dl=${autopkg_pinned_pkg}
        /bin/rm "${autopkg_temp_dl}"
        /usr/bin/curl -L "${autopkg_pkg_dl}" -o "${autopkg_temp_dl}"

        # Confirm shasum of pinned value
        if [[ ! $(/usr/bin/shasum -a 256 "${autopkg_temp_dl}" 2>/dev/null  | /usr/bin/awk '{print $1}') == ${autopkg_pinned_shasum} ]]; then
            echo "$(date +'%r') : ${joint_identifier}: CRITICAL: Shasum mismatch for AutoPkg download\nAttempted download from ${autopkg_pinned_pkg}, but shasum check failed!"
            slack_notify --status "CRITICAL" --title "Shasum mismatch for AutoPkg download" --text "Attempted download from ${autopkg_pinned_pkg}, but shasum check failed!"
            exit 1
        fi
    fi

    echo "$(date +'%r') : ${joint_identifier}: AutoPkg download complete — beginning install..."

    # Install core AutoPkg
    /usr/sbin/installer -pkg "${autopkg_temp_dl}" -target / 2>/dev/null

    # Validate success
    exit_code=$?

    if [[ "${exit_code}" == 0 ]]; then
        echo "$(date +'%r') : ${joint_identifier}: Successfully installed AutoPkg from core project"
    else
        slack_notify --status "ERROR" --title "AutoPkg Runner Failure" --text "AutoPkg install failed with error code ${exit_code}" --host_info "yes"
        exit 1
    fi

    # Remove temp DL
    /bin/rm "${autopkg_temp_dl}"
}


##############################################
# DL + install Rosetta 2 if needed for system
# Globals:
#   slack_notify
# Outputs:
#   Installs Rosetta 2 on disk
# Returns:
#   Success, else exit 1 and notify on error
##############################################
function rosetta_install() {
    # If needed, install Rosetta on Apple silicon arch
    /usr/sbin/softwareupdate --install-rosetta --agree-to-license 1>/dev/null

    # Validate success
    exit_code=$?

    if [[ "${exit_code}" == 0 ]]; then
        echo "$(date +'%r') : ${joint_identifier}: Successfully installed Rosetta 2 on Apple silicon hardware"
    else
        slack_notify --status "ERROR" --title "AutoPkg Runner Failure" --text "Rosetta 2 install failed on Apple silicon HW with error code ${exit_code}" --host_info "yes"
        exit 1
    fi
}

##############################################
# Configures AutoPkg config changes ownership
# to logged-in user; pip installs requests
# Globals:
#   slack_notify
# Outputs:
#   Installs Python requests
# Returns:
#   Success, else exit 1 and notify on error
##############################################
function custom_autopkg_config() {

    echo "$(date +'%r') : ${joint_identifier}: Customizing AutoPkg config..."

    # Add our Git recipe directory to AutoPkg's search paths
    /usr/bin/defaults write "/Users/${console_user}/Library/Preferences/com.github.autopkg.plist" RECIPE_SEARCH_DIRS "${autopkg_recipes_dir}"

    # Make everything AutoPkg owned by the logged in user
    /usr/sbin/chown "${console_user}:staff" "/Users/${console_user}/Library/Preferences/com.github.autopkg.plist"
    /usr/sbin/chown -R "${console_user}:staff" "${autopkg_recipes_dir}"

    # Install requests with our AutoPkg Python
    # Running pip as root returns expected stderr, so supress out and check for return code
    /usr/local/autopkg/python -m pip install requests >/dev/null 2>&1
    exit_code=$?

    if [[ "${exit_code}" == 0 ]]; then
        echo "$(date +'%r') : ${joint_identifier}: Successfully installed AutoPkg Python dependencies"
    else
        slack_notify --status "ERROR" --title "AutoPkg Runner Failure" --text "AutoPkg Python dependencies failed to install with error code ${exit_code}" --host_info "yes"
        exit 1
    fi
}

##############################################
# Main run with logic checks for function exec
##############################################
function main() {

    if ! /usr/local/bin/autopkg version >/dev/null 2>&1; then
        echo "$(date +'%r') : ${joint_identifier}: No AutoPkg found — beginning download..."
        autopkg_dl_install
    fi

    if [[ ! $(/usr/sbin/sysctl -n machdep.cpu.brand_string | /usr/bin/grep -oi "Intel") ]] && [[ ! $(/usr/bin/pgrep oahd) ]]; then
        echo "$(date +'%r') : ${joint_identifier}: Hardware type is not Intel and Rosetta 2 was not detected... installing."
        rosetta_install
    fi

    custom_autopkg_config
}

###############
##### MAIN ####
###############

main
