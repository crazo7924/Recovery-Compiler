#!/bin/bash

printf "\e[1;32m \u2730 Recovery compiler\e[0m\n\n"

# Echo Loop
while ((${SECONDS_LEFT:=10} > 0)); do
    printf "Please wait for %.fs ...\n" "${SECONDS_LEFT}"
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
    VenCode=$(echo ${GITHUB_REPOSITORY#*/} | sed 's/android_device_//;')
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
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

sudo apt-get -qqy update &>/dev/null
sudo apt-get -qqy install --no-install-recommends \
    bc bison build-essential ccache curl flex g++-multilib gcc-multilib \
    git gnupg gperf imagemagick lib32ncurses5-dev lib32readline-dev lib32z1-dev liblz4-tool \
    libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev libxml2 libxml2-utils lzop \
    pngcrush rsync schedtool squashfs-tools xsltproc zip zlib1g-dev \
    &>/dev/null
printf "Cleaning some programs...\n"
sudo apt-get -qqy purge default-jre-headless openjdk-11-jre-headless &>/dev/null
sudo apt-get -qy clean &>/dev/null && sudo apt-get -qy autoremove &>/dev/null
sudo rm -rf -- /var/lib/apt/lists/* /var/cache/apt/archives/* &>/dev/null
echo "::endgroup::"

echo "::group::Installation of git-repo tool"
cd /home/runner || exit 1
printf "Adding latest stable git-repo ...\n"
curl -sL https://gerrit.googlesource.com/git-repo/+/refs/heads/stable/repo?format=TEXT | base64 --decode  > repo
chmod a+rx ./repo && sudo mv ./repo /usr/local/bin/
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
repo sync -c -q --force-sync --no-clone-bundle --no-tags -j$(nproc --all) || { printf "Git-Repo Sync Failed.\n"; exit 1; }

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
. build/envsetup.sh
# A workaround for non-zero exit status because roomservice isn't done properly
lunch twrp_${CODENAME}-${FLAVOR} || true
echo "::endgroup::"

echo "::group::Compilation"
mka ${TARGET} -j$(nproc --all) || { printf "Compilation failed.\n"; exit 1; }
echo "::endgroup::"

# Export VENDOR, CODENAME and BuildPath for next steps
echo "VENDOR=${VENDOR}" >> ${GITHUB_ENV}
echo "CODENAME=${CODENAME}" >> ${GITHUB_ENV}
echo "BuildPath=/home/runner/builder" >> ${GITHUB_ENV}

