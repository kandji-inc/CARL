# `C`acheless `A`utoPkg `R`unner `L`ocalized (`CARL`)
  * #### [ABOUT](#about-1)
  * #### [SETUP](#setup-1)
  * #### [RUNTIME](#runtime-1)
  * #### [RUNTIME COMPONENTS](#runtime-components-1)
  * #### [CREDITS](#credits-1)

---
## ABOUT
- ### CARL is a local workflow to:
  - #### Configure and bootstrap an [Anka](https://veertu.com/anka-develop/) macOS VM for [AutoPkg](https://github.com/autopkg/autopkg) execution
  - #### Run specified AutoPkg recipes
  - #### Record and preserve download metadata in a JSON blob
  - #### For subsequent recipe runs, recreate AutoPkg download cache from previous JSON metadata
    - #### JSON-populated cache writes very quickly to disk and uses a fraction of the disk space
    - #### Recreated cache is equally performant when used to compare downloads/identify new updates
<br></br>
> **Note**
> The default config works just fine for getting started
> 
> To jump right in, clone this repo and run `./build.zsh` from the root dir
>
> Otherwise, read on for setup instructions and technical details

<br></br>
## SETUP
### CONFIG
- There are three configurable settings available in the [config.json](config.json):
    - `host_runtime`
        - `local`: **Default** setting, uses the local Mac to execute the end-to-end Cacheless AutoPkg workflow
        - `docker`: Builds from [Dockerfile](Dockerfile), copies over all dependencies, and orchestrates the Anka VM runtime
    - `local_autopkg_recipes_dir`
        - Can specify a directory path elsewhere on-disk containing .recipe files for execution
        - **Defaults** to [./example-recipes](example-recipes) folder at root dir
        - If `basename` of path (i.e. folder name) does not exist at root dir, it will be copied over and the [CacheRecipeMetadata](example-recipes/CacheRecipeMetadata) processor placed within
        - **NOTE**: To scope recipes for runtime, they must be added to [recipe_list.json](recipe_list.json)
    - `slack_notify`
        - `bool` value to disable Slack notifications for entire runtime
        - **Default** is `false`; results in no messages posting to Slack for any execution, only stdout and logging
        - Setting to `true` expects an ENV variable key `SLACK_WEBHOOK_TOKEN` with the value of a valid `hooks.slack.com` URL (see below)
- On your local Mac, you may define `SLACK_WEBHOOK_TOKEN` as an envrionment variable
    - This is used to send messages to a specified Slack channel with updates for
        - AutoPkg Runner start
        - Any updates downloaded
        - Any updates built
        - Any failures
        - AutoPkg Runner end
    - ENV should be in the form of `SLACK_WEBHOOK_TOKEN=https://hooks.slack.com/services/XXXXXXXXX/XXXXXXXXXXX/XXXXXXXXXXXXXXXXXXXXXXXX`
    - It can be added to `~/.zshrc`, `~/.zshenv`, or any other file that is sourced and makes ENV vars available to your Terminal session
    - To confirm `SLACK_WEBHOOK_TOKEN` is available to AutoPkg Runner, open a new Terminal window and run `export | grep SLACK_WEBHOOK_TOKEN`
