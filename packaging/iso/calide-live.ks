# CaliDE live ISO (Fedora 45). Built by .github/workflows/iso.yml with
# livemedia-creator --no-virt. Boots into Cali through GDM as "liveuser";
# "Install to Hard Drive" in the app grid runs Fedora's installer.
#
# The workflow serves the freshly built sookie and calide RPMs from
# file:///cali-repo.

lang en_US.UTF-8
keyboard us
timezone UTC
selinux --enforcing
firewall --enabled --service=mdns
network --bootproto=dhcp --device=link --activate
xconfig --startxonboot
services --disabled=sshd --enabled=NetworkManager,ModemManager,livesys,livesys-late,gdm
rootpw --lock
shutdown
bootloader --location=none
clearpart --all --initlabel
reqpart
part / --size=9000

url --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-45&arch=x86_64
repo --name=fedora-updates --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f45&arch=x86_64
repo --name=cali --baseurl=file:///cali-repo

# GitHub release assets must stay under 2 GiB, so the image carries no docs,
# no printing stack and only the core fonts. The workflow fails the build if
# the ISO grows past the limit again.
%packages --excludedocs
# Live system and installer
kernel
kernel-modules
dracut-live
dracut-config-generic
# checkisomd5 for the "Test this media" boot entry (the GRUB default); dracut
# only puts it in the initramfs when it's installed, and without it the check
# fails at once and the boot halts.
isomd5sum
livesys-scripts
anaconda-live
@anaconda-tools
glibc-langpack-en
shim-x64
grub2-efi-x64
grub2-efi-x64-cdboot
grub2-pc
grub2-tools
efibootmgr

# Base system
@core
@hardware-support
@multimedia
@networkmanager-submodules
# Core fonts only; @fonts pulls in the CJK families (hundreds of MB).
default-fonts-core-sans
default-fonts-core-serif
default-fonts-core-mono
default-fonts-core-emoji
default-fonts-core-math

# Cali, with GNOME's login screen and apps (GNOME users feel at home)
calide
sookie
gdm
mate-polkit
python3-gobject
orca
gnome-keyring
gnome-control-center
nautilus
ptyxis
gnome-text-editor
loupe
gnome-disk-utility
gnome-system-monitor
file-roller
firefox
flatpak
xdg-user-dirs-gtk
adwaita-icon-theme
NetworkManager-wifi
bluez
upower
power-profiles-daemon
pipewire
wireplumber

-@dial-up
-@input-methods
-gnome-boxes
-gnome-initial-setup
%end

%post
# Live session setup for Cali (livesys runs sessions.d/livesys-<session>).
cat > /usr/libexec/livesys/sessions.d/livesys-cali << 'FOE'
#!/usr/bin/sh
# Log liveuser straight into Cali.
cat > /etc/gdm/custom.conf << EOS
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=liveuser
EOS
mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/liveuser << EOS
[User]
Session=cali
SystemAccount=false
EOS

# Show the installer in the app grid.
if [ -f /usr/share/applications/liveinst.desktop ]; then
  sed -i -e 's/NoDisplay=true/NoDisplay=false/' /usr/share/applications/liveinst.desktop
fi
# Dock favorites for the live session, the installer last.
mkdir -p /etc/xdg/cali
cat > /etc/xdg/cali/cali.toml << EOS
dock-favorites = ["org.mozilla.firefox.desktop", "org.gnome.Nautilus.desktop", "org.gnome.Ptyxis.desktop", "org.gnome.TextEditor.desktop", "org.calide.Settings.desktop", "liveinst.desktop"]
EOS

# Skip installer pages the live user already went through.
cat >> /etc/sysconfig/anaconda << EOS
[NetworkSpoke]
visited=1
EOS

# Starting the installer needs no password.
cat > /usr/share/polkit-1/rules.d/20-livesys-cali.rules << EOS
polkit.addRule(function(action, subject) {
    if (subject.local && subject.user === 'liveuser' &&
        action.id.indexOf('org.fedoraproject.pkexec.liveinst') === 0)
        return 'yes';
    return undefined;
});
EOS
FOE
chmod 755 /usr/libexec/livesys/sessions.d/livesys-cali
sed -i 's/^livesys_session=.*/livesys_session="cali"/' /etc/sysconfig/livesys

# New users (on an installed system too) get Cali by default.
mkdir -p /etc/accountsservice
cat > /usr/share/accountsservice/user-templates/standard << 'FOE'
[User]
Session=cali
FOE

systemctl enable tmp.mount
rm -f /var/lib/systemd/random-seed
rm -f /boot/*-rescue*
rm -f /etc/machine-id
touch /etc/machine-id
%end
