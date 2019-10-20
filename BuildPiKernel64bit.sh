#!/usr/bin/env bash

# INSTALL DEPENDENCIES

sudo apt-get install build-essential libgmp-dev libmpfr-dev libmpc-dev libssl-dev bison flex libncurses-dev kpartx -y
sudo apt-get install qemu-user-static -y

# TOOLCHAIN
cd ~
if [ -d "toolchains" ]; then
  cd toolchains/aarch64
  export TOOLCHAIN=`pwd`
else
  mkdir -p toolchains/aarch64
  cd toolchains/aarch64
  export TOOLCHAIN=`pwd`
  cd ~

  cd "$TOOLCHAIN"
  wget https://ftp.gnu.org/gnu/binutils/binutils-2.32.tar.bz2
  tar -xf binutils-2.32.tar.bz2
  mkdir binutils-2.32-build
  cd binutils-2.32-build
  ../binutils-2.32/configure --prefix="$TOOLCHAIN" --target=aarch64-linux-gnu --disable-nls
  make -j4
  make install

  cd "$TOOLCHAIN"
  wget https://ftp.gnu.org/gnu/gcc/gcc-9.2.0/gcc-9.2.0.tar.gz
  tar -xf gcc-9.2.0.tar.gz
  mkdir gcc-9.2.0-build
  cd gcc-9.2.0-build
  ../gcc-9.2.0/configure --prefix="$TOOLCHAIN" --target=aarch64-linux-gnu --with-newlib --without-headers --disable-nls --disable-shared --disable-threads --disable-libssp --disable-decimal-float --disable-libquadmath --disable-libvtv --disable-libgomp --disable-libatomic --enable-languages=c
  make all-gcc -j4
  make install-gcc
fi

# GET FIRMWARE NON-FREE

cd ~
sudo rm -rf firmware-nonfree
git clone https://github.com/RPi-Distro/firmware-nonfree firmware-nonfree --depth 1
cd firmware-nonfree
git pull

# % firmware-raspbian should be a copy of /lib/firmware from the latest Raspbian image
cp -rf ~/firmware-raspbian/* ~/firmware-nonfree

# % Get Wireless firmware
cd ~/firmware-nonfree/brcm
sudo rm -f brcmfmac43455-sdio.bin
sudo rm -f brcmfmac43455-sdio.clm_blob
wget https://raw.githubusercontent.com/TheRemote/Ubuntu-Server-raspi4-unofficial/master/firmware-nonfree/brcm/brcmfmac43455-sdio.bin
wget https://raw.githubusercontent.com/TheRemote/Ubuntu-Server-raspi4-unofficial/master/firmware-nonfree/brcm/brcmfmac43455-sdio.clm_blob

# GET FIRMWARE
cd ~
sudo rm -rf firmware
git clone https://github.com/raspberrypi/firmware firmware --depth 1
cd firmware
git pull

# BUILD KERNEL

# % Check out the 4.19.y kernel branch -- if building and future versions are available you can update which branch is checked out here
cd ~
if [ ! -d "rpi-linux" ]; then
  git clone https://github.com/raspberrypi/linux.git rpi-linux --single-branch --branch rpi-4.19.y --depth 1
  cd rpi-linux
  git checkout origin/rpi-4.19.y

  # CONFIGURE / MAKE
  cd ~/rpi-linux
  PATH=$PATH:$TOOLCHAIN/bin make O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-  bcm2711_defconfig

  cd kernel-build
  # % If you want to build yourself from scratch (without using the .config from the repository) uncomment the lines below
  wget https://raw.githubusercontent.com/sakaki-/bcmrpi3-kernel-bis/master/conform_config.sh
  chmod +x conform_config.sh
  ./conform_config.sh
  rm -f conform_config.sh
  wget https://raw.githubusercontent.com/TheRemote/Ubuntu-Server-raspi4-unofficial/master/conform_config_jamesachambers.sh
  chmod +x conform_config_jamesachambers.sh
  ./conform_config_jamesachambers.sh
  rm -f confirm_config_jamesachambers.sh

  cd ~/rpi-linux

  # % This pulls the latest config from the repository -- if building yourself/customizing comment out
  #rm .config
  #wget https://raw.githubusercontent.com/TheRemote/Ubuntu-Server-raspi4-unofficial/master/.config
  #cd ~/rpi-linux

  # % If you want to change options, use the line below to enter the menuconfig kernel utility and configure your own kernel config flags
  #PATH=$PATH:$TOOLCHAIN/bin make O=./kernel-build/ ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-  menuconfig

  # % The line below starts the kernel build
  PATH=$PATH:$TOOLCHAIN/bin make -j4 O=./kernel-build/ ARCH=arm64 DTC_FLAGS="-@ -H epapr" CROSS_COMPILE=aarch64-linux-gnu-
  export KERNEL_VERSION=`cat ./kernel-build/include/generated/utsrelease.h | sed -e 's/.*"\(.*\)".*/\1/'`
  # % Creates /lib/modules/${KERNEL_VERSION} that we will install into our Ubuntu image so our custom kernel has all the modules needed available
  sudo make -j4 O=./kernel-build/ DEPMOD=echo MODLIB=./kernel-install/lib/modules/${KERNEL_VERSION} INSTALL_FW_PATH=./kernel-install/lib/firmware modules_install
  #sudo depmod --basedir ./kernel-build/kernel-install "${KERNEL_VERSION}"
  export KERNEL_BUILD_DIR=`realpath ./kernel-build`
  cd ~
