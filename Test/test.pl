use strict; use EAI::Wrap; use Data::Dumper;

%common = (
	FTP => {
		remoteDir => "",
		remoteHost => {Prod => "localhost", Test => "localhost"},
		FTPdebugLevel => 0, #~(1|2|4|8|16|1024|2048) or -1 for everything...
		remove => {removeFolders => ["",""], day=>, mon=>, year=>1},
		maxConnectionTries => 2,
		privKey => "",
		prefix => "ftp",
		dontUseQuoteSystemForPwd => 0,
		archiveDir => "",
		simulate => 0,
		dontUseTempFile => 1,
		dontMoveTempImmediately => 1,
	},
	DB => {
		database => "pubs",
	},
	task => {
		retrySecondsErr => 30,
		retrySecondsPlanned => 300,
		#plannedUntil => "2359",
		skipHolidays => 0,
		skipHolidaysDefault => "AT",
		skipWeekends => 0,
		skipForFirstBusinessDate => 0,
		ignoreNoTest => 0,
	},
);

@loads = (
	{
		DB_ => {
			primkey => "ID1 = ? AND ID2 = ?",
			tablename => "TestTableEAI",
			addID => {addID => "test123"},
		},
		File => {
			localFilesystemPath => ".",
			dontKeepHistory => 1,
			filename => "test.txt",
			format_sep => qr/\t/,
			format_skip => 2,
			format_header => "ID1	ID2	Name	Number",
			lineCode => sub {$EAI::File::line{hello}="world" if $EAI::File::line{ID1} eq "123";get_logger()->info("line:".Dumper(\%EAI::File::line));}
			#lineCode => '$line{hello}="world" if $line{ID1} eq "123";get_logger()->info("line:".Dumper(\%line));'
		},
	},
	{
		DB => {
			primkey => "ID1 = ? AND ID2 = ?",
			tablename => "TestTableEAI",
			addID => {addID => "321test"}
		},
		File => {
			localFilesystemPath => ".",
			dontKeepHistory => 1,
			filename => "test.txt",
			format_sep => qr/\t/,
			format_skip => 2,
			format_header => "ID1	ID2	Name	Number",
		}
	},
);
setupEAIWrap();
get_logger()->info("opt:".$common{process}{interactive_test});
# removeFilesinFolderOlderX(\%common);
standardLoop();