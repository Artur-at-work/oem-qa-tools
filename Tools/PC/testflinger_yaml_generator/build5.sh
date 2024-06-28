#!/bin/bash
set +e
set -x

cd $WORKSPACE

set -o allexport
source "$WORKSPACE/.build_env"
set +o allexport

is_valid_cid() {
    # Pattern to match: 6 digits, '-', and 5 digits
    local cid=$1
    if [[ $cid =~ ^[0-9]{6}-[0-9]{5}$ ]]; then
        return 0
    fi    
    return 1
}

update_checkbox_conf_manifest() {
	# 2024.06.28 - copied this function from sanity-3-main.sh and adapted to current build env
	SSH_KEY="$WORKSPACE/secrets/oem-qa/ssh_private_key"
    SSH_PHRASE="$WORKSPACE/secrets/oem-qa/passphrase"
	if [[ ! -f $SSH_KEY || ! -f $SSH_PHRASE ]]; then
        echo "OEM-QA private key or OEM-QA passphrase is not available!"
        exit 5
    fi
    manifest_repo="ce-oem-dut-checkbox-configuration"
    target_branch="main"
    pc_sanity_manifest="pc/default/pc-mini-manifest.json"
    git_url="git@github.com:canonical/ce-oem-dut-checkbox-configuration.git"

    # Added ce-qa key into ssh-agent, we will uses it while push code to ce-oem-dut-checkbox-configuration git repo
    export PASSPHRASE=$(cat $SSH_PHRASE)
    echo -e '#!/bin/bash\nread SECRET\necho $SECRET' > echo_key.sh
    chmod 755 echo_key.sh
    chmod 600 $SSH_KEY
    eval `ssh-agent -s`
    DISPLAY=1 SSH_ASKPASS="./echo_key.sh" ssh-add $SSH_KEY <<< "$PASSPHRASE"
    GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null' git clone "$git_url" -b "$target_branch" --depth 1
    # AI: update the name for CLONE_MANIFEST variable
    # Currently, we will clone the manifest repo any way, and having following purpose for this variable
    # 1. Upload manifest to git repo if CLONE_MANIFEST is true
    # 2. When the machine manifest not exists, apply full default manifest file if CLONE_MANIFEST is true
    # 3. When the machine manifest not exists, apply pc-mini-manifest file if CLONE_MANIFEST is false

    if [ -d "$manifest_repo" ]; then
        # merge system manifest and checkbox conf
        # DEVICE_ID is CID
        cd "$manifest_repo" || return
        args=(-c "$CID" -t pc --checkbox-conf-data "$PLAINBOX_CONF" --manifest-data "$MACHINE_MST_JSON" -b "$target_branch")
        [ "$CLONE_MANIFEST" == "true" ] && args+=(--upload)
        # Will generate a machine manifest JSON file for DUT, and upload it to git repo if CLONE_MANIFEST is toggle
        # If the machine manifest already exists in that git repo, will update MACHINE_MST_JSON to that file
        # Otherwise, the script will generate a machine manifest file with following conditions
        #  1. Apply MACHINE_MST_JSON if MACHINE_MST_JSON is available
        #  2. Apply pc/default/manifest.json if upload argument is True
        #  3. Apply pc/default/pc-mini-manifest.json if upload argument is False
        python3 utils/manifest-update.py "${args[@]}"
        # Update the MACHINE_MST_JSON variable, and this script will generate a manifest.json in DUT
        MACHINE_MST_JSON=$(cat "pc/$CID/manifest.json")
        cd - || return
    fi

    if [ -e "$manifest_repo/pc/$CID/checkbox.conf" ]; then
        PLAINBOX_CONF=$(cat "$manifest_repo/pc/$CID/checkbox.conf")
    elif [ -e "$manifest_repo/pc/default/checkbox.conf" ]; then
        PLAINBOX_CONF=$(cat "$manifest_repo/pc/default/checkbox.conf")
    fi

    # Remove the ssh-agent
    ssh-add -D
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
queues_list=$(curl --url "https://testflinger.canonical.com/v1/agents/data" --request GET --header "Content-type: application/json" | jq -r '.[] | select(.identifier == '\"$CID\"') | .queues')
if [ -z "${queues_list:-}" ]; then
	echo "No queues found for $CID"
    exit 3
fi

# Get YAML generator
rm -rf oem-qa-tools
git clone -b pc-sanity-shared git@github.com:Artur-at-work/oem-qa-tools.git

pushd "$YAML_GENERATOR_DIR"
echo "CHECKBOX_SIDELOAD_PATH: $CHECKBOX_SIDELOAD_PATH"
if [ "$CHECKBOX_SIDELOAD_PATH" = "https://github.com/canonical/checkbox -b master" ];then
    # default in Jenkins
	echo "_run sudo add-apt-repository ppa:checkbox-dev/beta -y" >> template/shell_scripts/03_install_checkbox_sideload
    echo "_run sudo apt-get install -y plainbox-provider-pc-sanity" >> template/shell_scripts/03_install_checkbox_sideload
elif [ -z "${CHECKBOX_SIDELOAD_PATH:-}" ]; then
    # no sideload
	echo "_run sudo apt-get purge plainbox-provider-pc-sanity" >> template/shell_scripts/05_remove_checkbox_sideload
    echo "_run sudo rm -rf /var/tmp/checkbox-providers" >> template/shell_scripts/05_remove_checkbox_sideload
else
	# custom sideload repo
    git_url="${CHECKBOX_SIDELOAD_PATH%% -b*}"
    git_branch="${CHECKBOX_SIDELOAD_PATH##*-b }"
    #mkdir -p /var/tmp/checkbox-providers
    echo "_run sudo mkdir -p /var/tmp/checkbox-providers" >> template/shell_scripts/03_install_checkbox_sideload
    echo "_run sudo git -C /var/tmp/checkbox-providers clone $git_url -b $git_branch" >> template/shell_scripts/03_install_checkbox_sideload
    echo "_run sudo ls -alh /var/tmp/checkbox-providers" >> template/shell_scripts/03_install_checkbox_sideload
fi

if [ -n "$CHECKBOX_PPAS" ]; then
	#cat /dev/null > template/shell_scripts/02_Install_checkbox_deb_2_ppa  # remove default ppa
    
    for ppa in $CHECKBOX_PPAS; do 
    	echo "_run sudo add-apt-repository -y ${ppa}" >> template/shell_scripts/02_additional_ppa
    done
    
fi

# generate checkbox.conf and manifest.json based on configs in repo
update_checkbox_conf_manifest
if [ -n "$PLAINBOX_CONF" ]; then
	echo "Overwriting plainbox.conf in template/launcher_config/env.conf"
    echo "$PLAINBOX_CONF" > template/launcher_config/env.conf
fi
    
if [ -n "$MACHINE_MST_JSON" ]; then
	# merges with generator's config
    echo "$MACHINE_MST_JSON" > machine-manifest.json
    YAML_GEN_CMD+=" --manifestJson machine-manifest.json"
fi

if [ -n "$TEST_FLINGER_GLOBAL_TIMEOUT" ]; then
	YAML_GEN_CMD+=" --globalTimeout $TEST_FLINGER_GLOBAL_TIMEOUT"
fi

if [ "$AUTO_CREATE_BUGS" = "true" ]; then
	echo "TRUE from AUTO_CREATE_BUGS"
	echo "AUTO_CREATE_BUGS = true" | tee -a template/launcher_config/env.conf
    #echo "AUTO_CREATE_BUGS = true">>template/launcher_config/env.conf
    
    if [ -z "$AUTO_CREATE_BUGS_ASSIGNEE" ]; then
		echo "Please provide bug's Assignee ID"
        exit 4
    fi
    
    echo "AUTO_CREATE_BUGS_ASSIGNEE = $AUTO_CREATE_BUGS_ASSIGNEE" | tee -a template/launcher_config/env.conf
	#YAML_GEN_CMD+=" --LpID $AUTO_CREATE_BUGS_ASSIGNEE"
    # TODO: do we want to set longer reserve time? default 1200s
fi

if [ "$UPLOAD_REPORT" = "true" ]; then
	echo "UPLOAD_REPORT = true" | tee -a template/launcher_config/env.conf # Unused actually
    # now uploads by default.
    #TODO: if need disabled, update launcher conf before generating? or add generator flag to disable the uplaod?
fi

if [[ "$PREFIX_SUBMISSION_TARBALL" == *' '* ]]; then
	echo "Error: white spaces in PREFIX_SUBMISSION_TARBALL. Exit"
fi    
YAML_GEN_CMD+=" --sessionDesc $PREFIX_SUBMISSION_TARBALL"

# install missing packages
if [ -z "$(command -v testflinger-cli)" ]; then
    sudo snap install testflinger-cli
fi

if [ -z "$(command -v shellcheck)" ]; then
    sudo apt-get install -y shellcheck
fi

if [ -z "$(command -v jq)" ]; then
    sudo apt-get install -y jq
fi

# Generate job.yaml
./"$YAML_GENERATOR_EXE"  ${YAML_GEN_CMD}
cp "$JOB_YAML" "$WORKSPACE"
popd

echo "Generated $JOB_YAML content:==="
cat "$JOB_YAML"
echo "=== end ==="
rm -rf artifacts

#exit 10
JOB_ID=$(LC_ALL=C.UTF-8 LANG=C.UTF-8 PYTHONIOENCODING=utf-8 PYTHONUNBUFFERED=1 "$TESTFLINGER_EXE" submit -q "$JOB_YAML")
[ -n "$JOB_ID" ] || exit 1

echo "JOB_ID: ${JOB_ID}"
"$TESTFLINGER_EXE" poll ${JOB_ID}

TEST_STATUS=$("$TESTFLINGER_EXE" results ${JOB_ID} |jq -r .test_status)
[ "$TEST_STATUS" == "null" ] && exit 1
echo "Test exit status: ${TEST_STATUS}"

# Get artifacts from the TF agent
for i in 1 2 3 4 5; do
  testflinger-cli artifacts ${JOB_ID} || (sleep 30 && testflinger-cli artifacts ${JOB_ID})
  tar -xf artifacts.tgz
  ls -alh
done

if [ ! -d "hwcert-jenkins-tools" ]; then
  git clone --depth=1 https://github.com/canonical/hwcert-jenkins-tools.git
fi

# Create mail.title
cat <<EOF > mail.title
[Auto-Sanity]<Staging><EXCEPTION><$PROJECT> Auto generated by Jenkins
EOF

# Create summary.html
ls artifacts/
PROJECT=$(cat artifacts/ubuntu-report.log | jq -r .OEM.DCD)
mkdir -p artifacts
cat <<EOF > artifacts/summary.html
<html><head><style>table, th, td {font-family:Consolas,Ubuntu Mono,DejaVu Sans Mono,Bitstream Vera Sans Mono,Courier New, monospace; border: 1px solid black;}</style></head><body>Owner: $BUILD_USER<br>Jenkins build details:&nbsp;<a href=$BUILD_URL>$JOB_NAME/$BUILD_ID/</a><br><br><br>There is no result found because of the early fail within the build.<br>Usually this happens when a device join auto sanity for the first time, and the owener is trying to make it work.<br>Please check the build for more detail or contact the owner directly.<br><br></body></html>
EOF

echo Jenkins build details: ${BUILD_URL} > artifacts/summary
# no previous submission.json, so just produce summary with the existing file
hwcert-jenkins-tools/job-summary artifacts/submission.json artifacts/submission.json > artifacts/raw_summary
# TODO: set by pxu?
[ "$DGPU" == "TRUE" ] && hwcert-jenkins-tools/job-summary artifacts/submission_dgpu.json submission_dgpu.json.previous.$DISTRO_IMAGE > artifacts/raw_summary_dgpu
cat artifacts/raw_summary >> artifacts/summary
[ "$DGPU" == "TRUE" ] && cat artifacts/raw_summary_dgpu >> artifacts/summary_dgpu
echo >> artifacts/summary
[ "$DGPU" == "TRUE" ] && echo >> artifacts/summary_dgpu


#mail.title
#PROJECT=$(echo $JOB_NAME | awk -F sanity-3-testflinger- '{ print $2 }')
if [ ! -f artifacts/submission.json ]
then
  export GOPATH=$PWD/go
  go get github.com/bndr/gojenkins
  cd oem-tool
  go run buildlog.go --build_name=$JOB_NAME --build_no=$BUILD_ID
  cat output.file >> ../artifacts/summary
  cd -
  cat <<EOF > mail.title
[Auto-Sanity]<Staging><Error><$PROJECT> Auto generated by Jenkins
EOF
elif [ "0" == `awk '{for (I=1;I<=NF;I++) if ($I == "fail:") {print $(I+1)};}' artifacts/summary` ]
then
  PASS=`awk '{for (I=1;I<=NF;I++) if ($I == "pass:") {print $(I+1)};}' artifacts/summary`
  FAIL=`awk '{for (I=1;I<=NF;I++) if ($I == "fail:") {print $(I+1)};}' artifacts/summary`
  TOTAL=$(( PASS + FAIL ))
  cat <<EOF > mail.title
[Auto-Sanity]<Staging><All $TOTAL Pass><$PROJECT> Report auto generated by Jenkins
EOF
else
  PASS=`awk '{for (I=1;I<=NF;I++) if ($I == "pass:") {print $(I+1)};}' artifacts/summary`
  FAIL=`awk '{for (I=1;I<=NF;I++) if ($I == "fail:") {print $(I+1)};}' artifacts/summary`
  TOTAL=$(( PASS + FAIL ))
  cat <<EOF > mail.title
[Auto-Sanity]<Staging><$PASS/$TOTAL Pass><$PROJECT> Report auto generated by Jenkins
EOF
fi

GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no" git clone git+ssh://$BOT_USERNAME@git.launchpad.net/~lyoncore-team/lyoncore/+git/oem-tool -b master --depth 1
git -C oem-tool rev-parse HEAD
cp artifacts/summary oem-tool
cd oem-tool
mkdir -p ./oem-credential
cp $WORKSPACE/oem-credential/c3.credentials ./oem-credential/c3.credentials
#go run c3link.go --cid=$CID --owner=$BUILD_USER
cp summary.html $WORKSPACE/artifacts/

if [ "$DGPU" == "TRUE" ] && [ -n "$(cat $ARTIFACTS/glxinfo_dgpu.log  | grep "renderer string" | grep Intel)" ];then
	echo "ERROR: switch to dgpu failed"
    exit 1
fi

# prepare variables for oem-share upload
submission_file=$(find "$WORKSPACE/artifacts" -name 'submission_*tar.xz'| head -n 1)
if [ -n "$submission_file" ]; then
  _submission_file=${submission_file#*submission_*_}
  OEM_CODENAME=${_submission_file%%_*}
  _submission_file=${submission_file%_*_*_*_*.tar.xz}
  PLATFORM_CODENAME=${_submission_file##*_}
  #export UPLOAD_REPORT="$UPLOAD_REPORT"
  if [ ! "$PLATFORM_CODENAME" = "vm-instance" ] && [ "$UPLOAD_REPORT" = "true" ]; then
    echo "submission_file=$(basename "$submission_file")" > "$WORKSPACE/artifacts/oem-share-upload.env"
    echo "OEM_CODENAME=$OEM_CODENAME" >> "$WORKSPACE/artifacts/oem-share-upload.env"
    echo "PLATFORM_CODENAME=$PLATFORM_CODENAME" >> "$WORKSPACE/artifacts/oem-share-upload.env"
    
    #echo "DEBUG: oem-share-upload.env:"
	#cat "$WORKSPACE/artifacts/oem-share-upload.env"
  fi
fi



 
