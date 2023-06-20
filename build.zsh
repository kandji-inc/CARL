#!/bin/zsh
# Created 06/06/23; NRJA
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

# Get script name
script_exec=$(basename $ZSH_ARGZERO)
# Get directory of script execution
dir=$(dirname $ZSH_ARGZERO)
# Absolute path of exec dir
abs_dir=$(realpath "${dir}")

# Abs path to config.json
config_abs_path=$(find "${abs_dir}" -name "config.json")
# Abs path to anka_install_create_clone.zsh
anka_abs_path=$(find "${abs_dir}" -name "anka_install_create_clone.zsh")
# Abs path to main_orchestrator.zsh
main_orch_abs_path=$(find "${abs_dir}" -name "main_orchestrator.zsh")
# Abs path to CacheRecipeMetadata folder with proc/stub
cache_proc_abs_path=$(find "${abs_dir}" -name "CacheRecipeMetadata")

###########################
########## CONFIG #########
###########################

# Read in values set in config.json
RUNTIME=$(plutil -extract host_runtime raw -o - "${config_abs_path}" 2>/dev/null)
SLACK_NOTIFY=$(plutil -extract slack_notify raw -o - "${config_abs_path}" 2>/dev/null)
RECIPES_DIR=$(plutil -extract local_autopkg_recipes_dir raw -o - "${config_abs_path}" 2>/dev/null)

# Override Slack webhook if notify is set to false
if [[ ! ${SLACK_NOTIFY} == true ]]; then
    # Re-set var and export for downstream execs
    SLACK_WEBHOOK_TOKEN=""
    export SLACK_WEBHOOK_TOKEN=""
fi

# Get folder name of recipes (will be placed in /tmp on remote VM)
RECIPES_DIR_NAME=$(basename "${RECIPES_DIR}")
# Re-set var and export for downstream execs
RECIPES_DIR_NAME="${RECIPES_DIR_NAME}"
export RECIPES_DIR_NAME="${RECIPES_DIR_NAME}"

# Check if folder by name already exists, and if not, if RECIPES_DIR is valid path
if [[ ! -d $(basename "${RECIPES_DIR}") ]] && [[ -d "${RECIPES_DIR}" ]]; then
    echo "${RECIPES_DIR_NAME} not found in local folder - copying over now..."
    cp -R "${RECIPES_DIR}" .
    if [[ -z $(find "${RECIPES_DIR}" -name "CacheRecipeMetadata") ]]; then
        if test -d "${cache_proc_abs_path}"; then
            # Copy over CacheMD proc, but no need to alert on it
            cp -R "${cache_proc_abs_path}" "./${RECIPES_DIR_NAME}"
        fi
    fi
fi

##############################
########## FUNCTIONS #########
##############################

##############################################
# Expects and will execute provided command to
# validate service health for either Docker or
# Anka. Service health checks return stdout
# validated by test -n
# Arguments:
#   "${1}", cmd to validate service is active
# Returns:
#   Exit 1 if service never reports healthy
##############################################
function wait_for_healthy_service() {

    echo "Checking if specified service is active (waiting up to 90 seconds)"

    service_check_cmd="${1}"
    timeout=1
    upperbound=30 # Allow 90 seconds before calling it

    # Checks provided to this func are designed to return stdout only if target app/service is healthy
    until [[ -n $(eval "${service_check_cmd}") ]] || [[ "${timeout}" -gt "${upperbound}" ]]; do
        sleep 3

        echo "$(date +'%r') : Still awaiting activation of service... (${timeout}/${upperbound})"

        let timeout++
    done

    if  [[ "${timeout}" -gt "${upperbound}" ]] && [[ -z $(eval "${service_check_cmd}") ]]; then
        echo "ERROR: Requested service never activated when confirming from stdout of below command!\n"
        echo "${service_check_cmd}"
        echo "\nPlease validate unhealthy service and re-run ${script_exec}"
        exit 1
    fi

    echo "Service activated! Proceeding..."

    # Sleep 5 to give the service a bit more time
    sleep 5
}

