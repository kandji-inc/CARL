#!/usr/local/autopkg/python
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
# BSD-3-Clause
# Copyright (c) Facebook, Inc. and its affiliates.
# Copyright (c) tig <https://6fx.eu/>.
# Copyright (c) Gusto, Inc.
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
################################################################################################

#######################
####### IMPORTS #######
#######################

import argparse
import json
import logging
import os
import platform
import plistlib
import re
import sys
from fnmatch import fnmatch
from glob import glob
from pathlib import Path
from subprocess import PIPE, STDOUT, CalledProcessError, run

import requests

#############################
######### ARGUMENTS #########
#############################

# Set parsers at the top so they're available to all funcs below
parser = argparse.ArgumentParser(
    prog="autopkg_tools.py",
    description="Wrapper for AutoPkg",
)
parser.add_argument(
    "-l",
    "--list",
    action="store",
    required=False,
    default=False,
    help="Path to JSON blob or PLIST of recipe names.",
)
parser.add_argument(
    "-c",
    "--cache",
    action="store_true",
    required=False,
    default=False,
    help="Load and write previously cached metadata/xattrs for comparison; save out new metadata post-run.",
)
parser.add_argument(
    "-d",
    "--debug",
    action="store_true",
    required=False,
    default=False,
    help="Disables Slack alerts and increases verbosity for logging/stdout.",
)

args = parser.parse_args()

###########################
######### LOGGING #########
###########################

# Get hostname for log record
hostname = platform.node()
# Local logging location
path_to_log = "/var/tmp/autopkg_runner.log"

logging_level = logging.DEBUG if args.debug else logging.INFO

logging.basicConfig(
    level=logging_level,
    format="{asctime} " + f"[{hostname}]" + ": {levelname}: {message}",
    handlers=[logging.FileHandler(path_to_log), logging.StreamHandler()],
    style="{",
    datefmt="%Y-%m-%d %I:%M:%S %p",
)

log = logging.getLogger(__name__)

#############################
######### VARIABLES #########
#############################


# Define PLIST func here to populate variable below
def _plist_pal(path):
    """Function accepts argument of path to .plist file as `path`
    Returns plist formatted as dict"""
    with open(path, "rb") as f:
        loaded_plist = plistlib.load(f)
        return loaded_plist


RELATIVE_DIR = Path(__file__).resolve()
EXECUTION_DIR = Path(RELATIVE_DIR).parents[0]
METADATA_CACHE_PATH = os.environ.get("METADATA_CACHE_PATH", "/tmp/autopkg_metadata.json")
REPORT_PLIST_PATH = "/tmp/autopkg.plist"
SLACK_WEBHOOK = os.environ.get("SLACK_WEBHOOK_TOKEN", None)
ENV_RECIPES_DIR = os.environ.get("RECIPES_DIR_NAME", None)
# Glob for AutoPkg PLIST that may have RECIPE_SEARCH_DIRS for us to read
AUTOPKG_PLIST = glob("/Users/**/Library/Preferences/com.github.autopkg.plist")
# If no ENV defined, set to value defined in AutoPkg plist
RECIPES_DIR = (
    f"/tmp/{ENV_RECIPES_DIR}" if ENV_RECIPES_DIR is not None else _plist_pal(AUTOPKG_PLIST[0]).get("RECIPE_SEARCH_DIRS")
)
RECIPE_TO_RUN = os.environ.get("RECIPE", None)

#############################
######### FUNCTIONS #########
#############################


def _run_command(shell_cmd):
    """Function accepts argument of shell command as `shell_cmd`
    Returns shell stderr + stdout and shell cmd exit code"""
    raw_out = run(shell_cmd, stdout=PIPE, stderr=STDOUT, shell=True, check=True)
    decoded_out = raw_out.stdout.decode().strip()
    exit_code = raw_out.returncode
    return exit_code, decoded_out


def handle_recipe(recipe, args):
    """Run specified recipe, validate results, and log downloads/builds"""
    recipe.run(args)
    if recipe.results.get("downloaded"):
        log.info(f"SUCCESS: Downloaded {recipe.name}")
    if recipe.results.get("built"):
        log.info(f"SUCCESS: Built {recipe.name}")
    return recipe


