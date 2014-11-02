#!/usr/bin/env perl
#
# kadadm:      Keepalived administration
#
# Authors:     Ilya Voronin <ivoronin@jet.msk.su>
#
#              This program is free software; you can redistribute it and/or
#              modify it under the terms of the GNU General Public License
#              as published by the Free Software Foundation; either version
#              2 of the License, or (at your option) any later version.
#

use strict;
use warnings FATAL => 'all';
use Getopt::Long;
use Data::Dumper;
use Pod::Usage;
use SNMP;

$main::VERSION = '0.1';

# Data::Dumper options
$Data::Dumper::Pad = 'DEBUG: ';
$Data::Dumper::Indent = 1;
$Data::Dumper::Terse = 1;

# GetOpt::Long options
Getopt::Long::Configure('no_ignore_case');
Getopt::Long::Configure('auto_help');
Getopt::Long::Configure('auto_version');

# Global Flags
my $verbose;
my $debug;
my $headers = 1;

# Configuration defaults
my $config = {
    'snmp_hostname' => 'localhost',
    'snmp_version' => '3',
    'snmp_community' => 'keepalived',
    'snmp_username' => 'keepalived',
    'snmp_authkey' => 'keepalived',
    'snmp_privkey' => 'keepalived',
    'snmp_seclevel' => 'authPriv'
};

# Global variable
my $snmp_session;

# Converts octet string to dot-decimal notation
sub hex2ip($) { 
    return sprintf('%*vi', '.', shift);
}

sub humanize($$$) {
    my ($num, $base, $suffixes) = @_;
    my $factor = 0;
    while ( $num > $base and $factor < $#{$suffixes} ) {
        $num /= $base;
        $factor++;
    }
    return sprintf('%.1f%s', $num, ${$suffixes}[$factor]);
}

sub humanize_count($) {
    return humanize(shift, 1000, [' ', 'k', 'M']);
}

sub humanize_bytes($) {
    return humanize(shift, 1024, [' ', 'K', 'M', 'G', 'T']);
}

