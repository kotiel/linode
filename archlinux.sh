#!/bin/bash
# Defines the variables needed for deployment with this script.
#
# <UDF name="hostname" label="The hostname for the new Linode.">
# <UDF name="fqdn" label="The new Linode's Fully Qualified Domain Name">
# <UDF name="sshport" label="Change the port that the SSH service runs on, security by obscurity, but mostly just to keep the logs clean">
# <UDF name="sudo_username" label="A username to create a user for sudo usage, non-root access">
# <UDF name="git_email" label="An email address for configuring git.">
# <UDF name="sudo_userpassword" label="Password for the user account for sudo usage, non-root access">
# <UDF name="sudo_userkey" label="SSH Public Key for account login, much more secure than password login">

# This sets the variable $IPADDR to the IPv4 address the new Linode receives.
IPADDR=$(ip a s|sed -ne '/127.0.0.1/!{s/^[ \t]*inet[ \t]*\([0-9.]\+\)\/.*$/\1/p}')

# This updates the system to the latest updates using pacman
# initial needfuls
pacman -Syu --noconfirm
pacman -S --noconfirm net-tools git tmux base-devel postgresql vim iptables openssh
pacman -S --noconfirm sudo nodejs npm zsh curl wget ncurses python redis mongodb
pacman -S --noconfirm wget coreutils haproxy expect htop mc imagemagick
pacman -S --noconfirm lighttpd phppgadmin php php-pgsql php-fpm php-gd php-mcrypt php-intl php-cgi

# Linode network-card name fix
ln -s /dev/null /etc/udev/rules.d/80-net-setup-link.rules

#set up IPTABLES
cat << EOF > /etc/iptables/iptables.rules
*filter
# Allow all loopback (lo0) traffic and reject traffic
# to localhost that does not originate from lo0.
-A INPUT -i lo -j ACCEPT
-A INPUT ! -i lo -s 127.0.0.0/8 -j REJECT
#
# Allow inbound traffic from established connections.
# This includes ICMP error returns.
-A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
#
#  Allow all outbound traffic - you can modify this to only allow certain traffic
-A OUTPUT -j ACCEPT
#
# Allow HTTP and HTTPS connections from anywhere
# (the normal ports for web servers).
-A INPUT -p tcp --dport 80 -m state --state NEW -j ACCEPT
-A INPUT -p tcp --dport 443 -m state --state NEW -j ACCEPT
-A INPUT -p tcp --dport $SSHPORT -j ACCEPT
#-A INPUT -p tcp --dport 2000 -j ACCEPT
#
# Allow SSH connections.
#  The -dport number should be the same port number you set in sshd_config
-A INPUT -p tcp --dport $SSHPORT -m state --state NEW -j ACCEPT

# Allow ping.
#-A INPUT -p icmp -m state --state NEW --icmp-type 8 -j ACCEPT
-A INPUT -p icmp --icmp-type echo-request -j DROP
# Allow incoming Longview connections.
# -A INPUT -s longview.linode.com -m state --state NEW -j ACCEPT
# Allow incoming NodeBalancer connections.
# -A INPUT -s 192.168.255.0/24 -m state --state NEW -j ACCEPT

# Log what was incoming but denied (optional but useful).
# Log iptables denied calls
-A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables_INPUT_denied: " --log-level 7
#
#  Drop all other inbound - default deny unless explicitly allowed policy
# Reject all other inbound.
#-A INPUT -j REJECT
-A INPUT -j DROP
#
# Reject all traffic forwarding.
#-A FORWARD -j REJECT
-A FORWARD -j DROP
COMMIT
EOF

sudo iptables-restore < /etc/iptables/iptables.rules
sudo systemctl start iptables haproxy
sudo systemctl enable iptables haproxy

# fix locale errors
locale -a
sed -i 's/#en_GB.UTF-8 UTF-8/en_GB.UTF-8 UTF-8/g' /etc/locale.gen
sed -i 's/#en_GB ISO-8859-1/en_GB ISO-8859-1/g' /etc/locale.gen
sed -i 's/en_US.UTF-8 UTF-8/#en_US.UTF-8 UTF-8/g' /etc/locale.gen
locale-gen
locale -a
# locale.conf
cat << EOF > /etc/locale.conf
LANG=en_GB.utf8
EOF
localectl set-locale LANG=en_GB.utf8
timedatectl set-timezone 'Europe/London'

# This section sets the hostname on the account
hostnamectl set-hostname $FQDN

