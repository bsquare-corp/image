#!/bin/bash

# This script is intended to be executed by automation or humans
# under a hack/get_ci_vm.sh context.  Use under any other circumstances
# is unlikely to function.

set -e

if [[ -r "/etc/automation_environment" ]]; then
    source /etc/automation_environment
    source $AUTOMATION_LIB_PATH/common_lib.sh
else
    (
    echo "WARNING: It does not appear that containers/automation was installed."
    echo "         Functionality of most of ${BASH_SOURCE[0]} will be negatively"
    echo "         impacted."
    ) > /dev/stderr
fi

export "PATH=$PATH:$GOPATH/bin"

_run_setup() {
    req_env_vars SKOPEO_PATH SKOPEO_CI_BRANCH GOSRC BUILDTAGS

    project_module=$(go list .)

    make tools

    rm -rf "${SKOPEO_PATH}"
    git clone -b ${SKOPEO_CI_BRANCH} \
        https://github.com/containers/skopeo.git ${SKOPEO_PATH}

    cd "${SKOPEO_PATH}"
    if [[ -n "$SKOPEO_PR" ]] && [[ $SKOPEO_PR -gt 1000 ]]; then
        warn "Fetching and checking out code from skopeo pull-request #$SKOPEO_PR"
        git fetch origin "+refs/pull/$SKOPEO_PR/head"
        git checkout FETCH_HEAD
    fi

    msg "Replacing upstream skopeo $SKOPEO_CI_BRANCH branch $project_module module"
    go mod edit -replace ${project_module}=$GOSRC

    "${SKOPEO_PATH}/${SCRIPT_BASE}/runner.sh" setup
}

_run_image_tests() {
    req_env_vars GOPATH GOSRC

    # Tests in this repo. are intended to run as a regular user.
    ROOTLESS_USER="testuser$RANDOM"
    msg "Setting up rootless user '$ROOTLESS_USER'"
    cd $GOSRC || exit 1
    # Guarantee independence from specific values
    rootless_uid=$((RANDOM+1000))
    rootless_gid=$((RANDOM+1000))
    msg "Creating $rootless_uid:$rootless_gid $ROOTLESS_USER user"
    groupadd -g $rootless_gid $ROOTLESS_USER
    useradd -g $rootless_gid -u $rootless_uid --no-user-group --create-home $ROOTLESS_USER

    msg "Setting ownership of $GOPATH and $GOSRC"
    chown -R $ROOTLESS_USER:$ROOTLESS_USER "$GOPATH" "$GOSRC"

    msg "Creating ssh key pairs"
    mkdir -p "/root/.ssh" "/home/$ROOTLESS_USER/.ssh"
    ssh-keygen -t ed25519 -P "" -f "/root/.ssh/id_ed25519"

    msg "Setup authorized_keys"
    cat /root/.ssh/*.pub >> /home/$ROOTLESS_USER/.ssh/authorized_keys

    msg "Configure ssh file permissions"
    chmod -R 700 "/root/.ssh"
    chmod -R 700 "/home/$ROOTLESS_USER/.ssh"
    chown -R $ROOTLESS_USER:$ROOTLESS_USER "/home/$ROOTLESS_USER/.ssh"

    msg "Ensure the ssh daemon is up and running within 5 minutes"
    systemctl is-active sshd || \
       systemctl start sshd

    msg "Setup known_hosts for root"
    ssh-keyscan localhost > /root/.ssh/known_hosts \

    msg "Executing tests as $ROOTLESS_USER"
    showrun ssh $ROOTLESS_USER@localhost make -C $GOSRC test "BUILDTAGS='$BUILDTAGS'"
}

req_env_vars GOSRC

handler="_run_${1}"
if [ "$(type -t $handler)" != "function" ]; then
    die "Unknown/Unsupported command-line argument '$1'"
fi

msg "************************************************************"
msg "Runner executing $1 on $OS_REL_VER"
msg "************************************************************"

cd "$GOSRC"
$handler
