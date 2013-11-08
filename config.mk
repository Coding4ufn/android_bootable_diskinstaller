# note: requires x86 because we assume grub is the mbr bootloader.
ifeq ($(TARGET_ARCH),x86)
ifeq ($(TARGET_USE_DISKINSTALLER),true)

diskinstaller_root := bootable/diskinstaller

android_sysbase_modules := \
	libc \
	libcutils \
	libdl \
	liblog \
	libm \
	libstdc++ \
	linker \
	ash \
	toolbox \
	logcat \
	gdbserver \
	strace \
	netcfg
android_sysbase_files = \
	$(call module-installed-files,$(android_sysbase_modules))

# $(1): source base dir
# $(2): target base dir
define sysbase-copy-files
$(hide) $(foreach _f,$(android_sysbase_files), \
	f=$(patsubst $(1)/%,$(2)/%,$(_f)); \
	mkdir -p `dirname $$f`; \
	echo "Copy: $$f" ; \
	cp -fR $(_f) $$f; \
)
endef

installer_base_modules := \
	libdiskconfig \
	libext2fs \
	libext2_com_err \
	libext2_e2p \
	libext2_blkid \
	libext2_uuid \
	libext2_profile \
	badblocks \
	resize2fs \
	tune2fs \
	mke2fs \
	e2fsck
installer_base_files = \
	$(call module-built-files,$(installer_base_modules))

# $(1): source base dir
# $(2): target base dir
define installer-copy-modules
$(hide) $(foreach m,$(installer_base_modules), \
	src=$(firstword $(strip $(call module-built-files,$(m)))); \
	dest=$(patsubst $(strip $(1))/%,$(strip $(2))/%,\
		$(firstword $(strip $(call module-installed-files,$(m))))); \
	echo "Copy: $$src -> $$dest"; \
	mkdir -p `dirname $$dest`; \
	cp -fdp $$src $$dest; \
)
endef

# Build the installer ramdisk image
installer_initrc := $(diskinstaller_root)/init.rc
installer_kernel := $(INSTALLED_KERNEL_TARGET)
installer_ramdisk := $(TARGET_INSTALLER_OUT)/ramdisk-installer.img
installer_build_prop := $(INSTALLED_BUILD_PROP_TARGET)
installer_config := $(diskinstaller_root)/installer.conf
installer_binary := \
	$(call intermediates-dir-for,EXECUTABLES,diskinstaller)/diskinstaller
busybox_binary := \
	$(call intermediates-dir-for,EXECUTABLES,busybox)/busybox

$(installer_ramdisk): $(diskinstaller_root)/config.mk \
		$(MKBOOTFS) \
		$(INSTALLED_RAMDISK_TARGET) \
		$(INSTALLED_BOOTIMAGE_TARGET) \
		$(TARGET_DISK_LAYOUT_CONFIG) \
		$(installer_binary) \
		$(installer_initrc) \
		$(installer_kernel) \
		$(installer_config) \
		$(android_sysbase_files) \
		$(installer_base_files) \
		$(installer_build_prop)
	@echo ----- Making installer image ------
	rm -rf $(TARGET_INSTALLER_OUT)
	mkdir -p $(TARGET_INSTALLER_OUT)
	mkdir -p $(TARGET_INSTALLER_ROOT_OUT)
	mkdir -p $(TARGET_INSTALLER_ROOT_OUT)/sbin
	mkdir -p $(TARGET_INSTALLER_ROOT_OUT)/data
	mkdir -p $(TARGET_INSTALLER_SYSTEM_OUT)
	mkdir -p $(TARGET_INSTALLER_SYSTEM_OUT)/etc
	mkdir -p $(TARGET_INSTALLER_SYSTEM_OUT)/bin
	@echo Copying baseline ramdisk...
	cp -fR $(TARGET_ROOT_OUT) $(TARGET_INSTALLER_OUT)
	@echo Copying sysbase files...
	$(call sysbase-copy-files,$(TARGET_OUT),$(TARGET_INSTALLER_SYSTEM_OUT))
	@echo Copying installer base files...
	$(call installer-copy-modules,$(TARGET_OUT),\
		$(TARGET_INSTALLER_SYSTEM_OUT))
	@echo Modifying ramdisk contents...
	cp -f $(installer_initrc) $(TARGET_INSTALLER_ROOT_OUT)/
	cp -f $(TARGET_DISK_LAYOUT_CONFIG) \
		$(TARGET_INSTALLER_SYSTEM_OUT)/etc/disk_layout.conf
	cp -f $(installer_config) \
		$(TARGET_INSTALLER_SYSTEM_OUT)/etc/installer.conf
	cp -f $(installer_binary) $(TARGET_INSTALLER_SYSTEM_OUT)/bin/installer
	$(hide) chmod ug+rw $(TARGET_INSTALLER_ROOT_OUT)/default.prop
	cat $(installer_build_prop) >> $(TARGET_INSTALLER_ROOT_OUT)/default.prop
	cp -f $(busybox_binary) $(TARGET_INSTALLER_ROOT_OUT)/sbin/busybox
	ln -s $(TARGET_INSTALLER_ROOT_OUT)/sbin/mkfs.ext2 $(TARGET_INSTALLER_ROOT_OUT)/sbin/busybox 
	$(MKBOOTFS) $(TARGET_INSTALLER_ROOT_OUT) | gzip > $(installer_ramdisk)
	@echo ----- Made installer ramdisk -[ $@ ]-