def parse_recipes(recipes):
    """Define recipe paths and map onto Recipe obj for execution"""
    recipe_list = []
    # If ENV var specified for recipe name, use that over recipe_list
    if RECIPE_TO_RUN:
        for recipe in recipes:
            ext = os.path.splitext(recipe)[1]
            if ext != ".recipe":
                recipe_list.append(recipe + ".recipe")
            else:
                recipe_list.append(recipe)
    else:
        # If we can't locate our recipe list, look in this script's relative dir
        if not os.path.exists(recipes):
            recipes = os.path.join(EXECUTION_DIR, recipes)
        ext = os.path.splitext(recipes)[1]
        if ext == ".json":
            parser = json.load
        elif ext == ".plist":
            parser = plistlib.load
        else:
            log.critical(f"Found invalid recipe list extension! Expected .plist/.json; got {ext}")
            sys.exit(1)

        with open(recipes, "rb") as f:
            recipe_list = parser(f)

    return map(Recipe, recipe_list)


def load_cached_attributes():
    """JSON load previous metadata to return as dict
    If no metadata found, return empty dict"""
    # Load metadata cache file from disk
    try:
        with open(METADATA_CACHE_PATH) as cache_file:
            cached_files = json.load(cache_file)
    # Treat as new build
    except FileNotFoundError:
        cached_files = {}
    return cached_files


def create_file_and_attributes(attributes_dict):
    """Read metadata cache from previous run and write out all items to disk
    If short name in cache path differs from logged in user, update path for current user
    Creates files via mkfile -n, consuming no disk space but reporting defined byte size when
    queried by AutoPkg via os module for filesize comparison; writes any associated xattrs to files"""
    # Python has no native support for extended attributes on macOS, so shell out to write attributes
    for i in attributes_dict:
        for dl_md in attributes_dict.get(i).get("download_metadata"):
            pathname = dl_md.get("pathname")
            etag = dl_md.get("etag")
            last_modified = dl_md.get("last_modified")
            dl_size_in_bytes = dl_md.get("dl_size_in_bytes")

            try:
                cache_path, cache_filename = os.path.split(pathname)
                log.debug(f"Found previous cache path {cache_path}")
                # Grab home dir shortname between Users and Library
                target_home_dir = cache_path[cache_path.find("/Users/") + len("/Users/") : cache_path.rfind("/Library")]
                exitc, console_user = _run_command("/usr/bin/stat -f%Su /dev/console")
                # If home directory and logged in username don't match, replace the former with the latter
                if None not in (target_home_dir, console_user) and target_home_dir != console_user:
                    log.debug(
                        f"Recorded home dir {target_home_dir} and logged in user {console_user} do not match; updating cache path"
                    )
                    cache_path = cache_path.replace(target_home_dir, console_user)
                    pathname = pathname.replace(target_home_dir, console_user)

                # Replicate the previous download file with the metadata we know about it
                if not os.path.exists(cache_path):
                    path_to_create = Path(cache_path)
                    path_to_create.mkdir(parents=True, exist_ok=True)
                # Shell command to write file with specified size to path
                # If dl_size_in_bytes isn't valid, our _run_command will check and throw an exception
                _run_command(f"mkfile -n '{dl_size_in_bytes}' '{pathname}'")
                # Add metadata attributes or skip/report if None
                _run_command(f"xattr -w com.github.autopkg.etag '{etag}' '{pathname}'") if etag else log.info(
                    f"Skipping write of attribute 'etag' for {i}; key is missing"
                )
                _run_command(
                    f"xattr -w com.github.autopkg.last-modified '{last_modified}' '{pathname}'"
                ) if last_modified else log.info(f"Skipping write of attribute 'last_modified' for {i}; key is missing")
                log.info(f"Wrote file with xattrs and byte size {dl_size_in_bytes} to {pathname}")
            # Will hit this exception if "pathname" is NoneType when we try to split it
            except TypeError as e:
                log.critical(
                    f"Issue when populating recipe '{i}' metadata!\nError is '{e}' for provided dict '{dl_md}'"
                )
                pass


