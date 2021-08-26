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
SCRIPT_VERSION="1.6"

SOC_FAMILY="stm32mp1"
SOC_NAME="stm32mp15"
SOC_VERSIONS=( "stm32mp157c" "stm32mp157f" )

# optional display panels (keep at least default)
DISPLAY_PANELS=( "mb1166" "default" )

BOOTLOADER_ARCH=arm
BOOTLOADER_TOOLCHAIN=gcc-arm-9.2-2019.12-x86_64-arm-none-eabi

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
BOOTLOADER_CROSS_COMPILE=arm-none-eabi-

BOOTLOADER_OUT=${TOP_PATH}/out-bsp/${SOC_FAMILY}/BOOTLOADER_OBJ
PBL_OUT=${BOOTLOADER_OUT}/PBL
SBL_OUT=${BOOTLOADER_OUT}/SBL

# PBL build parameters
#   1- enable SD and eMMC support (NOR/NAND disabled)
#   2- enable debug build by default
PBL_OEMAKE="STM32MP_SDMMC=1 STM32MP_EMMC=1 "
PBL_OEMAKE+="DEBUG=1 "

# PBL for STM32CubeProgrammer build parameters
PBL_PROGRAMMER_OEMAKE="STM32MP_UART_PROGRAMMER=1 "
PBL_PROGRAMMER_OEMAKE+="STM32MP_USB_PROGRAMMER=1 "

# Board name and flavour shall be listed in associated order
DEFAULT_BOARD_NAME_LIST=( "eval" )
DEFAULT_BOARD_FLAVOUR_LIST=( "ev1" )

# Board memory type (used only for eval)
DEFAULT_BOARD_MEM_LIST=( "sd" "emmc" )

# Boot mode
DEFAULT_BOOT_OPTION_LIST=( "optee" )

#######################################
# Variables
#######################################
nb_states=0
do_install=0