######################################################################
# Now the installer boot image which includes the kernel and the ramdisk
internal_installerimage_args := \
	--kernel $(installer_kernel) \
	--ramdisk $(installer_ramdisk)

internal_installerimage_files := \
	$(filter-out --%,$(internal_installerimage_args))

BOARD_INSTALLER_CMDLINE := $(strip $(BOARD_INSTALLER_CMDLINE))
ifdef BOARD_INSTALLER_CMDLINE
  internal_installerimage_args += --cmdline "$(BOARD_INSTALLER_CMDLINE)"
endif

installer_tmp_img := $(TARGET_INSTALLER_OUT)/installer_tmp.img
tmp_dir_for_inst_image := \
	$(call intermediates-dir-for,EXECUTABLES,installer_img)/installer_img
internal_installerimage_args += --tmpdir $(tmp_dir_for_inst_image)
internal_installerimage_args += --genext2fs $(MKEXT2IMG)
$(installer_tmp_img): $(MKEXT2IMG) $(internal_installerimage_files)
	$(call pretty,"Target installer image: $@")
	$(hide) $(MKEXT2BOOTIMG) $(internal_installerimage_args) --output $@

######################################################################
# Now make a data image that contains all the target image files for the
# installer.

bootldr_bin := $(PRODUCT_OUT)/grub/grub.bin
installer_target_data_files := \
	$(INSTALLED_BOOTIMAGE_TARGET) \
	$(INSTALLED_SYSTEMIMAGE) \
	$(INSTALLED_USERDATAIMAGE_TARGET) \
	$(bootldr_bin)

# $(1): src directory
# $(2): output file
# $(3): mount point
# $(4): ext variant (ext2, ext3, ext4)
# $(5): size of the partition
define build-installerimage-ext-target
  @mkdir -p $(dir $(2))
    $(hide) PATH=$(foreach p,$(INTERNAL_USERIMAGES_BINARY_PATHS),$(p):)$(PATH) \
          $(MKEXTUSERIMG) $(1) $(2) $(4) $(3) $(5)
endef

installer_data_img := $(TARGET_INSTALLER_OUT)/installer_data.img
$(installer_data_img): $(diskinstaller_root)/config.mk \
			$(installer_target_data_files) \
			$(MKEXT2IMG) \
			$(installer_ramdisk)
	@echo --- Making installer data image ------
	mkdir -p $(TARGET_INSTALLER_OUT)
	mkdir -p $(TARGET_INSTALLER_OUT)/data
	cp -f $(bootldr_bin) $(TARGET_INSTALLER_OUT)/data/bootldr.bin
	cp -f $(INSTALLED_BOOTIMAGE_TARGET) $(TARGET_INSTALLER_OUT)/data/boot.img
	cp -f $(INSTALLED_SYSTEMIMAGE) \
		$(TARGET_INSTALLER_OUT)/data/system.img
	cp -f $(INSTALLED_USERDATAIMAGE_TARGET) \
		$(TARGET_INSTALLER_OUT)/data/userdata.img
	$(call build-installerimage-ext-target,$(TARGET_INSTALLER_OUT)/data,$@, \
		inst_data,ext4,$(BOARD_INSTALLERIMAGE_PARTITION_SIZE))
	@echo --- Finished installer data image -[ $@ ]-

