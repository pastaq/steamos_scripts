VER=$1

if [ -z "$VER" ]; then
  echo "Error: The kernel verison is empty or not provided."
  exit 1
else
  echo "Installing kernel version $VER"
fi

if  [ ! -f "linux-${VER}-x86.tar.zst" ]; then
  echo "Error: linux-${VER}-x86.tar.zst not present."
  exit 1
fi

if [ -f oldver ]; then
	OLD_VER="$(cat oldver)"
	BOOT_PATH="/boot/*${OLD_VER}*"
	MOD_PATH="/lib/modules/*${OLD_VER}*"
	sudo rm -rf $BOOT_PATH $MOD_PATH
	echo "Removed old kernel version $OLD_VER"
fi

sudo tar -C / --zstd -xvf linux-${VER}-x86.tar.zst --keep-directory-symlink && rm linux-*
sudo mkinitcpio -k ${VER} -g /boot/initramfs-${VER}.img
sudo update-grub
sudo sync

echo $VER > oldver
echo "Installed kernel version $VER"