# This section updates the /etc/hosts file
echo $IPADDR $FQDN $HOSTNAME >> /etc/hosts

# This section adds the new user for sudo usage
groupadd $SUDO_USERNAME
useradd  -m -g $SUDO_USERNAME -G wheel -s /bin/bash $SUDO_USERNAME
echo "$SUDO_USERNAME:$SUDO_USERPASSWORD" | chpasswd
usermod -aG http,postgres $SUDO_USERNAME
cp -a /etc/skel/.[a-z]* /home/$SUDO_USERNAME
chown -R $SUDO_USERNAME:$SUDO_USERNAME /home/$SUDO_USERNAME

# This section adds the user's public key to the server and configures the files/folders
mkdir -p /home/$SUDO_USERNAME/.ssh
echo "$SUDO_USERKEY" >> /home/$SUDO_USERNAME/.ssh/authorized_keys
chown -R $SUDO_USERNAME:$SUDO_USERNAME /home/$SUDO_USERNAME/.ssh
chmod go-w /root/
chmod go-w /home/$SUDO_USERNAME/
chmod 700 /home/$SUDO_USERNAME/.ssh
chmod 600 /home/$SUDO_USERNAME/.ssh/authorized_keys

# This section secures the SSH daemon
sed -i 's/#Port 22/Port '$SSHPORT'/' /etc/ssh/sshd_config
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
echo "AllowGroups wheel" >> /etc/ssh/sshd_config
sed -i 's/# %wheel ALL=(ALL) NOPASSWD: ALL/%wheel ALL=(ALL) NOPASSWD: ALL/g' /etc/sudoers
echo 'AddressFamily inet' | sudo tee -a /etc/ssh/sshd_config
systemctl reload sshd

# Add a few useful aliases to .bashrc
echo "alias update='sudo pacman -Syu'" >> /home/$SUDO_USERNAME/.bashrc
echo "alias install='sudo pacman --noconfirm -S'" >> /home/$SUDO_USERNAME/.bashrc
echo "alias free='free -m'" >> /home/$SUDO_USERNAME/.bashrc
echo "alias df='sudo df -h'" >> /home/$SUDO_USERNAME/.bashrc

# Basic git configuration
git config --global user.email "$GIT_EMAIL"
git config --global user.name "$SUDO_USERNAME"
mv ~/.gitconfig /home/$SUDO_USERNAME/.gitconfig
chown $SUDO_USERNAME:$SUDO_USERNAME /home/$SUDO_USERNAME/.gitconfig
chmod 664 /home/$SUDO_USERNAME/.gitconfig

# Config postgres
echo "postgres:postgres" | chpasswd
#sudo -u postgres -i initdb --locale $LANG -E UTF8 -D '/var/lib/postgres/data'
#sudo systemctl start postgresql.service
#sudo systemctl enable postgresql.service

echo "UUID=0e4dd9bd-459f-4d6e-9a1c-be304d8624e3 /mnt/loop01 ext4 defaults,rw 0 2" >> /etc/fstab
echo "#/dev/disk/by-id/scsi-0Linode_Volume_loop01 /mnt/loop01 ext4 defaults,rw 0 2" >> /etc/fstab
mkdir /mnt/loop01
mount /dev/disk/by-id/scsi-0Linode_Volume_loop01 /mnt/loop01
chmod g+w /mnt/loop01/
# Only the first time when initdb not done - as Volume is permanent
#mkdir -p /mnt/loop01/pgroot/data
#chown -R postgres:postgres /mnt/loop01/pgroot
#chmod -R 751 /mnt/loop01/pgroot

# Setup postgres database pgroot
#su - postgres
#initdb --locale $LANG -E UTF8 -D '/mnt/loop01/pgroot/data'
#sudo systemctl edit postgresql.service
#[Service]
#Environment=PGROOT=/mnt/loop01/pgroot
#PIDFile=/mnt/loop01/pgroot/data/postmaster.pid

#gitolite
pacman -S --noconfirm gitolite
groupadd gitdev
useradd -b /var/lib -l -g gitdev -s /bin/bash gitdev
echo "gitdev:gitdev" | chpasswd

#jupyter
#ln -s /var/lib/jupyter/bower_components/MathJax /usr/share/jupyter/nbextensions/MathJax
#ln -s /usr/bin/python3-config python-config
#ln -s /usr/bin/python python

# Reboot the server, ready to go
#shutdown -r now
