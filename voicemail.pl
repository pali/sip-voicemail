#!/usr/bin/perl
# (c) Pali 2018, Perl license

use strict;
use warnings;
use Getopt::Long qw(:config posix_default bundling);

use Net::SIP;
use Net::SIP::Util qw(create_rtp_sockets invoke_callback sip_hdrval2parts sip_uri2parts);

$| = 1;

my $wave_ulaw_header = "WAVEfmt \x12\x00\x00\x00\x07\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00\x00\x00";

sub read_welcome_file {
	my ($welcome_file) = @_;
	open my $fh, '<', $welcome_file
		or do { print "Error: Cannot open welcome file $welcome_file: $!\n"; return ''; };
	read($fh, my $header, 38) == 38
		or do { print "Error: Welcome file $welcome_file is too short\n"; return ''; };
	substr($header, 0, 4) eq 'RIFF'
		or do { print "Error: Welcome file $welcome_file is not in WAVE format\n"; return ''; };
	substr($header, 8, 30) eq $wave_ulaw_header
		or do { print "Error: Welcome file $welcome_file is not in WAVE G.711 u-law 8kHz (PCMU) format\n"; return ''; };
	while (1) {
		read($fh, my $type, 4) == 4
			or do { print "Error: Welcome file $welcome_file has corrupted WAVE header\n"; return ''; };
		last if $type eq 'data';
		read($fh, my $length, 4) == 4
			or do { print "Error: Welcome file $welcome_file has corrupted WAVE header\n"; return ''; };
		$length = unpack 'V', $length;
		read($fh, my $dummy, $length) == $length
			or do { print "Error: Welcome file $welcome_file has corrupted WAVE header\n"; return ''; };
	}
	read($fh, my $length, 4) == 4
		or do { print "Error: Welcome file $welcome_file has corrupted WAVE header\n"; return ''; };
	return join '', <$fh>;
}

my $listen = 'udp:127.0.0.1:5062';
my $rtp = '';
my $ports = '';
my $sdpaddr = '';
my $identity = 'Voicemail <voicemail@localhost>';
my $multiuser;
my $welcome = '';
my $directory = '.';
my $afterwelcome;
my $timeout = 60;
GetOptions(
	'h|help' => sub {
		print <<"EOD";
Usage: $0 [ options ]
Simple SIP voicemail. Listens for incoming SIP calls,
sends welcome message and records data from user.

Options:
  -h|--help                   Show this help
  -l|--listen socket          SIP listen socket (default $listen)
  -r|--rtp address            RTP listen address (default SIP listen address)
  -p|--ports start:end        RTP listen port range (default any port)
  -s|--sdp address            Announced RTP address in SDP (default RTP listen address)
  -f|--identity identity      SIP identity (default $identity)
  -m|--multiuser              Enable multiuser mode, must be run as root (default single user)
  -w|--welcome filename       Welcome file in Wave G.711 u-law 8kHz (PCMA) format (default none)
  -d|--directory directory    Where to save received messages (default $directory)
  -a|--afterwelcome           Start recording after welcome message (default immediately)
  -t|--timeout time           Record at most time seconds (default $timeout)
EOD
		exit;
	},
	'l|listen=s' => \$listen,
	'r|rtp=s' => \$rtp,
	'p|ports=s' => \$ports,
	's|sdp=s' => \$sdpaddr,
	'f|identity=s' => \$identity,
	'm|multiuser' => \$multiuser,
	'w|welcome=s' => \$welcome,
	'd|directory=s' => \$directory,
	'a|afterwelcome' => \$afterwelcome,
	't|timeout=i' => \$timeout,
) or exit 1;

my ($proto, $addr, $port) = $listen =~ m/^(tcp|udp|tls):([^\[\]<>:]*|\[[^\[\]<>]*\]):([0-9]+)$/;
defined $proto and defined $addr and defined $port
	or die "Error: Malformed listen address $listen\n";

$rtp = $addr unless length $rtp;
$sdpaddr = $rtp unless length $sdpaddr;

my ($min_port, $max_port);
if (length $ports) {
	($min_port, $max_port) = $ports =~ m/^([0-9]+)[:\-]([0-9]+)$/;
	defined $min_port and defined $max_port
		or die "Error: Malformed rtp range $ports\n";
}

$multiuser and $< != 0
	and die "Error: Root is required for multiuser mode\n";

my $leg = Net::SIP::Leg->new(
	proto => $proto,
	addr => $addr,
	port => $port,
) or die "Error: Cannot create leg at $proto:$addr:$port: $!\n";

my $ua = Net::SIP::Simple->new(
	from => $identity,
	legs => [ $leg ],
) or die "Error: Cannot create user agent for $identity: $!\n";

