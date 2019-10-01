#!/bin/bash
#
# Build primary and secondary bootloader

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
SCRIPT_VERSION="1.3"

SOC_FAMILY="stm32mp1"
SOC_NAME="stm32mp15"
SOC_VERSION="stm32mp157c"

BOOTLOADER_ARCH=arm
BOOTLOADER_TOOLCHAIN=gcc-arm-8.2-2019.01-x86_64-arm-eabi

BOOTLOADER_EXT="stm32"
BOOTLOADER_ELF_EXT="elf"

if [ -n "${ANDROID_BUILD_TOP+1}" ]; then
  TOP_PATH=${ANDROID_BUILD_TOP}
elif [ -d "device/stm/${SOC_FAMILY}-bootloader" ]; then
  TOP_PATH=$PWD
else
  echo "ERROR: ANDROID_BUILD_TOP env variable not defined, this script shall be executed on TOP directory"
  exit 1
fi

\pushd ${TOP_PATH} >/dev/null 2>&1

BOOTLOADER_BUILDCONFIG=android_bootloaderbuild.config

BOOTLOADER_SOURCE_PATH=${TOP_PATH}/device/stm/${SOC_FAMILY}-bootloader/source
BOOTLOADER_PREBUILT_PATH=${TOP_PATH}/device/stm/${SOC_FAMILY}-bootloader/prebuilt

BOOTLOADER_CROSS_COMPILE_PATH=${TOP_PATH}/prebuilts/gcc/linux-x86/arm/${BOOTLOADER_TOOLCHAIN}/bin
BOOTLOADER_CROSS_COMPILE=arm-eabi-

BOOTLOADER_OUT=${TOP_PATH}/out-bsp/${SOC_FAMILY}/BOOTLOADER_OBJ
PBL_OUT=${BOOTLOADER_OUT}/PBL
SBL_OUT=${BOOTLOADER_OUT}/SBL

# Board name and flavour shall be listed in associated order
DEFAULT_BOARD_NAME_LIST=( "eval" )
DEFAULT_BOARD_FLAVOUR_LIST=( "ev1" )

# Board memory type (used only for eval)
DEFAULT_BOARD_MEM_LIST=( "sd" "emmc" )

# Boot mode
DEFAULT_BOOT_OPTION_LIST=( "optee" "trusted" )

#######################################
# Variables
#######################################
nb_states=0
do_install=0

do_programmer=0

verbose="--silent"
verbose_level=0

# By default redirect stdout and stderr to /dev/null
redirect_out="/dev/null"

board_name_list=("${DEFAULT_BOARD_NAME_LIST[@]}")
board_mem_list=("${DEFAULT_BOARD_MEM_LIST[@]}")
boot_mode_list=("${DEFAULT_BOOT_OPTION_LIST[@]}")

pbl_src=
sbl_src=

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
  echo "Usage: `basename $0` [Options] [Mode options] [Board options]"
  empty_line
  echo "  This script allows building the bootloaders source (TF-A and/or U-Boot)"
  empty_line
  echo "Options:"
  echo "  -h/--help: print this message"
  echo "  -v/--version: get script version"
  echo "  -i/--install: update prebuilt images"
  echo "  --verbose <level>: enable verbosity (1 or 2 depending on level of verbosity required)"
  empty_line
  echo "Mode options (exclusive, default = both optee and trusted):"
  echo "  -o/--optee: set optee mode for bootloaders"
  echo "  or"
  echo "  -t/--trusted: set trusted mode for bootloaders (non op-tee option)"
  echo "  or"
  echo "  -p/--programmer: build dedicated programmer version (-i option is mandatory)"
  empty_line
  echo "Board options: (exclusive, default = all possibilities)"
  echo "  -c/--current: build only for current configuration (board and memory)"
  echo "  or"
  echo "  -b/--board <name>: set board name from following list = ${DEFAULT_BOARD_NAME_LIST[*]} (default: all)"
  echo "  -m/--mem <name>: set memory configuration from following list = ${DEFAULT_BOARD_MEM_LIST[*]} (default: all)"
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
  echo "$(tput setaf 1)ERROR: $1$(tput sgr0)" >&2
}

#######################################
# Print warning message in orange on stdout
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#######################################
warning()
{
  echo "$(tput setaf 3)WARNING: $1$(tput sgr0)"
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
  echo "$(tput setaf 6)  [${action_state}/${nb_states}]: $1 $(tput sgr0)"
  action_state=$((action_state+1))
}

