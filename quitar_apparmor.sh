ln -s /etc/apparmor.d/usr.sbin.dhcpd /etc/apparmor.d/disable
apparmor_parser -R /etc/apparmor.d/usr.sbin.dhcpd 
ln -s /etc/apparmor.d/usr.sbin.named /etc/apparmor.d/disable
apparmor_parser -R /etc/apparmor.d/usr.sbin.named 
ls -la /etc/apparmor.d/disable/