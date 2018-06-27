#!/bin/bash
#
# Copyright 2018 Google Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Usage:  source install.sh
#
# This script installs all the packages required to build Nucleus, and
# then builds Nucleus.  If the flag "--prereqs_only" is passed, only
# the prereqs will be installed and the nucleus build will be skipped.
#
# This script will run as-is on Ubuntu 14, Ubuntu 16, and Debian 9 systems.
# On all other systems, you will need to first install CLIF by following the
# instructions at https://github.com/google/clif#installation
#
# We also assume that apt-get is already installed and available.
#
# You have some options about how to (or whether to) install TensorFlow.
# If you care about that, you can read the pip_install_tensorflow function
# below, comment out the default option, and uncomment ONE of the other
# choices.

function pip_install_tensorflow {
  # Please uncomment ONE of the following options for installing TensorFlow.

  # 1) Do nothing; use a pre-installed version of TensorFlow.
  # The true is necessary; bash doesn't like empty functions.
  true

  # 2) Install a GPU-enabled version.
  # sudo -H pip install --upgrade 'tensorflow-gpu==1.7'

  # 3) Install a CPU-enabled version.  This is the default option.
  # sudo -H pip install --upgrade 'tensorflow==1.7'

  # 4) Install a Google Cloud Platform optimized CPU-only version of TensorFlow.
  # curl https://storage.googleapis.com/deepvariant/packages/tensorflow/tensorflow-1.7.0.deepvariant_gcp-cp27-none-linux_x86_64.whl > /tmp/my.whl && sudo -H pip install --upgrade /tmp/my.whl
}

function note_build_stage {
  echo "========== [$(date)] Stage '${1}' starting"
}

# Update package list
################################################################################
note_build_stage "Update package list"
sudo -H apt-get -qq -y update

# Install generic dependencies
################################################################################
note_build_stage "Update misc. dependencies"
sudo -H apt-get -y install pkg-config zip g++ zlib1g-dev unzip curl git lsb-release

# Install htslib dependencies
################################################################################
note_build_stage "Install htslib dependencies"
sudo -H apt-get -y install libssl-dev libcurl4-openssl-dev liblz-dev libbz2-dev liblzma-dev

# Install pip
################################################################################
note_build_stage "Update pip"
sudo -H apt-get -y install python-dev python-pip python-wheel
sudo -H pip install --upgrade pip

# Install python packages used by Nucleus
################################################################################
sudo -H pip install contextlib2
# sortedcontainers>=2.0.0 breaks intervaltree=2.1.0
# Remove this when https://github.com/chaimleib/intervaltree/pull/69
# is resolved.  Tracked internally at b/80085543.
sudo -H pip install 'sortedcontainers==1.5.3'
sudo -H pip install intervaltree
sudo -H pip install 'mock>=2.0.0'
sudo -H pip install 'numpy==1.14'
sudo -H pip install 'scipy==1.0'
sudo -H pip install 'six>=1.11.0'

# Install Java (required for Bazel)
################################################################################

note_build_stage "Install Java and friends"

# Java is available on Kokoro, so we add this cutout.
if ! java -version 2>&1 | fgrep "1.8"; then
  echo "No Java 8, will install."
  sudo -H apt-get install -y software-properties-common debconf-utils
  # Debian needs authentication.
  # (http://www.webupd8.org/2014/03/how-to-install-oracle-java-8-in-debian.html)
  [[ $(lsb_release -d | grep 'Debian') ]] && \
    sudo -H apt-get install -y gnupg dirmngr && \
    sudo -H apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys EEA14886
  sudo add-apt-repository -y ppa:webupd8team/java
  sudo -H apt-get -qq -y update
  echo "oracle-java8-installer shared/accepted-oracle-license-v1-1 select true" | sudo debconf-set-selections
  sudo -H apt-get install -y oracle-java8-installer
  sudo -H apt-get -y install ca-certificates-java
  sudo update-ca-certificates -f
else
  echo "Java 8 found, will not reinstall."
fi

# Install Bazel
################################################################################

note_build_stage "Install bazel"

function update_bazel_linux {
  BAZEL_VERSION=$1
  rm -rf ~/bazel
  mkdir ~/bazel

  pushd ~/bazel
  curl -L -O https://github.com/bazelbuild/bazel/releases/download/"${BAZEL_VERSION}"/bazel-"${BAZEL_VERSION}"-installer-linux-x86_64.sh
  chmod +x bazel-*.sh
  ./bazel-"${BAZEL_VERSION}"-installer-linux-x86_64.sh --user
  rm bazel-"${BAZEL_VERSION}"-installer-linux-x86_64.sh
  popd

  PATH="$HOME/bin:$PATH"
}

bazel_ver="0.11.0"
if
  v=$(bazel --bazelrc=/dev/null --nomaster_bazelrc version) &&
  echo "$v" | awk -v b="$bazel_ver" '/Build label/ { exit ($3 != b)}'
then
  echo "Bazel $bazel_ver already installed on the machine, not reinstalling"
else
  update_bazel_linux "$bazel_ver"
fi

# Install CLIF
################################################################################

note_build_stage "Install CLIF binary"

if [[ -e /usr/local/clif/bin/pyclif ]];
then
  echo "CLIF already installed."
else
  # Figure out which linux installation we are on to fetch an appropriate
  # version of the pre-built CLIF binary. Note that we only support now Ubuntu
  # 14, Ubuntu 16, and Debian 9.
  case "$(lsb_release -d)" in
    *Ubuntu*16.*.*)  PLATFORM="ubuntu-16" ;;
    *Ubuntu*14.*.*)  PLATFORM="ubuntu-14" ;;
    *Debian*9.*)     PLATFORM="debian" ;;
    *Debian*rodete*) PLATFORM="debian" ;;
    *) echo "CLIF is not installed on this machine and a prebuilt binary is not
unavailable for this platform. Please install CLIF at
https://github.com/google/clif before continuing."
    exit 1
  esac

  PACKAGE_CURL_PATH="https://storage.googleapis.com/deepvariant/packages"
  OSS_CLIF_CURL_ROOT="${PACKAGE_CURL_PATH}/oss_clif"
  OSS_CLIF_PKG="oss_clif.${PLATFORM}.latest.tgz"

  if [[ ! -f "/tmp/${OSS_CLIF_PKG}" ]]; then
    curl "${OSS_CLIF_CURL_ROOT}/${OSS_CLIF_PKG}" > /tmp/${OSS_CLIF_PKG}
  fi

  (cd / && sudo tar xzf "/tmp/${OSS_CLIF_PKG}")
  sudo ldconfig  # Reload shared libraries.
fi

# Download and build TensorFlow
################################################################################
note_build_stage "Download and build TensorFlow"

(cd .. &&
 git clone https://github.com/tensorflow/tensorflow &&
 cd tensorflow &&
 git checkout v1.7.0 &&
 echo | ./configure &&
 pip_install_tensorflow
 )


echo "Done installing prereqs at $(date)!"

if [[ "$1" != "--prereqs_only" ]]; then
  # Build Nucleus
  ################################################################################
  note_build_stage "Building Nucleus"

  COPT_FLAGS="--copt=-msse4.1 --copt=-msse4.2 --copt=-mavx --copt=-O3"
  bazel build -c opt ${COPT_FLAGS} nucleus/...

  bazel build :licenses_zip

fi

# Done!
################################################################################
echo "Installation complete at $(date)!"
