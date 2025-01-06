use strict; use feature 'unicode_strings'; use Time::localtime;
# enter new version to update all modules with
my $data = read_file ("Makefile.PL");
my ($newVersion) = ($data =~ /', version => 1\.([\d]+)},/);
$newVersion++; $newVersion="1.$newVersion";
print "new version is $newVersion (any entry to accept, empty to skip and only fetch param descriptions into Wrap.pm):";
my $doNewVersion = <STDIN>;
chomp $doNewVersion;

# used for CONFIGURATION REFERENCE, fetches comments from %hashCheck in Common.pm and translates them to pod =items
open (COMMONFILE, "<".'lib\EAI\Common.pm') or die ('can\'t open lib\EAI\Common.pm for reading');
my $insertIntoEAIWrap; my $return; my $startParsing;
while (<COMMONFILE>){
	if (/my %hashCheck = \(/) {
		$startParsing = 1;
		$insertIntoEAIWrap.="=over 4\n\n";
		next;
	}
	next if !$startParsing;
	if (/\t\},/) {
		$insertIntoEAIWrap.="=back\n\n" if $return;
		$return = 0;
	}
	if (/^\t(\S*?) =>.*# (.*?)$/) {
		$insertIntoEAIWrap.="=item $1\n\n$2\n\n=over 4\n\n" if $2;
		$return = $2;
	}

	if (/^\t\t(\S*?) =>.*# (.*?)$/) {
		$insertIntoEAIWrap.="=item $1\n\n$2\n\n" if $2;
	}
	if (/^\);$/) {
		$insertIntoEAIWrap.="=back\n\n";
		last;
	}
}
close COMMONFILE;

print "updating version to $newVersion for Makefile.PL\n";
$data =~ s/', version => [\d\.]+},/', version => $newVersion},/g if $doNewVersion;
write_file("Makefile.PL", $data);

my $curYear = localtime->year()+1900;
$data = read_file ("lib/EAI/Wrap.pm");
print "updating ".($doNewVersion ? "version to $newVersion/year of copyright" : "copyright")." and API descriptions for Wrap.pm\n";
$data =~ s/^(.*?)=head2 CONFIGURATION REFERENCE\n\n(.*?)=head1 COPYRIGHT(.*?)$/$1=head2 CONFIGURATION REFERENCE\n\n${insertIntoEAIWrap}=head1 COPYRIGHT$3/s;
$data =~ s/^package EAI::(.*?) (.*?);\n(.*?)/package EAI::$1 $newVersion;\n$3/s if $doNewVersion;
$data =~ s/Copyright \(c\) (\d{4}) Roland Kapl/Copyright \(c\) $curYear Roland Kapl/s;
write_file("lib/EAI/Wrap.pm", $data);

for my $libfile ("Common","File","FTP","DB","DateUtil") {
	print "updating ".($doNewVersion ? "version to $newVersion/year of copyright" : "copyright")." for $libfile.pm\n";
	my $data = read_file ("lib/EAI/$libfile.pm");
	$data =~ s/^package EAI::(.*?) (.*?);\n(.*?)/package EAI::$1 $newVersion;\n$3/s if $doNewVersion;
	$data =~ s/Copyright \(c\) (\d{4}) Roland Kapl/Copyright \(c\) $curYear Roland Kapl/s;
	write_file("lib/EAI/$libfile.pm", $data);
}
print "updating copyright for LICENSE\n";
$data = read_file ("LICENSE");
$data =~ s/Copyright \(c\) 2023-(\d{4}) Roland Kapl/Copyright \(c\) 2023-$curYear Roland Kapl/s;
write_file("LICENSE", $data);

print "enter to finish, don't forget to add changes to Changes file before creating/uploading the distribution!";
<STDIN>;

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