def _eval_recipe_results(recipe):
    """Check recipe obj status and define vars for Slack messaging"""
    task_title, task_description = None, None
    if recipe.error:
        try:
            task_title = f"Failed to run {recipe.name}"
            if not recipe.results["failed"]:
                task_description = "Unknown error"
            else:
                task_description = (
                    f"ERROR: {recipe.results['failed'][0]['message']}\n"
                    f"Traceback: {recipe.results['failed'][0]['traceback']}\n"
                )
                if "No releases found for repo" in task_description:
                    # Just no updates
                    return
        except AttributeError:
            task_title = "ERROR: Unable to locate specified recipe!"
            task_description = f"Skipping run of {recipe.recipe_name}; recipe doesn't exist or name is malformed."

    elif recipe.success:
        last_build = recipe.results["built"][-1].get("pkg_path")
        last_vers = recipe.results["built"][-1].get("version")
        if not last_vers:
            # Find a version number from our new PKG build
            out = re.search(r"([0-9](.*)[0-9])", last_build)
            try:
                version = out.group(0)
            except AttributeError:
                version = "Unknown"
        else:
            # If defined, set version as value from receipt plist
            version = last_vers
        all_builds = "\n".join([x.get("pkg_path") for x in recipe.results["built"] if x.get("pkg_path")])
        task_title = f"SUCCESS: Recipe {recipe.name} packaged new version {version}"
        task_description = f"*Build Path(s):*\n {all_builds}\n"
    return task_title, task_description


def slack_alert(recipe, args):
    """Message to Slack channel specified in SLACK_WEBHOOK with recipe run results"""
    # Skip Slack if debug enabled
    if args.debug:
        log.debug("Skipping Slack notification - debug is enabled!")
        return

    # Skip Slack if no webhook defined
    if SLACK_WEBHOOK is None:
        log.warning("Skipping Slack notification - webhook is missing!")
        return

    # Populate title and description from recipe results
    task_title, task_description = _eval_recipe_results(recipe)

    # Validate all req'd vars are populated for Slack posting
    if task_title and task_description and SLACK_WEBHOOK:
        response = requests.post(
            SLACK_WEBHOOK,
            data=json.dumps(
                {
                    "attachments": [
                        {
                            "username": "Autopkg",
                            "as_user": True,
                            "title": task_title,
                            "color": "good" if not recipe.error else "danger",
                            "text": task_description,
                            "mrkdwn_in": ["text"],
                        }
                    ]
                }
            ),
            headers={"Content-Type": "application/json"},
        )
        if response.status_code != 200:
            msg = f"Request to Slack returned an error {response.status_code} with response {response.text}"
            raise ValueError(msg)