##############################################
# Confirms runtime is not with sudo/root
# Checks for valid Anka install, and prompts
# to install (requiring sudo) or clone if no
# running VM located. Outputs JSON file with
# name and IP address of running Anka VM
# Outputs:
#   Writes out ./running_vms.json with VM info
# Assigns:
#   Variables assigned
# Returns:
#   Exit 1 if any prechecks fail
##############################################
function prechecks() {

    # Check for sudo or root
    if [[ "${EUID}" -eq 0 ]]; then
        echo "CRITICAL: Build script should not be run with sudo or as root!"
        exit 1
    fi

    # Check for running Anka VM
    if ! anka version >/dev/null 2>&1; then
        echo "ERROR: No Anka install found!"
        if read -q "?Download + install Anka (requires sudo!) and create a new macOS VM? (Y/N): "; then
            sudo "${anka_abs_path}"
            # Check for running Anka VM that reports IP address — grep for IP given expected pattern
            wait_for_healthy_service 'anka list -r -f ip 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b"'
        else
            echo "\n\nRun the below to install and create new macOS VM\n\nsudo ${anka_abs_path}\n"
            exit 1
        fi
        # If anka is installed, but no VM running, offer to clone and then continue
    elif [[ -z $(anka list -r 2>/dev/null) ]]; then
        echo "WARNING: No running Anka VMs found!"
        docker_alive=$(launchctl print gui/$(/usr/bin/stat -f%Du /dev/console) | grep -i application.com.docker | awk '{print $1}')
        if [[ ${docker_alive} -gt 0 ]]; then
            echo "WARNING: Due to a vendor bug, Docker must be fully closed before cloning/starting an Anka VM!"
            echo "Please fully close Docker Desktop and re-run ${script_exec}"
            exit 1
        fi
        echo "Cloning a new VM before continuing"
        echo "Will wait post-clone for Anka service for fully start"
        "${anka_abs_path}" --cloneonly
        # Check for running Anka VM that reports IP address — grep for IP given expected pattern
        wait_for_healthy_service 'anka list -r -f ip 2>/dev/null | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b"'
    fi

    # Write JSON file of running VM out to disk
    anka -j list -r -f name -f ip > ./running_vms.json || exit 1
}

##############################################
# Checks the assigned runtime — if local, runs
# main_orchestrator.zsh. If docker, validates
# Docker install, prompts for local run if
# Docker not present, and confirms healthy
# Docker prior to building and running image
# Outputs:
#   AutoPkg results to autopkg-runner-results
#   AutoPkg metadata to autopkg_metadata.json
# Returns:
#   If local runtime, main_orchestrator exec
#   Exit 1 on error
##############################################
function execute_runtime() {

    if [[ "${RUNTIME}" == "local" ]]; then

        # Invoke main orchestrator on local machine with exec to replace this script
        exec "${main_orch_abs_path}"

    elif [[ "${RUNTIME}" == "docker" ]]; then

        # Confirm Docker is installed
        docker_installed=$(readlink $(which docker) | grep -o '.*Docker.app')

        if [[ -z ${docker_installed} ]]; then
            echo "WARNING: No Docker install found on-disk!"
            if read -q "?Proceed with Anka VM bootstrap using this Mac as host? (Y/N): "; then
                exec "${main_orch_abs_path}"
            else
                echo "\nExiting..."
                exit 0
            fi
        fi

        # Check if Docker proc is active
        docker_alive=$(launchctl print gui/$(/usr/bin/stat -f%Du /dev/console) | grep -i application.com.docker | awk '{print $1}')

        if [[ ${docker_alive} -gt 0 ]]; then
            # Docker version returns error code if EULA not accepted
            if ! docker version >/dev/null 2>&1; then
                echo "WARNING: Docker is open, but appears unhealthy."
                echo "Ensure setup is complete/EULAs accepted and re-run ${script_exec}"
                exit 1
            fi
            # Stop and remove existing containers and images
            docker stop $(docker ps -aq -f "Name=AnkaVM") 2>/dev/null
            docker rm -f $(docker ps -aq -f "Name=AnkaVM") 2>/dev/null
            docker rmi -f $(docker images --filter=reference='anka_vm') 2>/dev/null
            # Rebuild container, remove JSON file once built (JSON is copied over)
            docker build . -t 'anka_vm'; rm ./running_vms.json
            # Run Docker with ENV vars passed in to begin AutoPkg execution
            docker run -e "SLACK_WEBHOOK_TOKEN=${SLACK_WEBHOOK_TOKEN}" -e "RECIPES_DIR_NAME=${RECIPES_DIR_NAME}" -it --name 'AnkaVM' anka_vm

            # Post execution, create a dedicated folder for results
            mkdir -p ./autopkg-runner-results
            # Copy back any metadata for runtime/downloads
            docker cp $(docker ps -aq -f "Name=AnkaVM"):/app/autopkg_metadata.json . 2>/dev/null
            # Copy back full recipe results with timestamp to folder
            docker cp $(docker ps -aq -f "Name=AnkaVM"):/app/autopkg_full_results.plist ./autopkg-runner-results/autopkg_full_results_$(date +%Y-%m-%d_%H%M%S).plist
        else
            echo "WARNING: Docker installed, but not active."
            echo "Attempting to launch Docker from ${docker_installed}..."
            open -jga "${docker_installed}"
            # Check for running Docker Server that reports proper version
            # Server only shows version once Docker Engine healthy
            wait_for_healthy_service 'docker version 2>/dev/null | grep -i "Server.*Docker"'
            # Hit it again with Docker open
            execute_runtime
        fi
    else
        echo "WARNING: No runtime specified!"
        if read -q "?Proceed with Anka VM bootstrap using this Mac as host? (Y/N): "; then
            exec "${main_orch_abs_path}"
        fi
        echo "\nExiting..."
    fi

}

##############################################
# Main runtime
##############################################
function main() {

    prechecks

    execute_runtime

    exit 0
}

###############
##### MAIN ####
###############

main
