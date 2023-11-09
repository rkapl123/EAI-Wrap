use strict; use EAI::Wrap;

my $curDate = get_curdate();
my $curDateDash = get_curdate_gen("Y/M/D");
my $curhyphenDate = get_curdate_gen("Y-M-D");
my $curdotDate = get_curdate_dot();
my $curTime = get_curtime_HHMM();

setupConfigMerge();

my $logger = get_logger();
$logger->info(">>>>>>> starting logcheck, curDate: $curDate, curDateDash: $curDateDash, curhyphenDate: $curhyphenDate, curdotDate: $curdotDate, curTime: $curTime, weekday(curDate):".weekday($curDate).",is_last_day_of_month(curDate):".is_last_day_of_month($curDate));

LOGCHECK:
foreach my $job (keys %{$config{checkLookup}}) {
	next LOGCHECK if $job eq "checkLogExist.pl"; # don't check our own logfile, configuration only for own error emailing (e.g from setupConfigMerge)
	my $freqToCheck = $config{checkLookup}{$job}{freqToCheck}; # frequency to check log file (business-daily, daily, monthly, etc.), default (if not given): every business day
	$freqToCheck = "B" if !$freqToCheck;
	my $timeToCheck = $config{checkLookup}{$job}{timeToCheck}; # earliest time to check log start entry
	my $logFileToCheck = $config{checkLookup}{$job}{logFileToCheck}; # Logfile to be searched
	my $logRootPath = ($config{checkLookup}{$job}{logRootPath} ne "" ? $config{checkLookup}{$job}{logRootPath} : $config{logRootPath}{""}); # default log root path
	my $prodEnvironmentInSeparatePath = ($config{checkLookup}{$job}{prodEnvironmentInSeparatePath} ne "" ? $config{checkLookup}{$job}{prodEnvironmentInSeparatePath} : $config{prodEnvironmentInSeparatePath});
	# amend logfile path with environment, depending on prodEnvironmentInSeparatePath:
	if ($prodEnvironmentInSeparatePath) {
		$logFileToCheck = $logRootPath.'/'.$execute{env}.'/'.$logFileToCheck;
	} else {
		$logFileToCheck = $logRootPath.($execute{envraw} ? '/'.$execute{envraw} : "").'/'.$logFileToCheck;
	}
	my $logcheck = $config{checkLookup}{$job}{logcheck}; # Logcheck (regex)
	
	$logger->info("preparing logcheck for $job, freqToCheck:$freqToCheck, timeToCheck:$timeToCheck, logFileToCheck:$logFileToCheck, logcheck regex:/$logcheck/");
	if ($freqToCheck eq "B" and (is_weekend($curDate) || is_holiday($config{logCheckHoliday},$curDate))) {
		$logger->info("IGNORING logcheck for $job as freqToCheck eq B and is_weekend($curDate)=".is_weekend($curDate)." || is_holiday(".$config{logCheckHoliday}.",$curDate)=".is_holiday($config{logCheckHoliday},$curDate));
		next LOGCHECK;
	}
	if ($freqToCheck eq "M1" and $curDate !~ /\d{4}\d{2}01/) {
		$logger->info("IGNORING logcheck for $job as freqToCheck eq M1 and curDate ($curDate) !~ /\d{4}\d{2}01/");
		next LOGCHECK;
	}
	if ($freqToCheck eq "Q" and $curDate !~ /\d{4}0102/ and $curDate !~ /\d{4}0401/ and $curDate !~ /\d{4}0701/ and $curDate !~ /\d{4}1001/) {
		$logger->info("IGNORING logcheck for $job as freqToCheck eq Q and curDate ($curDate) !~ /\d{4}0102/ and curDate !~ /\d{4}0401/ and curDate !~ /\d{4}0701/ and curDate !~ /\d{4}1001/");
		next LOGCHECK;
	}
	if ($freqToCheck eq "ML" and !is_last_day_of_month($curDate)) {
		$logger->info("IGNORING logcheck for $job as freqToCheck eq ML and !is_last_day_of_month($curDate)=".is_last_day_of_month($curDate));
		next LOGCHECK;
	}
	if (substr($freqToCheck,0,1) eq "W" and !(weekday($curDate) eq substr($freqToCheck,1,1))) {
		$logger->info("IGNORING logcheck for $job as substr($freqToCheck,0,1) eq W and !(weekday($curDate) (".weekday($curDate).") eq substr($freqToCheck,1,1))");
		next LOGCHECK;
	}
	if (substr($freqToCheck,0,2) eq "MW" and !(first_weekYYYYMMDD($curDate,substr($freqToCheck,2,1)))) {
		$logger->info("IGNORING logcheck for $job as substr($freqToCheck,0,2) eq MW and !(first_weekYYYYMMDD($curDate,substr($freqToCheck,2,1)))");
		next LOGCHECK;
	}
	if ($timeToCheck gt $curTime) {
		$logger->info("IGNORING logcheck for $job as timeToCheck gt ".$curTime);
		next LOGCHECK;
	}
	# for non prod environments
	if ($execute{envraw}) {
		# ignore some jobs in non prod environments
		if ($config{logs_to_be_ignored_in_nonprod} ne "" and $job =~ $config{logs_to_be_ignored_in_nonprod}) {
			$logger->info("IGNORING logcheck for $job as environment not Production and non production logs are to be ignored: ".$config{logs_to_be_ignored_in_nonprod});
			next LOGCHECK;
		}
	}
	my $infos = " is missing for job $job:\n";
	if (open (LOGFILE, "<$logFileToCheck")) {
		# check log file for log check pattern, assumption tab separated!
		while (<LOGFILE>){
			my $wholeLine = $_;
			my @logline = split "\t";
			# found, if log check pattern matches and date today, either YYYY/MM/DD or "german" logs using dd.mm.yyyy or log4j using YYYY-MM-DD
			if (($logline[0] =~ /$curDateDash/ or $logline[0] =~ /$curdotDate/ or $logline[0] =~ /$curhyphenDate/) and $wholeLine =~ /$logcheck/) {
				$logger->info("logcheck '".$logcheck."' successful, row:".$wholeLine);
				close LOGFILE; next LOGCHECK;
			}
		}
		$logger->info("$logcheck wasn't found in $logFileToCheck");
		$infos = "The log starting entry in logfile $logFileToCheck".$infos;
	} else {
		$infos = "The logfile $logFileToCheck".$infos;
	}
	close LOGFILE;
	# send mail for not found log entries
	# insert $curDate before file name with a dot
	my $lastLogFile = $logFileToCheck;
	$lastLogFile =~ s/^(.+?[\\\/])([^\\\/]+?)$/$1$curDate\.$2/;
	$infos = $infos."\njob: <$job>, frequency: ".$freqToCheck.", time to check: ".$timeToCheck.", log in file file:///".$logFileToCheck." resp. file:///".$lastLogFile;
	my $mailsendTo = ($execute{envraw} ? $config{testerrmailaddress} : $config{checkLookup}{$job}{errmailaddress});
	$logger->info("failed logcheck for '".$job."', sending mail to: '".$mailsendTo);
	EAI::Common::sendGeneralMail("", $mailsendTo,"","","Starting problem detected for $job",$infos,'text/plain');
	# sendGeneralMail($From, $To, $Cc, $Bcc, $Subject, $Data, $Type, $Encoding, $AttachType, $AttachFile)
}
__END__
=head1 NAME

