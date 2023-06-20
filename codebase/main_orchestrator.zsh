#!/bin/zsh
# Created 06/21/22; NRJA
# Updated 10/05/22; NRJA
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

#############################
######### ARGUMENTS #########
#############################

# Set arguments with zparseopts
zparseopts -D -E -a opts h -help p -prechecks v -verbose

# shellcheck disable=SC2154
# Set args for verbosity
if (( ${opts[(I)(-v|--verbose)]} )); then
    set -x
fi

# Set args for help
if (( ${opts[(I)(-h|--help)]} )); then
    echo "Usage: ./main_orchestrator.zsh [--help|--prechecks|--verbose] [arguments...]"
    echo
    echo "Spins up a Docker container, instantiates, and connects to an Anka VM runner"
    echo "Clones, installs, and executes AutoPkg runners for selected recipes"
    exit 0
fi

#############################
######### VARIABLES #########
#############################

# Get script name
script_exec=$(basename $ZSH_ARGZERO)
# Get directory of script execution
dir=$(dirname $ZSH_ARGZERO)
# Absolute path of script exec dir
abs_dir=$(realpath "${dir}")
# Absolute path of script exec dir parent
parent_abs_dir=$(dirname "${abs_dir}")

# Path definition for SSH keypair
key_dir="/tmp/anka_vm"

# Remote username for VM
remote_user="anka"
# Remote password for VM
# PW available on vendor website, so not privileged
remote_pass="admin"

# Define SSH key name (both private + public)
ssh_key="${remote_user}_vm"
public_key="${ssh_key}.pub"

# File written to disk for installing public SSH key
public_key_exec="/tmp/public_key_exec.zsh"

# JSON filename with recipe names
recipes_to_run="recipe_list.json"

# Remote files/dirs written to be scp'd back to host
remote_metadata_json="/tmp/autopkg_metadata.json"
remote_cache_dir="/Users/${remote_user}/Library/AutoPkg/Cache"
remote_report_plist="/tmp/combined_autopkg_results.plist"

# If running locally on macOS, prepare the results and attach timestamp
if [[ $(uname) == "Darwin" ]]; then
    mkdir -p "${parent_abs_dir}/autopkg-runner-results"
    local_upload_report="${parent_abs_dir}/autopkg-runner-results/autopkg_full_results_$(date +%Y-%m-%d_%H%M%S).plist"
else
    # Docker takes care of this for us at the end
    local_upload_report="${parent_abs_dir}/autopkg_full_results.plist"
fi

# Local files copied over to or back from remote VM
local_upload_metadata="${parent_abs_dir}/autopkg_metadata.json"
local_save_metadata="${parent_abs_dir}/last_autopkg_metadata.json"

# Set as array because could also auth through token or SSH key in ENV
declare -a env_vars
# Populate ENV vars used on remote Mac
env_vars=(
    SLACK_WEBHOOK_TOKEN
    RECIPES_DIR_NAME
)

# Set vars with absolute paths of files/folders
helpers_abs_path=$(find "${abs_dir}" -name "helpers")
apkg_tools_abs_path=$(find "${abs_dir}" -name "autopkg_tools.py")
recipe_list_abs_path=$(find "${parent_abs_dir}" -name "recipe_list.json")
running_vms_abs_path=$(find "${parent_abs_dir}" -name "running_vms.json")
# If the below isn't populated, we'll catch that error during prechecks
recipes_abs_path=$(find "${parent_abs_dir}" -name "${RECIPES_DIR_NAME}")

# Concatenate env vars with SendEnv SSH options
ssh_env_flags=$(printf -- '-o SendEnv="%s" ' "${env_vars[@]}" | sed -e "s/ *$//")

# Import our Slack notification code/function
source "${dir}/helpers/slack_notify.zsh"

##############################
########## FUNCTIONS #########
##############################


##############################################
# Checks under the user context if an Anka VM
# is currently active and running
# Returns:
#   1 if no running Anka VM found
##############################################
function is_vm_running() {

    if [[ -z $(anka list -r 2>/dev/null) ]]; then
        echo "$(date +'%r') : ${script_exec}: WARNING: No running Anka VMs found!"
        echo "$(date +'%r') : ${script_exec}: Run sudo ./anka_install_create_clone.zsh to clone a new VM"
        return 1
    fi
}

