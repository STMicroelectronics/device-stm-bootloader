#!/bin/bash
#
# Load primary and secondary bootloader source

# Copyright (C)  2019. STMicroelectronics
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#######################################
# Constants
#######################################
SCRIPT_VERSION="1.2"

SOC_FAMILY="stm32mp1"
SOC_NAME="stm32mp15"
SOC_VERSIONS=( "stm32mp157c" "stm32mp157f" )

DEFAULT_FSBL_VERSION=2.2
DEFAULT_SSBL_VERSION=2020.01

if [ -n "${ANDROID_BUILD_TOP+1}" ]; then
  TOP_PATH=${ANDROID_BUILD_TOP}
elif [ -d "device/stm/${SOC_FAMILY}-bootloader" ]; then
  TOP_PATH=$PWD
else
  echo "ERROR: ANDROID_BUILD_TOP env variable not defined, this script shall be executed on TOP directory"
  exit 1
fi

\pushd ${TOP_PATH} >/dev/null 2>&1

BOOTLOADER_PATH="${TOP_PATH}/device/stm/${SOC_FAMILY}-bootloader"
COMMON_PATH="${TOP_PATH}/device/stm/${SOC_FAMILY}"

FSBL_PATCH_PATH="${BOOTLOADER_PATH}/source/patch/fsbl"
FSBL_CONFIG_FILE="android_fsbl.config"

SSBL_PATCH_PATH="${BOOTLOADER_PATH}/source/patch/ssbl"
SSBL_CONFIG_FILE="android_ssbl.config"

BOOTLOADER_CONFIG_STATUS_PATH="${COMMON_PATH}/configs/bootloader.config"

#######################################
# Variables
#######################################
force_load=0
do_ssbl_load=1
do_fsbl_load=1
nb_states=2

#######################################
# Functions
#######################################

#######################################
# Add empty line in stdout
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
empty_line()
{
  echo
}

#######################################
# Print script usage on stdout
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
usage()
{
  echo "Usage: `basename $0` [Options] [Exclusive Options]"
  empty_line
  echo "  This script allows loading bootloaders source (TF-A and/or U-Boot)"
  echo "  based on the configuration file associated"
  empty_line
  echo "Options:"
  echo "  -h / --help: print this message"
  echo "  -v / --version: get script version"
  echo "  -f / --force: force bootloader load"
  echo "Exclusive 0ptions:"
  echo "  -p / --pbl: load only the first primary bootloader (TF-A)"
  echo "or"
  echo "  -s / --sbl: load only the second secondary bootloader (U-Boot)"
  empty_line
}

#######################################
# Print error message in red on stderr
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
error()
{
  echo "$(tput setaf 1)ERROR: $1$(tput sgr0)"  >&2
}

#######################################
# Print message in blue on stdout
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
blue()
{
  echo "$(tput setaf 6)$1$(tput sgr0)"
}

#######################################
# Print message in green on stdout
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
green()
{
  echo "$(tput setaf 2)$1$(tput sgr0)"
}

#######################################
# Clear current line in stdout
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
clear_line()
{
  echo -ne "\033[2K"
}

#######################################
# Print state message on stdout
# Globals:
#   I nb_states
#   I/O action_state
# Arguments:
#   None
# Returns:
#   None
#######################################
action_state=1
state()
{
  clear_line
  echo -ne "  [${action_state}/${nb_states}]: $1 \033[0K\r"
  action_state=$((action_state+1))
}

#######################################
# Clean before exit
# Globals:
#   I bootloader_path
#   I msg_patch
# Arguments:
#   $1: ERROR or OK
# Returns:
#   None
#######################################
teardown() {

  if [[ "$1" == "ERROR" ]]; then
      \pushd $TOP_PATH >/dev/null 2>&1
      \rm -rf ${bootloader_path}
      \popd >/dev/null 2>&1
  fi

  if [[ ${msg_patch} == 1 ]]; then
    \popd >/dev/null 2>&1
  fi

  # Come back to original directory
  \popd >/dev/null 2>&1
}

#######################################
# Check Bootloader status within the status file
# Globals:
#   I BOOTLOADER_CONFIG_STATUS_PATH
# Arguments:
#   $1 Bootloader tag
# Returns:
#   1 if Bootloader is already loaded
#   0 if Bootloader is not already loaded
#######################################
check_bootloader_status()
{
  local loc_bootloader_status

  \ls ${BOOTLOADER_CONFIG_STATUS_PATH} &> /dev/null
  if [ $? -eq 0 ]; then
    loc_bootloader_status=`grep $1 ${BOOTLOADER_CONFIG_STATUS_PATH}`
    if [[ ${loc_bootloader_status} =~ "LOADED" ]]; then
      return 1
    fi
  fi
  return 0
}

