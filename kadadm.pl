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

# Reads configuration file ~/.kadadm.conf or /etc/kadadm.conf and updates $config with new values
sub config_read() {
    open(CONFIG, $ENV{'HOME'} . '/.kadadm.conf') or open(CONFIG, '/etc/kadadm.conf') or return;
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
    print Dumper($snmp_options) if $debug;

    $snmp_session = new SNMP::Session(
        %$snmp_options
    ) or die "kadadm: cannot create SNMP session\n";
}

sub snmp_wait_kad() {
    my $c = 0;
    my $vb = new SNMP::Varbind(['KEEPALIVED-MIB::version', 0]);
    # Wait 18 times for 10 seconds (3 mins) for keepalived to register its MIB
    while () {
        my $kad_version = $snmp_session->get($vb);
        snmp_die_on_error();
        return if ($kad_version ne 'NOSUCHOBJECT');
        last if ($c++ > 17 );
        sleep(10);
    }
    die "kadadm: timed out waiting for keepalived to register MIB\n";
}

sub snmp_die_on_error() {
    if ($snmp_session->{'ErrorNum'}) {
        die("kadadm: SNMP error: " . $snmp_session->{'ErrorStr'} . "\n");
    }
}

sub snmp_get_value($$) {
    snmp_wait_kad();
    my ($object, $instance) = @_;
    my $vars = new SNMP::Varbind([$object, $instance]);
    print Dumper($vars) if $debug;
    my $value = $snmp_session->get($vars);
    snmp_die_on_error();
    return $value;
}

sub snmp_get_table($) {
    snmp_wait_kad();
    my $table = $snmp_session->gettable(shift);
    snmp_die_on_error();
    print Dumper($table) if $debug;
    return $table;
}