#######################################
# Check if item is available in list
# Globals:
#   None
# Arguments:
#   $1 = list of possible items
#   $2 = item which shall be tested
# Returns:
#   0 if item found in list
#   1 if item not found in list
#######################################
in_list()
{
  local list="$1"
  local checked_item="$2"

  for item in ${list}
  do
    if [[ "$item" == "$checked_item" ]]; then
      return 0
    fi
  done

  return 1
}

#######################################
# Initialize number of states
# Globals:
#   I BOOTLOADER_SOURCE_PATH
#   I BOOTLOADER_BUILDCONFIG
#   O nb_states
# Arguments:
#   None
# Returns:
#   None
#######################################
init_nb_states()
{
  for board_name in "${board_name_list[@]}"
  do
    if [[ ${do_programmer} == 0 ]]; then
      for boot_mode in "${boot_mode_list[@]}"
      do
        for board_mem in "${board_mem_list[@]}"
        do
          if [[ ${board_mem} == "emmc" ]] && [[ ${board_name} == "disco" ]]; then
            continue
          fi
          nb_states=$((nb_states+2))
          if [[ ${do_install} == 1 ]]; then
            nb_states=$((nb_states+1))
          fi
        done
        nb_states=$((nb_states+1))
        if [[ ${do_install} == 1 ]]; then
          nb_states=$((nb_states+1))
        fi
      done
    fi

    if [[ ${do_programmer} == 1 ]] && [[ ${do_install} == 1 ]]; then
      nb_states=$((nb_states+4))
    fi
  done
}

#######################################
# Update board flavour based on board name
# Globals:
#   I DEFAULT_BOARD_NAME_LIST
#   I DEFAULT_BOARD_FLAVOUR_LIST
#   O board_flavour
# Arguments:
#   $1 = Board name
# Returns:
#   None
#######################################
update_board_flavour()
{
  if [[ $1 == ${DEFAULT_BOARD_NAME_LIST[0]} ]]; then
    board_flavour=${DEFAULT_BOARD_FLAVOUR_LIST[0]}
  else
    board_flavour=${DEFAULT_BOARD_FLAVOUR_LIST[1]}
  fi
}

#######################################
# Extract Bootloader build config
# Globals:
#   I BOOTLOADER_SOURCE_PATH
#   I BOOTLOADER_BUILDCONFIG
#   O pbl_src
#   O sbl_src
# Arguments:
#   None
# Returns:
#   None
#######################################
extract_buildconfig()
{
  local l_bootloader_value
  local l_line
  local l_src

  while IFS='' read -r l_line || [[ -n $l_line ]]; do
    echo $l_line | grep '^BOOTLOADER_'  >/dev/null 2>&1

    if [ $? -eq 0 ]; then
      l_line=$(echo "${l_line: 11}")
      l_bootloader_value=($(echo $l_line | awk '{ print $1 }'))

      case ${l_bootloader_value} in
      "PBL_SRC" )
        l_src=($(echo $l_line | awk '{ print $2 }'))
        pbl_src=($(realpath ${l_src}))
        ;;
      "SBL_SRC" )
        l_src=($(echo $l_line | awk '{ print $2 }'))
        sbl_src=($(realpath ${l_src}))
        ;;
      esac
    fi
  done < ${BOOTLOADER_SOURCE_PATH}/${BOOTLOADER_BUILDCONFIG}
}

#######################################
# Generate PBL binary
# Globals:
#   I pbl_src
#   I PBL_OUT
#   I SBL_OUT
#   I BOOTLOADER_CROSS_COMPILE_PATH
#   I BOOTLOADER_CROSS_COMPILE
# Arguments:
#   $1: board flavour (used to select device tree)
#   $2: boot mode (optee or trusted)
# Returns:
#   None
#######################################
generate_pbl()
{
  local l_pbl_dtb
  local l_pbl_mode

  l_pbl_dtb=${SOC_VERSION}-${1}.dtb

  if [ $2 == "trusted" ]; then
    l_pbl_mode="sp_min"
  else
    l_pbl_mode="optee"
  fi

  \make ${verbose} -j8 -C ${pbl_src} CROSS_COMPILE=${BOOTLOADER_CROSS_COMPILE_PATH}/${BOOTLOADER_CROSS_COMPILE} PLAT=${SOC_FAMILY} ARCH=aarch32 V=1 DEBUG=1 AARCH32_SP=${l_pbl_mode} BUILD_PLAT=${PBL_OUT}-${2^^} ARM_ARCH_MAJOR=7 ARM_ARCH_MINOR=3 DTC=${SBL_OUT}-${2^^}/scripts/dtc/dtc DTB_FILE_NAME=${l_pbl_dtb} &>${redirect_out}
}