fi

# MOUNT IMAGE
xzcat ubuntu-18.04.3-preinstalled-server-arm64+raspi3.img.xz > ubuntu-18.04.3-preinstalled-server-arm64+raspi4.img
MountXZ=$(sudo kpartx -av ubuntu-18.04.3-preinstalled-server-arm64+raspi4.img)
MountXZ=$(echo "$MountXZ" | awk 'NR==1{ print $3 }')
MountXZ="${MountXZ%p1}"
echo "Using loop $MountXZ"

# % Mount the image on /mnt (rootfs) and /mnt/boot/firmware (bootfs)
sudo mount /dev/mapper/"${MountXZ}"p2 /mnt
sudo rm -rf /mnt/boot/firmware/*
sudo mount /dev/mapper/"${MountXZ}"p1 /mnt/boot/firmware

# % Clean out old firmware, kernel and modules that don't support RPI 4
sudo rm -rf /mnt/lib/firmware/4.15.0-1041-raspi2
sudo rm -rf /mnt/boot/firmware/*
sudo rm -rf /mnt/usr/src/*
sudo rm -rf /mnt/lib/modules/*

sudo rm -rf /mnt/boot/initrd*
sudo rm -rf /mnt/boot/config*
sudo rm -rf /mnt/boot/vmlinuz*
sudo rm -rf /mnt/boot/System.map*

# % After we've cleaned some files off the image run a e4defrag to optimize disk img
sudo fstrim -av
sudo e4defrag /mnt/*

# % Copy bootfiles folder
sudo cp -rvf bootfiles/* /mnt/boot/firmware

# % Copy newly compiled kernel, stubs, overlays, etc to Ubuntu image
sudo mkdir /mnt/boot/firmware/overlays
sudo cp -vf rpi-linux/kernel-build/arch/arm64/boot/dts/broadcom/*.dtb /mnt/boot/firmware
sudo cp -vf rpi-linux/kernel-build/arch/arm64/boot/dts/overlays/*.dtb* /mnt/boot/firmware/overlays
sudo cp -vf rpi-linux/kernel-build/arch/arm64/boot/Image /mnt/boot/firmware/kernel8.img
sudo cp -vf rpi-linux/kernel-build/vmlinux /mnt/boot/vmlinuz-"${KERNEL_VERSION}"
sudo cp -vf rpi-linux/kernel-build/System.map /mnt/boot/System.map-"${KERNEL_VERSION}"
sudo cp -vf rpi-linux/kernel-build/.config /mnt/boot/config-"${KERNEL_VERSION}"

# % Create symlinks to our custom kernel -- this allows initramfs to find our kernel and update modules successfully
(
  cd /mnt/boot
  sudo ln -s vmlinuz-"${KERNEL_VERSION}" vmlinuz
  sudo ln -s initrd.img-"${KERNEL_VERSION}" initrd.img
)
# % Copy gpu firmware via start*.elf and fixup*.dat files
sudo cp -vf firmware/boot/*.elf /mnt/boot/firmware
sudo cp -vf firmware/boot/*.dat /mnt/boot/firmware

# % Remove initramfs actions for invalid existing kernels, then create a new link to our new custom kernel
sudo rm /mnt/var/lib/initramfs-tools/*
sha1sum=$(sha1sum  /mnt/boot/initrd.img-${KERNEL_VERSION})
echo "$sha1sum  /boot/vmlinuz-${KERNEL_VERSION}" | sudo -A tee -a /mnt/var/lib/initramfs-tools/"${KERNEL_VERSION}" >/dev/null;

# % Copy the new kernel modules to the Ubuntu image
sudo mkdir /mnt/lib/modules/${KERNEL_VERSION}
sudo cp -ravf rpi-linux/kernel-build/kernel-install/* /mnt

# % Copy System.map, kernel .config and Module.symvers to Ubuntu image
sudo cp -vf rpi-linux/kernel-build/System.map /mnt/usr/src/linux-headers-${KERNEL_VERSION}/System.map
sudo cp -vf rpi-linux/kernel-build/Module.symvers /mnt/usr/src/linux-headers-${KERNEL_VERSION}/Module.symvers
sudo cp -vf rpi-linux/kernel-build/.config /mnt/usr/src/linux-headers-${KERNEL_VERSION}/config

# % Create kernel header symlink
cd /mnt
sudo rm lib/modules/${KERNEL_VERSION}/build
sudo ln -s usr/src/linux-headers-${KERNEL_VERSION} lib/modules/${KERNEL_VERSION}/build

# QUIRKS

# % Fix WiFi
# % The Pi 4 version returns boardflags3=0x44200100
# % The Pi 3 version returns boardflags3=0x48200100cd
sudo sed -i "s:0x48200100:0x44200100:g" /mnt/lib/firmware/brcm/brcmfmac43455-sdio.txt

# % Remove flash-kernel hooks to prevent firmware updater from overriding our custom firmware
sudo rm -f /mnt/etc/kernel/postinst.d/zz-flash-kernel
sudo rm -f /mnt/etc/kernel/postrm.d/zz-flash-kernel
sudo rm -f /mnt/etc/initramfs/post-update.d/flash-kernel

# % Disable ib_iser iSCSI cloud module to prevent an error during systemd-modules-load at boot
sudo sed -i "s/ib_iser/#ib_iser/g" /mnt/lib/modules-load.d/open-iscsi.conf
sudo sed -i "s/iscsi_tcp/#iscsi_tcp/g" /mnt/lib/modules-load.d/open-iscsi.conf

# % Fix update-initramfs mdadm.conf warning
grep "ARRAY devices" /mnt/etc/mdadm/mdadm.conf >/dev/null || echo "ARRAY devices=/dev/sda" | sudo -A tee -a /mnt/etc/mdadm/mdadm.conf >/dev/null;

# CHROOT

# % Copy hosts file to prevent slow sudo commands
sudo rm -f /mnt/etc/hosts
sudo cp extras/hosts /mnt/etc/hosts

# % Copy QEMU bin file so we can chroot into arm64 from x86_64
sudo cp -f /usr/bin/qemu-aarch64-static /mnt/usr/bin

# % Install new kernel modules
sudo mkdir -p /mnt/run/systemd/resolve
cat /run/systemd/resolve/stub-resolv.conf | sudo -A tee /mnt/run/systemd/resolve/stub-resolv.conf >/dev/null;
sudo touch /mnt/etc/modules-load.d/cups-filters.conf

# % Startup tweaks to fix bluetooth
sudo rm /mnt/etc/rc.local
cat << EOF | sudo tee /mnt/etc/rc.local
#!/bin/sh -e
#
# rc.local
#

# Enable bluetooth
if [ -n "`which hciattach`" ]; then
  echo "Attaching Bluetooth controller ..."
  hciattach /dev/ttyAMA0 bcm43xx 921600
fi

# % Fix crackling sound
if [ -n "`which pulseaudio`" ]; then
  GrepCheck=$(cat /etc/pulse/default.pa | grep "load-module module-udev-detect tsched=0")
  if [ ! -n "$GrepCheck" ]; then
    sed -i "s:load-module module-udev-detect:load-module module-udev-detect tsched=0:g" /etc/pulse/default.pa
  fi
fi

exit 0
EOF
sudo chmod +x /mnt/etc/rc.local

# % Enter Ubuntu image chroot
sudo chroot /mnt /bin/bash << EOF

# % Fix /lib/firmware permission and symlink
chown -R root /lib

# % Add symbolic link from /etc/firmware to /lib/firmware (fixes Bluetooth)
ln -s /lib/firmware /etc/firmware

# % Add updated mesa repository for video driver support
add-apt-repository ppa:ubuntu-x-swat/updates -y

# % Add Raspberry Pi Userland repository
sudo add-apt-repository ppa:ubuntu-raspi2/ppa

# % Hold Ubuntu packages that will break booting from the Pi 4
apt-mark hold flash-kernel linux-raspi2 linux-image-raspi2 linux-headers-raspi2 linux-firmware-raspi2

# % Remove linux-firmware-raspi2
apt remove linux-firmware-raspi2 --allow-change-held-packages -y

# % Update all software to current from Ubuntu apt repositories
apt update && apt dist-upgrade -y

# % INSTALL HAVAGED - prevents low entropy from making the Pi take a long time to start up.
apt install haveged -y

# % Install Bluetooth stack
apt install bluez -y

# % Install Wireless tools
apt install wireless-tools iw rfkill -y

# % Install Raspberry Pi userland utilities (vcgencmd, etc.)
apt install libraspberrypi-bin -y

# % Install raspi-config utility
apt install libnewt0.52 whiptail parted triggerhappy lua5.1 alsa-utils -y
wget https://archive.raspberrypi.org/debian/pool/main/r/raspi-config/raspi-config_20191005_all.deb
dpkg -i raspi-config_20191005_all.deb
rm raspi-config_20191005_all.deb
sed -i "s:/boot/config.txt:/boot/firmware/config.txt:g" /usr/bin/raspi-config
sed -i "s:/boot/cmdline.txt:/boot/firmware/cmdline.txt:g" /usr/bin/raspi-config
sed -i "s:armhf:arm64:g" /usr/bin/raspi-config
sed -i "s:/boot/overlays:/boot/firmware/overlays:g" /usr/bin/raspi-config
sed -i "s:/boot/start:/boot/firmware/start:g" /usr/bin/raspi-config
sed -i "s:/boot/arm:/boot/firmware/arm:g" /usr/bin/raspi-config
sed -i "s:/boot :/boot/firmware :g" /usr/bin/raspi-config
sed -i "s:\\/boot\.:\\/boot\\\/firmware\.:g" /usr/bin/raspi-config
sed -i "s:dtparam i2c_arm=$SETTING:dtparam -d /boot/firmware/overlays i2c_arm=$SETTING:g" /usr/bin/raspi-config
sed -i "s:dtparam spi=$SETTING:dtparam -d /boot/firmware/overlays spi=$SETTING:g" /usr/bin/raspi-config
sed -i "s:su pi:su $SUDO_USER:g" /usr/bin/dtoverlay-pre
sed -i "s:su pi:su $SUDO_USER:g" /usr/bin/dtoverlay-post

# % Add group and udev rule for i2c so it works for non-root Ubuntu user
groupadd i2c
usermod -aG i2c ubuntu
rm /etc/udev/rules.d/10-local_i2c_group.rules
echo 'KERNEL=="i2c-[0-9]*", GROUP="i2c"' >> /etc/udev/rules.d/10-local_i2c_group.rules

# % Remove ureadahead, does not support arm and makes our bootup unclean when checking systemd status
apt remove ureadahead libnih1 -y

# % Update initramfs
update-initramfs -u

# % Clean up after ourselves and clean out package cache to keep the image small
apt autoremove -y && apt clean && apt autoclean

# % Force fsck on next reboot
touch /forcefsck

EOF

# % Set regulatory crda to enable 5 Ghz wireless
sudo rm /mnt/etc/default/crda
cat << EOF | sudo tee /mnt/etc/default/crda
# Set REGDOMAIN to a ISO/IEC 3166-1 alpha2 country code so that iw(8) may set
# the initial regulatory domain setting for IEEE 802.11 devices which operate
# on this system.
#
# Governments assert the right to regulate usage of radio spectrum within
# their respective territories so make sure you select a ISO/IEC 3166-1 alpha2
# country code suitable for your location or you may infringe on local
# legislature. See `/usr/share/zoneinfo/zone.tab' for a table of timezone
# descriptions containing ISO/IEC 3166-1 alpha2 country codes.

REGDOMAIN=US
EOF

# % Set loopback address in hosts to prevent slow bootup
sudo rm /mnt/etc/hosts
cat << EOF | sudo tee /mnt/etc/hosts
127.0.0.1 localhost
127.0.1.1 ubuntu

# The following lines are desirable for IPv6 capable hosts
::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
ff02::3 ip6-allhosts
EOF

# % Remove any crash files generated during chroot
sudo rm /mnt/var/crash/*

# % Copy latest firmware to Ubuntu image
sudo rm -rf firmware-nonfree/.git*
sudo cp -ravf firmware-nonfree/* /mnt/lib/firmware

sudo fstrim -av
sudo e4defrag /mnt/*

# UNMOUNT

sudo umount /mnt/boot/firmware
sudo umount /mnt

# Run fsck on image
sudo fsck.ext4 -f -p -v -c /dev/mapper/"${MountXZ}"p2

# Save image
sudo kpartx -dv ubuntu-18.04.3-preinstalled-server-arm64+raspi4.img
