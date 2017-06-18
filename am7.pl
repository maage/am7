#!/usr/bin/perl -Tw
#
#

use lib './lib';

use strict;
use diagnostics;
use warnings;

use AnyEvent;
use AnyEvent::SerialPort;
use AnyEvent::AIO;
use IO::AIO;
use List::Util qw(sum);

use Time::HiRes qw(time sleep);

my $PORT = '/dev/ttyUSB0';

my $cv = AE::cv;
my $timer;
my $am7;
my $wait_device_timer;
my $wait_device_initial_wait = 0.1; # seconds
my $wait_device_max_wait = 5.0; # seconds
my $wait_device_wait = $wait_device_initial_wait;

sub op_READ_SENSOR;
sub wait_device;

my $formats = {
  SET_TIME => {
    request => pack('C13', 0x55, 0xCD, 0x45, (0x00) x 8, 0x0D, 0x0A),
    request_update => sub {
      my $buf_ref = shift;
      my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime(time);
      $year += 1900 - 2000;
      $mon += 1;
      substr($$buf_ref, 3, 6, pack('C6', $year, $mon, $mday, $hour, $min, $sec));
    },
    response_parse => [qw(
      xaa C
      a1 n
      a2 n
      a3 n
      a4 n
      a5 n
      a6 n
      a7 n
      a8 n
      a9 n
      a10 n
      a11 n
      a12 n
      a13 n
      a14 n
      a15 n
      a16 n
      a17 n
      x47 C
      csum n
      x0d0a n
    )],
  },
  READ_SENSOR => {
    request => pack('C13', 0x55, 0xCD, 0x47, (0x00) x 8, 0x0D, 0x0A),
    response_parse => [
      start => ['C', 0xAA],
      pm25  => ['n', undef, [1000]],
      pm10  => ['n', undef, [1000]],
      hcho  => ['n', undef, [0xFFFF,3100]],
      vocs  => ['n', undef, [3100]],
      co2   => ['n', undef, [5100]],
      temp  => ['n', undef, [10100]],
      rh    => ['n', undef, [10100]],
      batt_status => ['C'],
      batt_charge => ['C'],
      p003  => ['n'],
      p005  => ['n'],
      p010  => ['n'],
      p025  => ['n'],
      p050  => ['n'],
      p100  => ['n'],
      nul   => ['n'],
      nul   => ['n'],
      nul   => ['n'],
      x47   => ['C', 0x47],
      csum  => ['n'],
      end   => ['n', 0x0D0A],
    ],
    response_data => [
      pm25 =>        ['%d',     1,     'ug/m^3'],
      pm10 =>        ['%d',     1,     'ug/m^3'],
      hcho =>        ['%1.03f', 0.001, 'mg/m^3'],
      vocs =>        ['%1.03f', 0.001, 'mg/m^3'],
      co2  =>        ['%4d',    1,     'ppm',],
      temp =>        ['%3.02f', 0.01,  'C'],
      rh =>          ['%2.02f', 0.01,  '%'],
      batt_status => ['%d',     1,     ''],
      batt_charge => ['%d',     1,     ''],
      p003 =>        ['%5d',    1,     ''],
      p005 =>        ['%5d',    1,     ''],
      p010 =>        ['%5d',    1,     ''],
      p025 =>        ['%5d',    1,     ''],
      p050 =>        ['%5d',    1,     ''],
      p100 =>        ['%5d',    1,     ''],
    ],
  },
};

#use Data::Dumper;
#print Dumper $formats;

sub serial_port_init {
  $am7 = AnyEvent::SerialPort->new(
    serial_port => [
      $PORT,
      [ baudrate => 19200 ],
      [ debug => 1 ],
    ],
    on_error => sub {
      my ($hdl, $fatal, $msg) = @_;
      AE::log error => $msg;
      $hdl->destroy;
      $am7 = undef;
      wait_device;
    },
  );
}

sub get_sum {
  my ($buf_ref) = @_;
  sum unpack('C*', substr($$buf_ref, 0, -4));
}

sub update_sum {
  my ($buf_ref) = @_;

  my $sum = get_sum($buf_ref);
  substr($$buf_ref, -4, 2, pack('n', $sum));
}

