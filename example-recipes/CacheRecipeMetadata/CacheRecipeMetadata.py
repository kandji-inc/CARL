#!/usr/bin/env python3
# Updated 09/01/22; NRJA
# Updated 06/07/23; NRJA
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
# Based originally on LastRecipeRunResult
# Copyright 2019-Present Graham R Pugh
# Copyright 2022 Gusto, Inc. (https://www.gusto.com/)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""See docstring for CacheRecipeMetadata class"""

#######################
####### IMPORTS #######
#######################

import json
import os
from datetime import datetime
from pathlib import Path
from subprocess import PIPE, STDOUT, run

from autopkglib import Processor  # pylint: disable=import-error

#############################
######### VARIABLES #########
#############################

__all__ = ["CacheRecipeMetadata"]

#############################
######### FUNCTIONS #########
#############################


def _run_command(shell_cmd):
    """Function accepts argument of shell command as `shell_cmd`
    Returns shell stderr + stdout and shell cmd exit code"""
    shell_cmd = shell_cmd.split()
    raw_out = run(shell_cmd, stdout=PIPE, stderr=STDOUT, shell=True, check=False)
    decoded_out = raw_out.stdout.decode().strip()
    exit_code = raw_out.returncode
    return exit_code, decoded_out


class CacheRecipeMetadata(Processor):
    """An AutoPkg processor for writing recipe metadata to a JSON file."""

    input_variables = {
        "output_file_path": {"description": ("Path to output file."), "required": False},
        "output_file_name": {
            "description": ("Name of output file."),
            "required": False,
            "default": "autopkg_metadata.json",
        },
        "url": {"description": ("the download URL."), "required": False},
        "RECIPE_PATH": {"description": ("The name of the package."), "required": False},
        "download_changed": {"description": ("If any downloads changed."), "required": False},
        "pathname": {
            "description": ("The path to the downloaded installer."),
            "required": False,
        },
        "last_modified": {
            "description": ("last_modified output from URLDownloader."),
            "required": False,
        },
        "etag": {
            "description": ("etag output from URLDownloader."),
            "required": False,
            "default": None,
        },
    }

    output_variables = {
        "url": {"description": ("the download URL.")},
        "last_modified": {"description": ("The current package last_modified.")},
        "etag": {"description": ("The outputted value for etag.")},
        "RECIPE_PATH": {"description": ("the package name.")},
    }

    description = __doc__

    def get_latest_recipe_run_info(self, output_file):
        """Load CacheRecipeMetadata output from disk."""
        try:
            with open(output_file) as fp:
                data = json.load(fp)
        except (OSError, ValueError):
            data = {}
        return data

    def find_downloads_dir(self, directory):
        """Drill down from provided path until we reach downloads dir"""
        while not str(directory).endswith("downloads"):
            directory = str(Path(directory).parent)
        return directory

    def populate_multiple_dls(self, dls_dir, known_dl):
        """Returns a list of dicts containing metadata for DL files appearing valid"""

        return_list = []
        # Identify files
        for root, dirs, files in os.walk(dls_dir):
            for name in files:
                additional_dl_path = os.path.join(root, name)

                placeholder_dict = {}
                additional_dl_size = os.path.getsize(additional_dl_path)

                # Populate any file names that don't match our reported recipe DL
                # Set our minimum DL size to 500KB to weed out tmp files
                if additional_dl_size > 500000 and additional_dl_path != known_dl:
                    print(f"{additional_dl_path} appears to be valid with byte size {additional_dl_size}")
                    # Grab previous curl etag
                    exitc, add_etag = _run_command(
                        f'xattr -p com.github.autopkg.etag "{additional_dl_path}" 2>/dev/null'
                    )
                    # Grab previous last modified
                    exitc, add_last_mod = _run_command(
                        f'xattr -p com.github.autopkg.last-modified "{additional_dl_path}" 2>/dev/null'
                    )
                    # Grab URL DL metadata (if exists)
                    # Useful info to capture if so, but not required
                    exitc, additional_dl = _run_command(
                        f'xattr -p com.apple.metadata:kMDItemWhereFroms "{additional_dl_path}" 2>/dev/null'
                    )
                    # Grab file type data to determine if .zip/.dmg/.pkg
                    exitc, additional_dl_type = _run_command(f'file -b "{additional_dl_path}" 2>/dev/null')
                    # A valid DL will typically have metadata for last modification
                    # If not, check if the file type has "archive" or "compressed" in the type
                    if add_last_mod or "archive" in additional_dl_type or "compressed" in additional_dl_type:
                        # If downloading multiple files, the URL value is overwritten by subsequent ones
                        # It's stored somewhere in the autopkg cache run data
                        # But there's not a clean way to get it, so pull from file metadata (if present)
                        if additional_dl:
                            self.output(f"Bonus URL: {additional_dl}")
                            placeholder_dict["url"] = additional_dl
                        if additional_dl_path:
                            self.output(f"Bonus path: {additional_dl_path}")
                            placeholder_dict["pathname"] = additional_dl_path
                        if add_etag:
                            self.output(f"Bonus etag: {add_etag}")
                            placeholder_dict["etag"] = add_etag
                        if add_last_mod:
                            self.output(f"Bonus last_modified: {add_last_mod}")
                            placeholder_dict["last_modified"] = add_last_mod
                        if additional_dl_size:
                            self.output(f"Bonus DL size: {additional_dl_size}")
                            placeholder_dict["dl_size_in_bytes"] = str(additional_dl_size)

                        return_list.append(placeholder_dict)
        return return_list

    def main(self):
        """output the values to a file in the location provided"""

        output_file_path = self.env.get("output_file_path")
        output_file_name = self.env.get("output_file_name")
        self.env.get("download_changed")
        pathname = self.env.get("pathname")
        recipe_name = self.env.get("RECIPE_PATH")
        url = self.env.get("url")
        last_modified = self.env.get("last_modified")
        etag = self.env.get("etag")
        dl_size_in_bytes = os.path.getsize(pathname)

        recipe_path, recipe_filename = os.path.split(recipe_name)

        # If we have multiple valid downloads, we want to record those
        # Data will be stored as a list of dicts under the recipe_filename key
        first_download_dict = {}
        recipe_metadata_list = []

        if not output_file_path:
            output_file_path = "/tmp"
        output_file = os.path.join(output_file_path, output_file_name)

        # Load stored JSON file
        data = self.get_latest_recipe_run_info(output_file)

        cache_modified = False

        # Replace modified values
        # Create new key if recipe metadata not previously cached
        if recipe_filename not in data.keys():
            data[recipe_filename] = {}

        if url:
            self.output(f"URL: {url}")
            first_download_dict["url"] = url

        if pathname:
            self.output(f"Path: {pathname}")
            first_download_dict["pathname"] = pathname

        if etag:
            self.output(f"etag: {etag}")
            cache_modified = True
            first_download_dict["etag"] = etag
        if last_modified:
            self.output(f"last_modified: {last_modified}")
            cache_modified = True
            first_download_dict["last_modified"] = last_modified
        if dl_size_in_bytes:
            self.output(f"DL size: {dl_size_in_bytes}")
            cache_modified = True
            first_download_dict["dl_size_in_bytes"] = str(dl_size_in_bytes)

        recipe_metadata_list.append(first_download_dict)

        downloads_dir = self.find_downloads_dir(pathname)
        dl_dir_contents = os.listdir(downloads_dir)

        # We want to capture multiple downloads if they exist
        if len(dl_dir_contents) > 1:
            bonus_dls_list = self.populate_multiple_dls(downloads_dir, pathname)

            # If our list doesn't return empty, the cache was likely modified
            if bonus_dls_list:
                cache_modified = True
                # Update our primary DL results with ancillary
                recipe_metadata_list.extend(bonus_dls_list)

        if cache_modified:
            data[recipe_filename]["cache_timestamp"] = str(datetime.now())
        if recipe_metadata_list:
            data[recipe_filename]["download_metadata"] = recipe_metadata_list

        # Write changes back to stored JSON file
        with open(output_file, "w") as outfile:
            json.dump(data, outfile, indent=4)

        self.output(f"Metadata cache written to: {output_file}")


if __name__ == "__main__":
    PROCESSOR = CacheRecipeMetadata()
    PROCESSOR.execute_shell()