##############################################
# Runs prechecks to validate dependencies are
# present and required infra reachable
# Globals:
#   slack_notify
# Returns:
#   Success, else exit 1 and notify on error
##############################################
function prechecks() {

    declare -a undefined_vars
    # Iterate over expected env var names
    # Add any undefined ones to our array
    for ev in "${env_vars[@]}"; do
        if [[ -z "${(P)ev}" ]]; then
            echo "$(date +'%r') : ${script_exec}: ERROR: No definition for ENV ${ev}"
            undefined_vars+=${ev}
        else
            echo "$(date +'%r') : ${script_exec}: ENV ${ev} defined"
        fi
    done

    # If any env vars were undefined, report as error
    if [[ -n "${undefined_vars[*]}" ]]; then
        echo "$(date +'%r') : ${script_exec}: CRITICAL: ENV variable(s) never defined for ${undefined_vars[*]}"
        if [[ "${undefined_vars[*]}" == "SLACK_WEBHOOK_TOKEN" ]]; then
            echo "$(date +'%r') : ${script_exec}: WARNING: Runtime will continue, but no Slack notifications will be sent"
        else
            # If any undefined env vars outside of Slack webhook, exit 1
            slack_notify --status "ERROR" --title "Environment Variable Error" --text "Values never defined for ENV(s) ${undefined_vars[*]}" 2>/dev/null
            exit 1
        fi
    fi

    # Check that anka in path and version returns 0
    if anka version >/dev/null 2>&1; then
        # Validate VM is running — func messages above
        if ! is_vm_running; then
            exit 1
        fi
        # Source name and IP directly from Anka if on macOS
        running_anka_vm=$(anka -j list -r -f name -f ip)
        anka_name=$(plutil -extract body.0.name raw -o - - <<< ${running_anka_vm})
        anka_ip=$(plutil -extract body.0.ip raw -o - - <<< ${running_anka_vm})
        # If running anka version returns false, should be running in Docker with JSON file available
    elif test -f "${running_vms_abs_path}"; then
        # Validate jq is installed
        if ! which jq >/dev/null 2>&1; then
            slack_notify --status "ERROR" --title "Docker Config Error" --text "jq not located after running apt-get install jq"
            echo "$(date +'%r') : ${script_exec}: ERROR: jq not installed! Please run apt-get install jq and try again"
            exit 1
        fi
        anka_name=$(jq -r '.body[].name' "${running_vms_abs_path}")
        anka_ip=$(jq -r '.body[].ip' "${running_vms_abs_path}")
    else
        echo "$(date +'%r') : ${script_exec}: ERROR: Couldn't locate name/IP of running VM"
        echo "$(date +'%r') : ${script_exec}: Validate cloned VM is running and try again"
        exit 1
    fi

    if [[ $(uname) == "Darwin" ]]; then
        echo "$(date +'%r') : ${script_exec}: \n\nINFO: Running main_orchestrator.zsh from macOS host\n"
    fi
}

# Set args for prechecks (after defining our precheck func)
if (( ${opts[(I)(-p|--prechecks)]} )); then
    echo "$(date +'%r') : ${script_exec}: Running prechecks..."
    prechecks
    echo "$(date +'%r') : ${script_exec}: Exiting..."
    exit 0
fi


##############################################
# Runs SSH command with flags on remote host
# Arguments:
#   "${1}", IP/hostname of remote host
#   "${2}", command for remote execution
##############################################
function ssh_exec() {

    ssh -q -i "${key_dir}/${ssh_key}" $(printf '%s' $ssh_env_flags) -o StrictHostKeyChecking=no "${remote_user}@${1}" "${2}"
}

