# kadadm - Keepalived administration
kadadm is used to inspect and maintain keepalived status and configuration through SNMP.

## Requirements
 - perl
 - net-snmp-perl
 - keepalived

## Installation
```
make
make install
```

## Configuration guide
 1. Enable keepalived SNMP subsystem by adding '-x' to KEEPALIVED_OPTIONS in /etc/sysconfig/keepalived:

 ```
 KEEPALIVED_OPTIONS="-Dx"
 ```

 2. Create a SNMPv3 user 'keepalived' (with password 'keepalived') by running:

 ```
 net-snmp-create-v3-user keepalived
 ```

 3. Allow access to KEEPALIVED-MIB subtree (read-only access for SNMPv2c 'public' community, read/write access for SNMPv3 user 'keepalived'), by adding the following lines to snmpd.conf(5):

 ```
 com2sec keepalived_user localhost none
 group keepalived_group usm keepalived_user
 view systemview included .1.3.6.1.4.1.9586.100.5
 view keepalived_view included .1.3.6.1.4.1.9586.100.5
 access keepalived_group "" usm priv exact keepalived_view keepalived_view none
 rwuser keepalived
 ```

 4. Restart snmpd(8) and keepalived(8):

 ```
 systemctl restart snmpd
 systemctl restart keepalived
 ```

## Documentation
Check the manual page of kadadm after installation.
