#!/bin/zsh

################################################################################################
# Created by Daniel Chapa | support@kandji.io | Kandji, Inc. | Systems Engineering
# Updated by Noah Anderson | support@kandji.io | Kandji, Inc. | Systems Engineering
################################################################################################
# Created on 09/14/2022
# Updated on 09/14/2022
# Updated 06/09/23; NRJA
################################################################################################
# Software Information
################################################################################################
# This checks for an existing install, installs the latest version of Veertu Anka Develop,
# and offers to spin up and clone a new VM image if none are found.
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

#############################
######### ARGUMENTS #########
#############################

# Set arguments with zparseopts
zparseopts -D -E -a opts h -help c -cloneonly v -verbose

# shellcheck disable=SC2154
# Set args for verbosity
if (( ${opts[(I)(-v|--verbose)]} )); then
    set -x
fi

# If clone only set, clone VM in user context (no sudo) then exit
if (( ${opts[(I)(-c|--cloneonly)]} )); then
    clone_only=true
else
    clone_only=false
fi

# Set args for help
if (( ${opts[(I)(-h|--help)]} )); then
    echo "Usage: sudo ./anka_install_create_clone.zsh [--help|--cloneonly|--verbose] [arguments...]"
    echo
    echo "Checks for, and if not found, downloads and installs Anka and activates Develop license"
    echo "Checks for any current VMs and offers to download latest macOS and immediately clone + start it"
    exit 0
fi

##############################
########## VARIABLES #########
##############################

#----- Download URL
ANKA_DOWNLOAD_URL="https://veertu.com/downloads/anka-virtualization-arm"

#----- Installer
ANKA_INSTALLER="/tmp/anka-installer.pkg"

#----- Developer Team ID for vendor
VEERTU_ID="TT9FAWP6V4"

console_user=$(/usr/bin/stat -f%Su /dev/console)


##############################
########## FUNCTIONS #########
##############################

##############################################
# Validates user is running script with
# appropriate permissions (sudo or root)
##############################################
function prechecks() {
    if [[ ${clone_only} == true ]]; then
        vm_clone_start
        exit 0
    fi

    if [[ "${EUID}" -ne 0 ]]; then
        echo "Installation script must be run with sudo or as root"
        exit 1
    fi
}

