#!/usr/bin/perl
# (c) Pali 2018-2019, Perl license

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

my $listen = 'udp:127.0.0.1:5060';
my $rtp = '';
my $ports = '';
my $sdpaddr = '';
my $identity = 'Voicemail <voicemail@localhost>';
my $env_from = 'double-bounce';
my $multiuser;
my $welcome = '';
my $directory = '';
my $email = '';
my $afterwelcome;
my $timeout = 60;
GetOptions(
	'h|help' => sub {
		print <<"EOD";
Usage: $0 [ options ]

SIP voicemail. Listens for incoming SIP calls,
sends welcome message and records data from user.
Stores it either on disk or sends via email.

Options:
  -h|--help                   Show this help
  -l|--listen socket          SIP listen socket (default $listen)
  -r|--rtp address            RTP listen address (default SIP listen address)
  -p|--ports start:end        RTP listen port range (default any port)
  -s|--sdp address            Announced RTP address in SDP (default RTP listen address)
  -i|--identity identity      SIP identity (default $identity)
  -f|--envelope-from address  Envelope From email address (default $env_from)
  -m|--multiuser              Enable multiuser mode, must be run as root (default single user)
  -w|--welcome filename       Welcome file in Wave G.711 u-law 8kHz (PCMA) format (default none)
  -d|--directory directory    Disk directory where to save received message files (default none)
  -e|--email address          Email address to which send received message files (default do not send)
  -a|--afterwelcome           Start recording after welcome message (default immediately)
  -t|--timeout time           Record at most time seconds (default $timeout)

You need to specify at least --directory or --email option.

You may use %u (unix user) and %h (home directory) patterns for multiuser options.
EOD
		exit;
	},
	'l|listen=s' => \$listen,
	'r|rtp=s' => \$rtp,
	'p|ports=s' => \$ports,
	's|sdp=s' => \$sdpaddr,
	'i|identity=s' => \$identity,
	'f|envelope-from=s' => \$env_from,
	'm|multiuser' => \$multiuser,
	'w|welcome=s' => \$welcome,
	'd|directory=s' => \$directory,
	'e|email=s' => \$email,
	'a|afterwelcome' => \$afterwelcome,
	't|timeout=i' => \$timeout,
) or exit 1;

length $directory or length $email
	or die "Error: At least --directory or --email option must be specified\n";

length $identity
	or die "Error: SIP identity cannot be empty\n";

length $env_from
	or die "Error: Envelope From email address cannot be empty\n";

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

$multiuser and length $directory and $< != 0
	and die "Error: Root is required for multiuser mode when storing messages to disk\n";

my $leg = Net::SIP::Leg->new(
	proto => $proto,
	addr => $addr,
	port => $port,
) or die "Error: Cannot create leg at $proto:$addr:$port: $!\n";

my $ua = Net::SIP::Simple->new(
	from => $identity,
	legs => [ $leg ],
) or die "Error: Cannot create user agent for $identity: $!\n";

sub hangup {
	my ($param) = @_;
	my $timer = delete $param->{stop_rtp_timer};
	$timer and $timer->cancel;
	print localtime . " - Hangup\n";
}