#######################################
# Update PBL prebuilt
# Globals:
#   I PBL_OUT
#   I BOOTLOADER_PREBUILT_PATH
#   I BOOTLOADER_EXT
#   I BOOTLOADER_ELF_EXT
#   I SOC_VERSION
# Arguments:
#   $1: board flavour (used to select device tree)
#   $2: boot mode (optee or trusted)
# Returns:
#   None
#######################################
update_pbl_prebuilt()
{
  \find ${PBL_OUT}-${2^^}/ -name "tf-a-${SOC_VERSION}-${1}.${BOOTLOADER_EXT}" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/fsbl/tf-a-${SOC_VERSION}-${1}-${2}.${BOOTLOADER_EXT}
  \find ${PBL_OUT}-${2^^}/ -name "bl2.${BOOTLOADER_ELF_EXT}" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/fsbl/tf-a-bl2-${SOC_VERSION}-${1}-${2}.${BOOTLOADER_ELF_EXT}
  \find ${PBL_OUT}-${2^^}/ -name "bl32.${BOOTLOADER_ELF_EXT}" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/fsbl/tf-a-bl32-${SOC_VERSION}-${1}-${2}.${BOOTLOADER_ELF_EXT}
}

#######################################
# Update PBL prebuilt for programmer
# Globals:
#   I PBL_OUT
#   I BOOTLOADER_PREBUILT_PATH
#   I SOC_VERSION
# Arguments:
#   $1: board flavour (used to select device tree)
#   $2: boot mode (optee or trusted)
# Returns:
#   None
#######################################
update_pbl_programmer_prebuilt()
{
  \find ${PBL_OUT}-${2^^}/ -name "tf-a-${SOC_VERSION}-${1}.stm32" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/fsbl/tf-a-${SOC_VERSION}-${2}-programmer.stm32
}

#######################################
# Generate SBL config
# Globals:
#   I sbl_src
#   I SBL_OUT
#   I BOOTLOADER_ARCH
#   I BOOTLOADER_CROSS_COMPILE_PATH
#   I BOOTLOADER_CROSS_COMPILE
# Arguments:
#   $1: board flavour (used to select device tree)
#   $2: board memory (sd or emmc)
#   $3: boot mode (optee or trusted)
# Returns:
#   None
#######################################
generate_sbl_config()
{
  local l_sbl_defconfig
  local l_board_mmc_dev

  l_sbl_defconfig=${SOC_NAME}_${3}_defconfig

  if [[ ${2} == "sd" ]]; then
    l_board_mmc_dev=0
  else
    l_board_mmc_dev=1
  fi

  \make ${verbose} -C ${sbl_src} O=${SBL_OUT}-${3^^} ARCH=${BOOTLOADER_ARCH} CROSS_COMPILE=${BOOTLOADER_CROSS_COMPILE_PATH}/${BOOTLOADER_CROSS_COMPILE} ${l_sbl_defconfig} &>${redirect_out}

  ${BOOTLOADER_SOURCE_PATH}/scripts/config --file ${SBL_OUT}-${3^^}/.config --set-val CONFIG_FASTBOOT_FLASH_MMC_DEV ${l_board_mmc_dev}
}

#######################################
# Generate SBL binary
# Globals:
#   I sbl_src
#   I SBL_OUT
#   I BOOTLOADER_CROSS_COMPILE_PATH
#   I BOOTLOADER_CROSS_COMPILE
# Arguments:
#   $1: board flavour (used to select device tree)
#   $2: boot mode (optee or trusted)
# Returns:
#   None
#######################################
generate_sbl()
{
  local l_sbl_dtb
  l_sbl_dtb=${SOC_VERSION}-${1}

  \make ${verbose} -j8 -C ${sbl_src} O=${SBL_OUT}-${2^^} CROSS_COMPILE=${BOOTLOADER_CROSS_COMPILE_PATH}/${BOOTLOADER_CROSS_COMPILE} DEVICE_TREE=${l_sbl_dtb} all &>${redirect_out}
}

