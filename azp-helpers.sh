#!/bin/bash

# Read pipelines env variables
source "${BASH_SOURCE%/*}/variables.sh"

# Print helper
function print_section() {
    # Center the msg
    fmt_str="##########################################################"
    fmt_len=${#fmt_str}
    msg_len=${#1}
    pad=$(((fmt_len-msg_len)/2))
    lead=$((msg_len+pad))
    echo ""
    echo ""
    echo ""
    echo "##########################################################"
    echo "#--------------------------------------------------------#"
    printf "%${lead}s \n" "$1"
    echo "#--------------------------------------------------------#"
    echo "##########################################################"
    echo ""
    echo ""
}

function global_variables_pipeline() {
    print_section "Setting pipeline variables"
    echo "##vso[task.setvariable variable=DEPLOY_ARTIFACTS_DIR;]${DEPLOY_ARTIFACTS_DIR}"
    echo "##vso[task.setvariable variable=SSTATE_DIR;]${SSTATE_DIR}"
    echo "##vso[task.setvariable variable=SSTATE_MIRRORS_DIR;]${SSTATE_MIRRORS_DIR}"
    check_freespace
}

function free_space_packages() {

    print_section "Removing unused packages"
    ###
    ###  Since we'll be upgrading later, we need to remove anything we dont want so we dont upgrade it either
    ###


    UNUSED_PACKAGES=" \
    ?name(adoptopenjdk.*) \
    ?name(ansible.*) \
    ?name(azure-cli.*) \
    ?name(bazel.*) \
    ?name(buildah.*) \
    ?name(cabal.*) \
    ?name(clang-.*) \
    ?name(containernetworking-plugins.*) \
    ?name(cpp-.*) \
    ?name(dotnet-apphost.*) \
    ?name(dotnet-runtime.*) \
    ?name(dotnet-sdk.*) \
    ?name(dotnet-targeting.*) \
    ?name(firefox.*) \
    ?name(g++-10.*) \
    ?name(g++-11.*) \
    ?name(g++-9.*) \
    ?name(gcc-10.*) \
    ?name(gcc-11.*) \
    ?name(gcc-9.*) \
    ?name(gfortran.*) \
    ?name(git-man.*) \
    ?name(gh.*) \
    ?name(ghc.*) \
    ?name(google-chrome-stable.*) \
    ?name(google-cloud-sdk.*) \
    ?name(google-cloud-cli.*) \
    ?name(google-cloud-cli-anthoscli.*) \
    ?name(hhvm.*) \
    ?name(initramfs-tools.*) \
    ?name(iso-codes.*) \
    ?name(isocodes.*) \
    ?name(kubectl.*) \
    ?name(libclang-common.*) \
    ?name(libclang-cpp.*) \
    ?name(libclang1.*) \
    ?name(libicu.*) \
    ?name(libldb.*) \
    ?name(libllvm.*) \
    ?name(libruby.*) \
    ?name(libsbt-launcher-interface-java.*) \
    ?name(libx265-199.*) \
    ?name(libxml2.*) \
    ?name(linux-azure-.*) \
    ?name(linux-cloud.*) \
    ?name(linux-headers.*) \
    ?name(linux-image.*) \
    ?name(linux-modules.*) \
    ?name(linux-tools.*) \
    ?name(llvm-.*) \
    ?name(mecab-ipadic.*) \
    ?name(mercurial.*) \
    ?name(microsoft-edge-stable.*) \
    ?name(moby.*) \
    ?name(mongodb.*) \
    ?name(mono.*) \
    ?name(mysql.*) \
    ?name(netstandard-targeting-pack.*) \
    ?name(nginx.*) \
    ?name(openjdk.*) \
    ?name(podman.*) \
    ?name(postgresql.*) \
    ?name(powershell.*) \
    ?name(python-babel.*) \
    ?name(r-base-core.*) \
    ?name(referenceassemblies.*) \
    ?name(ruby2.*) \
    ?name(skopeo.*) \
    ?name(snapd.*) \
    ?name(temurin.*) \
    ?name(vim.*) \
    "

    sudo DEBIAN_FRONTEND=noninteractive apt update

    # Only show output if cmd doesnt execute successfully
    echo ""
    echo "Purging unused packages..."
    aptOutput=$(sudo DEBIAN_FRONTEND=noninteractive apt purge ${UNUSED_PACKAGES})
    if [ $? -ne 0 ]; then
        echo ${aptOutput}
    fi
}

function analyze_storage() {
    print_section "Analyzing Storage"
    # sudo DEBIAN_FRONTEND=noninteractive apt -yq install durep wajig >/dev/null
    # print_section "Largest packages"
    # wajig large
    print_section "Largest files (dh/du)"
    df -h
    du -Sh / 2>/dev/null | sort -rh | head -n 200
    du -akS -d 4  / 2>/dev/null | sort -n -r | head -n 50
    # print_section "Largest files durep"
    # durep -td 3 /
}

function setup_yp_deps() {
    free_space_packages
    print_section "Installing Yocto Project Dependencies"
    ###
    ###  Install YP dependencies
    ###
    sudo DEBIAN_FRONTEND=noninteractive apt-mark hold grub-efi-amd64-bin
    sudo DEBIAN_FRONTEND=noninteractive apt-mark hold grub-efi-amd64-signed
    sudo DEBIAN_FRONTEND=noninteractive apt update
    sudo DEBIAN_FRONTEND=noninteractive apt upgrade

    YP_DEPS=" \
    gawk \
    wget \
    git-core \
    diffstat \
    unzip \
    texinfo \
    gcc-multilib \
    build-essential \
    chrpath \
    socat \
    cpio \
    python3 \
    python3-pip \
    python3-pexpect \
    xz-utils \
    debianutils \
    iputils-ping \
    python3-git \
    python3-jinja2 \
    libegl1-mesa \
    libsdl1.2-dev \
    pylint \
    xterm \
    python3-subunit \
    mesa-common-dev \
    lz4 \
    zstd \
    "

    # Dependencies from the Yocto Quickstart
    retries=0
    until [ "$retries" -ge 3 ]
    do
        sudo DEBIAN_FRONTEND=noninteractive apt install ${YP_DEPS}
        ECODE=$?
        if [ $ECODE -eq 0 ]; then
            break
        fi
        retries=$((retries+1))
        echo "ERROR: Failed to install dependencies, trying again..."
        sleep 10
    done
    if [ $ECODE -ne 0 ]; then
        echo "ERROR: Failed to install dependencies, error: $ECODE"
        exit $ECODE
    fi
}

function check_freespace() {
    print_section "Free Space Available"
    df -h
}

function cleanup_leftover_deps() {
    print_section "Cleanup leftover dependencies"

    sudo DEBIAN_FRONTEND=noninteractive apt autoremove --purge
    sudo DEBIAN_FRONTEND=noninteractive apt autoclean
    sudo DEBIAN_FRONTEND=noninteractive apt clean
}

function purge_space () {

    print_section "Purging container space"
    ###
    ###  Remove files kept to free up even more space
    ###
    #### There are a lot of tools that we dont need inside the container

    export TOFREE=" \
    /home/linuxbrew/.linuxbrew/ \
    /home/vsts/agents/*.tgz \
    /home/vsts/agents/2.150.3/ \
    /home/vsts/agents/2.152.0/ \
    /home/vsts/agents/2.152.1/ \
    /home/vsts/agents/2.160.1/ \
    /home/vsts/agents/2.162.0/ \
    /home/vsts/agents/2.171.1/ \
    /home/vsts/.rustup/ \
    /etc/skel/.rustup/ \
    /usr/share/sbt/bin \
    /imagegeneration/ \
    /opt/* \
    /usr/lib/cgi-bin \
    /usr/lib/firefox \
    /usr/lib/google-cloud-sdk \
    /usr/lib/heroku \
    /usr/lib/jvm \
    /usr/lib/mono \
    /usr/lib/monodoc \
    /usr/lib/php* \
    /usr/lib32/gconv \
    /usr/libx32/gconv \
    /usr/local/.ghcup/ \
    /usr/local/aws-cli/ \
    /usr/local/bin/ \
    /usr/local/doc/ \
    /usr/local/go* \
    /usr/local/graalvm/ \
    /usr/local/julia*/ \
    /usr/local/lib/android/ \
    /usr/local/lib/android/ \
    /usr/local/lib/heroku/ \
    /usr/local/lib/node* \
    /usr/local/n/ \
    /usr/local/share/ \
    /usr/local/share/chromium/ \
    /usr/local/share/powershell/ \
    /usr/local/sqlpackage \
    /usr/share/apache-maven-3.6.2/ \
    /usr/share/az_1* \
    /usr/share/az_2.3* \
    /usr/share/doc/ \
    /usr/share/docs \
    /usr/share/dotnet \
    /usr/share/gradle* \
    /usr/share/icons/ \
    /usr/share/kotlinc/ \
    /usr/share/man \
    /usr/share/miniconda/ \
    /usr/share/rust \
    /usr/share/swift/ \
    /usr/share/swift/ \
    /usr/share/vim/ \
    /var/cache/apt/ \
    /var/lib/apt/lists \
    "
    # This cant be done in parallel
    echo "Removing:"
    for i in ${TOFREE};do echo "$i"; sudo rm -rf $i; done;
}

function create_local_dirs() {
    print_section "Creating local directories"
    ###
    ###  Create local directories
    ###
    sudo mkdir ${DL_DIR}
    sudo mkdir ${SSTATE_DIR}
    sudo mkdir ${SSTATE_MIRRORS_DIR}
    sudo mkdir ${DEPLOY_ARTIFACTS_DIR}
    sudo chown vsts:vsts ${SSTATE_DIR}
    sudo chown vsts:vsts ${DL_DIR}
    sudo chown vsts:vsts ${SSTATE_MIRRORS_DIR}
    sudo chown vsts:vsts ${DEPLOY_ARTIFACTS_DIR}
    if [ "$(ls -A ~/work/1/base-artifacts)" ]; then
        mv ~/work/1/base-artifacts/* ${SSTATE_DIR}/
    fi
    check_freespace
}

function localconf() {

    cd ~/
    source openembedded-core/oe-init-build-env
    echo "SSTATE_DIR = \"${SSTATE_DIR}\"" >> ./conf/local.conf
    echo "DL_DIR = \"${DL_DIR}\"" >> ./conf/local.conf
    if [ ! -z "${DISTRO}" ]; then
        echo "DISTRO = \"${DISTRO}\"" >> ./conf/local.conf
    fi
    if [ ! -z "${TCLIBC}" ]; then
        echo "TCLIBC = \"${TCLIBC}\"" >> ./conf/local.conf
    fi

    ###
    ###  Sstate and Downloads fetching
    ###

    # Use pipeline artifact
    echo "SSTATE_MIRRORS = \" file://.* file://${SSTATE_MIRRORS_DIR}PATH\"" >> ./conf/local.conf

    # # Keep for compatibility, az fetcher sstate and downloads
    # if [ ! -z "${AZ_SAS}" ]; then
    #     echo "AZ_SAS = \"${AZ_SAS}\"" >> ./conf/local.conf
    #     echo "SSTATE_MIRRORS=\" file://.* az://ypcache.blob.core.windows.net/sstate-cache/PATH;downloadfilename=PATH \n\"" >> ./conf/local.conf
    #     # echo "PREMIRRORS:prepend=\" git://.*/.* az://sstate.blob.core.windows.net/downloads/ \n ftp://.*/.* az://sstate.blob.core.windows.net/downloads/ \n http://.*/.* az://sstate.blob.core.windows.net/downloads/ \n https://.*/.* az://sstate.blob.core.windows.net/downloads/ \n \"" >> ./conf/local.conf

    #     Override fetch command to increase timeout
    #     echo "FETCHCMD_wget=\"/usr/bin/env wget -d --retry-connrefused --waitretry=10 -t 30 -T 60 --passive-ftp\"" >> ./conf/local.conf
    # fi

    ###
    ###  Slower builds but more space
    ###
    if [ "${RMWORK}" != "0" ]; then
        echo "INHERIT += \"rm_work\"" >> ./conf/local.conf
    fi
}


function clone_layers() {
    print_section "Cloning Yocto Project"
    if [ ! -z ${SELF} ]; then
        echo "Cloning submodules"
        cd ${SELF}
        git submodule update --init --recursive
    fi
    
    if [ -z ${GITHUB} ]; then
        GITHUB=0
    fi
    if [ "${GITHUB}" -ne 1 ]; then
        if [ "${BRANCH}" == "scarthgap" ]; then
            BRANCHNAME=${BRANCH}
        elif [ "${BRANCH}" == "scarthgap-next" ]; then
            BRANCHNAME="scarthgap"
        elif [ "${BRANCH}" == "master-next" ]; then
            BRANCHNAME="master"
        else
            BRANCHNAME="master"
        fi
    else
        BRANCHNAME=${BRANCH}
    fi

    print_section "Building Yocto Project branch: ${BRANCHNAME}"

    cd ~
    for layer in "$@"
    do
        echo "Processing ${layer}"
        case ${layer} in
            oe-core )
                ###
                ###  In case we need local changes
                ###
                if [ "${GITHUB}" -ne 1 ]; then
                    echo "Cloning from OE"
                    git clone https://git.openembedded.org/openembedded-core -b ${BRANCHNAME}
                    git clone https://git.openembedded.org/bitbake -b ${BRANCHNAME}
                else
                    echo "Cloning from Github"
                    git clone https://github.com/ahcbb6/poky.git -b ${BRANCHNAME}
                fi
                cd openembedded-core/
                # Print out where we were before rebase
                git show
                # Add Az fetcher to Dunfell
                # git config --global user.email "you@example.com"
                # git config --global user.name "Your Name"
                # git remote add gh https://github.com/aehs29/poky.git
                # git fetch gh
                # git checkout gh/azfetcher-fixes-${BRANCHNAME} -b azfetcher-fixes-${BRANCHNAME}
                # git rebase master
                git log --pretty=oneline -n 20
                cd -
                ;;
            yocto )
                git clone https://git.yoctoproject.org/meta-yocto -b ${BRANCHNAME}
                ;;
            intel )
                git clone https://git.yoctoproject.org/git/meta-intel -b ${BRANCHNAME}
                ;;
            oe )
                git clone https://git.openembedded.org/meta-openembedded -b ${BRANCHNAME}
                ;;
            *)
                echo "Requested layer is not known"
                ;;
        esac
    done
}