class Recipe:
    """Object to interact with AutoPkg recipe"""

    def __init__(self, path):
        try:
            self.recipe_name = path
            self.path = next(iter(glob(f"{RECIPES_DIR}/**/{self.recipe_name}", recursive=True)))
            self.success = False
            self.error = False
            self.results = {}
            self._keys = None
            self._has_run = False

        except StopIteration:
            log.error(f"Could not locate {self.recipe_name}")
            self.error = True
            return None

    @property
    def plist(self):
        if self._keys is None:
            with open(self.path, "rb") as f:
                self._keys = plistlib.load(f)

        return self._keys

    @property
    def name(self):
        return self.plist.get("Input").get("NAME")

    def _get_pkg_version_from_receipt(self, new_dl):
        """Some processors don't return summary results with version/pkg_path
        This func will attempt to locate a receipt newer than the located DL
        and extract both version and pkg_path details for Slack notification"""
        # Set receipt pkg + version to None to return if we can't derive our version below
        receipt_pkg = None
        receipt_version = None
        # Get modification time of new DMG download
        dl_mod_time = os.path.getmtime(new_dl)
        # Get cache dir for build
        parent_path = Path(new_dl).parents[1]

        log.debug(f"Trying to get receipt data from provided DL {new_dl}")

        # Check if receipts dir exists
        if os.path.exists(os.path.join(parent_path, "receipts")):
            for receipt in os.scandir(os.path.join(parent_path, "receipts")):
                # If we find a receipt with a newer mod time than our download, likely the receipt for our new build
                if os.path.getmtime(receipt) > dl_mod_time:
                    log.debug(f"Found new receipt at {receipt}")
                    receipt_plist = _plist_pal(receipt)
                    log.debug(f"Read in plist with contents {receipt_plist}")
                    try:
                        # Get "version" value from receipts plist and assign
                        receipt_version = [
                            values.get("version")
                            for plist in receipt_plist
                            for values in plist.values()
                            if isinstance(values, dict) and "version" in values.keys()
                        ][-1]
                        log.debug(f"Found {receipt_version}")
                    except IndexError:
                        continue
                    try:
                        # Get "pkg_path" value from receipts plist and assign
                        receipt_pkg = [
                            values.get("pkg_path")
                            for plist in receipt_plist
                            for values in plist.values()
                            if isinstance(values, dict) and "pkg_path" in values.keys()
                        ][-1]
                    except IndexError:
                        continue
        return receipt_pkg, receipt_version

    def _parse_report(self, report):
        """Deeply parse AutoPkg summary to find all downloads/builds/failures"""
        # Read plist
        report_data = _plist_pal(report)
        failed_items = report_data.get("failures", [])
        downloaded_items = []
        built_items = []
        # If True, this means something happened
        if report_data.get("summary_results"):
            # Wildcard search for "pkg" in results to get key name since there are multiple possibilities
            pkg_summary_key = "".join([x for x in report_data["summary_results"].keys() if fnmatch(x, "*pkg*")])
            pkg_results = report_data.get("summary_results").get(pkg_summary_key, {})
            built_items.extend(pkg_results.get("data_rows", []))
            dl_results = report_data.get("summary_results").get("url_downloader_summary_result", {})
            downloaded_items.extend(dl_results.get("data_rows", []))
            # There are some cases where a new package was built, but processors like FlatPkgPacker don't show in results
            if dl_results and not pkg_results:
                # If so, look at the download path and identify if the DL'd file was a pkg and report it like a build
                if fringe_build := "".join(
                    [
                        next(iter(x.values()))
                        for x in dl_results.get("data_rows")
                        if fnmatch(next(iter(x.values())), "*pkg*")
                    ]
                ):
                    receipt_pkg, receipt_version = self._get_pkg_version_from_receipt(fringe_build)

                    # Append pkg_path and version if values are not None
                    # Elif append download as pkg_path and version if populated
                    # Else append download as pkg_path and version will be Unknown
                    if receipt_pkg and receipt_version:
                        built_items.append({"pkg_path": receipt_pkg, "version": receipt_version})
                    elif receipt_version:
                        log.debug("Appending built items with version")
                        built_items.append({"pkg_path": fringe_build, "version": receipt_version})
                    else:
                        built_items.append({"pkg_path": fringe_build})

        return {"built": built_items, "downloaded": downloaded_items, "failed": failed_items}

    def run(self, args):
        if not os.path.isfile(REPORT_PLIST_PATH):
            # Create this ourselves so it's ready for AutoPkg to write to
            Path(REPORT_PLIST_PATH).touch()
        try:
            cmd = [
                "/usr/local/bin/autopkg",
                "run",
                "-vvv",
                f'"{self.path}"',
                "--report-plist",
                REPORT_PLIST_PATH,
            ]
            if args.cache:
                cmd.extend(["--post", "io.kandji.cachedata/CacheRecipeMetadata"])
            # Concatenate our commands and run with subprocess
            cmd = " ".join(cmd)
            log.debug(f"Running {cmd}")
            _run_command(cmd)

        except CalledProcessError as e:
            log.error(e)
            self.error = True

        self._has_run = True
        self.results = self._parse_report(REPORT_PLIST_PATH)

        if self.results.get("built"):
            self.success = True

        return self.results


def main():
    """Define recipes to run, write out previous cache (if exists),
    re-export ENV vars for downstream usage, parse/iterate over recipes,
    reporting successes/failures to Slack as they occur"""
    failures = []

    recipes = RECIPE_TO_RUN.split(", ") if RECIPE_TO_RUN else args.list if args.list else None
    if recipes is None:
        log.critical("Recipe --list or RECIPE_TO_RUN not provided!")
        sys.exit(1)
    if args.cache:
        attributes_dict = load_cached_attributes()
        create_file_and_attributes(attributes_dict)
    recipes = parse_recipes(recipes)
    for recipe in recipes:
        log.info(f"Running {recipe.recipe_name}...")
        try:
            handle_recipe(recipe, args)
            slack_alert(recipe, args)
            if failures:
                title = " ".join([f"{recipe.name}" for recipe in failures])
                lines = [f"{recipe.results['message']}\n" for recipe in failures]
                log.error(f"Some failures occurred!\n{title}:\n{lines}")
        except AttributeError as e:
            log.error(f"{e}: Skipping run of {recipe.recipe_name}! Recipe was not found.")
            slack_alert(recipe, args)
            pass


##############
#### MAIN ####
##############

if __name__ == "__main__":
    main()