##############################################
# Conditional check for Anka binary exec
# Returns:
#   0 if anka version succeeds, 1 on error.
##############################################
function is_anka_installed() {

    # Confirm Anka binary is present and returns version
    if anka version >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

##############################################
# Conditional check for Anka license
# Returns:
#   0 if license show succeeds, 1 on error.
##############################################
function check_anka_license() {

    # Confirm Anka license is active
    if anka license show >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

##############################################
# Checks if Anka is instaled, downloading
# installer if not. Validates code signature
# on PKG and then installs once confirmed.
# Arguments:
#   Arguments taken (e.g. "${1}")
# Outputs:
#   Installs Anka on-disk
# Returns:
#   Exit 1 on PKG signature verification error
##############################################
function download_validate_install() {

    if ! is_anka_installed; then

        # Download
        echo "\n\nAnka binary not found; downloading installer..."
        /usr/bin/curl -s -S -L "${ANKA_DOWNLOAD_URL}" -o "${ANKA_INSTALLER}"

        # Validate Package
        # First sed filters to the line, second returns value between (...)
        pkg_id=$(/usr/sbin/pkgutil --check-signature "${ANKA_INSTALLER}" | sed -n -e 's/^.*Developer ID Installer: //p' | sed -e 's/.*(\(.*\)).*/\1/;s/,//g')

        if [[ "${pkg_id}" != "${VEERTU_ID}" ]]; then
            echo "ERROR: PKG signature check failure!"
            echo "Expected Team ID was ${VEERTU_ID}; got ${pkg_id}"
            exit 1
        fi

        # Install
        sudo /usr/sbin/installer -pkg "${ANKA_INSTALLER}" -target /
    else
        echo "Anka binary already present"
    fi
}

# Detects current runtime of script and will run any user commands without invoking sudo
function run_as_user() {

    if [[ "${EUID}" -eq 0 ]]; then
        # Eval is clearly not best practice, but fine for where we provide the cmds
        su - "${console_user}" -c "eval ${1}"
    else
        eval ${1}
    fi
}


##############################################
# Confirms Anka installed as expected, then
# checks for licensing and accepts if inactive
# Outputs:
#   Activates Anka license
# Returns:
#   Exit 1 on install or license failure
##############################################
function activate_anka() {

    if is_anka_installed; then
        echo "Anka install present"
    else
        echo "ERROR: Anka install failed! Check /var/log/install.log for details"
        exit 1
    fi

    if ! check_anka_license; then
        # Accept Licensing
        echo "Activating license..."
        sudo anka license accept-eula || true
    fi

    # Validate Licensing
    if check_anka_license; then
        echo "Anka license active"
    else
        echo "ERROR: Anka license was not activated!"
        exit 1
    fi
}

##############################################
# If no Anka VMs are found under the user env,
# searches for the latest macOS and offers to
# download and use it to create a new Anka VM
# Outputs:
#   Creates new Anka VM running latest macOS
# Returns:
#   Exit 0 if user elects not to create a VM
##############################################
function offer_create_new_vm() {

    vm_count=$(run_as_user "anka -j list | plutil -extract body raw -o - -")

    if [[ ${vm_count} -lt 1 ]]; then
        # shellcheck disable=SC2051
        # bash doesn't support variables in brace range expansions, but zsh does
        for i in {0..$(anka -j create --list | plutil -extract body raw -o - -)}; do
            if anka -j create --list | plutil -extract body.${i}.latest raw -o - - >/dev/null 2>&1; then
                latest_macos=$(anka -j create --list | plutil -extract body.${i}.version raw -o - -)
                break
            fi
        done

        if read -q "?No Anka VM found for user ${console_user}! Create new VM running macOS ${latest_macos}? (Y/N): "; then
            anka_vm_name="anka_vm_${latest_macos}"
            # Create new VM downloading from latest macOS
            run_as_user "anka create ${anka_vm_name} latest"
        else
            echo "\nExiting..."
            exit 0
        fi
    fi
}

##############################################
# Counts the number of Anka VMs under the user
# env — if only one found, clones and starts
# it. If existing VM found with _CLONE name,
# offers to delete/recreate, else starts VM
# Outputs:
#   Creates VM clone and starts it
##############################################
function vm_clone_start() {

    vm_name_count=$(run_as_user "anka -j list -s -f name" | plutil -extract body raw -o - -)

    declare -a all_vms

    if [[ ${vm_name_count} -lt 1 ]]; then
        offer_create_new_vm
        vm_clone_start
    elif [[ ${vm_name_count} -gt 1 ]]; then
        all_vms=($(run_as_user "anka list -s -f name"  | grep '[[:alnum:]]' | sed 's/|//g' | tail -n +2 ))
        ps3_text=$(echo "Found more than one VM to clone! Type number and hit return to select VM from above\n: ")
        PS3=${ps3_text}
        select VM_NAME in "${all_vms[@]}"; do
            [[ -n ${VM_NAME} ]] || { echo "\nImproper selection! Please type number (e.g. 2) and hit return\n" >&2; continue; }
            vm_to_clone=${VM_NAME}
            break
        done
    else
        vm_to_clone=$(run_as_user "anka -j list -s -f name" | plutil -extract body.0.name raw -o - -)
    fi

    clone_name="${vm_to_clone}_CLONE"

    if run_as_user "anka list -f name | grep -o ${clone_name}" 2>/dev/null; then
        if read -q "?Found existing VM ${clone_name}! Delete and recreate before starting? (Y/N): "; then
            run_as_user "anka stop ${clone_name}" 2>/dev/null
            run_as_user "anka delete --yes ${clone_name}" 2>/dev/null
            run_as_user "anka clone ${vm_to_clone} ${clone_name}" || echo "ERROR: Unable to clone VM; see output for error"
            run_as_user "anka start -v ${clone_name}" 2>/dev/null
        else
            echo "Starting ${clone_name}..."
            run_as_user "anka start -v ${clone_name}" 2>/dev/null
        fi
    else
        echo "Cloning and starting new Anka VM ${clone_name}"
        run_as_user "anka clone ${vm_to_clone} ${clone_name}" || echo "ERROR: Unable to clone VM; see output for error"
        run_as_user "anka start -v ${clone_name}" 2>/dev/null
    fi
}

##############################################
# Deletes Anka installer from /tmp
##############################################
function cleanup() {

    # Cleanup
    echo "Cleaning up..."
    /bin/rm -f "${ANKA_INSTALLER}"
}

##=============================================================
## Script Run
##=============================================================
function main() {

    prechecks

    download_validate_install

    activate_anka

    offer_create_new_vm

    vm_clone_start

    cleanup
}

###############
##### MAIN ####
###############

main