$ua->listen(
	recv_bye => \&hangup,
	filter => sub {
		my ($from, $request) = @_;
		($from) = sip_hdrval2parts(from => $from);
		my $for = ($request->as_parts)[1];
		print localtime . " - Incoming call for $for from: $from\n";
		if ($multiuser) {
			my $for_user = (sip_uri2parts($for))[1];
			my (undef, undef, $uid, $gid, undef, undef, undef, $home) = getpwnam($for_user);
			if (not defined $uid or not defined $gid) {
				print localtime . " - Rejecting call, user $for_user does not exist\n";
				return 0;
			}
			if (not defined $home or not length $home) {
				print localtime . " - Rejecting call, no home directory for user $for_user\n";
				return 0;
			}
			if (length $directory) {
				my $user_directory = $directory;
				$user_directory =~ s/%h/$home/g;
				$user_directory =~ s/%u/$for_user/g;
				if (not -d $user_directory) {
					print localtime . " - Rejecting call, directory $user_directory for $for_user does not exist\n";
					return 0;
				}
			}
		}
		return 1;
	},
	cb_invite => sub {
		my ($call, $request) = @_;
		my $leg = $call->{param}->{leg};
		my ($rtp_port, $rtp_sock, $rtcp_sock) = create_rtp_sockets($rtp, 2, $min_port, $max_port);
		$rtp_sock or do { print localtime . " - Error: Cannot create rtp socket at $addr: $!\n"; die; };
		$rtcp_sock or do { print localtime . " - Error: Cannot create rtcp socket at $addr: $!\n"; die; };
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
		($call->{param}->{voicemail_call_id}) = $request->get_header('call-id');
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
			$call->{param}->{voicemail_user_email} = $email;
			$call->{param}->{voicemail_user_email} =~ s/%u/$for_user/g;
		}
	},
	init_media => sub {
		my ($call, $param) = @_;
		my $welcome_file = $multiuser ? $param->{voicemail_user_welcome} : $welcome;
		my $welcome_buffer = length $welcome_file ? read_welcome_file($welcome_file) : '';
		my $send_welcome_buffer = $welcome_buffer;
		my $send_welcome_state;
		my $send_welcome = sub {
			my ($seq, $channel) = @_;
			if (not $send_welcome_state) {
				$send_welcome_state = 1;
				print localtime . ' - Sending welcome message' . (length $welcome_buffer ? " from file $welcome_file" : '') . "\n";
			}
			my $payload = substr $send_welcome_buffer, 0, 160, '';
			$payload .= "\xff" x (160 - length $payload)
				if length $payload < 160;
			return $payload;
		};
		my $from = $call->get_peer;
		my $from_name = ($from =~ /^\s*(.*?)\s*</) ? $1 : '';
		$from_name =~ s/[<>[:^print:]]/_/g;
		$from =~ s/^.*<(?:sips?:)?([^>]+)>\s*$/$1/;
		$from =~ s/[\s"\/<>[:^print:]]/_/g;
		my ($to) = sip_hdrval2parts(to => $call->{ctx}->{to});
		my $to_name = ($to =~ /^\s*(.*?)\s*</) ? $1 : '';
		$to_name =~ s/[<>[:^print:]]/_/g;
		$to =~ s/^.*<(?:sips?:)?([^>]+)>\s*$/$1/;
		$to =~ s/[\s"\/<>[:^print:]]/_/g;
		my $t = time;
		my ($sec, $min, $hour, $mday, $mon, $year, $wday) = gmtime($t);
		my @mon_abbrv = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
		my @wday_abbrv = qw(Sun Mon Tue Wed Thu Fri Sat);
		my $date_email = sprintf "%3s, %2d %3s %4d %02d:%02d:%02d +0000", $wday_abbrv[$wday], $mday, $mon_abbrv[$mon], 1900+$year, $hour, $min, $sec;
		($sec, $min, $hour, $mday, $mon, $year) = localtime($t);
		$year += 1900;
		$mon += 1;
		my $date = sprintf "%04d-%02d-%02d_%02d:%02d:%02d", $year, $mon, $mday, $hour, $min, $sec;
		my $mid = (defined $call->{param}->{voicemail_call_id}) ? ('<call-id-' . $call->{param}->{voicemail_call_id} . ($call->{param}->{voicemail_call_id} =~ /@/ ? '' : '@localhost') . '>') : undef;
		my $receive_directory = $multiuser ? $param->{voicemail_user_directory} : $directory;
		my $receive_file = length $receive_directory ? ($receive_directory . '/voicemail_' . $date . '_' . $from . '.wav') : '';
		my $receive_email = $multiuser ? $param->{voicemail_user_email} : $email;
		my $receive_fh;
		my $receive_pipe;
		my $stop;
		my $receive_voicemail = sub {
			my ($payload, $seq, $timestamp, $channel) = @_;
			return if $stop;
			return if $afterwelcome and length $send_welcome_buffer > 0;
			if (not $receive_fh and not $receive_pipe) {
				$param->{stop_rtp_timer} = $call->add_timer($timeout, sub { print localtime . "Hangup (timeout)\n"; $stop = 1; $call->bye() });
			}
			if (not $receive_fh and length $receive_file) {
				print localtime . " - Storing voicemail to file $receive_file\n";
				open $receive_fh, '>', $receive_file
					or do { print "Cannot open file $receive_file: $!\n"; $stop = 1; hangup($param); $call->bye; return; };
				chown $param->{voicemail_user_uid}, $param->{voicemail_user_gid}, $receive_file if $multiuser;
				print $receive_fh "RIFF\xff\xff\xff\xff";
				print $receive_fh $wave_ulaw_header;
				print $receive_fh "data\xff\xff\xff\xff";
			}
			if (not $receive_pipe and length $receive_email) {
				print localtime . " - Sending voicemail to email address $receive_email\n";
				open $receive_pipe, '|-', '/usr/sbin/sendmail', '-oi', '-oeq', '-f', $env_from, $receive_email
					or do { print "Cannot spawn /usr/sbin/sendmail binary: $!\n"; $stop = 1; hangup($param); $call->bye; return; };
				print $receive_pipe "From: " . (length $from_name ? "$from_name <$from>" : $from) . "\n";
				print $receive_pipe "To: " . (length $to_name ? "$to_name <$to>" : $to) . "\n";
				print $receive_pipe "Date: $date_email\n";
				print $receive_pipe "Subject: SIP voicemail\n";
				print $receive_pipe "Message-ID: $mid\n" if defined $mid;
				print $receive_pipe "MIME-Version: 1.0\n";
				print $receive_pipe "Content-Type: audio/vnd.wave; codec=7\n";
				print $receive_pipe "Content-Disposition: attachment;\n";
				print $receive_pipe "  filename=\"voicemail_${date}_${from}.wav\"\n";
				print $receive_pipe "Content-Transfer-Encoding: base64\n";
				print $receive_pipe "\n";
				binmode $receive_pipe, ':via(Base64Stream)';
				print $receive_pipe "RIFF\xff\xff\xff\xff";
				print $receive_pipe $wave_ulaw_header;
				print $receive_pipe "data\xff\xff\xff\xff";
			}
			print $receive_fh $payload if $receive_fh;
			print $receive_pipe $payload if $receive_pipe;
			return;
		};
		my $rtp = $call->rtp('media_send_recv', $send_welcome, 1, $receive_voicemail);
		return invoke_callback($rtp, $call, $param);
	},
);

my $stop;
$SIG{INT} = $SIG{QUIT} = $SIG{TERM} = sub { $SIG{INT} = $SIG{QUIT} = $SIG{TERM} = 'DEFAULT'; print localtime . " - Stopping main loop...\n"; $stop = 1; };
print localtime . " - Starting main loop...\n";
$ua->loop(undef, \$stop);
$ua->cleanup();
print localtime . " - Stopped\n";


package PerlIO::via::Base64Stream;

use MIME::Base64;

sub PUSHED {
	my ($class, $mode, $fh) = @_;
	my $buf = '';
	return bless \$buf, $class;
}

sub FLUSH {
	my ($self, $fh) = @_;
	print $fh encode_base64 substr $$self, 0, length $$self, '';
	return 0;
}

sub WRITE {
	my ($self, $buf, $fh) = @_;
	$$self .= $buf;
	print $fh encode_base64 substr $$self, 0, int(length($$self)/57)*57, '';
	return length $buf;
}