#######################################
# Apply selected patch in current target directory
# Globals:
#   I BOOTLOADER_PATCH_PATH
#   I bootloader_version
# Arguments:
#   $1: patch
# Returns:
#   None
#######################################
apply_patch()
{
  local loc_patch_path

  loc_patch_path="${BOOTLOADER_PATCH_PATH}/"
  loc_patch_path+="${bootloader_version}/"
  loc_patch_path+=$1
  if [ "${1##*.}" != "patch" ];then
    loc_patch_path+=".patch"
  fi

  \git am ${loc_patch_path} &> /dev/null
  if [ $? -ne 0 ]; then
    error "Not possible to apply patch ${loc_patch_path}, please review android_xxxx.config"
    teardown "ERROR"
    exit 1
  fi
}

#######################################
# Load bootloader based on configuration file BOOTLOADER_CONFIG_PATH
# Globals:
#   I BOOTLOADER_CONFIG_PATH
#   O bootloader_path
#   O bootloader_version
#   I/O msg_patch
# Arguments:
#   None
# Returns:
#   None
#######################################
load_bootloader()
{

  local bootloader_name="$1"

  # Start Bootloader config file parsing
  while IFS='' read -r line || [[ -n $line ]]; do

    echo $line | grep '^BOOTLOADER_' >/dev/null 2>&1

    if [ $? -eq 0 ]; then

      line=$(echo "${line: 11}")

      unset bootloader_value
      bootloader_value=($(echo $line | awk '{ print $1 }'))

      case ${bootloader_value} in
        "VERSION" )
          bootloader_version=($(echo $line | awk '{ print $2 }'))
          ;;
        "GIT_PATH" )
          git_path=($(echo $line | awk '{ print $2 }'))
          state "Loading the ${bootloader_name} bootloader source (it can take several minutes)"
          \rm -rf ${bootloader_path}  >/dev/null 2>&1
          if [ -n "${bootloader_cache+1}" ]; then
            \git clone -b v${bootloader_version} --reference ${bootloader_cache} ${git_path} ${bootloader_path} >/dev/null 2>&1
          else
            \git clone -b v${bootloader_version} ${git_path} ${bootloader_path} >/dev/null 2>&1
          fi
          if [ $? -ne 0 ]; then
            error "Not possible to clone module from ${git_path}"
            teardown "ERROR"
            exit 1
          fi
          ;;
        "GIT_SHA1" )
          git_sha1=($(echo $line | awk '{ print $2 }'))
          \pushd ${bootloader_path} >/dev/null 2>&1
          \git checkout ${git_sha1} >/dev/null 2>&1
          if [ $? -ne 0 ]; then
            error "Not possible to checkout ${git_sha1} for ${git_path}"
            teardown "ERROR"
            exit 1
          fi
          \popd >/dev/null 2>&1
          ;;
      "ARCHIVE_PATH" )
        archive_path=($(echo $line | awk '{ print $2 }'))
        state "Loading the ${bootloader_name} bootloader source (it can take several minutes)"
        \mkdir -p ${bootloader_path} >/dev/null 2>&1
        \pushd ${bootloader_path} >/dev/null 2>&1
        \wget ${archive_path}/archive/v${bootloader_version}.tar.gz >/dev/null 2>&1
        if [ $? -ne 0 ]; then
          error "Not possible to load ${archive_path}/archive/${bootloader_version}.tar.gz"
          teardown "ERROR"
          exit 1
        fi
        archive_dir=($(basename ${archive_path}))
        \tar zxf v${bootloader_version}.tar.gz --strip=1 ${archive_dir}-${bootloader_version} >/dev/null 2>&1
        \rm -f v${bootloader_version}.tar.gz >/dev/null 2>&1
        \git init >/dev/null 2>&1
        \git commit --allow-empty -m "Initial commit" >/dev/null 2>&1
        \git add . >/dev/null 2>&1
        \git commit -m "v${bootloader_version}" >/dev/null 2>&1
        \popd >/dev/null 2>&1
        ;;
        "FILE_PATH" )
          bootloader_path=($(echo $line | awk '{ print $2 }'))
          msg_patch=0
          \rm -rf ${bootloader_path}
          ;;
        "PATCH"* )
          patch_path=($(echo $line | awk '{ print $2 }'))
          if [ ${msg_patch} == 0 ]; then
            state "Applying required patches to ${bootloader_path}"
            msg_patch=1
            \pushd ${bootloader_path} >/dev/null 2>&1
          fi
          apply_patch "${patch_path}"
          ;;
      esac
    fi

  done < ${BOOTLOADER_CONFIG_PATH}

  if [[ ${msg_patch} == 1 ]]; then
    \popd >/dev/null 2>&1
    msg_patch=0
  fi

}

#######################################
# Main
#######################################