# Reads configuration file ~/.kadadmrc and updates $config with new values
sub config_read() {
    open(CONFIG, $ENV{'HOME'} . '/.kadadmrc') or return;
    while ( my $line = <CONFIG> ) {
        chomp($line);
        next if ($line =~ /^#/);
        my ($parameter, $value) = split(/ +/, $line, 2);
        if (exists $config->{$parameter}) {
            $config->{$parameter} = $value;
        } else {
            die "Unknown configuration parameter: $parameter\n";
        }
    }
}

sub snmp_create_session() {
    my $snmp_options = {
        'Version' => $config->{'snmp_version'},
        'DestHost' => $config->{'snmp_hostname'},
        'Community' => $config->{'snmp_community'},
        'SecLevel' => $config->{'snmp_seclevel'},
        'SecName' => $config->{'snmp_username'},
        'AuthPass' => $config->{'snmp_authkey'},
        'PrivPass' => $config->{'snmp_privkey'}
    };

    $snmp_session = new SNMP::Session(
        %$snmp_options
    ) or die "kadadm: cannot create SNMP session\n";
}

sub snmp_die_on_error() {
    if ($snmp_session->{'ErrorNum'}) {
        die("kadadm: SNMP error: " . $snmp_session->{'ErrorStr'} . "\n");
    }
}

sub snmp_get_table($) {
    my $table = $snmp_session->gettable(shift);
    snmp_die_on_error();
    print Dumper($table) if $debug;
    return $table;
}

sub snmp_set_value($$$) {
    my ($object, $instance, $value) = @_;
    my $vars = new SNMP::Varbind([$object, $instance, $value]);
    print Dumper($vars) if $debug;
    $snmp_session->set($vars);
    snmp_die_on_error();
}

sub show_virtual_routers($) {
    my $vr = shift; # Virtual router index
    my $found;
    my %states = qw(0 init 1 backup 2 master 3 fault 4 unknown);

    my $table = snmp_get_table('KEEPALIVED-MIB::vrrpInstanceTable') or goto out;

    my $fmt = "%-3s %-12s %-12s %-4s %-8s %-4s %-4s %-7s %-9s %-7s\n";

    while (my ($i, $row) = each $table) {
        next if ( $vr and $vr ne $i );

        printf($fmt, 'VR#', 'NAME', 'GROUP', 'VRID', 'IFACE', 'BPRI', 'EPRI',
            'PREEMPT', 'ADDRESSES', 'STATE') if $headers and not $found;

        $found++;

        printf($fmt,
            $i,
            $row->{'vrrpInstanceName'},
            $row->{'vrrpInstanceSyncGroup'} || '-',
            $row->{'vrrpInstanceVirtualRouterId'},
            $row->{'vrrpInstancePrimaryInterface'},
            $row->{'vrrpInstanceBasePriority'},
            $row->{'vrrpInstanceEffectivePriority'},
            $row->{'vrrpInstancePreempt'} == 1 ? 'yes' : 'no',
            $row->{'vrrpInstanceVipsStatus'} == 1 ? 'allSet' : 'notAllSet',
            $states{$row->{'vrrpInstanceState'}} || '?',
        );
    }

out:
    die("No virtual routers found\n") if not $found;
}

sub show_virtual_addresses($) {
    my $vr = shift; # Virtual router index
    my $found;

    my $table = snmp_get_table('KEEPALIVED-MIB::vrrpAddressTable') or goto out;

    my $fmt = "%-5s %-15s %-6s %-8s %-6s\n";

    while (my ($i, $row) = each $table) {
        next if ( $vr and $vr ne $i );

        printf($fmt, 'VA#', 'ADDRESS', 'PREFIX', 'IFACE', 'STATUS')
            if $headers and not $found;

        $found++;

        printf($fmt,
            $i,
            hex2ip($row->{'vrrpAddressValue'}),
            $row->{'vrrpAddressMask'},
            $row->{'vrrpAddressIfName'},
            $row->{'vrrpAddressStatus'} == 1 ? 'set' : 'unset',
        );
    }

out:
    die("No virtual addresses found\n") if not $found;
}

sub show_virtual_servers($) {
    my $vs = shift; # Virtual server index
    my $found;

    my $table = snmp_get_table('KEEPALIVED-MIB::virtualServerTable') or goto out;

    my $fmt = "%-3s %-15s %-5s %-6s %-6s %-6s %-8s %-8s %-8s %-8s %-8s\n";

    while (my ($i, $row) = each $table) {
        next if ( $vs and $vs ne $i );

        printf($fmt, 'VS#', 'ADDRESS', 'PORT', 'STATUS', 'TOT_RS', 'UP_RS',
            'CPS', 'IPPS', 'OPPS', 'IBPS', 'OBPS') if $headers and not $found;

        $found++;

        printf($fmt,
            $i,
            hex2ip($row->{'virtualServerAddress'}),
            $row->{'virtualServerPort'},
            $row->{'virtualServerStatus'} == 1 ? 'alive' : 'dead',
            $row->{'virtualServerRealServersTotal'},
            $row->{'virtualServerRealServersUp'},
            humanize_count($row->{'virtualServerRateCps'}),
            humanize_count($row->{'virtualServerRateInPPS'}),
            humanize_count($row->{'virtualServerRateOutPPS'}),
            humanize_bytes($row->{'virtualServerRateInBPS'}),
            humanize_bytes($row->{'virtualServerRateOutBPS'}),
        );
    }

out:
    die("No virtual servers found\n") if not $found;
}

sub show_real_servers($) {
    my $rs = shift; # Real server index
    my $found = 0;

    my $table = snmp_get_table('KEEPALIVED-MIB::realServerTable') or goto out;

    my $fmt = "%-5s %-15s %-5s %-6s %-6s %-9s %-11s %-8s %-8s %-8s %-8s %-8s\n";

    while (my ($i, $row) = each $table) {
        next if ( $rs and $rs ne $i );

        printf($fmt, 'VS#', 'ADDRESS', 'PORT', 'WEIGHT', 'STATUS', 
                'ACT_CONNS', 'INACT_CONNS', 'CPS', 'IPPS', 'OPPS',
                'IBPS', 'OBPS') if $headers and not $found;

        $found++;

        printf($fmt, 
            $i,
            hex2ip($row->{'realServerAddress'}),
            $row->{'realServerPort'},
            $row->{'realServerWeight'},
            $row->{'realServerStatus'} == 1 ? 'alive' : 'dead',
            $row->{'realServerStatsActiveConns'},
            $row->{'realServerStatsInactiveConns'},
            humanize_count($row->{'realServerRateCps'}),
            humanize_count($row->{'realServerRateInPPS'}),
            humanize_count($row->{'realServerRateOutPPS'}),
            humanize_bytes($row->{'realServerRateInBPS'}),
            humanize_bytes($row->{'realServerRateOutBPS'}),
        );
    }

out:
    die("No real servers found\n") if not ( $found );
}

sub set_virtual_router_priority($$) {
    my ($vr, $pri) = @_;
    snmp_set_value('KEEPALIVED-MIB::vrrpInstanceBasePriority', $vr, $pri);
}

sub set_virtual_router_preempt($$) {
    my ($vr, $preempt) = @_;
    if ( $preempt eq 'yes' ) {
        snmp_set_value('KEEPALIVED-MIB::vrrpInstancePreempt', $vr, 1);
    } elsif ( $preempt eq 'no' ) {
        snmp_set_value('KEEPALIVED-MIB::vrrpInstancePreempt', $vr, 2);
    } else {
        pod2usage('preempt value should be "yes" or "no"');
    }
}

sub set_real_server_weight($$) {
    my ($rs, $weight) = @_;
    snmp_set_value('KEEPALIVED-MIB::realServerWeight', $rs, $weight);
}

sub start_exabgp_healthcheck() {
    sub command($$) {
        my ($address, $status) = @_;
        printf("%s %s/32 next-hop self\n", $status, $address);
    }

    sub announce($) {
        command(shift, 'announce');
    }

    sub withdraw($) {
        command(shift, 'withdraw');
    }
        
    my $address_statuses_prev = {};

    while () {
        my $table = snmp_get_table('KEEPALIVED-MIB::vrrpAddressTable');
        my $address_statuses = {};

        while (my ($i, $row) = each $table) {
            my $address = hex2ip($row->{'vrrpAddressValue'});
            my $status = $row->{'vrrpAddressStatus'} == 1 ? 'set' : 'unset';

            if ( not exists $address_statuses_prev->{$address} ) {
                # New address found, mark it as unset
                $address_statuses->{$address} = 'unset';
            } else {
                # Address was present at the previous run, copy its status
                $address_statuses->{$address} = $address_statuses_prev->{$address};
            }

            if ($status ne $address_statuses->{$address}) {
                # Status differs from previous one
                $status eq 'set' ? announce($address) : withdraw($address);
                $address_statuses->{$address} = $status;
            }
        }

        # Check for disappeared addresses
        while (my ($address, $status) = each $address_statuses_prev) {
            if ( (not exists $address_statuses->{$address}) and ($status eq 'set')) {
                # Address is not present anymore but it was announced, we need to withdraw it
                withdraw($address);
            }
        }

        $address_statuses_prev = $address_statuses;
        sleep(1);
    }
}

sub main() {
    # Managed objects
    my $virtual_router;
    my $virtual_address;
    my $virtual_server;
    my $real_server;
    my $exabgp_healthcheck;

    # Parameter and value
    my $parameter;
    my $value;

    GetOptions(
        # Global flags
        'verbose|V' => \$verbose,
        'debug|D' => \$debug,
        'noheaders|H' => sub { $headers = 0 },

        # Managed objects
        'virtual-routers|r:s' => \$virtual_router,
        'virtual-addresses|a:s' => \$virtual_address,
        'virtual-servers|e:s' => \$virtual_server,
        'real-servers|i:s' => \$real_server,

        # ExaBGP healthcheck mode
        'exabgp-healthcheck|b' => \$exabgp_healthcheck,

        # Parameter and value
        'parameter|p=s' => \$parameter,
        'value|v=s' => \$value,
    ) or pod2usage();

    # Exactly one object should be specified
    if ( not (defined $virtual_router xor
            defined $virtual_address xor 
            defined $virtual_server xor 
            defined $real_server xor
            (defined $exabgp_healthcheck xor ($parameter or $value))) ) {
        pod2usage('Missing or conflicting options');
    }

    config_read();
    snmp_create_session();

    pod2usage('Wrong number of arguments') if ($#ARGV != -1);

    if ( $exabgp_healthcheck ) {
        start_exabgp_healthcheck();
    }

    if ( not (defined $parameter or defined $value) ) {
        # List
        show_virtual_routers($virtual_router) if ( defined $virtual_router );
        show_virtual_addresses($virtual_address) if ( defined $virtual_address );
        show_virtual_servers($virtual_server) if ( defined $virtual_server );
        show_real_servers($real_server) if ( defined $real_server );
    } else {
        # Modify
        if ( not (defined $parameter and defined $value) ) {
            pod2usage('Both parameter and value should be specified');
        }

        if ( not ($virtual_router xor $virtual_address xor
                $virtual_server xor $real_server) ) {
            pod2usage('Missing option value');
        }

        if ( $virtual_router and $parameter eq 'priority' ) {
            set_virtual_router_priority($virtual_router, $value);
        } elsif ( $virtual_router and $parameter eq 'preempt' ) {
            set_virtual_router_preempt($virtual_router, $value);
        } elsif ( $real_server and $parameter eq 'weight' ) {
            set_real_server_weight($real_server, $value);
        } else {
            pod2usage('Unknown parameter name');
        }
    }
}

main();

__END__
=head1 NAME

kadadm - Keepalived administration

=head1 SYNOPSIS

 kadadm <-r [vr]|-a [vr]|-e [vs]|-i [rs]> [-VDH]
 kadadm -r <vr> -p priority -v <0-255> [-VDH]
 kadadm -r <vr> -p preempt -v <yes|no> [-VDH]
 kadadm -i <rs> -p weight -v <0-65535> [-VDH]
 kadadm -b

=head1 DESCRIPTION

kadadm(8) is used to inspect and maintain keepalived(8) status and
configuration. kadadm(8) communicates with keepalived(8) through SNMP,
therefore you will need to enable SNMP subsystem in keepalived(8), turn on
AgentX support in snmpd(8) and allow read/write access to KEEPALIVED-MIB
subtree. It is highly advised to use SNMP version 3. Please
check corresponding manual pages and L<CONFIGURATION GUIDE> section for
more details.

=head1 OPTIONS

=over 4

=item B<-r, --virtual-routers>

List or modify virtual routers

=item B<-a, --virtual-addresses>

List virtual addresses

=item B<-e, --virtual-servers>

List virtual servers

=item B<-i, --real-servers>

List or modify real servers

=item B<-b, --exabgp-healthcheck>

Watch for virtual address status changes

=item B<-p, --parameter>

Name of the parameter to set

=item B<-v, --value>

Value of the parameter to set

=item B<-V, --verbose>

Show verbose output

=item B<-D, --debug>

Show debug output

=item B<-H, --noheaders>

Do not print headers

=back

=head1 CONFIGURATION FILE FORMAT

kadadm(8) looks for configuration file in F<~/.kadadmrc>. File format is very simple - each line contains a I<parameter> and a I<value> separated by a space (C< >), lines starting with a pound sign (C<#>) are comments, and are ignored. The possible parameters are as follows:

=over 4

=item B<snmp_hostname>

The host name or IP address of the SNMP agent to connect to. Default is C<localhost>.

=item B<snmp_version>

SNMP version to use. Default is C<3>.

=item B<snmp_community>

Community to use for SNMP version C<1> and C<2> sessions. Default is C<public>.

=item B<snmp_username>

User name to use for SNMP version C<3> sessions. Default is C<keepalived>.

=item B<snmp_authkey>

Authentication key to use for SNMP version C<3> sessions. Default is C<keepalived>.

=item B<snmp_privkey>

Privacy key to use for SNMP version C<3> sessions. Default is C<keepalived>.

=item B<snmp_seclevel>

Security level to use for SNMP version C<3> sessions. Default is C<authPriv>.

=back

=head1 EXAMPLES

=over 4

=item B<kadadm -r>

Lists all virtual routers

=item B<kadadm -r >I<1>

Lists virtual router I<1>

=item B<kadadm -r >I<1>B< -p priority -v >I<200>

Sets priority of a virtual router I<1> to I<200>

=back

=head1 CONFIGURATION GUIDE

The following guide is valid for Red Hat Enterprise Linux 7.0 and its derivatives.

=over 4

=item 1. Enable keepalived SNMP subsystem by adding B<-x> to B<KEEPALIVED_OPTIONS> in F</etc/sysconfig/keepalived>:

 KEEPALIVED_OPTIONS="-Dx"

=item 2. Enable AgentX support by adding the following line to snmpd.conf(5): 

 master agentx

=item 3. Create a SNMPv3 user I<keepalived> by running:

 net-snmp-create-v3-user keepalived

=item 4. Allow access to KEEPALIVED-MIB subtree (read-only access for SNMPv2c C<public> community, read/write access for SNMPv3 user I<keepalived>), by adding the following lines to snmpd.conf(5):

 com2sec keepalived_user localhost none
 group keepalived_group usm keepalived_user
 view systemview included .1.3.6.1.4.1.9586.100.5
 view keepalived_view included .1.3.6.1.4.1.9586.100.5
 access keepalived_group "" usm priv exact keepalived_view keepalived_view none
 rwuser keepalived

=item 5. Restart snmpd(8) and keepalived(8):

 systemctl restart snmpd
 systemctl restart keepalived

=back

=head1 FILES

F<~/.kadadmrc>

=head1 SEE ALSO

keepalived(8), keepalived.conf(5), snmpd(8), snmpd.conf(5), net-snmp-create-v3-user(1), ipvsadm(8)

=head1 AUTHORS

=over 4

=item Ilya Voronin <ivoronin@jet.msk.su>

=back

=cut
