#!/bin/bash
set +e
set -x

is_valid_cid() {
    # Pattern to match: 6 digits, '-', and 5 digits
    local cid=$1
    if [[ $cid =~ ^[0-9]{6}-[0-9]{5}$ ]]; then
        return 0
    fi    
    return 1
}

YAML_GENERATOR_DIR="oem-qa-tools/Tools/PC/testflinger_yaml_generator"
YAML_GENERATOR_EXE="testflinger_yaml_generator.py"
TESTFLINGER_EXE="testflinger-cli"
JOB_YAML="job.yaml"
YAML_GEN_CMD=""

# get the inputs

if ! is_valid_cid "$CID"; then
	echo "Please provide a valid CID"
    exit 1
fi
YAML_GEN_CMD+="-c $CID -o $JOB_YAML"

if [ -z "$PLAN" ]; then
	echo "Please provide a test plan"
    exit 2
fi
YAML_GEN_CMD+=" --testplan $PLAN"

if [ -n "$EXCLUDE_TASK" ]; then
	YAML_GEN_CMD+=" --excludeJobs $EXCLUDE_TASK"
fi


# Check if CID has available Queue

queue_list=$(curl --url "https://testflinger.canonical.com/v1/agents/data" --request GET --header "Content-type: application/json" | jq -r '.[] | select(.identifier == "202405-34051")')

# Get YAML generator


cd "$WORKSPACE"
rm -rf oem-qa-tools
git clone -b pc-sanity-shared git@github.com:Artur-at-work/oem-qa-tools.git
pushd "$YAML_GENERATOR_DIR"

if [ "$SIDELOAD_PROVIDER_PATH" = "https://github.com/canonical/checkbox -b master" ];then
	echo "_run sudo add-apt-repository ppa:checkbox-dev/beta -y" >> template/shell_scripts/03_install_checkbox_sideload
    echo "_run sudo apt-get install -y plainbox-provider-pc-sanity" >> template/shell_scripts/03_install_checkbox_sideload
elif [ -z "${$SIDELOAD_PROVIDER_PATH:-}" ]; then
	echo "_run sudo apt-get purge plainbox-provider-pc-sanity" >> template/shell_scripts/05_remove_checkbox_sideload
    echo "_run sudo rm -rf /var/tmp/checkbox-providers" >> template/shell_scripts/05_remove_checkbox_sideload
else
	# custom sideload repo
    git_url="${SIDELOAD_PROVIDER_PATH%% -b*}"
    git_branch="${SIDELOAD_PROVIDER_PATH##*-b }"
    echo "_run sudo git -C /var/tmp/checkbox-providers clone $git_url -b $git_branch" >> template/shell_scripts/03_install_checkbox_sideload
fi

if [ -n "$CHECKBOX_PPAS" ]; then
    echo "sudo add-apt-repository -y -P ${CHECKBOX_PPAS// / -P }" > template/shell_scripts/02_Install_checkbox_deb_2_ppa
fi

if [ -n "$PLAINBOX_CONF" ]; then
    echo "$PLAINBOX_CONF" > template/launcher_config/env.conf  # overwrites the template OR create the env flag in generator?
fi

if [ -n "$MACHINE_MST_JSON" ]; then
    echo "$MACHINE_MST_JSON" > machine-manifest.json
	YAML_GEN_CMD+=" --manifestJson machine-manifest.json"
fi

if [ -n "$TEST_FLINGER_GLOBAL_TIMEOUT" ]; then
	YAML_GEN_CMD+=" --globalTimeout $TEST_FLINGER_GLOBAL_TIMEOUT"
fi

if [ -n "$AUTO_CREATE_BUGS" ]; then
	#TODO
    echo "auto create bugs TRUE"
fi

if [ -n "$AUTO_CREATE_BUGS_ASSIGNEE" ]; then
	YAML_GEN_CMD+=" --LpID $AUTO_CREATE_BUGS_ASSIGNEE"
    # TODO: do we want to set longer reserve time? default 1200s
fi

# install missing packages
if [ -z "$(command -v testflinger-cli)" ]; then
    sudo snap install testflinger-cli
fi

if [ -z "$(command -v shellcheck)" ]; then
    sudo apt-get install -y shellcheck
fi







#./"$YAML_GENERATOR_EXE"  -c "$CID" -o "$JOB_YAML" --testplan "$PLAN"
./"$YAML_GENERATOR_EXE"  ${YAML_GEN_CMD}

cp "$JOB_YAML" "$WORKSPACE"
popd
"$TESTFLINGER_EXE" submit -p "$JOB_YAML"