# Check that the current script is not sourced
if [[ "$0" != "$BASH_SOURCE" ]]; then
  empty_line
  error "This script shall not be sourced"
  empty_line
  usage
  \popd >/dev/null 2>&1
  return
fi

# check the options
while getopts "hvfps-:" option; do
  case "${option}" in
    -)
      # Treat long options
      case "${OPTARG}" in
        help)
          usage
          popd >/dev/null 2>&1
          exit 0
          ;;
        version)
          echo "`basename $0` version ${SCRIPT_VERSION}"
          \popd >/dev/null 2>&1
          exit 0
          ;;
        force)
          force_load=1
          ;;
        pbl)
          do_ssbl_load=0
          ;;
        sbl)
          do_fsbl_load=0
          ;;
        *)
          usage
          popd >/dev/null 2>&1
          exit 1
          ;;
      esac;;
    # Treat short options
    h)
      usage
      popd >/dev/null 2>&1
      exit 0
      ;;
    v)
      echo "`basename $0` version ${SCRIPT_VERSION}"
      \popd >/dev/null 2>&1
      exit 0
      ;;
    f)
      force_load=1
      ;;
    p)
      do_ssbl_load=0
      ;;
    s)
      do_fsbl_load=0
      ;;
    *)
      usage
      popd >/dev/null 2>&1
      exit 1
      ;;
  esac
done

shift $((OPTIND-1))

if [ $# -gt 0 ]; then
  error "Unknown command : $*"
  usage
  popd >/dev/null 2>&1
  exit 1
fi

# Start Loading First Bootloader
if [[ ${do_fsbl_load} == 1 ]]; then

  BOOTLOADER_PATCH_PATH=${FSBL_PATCH_PATH}
  BOOTLOADER_CONFIG_PATH=${FSBL_PATCH_PATH}/${FSBL_CONFIG_FILE}

  # Check availability of the BOOTLOADER configuration file
  if [[ ! -f ${BOOTLOADER_CONFIG_PATH} ]]; then
    error "The primary bootloader configuration ${BOOTLOADER_CONFIG_PATH} file not available"
    \popd >/dev/null 2>&1
    exit 1
  fi

  check_bootloader_status "FSBL"
  fsbl_status=$?

  if [[ ${fsbl_status} == 0 ]] || [[ ${force_load} == 1 ]]; then
    empty_line
    echo "Start loading the primary bootloader source (TF-A)"

    unset bootloader_cache
    if [ -n "${FSBL_CACHE_DIR+1}" ]; then
      bootloader_cache=${FSBL_CACHE_DIR}
    fi

    bootloader_version=${DEFAULT_FSBL_VERSION}

    load_bootloader "primary bootloader"

    if [[ ${fsbl_status} == 0 ]]; then
      echo "FSBL LOADED" >> ${BOOTLOADER_CONFIG_STATUS_PATH}
    fi

    green "The primary bootloader has been successfully loaded in ${bootloader_path}"
  else
    blue "The primary bootloader is already loaded"
    echo " If you want to reload it"
    echo "   execute the script with -f/--force option"
    echo "   or remove the file ${BOOTLOADER_CONFIG_STATUS_PATH}"
  fi
fi

action_state=1

# Start Loading Second Bootloader
if [[ ${do_ssbl_load} == 1 ]]; then

  BOOTLOADER_PATCH_PATH=${SSBL_PATCH_PATH}
  BOOTLOADER_CONFIG_PATH=${SSBL_PATCH_PATH}/${SSBL_CONFIG_FILE}

  # Check availability of the BOOTLOADER configuration file
  if [[ ! -f ${BOOTLOADER_CONFIG_PATH} ]]; then
    error "The secondary bootloader configuration $BOOTLOADER_CONFIG_PATH file not available"
    \popd >/dev/null 2>&1
    exit 1
  fi

  check_bootloader_status "SSBL"
  ssbl_status=$?

  if [[ ${ssbl_status} == 0 ]] || [[ ${force_load} == 1 ]]; then
    empty_line
    echo "Start loading the secondary bootloader source (U-Boot)"

    unset bootloader_cache
    if [ -n "${SSBL_CACHE_DIR+1}" ]; then
      bootloader_cache=${SSBL_CACHE_DIR}
    fi

    bootloader_version="${DEFAULT_SSBL_VERSION}"

    load_bootloader "secondary bootloader"

    if [[ ${ssbl_status} == 0 ]]; then
      echo "SSBL LOADED" >> ${BOOTLOADER_CONFIG_STATUS_PATH}
    fi

    clear_line
    green "The secondary bootloader has been successfully loaded in ${bootloader_path}"
  else
    blue "The secondary bootloader already loaded"
    echo " If you want to reload it"
    echo "   execute the script with -f/--force option"
    echo "   or remove the file ${BOOTLOADER_CONFIG_STATUS_PATH}"
  fi
fi

\popd >/dev/null 2>&1