function add_layers() {
    print_section "Creating bblayers.conf"
    find ~/
    for layer in "$@"
    do
        echo "Processing ${layer}"
        case ${layer} in
            oe-core )
                LAYER="../openembedded-core"
                ;;
            intel )
                LAYER="../meta-intel"
                ;;
            oe )
                LAYER="../meta-openembedded/meta-oe"
                ;;
            python )
                LAYER="../meta-openembedded/meta-python"
                ;;
            networking )
                LAYER="../meta-openembedded/meta-networking"
                ;;
            skeleton )
                LAYER="../meta-skeleton"
                ;;
            freertos )
                LAYER="${SELF}/layers/meta-freertos"
                ;;
            yocto )
                LAYER="../meta-yocto/meta-yocto-bsp"
                ;;
            poky )
                LAYER="../meta-yocto/meta-poky"
                ;;
            *)
                echo "Requested layer: ${layer} is not known"
                ;;
        esac
        bitbake-layers add-layer ${LAYER}
        ECODE=$?
        if [ $ECODE -ne 0 ]; then
            exit 1
        fi
    done
    
    if [ ! -z "${SELF}" ]; then
        bitbake-layers add-layer ${SELF}
    fi
    cat conf/bblayers.conf
}

function sync_sstate() {

    print_section "Shared State Sync"

    export AZCOPY_VERSION="10"
    wget -O azcopy_v$AZCOPY_VERSION.tar.gz https://aka.ms/downloadazcopy-v$AZCOPY_VERSION-linux && tar -xf azcopy_v$AZCOPY_VERSION.tar.gz  --strip-components=1

    if [ -z "${SASW_TOKEN}" ]; then
        echo "No Shared Access Token provided"
        echo "##vso[task.logissue type=error;]No Shared Access Token provided"
        exit 0
    fi
    retries=0
    until [ "$retries" -ge 3 ]
    do
        ./azcopy sync ${SSTATE_DIR} --recursive "https://ypcache.blob.core.windows.net/sstate-cache${SASW_TOKEN}"
        ECODE=$?
        if [ $ECODE -eq 0 ]; then
            break
        fi
        retries=$((retries+1))
        echo "Uploading sstate artifacts failed (try #$retries), retrying ..."
        sleep 10
    done
    if [ $ECODE -ne 0 ]; then
        echo "Couldn't upload build cache, error: $ECODE"
        exit $ECODE
    fi
}

# Useful to poke around in a pipeline container (update packages to remove)
function create_ssh_tunnel(){
    print_section "Creating ssh tunnel to ${IP} for user:${SSHUSER}"
    mkdir -p ~/.ssh/
    chmod 700 ~/.ssh/
    echo "Adding authorized pub key"
    echo "${PUBKEY}" >> ~/.ssh/authorized_keys

    echo "Setting permissions"
    chmod 0600 ~/.ssh/authorized_keys

    echo "Setting password"
    echo "Changing password"
    echo "vsts:vsts" | sudo chpasswd
    # TODO: create key
    # chmod 0400 ~/.ssh/key.pem

    echo "Creating tunnel"
    sshpass -p vsts ssh -tt  -o StrictHostKeyChecking=no -fN -R 7777:localhost:22 ${SSHUSER}@${IP} -i ~/.ssh/key.pem

    print_section "Sleeping..."
    sleep 6000
}