##############################################
# Generates SSH keypair and assign to heredoc
# written to disk to deploy public key for VM
# Outputs:
#   Writes VM SSH setup to $public_key_exec
#   Remove $public_key_exec once run on VM
##############################################
function generate_ssh_key() {

    if [[ -e ${key_dir} ]]; then
        /bin/rm -r ${key_dir}
    fi

    mkdir -p "${key_dir}"

    echo "$(date +'%r') : ${script_exec}: Generating SSH keypair..."
    /usr/bin/ssh-keygen -b 2048 -t rsa -f ${key_dir}/${ssh_key} -q -N ""

    # Validate anka binary
    if which anka >/dev/null 2>&1; then
        public_key_contents=$(/bin/cat "${key_dir}/${public_key}")

        # Assign our runtime command for VMs to a heredoc variable
        /bin/cat > "${public_key_exec}" <<EOF
        /bin/mkdir -p .ssh
        /bin/chmod 700 .ssh
        echo "${public_key_contents}" >> .ssh/authorized_keys && /bin/chmod 640 .ssh/authorized_keys && chown -R ${remote_user} .ssh
        # Self-destruct this script
        /bin/rm "\${0}"
        exit 0
EOF
        anka cp ${public_key_exec} ${anka_name}:/tmp
        anka run ${anka_name} sudo zsh ${public_key_exec}
        /bin/rm "${public_key_exec}"
    else
        sshpass -p "${remote_pass}" ssh-copy-id -o StrictHostKeyChecking=no -i "${key_dir}/${ssh_key}" "${remote_user}@${anka_ip}"
    fi
}

##############################################
# Validates if AutoPkg recipe metadata exists
# Copies that + bootstrap over, adds ENV vars
# Arguments:
#   Anka VM IP: "${1}"
##############################################
function stage_runner() {

    ##########################################
    # Copy over bootstrap, helpers, metadata
    ##########################################

    if [[ -f "${local_upload_metadata}" ]] && [[ ! -f "${local_save_metadata}" ]]; then
        # If expected metadata from last run isn't present but local_upload_metadata is, use for comparison
        cp "${local_upload_metadata}" "${local_save_metadata}"
    fi

    if [[ -f "${local_save_metadata}" ]]; then
        # Rename last_autopkg_metadata.json to autopkg_metadata.json remotely with our scp below
        scp -q -o LogLevel=QUIET -i "${key_dir}/${ssh_key}" "${local_save_metadata}" "${remote_user}@${1}":"${remote_metadata_json}"
    fi

    # Copy over all helpers for AutoPkg runtime and bootstrapping
    scp -q -o LogLevel=QUIET -r -i "${key_dir}/${ssh_key}" -o StrictHostKeyChecking=no "${recipes_abs_path}" "${recipe_list_abs_path}" "${apkg_tools_abs_path}" "${helpers_abs_path}/"* "${remote_user}@${1}":"/tmp"

    ##########################################
    # Populate ENV in remote sshd_config
    ##########################################

    ssh_exec "${1}" "sudo chmod 666 /etc/ssh/sshd_config"
    # Iterate over and write out our ENV vars to the remote Mac
    for ev in "${env_vars[@]}"; do
        ssh_exec "${1}" "sudo echo AcceptEnv ${ev} >> /etc/ssh/sshd_config"
    done
    ssh_exec "${1}" "sudo chmod 644 /etc/ssh/sshd_config"
}