######################################################################
# now combine the installer image with the grub bootloader
grub_bin := $(PRODUCT_OUT)/grub/grub.bin
installer_layout := $(diskinstaller_root)/installer_img_layout.conf
edit_mbr := $(HOST_OUT_EXECUTABLES)/editdisklbl

INSTALLED_DISK_INSTALLER_IMAGE_TARGET := $(PRODUCT_OUT)/installer.img
$(INSTALLED_DISK_INSTALLER_IMAGE_TARGET): \
					$(installer_tmp_img) \
					$(installer_data_img) \
					$(grub_bin) \
					$(edit_mbr) \
					$(installer_layout)
	@echo "Creating bootable installer image: $@"
	@rm -f $@
	$(hide) cat $(grub_bin) > $@
	@echo $(edit_mbr) -l $(installer_layout) -i $@ \
		inst_boot=$(installer_tmp_img) \
		inst_data=$(installer_data_img)
	$(hide) $(edit_mbr) -l $(installer_layout) -i $@ \
		inst_boot=$(installer_tmp_img) \
		inst_data=$(installer_data_img)
	@echo "Done with bootable installer image -[ $@ ]-"

#
# Ditto for the android_system_disk and android_data_disk images
#
qemu-image := qemu-img
qemu-image-options := create -f raw
MITRE_INSTALLED_CACHE := $(PRODUCT_OUT)/cache.img 
$(MITRE_INSTALLED_CACHE) :
	@echo create cache.img
	$(hide) $(qemu-image) \
		$(qemu-image-options) $(MITRE_INSTALLED_CACHE) 100M
MITRE_INSTALLED_SDCARD := $(PRODUCT_OUT)/sdcard.img 
$(MITRE_INSTALLED_SDCARD) :
	@echo create sdcard.img
	$(hide) $(qemu-image) \
		$(qemu-image-options) $(MITRE_INSTALLED_SDCARD) 100M
	mkfs.vfat $(MITRE_INSTALLED_SDCARD) 



INSTALLED_ANDROID_IMAGE_SYSTEM_TARGET := $(PRODUCT_OUT)/android_system_disk.img
android_system_layout := $(diskinstaller_root)/android_img_system_layout.conf

INSTALLED_ANDROID_IMAGE_DATA_TARGET := $(PRODUCT_OUT)/android_data_disk.img
android_data_layout := $(diskinstaller_root)/android_img_data_layout.conf

$(INSTALLED_ANDROID_IMAGE_SYSTEM_TARGET): \
					$(INSTALLED_SYSTEMIMAGE) \
					$(INSTALLED_BOOTIMAGE_TARGET) \
					$(grub_bin) \
					$(MITRE_INSTALLED_SDCARD) \
					$(edit_mbr) \
					$(android_system_layout)
	@echo "Creating bootable android system-disk image: $@"
	@rm -f $@
	$(hide) cat $(grub_bin) > $@
	@echo $(edit_mbr) -l $(android_system_layout) -i $@ \
		inst_boot=$(INSTALLED_BOOTIMAGE_TARGET) \
		inst_system=$(INSTALLED_SYSTEMIMAGE) \
		inst_sdcard=$(MITRE_INSTALLED_SDCARD);
	$(hide) $(edit_mbr) -l $(android_system_layout) -i $@ \
		inst_boot=$(INSTALLED_BOOTIMAGE_TARGET) \
		inst_system=$(INSTALLED_SYSTEMIMAGE)  \
		inst_sdcard=$(MITRE_INSTALLED_SDCARD);
	@echo "Done with bootable android system-disk image -[ $@ ]-"