sub op_SET_TIME {
  my $op = 'SET_TIME';

  my $out = $formats->{$op}->{request};
  my $request_update = $formats->{$op}->{request_update};
  my @parse = @{$formats->{$op}->{response_parse}};

  if ($request_update) {
    $request_update->(\$out);
  }
  update_sum(\$out);

  $am7->push_write($out);
  $am7->on_read(sub {
    shift->unshift_read(chunk => 40, sub {
      unless (@_) {
	return wait_device;
      }
      my $response = $_[1];

      my $ok = 1;
      my $packstring = join('', map { $parse[$_*2+1][0] } 0..int((@parse-1)/2));
      my @v = unpack($packstring, $response);
      my %r;
      for (my $i = 0; $i < @v; $i++) {
	printf("%s = %X\n", $parse[$i*2], $v[$i]);
	$r{$parse[$i*2]} = $v[$i];
      }
      my $sum = pack('n', get_sum(\$response));

      if ($r{xaa} != 0xAA) {
	warn sprintf('Wrong start: %2X != %2X', 0xAA, $r{xaa});
	$ok = 0;
      } elsif ($r{x0d0a} != 0x0D0A) {
	warn sprintf('Wrong end: %4X != %4X', 0x0D0A, $r{x0d0a});
	$ok = 0;
      } elsif ($r{csum} eq $sum) {
	warn sprintf('Wrong checksum: %4X != %4X', $r{csum}, $sum);
	$ok = 0;
      }

      my @vals = unpack('C*', $response);
      my @hex_in = map { sprintf('%3X', ord($_)) } @vals;
      my @ord_in = map { sprintf('%3d', ord($_)) } @vals;
      printf('%s: %s', ($ok ? 'OK' : 'ERR'), "@hex_in\n");
      printf('%s: %s', ($ok ? 'OK' : 'ERR'), "@ord_in\n");
    });
  });
}

sub op_READ_SENSOR {
  my $op = 'READ_SENSOR';
  unless ($timer) {
    return $timer = AE::timer 2.0, 0, sub {
      op_READ_SENSOR();
    };
  }
  $timer = undef;

  my $out = $formats->{$op}->{request};
  my @parse = @{$formats->{$op}->{response_parse}};
  my %parse = @parse;
  my $response_data = $formats->{$op}->{response_data};
  {
    my %response_data = @{$response_data};
    for (keys %response_data) {
      die "$_" unless (defined $parse{$_});
    }
  }

  update_sum(\$out);
  $am7->push_write($out);

  $am7->on_read(sub {
    shift->unshift_read(chunk => 40, sub {
      unless (@_) {
	return wait_device;
      }
      my $response = $_[1];
      op_READ_SENSOR;

      my $ok = 1;
      my $packstring = join('', map { $parse[$_*2+1][0] } 0..int((@parse-1)/2));
      my @v = unpack($packstring, $response);
      my %r;
      for (my $i = 0; $i < @v; $i++) {
	#printf("%s = %X\n", $parse[$i*2], $v[$i]);
	$r{$parse[$i*2]} = $v[$i];
      }
      my $sum = pack('n', get_sum(\$response));
      if ($r{csum} eq $sum) {
	warn sprintf('Wrong checksum: %4X != %4X', $r{csum}, $sum);
	$ok = 0;
      }
      for my $k (keys %parse) {
	my ($pack, $ok_value, $err_values) = @{$parse{$k}};
	if (defined $ok_value and ref($ok_value) eq 'SCALAR' and $r{$k} != $ok_value) {
	  if ($pack eq 'C') {
	    warn sprintf('Field %s wrong value: %2X != %2X', $ok_value, $r{$k});
	  } elsif ($pack eq 'n') {
	    warn sprintf('Field %s wrong value: %4X != %4X', $ok_value, $r{$k});
	  }
	  $ok = 0;
	  last;
	}
	if (defined $err_values and grep { $r{$k} == $_ } @{$err_values}) {
	  $ok = 0;
	  last;
	}
      }

      if ($ok and $response_data) {
	my %out;
	$out{'time'} = sprintf('%0.3f', time);
	print "OK: {";
	printf(' "%s":%s', $_, $out{$_}) for ('time');
	for (my $i = 0; $i < @{$response_data}; ) {
	  my ($name) = $response_data->[$i++];
	  my ($fmt, $mul, $unit) = @{$response_data->[$i++]};
	  $out{$name} = sprintf($fmt, $r{$name} * $mul);
	  printf(',"%s":%s', $name, $out{$name});
	}
	print "}\n";
	return;
      }

      my @vals = unpack('C*', $response);
      my @hex_in = map { sprintf(' %2X', $_) } @vals;
      my @ord_in = map { sprintf('%3d', $_) } @vals;
      printf('%s: %s', ($ok ? 'OK' : 'ERR'), "@hex_in\n");
      printf('%s: %s', ($ok ? 'OK' : 'ERR'), "@ord_in\n");
    });
  });
}

sub wait_device {
  aio_stat $PORT, sub {
    if ($_[0]) {
      return $wait_device_timer = AE::timer $wait_device_wait, 0, sub {
	$wait_device_wait = min($wait_device_wait*1.1, $wait_device_max_wait);
	wait_device;
      };
    }
    $wait_device_wait = $wait_device_initial_wait;
    serial_port_init;
    op_READ_SENSOR;
  };
}

wait_device;

$cv->recv;
