#!/usr/bin/perl -w

########################################################################
#
# run_report.pl
# 
# Author: Dmitry Minaev, Five9 (dminaev@five9.com)
#
# Description: script calls Five9 API to run a report, then puts results
#	into a CSV file and uploads file by SFTP.
########################################################################

use strict;
use warnings;

use SOAP::Lite; # +trace => 'debug'; # uncomment if you want to see API request/response
use DateTime;
use Net::SFTP::Foreign;
use Data::Dumper;
use Cwd;

my $constants;

########################################################################
### Main execution goes here

eval { main(); };

if($@) {
	print $@;
}


########################################################################
### Main

sub main {

	$constants = parse_config_file();
	my ($start_ts, $end_ts) = get_reporting_period();
	my $client = initialize_SOAP();
	my $repID = run_report($client, $start_ts, $end_ts);
	wait_till_report_ends($client, $repID);
	my $filename = get_report_results($client, $repID);
	upload($constants->{'FTP_HOST'}, $constants->{'FTP_USER'}, $constants->{'FTP_PASS'}, $constants->{'SPOOL'}.$filename, $constants->{'FTP_FLDR'}.$filename);

	return 0;
}


########################################################################
### Functions

### read config file
sub parse_config_file {

	my %ret;

	my $filepath = Cwd::getcwd()."/config.txt";
	open(my $fh, '<:encoding(UTF-8)', $filepath)
	  or die "Could not open file '$filepath' $!";

	while (<$fh>) {
		chomp;                  # no newline
		s/#.*//;                # no comments
		s/^\s+//;               # no leading white
		s/\s+$//;               # no trailing white
		next unless length;     # anything left?
		my ($var, $value) = split(/\s*=\s*/, $_, 2);
		$ret{$var} = $value;
	}

	return \%ret;
}

### get current date and time
sub getCurrentTime {

	my (
		$sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst
	) = gmtime(time());

	my $dt = DateTime->new(
		'year'		=> 1900 + $year,
		'month'		=> $mon + 1,
		'day'		=> $mday,
		'hour'		=> $hour,
		'minute'	=> $min,
		'second'	=> $sec,
		'time_zone'	=> 'GMT'
	);

	return $dt;
}

### upload report by sftp
sub upload {

	my ($host, $user, $pass, $local, $remote) = @_;
	my ($err, $sftp);

	print "Uploading file ${local} to ${user}:${pass}\@${host}:${remote}\n" if $constants->{'DEBUG'};

	eval {
		$err = ($sftp->error ? $sftp->error : undef) if
			(!($sftp = Net::SFTP::Foreign->new(host => $host, user => $user, password => $pass)) ||
			 !($sftp->put($local, $remote, late_set_perm => 1,  copy_perms => 0, copy_time => 0)));
	};

	if(defined $err || $@) {
		$err = "SFTP Error: $@". (defined $err ? "$err" : "");
		print $err."\n";
		return 1;
	}

	print "File successfully uploaded" if $constants->{'DEBUG'};

	return 0;
}


########################################################################
### get reporting period
sub get_reporting_period {

	my $tz = $constants->{'REPORTING_PERIOD_TIMEZONE'};
	my $dt = getCurrentTime();
	$dt->set_time_zone($tz);
	
	my $dtend = $dt->clone();
	$dtend->set(
		'hour' 	 => 0,
		'minute' => 0,
		'second' => 0
	);
	
	my $dtstart = $dtend->clone();
	$dtstart->subtract('days' => $constants->{'REPORTING_PERIOD_NUMBER_OF_DAYS'});
	
	my $start_ts = $dtstart->format_cldr(q{yyyy-MM-ddTHH:mm:ss.SSSZZZZZ});
	my $end_ts   =   $dtend->format_cldr(q{yyyy-MM-ddTHH:mm:ss.SSSZZZZZ});

	# Please note:
	# $start_ts and $end_ts format should be: '2014-04-08T00:00:00.000-07:00';
	# if you have different format returned please update DateTime module to version 1.07+
	print $start_ts." - ".$end_ts."\n" if $constants->{'DEBUG'};

	return ($start_ts, $end_ts);
}


########################################################################
### initialize SOAP
sub initialize_SOAP {

	my $client = SOAP::Lite->new()
		->soapversion('1.2')
		->service($constants->{'BASEURI'}.$constants->{'FIVE9USERNAME'})
		->readable('true')
		->on_fault(
			sub {
				my($soap, $res) = @_; 
				die (ref($res) ? Dumper $res->faultdetail : Dumper $soap->transport->status, "\n");
			})
		;
	
	#- Overriding the constant for SOAP 1.2
	$SOAP::Constants::DEFAULT_HTTP_CONTENT_TYPE = 'application/soap+xml';
	
	#- Pass Basic login/password authentication, override get_basic_credentials function
	sub SOAP::Transport::HTTP::Client::get_basic_credentials {
		my $u = $constants->{'FIVE9USERNAME'};
		my $p = $constants->{'FIVE9PASSWORD'};
		return $u => $p;
	}

	return $client;
}


########################################################################
### run report and get the report ID
sub run_report {

	my ($client, $start_ts, $end_ts) = @_;

	my $repID = '';

	### run the report
	$repID = $client->runReport(
		$client,
		SOAP::Data->name('folderName', $constants->{'FOLDERNAME'}),
		SOAP::Data->name('reportName', $constants->{'REPORTNAME'}),
		SOAP::Data->name('criteria' => \SOAP::Data->value(
				SOAP::Data->name('reportObjects' => \SOAP::Data->value(
					SOAP::Data->name('objectNames', ''),					# DUMMY FILTERS
					SOAP::Data->name('objectType', 'CallVariable')			# DUMMY FILTERS
				)),
				SOAP::Data->name('time' => \SOAP::Data->value(
					SOAP::Data->name('end', $end_ts),
					SOAP::Data->name('start', $start_ts)
				))
		))
	);

	print "Report id: " . $repID . "\n" if $constants->{'DEBUG'};

	return $repID;
}

########################################################################
### Wait till report ends
sub wait_till_report_ends {

	my ($client, $repID) = @_;

	my $repState = 'true';
	my $repTime = 0;
	my $updInterval = 15;

	while($repState eq 'true') {

		$client->soapversion('1.2'); # MANDATORY
		$repState = $client->isReportRunning(
			$client,
			SOAP::Data->name('identifier', $repID),
			SOAP::Data->name('timeout', $updInterval)
		);
		if($constants->{'DEBUG'}) {
			print "Working... ".$repTime." seconds passed\r";
			$repTime += $updInterval;
		}
	}
}


sub get_report_results {

	my ($client, $repID) = @_;

	########################################################################
	### Get report results

	$client->soapversion('1.2'); # MANDATORY

	my $filename = $constants->{'REPORT_FILENAME'}.'.csv';	# this is the place to adjust the filename, e.g. add a reporting period or anything

	# open file
	open (CSV, ">".$constants->{'SPOOL'}.$filename) || die "$!";

	# get report results
	my $rslt = $client->getReportResultCsv($client, SOAP::Data->name('identifier', $repID));

	# replace line endings
	$rslt =~ s/\n/\r\n/g;

	# print report data to file
	print CSV $rslt;

	# close file
	close CSV;

	print "Resulting report: ".$constants->{'SPOOL'}."$filename\n" if $constants->{'DEBUG'};

	return $filename;
}