#######################################
# Update SBL prebuilt
# Globals:
#   I SBL_OUT
#   I BOOTLOADER_PREBUILT_PATH
#   I BOOTLOADER_EXT
#   I BOOTLOADER_ELF_EXT
#   I SOC_VERSION
# Arguments:
#   $1: board flavour (used to select device tree)
#   $2: board memory (sd or emmc)
#   $3: boot mode (optee or trusted)
# Returns:
#   None
#######################################
update_sbl_prebuilt()
{
  \find ${SBL_OUT}-${3^^}/ -name "u-boot.${BOOTLOADER_EXT}" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/ssbl/u-boot-${SOC_VERSION}-${1}-${3}-fb${2}.${BOOTLOADER_EXT}
  \find ${SBL_OUT}-${3^^}/ -name "u-boot" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/ssbl/u-boot-${SOC_VERSION}-${1}-${3}-fb${2}.${BOOTLOADER_ELF_EXT}
}

#######################################
# Update SBL for programmer prebuilt
# Globals:
#   I SBL_OUT
#   I BOOTLOADER_PREBUILT_PATH
#   I SOC_VERSION
# Arguments:
#   $1: board flavour (used to select device tree)
#   $2: boot mode (optee or trusted)
# Returns:
#   None
#######################################
update_sbl_programmer_prebuilt()
{
  \find ${SBL_OUT}-${2^^}/ -name "u-boot.stm32" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/ssbl/u-boot-${SOC_VERSION}-${1}-programmer.stm32
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

# Check the current usage
if [ $# -gt 7 ]
then
  usage
  popd >/dev/null 2>&1
  exit 0
fi

while test "$1" != ""; do
  arg=$1
  case $arg in
    "-h"|"--help" )
      usage
      popd >/dev/null 2>&1
      exit 0
      ;;

    "-v"|"--version" )
      echo "`basename $0` version ${SCRIPT_VERSION}"
      \popd >/dev/null 2>&1
      exit 0
      ;;

    "-i"|"--install" )
      do_install=1
      ;;

    "--verbose" )
      verbose_level=${2}
      redirect_out="/dev/stdout"
      if ! in_list "0 1 2" "${verbose_level}"; then
        error "unknown verbose level ${verbose_level}"
        \popd >/dev/null 2>&1
        exit 1
      fi
      if [ ${verbose_level} == 2 ];then
        verbose=
      fi
      shift
      ;;

    "-o"|"--optee" )
      boot_mode_list=( "optee" )
      ;;

    "-t"|"--trusted" )
      boot_mode_list=( "trusted" )
      ;;

    "-p"|"--programmer" )
      do_programmer=1
      ;;

    "-c"|"--current" )
      if [ -n "${STM32MP1_DISK_TYPE+1}" ]; then
        if in_list "${DEFAULT_BOARD_MEM_LIST[*]}" "${STM32MP1_DISK_TYPE}"; then
          board_mem_list=( "${STM32MP1_DISK_TYPE}" )
        else
          error "unknown disk type ${STM32MP1_DISK_TYPE}"
          popd >/dev/null 2>&1
          exit 1
        fi
      else
        echo "STM32MP1_DISK_TYPE not defined !"
        echo "Please execute \"source ./build/envsetup.sh\" followed by \"lunch\" with appropriate target"
        popd >/dev/null 2>&1
        exit 0
      fi
      if [ -n "${ANDROID_PRODUCT_OUT+1}" ]; then
        board_name=$(basename ${ANDROID_PRODUCT_OUT})
        if in_list "${DEFAULT_BOARD_NAME_LIST[*]}" "${board_name}"; then
          board_name_list=( "${board_name}" )
        else
          error "unknown board name ${board_name}"
          popd >/dev/null 2>&1
          exit 1
        fi
      else
        echo "ANDROID_PRODUCT_OUT not defined !"
        echo "Please execute \"source ./build/envsetup.sh\" followed by \"lunch\" with appropriate target"
        popd >/dev/null 2>&1
        exit 0
      fi
      do_current=1
      ;;

    "-b"|"--board" )
      # Check board name
      if ! in_list "${DEFAULT_BOARD_NAME_LIST[*]}" "${2}"; then
        error "unknown board name ${2}"
        popd >/dev/null 2>&1
        exit 1
      fi
      board_name_list=( "${2}" )
      shift
      ;;

    "-m"|"--mem" )
      # Check board memory
      if ! in_list "${DEFAULT_BOARD_MEM_LIST[*]}" "${2}"; then
        error "unknown board memory ${2}"
        popd >/dev/null 2>&1
        exit 1
      fi
      board_mem_list=( "${2}" )
      shift
      ;;

    ** )
      usage
      popd >/dev/null 2>&1
      exit 0
      ;;
  esac
  shift
