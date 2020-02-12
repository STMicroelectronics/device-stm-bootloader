# stm32mp1-bootloader #

This module is used to provide
* prebuilt images of the fsbl (tf-a) and the ssbl (u-boot) for STM32MP1
* scripts to load and build tf-a and u-boot source for STM32MP1

It is part of the STMicroelectronics delivery for Android (see the [delivery][] for more information).

[delivery]: https://wiki.st.com/stm32mpu/wiki/STM32MP15_distribution_for_Android_release_note_-_v1.1.0

## Description ##

This module version is the first version for stm32mp1

Please see the release notes for more details.

## Documentation ##

* The [release notes][] provide information on the release.
* The [distribution package][] provides detailed information on how to use this delivery.

[release notes]: https://wiki.st.com/stm32mpu/wiki/STM32MP15_distribution_for_Android_release_note_-_v1.1.0
[distribution package]: https://wiki.st.com/stm32mpu/wiki/STM32MP1_Distribution_Package_for_Android

## Dependencies ##

This module can't be used alone. It is part of the STMicroelectronics delivery for Android.

## Containing ##

This module contains several files and directories.

**prebuilt**
* `./prebuilt/fsbl/*`: prebuilt image of tf-a
* `./prebuilt/ssbl/*`: prebuilt images of u-boot

**source**
* `./source/load_bootloader.sh`: script used to load primary and secondary bootloader source with required patches for STM32MP1
* `./source/build_bootloader.sh`: script used to generate/update prebuilt images
* `./source/android_bootloaderbuild.config`: configuration file used by the build_bootloader.sh script
* `./source/patch/fsbl/<version>/*`: tf-a patches required (not yet up-streamed)
* `./source/patch/ssbl/<version>/*`: u-boot kernel patches required (not yet up-streamed)

## License ##

This module is distributed under the Apache License, Version 2.0 found in the [Apache-2.0](./LICENSES/Apache-2.0) file.

There are exceptions which are distributed under BSD-3-Clause License, found in the [BSD-3-Clause](./LICENSES/BSD-3-Clause) file:
* all binaries provided in `./prebuilt/fsbl/` directory
* all .patch files provided in `./source/patch/fsbl/` directory

There are exceptions which are distributed under GPL License, Version 2.0 found in the [GPL-2.0](./LICENSES/GPL-2.0) file:
* all binaries provided in `./prebuilt/ssbl/` directory
* all .patch files provided in `./source/patch/ssbl/` directory
