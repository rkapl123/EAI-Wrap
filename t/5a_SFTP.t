# to use these testcases, activate a local SFTP service and create ../config/Test/site.config with a user/pwd in the prefix sftp there.
use strict; use warnings;
use EAI::FTP; use Test::More; use Test::File; use File::Spec; use Data::Dumper;

my $author = eval "no warnings; getlogin eq 'rolan'";
plan skip_all => "tests not automatic in non-author environment" if ($^O =~ /MSWin32/i and not $author);
use Test::More tests => 13;
require './setup.t';

my $sshExecutable = 'C:/dev/EAI/putty/PLINK.EXE';
my $filecontent = "skipped line\nID1\tID2\tName\tNumber\n234234\t2\tFirstLast2\t123123.0\n543453\t1\tFirstLast1\t546123.0\n";
open (FH,">test.txt");
print FH $filecontent;
close FH;

my %config;
my $siteCONFIGFILE;
open (CONFIGFILE, "<../config/Test/site.config") or die("couldn't open config/Test/site.config: $@ $!, caller ".(caller(1))[3].", line ".(caller(1))[2]." in ".(caller(1))[1]);
{
	local $/=undef;
	$siteCONFIGFILE = <CONFIGFILE>;
	close CONFIGFILE;
}
unless (my $return = eval $siteCONFIGFILE) {
	die("Error parsing config file: $@") if $@;
	die("Error executing config file: $!") unless defined $return;
	die("Error executing config file") unless $return;
}

my ($ftpHandle, $ftpHost);

login({remoteHost => {Prod => "unknown", Test => "unknown"}, sshInstallationPath => $sshExecutable, maxConnectionTries => 2,privKey => "",FTPdebugLevel => 0,user => "", pwd => ""},{env => "Test"});
($ftpHandle, $ftpHost) = getHandle();
ok(!defined($ftpHandle),"expected login failure");

login({remoteHost => {Prod => "localhost",Test => "localhost"}, sshInstallationPath => $sshExecutable, maxConnectionTries => 2,privKey => "",FTPdebugLevel => 0,hostkey => $config{sensitive}{sftp}{hostkey},user => $config{sensitive}{sftp}{user}, pwd => $config{sensitive}{sftp}{pwd}},{env => "Test"});
($ftpHandle, $ftpHost) = getHandle();
ok(defined($ftpHandle) && $ftpHost eq "localhost","login success");
setHandle($ftpHandle) or print "error: $@";

# create an archive dir
$ftpHandle->mkdir("Archive");
$ftpHandle->mkdir("relativepath");

putFile({remoteDir => "/relativepath", dontUseTempFile=> 1},{fileToWrite => "test.txt"});
my $fileUploaded1 = $ftpHandle->ls(".", wanted => qr/test\.txt/, names_only => 1) or die "unable to retrieve directory: ".$ftpHandle->error;
ok($fileUploaded1->[0] eq "test.txt","test.txt uploaded file relativepath");

putFile({remoteDir => "/relativepath",dontMoveTempImmediately =>1},{fileToWrite => "test.txt"});
my $fileUploaded2 = $ftpHandle->ls(".", wanted => qr/temp\.test\.txt/, names_only => 1) or die "unable to retrieve directory: ".$ftpHandle->error;
ok($fileUploaded2->[0] eq "temp.test.txt","test.txt uploaded temp file relativepath");

putFile({remoteDir => "/",dontMoveTempImmediately =>1},{fileToWrite => "test.txt"});
my $fileUploaded3 = $ftpHandle->ls("/", wanted => qr/temp\.test\.txt/, names_only => 1) or die "unable to retrieve directory: ".$ftpHandle->error;
ok($fileUploaded3->[0] eq "temp.test.txt","test.txt uploaded temp file");
unlink "test.txt",

moveTempFile({remoteDir => "."},{fileToWrite => "test.txt"});
my $fileMoved = $ftpHandle->ls("", wanted => qr/^test\.txt$/, names_only => 1) or die "unable to retrieve directory: ".$ftpHandle->error;
ok($fileMoved->[0] eq "test.txt","test.txt renamed temp file");

my @retrieved;
fetchFiles({remoteDir => "",localDir => "."},{retrievedFiles=>\@retrieved},{fileToRetrieve => "test.txt"});
ok($retrieved[0] eq "test.txt","retrieved file in returned array");
file_contains_like("test.txt",qr/$filecontent/,"test.txt downloaded file");

my @retrieved2;
fetchFiles({remoteDir => "",localDir => "."},{retrievedFiles=>\@retrieved2},{fileToRetrieve => "relativepath/*.txt"});
ok($retrieved2[0] eq "temp.test.txt","retrieved file in returned array");
ok($retrieved2[1] eq "test.txt","retrieved file in returned array");

archiveFiles({remoteDir => "", archiveDir => "Archive", timestamp => "date_time.", filesToArchive => ["test.txt"]});
my $fileArchived = $ftpHandle->ls("Archive", wanted => qr/date_time\.test\.txt/, names_only => 1) or die "unable to retrieve directory: ".$ftpHandle->error;
ok($fileArchived->[0] eq "date_time.test.txt","test.txt archived file to date_time.test.txt");

removeFiles({remoteDir => "relativepath", filesToRemove => ["temp.test.txt", "test.txt"]});
my $fileExisting1 = $ftpHandle->ls(".", wanted => qr/.*\.txt/, names_only => 1) or die "unable to retrieve directory: ".$ftpHandle->error;
ok(@$fileExisting1 == 0, "removeFiles removed multiple files");

removeFilesOlderX({remoteDir => "/", remove => {removeFolders => ["Archive"], day=>-1, mon=>0, year=>0},});
# we're still in Archive, so ls "."
my $fileExisting2 = $ftpHandle->ls(".", wanted => qr/date_time\.test\.txt/, names_only => 1) or die "unable to retrieve directory: ".$ftpHandle->error;
ok(@$fileExisting2 == 0,"removeFilesOlderX removed file");

# cleanup
$ftpHandle->setcwd("..");
$ftpHandle->rmdir("Archive");
$ftpHandle->rmdir("relativepath");
unlink "test.txt";
unlink "temp.test.txt";
unlink glob "*.config";

done_testing();