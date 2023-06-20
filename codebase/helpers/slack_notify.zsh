#!/bin/zsh
# Created 08/15/22; NRJA
# Updated 06/01/23; NRJA
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

slack_webhook_url=${SLACK_WEBHOOK_TOKEN}
slack_footer_icon="https://avatars.githubusercontent.com/u/5170557?s=200&v=4"

# Check if webhook is defined/expected format — if not, skip Slack notifications
if [[ ! "${slack_webhook_url}" =~ hooks.slack.com/services ]]; then
    NO_SLACK=true
fi

##############################
########## FUNCTIONS #########
##############################

##############################################
# Sourceable function to send Slack messages
# Globals:
#   slack_webhook_url
# Arguments:
#   --status (str): SUCCESS/NOTICE/WARNING/ERROR
#   --title (str): Header of Slack notification
#   --text (str): Body of Slack notification
#   --host_info (bool): Send details of macOS host
# Returns:
#   POST message to slack_webhook_url channel
##############################################
function slack_notify() {

    zparseopts -D -E -A opts -status: -title: -link: -text: -host_info:
    # shellcheck disable=SC2154
    if [[ -n "${NO_SLACK}" ]]; then
        echo "Skipping $opts[--status] Slack notification with text $opts[--text]"
        return 0
    fi

    case $opts[--status] in
        SUCCESS)
            # Set alert color to green
            color="00FF00"
            icon="https://emoji.slack-edge.com/T9C5BNZ0D/visible_happiness/58eb35fc3dddedbd.png"
            ;;
        NOTICE)
            # Set alert color to magenta
            color="FF00C8"
            icon="https://emoji.slack-edge.com/T9C5BNZ0D/autoapps_intensify/364cc72c5f04f5f5.gif"
            ;;
        WARNING)
            # Set alert color to orange
            color="E8793B"
            icon="https://emoji.slack-edge.com/T9C5BNZ0D/yellow_alert/94fbc21b9646e931.gif"
            ;;
        ERROR)
            # Set alert color to red
            color="FF0000"
            icon="https://emoji.slack-edge.com/T9C5BNZ0D/red_alert/54c511cbd0ef70e5.gif"
            ;;
        *)
            # Else, set alert to black
            color="000000"
            icon="https://emoji.slack-edge.com/T9C5BNZ0D/spinning_beachball_of_death/e398593cdbd8557c.gif"
            ;;
    esac

    read -r -d '' payload_builder <<EOF
            payload={"attachments":[{
            "fallback":"$opts[--status]: $opts[--title]",
            "title":"$opts[--status]: $opts[--title]",
            "title_link":"$opts[--link]",
            "text":"$opts[--text]",
            "color":"#${color}",
            "thumb_url": "${icon}",
            "footer": "AutoPkg Runner",
            "footer_icon": "${slack_footer_icon}",
            "ts": $(date +%s),
EOF

    # Add values if flag is selected to provide details
    # Accepts True or Yes
    if [[ "$opts[--host_info]" =~ [tTyY] ]]; then
        read -r -d '' <<EOF
            "fields":[
            {"title":"Hostname","value":"$(scutil --get ComputerName)","short":true},
            {"title":"Serial Number","value":"$(ioreg -c IOPlatformExpertDevice -d 2 | awk -F\" '/IOPlatformSerialNumber/{print $(NF-1)}')","short":true},
            {"title":"Operating System","value":"$(sw_vers -productName) $(sw_vers -productVersion)","short":true},
            {"title":"Internal IP","value":"$(ifconfig | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p' | tr '\n' '\t')","short":true}],
EOF
        payload_builder+=${REPLY}
    fi
    # End tags for JSON body
    payload_builder+='}]}'

    # POST our Slack message
    curl -s -X POST --data-urlencode "${payload_builder}" "${slack_webhook_url}" 1>/dev/null
}