- **OPTIONAL INSTALL**: This workflow supports running from a containerized Docker image
    - You can download [Docker Desktop here](https://docs.docker.com/desktop/install/mac-install/) for your Mac's chipset
    - **IMPORTANT**: Due to a bug with Anka Develop, you must first start your cloned VM, _then_ launch Docker
    - See instructions above to specify `docker` as `host_runtime` in the [config.json](config.json)

### AUTOPKG RECIPES
- This repo contains several example recipes (in the aptly named [example-recipes](example-recipes) folder), as well as [a JSON file](recipe_list.json) governing which recipes are run
    - You are free to add your own recipes, overrides, custom processors, etc.
    - See instructions above to specify `local_autopkg_recipes_dir` in the [config.json](config.json)

## RUNTIME
### BOOTSTRAPPING

- Once your config is set, run [build.zsh](build.zsh) from the root directory.
- If Anka isn't installed, you'll be prompted to enter your `sudo` password to execute [anka_install_create_clone.zsh](codebase/anka_install_create_clone.zsh), which:
  1. Ensures you have appropriate rights (e.g. invoked with sudo)
  2. Downloads, validates the security of, and installs the free Anka Develop client
  3. Accepts the software license and offers to download/create a new VM running the latest macOS
  4. Clones our newly downloaded VM and spins it up
    - If more than one VM is found, you will be prompted to select one to clone
  5. Deletes the Anka installer
  6. Once started, the cloned Anka VM has a default username:password of `anka`:`admin`

### END-TO-END FLOW
#### Below runtime is for a [config.json](config.json) set as follows (not the default!):

```
{
  "host_runtime": "docker",
  "local_autopkg_recipes_dir": "./example-recipes",
  "slack_notify": true
}
```

1. Spins up a lightweight Docker container and connects to an active Anka VM runner
2. If previous AutoPkg run JSON results exist, they are copied over to the Anka VM alongside other dependencies
3. Remote VM is bootstrapped, AutoPkg installed and configured, and is ready to run some recipes
4. Runner executes `autopkg_tools.py`
    - Using the `--cache` flag, if existing, JSON metadata file is parsed and cache of all previously downloaded files + extended attributes (`xattrs`; e.g. `last-modified`) are recreated on-disk
    - Files are created using `mkfile -n`, where file size is noted upon object creation (e.g. `ls -la` shows reported size), but disk blocks aren't allocated (e.g. `du -sh` shows no actual disk usage)
    - Python's `os.path.getsize` (used by AutoPkg to read byte size) can also read in these no-block files and use them for comparison of both file size and `xattrs`
    - This allows us to very quickly recreate a directory of files that reads like multiple gigabytes with virtually no disk usage
5. `autopkg_tools.py` reads and locates all recipes specified in `recipe_list.json`
6. Target recipes will check cache (if present) and compare against available download
7. If download differs (according to `xattr` or alternate check of byte size only), update is downloaded and a subsequent PKG created
8. Results from new builds/downloads are concatenated into a combined `.plist`, metadata `.json` updated with any new downloads, and both files `scp`'d back to host endpoint
9. New and old metadata files are compared and reported on if shasum values differ
10. Status of new builds and `autopkg-runner` execution are reported back to Slack in the channel specified by `SLACK_WEBHOOK_TOKEN`

## RUNTIME COMPONENTS
### Primary
- [main_orchestrator.zsh](codebase/main_orchestrator.zsh): Z shell
  - Runs prechecks to validate required dependencies are available/defined
  - Generates an SSH keypair and formats public key to be received by Anka VM
  - Clones a Mac VM and installs public SSH key
  - Copies over AutoPkg last run metadata (if present), as well as other req'd files
  - Remotely executes our bootstraper `anka_bootstrap.zsh`
  - Remotely executes our AutoPkg runner `autopkg_tools.py`
  - Copies back metadata, recipe receipts, and reports on changes to metadata
- [autopkg_tools.py](codebase/autopkg_tools.py): Python 3
  - Iterates over and builds packages based on a list of recipes; called with flag `-l` and file `recipe_list.json`
  - Loads and writes out cached metadata from the last AutoPkg run, caches any new metadata post-run; called with flag `-c`

### Helpers
- [anka_bootstrap.zsh](codebase/helpers/anka_bootstrap.zsh): Z shell
  - Checks for the existence of, and if missing, installs AutoPkg, Rosetta 2, and custom AutoPkg settings
- [slack_notify.zsh](codebase/helpers/slack_notify.zsh): Z shell
  - Can be passed named args of `-status`, `-title`, `-text`, and optional `-host_info` (Hostname, Serial, OS, internal IP)
  - Sourced by `main_orchestrator.zsh`, `anka_bootstrap.zsh`

### Processors

- [CacheRecipeMetadata](example-recipes/CacheRecipeMetadata): A folder containing the caching processor and recipe stub; present in the `example-recipes` folder
  - [CacheRecipeMetadata.py](example-recipes/CacheRecipeMetadata/CacheRecipeMetadata.py): Python AutoPkg postprocessor; executes after every individual AutoPkg recipe run, collects download metadata, and writes to `/tmp/autopkg_metadata.json`
  - [io.kandji.cachedata.recipe](example-recipes/CacheRecipeMetadata/io.kandji.cachedata.recipe): A recipe stub in the same relative directory as our Python code so AutoPkg knows how to identify and run the above

### Configuration

- [recipe_list.json](recipe_list.json): A JSON blob populated by recipe names for execution
  - These recipes must be available within the folder path defined in [config.json](config.json)
    - They are sequentially run by invoking `autopkg_tools.py -l recipe_list.json`
  - **Defaults** to all recipes (see below) contained within the `example-recipes` directory
```
[
  "AdobeAcrobatProDC.pkg.recipe",
  "AndroidStudio.pkg.recipe",
  "BraveBrowser.pkg.recipe",
  "Docker.pkg.recipe",
  "GitHubDesktop.pkg.recipe",
  "GoogleChrome.pkg.recipe",
  "MicrosoftExcel.pkg.recipe",
  "MicrosoftPowerPoint.pkg.recipe",
  "MicrosoftRemoteDesktop.pkg.recipe",
  "MicrosoftWord.pkg.recipe",
  "PyCharmCE.pkg.recipe",
  "TableauDesktop.pkg.recipe",
  "VLC.pkg.recipe",
  "Zoom.pkg.recipe"
]
```

## CREDITS
[autopkg_tools.py](https://github.com/facebook/IT-CPE/tree/master/legacy/autopkg_tools) from Facebook under a BSD 3-clause license with modifications from [tig](https://6fx.eu) and [Gusto](https://github.com/Gusto/it-cpe-opensource/blob/main/autopkg/autopkg_tools.py).
