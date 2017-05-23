#!/usr/bin/perl -Tw
#
#
#

use strict;
use diagnostics;
use warnings;

# use AnyEvent;
# use AnyEvent::SerialPort;

use Device::SerialPort;
use Time::HiRes qw(time sleep);

my $PORT = '/dev/ttyUSB0';

my $am7 = Device::SerialPort->new($PORT, 0);
unless ($am7) {
	die "Can't open $PORT: $!\n";
}

$am7->baudrate(19200);
#$am7->parity('odd');
$am7->databits(8);
$am7->stopbits(1);

$am7->debug(1);
$am7->read_const_time(10000);

my %commands = (
	READ_THRESHOLD => pack('C13', 0x55, 0xCD, 0x55, (0x00) x 6, 0x01, 0x77, 0x0D, 0x0A),
	READ_SENSOR => pack('C13', 0x55, 0xCD, 0x47, (0x00) x 6, 0x01, 0x69, 0x0D, 0x0A),
	SET_TIME => pack('C13', 0x55, 0xCD, 0x45, (0x00) x 8, 0x0D, 0x0A),
);

sub status {
	if (0 and $am7->can_wait_modemlines) {
		my $rc = $am7->wait_modemlines($am7->MS_RLSD_ON);
		unless ($rc) {
			print "carrier detect changed: c_w_m\n";
		}
	} elsif (0 and $am7->can_modemlines) {
		my $rc = $am7->modemlines;
		if ($rc & $am7->MS_RLSD_ON) {
			print "carrier detect changed: c_m\n";
		}
	}
	if (0 and $am7->can_intr_count) {
		my $count = $am7->intr_count();
		if ($count) {
			print "got $count interrupts\n";
		}
	}
}

sub cmd {
	my $command = shift;

	status;

	my $in_length = 40;
	my $timeout = 5;

	#my $in = '';

	my $out = $commands{$command};
	die unless ($out);
	my $out_length = length($out);
	if ($command eq 'SET_TIME')  {
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time);
		$year += 1900 - 2000;
		$mon += 1;
		printf("%d %d %d %d %d %d\n", $year, $mon, $mday, $hour, $min, $sec);
		substr($out, 3, 6, pack('C6', $year, $mon, $mday, $hour, $min, $sec));
		my $sum = 0;
		for (split('',  substr($out, 0, -4))) {
			$sum += ord($_);
		}
		substr($out, -4, 2, pack('n', $sum));
	}
	my $count_out = $am7->write($out);
	unless ($count_out) {
		die 'Write failed';
	}
	unless ($count_out == $out_length) {
		die sprintf('Write incomplete: %d != %d', $count_out, $out_length);
	}

	status;

	my ($count_in, $string_in) = $am7->read($in_length);
	#my $sleep = 0.01;
	#while ($in_length > 0 and $timeout > 0) {
	#	if ($count_in > 0) {
	#		$in .= $string_in;
	#		$in_length -= $count_in;
	#		$sleep /= 1.05;
	#		$sleep = 0.01 if ($sleep < 0.01);
	#		next;
	#	} else {
	#		$sleep *= 1.2;
	#		$sleep = 5.0 if ($sleep > 5.0);
	#		$timeout -= $sleep;
	#	}
	#	#status;
	#	sleep($sleep);
	#	#print "sleep=$sleep $count_in\n";
	#}
	my $in = $string_in;


	#unless (length($in) == 40) {
	#	warn sprintf('read unsuccessfull(%d != %d)', length($in), 40);
	#}

	my @vals = split('', $in);
	my $ok = 0;
	if ($command eq 'READ_SENSOR' and @vals == 40) {
		$ok = 1;
		my ($xaa, $pm25, $pm10, $hcho, $vocs, $co2, $temp, $rh, $batt_status, $batt_charge, $p003, $p005, $p010, $p025, $p050, $p100, $nuls, $x47, $csum, $x0d, $x0a) =
			unpack('CnnnnnnnCCnnnnnnNCnCC', $in);
		unless (ord($vals[0]) == 0xAA) {
			warn sprintf('Wrong start char: %2X != %2X %2X', ord($vals[0]), 0xAA, $xaa);
			$ok = 0;
		}
		unless (ord($vals[-2]) == 0x0D) {
			warn sprintf('Wrong end1 char: %2X != %2X', ord($vals[-2]), 0x0D);
			$ok = 0;
		}
		unless (ord($vals[-1]) == 0x0A) {
			warn sprintf('Wrong end2 char: %2X != %2X', ord($vals[-1]), 0x0A);
			$ok = 0;
		}
		my $sum = 0;
		for (@vals[0..35]) {
			$sum += ord($_);
		}
		my @sum = split('', pack('n', $sum));
		unless ($vals[-4] eq $sum[0]) {
			warn sprintf('Wrong checksum: %2X != %2X', ord($vals[-4]), ord($sum[0]));
			$ok = 0;
		}
		unless ($vals[-3] eq $sum[1]) {
			warn sprintf('Wrong checksum: %2X != %2X', ord($vals[-3]), ord($sum[1]));
			$ok = 0;
		}
		if ($ok) {
			printf('OK: %0.3f %d %d %1.03f %1.03f %4d %2.02f %2.02f batt=%d %d p=%5d %5d %5d %5d %5d %5d%s',
				time,
				$pm25, $pm10,
				$hcho / 1000.0, $vocs / 1000.0,
				$co2,
				$temp / 100.0, $rh / 100.0,
				$batt_status, $batt_charge,
				$p003, $p005, $p010, $p025, $p050, $p100,
				"\n");
			return;
		}
	}
	my @hex_in = map { sprintf('%3X', ord($_)) } @vals;
	my @ord_in = map { sprintf('%3d', ord($_)) } @vals;
	printf('%s: %s', ($ok ? 'OK' : 'ERR'), "@hex_in\n");
	printf('%s: %s', ($ok ? 'OK' : 'ERR'), "@ord_in\n");
}

cmd('SET_TIME');

$| = 1;
#cmd('READ_THRESHOLD');
my $freq = 2.0;
my $t0 = time;
while(1) {
	cmd('READ_SENSOR');
	my $t1 = time;
	my $took = $t1 - $t0;
	$t0 += $freq;
	my $sleep = $t0 - $t1;
	while ($sleep < 0) {
		$t0 += $freq;
		$sleep = $t0 - $t1;
	}
	if ($sleep > $freq) {
		$sleep = $freq;
	}
	printf("took: %f sleep: %f\n", $took, $sleep);
	sleep $sleep;
}
