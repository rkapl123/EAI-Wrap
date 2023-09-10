use strict; use warnings; use Data::Dumper;
use EAI::Common; use Test::More; use Test::File; use File::Spec;
use Test::More tests => 16;

require './t/setup.pl';
chdir "./t";
our %config = (sensitive => {db => {user => "sensitiveDBuserInfo", pwd => "sensitiveDBPwdInfo"},ftp => {user => {Test => "sensitiveFTPuserInfo", Prod => ""}, pwd => {Test => "sensitiveFTPPwdInfo", Prod => ""}}});
our %execute = (env => "Test");

is(getSensInfo("db","user"),"sensitiveDBuserInfo","sensitive info direct set");
is(getSensInfo("ftp","pwd"),"sensitiveFTPPwdInfo","sensitive info environment lookup");

$config{process} = {uploadCMD => "testcmd",};
%common = (process => {uploadCMDPath => "path_to_testcmd"});
# first prevents inheritance from %common (but NOT from %config!), second inherits from %common
@loads = ({process_ => {}},{process => {uploadCMDLogfile => "testcmd.log"}});
my @loads_expected=({process=>{uploadCMDPath=>undef,uploadCMD=>'testcmd'},File=>{},DB=>{},FTP=>{}},{process=>{uploadCMDPath=>'path_to_testcmd',uploadCMD=>'testcmd',uploadCMDLogfile=>'testcmd.log'},File=>{},DB=>{},FTP=>{}});
setupConfigMerge();
is_deeply(\@loads,\@loads_expected,"merge configs");

@ARGV = ('--process','uploadCMD=testcmd from opt','--load0process','uploadCMDPath=path_to_testcmd from opt');
getOptions();
is($opt{process}{uploadCMD},"testcmd from opt","command line parsing into common");
is($optload[0]{process}{uploadCMDPath},"path_to_testcmd from opt","command line parsing into loads");
setupConfigMerge(); # need to call merge again to bring options into config
is($common{process}{uploadCMD},"testcmd from opt","command line parsing into common in config");
is($loads[0]{process}{uploadCMDPath},"path_to_testcmd from opt","command line parsing into loads in config");

my ($process) = extractConfigs(\%common,"process");
my $process_expected = {uploadCMDPath=>'path_to_testcmd',uploadCMD=>'testcmd from opt'};
is_deeply($process,$process_expected,"extractConfigs");

$config{invalid} = "invalid key";
is(checkHash(\%config,"config"),0,"detected invalid key in hash");
like($@, qr/key name not allowed: \$config\{invalid\}, when calling/, "invalid key exception");
delete $config{invalid};

$config{smtpTimeout} = "invalid value";
is(checkHash(\%config,"config"),0,"detected invalid key value in hash");
like($@, qr/wrong type for value: \$config\{smtpTimeout\}, when calling/, "invalid key value exception");
$config{smtpTimeout} = 60;

$config{logRootPath} = "invalid value";
is(checkHash(\%config,"config"),0,"detected invalid key reference value in hash");
like($@, qr/wrong reference type for value: \$config\{logRootPath\}, when calling/, "invalid key reference value exception");

is(checkStartingCond(\%common),0,"no starting condition exit");

$common{task}{skipHolidays} = "TEST";
is(checkStartingCond(\%common),1,"starting condition exit because holiday");

unlink "config/site.config";
unlink "config/log.config";
rmdir "config";
done_testing();