#!/usr/bin/perl
# (c) Pali 2018, Perl license

use strict;
use warnings;
use Getopt::Long qw(:config posix_default bundling);

use Net::SIP;
use Net::SIP::Util qw(create_rtp_sockets invoke_callback);

my $wave_ulaw_header = "WAVEfmt \x12\x00\x00\x00\x07\x00\x01\x00\x40\x1f\x00\x00\x40\x1f\x00\x00\x01\x00\x08\x00\x00\x00";

my $listen = 'udp:127.0.0.1:5062';
my $rtp = '';
my $ports = '';
my $sdpaddr = '';
my $identity = 'Voicemail <voicemail@localhost>';
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
  -l|--listen socket          SIP listen socket (default udp:127.0.0.1:5062)
  -r|--rtp address            RTP listen address (default SIP listen address)
  -p|--ports start:end        RTP listen port range (default any port)
  -s|--sdp address            Announced RTP address in SDP (default RTP listen address)
  -f|--identity identity      SIP identity (default Voicemail <voicemail\@localhost>)
  -w|--welcome filename       Welcome file in Wave G.711 u-law 8kHz (PCMA) format (default none)
  -d|--directory directory    Where to save received messages (default .)
  -a|--afterwelcome           Start recording after welcome message (default immediately)
  -t|--timeout time           Record at most time seconds (default 60)
EOD
		exit;
	},
	'l|listen=s' => \$listen,
	'r|rtp=s' => \$rtp,
	'p|ports=s' => \$ports,
	's|sdp=s' => \$sdpaddr,
	'f|identity=s' => \$identity,
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

my $welcome_buffer = '';
if (length $welcome) {
	open my $fh, '<', $welcome
		or die "Error: Cannot open welcome file $welcome: $!\n";
	read($fh, my $header, 38) == 38
		or die "Error: Welcome file $welcome is too short\n";
	substr($header, 0, 4) eq 'RIFF'
		or die "Error: Welcome file $welcome is not in WAVE format\n";
	substr($header, 8, 30) eq $wave_ulaw_header
		or die "Error: Welcome file $welcome is not in WAVE G.711 u-law 8kHz (PCMU) format\n";
	while (1) {
		read($fh, my $type, 4) == 4
			or die "Error: Welcome file $welcome has corrupted WAVE header\n";
		last if $type eq 'data';
		read($fh, my $length, 4) == 4
			or die "Error: Welcome file $welcome has corrupted WAVE header\n";
		$length = unpack 'V', $length;
		read($fh, my $dummy, $length) == $length
			or die "Error: Welcome file $welcome has corrupted WAVE header\n";
	}
	read($fh, my $length, 4) == 4
		or die "Error: Welcome file $welcome has corrupted WAVE header\n";
	$welcome_buffer = join '', <$fh>;
	close $fh;
}

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
	},
	init_media => sub {
		my ($call, $param) = @_;
		my $send_welcome_buffer = $welcome_buffer;
		my $send_welcome_state;
		my $send_welcome = sub {
			my ($seq, $channel) = @_;
			if (not $send_welcome_state) {
				$send_welcome_state = 1;
				print "Sending welcome message\n";
			}
			my $payload = substr $send_welcome_buffer, 0, 160, '';
			$payload .= "\xff" x (160 - length $payload)
				if length $payload < 160;
			return $payload;
		};
		my $from = $call->get_peer;
		print "Incoming call from: $from\n";
		$from =~ s/^.*\s+<(?:sip:)?([^>]+)>\s*$/$1/;
		$from =~ s/[\s"\/<>[:^print:]]/_/g;
		my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
		$year += 1900;
		$mon += 1;
		my $date = sprintf "%04d-%02d-%02d_%02d:%02d:%02d", $year, $mon, $mday, $hour, $min, $sec;
		my $receive_file = $directory . '/' . $date . '_' . $from . '.wav';
		my $receive_fh;
		my $receive_voicemail = sub {
			my ($payload, $seq, $timestamp, $channel) = @_;
			return if $afterwelcome and length $send_welcome_buffer > 0;
			if (not $receive_fh) {
				$param->{stop_rtp_timer} = $call->add_timer($timeout, sub { print "Hangup (timeout)\n"; $call->bye() });
				print "Storing voicemail to file $receive_file\n";
				open $receive_fh, '>', $receive_file
					or do { print "Cannot open file $receive_file: $!\n"; $call->bye; return; };
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