done

# Check existence of the Bootloader build configuration file
if [[ ! -f ${BOOTLOADER_SOURCE_PATH}/${BOOTLOADER_BUILDCONFIG} ]]; then
  error "Bootloader configuration ${BOOTLOADER_BUILDCONFIG} file not available"
  popd >/dev/null 2>&1
  exit 1
fi

if [[ ! -d ${BOOTLOADER_CROSS_COMPILE_PATH} ]]; then
  error "Required toolchain ${BOOTLOADER_TOOLCHAIN} not available, please execute bspsetup"
  popd >/dev/null 2>&1
  exit 1
fi

# Extract Bootloader build configuration
extract_buildconfig

# Check existence of the primary bootloader source
if [[ ! -f ${pbl_src}/Makefile ]]; then
  error "Primary bootloader source ${pbl_src} not available, please execute load_bootloader first"
  popd >/dev/null 2>&1
  exit 1
fi

# Check existence of the secondary bootloader source
if [[ ! -f ${sbl_src}/Makefile ]]; then
  error "Secondary bootloader source ${sbl_src} not available, please execute load_bootloader first"
  popd >/dev/null 2>&1
  exit 1
fi

# Initialize number of build states
init_nb_states

for board_name in "${board_name_list[@]}"
do
  # get back board flavour associated to board name
  update_board_flavour "${board_name}"

  if [[ ${do_programmer} == 0 ]]; then

    for boot_mode in "${boot_mode_list[@]}"
    do
      for board_mem in "${board_mem_list[@]}"
      do
        if [[ ${board_mem} == "emmc" ]] && [[ ${board_name} == "disco" ]]; then
          continue
        fi

        # Build SBL (shall be built first)
        state "Generate U-Boot .config for ${SOC_FAMILY} ${board_flavour} board, case ${board_mem}, mode ${boot_mode}"
        generate_sbl_config "${board_flavour}" "${board_mem}" "${boot_mode}"

        state "Generate U-Boot image for ${SOC_FAMILY} ${board_flavour} board case, ${board_mem}, mode ${boot_mode}"
        generate_sbl "${board_flavour}" "${boot_mode}"

        if [[ ${do_install} == 1 ]]; then
          state "Update U-Boot prebuilt image for ${SOC_FAMILY} ${board_flavour} board, case ${board_mem}, mode ${boot_mode}"
          update_sbl_prebuilt "${board_flavour}" "${board_mem}" "${boot_mode}"
        fi
      done

      state "Generate TF-A image for ${SOC_FAMILY} ${board_flavour} board, mode ${boot_mode}"
      generate_pbl "${board_flavour}" "${boot_mode}"

      if [[ ${do_install} == 1 ]]; then
        state "Update TF-A prebuilt image for ${SOC_FAMILY} ${board_flavour} board, mode ${boot_mode}"
        update_pbl_prebuilt "${board_flavour}" "${boot_mode}"
      fi
    done
  fi

  # programmer build is required only if installed (mode = trusted, mem = sd)
  if [[ ${do_programmer} == 1 ]] && [[ ${do_install} == 1 ]]; then
    state "Generate U-Boot image for ${SOC_FAMILY} ${board_flavour} board, case programmer"
    generate_sbl_config "${board_flavour}" "sd" "trusted"
    generate_sbl "${board_flavour}" "trusted"

    state "Update U-Boot prebuilt image for ${SOC_FAMILY} ${board_flavour} board, case programmer"
    update_sbl_programmer_prebuilt "${board_flavour}" "trusted"

    state "Generate TF-A image for ${SOC_FAMILY} ${board_flavour} board, case programmer"
    generate_pbl "${board_flavour}" "trusted"

    state "Update TF-A prebuilt image for ${SOC_FAMILY} ${board_flavour} board, case programmer"
    update_pbl_programmer_prebuilt "${board_flavour}" "trusted"
  fi

done

popd >/dev/null 2>&1
