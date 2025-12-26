package PVE::QemuServer::CPUAffinityServiceClient;

use strict;
use warnings;

use JSON;
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use PVE::Tools qw(file_get_contents);
use PVE::RESTEnvironment qw(log_warn);

use base qw(Exporter);

our @EXPORT_OK = qw(
    load_config
    ping
    update_affinity
);

my $CONFIG_FILE = '/etc/default/proxmox-cpu-affinity';
my $cached_config;
my $cached_mtime;

sub load_config {
    # Make this very robust, proxmox-cpu-affinity might getting
    # installed, updated, reinstalled during our lifecycle.

    my @st = stat($CONFIG_FILE);
    return if !@st;

    my $mtime = $st[9];
    return $cached_config if defined($cached_mtime) && $cached_mtime == $mtime;

    my $config = {
        socket_file => '/var/run/proxmox-cpu-affinity.sock',
        socket_retry => 10,
        socket_sleep => 10, # in seconds
        socket_timeout => 30, # in seconds
        socket_ping_on_prestart => 1,
    };

    my $raw = eval { file_get_contents($CONFIG_FILE) };
    if (my $err = $@) {
        log_warn("failed to read $CONFIG_FILE: $err");
        return $config;
    }

    while ($raw =~ /^\s*(PCA_[A-Z0-9_]+)\s*=\s*(.*?)\s*$/gm) {
        my ($key, $value) = ($1, $2);
        # remove optional quotes
        $value =~ s/^"(.*)"$/$1/;
        $value =~ s/^'(.*)'$/$1/;

        if ($key eq 'PCA_SOCKET_FILE') {
            $config->{socket_file} = $value;
        } elsif ($key eq 'PCA_SOCKET_RETRY') {
            $config->{socket_retry} = $value;
        } elsif ($key eq 'PCA_SOCKET_SLEEP') {
            $config->{socket_sleep} = $value;
        } elsif ($key eq 'PCA_SOCKET_TIMEOUT') {
            $config->{socket_timeout} = $value;
        } elsif ($key eq 'PCA_SOCKET_PING_ON_PRESTART') {
            $config->{socket_ping_on_prestart} = $value;
        }
    }

    $cached_config = $config;
    $cached_mtime = $mtime;

    return $config;
}

my $call_service = sub {
    my ($command, $vmid) = @_;

    my $config = load_config();
    return "service not configured" if !$config;

    my $socket_path = $config->{socket_file};

    my $err;
    for (my $i = 0; $i <= $config->{socket_retry}; $i++) {
        sleep($config->{socket_sleep}) if $i > 0;

        my $sock = IO::Socket::UNIX->new(
            Peer => $socket_path,
            Type => SOCK_STREAM,
            Timeout => $config->{socket_timeout},
        );

        if (!$sock) {
            $err = "failed to connect to socket '$socket_path': $!";
            next;
        }

        my $req = {
            command => $command,
            vmid => int($vmid),
        };

        eval {
            print $sock to_json($req);
            shutdown($sock, 1);

            my $res_str = do { local $/; <$sock> };
            die "received empty response\n" if !$res_str;

            my $res = from_json($res_str);
            die "service returned error: $res->{error}\n" if $res->{status} ne 'ok';
        };
        $err = $@;
        close($sock);

        return if !$err;
    }

    return $err;
};

sub ping {
    my ($vmid) = @_;

    my $config = load_config();
    return if !$config;

    if ($config->{socket_ping_on_prestart} && $config->{socket_ping_on_prestart} =~ m/^(1|true|yes|on)$/i) {
        if (my $err = $call_service->("ping", $vmid)) {
            log_warn("Error server not ready: $err");
        }
    }
}

sub update_affinity {
    my ($vmid) = @_;

    my $config = load_config();
    return if !$config;

    if (my $err = $call_service->("update-affinity", $vmid)) {
        log_warn("Error calling service: $err");
    }
}

1;