##############################################
# Executes bootstrap on VM with sudo, runs
# AutoPkg recipe builds from ${recipes_to_run}
# Reports on metadata diffs if JSON updated
# Arguments:
#   Anka VM IP: "${1}"
# Outputs:
#   Copies MD + report back to container/host
##############################################
function execute_runner() {

    ##########################################
    # Bootstrap Anka VM
    ##########################################

    ssh_exec "${1}" "sudo -E zsh /tmp/anka_bootstrap.zsh"

    boot_exit_code=$?

    # Check exit code of bootstrap
    if [[ "${boot_exit_code}" -ne 0 ]]; then
        echo "$(date +'%r') : ${script_exec}: ERROR: Bootstrap exited with fatal error ${boot_exit_code}; aborting AutoPkg run... "
        slack_notify --status "ERROR" --title "Bootstrap Failure" --text "Bootstrap exited with fatal error ${boot_exit_code}\nAborting AutoPkg run..."
        exit ${boot_exit_code}
    fi

    ##########################################
    # Run AutoPkg recipes
    ##########################################

    # Run Python unbuffered (-u) so stdout is immediately returned
    ssh_exec "${1}" "/usr/local/autopkg/python -u /tmp/autopkg_tools.py --list ${recipes_to_run} --cache"

    apkgr_exit_code=$?

    # Check exit code of autopkg-runner
    if [[ "${apkgr_exit_code}" -ne 0 ]]; then
        echo "$(date +'%r') : ${script_exec}: ERROR: AutoPkg runner exited with fatal error ${apkgr_exit_code}; aborting AutoPkg run... "
        slack_notify --status "ERROR" --title "AutoPkg runner failure" --text "Runner exited with fatal error ${apkgr_exit_code}\nAborting AutoPkg run..."
        exit ${apkgr_exit_code}
    else
        echo "$(date +'%r') : ${script_exec}: SUCCESS: AutoPkg runner finished with exit code ${apkgr_exit_code}\n"
    fi

    ##########################################
    # Compile and scp back reports/metadata
    ##########################################

    # Create new plist; swap dict values for array
    ssh_exec "${1}" \
        "/usr/libexec/PlistBuddy -c 'Save' \"${remote_report_plist}\"; /usr/bin/sed -i '' 's/dict/array/g' \"${remote_report_plist}\""

    echo "$(date +'%r') : ${script_exec}: Combining below AutoPkg receipts into single file..."

    # Run a find on the remote Mac, looking for recipe plists that ran successfully, and then merge them into the unified AutoPkg results plist created above
    ssh_exec "${1}" \
        "/usr/bin/find \"${remote_cache_dir}\" -type f -iname \"*receipt*plist\" -exec grep -L 'stop_processing_recipe' {} + -exec /usr/libexec/PlistBuddy -x -c 'Merge \"{}\"' \"${remote_report_plist}\" \;"

    # If all looks good, bring back the metadata about our build and upload below if hashes differ
    scp -q -o LogLevel=QUIET -i "${key_dir}/${ssh_key}" "${remote_user}@${1}":"${remote_metadata_json}" "${local_upload_metadata}"
    # Copy full report plist from Cache dir
    scp -q -o LogLevel=QUIET -i "${key_dir}/${ssh_key}" "${remote_user}@${1}":"${remote_report_plist}" "${local_upload_report}"

    # ##########################################
    # Check for diffs, and if MD matches, rm old
    # ##########################################

    # # If on macOS vs Linux, need different commands to get the sha256 value
    if [[ $(uname) == "Darwin" ]]; then
        new_sha256=$(shasum -a 256 "${local_upload_metadata}" 2>/dev/null | awk '{print $1}')
        old_sha256=$(shasum -a 256 "${local_save_metadata}" 2>/dev/null | awk '{print $1}')
        # Linux uses a standalone command for SHA256
    elif [[ $(uname) == "Linux" ]]; then
        new_sha256=$(sha256sum "${local_upload_metadata}" 2>/dev/null | awk '{print $1}')
        old_sha256=$(sha256sum "${local_save_metadata}" 2>/dev/null | awk '{print $1}')
    fi

    if [[ "${new_sha256}" != "${old_sha256}" ]]; then
        echo "$(date +'%r') : ${script_exec}: SHA256 metadata updated for new recipe downloads"
    fi
    # Discard last_autopkg_metadata.json
    /bin/rm -f "${local_save_metadata}"
}


##############################################
# Main run
##############################################
function main() {

    # Timestamp of start
    start_epoch=$(date +%s)

    echo "$(date +'%r') : ${script_exec}: Executing AutoPkg runtime at $(date +"%r %Z")"
    slack_notify --status "NOTICE" --title "Executing AutoPkg" --text "Beginning runtime at $(date +"%r %Z")"

    # Run prechecks — exit if any fail
    prechecks || exit 1

    # Generate SSH keypair
    generate_ssh_key

    # Stage remote runtime
    stage_runner "${anka_ip}"

    # Execute remote runtime
    execute_runner "${anka_ip}"

    # Timestamp of finish
    end_epoch=$(date +%s)
    # Get time elapsed in seconds, convert to hours + minutes where applicable
    exec_time=$(awk '{printf "%d hours, %02d minutes, %02d seconds", $1/3600, ($1/60)%60, $1%60}' <<< $(expr $end_epoch - $start_epoch))

    echo "$(date +'%r') : ${script_exec}: Terminating AutoPkg runtime at $(date +"%r %Z")\nExecution took ${exec_time} to complete\n"
    slack_notify --status "NOTICE" --title "Terminating AutoPkg" --text "Ending runtime at $(date +"%r %Z")\nExecution took ${exec_time} to complete"

    exit 0
}


##############
#### MAIN ####
##############

main
