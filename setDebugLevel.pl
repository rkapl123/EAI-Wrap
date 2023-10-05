use strict; use feature 'unicode_strings';
my $mainLoop = 1; 
my %levels = ("e" => "ERROR", "i" => "INFO", "d" => "DEBUG", "t" => "TRACE");
my %appenders = ("s" => "SCREEN", "m" => "MAIL", "f" => "FILE");
# main loop: read log.config and write back changes made by user choices
while (1) {
	system $^O eq 'MSWin32' ? 'cls' : 'clear'; # clear screen first
	my $data = read_file ($ENV{EAI_WRAP_CONFIG_PATH}."/log.config");
	my @datalines = split('\n',$data);
	my $i=1; my %toChange; my %levelToChange;
	# print loggers with levels to screen, collecting them for later change
	print "Use setDebugLevel to change the following entries from $ENV{EAI_WRAP_CONFIG_PATH}/log.config:\n\n";
	do {
		print "$i: $datalines[$i-1]\n";
		($toChange{$i},$levelToChange{$i}) = ($datalines[$i-1] =~ /(.+?) = (.+?)$/) if $datalines[$i-1] =~ /(.+?) = (.+?)$/;
		($toChange{$i},$levelToChange{$i}) = ($datalines[$i-1] =~ /(.+?) = (.+?),.*$/) if $datalines[$i-1] =~ /(.+?) = (.+?),.*$/;
		$i+=1;
	} until($datalines[$i-1] eq "" or $datalines[$i-1] eq "\r");
	# ask user for choices of logger to change
	print "\nenter first logger (1..".($i-1).") or (#) to invert comments globally,\nthen level to change to ((E)RROR, (I)NFO, (D)EBUG, (T)RACE) or (#) to comment the logger in/out,\nand finally optional appenders ((S)CREEN, (M)AIL, (F)ILE) not for rootLogger!), only possible with changing the level.\n(no entry ends the program):";
	my $choice= <STDIN>; chomp $choice;
	last if !$choice; # break out of loop
	my ($loggerToChange,$level,$appenders) = ($choice =~ /^(.)(.)(.*?)$/);
	my @appenders = split(//,lc($appenders)); $appenders = "";
	for (@appenders) {
		if ($appenders{$_}) {
			$appenders.=", ".$appenders{$_};
		} else {
			print "invalid choice made for appender ($_)\npress enter";
			<STDIN>;
		}
	}
	# globally invert comments if the only input is #
	if ($choice eq "#") {
		$i=0;
		do {
			if ($datalines[$i] =~ /^#.+$/) {
				$datalines[$i] =~ s/#//;
				$data =~ s/^#$datalines[$i]$/$datalines[$i]/gm;
			} else {
				$data =~ s/^$datalines[$i]$/#$datalines[$i]/gm;
			}
			$i+=1;
		} until($datalines[$i] eq "" or $datalines[$i] eq "\r");
	} else {
		print "you have to enter at least two choices or only # for inverting comments\n" if !$level and !$loggerToChange;
		print "invalid choice made for level ($level), available:".join(" ",%levels)."\n" if !$levels{$level} and $toChange{$loggerToChange};
		print "invalid choice made for logger to change ($loggerToChange)\n" if !$toChange{$loggerToChange} and $levels{$level};
		# now change it in the log.config
		if ($level eq "#") {
			# toggle comments
			if ($toChange{$loggerToChange} =~ /^#.+$/) {
				$toChange{$loggerToChange} =~ s/#//;
				$data =~ s/^#$toChange{$loggerToChange} = (.*?)$/$toChange{$loggerToChange} = $1/gm;
			} else {
				$data =~ s/^$toChange{$loggerToChange} = (.*?)$/#$toChange{$loggerToChange} = $1/gm;
			}
		} elsif ($toChange{$loggerToChange} and $levels{$level}) {
			# change level and appenders (except for root logger)
			if ($toChange{$loggerToChange} =~ /rootLogger/) {
				$data =~ s/^$toChange{$loggerToChange} = $levelToChange{$loggerToChange}(.*?)$/$toChange{$loggerToChange} = $levels{$level}$1/gm;
			} else {
				$data =~ s/^$toChange{$loggerToChange} = $levelToChange{$loggerToChange}(.*?)$/$toChange{$loggerToChange} = $levels{$level}$appenders/gm;
			}
		} else {
			print "press enter";
			<STDIN>;
			next;
		}
	}
	# and write back
	write_file($ENV{EAI_WRAP_CONFIG_PATH}."/log.config", $data);
}

sub read_file {
	my ($filename) = @_;

	open my $in, '<:encoding(UTF-8)', $filename or die "Could not open '$filename' for reading $!";
	binmode($in);
	local $/ = undef;
	my $all = <$in>;
	close $in;

	return $all;
}

sub write_file {
	my ($filename, $content) = @_;

	open my $out, '>:encoding(UTF-8)', $filename or die "Could not open '$filename' for writing $!";
	binmode($out);
	print $out $content;
	close $out;

	return;
}

