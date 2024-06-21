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

# get the inputs
YAML_GEN_CMD=""

if ! is_valid_cid "$CID"; then
	echo "Please provide a valid CID"
    exit 1
fi
YAML_GEN_CMD+=" -c $CID"

if [ -z "$PLAN" ]; then
	echo "Please provide a test plan"
    exit 2
fi
YAML_GEN_CMD+=" --testplan $PLAN"

if [ -n "$EXCLUDE_TASK" ]; then
	YAML_GEN_CMD+=" --excludeJobs $EXCLUDE_TASK"
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

cd "$WORKSPACE"

# Check if CID has available Queue
# TODO: call api

# Generate yaml for given CID

YAML_GENERATOR_DIR="oem-qa-tools/Tools/PC/testflinger_yaml_generator"
YAML_GENERATOR_EXE="testflinger_yaml_generator.py"
TESTFLINGER_EXE="testflinger-cli"
JOB_YAML="job.yaml"

git clone -b pc-sanity-shared git@github.com:Artur-at-work/oem-qa-tools.git

pushd "$YAML_GENERATOR_DIR"
./"$YAML_GENERATOR_EXE"  -c "$CID" -o "$JOB_YAML" --testplan "$PLAN"

cp "$JOB_YAML" "$WORKSPACE"
popd
"$TESTFLINGER_EXE" submit -p "$JOB_YAML"