$ua->listen(
	recv_bye => sub {
		my ($param) = @_;
		my $timer = delete $param->{stop_rtp_timer};
		$timer and $timer->cancel;
		print "Hangup\n";
	},
	filter => sub {
		my ($from, $request) = @_;
		($from) = sip_hdrval2parts(from => $from);
		my $for = ($request->as_parts)[1];
		print "Incoming call for $for from: $from\n";
		if ($multiuser) {
			my $for_user = (sip_uri2parts($for))[1];
			my (undef, undef, $uid, $gid, undef, undef, undef, $home) = getpwnam($for_user);
			if (not defined $uid or not defined $gid) {
				print "Rejecting call, user $for_user does not exist\n";
				return 0;
			}
			if (not defined $home or not length $home) {
				print "Rejecting call, no home directory for user $for_user\n";
				return 0;
			}
			my $user_directory = $directory;
			$user_directory =~ s/%h/$home/g;
			$user_directory =~ s/%u/$for_user/g;
			if (not -d $user_directory) {
				print "Rejecting call, directory $user_directory for $for_user does not exist\n";
				return 0;
			}
		}
		return 1;
	},
	cb_invite => sub {
		my ($call, $request) = @_;
		my $leg = $call->{param}->{leg};
		my ($rtp_port, $rtp_sock, $rtcp_sock) = create_rtp_sockets($rtp, 2, $min_port, $max_port);
		$rtp_sock or do { print "Error: Cannot create rtp socket at $addr: $!\n"; die; };
		$rtcp_sock or do { print "Error: Cannot create rtcp socket at $addr: $!\n"; die; };
		my $sdp = Net::SIP::SDP->new(
			{
				addr => $sdpaddr,
			},
			{
				media => 'audio',
				proto => 'RTP/AVP',
				port => $rtp_port,
				range => 2,
				fmt => [ 0 ],
			},
		);
		$call->{param}->{sdp} = $sdp;
		$call->{param}->{media_lsocks} = [ [ $rtp_sock, $rtcp_sock ] ];
		if ($multiuser) {
			my $for = ($request->as_parts)[1];
			my $for_user = (sip_uri2parts($for))[1];
			my (undef, undef, $uid, $gid, undef, undef, undef, $home) = getpwnam($for_user);
			$call->{param}->{voicemail_user_uid} = $uid;
			$call->{param}->{voicemail_user_gid} = $gid;
			$call->{param}->{voicemail_user_welcome} = $welcome;
			$call->{param}->{voicemail_user_welcome} =~ s/%h/$home/g;
			$call->{param}->{voicemail_user_welcome} =~ s/%u/$for_user/g;
			$call->{param}->{voicemail_user_directory} = $directory;
			$call->{param}->{voicemail_user_directory} =~ s/%h/$home/g;
			$call->{param}->{voicemail_user_directory} =~ s/%u/$for_user/g;
		}
	},
	init_media => sub {
		my ($call, $param) = @_;
		my $welcome_file = $multiuser ? $call->{param}->{voicemail_user_welcome} : $welcome;
		my $welcome_buffer = length $welcome_file ? read_welcome_file($welcome_file) : '';
		my $send_welcome_buffer = $welcome_buffer;
		my $send_welcome_state;
		my $send_welcome = sub {
			my ($seq, $channel) = @_;
			if (not $send_welcome_state) {
				$send_welcome_state = 1;
				print 'Sending welcome message' . (length $welcome_buffer ? " from file $welcome_file" : '') . "\n";
			}
			my $payload = substr $send_welcome_buffer, 0, 160, '';
			$payload .= "\xff" x (160 - length $payload)
				if length $payload < 160;
			return $payload;
		};
		my $from = $call->get_peer;
		$from =~ s/^.*\s+<(?:sips?:)?([^>]+)>\s*$/$1/;
		$from =~ s/[\s"\/<>[:^print:]]/_/g;
		my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
		$year += 1900;
		$mon += 1;
		my $date = sprintf "%04d-%02d-%02d_%02d:%02d:%02d", $year, $mon, $mday, $hour, $min, $sec;
		my $receive_directory = $multiuser ? $call->{param}->{voicemail_user_directory} : $directory;
		my $receive_file = $receive_directory . '/' . $date . '_' . $from . '.wav';
		my $receive_fh;
		my $receive_voicemail = sub {
			my ($payload, $seq, $timestamp, $channel) = @_;
			return if $afterwelcome and length $send_welcome_buffer > 0;
			if (not $receive_fh) {
				$param->{stop_rtp_timer} = $call->add_timer($timeout, sub { print "Hangup (timeout)\n"; $call->bye() });
				print "Storing voicemail to file $receive_file\n";
				open $receive_fh, '>', $receive_file
					or do { print "Cannot open file $receive_file: $!\n"; $call->bye; return; };
				chown $call->{param}->{voicemail_user_uid}, $call->{param}->{voicemail_user_gid}, $receive_file if $multiuser;
				print $receive_fh "RIFF\xff\xff\xff\xff";
				print $receive_fh $wave_ulaw_header;
				print $receive_fh "data\xff\xff\xff\xff";
			}
			print $receive_fh $payload;
			return;
		};
		my $rtp = $call->rtp('media_send_recv', $send_welcome, 1, $receive_voicemail);
		return invoke_callback($rtp, $call, $param);
	},
);

print "Starting main loop...\n";
$ua->loop;