sub snmp_set_value($$$) {
    snmp_wait_kad();
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

    my $fmt = "%-3s %-12s %-12s %-4s %-12s %-4s %-4s %-7s %-9s %-7s\n";

    while (my ($i, $row) = each $table) {
        my $name = $row->{'vrrpInstanceName'};
        next if ( $vr and $vr ne $name );

        printf($fmt, 'VR#', 'NAME', 'GROUP', 'VRID', 'IFACE', 'BPRI', 'EPRI',
            'PREEMPT', 'ADDRESSES', 'STATE') if $headers and not $found;

        $found++;

        printf($fmt,
            $i,
            $name,
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

    my $fmt = "%-5s %-15s %-6s %-12s %-6s\n";

    while (my ($i, $row) = each $table) {
        my $address = hex2ip($row->{'vrrpAddressValue'});
        next if ( $vr and $vr ne $address );

        printf($fmt, 'VA#', 'ADDRESS', 'PREFIX', 'IFACE', 'STATUS')
            if $headers and not $found;

        $found++;

        printf($fmt,
            $i,
            $address,
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

    my $fmt = "%-3s %-22s %-6s %-6s %-6s %-8s %-8s %-8s %-8s %-8s\n";

    while (my ($i, $row) = each $table) {
        my $addressport = hex2ip($row->{'virtualServerAddress'}) . ":" . $row->{'virtualServerPort'};
        next if ( $vs and $vs ne $addressport );

        printf($fmt, 'VS#', 'ADDRESS:PORT', 'STATUS', 'TOT_RS', 'UP_RS',
            'CPS', 'IPPS', 'OPPS', 'IBPS', 'OBPS') if $headers and not $found;

        $found++;

        printf($fmt,
            $i,
            $addressport,
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

sub show_status() {
    my $version = snmp_get_value('KEEPALIVED-MIB::version', 0);
    my $router_id = snmp_get_value('KEEPALIVED-MIB::routerId', 0);
    print "$version on $router_id is running\n";
}

sub show_real_servers($) {
    my $rs = shift; # Real server index
    my $found = 0;

    my $table = snmp_get_table('KEEPALIVED-MIB::realServerTable') or goto out;

    my $fmt = "%-5s %-22s %-6s %-6s %-9s %-11s %-8s %-8s %-8s %-8s %-8s\n";

    while (my ($i, $row) = each $table) {
        my $addressport = hex2ip($row->{'realServerAddress'}) . ":" . $row->{'realServerPort'};
        next if ( $rs and $rs ne $addressport );

        printf($fmt, 'VS#', 'ADDRESS:PORT', 'WEIGHT', 'STATUS',
                'ACT_CONNS', 'INACT_CONNS', 'CPS', 'IPPS', 'OPPS',
                'IBPS', 'OBPS') if $headers and not $found;

        $found++;

        printf($fmt, 
            $i,
            $addressport,
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
    my $found = 0;

    my $table = snmp_get_table('KEEPALIVED-MIB::vrrpInstanceTable') or goto out;

    while (my ($i, $row) = each $table) {
        my $name = $row->{'vrrpInstanceName'};
        if ( $name eq $vr ) {
            snmp_set_value('KEEPALIVED-MIB::vrrpInstanceBasePriority', $i, $pri);
            $found++;
            last;
        }
    }

out:
    die("Virtual router $vr not found\n") if not $found;
}

sub set_virtual_router_preempt($$) {
    my ($vr, $preempt) = @_;
    my $found = 0;

    my $table = snmp_get_table('KEEPALIVED-MIB::vrrpInstanceTable') or goto out;

    while (my ($i, $row) = each $table) {
        my $name = $row->{'vrrpInstanceName'};
        if ( $name eq $vr ) {
            snmp_set_value('KEEPALIVED-MIB::vrrpInstancePreempt', $i, $preempt);
            $found++;
            last;
        }
    }

out:
    die("Virtual router $vr not found\n") if not $found;
}

sub set_real_server_weight($$) {
    my ($rs, $weight) = @_;
    my $found = 0;

    my $table = snmp_get_table('KEEPALIVED-MIB::realServerTable') or goto out;
    while (my ($i, $row) = each $table) {
        my $addressport = hex2ip($row->{'realServerAddress'}) . ":" . $row->{'realServerPort'};
        if ( $addressport eq $rs ) {
            snmp_set_value('KEEPALIVED-MIB::realServerWeight', $i, $weight);
            $found++;
            last;
        }
    }
out:
    die("Real server $rs not found\n") if not $found;
}

sub main() {
    my $virtual_router;
    my $virtual_address;
    my $virtual_server;
    my $real_server;
    my $status;

    # Parameters
    my $priority;
    my $preempt;
    my $weight;

    my $hostname;

    GetOptions(
        # Global flags
        'verbose|V' => \$verbose,
        'debug|D' => \$debug,
        'noheaders|H' => sub { $headers = 0 },

        'virtual-routers|r:s' => \$virtual_router,
        'virtual-addresses|a:s' => \$virtual_address,
        'virtual-servers|e:s' => \$virtual_server,
        'real-servers|i:s' => \$real_server,
        'status|S' => \$status,

        # Parameter and value
        'priority|p=s' => \$priority,
        'preempt|P=s' => \$preempt,
        'weight|v=s' => \$weight,

        'hostname|N=s' => \$hostname,
    ) or pod2usage();

    # Exactly one object should be specified
    if ( not (defined $virtual_router xor
            defined $virtual_address xor 
            defined $virtual_server xor 
            defined $real_server xor
            defined $status) ) {
        pod2usage('Missing or conflicting options');
    }

    config_read();

    pod2usage('Wrong number of arguments') if ($#ARGV != -1);

    if ( defined $hostname ) {
        $config->{'snmp_hostname'} = $hostname;
    }

    snmp_create_session();

    if ( ( defined $priority or defined $preempt ) and not defined $virtual_router ) {
        pod2usage('Conflicting options');
    }

    if ( defined $weight and not defined $real_server ) {
        pod2usage('Conflicting options');
    }

    if ( defined $priority ) {
        set_virtual_router_priority($virtual_router, $priority);
    }

    if ( defined $preempt ) {
        if ( $preempt eq 'yes' ) {
            set_virtual_router_preempt($virtual_router, 1);
        } elsif ( $preempt eq 'no' ) {
            set_virtual_router_preempt($virtual_router, 2);
        } else {
            pod2usage('preempt value should be "yes" or "no"');
        }
    }

    if ( defined $weight ) {
        set_real_server_weight($real_server, $weight);
    }

    if ( not (defined $priority or defined $preempt or defined $weight) ) {
        # List
        show_virtual_routers($virtual_router) if ( defined $virtual_router );
        show_virtual_addresses($virtual_address) if ( defined $virtual_address );
        show_virtual_servers($virtual_server) if ( defined $virtual_server );
        show_real_servers($real_server) if ( defined $real_server );
        show_status() if ( defined $status );
    }
}

main();

__END__
=head1 NAME

kadadm - Keepalived administration

=head1 SYNOPSIS

 kadadm [-N hostname] <-r [vr]|-a [vr]|-e [vs]|-i [rs]> [-VDH]
 kadadm [-N hostname] -r <vr> -p <0-255> [-VDH]
 kadadm [-N hostname] -r <vr> -P <yes|no> [-VDH]
 kadadm [-N hostname] -i <rs> -w <0-65535> [-VDH]

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

=item B<-N, --hostname>

Keepalived server hostname to connect to (default is localhost)

=item B<-r, --virtual-routers>

List or modify virtual routers

=item B<-a, --virtual-addresses>

List virtual addresses

=item B<-e, --virtual-servers>

List virtual servers

=item B<-i, --real-servers>

List or modify real servers

=item B<-p, --priority>

Virtual router priority

=item B<-P, --preempt>

Virtual router preempt setting

=item B<-w, --weight>

Real server weight

=item B<-V, --verbose>

Show verbose output

=item B<-D, --debug>

Show debug output

=item B<-H, --noheaders>

Do not print headers

=back

=head1 CONFIGURATION FILE FORMAT

kadadm(8) looks for configuration file in F<~/.kadadm.conf> and F</etc/kadadm.conf>. File format is very simple - each line contains a I<parameter> and a I<value> separated by a space (C< >), lines starting with a pound sign (C<#>) are comments, and are ignored. The possible parameters are as follows:

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

=item B<kadadm -r >I<EXT>B< -p >I<200>

Sets priority of a virtual router I<EXT> to I<200>

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

F<~/.kadadm.conf>
F</etc/kadadm.conf>

=head1 SEE ALSO

keepalived(8), keepalived.conf(5), snmpd(8), snmpd.conf(5), net-snmp-create-v3-user(1), ipvsadm(8)

=head1 AUTHORS

=over 4

=item Ilya Voronin <ivoronin@jet.msk.su>

=back

=cut