do_programmer=0
do_gdb=0

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
  echo "Usage: `basename $0` [Options] [Mode Options] [Board Options]"
  empty_line
  echo "  This script allows building the bootloaders source (TF-A and/or U-Boot)"
  empty_line
  echo "Options:"
  echo "  -h / --help: print this message"
  echo "  -v / --version: get script version"
  echo "  -i / --install: update prebuilt images"
  echo "  --verbose=<level>: enable verbosity (1 or 2 depending on level of verbosity required)"
  empty_line
  echo "  -p / --programmer: build dedicated programmer version (-i option forced)"
  echo "  -g/--gdb: generate .elf files useful for debug purpose"
  empty_line
  echo "Board options: (default = all possibilities)"
  echo "  -b <name> / --board=<name>: set board name from following list = ${DEFAULT_BOARD_NAME_LIST[*]} (default: all)"
  echo "  -m <config> / --mem=<config>: set memory configuration from following list = ${DEFAULT_BOARD_MEM_LIST[*]} (default: all)"
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
  if [[ ${do_programmer} == 0 ]]; then

    for board_mem in "${board_mem_list[@]}"
    do
      if [[ ${board_mem} == "emmc" ]] && [[ ${board_name} == "disco" ]]; then
        continue
      fi
      for disp_panel in "${DISPLAY_PANELS[@]}"
      do
        nb_states=$((nb_states+2))
        if [[ ${do_install} == 1 ]]; then
          nb_states=$((nb_states+1))
        fi
      done
    done

    for boot_mode in "${boot_mode_list[@]}"
    do
      nb_states=$((nb_states+1))
      if [[ ${do_install} == 1 ]]; then
        nb_states=$((nb_states+1))
      fi
    done

  fi

  if [[ ${do_programmer} == 1 ]] && [[ ${do_install} == 1 ]]; then
    nb_states=$((nb_states+4))
  fi

  board_nb=${#board_name_list[@]}
  nb_states=$((nb_states*${board_nb}))

  soc_nb=${#SOC_VERSIONS[@]}
  nb_states=$((nb_states*${soc_nb}))
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
#   $1: boot mode (optee or trusted)
# Returns:
#   None
#######################################
generate_pbl()
{
  local l_pbl_dtb
  local l_pbl_mode

  l_pbl_dtb=${soc_version}-${board_flavour}.dtb

  if [ $1 == "trusted" ]; then
    l_pbl_mode="sp_min"
  else
    l_pbl_mode="optee"
  fi

  if [ ! -d "${PBL_OUT}-${1^^}" ]; then
    \mkdir -p ${PBL_OUT}-${1^^}
  fi

  \make ${verbose} -j8 -C ${pbl_src} CROSS_COMPILE=${BOOTLOADER_CROSS_COMPILE_PATH}/${BOOTLOADER_CROSS_COMPILE} V=1 ${PBL_OEMAKE} PLAT=${SOC_FAMILY} ARCH=aarch32 AARCH32_SP=${l_pbl_mode} BUILD_PLAT=${PBL_OUT}-${1^^}/${soc_version}-${board_flavour} ARM_ARCH_MAJOR=7 ARM_ARCH_MINOR=3 DTC=${SBL_OUT}/${soc_version}-${board_flavour}/scripts/dtc/dtc DTB_FILE_NAME=${l_pbl_dtb} &>${redirect_out}
  if [ $? -ne 0 ]; then
    error "Not possible to generate the PBL image"
    if [ ${verbose_level} == 0 ];then
      error "Increase verbose level to get more information"
    fi
    popd >/dev/null 2>&1
    exit 1
  fi
}

#######################################
# Update PBL prebuilt
# Globals:
#   I PBL_OUT
#   I BOOTLOADER_PREBUILT_PATH
#   I BOOTLOADER_EXT
#   I BOOTLOADER_ELF_EXT
#   I soc_version
#   I board_flavour
# Arguments:
#   $1: boot mode (optee or trusted)
# Returns:
#   None
#######################################
update_pbl_prebuilt()
{
  if [ ! -d "${BOOTLOADER_PREBUILT_PATH}/fsbl/${soc_version}-${board_flavour}" ]; then
    \mkdir -p ${BOOTLOADER_PREBUILT_PATH}/fsbl/${soc_version}-${board_flavour}
  fi
  \find ${PBL_OUT}-${1^^}/${soc_version}-${board_flavour} -name "tf-a-${soc_version}-${board_flavour}.${BOOTLOADER_EXT}" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/fsbl/${soc_version}-${board_flavour}/tf-a-${soc_version}-${board_flavour}-${1}.${BOOTLOADER_EXT}
  if [[ ${do_gdb} == 1 ]]; then
    \find ${PBL_OUT}-${1^^}/${soc_version}-${board_flavour} -name "bl2.${BOOTLOADER_ELF_EXT}" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/fsbl/${soc_version}-${board_flavour}/tf-a-bl2-${soc_version}-${board_flavour}-${1}.${BOOTLOADER_ELF_EXT}
    \find ${PBL_OUT}-${1^^}/${soc_version}-${board_flavour} -name "bl32.${BOOTLOADER_ELF_EXT}" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/fsbl/${soc_version}-${board_flavour}/tf-a-bl32-${soc_version}-${board_flavour}-${1}.${BOOTLOADER_ELF_EXT}
  fi
}

#######################################
# Generate PBL binary for programmer
# Globals:
#   I pbl_src
#   I PBL_OUT
#   I SBL_OUT
#   I BOOTLOADER_CROSS_COMPILE_PATH
#   I BOOTLOADER_CROSS_COMPILE
# Arguments:
#   None
# Returns:
#   None
#######################################
generate_pbl_programmer()
{
  local l_pbl_dtb
  local l_pbl_mode

  l_pbl_dtb=${soc_version}-${board_flavour}.dtb
  l_pbl_mode="sp_min"

  if [ ! -d "${PBL_OUT}-PROG" ]; then
    \mkdir -p ${PBL_OUT}-PROG
  fi

  \make ${verbose} -j8 -C ${pbl_src} CROSS_COMPILE=${BOOTLOADER_CROSS_COMPILE_PATH}/${BOOTLOADER_CROSS_COMPILE} V=1 ${PBL_PROGRAMMER_OEMAKE} PLAT=${SOC_FAMILY} ARCH=aarch32 AARCH32_SP=${l_pbl_mode} BUILD_PLAT=${PBL_OUT}-PROG/${soc_version}-${board_flavour} ARM_ARCH_MAJOR=7 ARM_ARCH_MINOR=3 DTC=${SBL_OUT}/${soc_version}-${board_flavour}/scripts/dtc/dtc DTB_FILE_NAME=${l_pbl_dtb} &>${redirect_out}
  if [ $? -ne 0 ]; then
    error "Not possible to generate the PBL image for programmer"
    if [ ${verbose_level} == 0 ];then
      error "Increase verbose level to get more information"
    fi
    popd >/dev/null 2>&1
    exit 1
  fi
}

#######################################
# Update PBL prebuilt for programmer
# Globals:
#   I PBL_OUT
#   I BOOTLOADER_PREBUILT_PATH
#   I soc_version
#   I board_flavour
# Arguments:
#   None
# Returns:
#   None
#######################################
update_pbl_programmer_prebuilt()
{
  if [ ! -d "${BOOTLOADER_PREBUILT_PATH}/fsbl/${soc_version}-${board_flavour}" ]; then
    \mkdir -p ${BOOTLOADER_PREBUILT_PATH}/fsbl/${soc_version}-${board_flavour}
  fi
  \find ${PBL_OUT}-PROG/${soc_version}-${board_flavour} -name "tf-a-${soc_version}-${board_flavour}.stm32" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/fsbl/${soc_version}-${board_flavour}/tf-a-${soc_version}-${board_flavour}-programmer.stm32
}

#######################################
# Generate SBL config
# Globals:
#   I sbl_src
#   I SBL_OUT
#   I BOOTLOADER_ARCH
#   I BOOTLOADER_CROSS_COMPILE_PATH
#   I BOOTLOADER_CROSS_COMPILE
#   I soc_version
#   I board_flavour
# Arguments:
#   $1: board memory (sd or emmc)
#   $2: display panel (can be: default)
# Returns:
#   None
#######################################
generate_sbl_config()
{
  local l_sbl_defconfig
  local l_board_mmc_dev
  local l_dtb

  l_sbl_defconfig=${SOC_NAME}_trusted_defconfig

  if [[ ${1} == "sd" ]]; then
    l_board_mmc_dev=0
  else
    l_board_mmc_dev=1
  fi

  if [ ! -d "${SBL_OUT}" ]; then
    \mkdir -p ${SBL_OUT}
  fi

  l_dtb="${soc_version}-${board_flavour}"
  if [[ ${2} != "default" ]]; then
    l_dtb+="-${2}"
  fi

  \make ${verbose} -C ${sbl_src} O=${SBL_OUT}/${l_dtb} ARCH=${BOOTLOADER_ARCH} CROSS_COMPILE=${BOOTLOADER_CROSS_COMPILE_PATH}/${BOOTLOADER_CROSS_COMPILE} ${l_sbl_defconfig} &>${redirect_out}
  if [ $? -ne 0 ]; then
    error "Not possible to generate the SBL config"
    if [ ${verbose_level} == 0 ];then
      error "Increase verbose level to get more information"
    fi
    popd >/dev/null 2>&1
    exit 1
  fi

  ${BOOTLOADER_SOURCE_PATH}/scripts/config --file ${SBL_OUT}/${l_dtb}/.config --set-val CONFIG_FASTBOOT_FLASH_MMC_DEV ${l_board_mmc_dev}
}

#######################################
# Generate SBL binary
# Globals:
#   I sbl_src
#   I SBL_OUT
#   I BOOTLOADER_CROSS_COMPILE_PATH
#   I BOOTLOADER_CROSS_COMPILE
#   I soc_version
#   I board_flavour
# Arguments:
#   $1: display panel (can be: default)
# Returns:
#   None
#######################################
generate_sbl()
{

  local l_dtb

  l_dtb="${soc_version}-${board_flavour}"
  if [[ ${1} != "default" ]]; then
    l_dtb+="-${1}"
  fi
  \make ${verbose} -j8 -C ${sbl_src} O=${SBL_OUT}/${l_dtb} CROSS_COMPILE=${BOOTLOADER_CROSS_COMPILE_PATH}/${BOOTLOADER_CROSS_COMPILE} DEVICE_TREE=${l_dtb} all &>${redirect_out}
  if [ $? -ne 0 ]; then
    error "Not possible to generate the SBL image"
    if [ ${verbose_level} == 0 ];then
      error "Increase verbose level to get more information"
    fi
    popd >/dev/null 2>&1
    exit 1
  fi
}

#######################################
# Update SBL prebuilt
# Globals:
#   I SBL_OUT
#   I BOOTLOADER_PREBUILT_PATH
#   I BOOTLOADER_EXT
#   I BOOTLOADER_ELF_EXT
#   I soc_version
#   I board_flavour
# Arguments:
#   $1: board memory (sd or emmc)
#   $2: display panel (can be: default)
# Returns:
#   None
#######################################
update_sbl_prebuilt()
{
  if [ ! -d "${BOOTLOADER_PREBUILT_PATH}/ssbl/${soc_version}-${board_flavour}" ]; then
    \mkdir -p ${BOOTLOADER_PREBUILT_PATH}/ssbl/${soc_version}-${board_flavour}
  fi

  local l_dtb

  l_dtb="${soc_version}-${board_flavour}"
  if [[ ${2} != "default" ]]; then
    l_dtb+="-${2}"
  fi

  \find ${SBL_OUT}/${l_dtb}/ -name "u-boot.${BOOTLOADER_EXT}" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/ssbl/${soc_version}-${board_flavour}/u-boot-${l_dtb}-trusted-fb${1}.${BOOTLOADER_EXT}
  if [[ ${do_gdb} == 1 ]]; then
    \find ${SBL_OUT}/${l_dtb}/ -name "u-boot" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/ssbl/${soc_version}-${board_flavour}/u-boot-${l_dtb}-trusted-fb${1}.${BOOTLOADER_ELF_EXT}
  fi
}

#######################################
# Update SBL for programmer prebuilt
# Globals:
#   I SBL_OUT
#   I BOOTLOADER_PREBUILT_PATH
#   I soc_version
#   I board_flavour
# Arguments:
#   $1: boot mode (optee or trusted)
# Returns:
#   None
#######################################
update_sbl_programmer_prebuilt()
{
  if [ ! -d "${BOOTLOADER_PREBUILT_PATH}/ssbl/${soc_version}-${board_flavour}" ]; then
    \mkdir -p ${BOOTLOADER_PREBUILT_PATH}/ssbl/${soc_version}-${board_flavour}
  fi
  \find ${SBL_OUT}/${soc_version}-${board_flavour}/ -name "u-boot.stm32" -print0 | xargs -0 -I {} cp {} ${BOOTLOADER_PREBUILT_PATH}/ssbl/${soc_version}-${board_flavour}/u-boot-${soc_version}-${board_flavour}-programmer.stm32
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
while getopts "hviotpb:m:-:" option; do
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
        verbose=*)
          verbose_level=${OPTARG#*=}
          redirect_out="/dev/stdout"
          if ! in_list "0 1 2" "${verbose_level}"; then
            error "unknown verbose level ${verbose_level}"
            \popd >/dev/null 2>&1
            exit 1
          fi
          if [ ${verbose_level} == 2 ];then
            verbose=
          fi
          ;;
        install)
          do_install=1
          ;;
        optee)
          boot_mode_list=( "optee" )
          ;;
        trusted)
          boot_mode_list=( "trusted" )
          ;;
        programmer)
          do_programmer=1
          do_install=1
          ;;
        gdb)
          do_gdb=1
          ;;
        board=*)
          board_arg=${OPTARG#*=}
          if ! in_list "${DEFAULT_BOARD_NAME_LIST[*]}" "${board_arg}"; then
            error "unknown board name ${board_arg}"
            popd >/dev/null 2>&1
            exit 1
          fi
          board_name_list=( "${board_arg}" )
          ;;
        mem=*)
          mem_arg=${OPTARG#*=}
          if ! in_list "${DEFAULT_BOARD_MEM_LIST[*]}" "${mem_arg}"; then
            error "unknown board memory ${mem_arg}"
            popd >/dev/null 2>&1
            exit 1
          fi
          board_mem_list=( "${mem_arg}" )
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
    i)
      do_install=1
      ;;
    o)
      boot_mode_list=( "optee" )
      ;;
    t)
      boot_mode_list=( "trusted" )
      ;;
    p)
      do_programmer=1
      do_install=1
      ;;
    b)
      if ! in_list "${DEFAULT_BOARD_NAME_LIST[*]}" "${OPTARG}"; then
        error "unknown board name ${OPTARG}"
        popd >/dev/null 2>&1
        exit 1
      fi
      board_name_list=( "${OPTARG}" )
      ;;
    m)
      if ! in_list "${DEFAULT_BOARD_MEM_LIST[*]}" "${OPTARG}"; then
        error "unknown board memory ${OPTARG}"
        popd >/dev/null 2>&1
        exit 1
      fi
      board_mem_list=( "${OPTARG}" )
      ;;
    g)
      do_gdb=1
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