checkLogExist.pl - checks Log-entries at given times

=head1 SYNOPSIS

 checkLogExist.pl

=head1 DESCRIPTION

checkLogExist should be called frequently in a separate job and checks if defined log entries exist in the defined log files, (hinting that the task was run/started), resp. whether the Logfile exists at all.

Configuration is done in sub-hash C<$config{checkLookup}>, being the same place for the errmailaddress/errmailsubject of error mails being sent in the tasks themselves:

 $config{checkLookup} = {
  <nameOfJobscript.pl> => {
     errmailaddress => "test\@test.com",
     errmailsubject => "testjob failed",
     timeToCheck => "0800",
     freqToCheck => "B",
     logFileToCheck => "test.log",
     logcheck => "started.*",
     logRootPath => "optional alternate logfile path"
   },
  <...> => {
     
   },
 }

The key consists of the scriptname + any additional defined interactive options, which are being passed to the script in an alphabetically sorted manner. For checkLogExist.pl the key is irrelevant as all entries of C<$config{checkLookup}> are worked through.

=over 4

=item errmailaddress 

where should the mail be sent to in case of non-existence of logfile/logline or an error in the script.

=item errmailsubject

subject-line for error mail, only used for error mail sending in the task scripts themselves.

=item timeToCheck

all checks earlier than this are ignored, given in format HHMM.

=item freqToCheck

ignore log check except on: ML..Monthend, D..every day, B..Business days, M1..Month-beginning, W{n}..Weekday (n:1=Sunday-7=Saturday)

=item logFileToCheck

Where (which logfile) should the job have written into ? this logfile is expected either in the logRootPath configured in site.config or in logRootPath configured for this locgcheck entry (see below).

=item logcheck

"regex keyword/expression" to compare the rows, if this is missing in the logfile after the current date/timeToCheck then an alarm is sent to the configured errmailaddress

=item logRootPath

instead of using the logRootPath configured in site.config, a special logRootPath can be optionally configured here for each log check.

=back

=head1 COPYRIGHT

Copyright (c) 2023 Roland Kapl

All rights reserved.  This program is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the LICENSE file included
with this module.

=cut