#$(INSTALLED_ANDROID_IMAGE_DATA_TARGET): \
#					$(INSTALLED_USERDATAIMAGE_TARGET) \
#					$(INSTALLED_CACHEIMAGE_TARGET) \
#					$(grub_bin) \
#					$(edit_mbr) \
#					$(android_data_layout)
#	@echo "Creating bootable android data-disk image: $@"
#	@rm -f $@
#	$(hide) cat $(grub_bin) > $@
#	@echo $(edit_mbr) -l $(android_data_layout) -i $@ \
#		inst_data=$(INSTALLED_USERDATAIMAGE_TARGET) \
#		inst_cache=$(MITRE_INSTALLED_CACHE)
#		#inst_cache=$(INSTALLED_CACHEIMAGE_TARGET)
#	$(hide) $(edit_mbr) -l $(android_data_layout) -i $@ \
#		inst_data=$(INSTALLED_USERDATAIMAGE_TARGET) \
#		inst_cache=$(MITRE_INSTALLED_CACHE)
#	@echo "Done with bootable android data-disk image -[ $@ ]-"

$(INSTALLED_ANDROID_IMAGE_DATA_TARGET): device/mitre/svmp/data-disk-blanks/android_data_disk_4G.img.tar.gz
	@echo "Decompressing android data-disk image: $@"
	@rm -f $@
	$(hide) tar xzf $< -C $(PRODUCT_OUT)
	$(hide) mv $(PRODUCT_OUT)/android_data_disk_4G.img $(PRODUCT_OUT)/android_data_disk.img
	@echo "Done with bootable android data-disk image -[ $@ ]-"


######################################################################
# now convert the installer_img (disk image) to a VirtualBox image

INSTALLED_VBOX_INSTALLER_IMAGE_TARGET := $(PRODUCT_OUT)/installer.vdi
qemu_img := qemu-img
# hrd-code the UUID so we don't have to release the disk manually in the VirtualBox manager.
qemu_img_options := convert -O vdi
vmware_manager_options := convert -O vmdk
#qemu_img_system_disk_ptions := --uuid "{aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa}"
#qemu_img_data_disk_ptions   := --uuid "{bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb}"

$(INSTALLED_VBOX_INSTALLER_IMAGE_TARGET): $(INSTALLED_DISK_INSTALLER_IMAGE_TARGET)
	@rm -f $(INSTALLED_VBOX_INSTALLER_IMAGE_TARGET)
	$(hide) $(qemu_img) $(qemu_img_options) $(INSTALLED_DISK_INSTALLER_IMAGE_TARGET) $(INSTALLED_VBOX_INSTALLER_IMAGE_TARGET)
	@echo "Done with VirtualBox bootable installer image -[ $@ ]-"

#
# Ditto for the android_system_disk and android_user_disk images
#

INSTALLED_VBOX_SYSTEM_DISK_IMAGE_TARGET := $(PRODUCT_OUT)/android_system_disk.vdi
$(INSTALLED_VBOX_SYSTEM_DISK_IMAGE_TARGET): $(INSTALLED_ANDROID_IMAGE_SYSTEM_TARGET)
	@rm -f $@
	$(hide) $(qemu_img) \
		$(qemu_img_options) \
		$^ $@
	@echo "Done with VirtualBox bootable system-disk image -[ $@ ]-"

INSTALLED_VMWARE_SYSTEM_DISK_IMAGE_TARGET := $(PRODUCT_OUT)/android_system_disk.vmdk
$(INSTALLED_VMWARE_SYSTEM_DISK_IMAGE_TARGET): $(INSTALLED_ANDROID_IMAGE_SYSTEM_TARGET)
	@rm -f $@
	$(hide) $(qemu_img) \
		$(vmware_manager_options) \
		$^ $@
	@echo "Done with VMWARE bootable system-disk image -[ $@ ]-"

INSTALLED_VBOX_DATA_DISK_IMAGE_TARGET := $(PRODUCT_OUT)/android_data_disk.vdi
INSTALLED_VMWARE_DATA_DISK_IMAGE_TARGET := $(PRODUCT_OUT)/android_data_disk.vmdk
$(INSTALLED_VBOX_DATA_DISK_IMAGE_TARGET): $(INSTALLED_ANDROID_IMAGE_DATA_TARGET)
	@rm -f $@
	$(hide) $(qemu_img) \
		$(qemu_img_options) \
		$(qemu_img_data_disk_ptions) \
		$^ $@
	@echo "Done with VirtualBox bootable data-disk image -[ $@ ]-"
