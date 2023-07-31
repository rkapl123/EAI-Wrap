# used for CONFIGURATION REFERENCE, fetches comments from %hashCheck in Common.pm and translates them to pod =items
open (COMMONFILE, "<".'C:\dev\EAI\lib\EAI\Wrap\Common.pm');
print "=head2 CONFIGURATION REFERENCE\n\n";
while (<COMMONFILE>){
	if (/my %hashCheck = \(/) {
		$startParsing = 1;
		print "=over 4\n\n";
		next;
	}
	next if !$startParsing;
	if (/\t\},/) {
		print "=back\n\n" if $return;
		$return = 0;
	}
	if (/^\t(\S*?) =>.*# (.*?)$/) {
		print "=item $1\n\n$2\n\n=over 4\n\n" if $2;
		$return = $2;
	}

	if (/^\t\t(\S*?) =>.*# (.*?)$/) {
		print "=item $1\n\n$2\n\n" if $2;
	}
	if (/^\);$/) {
		print "=back\n\n";
		last;
	}
}
close COMMONFILE;
