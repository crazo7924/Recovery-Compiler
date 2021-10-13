#!/bin/bash

printf "\e[1;32m \u2730 Recovery compiler\e[0m\n\n"

# Echo Loop
while ((${SECONDS_LEFT:=10} > 0)); do
    printf "Please wait %.fs ...\n" "${SECONDS_LEFT}"
    sleep 1
    SECONDS_LEFT=$((SECONDS_LEFT - 1))
done
unset SECONDS_LEFT

echo "::group::Free space check-up"
if [[ ! $(df / --output=avail | tail -1 | awk '{print $NF}') -ge 41943040 ]]; then
    printf "Please use 'slimhub_actions@main' to gain at least 40 GB space\n"
    exit 1
else
    printf "You have %s space available\n" "$(df -h / --output=avail | tail -1 | awk '{print $NF}')"
fi
echo "::endgroup::"

echo "::group::Mandatory variables check-up"
if [[ -z ${MANIFEST} ]]; then
    printf "Please provide a valid repo manifest URL\n"
    exit 1
fi
if [[ -z ${VENDOR} || -z ${CODENAME} ]]; then
    # Assume the workflow runs in the device tree
    # And the naming is exactly like android_device_vendor_codename
    VenCode=$(echo ${GITHUB_REPOSITORY#*/} | sed 's/android_device_//;s//;')
    export VENDOR=$(echo ${VenCode} | cut -d'_' -f1)
    export CODENAME=$(echo ${VenCode} | cut -d'_' -f2-)
    unset VenCode
fi
if [[ -z ${DT_LINK} ]]; then
    # Assume the workflow runs in the device tree with the current checked-out branch
    DT_BR=${GITHUB_REF##*/}
    export DT_LINK="https://github.com/${GITHUB_REPOSITORY} -b ${DT_BR}"
    unset DT_BR
fi
# Default TARGET will be recoveryimage if not provided
export TARGET=${TARGET:-recoveryimage}
# Default FLAVOR will be eng if not provided
export FLAVOR=${FLAVOR:-eng}
# Default TZ (Timezone) will be set as UTC if not provided
export TZ=${TZ:-UTC}
if [[ ! ${TZ} == "UTC" ]]; then
    sudo timedatectl set-timezone ${TZ}
fi
echo "::endgroup::"

printf "We are going to build ${TARGET} for ${CODENAME} from the OEM ${VENDOR}\n"

echo "::group::Installation of required programs"
export \
    DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    JAVA_OPTS=" -Xmx7G " JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
sudo apt-get -qqy update &>/dev/null
sudo apt-get -qqy install --no-install-recommends \
    lsb-core lsb-security patchutils bc \
    android-sdk-platform-tools adb fastboot \
    openjdk-8-jdk ca-certificates-java maven \
    python-all-dev python-is-python2 \
    lzip lzop xzdec pixz libzstd-dev lib32z1-dev \
    exfat-utils exfat-fuse \
    gcc gcc-multilib g++-multilib clang llvm lld cmake ninja-build \
    libxml2-utils xsltproc expat re2c libxml2-utils xsltproc expat re2c \
    libreadline-gplv2-dev libsdl1.2-dev libtinfo5 xterm rename schedtool bison gperf libb2-dev \
    pngcrush imagemagick optipng advancecomp \
    &>/dev/null
printf "Cleaning some programs...\n"
sudo apt-get -qqy purge default-jre-headless openjdk-11-jre-headless &>/dev/null
sudo apt-get -qy clean &>/dev/null && sudo apt-get -qy autoremove &>/dev/null
sudo rm -rf -- /var/lib/apt/lists/* /var/cache/apt/archives/* &>/dev/null
echo "::endgroup::"

echo "::group::Installation of git-repo and ghr"
cd /home/runner || exit 1
printf "Adding latest stable git-repo and ghr binary...\n"
curl -sL https://gerrit.googlesource.com/git-repo/+/refs/heads/stable/repo?format=TEXT | base64 --decode  > repo
curl -s https://api.github.com/repos/tcnksm/ghr/releases/latest | jq -r '.assets[] | select(.browser_download_url | contains("linux_amd64")) | .browser_download_url' | wget -qi -
tar -xzf ghr_*_amd64.tar.gz --wildcards 'ghr*/ghr' --strip-components 1 && rm -rf ghr_*_amd64.tar.gz
chmod a+rx ./repo && chmod a+x ./ghr && sudo mv ./repo ./ghr /usr/local/bin/
echo "::endgroup::"

echo "::group::Make symlink of libncurses v5 to v6"
if [ -e /lib/x86_64-linux-gnu/libncurses.so.6 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libncurses.so.5 ]; then
    ln -s /lib/x86_64-linux-gnu/libncurses.so.6 /usr/lib/x86_64-linux-gnu/libncurses.so.5
fi
export \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TERM=xterm-256color
. /home/runner/.bashrc 2>/dev/null
printf "All preparation to build is done!\n"
echo "::endgroup::"

# Switch to an absolute path
mkdir -p /home/runner/builder &>/dev/null
cd /home/runner/builder || exit 1

echo "::group::Perform repo sync"
printf "Initializing Repo\n"
printf "We will be using %s as the manifest source\n" "${MANIFEST}"
repo init -q -u ${MANIFEST} --depth=1 --groups=all,-notdefault,-device,-darwin,-x86,-mips || { printf "Repo Initialization Failed.\n"; exit 1; }
repo sync -c -q --force-sync --no-clone-bundle --no-tags -j6 || { printf "Git-Repo Sync Failed.\n"; exit 1; }

echo "::endgroup::"

echo "::group::Clone the device trees"
printf "Cloning the device tree...\n"
git clone ${DT_LINK} --depth=1 device/${VENDOR}/${CODENAME}
if [[ ! -z "${KERNEL_LINK}" ]]; then
    printf "Kernel will be compiled from sources.\n"
    git clone ${KERNEL_LINK} --depth=1 kernel/${VENDOR}/${CODENAME}
else
    printf "Using pre-built kernel For the build.\n"
fi
echo "::endgroup::"

echo "::group::Execute extra commands"
if [[ ! -z "$EXTRA_CMD" ]]; then
    printf "Executing the extra commands...\n"
    eval "${EXTRA_CMD}"
    cd /home/runner/builder || exit
fi
echo "::endgroup::"

echo "::group::Prepare for compilation"
printf "Compiling Recovery...\n"
export ALLOW_MISSING_DEPENDENCIES=true
source build/envsetup.sh
# A workaround for non-zero exit status because roomservice isn't done properly
lunch twrp_${CODENAME}-${FLAVOR} || true
echo "::endgroup::"

echo "::group::Compilation"
mka ${TARGET} || { printf "Compilation failed.\n"; exit 1; }
echo "::endgroup::"