$(INSTALLED_VMWARE_DATA_DISK_IMAGE_TARGET): $(INSTALLED_ANDROID_IMAGE_DATA_TARGET)
	@rm -f $@
	$(hide) $(qemu_img) \
		$(vmware_manager_options) \
		$(qemu_img_data_disk_ptions) \
		$^ $@
	@echo "Done with VirtualBox bootable data-disk image -[ $@ ]-"

.PHONY: installer_img
installer_img: $(INSTALLED_DISK_INSTALLER_IMAGE_TARGET)

.PHONY: installer_vdi
installer_vdi: $(INSTALLED_VBOX_INSTALLER_IMAGE_TARGET)

INSTALLED_ANDROID_IMAGE_SYSTEM_TARGET := $(PRODUCT_OUT)/android_system_disk.img
android_system_layout := $(diskinstaller_root)/android_img_system_layout.conf

INSTALLED_ANDROID_IMAGE_DATA_TARGET := $(PRODUCT_OUT)/android_data_disk.img
android_data_layout := $(diskinstaller_root)/android_img_data_layout.conf
.PHONY: android_disk_vdi android_system_disk_vdi android_system_disk_vmdk \
       	android_data_disk_vdi android_data_disk_vmdk android_disk_zip \
       	android_disk_zip_vdi android_disk_zip_vmdk

android_system_disk_vdi: $(INSTALLED_VBOX_SYSTEM_DISK_IMAGE_TARGET)
android_system_disk_vmdk: $(INSTALLED_VMWARE_SYSTEM_DISK_IMAGE_TARGET)
android_data_disk_vdi: $(INSTALLED_VBOX_DATA_DISK_IMAGE_TARGET)
android_data_disk_vdi: $(INSTALLED_VMWARE_DATA_DISK_IMAGE_TARGET)
android_system_disk_vmdk: $(INSTALLED_VMWARE_DATA_DISK_IMAGE_TARGET)
android_system_disk: $(INSTALLED_ANDROID_IMAGE_SYSTEM_TARGET)
android_data_disk: $(INSTALLED_ANDROID_IMAGE_DATA_TARGET)
android_mitre_images: $(MITRE_INSTALLED_CACHE) $(INSTALLED_USERDATAIMAGE_TARGET) 
# $(MITRE_INSTALLED_USER_DATA) 
android_disk_vdi:  android_system_disk_vdi android_data_disk_vdi
android_disk_vmdk: android_system_disk_vmdk android_data_disk_vmdk
android_disk_raw: android_mitre_images android_system_disk android_data_disk
android_disk_zip: android_disk_raw
	@echo creating raw image zip file
	$(hide) cd $(PRODUCT_OUT); tar  -czf rawimage.tar.gz android_system_disk.img
	@echo zip file is in $(PRODUCT_OUT)/rawimage.tar.gz
android_disk_zip_vdi: android_system_disk_vdi
	@echo creating virtualbox image zip file
	$(hide) cd $(PRODUCT_OUT); tar  -czf vdiimage.tar.gz android_system_disk.vdi
	@echo zip file is in $(PRODUCT_OUT)/vdiimage.tar.gz
android_disk_zip_vmdk: android_system_disk_vmdk
	@echo creating vmware image zip file
	$(hide) cd $(PRODUCT_OUT); tar  -czf vmdkimage.tar.gz android_system_disk.vmdk
	@echo zip file is in $(PRODUCT_OUT)/vmdkimage.tar.gz
else  # ! TARGET_USE_DISKINSTALLER
INSTALLED_DISK_INSTALLER_IMAGE_TARGET :=
INSTALLED_VBOX_SYSTEM_DISK_IMAGE_TARGET :=
INSTALLED_VBOX_DATA_DISK_IMAGE_TARGET :=
endif
endif # TARGET_ARCH == x86
