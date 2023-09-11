sub INIT {
	use Test::More;
	if ($ENV{EAI_WRAP_AUTHORTEST}) {
		plan tests => 11;
	} else {
		plan skip_all => "tests not automatic in non-author environment";
	}
}
# to use these testcases, activate a local SFTP service and create $ENV{EAI_WRAP_CONFIG_PATH}."/Test/site.config with a user/pwd in the prefix sftp there and set env variable EAI_WRAP_AUTHORTEST.
use strict; use warnings;
use EAI::Wrap; use Archive::Zip qw( :ERROR_CODES :CONSTANTS ); use Test::File; use File::Spec; use Test::Timer; use Data::Dumper;
chdir "./t";

# set up EAI::Wrap definitions
%common = (
	DB => {longreadlen => 1024,schemaName => "dbo",DSN => 'driver={SQL Server};Server=.;database=$DB->{database};TrustedConnection=Yes;',database => "testDB",primkey => "col1 = ?",tablename => "theTestTable",},
);
@loads = ({
	File => {localFilesystemPath => ".",dontKeepHistory => 1,filename => "test.zip",extract => 1,format_sep => "\t",format_skip => 1,format_header => "col1	col2	col3",},
	},{
	DB => {query => "select * from theTestTable"},
	FTP => {remoteDir=>"",remoteHost=>{Test => "localhost"},FTPdebugLevel=>0,privKey=>"",prefix=>"sftp",dontUseTempFile=>1,fileToRemove=>1},
	File => {filename => "testTarget.txt",dontKeepHistory => 1,format_sep => "\t",format_skip => 2,format_header => "col1	col2	col3",},
	},
);
$execute{env}="Test";
setupEAIWrap();

# set up DB environment for tests
openDBConn(\%common);
doInDB({doString => "DROP TABLE [dbo].[theTestTable];"});
my $createStmt = "CREATE TABLE [dbo].[theTestTable]([col1] [varchar](5) NOT NULL,[col2] [varchar](5) NOT NULL,[col3] [varchar](5) NOT NULL, CONSTRAINT [PK_theTestTable] PRIMARY KEY CLUSTERED (col1 ASC)) ON [PRIMARY]";
is(doInDB({doString => $createStmt}),1,'doInDB');

# create files for tests
my $expected_filecontent = "col1\tcol2\tcol3\nval11\tval21\tval31\nval12\tval22\tval32\n";
my $expected_datastruct = [{col1 => "val11",col2 => "val21",col3 => "val31"},{col1 => "val12",col2 => "val22",col3 => "val32"}];
my $zip = Archive::Zip->new();
my $string_member = $zip->addString($expected_filecontent, 'testContent.txt' );
$string_member->desiredCompressionMethod( COMPRESSION_DEFLATED );
die 'ziptest prepare error' unless ($zip->writeToFileNamed('test.zip') == AZ_OK );


getLocalFiles($loads[0]);
my $result = checkFiles($loads[0]);
is ($result,1,"checkFiles \$loads[0] successful");
file_exists_ok("testContent.txt","checkFiles/extractArchives testContent.txt");
file_contains_like("testContent.txt",qr/$expected_filecontent/,"checkFiles/extractArchives testContent.txt expected content");
is_deeply($loads[0]{process}{filenames}, ["testContent.txt"], "checkFiles/extractArchives \$process{filenames} testContent.txt");
is_deeply($loads[0]{process}{archivefilenames}, ["test.zip"], "checkFiles/extractArchives \$process{archivefilenames} test.zip");
is_deeply($execute{retrievedFiles}, [], "checkFiles/extractArchives \$execute{retrievedFiles} empty");
readFileData($loads[0]);
is_deeply($loads[0]{process}{data},$expected_datastruct,"readFileData expected content");

dumpDataIntoDB($loads[0]);
markProcessed($loads[0]);

writeFileFromDB($loads[1]);
file_exists_ok("testTarget.txt","writeFileFromDB testTarget.txt");
file_contains_like("testTarget.txt",qr/$expected_filecontent/,"testTarget.txt expected content");

openFTPConn($loads[1]);
uploadFileToFTP($loads[1]);
getFilesFromFTP($loads[1]);
$result = checkFiles($loads[1]);
is ($result,1,"checkFiles \$loads[1] successful");
markProcessed($loads[1]);
processingEnd();

unlink "test.zip";
unlink "testContent.txt";
done_testing();