for soc_version in "${SOC_VERSIONS[@]}"
do

  for board_name in "${board_name_list[@]}"
  do

    # get back board flavour associated to board name
    update_board_flavour "${board_name}"

    if [[ ${do_programmer} == 0 ]]; then

      for board_mem in "${board_mem_list[@]}"
      do
        if [[ ${board_mem} == "emmc" ]] && [[ ${board_name} == "disco" ]]; then
          continue
        fi

        for disp_panel in "${DISPLAY_PANELS[@]}"
        do

          # Build SBL (shall be built first)
          state "Generate U-Boot .config for ${soc_version}-${board_flavour} board (disp ${disp_panel}), case ${board_mem}"
          generate_sbl_config "${board_mem}" "${disp_panel}"

          state "Generate U-Boot image for ${soc_version}-${board_flavour} board (disp ${disp_panel}), case ${board_mem}"
          generate_sbl "${disp_panel}"

          if [[ ${do_install} == 1 ]]; then
            state "Update U-Boot prebuilt image for ${soc_version}-${board_flavour} board (disp ${disp_panel}), case ${board_mem}"
            update_sbl_prebuilt "${board_mem}" "${disp_panel}"
          fi
        done
      done

      for boot_mode in "${boot_mode_list[@]}"
      do
        state "Generate TF-A image for ${soc_version}-${board_flavour} board, mode ${boot_mode}"
        generate_pbl "${boot_mode}"

        if [[ ${do_install} == 1 ]]; then
          state "Update TF-A prebuilt image for ${soc_version}-${board_flavour} board, mode ${boot_mode}"
          update_pbl_prebuilt "${boot_mode}"
        fi
      done
    fi

    # programmer build is required only if installed (mode = trusted, mem = sd)
    if [[ ${do_programmer} == 1 ]] && [[ ${do_install} == 1 ]]; then
      state "Generate U-Boot image for ${soc_version}-${board_flavour} board, case programmer"
      generate_sbl_config "sd"
      generate_sbl

      state "Update U-Boot prebuilt image for ${soc_version}-${board_flavour} board, case programmer"
      update_sbl_programmer_prebuilt

      state "Generate TF-A image for ${soc_version}-${board_flavour} board, case programmer"
      generate_pbl_programmer

      state "Update TF-A prebuilt image for ${soc_version}-${board_flavour} board, case programmer"
      update_pbl_programmer_prebuilt "trusted"
    fi

  done

done

popd >/dev/null 2>&1
