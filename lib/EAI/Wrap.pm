package EAI::Wrap 0.1;

use strict;
use Time::Local; use Time::localtime; use MIME::Lite; use Data::Dumper; use Module::Refresh; use Exporter; use File::Copy; use Cwd; use Archive::Extract;
# we make $EAI::Common::common/config/execute/loads an alias for $EAI::Wrap::common/config/execute/loads so that the user can set it without knowing anything about the Common package!
our %common;
our %config;
our %execute;
our @loads;
our @optload; our %opt;

BEGIN {
	*EAI::Common::common = \%common;
	*EAI::Common::config = \%config;
	*EAI::Common::execute = \%execute;
	*EAI::Common::loads = \@loads;
	*EAI::Common::optload = \@optload;
	*EAI::Common::opt = \%opt;
};
use EAI::Common; use EAI::DateUtil; use EAI::DB; use EAI::File; use EAI::FTP;

our @ISA = qw(Exporter);
our @EXPORT = qw(%common %config %execute @loads @optload %opt removeFilesinFolderOlderX openDBConn openFTPConn redoFiles getLocalFiles getFilesFromFTP getFiles checkFiles extractArchives getAdditionalDBData readFileData dumpDataIntoDB markProcessed writeFileFromDB putFileInLocalDir markForHistoryDelete uploadFileToFTP uploadFileCMD uploadFile processingEnd processingPause moveFilesToHistory deleteFiles
%months %monate get_curdate get_curdatetime get_curdate_dot formatDate formatDateFromYYYYMMDD get_curdate_dash get_curdate_gen get_curdate_dash_plus_X_years get_curtime get_curtime_HHMM get_lastdateYYYYMMDD get_lastdateDDMMYYYY is_first_day_of_month is_last_day_of_month get_last_day_of_month weekday is_weekend is_holiday first_week first_weekYYYYMMDD last_week last_weekYYYYMMDD convertDate convertDateFromMMM convertDateToMMM convertToDDMMYYYY addDays addDaysHol addMonths subtractDays subtractDaysHol convertcomma convertToThousendDecimal get_dateseries parseFromDDMMYYYY parseFromYYYYMMDD convertEpochToYYYYMMDD
newDBH beginWork commit rollback readFromDB readFromDBHash doInDB storeInDB deleteFromDB updateInDB
readText readExcel readXML writeText writeExcel
removeFilesOlderX fetchFiles putFile moveTempFile archiveFiles removeFiles login
readConfigFile getSensInfo setupConfigMerge getOptions setupEAIWrap extractConfigs checkHash setupLogging checkStartingCond sendGeneralMail
get_logger Dumper);

# initialize module, reading all config files and setting basic execution variables
sub INIT {
	# read site config, additional configs and sensitive config in alphabetical order (allowing precedence)
	STDOUT->autoflush(1);
	$EAI_WRAP_CONFIG_PATH = $ENV{EAI_WRAP_CONFIG_PATH};
	$EAI_WRAP_SENS_CONFIG_PATH = $ENV{EAI_WRAP_SENS_CONFIG_PATH};
	$EAI_WRAP_CONFIG_PATH =~ s/\\/\//g;
	$EAI_WRAP_SENS_CONFIG_PATH =~ s/\\/\//g;
	print STDOUT "EAI_WRAP_CONFIG_PATH: ".($EAI_WRAP_CONFIG_PATH ? $EAI_WRAP_CONFIG_PATH : "not set").", EAI_WRAP_SENS_CONFIG_PATH: ".($EAI_WRAP_SENS_CONFIG_PATH ? $EAI_WRAP_SENS_CONFIG_PATH : "not set")."\n";
	EAI::Common::readConfigFile($EAI_WRAP_CONFIG_PATH."/site.config");
	EAI::Common::readConfigFile($_) for sort glob($EAI_WRAP_CONFIG_PATH."/additional/*.config");
	EAI::Common::readConfigFile($_) for sort glob($EAI_WRAP_SENS_CONFIG_PATH."/*.config");
	
	$execute{homedir} = File::Basename::dirname(File::Spec->rel2abs((caller(0))[1])); # folder, where the main script is being executed.
	$execute{scriptname} = File::Basename::fileparse((caller(0))[1]);
	my ($homedirnode) = ($execute{homedir} =~ /^.*[\\\/](.*?)$/);
	$execute{envraw} = $config{folderEnvironmentMapping}{$homedirnode};
	if ($execute{envraw}) {
		$execute{env} = $execute{envraw};
	} else {
		# if not configured, used default mapping (usually ''=>"Prod" for productionn)
		$execute{env} = $config{folderEnvironmentMapping}{''};
	}
	if ($execute{envraw}) { # for non-production environment read separate configs, if existing
		EAI::Common::readConfigFile($EAI_WRAP_CONFIG_PATH."/".$execute{envraw}."/site.config") if -e $EAI_WRAP_CONFIG_PATH."/".$execute{envraw}."/site.config";
		EAI::Common::readConfigFile($_) for sort glob($EAI_WRAP_CONFIG_PATH."/".$execute{envraw}."/additional/*.config");
		EAI::Common::readConfigFile($_) for sort glob($EAI_WRAP_SENS_CONFIG_PATH."/".$execute{envraw}."/*.config");
	}
	EAI::Common::getOptions(); # getOptions before logging setup as centralLogHandling depends on interactive options passed
	my $return = 1;
	$return = eval $config{executeOnInit} if $config{executeOnInit};
	unless ($return) {
		die("Error parsing config{executeOnInit}: $@") if $@;
		die("Error executing config{executeOnInit}: $!") unless defined $return;
		die("Error executing config{executeOnInit}") unless $return;
	}
	EAI::Common::setupLogging();
}

# remove all files in FTP server folders that are older than a given day/month/year
sub removeFilesinFolderOlderX ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($FTP) = EAI::Common::extractConfigs($arg,"FTP");
	EAI::Common::setErrSubject("Cleaning of Archive folders");
	return EAI::FTP::removeFilesOlderX($FTP);
}

# open a DB connection
sub openDBConn ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($DB) = EAI::Common::extractConfigs($arg,"DB");
	$logger->debug("openDBConn");
	# only for set prefix, take username and password from $config{sensitive}{$DB->{prefix}}
	if ($DB->{prefix}) {
		$DB->{user} = getSensInfo($DB->{prefix},"user");
		$DB->{pwd} = getSensInfo($DB->{prefix},"pwd");
	}
	(!$DB->{user} && $DB->{DSN} =~ /\$DB->\{user\}/) and do {
		$logger->error("specified DSN ('".$DB->{DSN}."') contains \$DB->{user}, which is neither set in \$DB->{user} nor in \$config{sensitive}{".$DB->{prefix}."}{user} !");
		return 0;
	};
	EAI::DB::newDBH($DB,\%execute) or do {
		$logger->error("couldn't open database connection for ".$DB->{DSN});
		return 0; # false means error in connection and signal to die...
	};
	return 1;
}

# open a FTP connection
sub openFTPConn ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($FTP) = EAI::Common::extractConfigs($arg,"FTP");
	$logger->debug("openFTPConn");
	# only for set prefix, take username, password, hostkey and privKey from $config{sensitive}{$FTP->{prefix}} (directly or via environment hash)
	if ($FTP->{prefix}) {
		$FTP->{user} = getSensInfo($FTP->{prefix},"user");
		$FTP->{pwd} = getSensInfo($FTP->{prefix},"pwd");
		$FTP->{hostkey} = getSensInfo($FTP->{prefix},"hostkey");
		$FTP->{privKey} = getSensInfo($FTP->{prefix},"privKey");
	}
	(!$FTP->{user}) and do {
		$logger->error("ftp user neither set in \$FTP->{user} nor in \$config{sensitive}{".$FTP->{prefix}."}{user} !");
		return 0;
	};
	EAI::FTP::login($FTP,\%execute) or do {
		$logger->error("couldn't open ftp connection for ".$FTP->{remoteHost}{$execute{env}});
		return 0; # false means error in connection and signal to die...
	};
	return 1; 
}

# redo file from redo directory if specified (used in getLocalFile and getFileFromFTP)
sub redoFiles ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($File) = EAI::Common::extractConfigs($arg,"File");
	return unless $common{task}{redoFile};
	$logger->debug("redoFiles");
	my $redoDir = $execute{redoDir};
	EAI::Common::setErrSubject("setting/renaming redo files");
	# file extension for local redo 
	my ($barename,$ext) = $File->{filename} =~ /(.*)\.(.*?)$/; # get file bare name and extension from filename
	if (!$ext) {
		$ext = $File->{extension}; # if no dots in filename (e.g. because of glob) -> no file extension retrievable -> take from here
	}
	if (!$ext) {
		$logger->error("redoFile set, no file extension for renaming redo files! should be either retrievable in filename as .<ext> or be set separately in File=>extension");
		return 0;
	}
	$logger->info("redoFile set, redoing files in ".$redoDir.", looking for files with extension ".$ext);
	if ($File->{filename} =~ /\*/) {
		$barename = $File->{filename}; 
		$barename =~ s/\*.*$//g; # remove glob pattern and quote dots to allow matching with redo file
	}
	if (chdir($redoDir)) {
		for my $redofile (glob("*.$ext")) {
			$logger->debug("found file $redofile in $redoDir");
			if ($redofile =~ /$barename.*/) {
				$logger->info("file $redofile available for redo, matched $barename.*");
				# only rename if not prohibited and not a glob, else just push into retrievedFiles
				if (!$File->{avoidRenameForRedo} and $File->{filename} !~ /\*/) {
					rename $redofile, "$barename.$ext" or $logger->error("error renaming file $redofile to $barename.$ext : $!");
					push @{$execute{retrievedFiles}}, "$barename.$ext";
				} else {
					push @{$execute{retrievedFiles}}, $redofile;
				}
			}
		}
	} else {
		$logger->error("couldn't change into redo folder ".$redoDir." !");
		return 0;
	}
	chdir($execute{homedir});
	return 1;
}

# get local file(s) from source into homedir and extract archives if needed
sub getLocalFiles ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($File,$process) = EAI::Common::extractConfigs($arg,"File","process");
	$logger->debug("getLocalFiles");
	EAI::Common::setErrSubject("Getting local files");
	return if $execute{retryBecauseOfError} and !$process->{hadErrors};
	if ($File->{localFilesystemPath}) {
		my $localFilesystemPath = $File->{localFilesystemPath};
		$localFilesystemPath.="/" if $localFilesystemPath !~ /^.*\/$/;
		if ($common{task}{redoFile}) {
			return redoFiles($arg);
		} else {
			my @multipleFiles;
			if ($File->{filename} =~ /\*/) { # if there is a glob character then copy multiple files !
				if (chdir($localFilesystemPath)) {
					@multipleFiles = glob($File->{filename});
					chdir($execute{homedir});
				} else {
					$logger->error("couldn't change into folder ".$localFilesystemPath." !");
					return 0;
				}
			} else {
				# no glob char -> single file
				push @multipleFiles, $File->{filename};
			}
			push @{$execute{retrievedFiles}}, @multipleFiles;
			for my $localfile (@multipleFiles) {
				unless ($File->{localFilesystemPath} eq ".") {
					$logger->info("copying local file: ".$localFilesystemPath.$localfile." to ".$execute{homedir});
					copy ($localFilesystemPath.$localfile, ".") or do {
						$logger->error("couldn't copy ".$localFilesystemPath.$localfile.": $!");
						@{$execute{retrievedFiles}} = ();
						return 0;
					};
				} else {
					$logger->info("taking local file: ".$localfile." from current folder (".$execute{homedir}.")");
				}
			}
		}
	} else {
		$logger->error("no \$File->{localFilesystemPath} parameter given");
		return 0;
	}
	return 1;
}

# get file/s (can also be a glob for multiple files) from FTP into homedir and extract archives if needed
sub getFilesFromFTP ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($FTP,$File,$process) = EAI::Common::extractConfigs($arg,"FTP","File","process");
	$logger->debug("getFilesFromFTP");
	EAI::Common::setErrSubject("Getting files from ftp");
	return if $execute{retryBecauseOfError} and !$process->{hadErrors};
	@{$execute{retrievedFiles}} = (); # reset last retrieved, but this is also necessary to create the retrievedFiles hash entry for passing back the list from getFiles
	if (defined($FTP->{remoteDir})) {
		if ($common{task}{redoFile}) {
			return redoFiles($arg);
		} else {
			if ($File->{filename}) {
				if (!EAI::FTP::fetchFiles ($FTP,\%execute,{fileToRetrieve=>$File->{filename},fileToRetrieveOptional=>$File->{optional}})) {
					$logger->error("error in fetching file from FTP") if !$execute{retryBecauseOfError};
					return 0;
				}
			} else {
				$logger->error("no \$File->{filename} given, can't get it from FTP");
				return 0;
			}
		}
	} else {
		$logger->error("no \$FTP->{remoteDir} parameter defined");
		return 0;
	}
	return 1;
}

# general procedure to get files from FTP or locally
sub getFiles ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($FTP,$File,$process) = EAI::Common::extractConfigs($arg,"FTP","File","process");
	$logger->debug("getFiles");
	return if $execute{retryBecauseOfError} and !$process->{hadErrors};
	if ($File->{localFilesystemPath}) {
		return getLocalFiles($arg);
	} else {
		return getFilesFromFTP($arg);
	}
}

# check files for continuation of processing
sub checkFiles ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($File,$process) = EAI::Common::extractConfigs($arg,"File","process");
	$logger->debug("checkFiles");
	return 1 if $execute{retryBecauseOfError} and !$process->{hadErrors};
	my $redoDir = $execute{redoDir}."/" if $common{task}{redoFile};
	my $fileDoesntExist;
	if ($execute{retrievedFiles} and @{$execute{retrievedFiles}} >= 1) {
		for my $singleFilename (@{$execute{retrievedFiles}}) {
			$logger->debug("checking file: ".$redoDir.$singleFilename);
			open (CHECKFILE, "<".$redoDir.$singleFilename) or $fileDoesntExist=1;
			close CHECKFILE;
		}
	} else {
		$fileDoesntExist=1;
	}
	if ($fileDoesntExist) {
		# exceptions from error message and return false for not continuing with readFile/whatever
		if ($File->{optional} || ($execute{firstRunSuccess} && $common{task}{plannedUntil}) || $common{task}{redoFile}) {
			if ($execute{firstRunSuccess} && $common{task}{plannedUntil}) {
				$logger->warn("file ".$File->{filename}." missing with planned execution until ".$common{task}{plannedUntil}." and first run successful, skipping");
			} elsif ($File->{optional}) {
				$logger->warn("file ".$File->{filename}." missing being marked as optional, skipping");
			} elsif ($common{task}{redoFile}) {
				$logger->warn("file ".$File->{filename}." missing being retried, skipping");
			}
		} else {
			if (!$execute{retrievedFiles} or @{$execute{retrievedFiles}} == 0) {
				$logger->error("file ".$File->{filename}." was not retrieved (maybe no successful call done to getFilesFromFTP or getLocalFiles ?)");
			} else {
				$logger->error("file ".$File->{filename}." doesn't exist and is not marked as optional!");
			}
			$process->{hadErrors} = 1;
		}
		$logger->debug("checking file failed");
		return 0;
	}
	# extract from files if needed
	if ($File->{extract}) {
		if (@{$execute{retrievedFiles}} == 1) {
			$logger->info("file checked, extracting archives");
			return extractArchives($arg);
		} else {
			$logger->error("multiple files returned (glob passed as filename), extracting not supported in this case");
			return 0;
		}
	}
	# add the files retrieved
	push @{$process->{filenames}}, @{$execute{retrievedFiles}} if ($execute{retrievedFiles} && @{$execute{retrievedFiles}} > 0);
	$logger->info("files checked: @{$process->{filenames}}") if $process->{filenames};
	return 1;
}

# extract files from archive
sub extractArchives ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($process) = EAI::Common::extractConfigs($arg,"process");
	$logger->debug("extractArchives");
	return 1 if $execute{retryBecauseOfError} and !$process->{hadErrors};
	my $redoDir = $execute{redoDir}."/" if $common{task}{redoFile};
	if ($execute{retrievedFiles}) { 
		for my $filename (@{$execute{retrievedFiles}}) {
			if (! -e $redoDir.$filename) {
				$logger->error($redoDir.$filename." doesn't exist for extraction");
				next;
			}
			$logger->info("extracting file(s) from archive package: $redoDir$filename");
			local $SIG{__WARN__} = sub { $logger->error("opening archive: ".$_[0]); };
			my $ae;
			eval {
				$ae = Archive::Extract->new(archive => $redoDir.$filename);
			};
			return 0 unless $ae;
			if (!$ae->extract(to => ($redoDir ? $redoDir : "."))) {
				$logger->error("extracting files: ".$ae->error()); 
				return 0;
			}
			$logger->info("extracted files: @{$ae->files}");
			push @{$process->{filenames}}, @{$ae->files};
			push @{$process->{archivefilenames}}, $filename; # archive itself needs to be removed/historized
		}
		# reset retrievedFiles to get rid of fetched archives (not to be processed further)
		@{$execute{retrievedFiles}} = ();
	} else {
		$logger->error("no files available to extract..");
		return 0;
	}
	return 1;
}

# get additional data from DB
sub getAdditionalDBData ($;$) {
	my ($arg,$refToDataHash) = @_;
	my $logger = get_logger();
	my ($DB,$process) = EAI::Common::extractConfigs($arg,"DB","process");
	$logger->debug("getAdditionalDBData");
	EAI::Common::setErrSubject("Getting additional data from DB");
	return 1 if $execute{retryBecauseOfError} and !$process->{hadErrors};
	# reset additionalLookupData to avoid strange errors in retrying run. Also needed to pass data back as reference
	%{$process->{additionalLookupData}} = ();
	if ($refToDataHash and ref($refToDataHash) ne "HASH") {
		$logger->error("passed second argument \$refToDataHash is not a ref to a hash");
		return 0;
	}
	# additional lookup needed (e.g. used in addtlProcessing), if optional $refToDataHash given pass data into that?
	return EAI::DB::readFromDBHash({query => $DB->{additionalLookup}, keyfields=> $DB->{additionalLookupKeys}}, ($refToDataHash ? \%{$refToDataHash} : \%{$process->{additionalLookupData}}) ) if ($DB->{additionalLookup});
}

# read data from file
sub readFileData ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($File,$process) = EAI::Common::extractConfigs($arg,"File","process");
	my $redoDir = $execute{redoDir}."/" if $common{task}{redoFile};
	$logger->debug("readFileData");
	return 1 if $execute{retryBecauseOfError} and !$process->{hadErrors};
	my $readSuccess;
	if ($File->{format_xlformat}) {
		$readSuccess = EAI::File::readExcel($File, $process, $process->{filenames}, $redoDir);
	} elsif ($File->{format_XML}) {
		$readSuccess = EAI::File::readXML($File, $process, $process->{filenames}, $redoDir);
	} else {
		$readSuccess = EAI::File::readText($File, $process, $process->{filenames}, $redoDir);
	}
	# error when reading files with readFile/readExcel/readXML
	if (!$readSuccess) {
		my @filesdone = @{$process->{filenames}} if $process->{filenames};
		$logger->error("error reading one of file(s) @filesdone") if (!$File->{optional});
		$logger->warn("error reading one of file(s) @filesdone, but ignored as \$File{emptyOK} = 1!") if ($File->{emptyOK});
	}
	return $readSuccess;
}

# store data into Database
sub dumpDataIntoDB ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($DB,$File,$process) = EAI::Common::extractConfigs($arg,"DB","File","process");
	$logger->debug("dumpDataIntoDB");
	return 1 if $execute{retryBecauseOfError} and !$process->{hadErrors};
	our $hadDBErrors = 0;
	if ($process->{data}) { # data supplied?
		if ($DB->{noDumpIntoDB}) {
			$logger->info("skip dumping of ".$File->{filename}." into DB");
		} else {
			my $table = $DB->{tablename};
			# Transaction begin
			unless ($DB->{noDBTransaction}) {
				EAI::DB::beginWork() or do {
					$logger->error ("couldn't start DB transaction");
					$hadDBErrors=1;
				};
			}
			# store data, tables are deleted if explicitly marked
			if ($DB->{dontKeepContent}) {
				$logger->info("removing all data from Table $table ...");
				EAI::DB::doInDB({doString => "delete from $table"});
			}
			$logger->info("dumping data to table $table");
			if (! EAI::DB::storeInDB($DB, $process->{data})) {
				$logger->error("error storing DB data.. ");
				$hadDBErrors=1;
			}
			# post processing (Perl code) for config, where postDumpProcessing is defined
			if ($DB->{postDumpProcessing}) {
				$logger->info("starting postDumpProcessing");
				$logger->debug($DB->{postDumpProcessing});
				eval $DB->{postDumpProcessing};
				if ($@) {
					$logger->error("error in eval postDumpProcessing: ".$DB->{postDumpProcessing}.": $@");
					$hadDBErrors = 1;
				}
			}
			# post processing (execute in DB!) for all configs, where postDumpExecs conditions and referred execs (DB scripts, that should be executed) are defined
			if (!$hadDBErrors && $DB->{postDumpExecs}) {
				$logger->info("starting postDumpExecs ... ");
				for my $postDumpExec (@{$DB->{postDumpExecs}}) {
					$logger->info("checking postDumpExec condition: ".$postDumpExec->{condition});
					my $dopostdumpexec = eval $postDumpExec->{condition};
					if ($@) {
						$logger->error("error parsing postDumpExec condition: ".$postDumpExec->{condition}.": $@");
						$hadDBErrors = 1;
						last;
					}
					if ($dopostdumpexec) {
						for my $exec (@{$postDumpExec->{execs}}) {
							if ($exec) { # only if defined (there could be an interpolation of perl variables, if these are contained in $exec. This is for setting $selectedDate in postDumpProcessing.
								# eval qq{"$exec"} doesn't evaluate $exec but the quoted string (to enforce interpolation where needed)
								$exec = eval qq{"$exec"} if $exec =~ /$/; # only interpolate if perl scalars are contained
								$logger->info("post execute: $exec");
								if (!EAI::DB::doInDB({doString => $exec})) {
									$logger->error("error executing postDumpExec: '".$exec."' .. ");
									$hadDBErrors=1;
									last;
								}
							}
						}
					}
				}
				$logger->info("postDumpExecs finished");
			}
			if (!$hadDBErrors) {
				# Transaction: commit of DB changes
				unless ($DB->{noDBTransaction}) {
					$logger->debug("committing data");
					if (EAI::DB::commit()) {
						$logger->info("data stored into table $table successfully");
					} else {
						$logger->error("error when committing");
						$process->{hadErrors} = 1;
					};
				}
			} else { # error dumping to DB or during pre/postDumpExecs
				unless ($DB->{noDBTransaction}) {
					$logger->info("Rollback because of error when storing into database");
					EAI::DB::rollback() or $logger->error("error with rollback ...");
				}
				$logger->error("error storing data into database");
				$process->{hadErrors} = 1;
			}
		}
	} else {# if ($process->{data}) .. in case there is no data and an empty file is OK no error will be thrown in readFile/readExcel, but any Import should not be done...
		if ($File->{emptyOK}) {
			$logger->warn("received empty file, will be ignored as \$File{emptyOK}=1");
		} else {
			my @filesdone = @{$process->{filenames}} if $process->{filenames};
			$logger->error("error as none of the following files didn't contain data: @filesdone !");
			$process->{hadErrors} = 1;
		}
	}
}

# mark files as being processed depending on whether there were errors, also decide on removal/archiving of downloaded files
sub markProcessed ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($File,$process) = EAI::Common::extractConfigs($arg,"File","process");
	$logger->debug("markProcessed");
	# this is important for the archival/deletion on the FTP Server!
	if ($File->{emptyOK} || !$process->{hadErrors}) {
		for (@{$process->{filenames}}) {
			$process->{filesProcessed}{$_} = 1;
			$logger->info("filesProcessed: $_");
		}
	} else {
		$process->{hadErrors} = 1;
	}
	# mark to be removed or be moved to history
	if ($File->{dontKeepHistory}) {
		push @{$execute{filesToDelete}}, @{$process->{filenames}};
		push @{$execute{filesToDelete}}, @{$process->{archivefilenames}} if $process->{archivefilenames};
	} else {
		push @{$execute{filesToMoveinHistory}}, @{$process->{filenames}};
		push @{$execute{filesToMoveinHistory}}, @{$process->{archivefilenames}} if $process->{archivefilenames};
	}
}

# create Data-files from Database
sub writeFileFromDB ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($DB,$File,$process) = EAI::Common::extractConfigs($arg,"DB","File","process");
	$logger->debug("writeFileFromDB");
	return 1 if $execute{retryBecauseOfError} and !$process->{hadErrors};
	EAI::Common::setErrSubject("creating/writing file from DB");
	my @columnnames;
	# get data from database, including column names (passed by ref)
	@{$DB->{columnnames}} = (); # reset columnnames to pass data back as reference
	@{$process->{data}} = (); # reset data to pass data back as reference
	EAI::DB::readFromDB($DB, \@{$process->{data}}) or do {
		$logger->error("couldn' read from DB");
		return 0;
	};
	# pass column information from database, if not explicitly set
	$File->{columns} = $DB->{columnnames} if !$File->{columns};
	$logger->warn("no data retrieved") if ($process->{data} and @{$process->{data}} == 0);
	# prepare for all configs, where postReadProcessing is defined
	if ($DB->{postReadProcessing}) {
		eval $DB->{postReadProcessing};
		$logger->error("error doing postReadProcessing: ".$DB->{postReadProcessing}.": ".$@) if ($@);
	}
	EAI::File::writeText($File,$process) or do {
		$logger->error("error creating/writing file");
		return 0;
	};
	return 1;
}

# put files into local folder if required
sub putFileInLocalDir ($) {
	my $arg = shift;
	my $logger = get_logger();
	$logger->debug("putFileInLocalDir");
	my ($File,$process) = EAI::Common::extractConfigs($arg,"File","process");
	return 1 if $execute{retryBecauseOfError} and !$process->{hadErrors};
	if ($File->{localFilesystemPath} and $File->{localFilesystemPath} ne '.') {
		$logger->info("moving file '".$File->{filename}."' into local dir ".$File->{localFilesystemPath});
		move($File->{filename}, $File->{localFilesystemPath}."/".$File->{filename}) or do {
			$logger->error("couldn't move ".$File->{filename}." into ".$File->{localFilesystemPath}.": ".$!);
			$process->{hadErrors} = 1;
			return 0;
		};
	} else {
		if ($File->{localFilesystemPath} eq '.') {
			$logger->info("\$File->{localFilesystemPath} is '.', didn't move files");
		} else {
			$logger->error("no \$File->{localFilesystemPath} defined, therefore no files processed with uploadFileCMD");
			return 0;
		}
	}
	return 1;
}

# mark to be removed or be moved to history after upload
sub markForHistoryDelete ($) {
	my $arg = shift;
	my $logger = get_logger();
	$logger->debug("markForHistoryDelete");
	my ($File) = EAI::Common::extractConfigs($arg,"File");
	if ($File->{dontKeepHistory}) {
		push @{$execute{filesToDelete}}, $File->{filename};
	} elsif (!$File->{dontMoveIntoHistory}) {
		push @{$execute{filesToMoveinHistoryUpload}}, $File->{filename};
	}
}

# upload files to FTP
sub uploadFileToFTP ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($FTP,$File,$process) = EAI::Common::extractConfigs($arg,"FTP","File","process");
	return 1 if $execute{retryBecauseOfError} and !$process->{hadErrors};
	markForHistoryDelete($arg) unless ($FTP->{localDir});
	if (defined($FTP->{remoteDir})) {
		$logger->debug ("upload of file '".$File->{filename}."' using FTP");
		EAI::Common::setErrSubject("Upload of file to FTP remoteDir ".$FTP->{remoteDir});
		if (!EAI::FTP::putFile ($FTP,{fileToWrite => $File->{filename}})) {
			$process->{hadErrors} = 1;
			return 0;
		}
	} else {
		$logger->warn("no \$FTP->{remoteDir} defined, therefore no files processed with uploadFileToFTP");
	}
	return 1;
}

# upload files using an upload command program
sub uploadFileCMD ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($FTP,$File,$process) = EAI::Common::extractConfigs($arg,"FTP","File","process");
	return 1 if $execute{retryBecauseOfError} and !$process->{hadErrors};
	markForHistoryDelete($arg) unless ($FTP->{localDir});
	if ($process->{uploadCMD}) {
		$logger->debug ("upload of file '".$File->{filename}."' using uploadCMD ".$process->{uploadCMD});
		EAI::Common::setErrSubject("Uploading of file with ".$process->{uploadCMD});
		system $process->{uploadCMD};
		my $errHappened;
		if ($? == -1) {
			$logger->error($process->{uploadCMD}." failed: $!");
			$errHappened = 1;
		} elsif ($? & 127) {
			$logger->error($process->{uploadCMD}." unexpected finished returning ".($? & 127).", ".(($? & 128) ? 'with' : 'without')." coredump");
			$errHappened = 1;
		} elsif ($? != 0) {
			$logger->error($process->{uploadCMD}." finished returning ".($? >> 8).", err: $!");
			$errHappened = 1;
		} else {
			$logger->info("finished upload using ".$process->{uploadCMD});
		}
		# remove produced files
		unlink ($process->{uploadCMDPath}."/".$File->{filename}) or $logger->error("couldn't remove $File->{filename} in ".$process->{uploadCMDPath}.": ".$!);
		# take error log from uploadCMD
		if (-e $process->{uploadCMDLogfile} && $errHappened) {
			my $err = do {
				local $/ = undef;
				open (FHERR, "<".$process->{uploadCMDLogfile}) or $logger->error("couldn't read uploadCMD log file ".$process->{uploadCMDLogfile}.":".$!);
				<FHERR>;
			};
			$logger->error($process->{uploadCMD}." returned following: $err");
			$process->{hadErrors} = 1;
			return 0;
		}
	} else {
		$logger->error("no \$process->{uploadCMD} defined, therefore no files processed with uploadFileCMD");
		return 0;
	}
	return 1;
}

# general procedure to upload files via FTP or CMD or to put into local dir
sub uploadFile ($) {
	my $arg = shift;
	my $logger = get_logger();
	my ($File,$process) = EAI::Common::extractConfigs($arg,"File","process");
	$logger->debug("uploadFile");
	return 1 if $execute{retryBecauseOfError} and !$process->{hadErrors};
	if ($File->{localFilesystemPath}) {
		return putFileInLocalDir($arg);
	} elsif ($process->{uploadCMD}) {
		return uploadFileCMD($arg);
	} else {
		return uploadFileToFTP($arg);
	}
}

# final processing steps for processEnd (cleanup, FTP removal/archiving) or retry after pausing. No context argument as it always depends on all loads/common
sub processingEnd {
	my $logger = get_logger();
	$logger->debug("processingEnd");
	my $processFailed = $common{process}{hadErrors} if ($common{process}{filenames} and !@loads);
	$processFailed = ($processFailed ? $_->{process}{hadErrors} : 0) for @loads;
	$execute{processEnd} = ($processFailed ? 0 : 1);
	if ($execute{processEnd}) {
		# archiving/removing on the FTP server only if not a local redo
		if (!$common{task}{redoFile}) {
			EAI::Common::setErrSubject("FTP archiving/removal");
			if ($common{process}{filenames} and !@loads) { # only take common part if no loads were defined.
				my (@filesToRemove,@filesToArchive);
				for (@{$common{process}{filenames}}) {
					# "onlyArchive" files are not processed and there is no need to check whether they were processed,
					# else only pass the actual processed files for archiving/removal
					push @filesToRemove, $_ if $common{FTP}{fileToRemove} and ($common{process}{filesProcessed}{$_} or $common{FTP}{onlyArchive});
					push @filesToArchive, $_ if $common{FTP}{fileToArchive} and ($common{process}{filesProcessed}{$_} or $common{FTP}{onlyArchive});
				}
				if (@filesToArchive or @filesToRemove) {
					openFTPConn(\%common);
					$logger->info("file cleanup: ".(@filesToArchive ? "archiving @filesToArchive" : "").(@filesToRemove ? "removing @filesToRemove" : "")." on FTP Server...");
					EAI::FTP::archiveFiles ({filesToArchive => \@filesToArchive, archiveDir => $common{FTP}{archiveDir}, remoteDir => $common{FTP}{remoteDir}, timestamp => $common{task}{customHistoryTimestamp}}) if @filesToArchive;
					EAI::FTP::removeFiles ({filesToRemove => \@filesToRemove, remoteDir => $common{FTP}{remoteDir}}) if @filesToRemove;
				}
			}
			for my $load (@loads) {
				if ($load->{process}{filenames}) {
					my (@filesToRemove,@filesToArchive);
					for (@{$load->{process}{filenames}}) {
						push @filesToRemove, $_ if $load->{FTP}{fileToRemove} and ($load->{process}{filesProcessed}{$_} or $load->{FTP}{onlyArchive});
						push @filesToArchive, $_ if $load->{FTP}{fileToArchive} and ($load->{process}{filesProcessed}{$_} or $load->{FTP}{onlyArchive});
					}
					if (@filesToArchive or @filesToRemove) {
						openFTPConn($load);
						$logger->info("file cleanup: ".(@filesToArchive ? "archiving @filesToArchive" : "").(@filesToRemove ? "removing @filesToRemove" : "")." on FTP Server...");
						EAI::FTP::archiveFiles ({filesToArchive => \@filesToArchive, archiveDir => $load->{FTP}{archiveDir}, remoteDir => $load->{FTP}{remoteDir}, timestamp => $common{task}{customHistoryTimestamp}}) if @filesToArchive;
						EAI::FTP::removeFiles ({filesToRemove => \@filesToRemove, remoteDir => $load->{FTP}{remoteDir}}) if @filesToRemove;
					}
				}
			}
		}

		# clean up locally
		EAI::Common::setErrSubject("local archiving/removal");
		moveFilesToHistory($common{task}{customHistoryTimestamp});
		deleteFiles($execute{filesToDelete}) if $execute{filesToDelete};
		if ($common{task}{plannedUntil}) {
			$execute{processEnd} = 0; # reset, if repetition is planned
			$execute{retrySeconds} = $common{task}{retrySecondsPlanned};
		}
		if ($execute{retryBecauseOfError}) {
			my @filesProcessed = keys %{$execute{filesProcessed}};
			# send success mail, if successful after first failure
			EAI::Common::sendGeneralMail("", $config{errmailaddress},"","","Successful retry of $execute{scriptname} $common{task}{typeconf} $common{task}{subtypeconf} !","@filesProcessed succesfully done on retry");
		}
		$execute{firstRunSuccess} = 1 if $common{task}{plannedUntil}; # for planned retries (plannedUntil) -> no more error messages (files might be gone)
		$execute{retryBecauseOfError} = 0;
	} else {
		if ($common{task}{plannedUntil} && $execute{firstRunSuccess}) {
			$execute{retrySeconds} = $common{task}{retrySecondsPlanned};
		} else {
			$execute{retrySeconds} = $common{task}{retrySecondsErr};
			$execute{retryBecauseOfError} = 1;
			$execute{failcount}++;
		}
	}
	unless ($execute{processEnd}) {
		# refresh modules and logging config for changes
		EAI::Common::refresh();
		# pausing processing/retry
		my $retrySeconds = $execute{retrySeconds};
		$retrySeconds = $common{task}{retrySecondsErr} if !$retrySeconds;
		$retrySeconds = 60 if !$retrySeconds; # sanity fallback if retrySecondsErr not set
		my $failcountFinish;
		if ($execute{failcount} > $common{task}{retrySecondsXfails}) {
			$logger->info("fail count reached $common{task}{retrySecondsXfails}, so now retrySeconds are switched to $common{task}{retrySecondsErrAfterXfails}") if $common{task}{retrySecondsErrAfterXfails};
			$failcountFinish = 1 if !$common{task}{retrySecondsErrAfterXfails};
			$retrySeconds = $common{task}{retrySecondsErrAfterXfails};
		}
		my $nextStartTime = calcNextStartTime($retrySeconds);
		my $currentTime = EAI::DateUtil::get_curtime_HHMM();
		my $endTime = $common{task}{plannedUntil};
		$endTime = "2400" if !$endTime and $processFailed;
		$endTime = "0000->not set" if !$endTime; # if neither planned nor process failed then endtime is undefined and needs to be lower than any currentTime for next decision
		if ($failcountFinish or $currentTime >= $endTime or ($nextStartTime =~ /24../)) {
			$logger->info("finished processing due ".($failcountFinish ? "to reaching set error count \$common{task}{retrySecondsXfails} $common{task}{retrySecondsXfails} and \$common{task}{retrySecondsErrAfterXfails} is false" : "to time out: current time(".$currentTime.") >= endTime(".$endTime.") or nextStartTime(".$nextStartTime.") =~ /24../!"));
			moveFilesToHistory($common{task}{customHistoryTimestamp});
			deleteFiles($execute{filesToDelete}) if $execute{filesToDelete};
			$execute{processEnd}=1;
		} else {
			$logger->debug("execute:\n".Dumper(\%execute));
			$logger->info("Retrying in ".$retrySeconds." seconds because of ".($execute{retryBecauseOfError} ? "occurred error" : "planned retry")." until ".$endTime.", next run: ".$nextStartTime);
			sleep $retrySeconds;
		}
	}
}

# helps to calculate next start time
sub calcNextStartTime ($) {
	my $seconds = shift;
	my $hrs = substr(EAI::DateUtil::get_curtime_HHMM(),0,2);
	my $min = substr(EAI::DateUtil::get_curtime_HHMM(),2,2);
	# Add time (60 module): 
	# hour part: including carry of minutes after adding additional minutes ($seconds/60); * 100 for shifting 2 digits left
	# minute part: integer rest from 60 of (original + additional)
	return sprintf("%04d",($hrs + int(($min+($seconds/60))/60))*100 + (($min + ($seconds/60))%60));
}

# generally available procedure for pausing processing
sub processingPause ($) {
	my $pauseSeconds = shift;
	my $logger = get_logger();
	$logger->debug("pause");
	$logger->info("pausing ".$pauseSeconds." seconds, resume processing: ".calcNextStartTime($pauseSeconds));
	sleep $pauseSeconds;
}

# moving files into history folder
sub moveFilesToHistory (;$) {
	my ($archiveTimestamp) = @_;
	my $logger = get_logger();
	$archiveTimestamp = EAI::DateUtil::get_curdatetime() if !$archiveTimestamp;
	my $redoDir = $execute{redoDir}."/" if $common{task}{redoFile};
	EAI::Common::setErrSubject("local archiving");
	for my $histFolder ("historyFolder", "historyFolderUpload") {
		my @filenames = @{$execute{filesToMoveinHistory}} if $execute{filesToMoveinHistory};
		@filenames = @{$execute{filesToMoveinHistoryUpload}} if $histFolder eq "historyFolderUpload" and $execute{filesToMoveinHistoryUpload};
		for (@filenames) {
			my ($strippedName, $ext) = /(.+)\.(.+?)$/;
			# if done from a redoDir, then add this folder to file (e.g. if done from redo/user specific folder then Filename_20190219_124409.txt becomes Filename_20190219_124409_redo_userspecificfolder_.txt)
			my $cutOffSpec = $archiveTimestamp;
			if ($redoDir) {
				my $redoSpec = $redoDir;
				$redoSpec =~ s/\//_/g;
				$cutOffSpec = $archiveTimestamp.'_'.$redoSpec;
			}
			if (!$execute{alreadyMovedOrDeleted}{$_}) {
				my $histTarget = $execute{$histFolder}."/".$strippedName."_".$cutOffSpec.".".$ext;
				$logger->info("moving file $redoDir$_ into $histTarget");
				rename $redoDir.$_, $histTarget or $logger->error("error when moving file $redoDir$_ into $histTarget: $!");
				$execute{alreadyMovedOrDeleted}{$_} = 1;
			}
		}
	}
}

# removing files
sub deleteFiles ($) {
	my ($filenames) = @_;
	my $logger = get_logger();
	my $redoDir = $execute{redoDir}."/" if $common{task}{redoFile};
	EAI::Common::setErrSubject("local cleanup"); #
	for (@$filenames) {
		if (!$execute{alreadyMovedOrDeleted}{$_}) {
			$logger->info("removing ".($common{task}{redoFile} ? "repeated loaded " : "")."file $redoDir$_ ");
			unlink $redoDir.$_ or $logger->error("error when removing file $redoDir".$_." : $!");
			$execute{alreadyMovedOrDeleted}{$_} = 1;
		}
	}
}
1;
__END__

=head1 NAME

EAI::Wrap - framework for easy creation of Enterprise Application Integration tasks

=head1 SYNOPSIS

    # site.config
    %config = (
    	sensitive => {
    		myftp => {user => 'someone', pwd => 'password', privKey => 'pathToPrivateKey', hostkey => 'hostkey to be presented'},
    		mydb => {user => 'someone', pwd => 'password'}
    	},
    	checkLookup => {"task_script.pl" => {errmailaddress => "test\@test.com", errmailsubject => "testjob failed", timeToCheck => "0800", freqToCheck => "B", logFileToCheck => "test.log", logcheck => "started.*"}},
    	folderEnvironmentMapping => {Test => "Test", Dev => "Dev", "" => "Prod"},
    	errmailaddress => 'To@somewhere.com',
    	errmailsubject => "errMailSubject",
    	fromaddress => 'from@somewhere.com',
    	smtpServer => "MailServer",
    	smtpTimeout => 60,
    	logRootPath => "C:/dev/EAI/Logs",
    	historyFolder => "History",
    	redoDir => "redo",
    	task => {
    		retrySecondsErr => 60*5,
    		retrySecondsPlanned => 60*15,
    	},
    	DB => {
    		server => {Prod => "ProdServer", Test => "TestServer"},
    		cutoffYr2000 => 60,
    		DSN => 'driver={SQL Server};Server=$DB->{server}{$execute->{env}};database=$DB->{database};TrustedConnection=Yes;',
    		schemaName => "dbo",
    	},
    	FTP => {
    		maxConnectionTries => 5, 
    		plinkInstallationPath => "C:/dev/EAI/putty/PLINK.EXE",
    	},
    	File => {
    		format_thousandsep => ",",
    		format_decimalsep => ".",
    	}
    );

    # task_script.pl
    use EAI::Wrap;
    %common = (
    	FTP => {
    		remoteHost => {"Prod" => "ftp.com", "Test" => "ftp-test.com"},
    		remoteDir => "/reports",
    		port => 22,
    		user => "myuser",
    		privKey => 'C:/keystore/my_private_key.ppk',
    		FTPdebugLevel => 0, # ~(1|2|4|8|16|1024|2048)
    	},
    	DB => {
    		tablename => "ValueTable",
    		deleteBeforeInsertSelector => "rptDate = ?",
    		dontWarnOnNotExistingFields => 1,
    		database => "DWH",
    	},
    	task => {
    		plannedUntil => "2359",
    	},
    );
    @loads = (
    	{
    		File => {
    			filename => "Datafile1.XML",
    			format_XML => 1,
    			format_sep => ',',
    			format_xpathRecordLevel => '//reportGrp/CM1/*',
    			format_fieldXpath => {rptDate => '//rptHdr/rptDat', NotionalVal => 'NotionalVal', tradeRef => 'tradeRefId', UTI => 'UTI'}, 
    			format_header => "rptDate,NotionalVal,tradeRef,UTI",
    		},
    	},
    	{
    		File => {
    			filename => "Datafile2.txt",
    			format_sep => "\t",
    			format_skip => 1,
    			format_header => "rptDate	NotionalVal	tradeRef	UTI",
    		},
    	}
    );
    setupEAIWrap();
    openDBConn(\%common) or die;
    openFTPConn(\%common) or die;
    while (!$execute{processEnd}) {
    	for my $load (@loads) {
    		getFilesFromFTP($load);
    		if (checkFiles($load)) {
    			readFileData($load);
    			dumpDataIntoDB($load);
    			markProcessed($load);
    		}
    	}
    	processingEnd();
    }

=head1 DESCRIPTION

EAI::Wrap provides a framework for defining EAI jobs directly in Perl, sparing the creator of low-level tasks as FTP-Fetching, file-parsing and storing into a database.
It also can be used to handle other workflows, like creating files from the database and uploading to FTP-Servers or using other externally provided tools.

The definition is done by first setting up configuration hashes and then providing a high-level scripting of the job itself using the provided API (although any perl code is welcome here!).

EAI::Wrap has a lot of infrastructure already included, like logging using Log4perl, database handling with L<DBI> and L<DBD::ODBC>, FTP services using L<Net::SFTP::Foreign>, file parsing using L<Text::CSV> (text files), L<Data::XLSX::Parser> and L<Spreadsheet::ParseExcel> (excel files), L<XML::LibXML> (xml files), file writing with L<Spreadsheet::WriteExcel> and L<Excel::Writer::XLSX> (excel files), L<Text::CSV> (text files).

Furthermore it provides very flexible commandline options, allowing almost all configurations to be set on the commandline.
Commandline options (e.g. additional information passed on with the interactive option) of the task script are fetched at INIT allowing use of options within the configuration, e.g. $opt{process}{interactive_startdate} for a passed start date.

Also the logging configured in C<$ENV{EAI_WRAP_CONFIG_PATH}/log.config> (logfile root path set in C<$ENV{EAI_WRAP_CONFIG_PATH}/site.config>) starts immediately at INIT of the task script, to use a logger, simply make a call to get_logger(). For the logging configuration, see L<EAI::Common>, setupLogging.


=head2 API

=over 4

=item %config 

global config (set in C<$ENV{EAI_WRAP_CONFIG_PATH}/site.config>, amended with C<$ENV{EAI_WRAP_CONFIG_PATH}/additional/*.config>), contains special parameters (default error mail sending, logging paths, etc.) and site-wide pre-settings for the five categories in task scripts, described below under L<configuration categories|/configuration categories>)

=item %common 

common configs for the task script, may contain one configuration hash for each configuration category.

=item @loads

list of hashes defining specific load processes within the task script. Each hash may contain one configuration hash for each configuration category.

=item configuration categories

In the above mentioned hashes can be five categories (sub-hashes): L<DB|/DB>, L<File|/File>, L<FTP|/FTP>, L<process|/process> and L<task|/task>. These allow further parameters to be set for the respective parts of EAI::Wrap (L<EAI::DB>, L<EAI::File> and L<EAI::FTP>), process parameters and task parameters. The parameters are described in detail in section L<CONFIGURATION REFERENCE|/CONFIGURATION REFERENCE>.

The L<process|/process> category is on the one hand used to pass information within each process (data, additionalLookupData, filenames, hadErrors or commandline parameters starting with interactive), on the other hand for additional configurations not suitable for L<DB|/DB>, L<File|/File> or L<FTP|/FTP> (e.g. L<uploadCMD|/uploadCMD>). The L<task|/task> category contains parameters used on the task script level and is therefore only allowed in %config and %common. It contains parameters for skipping, retrying and redoing the whole task script.

The settings in DB, File, FTP and task are "merge" inherited in a cascading manner (i.e. missing parameters are merged, parameters already set below are not overwritten):

 %config (defined in site.config and other associated configs loaded at INIT)
 merged into ->
 %common (common task parameters defined in script)
 merged into each of ->
 $loads[]

special config parameters and DB, FTP, File, task parameters from command line options are merged at the respective level (config at the top, the rest at the bottom) and always override any set parameters.
Only scalar parameters can be given on the command line, no lists and hashes are possible. Commandline options are given in the format:

  --<category> <parameter>=<value>

for the common level and 

  --load<i><category> <parameter>=<value>

for the loads level.

Command line options are also available to the script via the hash C<%opt> or the list of hashes C<@optloads>, so in order to access the cmdline option C<--process interactive_date=202300101> you could either use C<$common{process}{interactive_date}> or C<$opt{process}{interactive_date}>. 

In order to use C<--load1process interactive_date=202300101>, you would use C<$loads[1]{process}{interactive_date}> or C<$optloads[1]{process}{interactive_date}>.

The merge inheritance for L<DB|/DB>, L<FTP|/FTP>, L<File|/File> and L<task|/task> can be prevented by using an underscore after the hashkey, ie. C<DB_>, C<FTP_>, C<File_> and C<task_>. In this case the parameters are not merged from C<common>. However, they are always inherited from C<config>.

=item %execute

hash of parameters for current task execution which is not set by the user but can be used to set other parameters and control the flow. Most important here are C<$execute{env}> giving the current used environment (Prod, Test, Dev, whatever), C<$execute{envraw}> (Production is empty here), the several files lists (being procesed, for deletion, moving, etc.), flags for ending/interrupting processing, directory locations as home and history, etc.

Detailed information about the several parameters used can be found in section L<execute|/execute> of the configuration parameter reference, there are parameters for files (L<filesProcessed|/filesProcessed>, L<filesToArchive|/filesToArchive>, L<filesToDelete|/filesToDelete>, L<filesToMoveinHistory|/filesToMoveinHistory>, L<filesToMoveinHistoryUpload|/filesToMoveinHistoryUpload>, L<filesToRemove|/filesToRemove> and L<retrievedFiles|/retrievedFiles>), directories (L<homedir|/homedir>, L<historyFolder|/historyFolder>, L<historyFolderUpload|/historyFolderUpload> and L<redoDir|/redoDir>), process controlling parameters (L<failcount|/failcount>, L<firstRunSuccess|/firstRunSuccess>, L<retryBecauseOfError|/retryBecauseOfError>, L<retrySeconds|/retrySeconds> and L<processEnd|/processEnd>).

Retrying with querying C<$execute{processEnd}> can happen on two reasons: First, because C<task =E<gt> {plannedUntil =E<gt> "HHMM"}> is set to a time until the task has to be retried, however this is done at most until midnight. Second, because an error occurred, in this case C<$process-E<gt>{hadErrors}> is set on each load that failed. C<$execute{retryBecauseOfError}> is also important in this context as it prevents the repeated run of following API procedures if the process didn't have an error:

L<getLocalFiles|/getLocalFiles>, L<getFilesFromFTP|/getFilesFromFTP>, L<getFiles|/getFiles>, L<checkFiles|/checkFiles>, L<extractArchives|/extractArchives>, L<getAdditionalDBData|/getAdditionalDBData>, L<readFileData|/readFileData>, L<dumpDataIntoDB|/dumpDataIntoDB>, L<writeFileFromDB|/writeFileFromDB>, L<putFileInLocalDir|/putFileInLocalDir>, L<uploadFileToFTP|/uploadFileToFTP>, L<uploadFileCMD|/uploadFileCMD>, and L<uploadFile|/uploadFile>.

After the first successful run of the task, C<$execute{firstRunSuccess}> is set to prevent any error messages resulting of files having been moved/removed while rerunning the task until the defined planned time (C<task =E<gt> {plannedUntil =E<gt> "HHMM"}>) has been reached.

=item INIT ()

The INIT procedure is executed at the EAI::Wrap module initialization (when EAI::Wrap is used in the task script) and loads the site configuration, starts logging and reads commandline options. This means that everything passed to the script via command line may be used in the definitions, especially the C<task{interactive.*}> parameters, here the name and the type of the parameter are not checked by the consistency checks (all other parameters not allowed or having the wrong type would throw an error).

=item removeFilesinFolderOlderX

remove files on FTP server being older than a time back (given in day/mon/year in C<remove =E<gt> {removeFolders =E<gt> ["",""], day=E<gt>, mon=E<gt>, year=E<gt>1}>), see L<EAI::FTP::removeFilesOlderX>

=item openDBConn

open a DB connection with the information provided in C<$DB-E<gt>{user}>, C<$DB-E<gt>{pwd}> (these can be provided by the sensitive information looked up using C<$DB-E<gt>{prefix}>), C<$DB-E<gt>{DSN}> and C<$execute{env}>, see L<EAI::DB::newDBH>

=item openFTPConn

open a FTP connection with the information provided in C<$FTP-E<gt>{remoteHost}>, C<$FTP-E<gt>{user}>, C<$FTP-E<gt>{pwd}>, C<$FTP-E<gt>{hostkey}>, C<$FTP-E<gt>{privKey}> (these four can be provided by the sensitive information looked up using C<$FTP-E<gt>{prefix}>) and C<$execute{env}>, see L<EAI::FTP::login>

=item redoFiles

redo file from redo directory if specified (C<$common{task}{redoFile}> is being set), this is also being called by getLocalFiles and getFilesFromFTP. Arguments are fetched from common or loads[i], using File parameter.

=item getLocalFiles

get local file(s) from source into homedir and extract archives if needed, uses C<$File-E<gt>{filename}>, C<$File-E<gt>{extension}> and C<$File-E<gt>{avoidRenameForRedo}>. Arguments are fetched from common or loads[i], using File parameter.

=item getFilesFromFTP

get file/s (can also be a glob for multiple files) from FTP into homedir and extract archives if needed. Arguments are fetched from common or loads[i], using File and FTP parameters.

=item getFiles

combines above two procedures in a general procedure to get files from FTP or locally. Arguments are fetched from common or loads[i], using File and FTP parameters.

=item checkFiles

check files for continuation of processing. Arguments are fetched from common or loads[i], using File parameter. The processed files are put into process->{filenames}

=item extractArchives

extract files from archive. Arguments are fetched from common or loads[i], using only the process->{filenames} parameter that was filled by checkFiles. 

=item getAdditionalDBData

get additional data from DB. Arguments are fetched from common or loads[i], using DB and process parameters. You can also pass an optional ref to a data hash parameter to store the retrieved data there instead of C<$process->{additionalLookupData}>

=item readFileData

read data from a file. Arguments are fetched from common or loads[i], using File parameter.

=item dumpDataIntoDB

store data into Database. Arguments are fetched from common or loads[i], using DB and File (for emptyOK) parameters.

=item markProcessed

mark files as being processed depending on whether there were errors, also decide on removal/archiving of downloaded files. Arguments are fetched from common or loads[i], using File parameter.

=item writeFileFromDB

create Data-files from Database. Arguments are fetched from common or loads[i], using DB and File parameters.

=item putFileInLocalDir

put files into local folder if required. Arguments are fetched from common or loads[i], using File parameter.

=item markForHistoryDelete

mark to be removed or be moved to history after upload. Arguments are fetched from common or loads[i], using File parameter.

=item uploadFileToFTP

upload files to FTP. Arguments are fetched from common or loads[i], using FTP and File parameters.

=item uploadFileCMD

upload files using an upload command program. Arguments are fetched from common or loads[i], using File and process parameters.

=item uploadFile

combines above two procedures in a general procedure to upload files via FTP or CMD or to put into local dir. Arguments are fetched from common or loads[i], using File and process parameters

=item processingEnd

final processing steps for processEnd (cleanup, FTP removal/archiving) or retry after pausing. No context argument as this always depends on all loads and/or the common definition

=item processingPause

generally available procedure for pausing processing, argument $pauseSeconds gives the delay

=item moveFilesToHistory (;$)

move transferred files marked for moving (filesToMoveinHistory/filesToMoveinHistoryUpload) into history and/or historyUpload folder. Optionally a custom timestamp can be passed.
 
=item deleteFiles ($)

delete transferred files. The filenames are passed in a ref to array

=back



=head2 CONFIGURATION REFERENCE

=over 4

=item config

parameter category for site global settings, defined in site.config and other associated configs loaded at INIT

=over 4

=item checkLookup

used for logchecker, each entry of the hash defines a log to be checked, defining errmailaddress to receive error mails, errmailsubject, timeToCheck as earliest time to check for existence in log, freqToCheck as frequency of checks (daily/monthly/etc), logFileToCheck as the name of the logfile to check, logcheck as the regex to check in the logfile and logRootPath as the folder where the logfile is found. lookup key: $execute{scriptname} + $execute{addToScriptName}

=item errmailaddress

default mail address for central logcheck/errmail sending 

=item errmailsubject

default mail subject for central logcheck/errmail sending 

=item executeOnInit

code to be executed during INIT of EAI::Wrap to allow for assignment of config/execute parameters from commandline params BEFORE Logging!

=item folderEnvironmentMapping

Mapping for $execute{envraw} to $execute{env}

=item fromaddress

from address for central logcheck/errmail sending, also used as default sender address for sendGeneralMail

=item historyFolder

folders where downloaded files are historized, lookup key as checkLookup, default in "" =>

=item historyFolderUpload

folders where uploaded files are historized, lookup key as checkLookup, default in "" =>

=item logCheckHoliday

calendar for business days in central logcheck/errmail sending

=item logs_to_be_ignored_in_nonprod

logs to be ignored in central logcheck/errmail sending

=item logRootPath

paths to log file root folders (environment is added to that if non production), lookup key as checkLookup, default in "" =>

=item redoDir

folders where files for redo are contained, lookup key as checkLookup, default in "" =>

=item sensitive

hash lookup for sensitive access information in DB and FTP (lookup keys are set with DB{prefix} or FTP{prefix}), may also be placed outside of site.config; all sensitive keys can also be environment lookups, e.g. hostkey=>{Test => "", Prod => ""} to allow for environment specific setting

=item smtpServer

smtp server for den (error) mail sending

=item smtpTimeout

timeout for smtp response

=item testerrmailaddress

error mail address in non prod environment

=back

=item execute

hash of parameters for current task execution which is not set by the user but can be used to set other parameters and control the flow

=over 4

=item alreadyMovedOrDeleted

hash for checking the already moved or deleted files, to avoid moving/deleting them again at cleanup

=item addToScriptName

this can be set to be added to the scriptname for config{checkLookup} keys, e.g. some passed parameter.

=item env

Prod, Test, Dev, whatever

=item envraw

Production has a special significance here as being the empty string (used for paths). Otherwise like env.

=item errmailaddress

for central logcheck/errmail sending in current process

=item errmailsubject

for central logcheck/errmail sending in current process

=item failcount

for counting failures in processing to switch to longer wait period or finish altogether

=item filesToArchive

list of files to be moved in archiveDir on FTP server, necessary for cleanup at the end of the process

=item filesToDelete

list of files to be deleted on FTP server, necessary for cleanup at the end of the process

=item filesToMoveinHistory

list of files to be moved in historyFolder locally, necessary for cleanup at the end of the process

=item filesToMoveinHistoryUpload

list of files to be moved in historyFolderUpload locally, necessary for cleanup at the end of the process

=item filesToRemove

list of files to be deleted locally, necessary for cleanup at the end of the process

=item firstRunSuccess

for planned retries (process=>plannedUntil filled) -> this is set after the first run to avoid error messages resulting of files having been moved/removed.

=item freqToCheck

for logchecker:  frequency to check entries (B,D,M,M1) ...

=item homedir

the home folder of the script, mostly used to return from redo and other folders for globbing files.

=item historyFolder

actually set historyFolder

=item historyFolderUpload

actually set historyFolderUpload

=item logcheck

for logchecker: the Logcheck (regex)

=item logFileToCheck

for logchecker: Logfile to be searched

=item logRootPath

actually set logRootPath

=item processEnd

specifies that the process is ended, checked in EAI::Wrap::processingEnd

=item redoDir

actually set redoDir

=item retrievedFiles

files retrieved from FTP or redo directory

=item retryBecauseOfError

retryBecauseOfError shows if a rerun occurs due to errors (for successMail) and also prevents several API calls from being run again.

=item retrySeconds

how many seconds are passed between retries. This is set on error with process=>retrySecondsErr and if planned retry is defined with process=>retrySecondsPlanned

=item scriptname

name of the current process script, also used in log/history setup together with addToScriptName for config{checkLookup} keys

=item timeToCheck

for logchecker: scheduled time of job (don't look earlier for log entries)

=back

=item DB

DB specific configs

=over 4

=item addID

this hash can be used to additionaly set a constant to given fields: Fieldname => Fieldvalue

=item additionalLookup

query used in getAdditionalDBData to retrieve lookup information from DB using readFromDBHash

=item additionalLookupKeys

used for getAdditionalDBData, list of field names to be used as the keys of the returned hash

=item cutoffYr2000

when storing date data with 2 year digits in dumpDataIntoDB/storeInDB, this is the cutoff where years are interpreted as 19XX (> cutoffYr2000) or 20XX (<= cutoffYr2000)

=item columnnames

returned column names from readFromDB and readFromDBHash, this is used in writeFileFromDB to pass column information from database to writeText

=item database

database to be used for connecting

=item debugKeyIndicator

used in dumpDataIntoDB/storeInDB as an indicator for keys for debugging information if primkey not given (errors are shown with this key information). Format is the same as for primkey

=item deleteBeforeInsertSelector

used in dumpDataIntoDB/storeInDB to delete specific data defined by keydata before an insert (first occurrence in data is used for key values). Format is the same as for primkey ("key1 = ? ...")

=item dontWarnOnNotExistingFields

suppress warnings in dumpDataIntoDB/storeInDB for not existing fields

=item dontKeepContent

if table should be completely cleared before inserting data in dumpDataIntoDB/storeInDB

=item doUpdateBeforeInsert

invert insert/update sequence in dumpDataIntoDB/storeInDB, insert only done when upsert flag is set

=item DSN

DSN String for DB connection

=item incrementalStore

when storing data with dumpDataIntoDB/storeInDB, avoid setting empty columns to NULL

=item ignoreDuplicateErrs

ignore any duplicate errors in dumpDataIntoDB/storeInDB

=item keyfields

used for readFromDBHash, list of field names to be used as the keys of the returned hash

=item longreadlen

used for setting database handles LongReadLen parameter for DB connection, if not set defaults to 1024

=item noDBTransaction

don't use a DB transaction for dumpDataIntoDB

=item noDumpIntoDB

if files from this load should not be dumped to the database

=item postDumpExecs

done in dumpDataIntoDB after postDumpProcessing and before commit/rollback. doInDB everything in execs if condition is fulfilled 

=item postDumpProcessing

done in dumpDataIntoDB after storeInDB, execute perl code in postDumpProcessing

=item postReadProcessing

done in writeFileFromDB after readFromDB, execute perl code in postReadProcessing

=item prefix

key for sensitive information (e.g. pwd and user) in config{sensitive}

=item primkey

primary key indicator to be used for update statements, format: "key1 = ? AND key2 = ? ..."

=item pwd

for password setting, either directly (insecure -> visible) or via sensitive lookup

=item query

query statement used for readFromDB and readFromDBHash

=item schemaName

schemaName used in dumpDataIntoDB/storeInDB, if tableName contains dot the extracted schema from tableName overrides this. Needed for datatype information!

=item server

DB Server in environment hash

=item tablename

the table where data is stored in dumpDataIntoDB/storeInDB

=item upsert

in dumpDataIntoDB/storeInDB, should an update be done after the insert failed (because of duplicate keys) or insert after the update failed (because of key not exists)?

=item user

for user setting, either directly (insecure -> visible) or via sensitive lookup

=back

=item File

File parsing specific configs

=over 4

=item avoidRenameForRedo

when redoing, usually the cutoff (datetime/redo info) is removed following a pattern. set this flag to avoid this

=item columns

for writeText: Hash of data fields, that are to be written (in order of keys)

=item columnskip

for writeText: boolean hash of column names that should be skipped when writing the file ({column1ToSkip => 1, column2ToSkip => 1, ...})

=item dontKeepHistory

if up- or downloaded file should not be moved into historyFolder but be deleted

=item dontMoveIntoHistory

if up- or downloaded file should not be moved into historyFolder but be kept in homedir

=item emptyOK

flag to specify whether empty files should not invoke an error message. Also needed to mark an empty file as processed in EAI::Wrap::markProcessed

=item encoding

text encoding of the file in question (e.g. :encoding(utf8))

=item extract

flag to specify whether to extract files from archive package (zip)

=item extension

the extension of the file to be read (optional, used for redoFile)

=item fieldCode

additional field based processing code: fieldCode => {field1 => 'perl code', ..}, invoked if key equals either header (as in format_header) or targetheader (as in format_targetheader) or invoked for all fields if key is empty {"" => 'perl code'}. set $skipLineAssignment to true (1) if current line should be skipped from data.

=item filename

the name of the file to be read

=item firstLineProc

processing done in reading the first line of text files

=item format_allowLinefeedInData

line feeds in values don't create artificial new lines/records, only works for csv quoted data

=item format_beforeHeader

additional String to be written before the header in write text

=item format_dateColumns

numeric array of columns that contain date values (special parsing) in excel files

=item format_decimalsep

decimal separator used in numbers of sourcefile (defaults to . if not given)

=item format_headerColumns

optional numeric array of columns that contain data in excel files (defaults to all columns starting with first column up to format_targetheader length)

=item format_header

format_sep separated string containing header fields (optional in excel files, only used to check against existing header row)

=item format_headerskip

skip until row-number for checking header row against format_header in excel files

=item format_eol

for quoted csv specify special eol character (allowing newlines in values)

=item format_fieldXpath

for XML reading, hash with field => xpath to content association entries

=item format_fix

for text writing, specify whether fixed length format should be used (requires format_padding)

=item format_namespaces

for XML reading, hash with alias => namespace association entries

=item format_padding

for text writing, hash with field number => padding to be applied for fixed length format

=item format_poslen

array of positions/length definitions: e.g. "poslen => [(0,3),(3,3)]" for fixed length format text file parsing

=item format_quotedcsv

special parsing/writing of quoted csv data using Text::CSV

=item format_sep

separator string for csv format, regex for split for other separated formats. Also needed for splitting up format_header and format_targetheader (Excel and XML-formats use tab as default separator here).

=item format_sepHead

special separator for header row in write text, overrides format_sep

=item format_skip

either numeric or string, skip until row-number if numeric or appearance of string otherwise in reading textfile

=item format_stopOnEmptyValueColumn

for excel reading, stop row parsing when a cell with this column number is empty (denotes end of data, to avoid very long parsing).

=item format_suppressHeader

for textfile writing, suppress output of header

=item format_targetheader

format_sep separated string containing target header fields (= the field names in target/database table). optional for XML and tabular textfiles, defaults to format_header if not given there.

=item format_thousandsep

thousand separator used in numbers of sourcefile (defaults to , if not given)

=item format_worksheetID

worksheet number for excel reading, this should always work

=item format_worksheet

alternatively the worksheet name can be passed, this only works for new excel format (xlsx)

=item format_xlformat

excel format for parsing, also specifies excel parsing

=item format_xpathRecordLevel

xpath for level where data nodes are located in xml

=item format_XML

specify xml parsing

=item lineCode

additional line based processing code, invoked after whole line has been read

=item localFilesystemPath

if files are taken from or put to the local file system with getLocalFiles/putFileInLocalDir then the path is given here. Setting this to "." avoids copying files.

=item optional

to avoid error message for missing optional files, set this to 1

=back

=item FTP

FTP specific configs

=over 4

=item archiveDir

folder for archived files on the FTP server

=item dontMoveTempImmediately

if 0 oder missing: rename/move files immediately after writing to FTP to the final name, otherwise/1: a call to EAI::FTP::moveTempFiles is required for that

=item dontDoSetStat

for Net::SFTP::Foreign, no setting of time stamp of remote file to that of local file (avoid error messages of FTP Server if it doesn't support this)

=item dontDoUtime

don't set time stamp of local file to that of remote file

=item dontUseQuoteSystemForPwd

for windows, a special quoting is used for passing passwords to Net::SFTP::Foreign that contain [()"<>& . This flag can be used to disable this quoting.

=item dontUseTempFile

directly upload files, without temp files

=item fileToArchive

should file be archived on FTP server? requires archiveDir to be set

=item fileToRemove

should file be removed on FTP server?

=item FTPdebugLevel

debug ftp: 0 or ~(1|2|4|8|16|1024|2048), loglevel automatically set to debug for module EAI::FTP

=item hostkey

hostkey to present to the server for Net::SFTP::Foreign, either directly (insecure -> visible) or via sensitive lookup

=item localDir

optional: local folder for files to be placed, if not given files are downloaded into current folder

=item maxConnectionTries

maximum number of tries for connecting in login procedure

=item onlyArchive

only archive/remove on the FTP server, requires archiveDir to be set

=item path

additional relative FTP path (under remoteDir which is set at login), where the file(s) is/are located

=item port

ftp/sftp port (leave empty for default port 22)

=item prefix

key for sensitive information (e.g. pwd and user) in config{sensitive}

=item privKey

sftp key file location for Net::SFTP::Foreign, either directly (insecure -> visible) or via sensitive lookup

=item pwd

for password setting, either directly (insecure -> visible) or via sensitive lookup

=item queue_size

queue_size for Net::SFTP::Foreign, if > 1 this causes often connection issues

=item remove

for for removing (archived) files with removeFilesOlderX, all files in removeFolders are deleted being older than day=> days, mon=> months and year=> years

=item remoteDir

remote root folder for up-/download, archive and remove: "out/Marktdaten/", path is added then for each filename (load)

=item remoteHost

ref to hash of IP-addresses/DNS of host(s).

=item SFTP

to explicitly use SFTP, if not given SFTP will be derived from existence of privKey or hostkey

=item simulate

for removal of files using removeFilesinFolderOlderX/removeFilesOlderX only simulate (1) or do actually (0)?

=item sshInstallationPath

path were ssh/plink exe to be used by Net::SFTP::Foreign is located

=item type

(A)scii or (B)inary

=item user

set user directly, either directly (insecure -> visible) or via sensitive lookup

=back

=item process

used to pass information within each process (data, additionalLookupData, filenames, hadErrors or commandline parameters starting with interactive) and for additional configurations not suitable for DB, File or FTP (e.g. uploadCMD)

=over 4

=item additionalLookupData

additional data retrieved from database with EAI::Wrap::getAdditionalDBData

=item archivefilenames

in case a zip archive package is retrieved, the filenames of these packages are kept here, necessary for cleanup at the end of the process

=item data

loaded data: array (rows) of hash refs (columns)

=item filenames

names of files that were retrieved and checked to be locally available for that load, can be more than the defined file in File->filename (due to glob spec or zip archive package)

=item filesProcessed

hash for checking the processed files, necessary for cleanup at the end of the whole task

=item hadErrors

set to 1 if there were any errors in the process

=item interactive_

interactive options (are not checked), can be used to pass arbitrary data via command line into the script (eg a selected date for the run with interactive_date).

=item uploadCMD

upload command for use with uploadFileCMD

=item uploadCMDPath

path of upload command

=item uploadCMDLogfile

logfile where command given in uploadCMD writes output (for error handling)

=back

=item task

contains parameters used on the task script level

=over 4

=item customHistoryTimestamp

optional custom timestamp to be added to filenames moved to History/HistoryUpload/FTP archive, if not given, get_curdatetime is used (YYYYMMDD_hhmmss)

=item ignoreNoTest

ignore the notest file in the process-script folder, usually preventing all runs that are not in production

=item plannedUntil

latest time that planned repitition should last

=item redoFile

flag for specifying a redo

=item retrySecondsErr

retry period in case of error

=item retrySecondsErrAfterXfails

after fail count is reached this alternate retry period in case of error is applied. If 0/undefined then job finishes after fail count

=item retrySecondsXfails

fail count after which the retrySecondsErr are changed to retrySecondsErrAfterXfails

=item retrySecondsPlanned

retry period in case of planned retry

=item skipHolidays

skip script execution on holidays

=item skipHolidaysDefault

holiday calendar to take into account for skipHolidays

=item skipWeekends

skip script execution on weekends

=item skipForFirstBusinessDate

used for "wait with execution for first business date", either this is a calendar or 1 (then calendar is skipHolidaysDefault), this cannot be used together with skipHolidays

=back

=back

=head1 COPYRIGHT

Copyright (c) 2023 Roland Kapl

All rights reserved.  This program is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the LICENSE file included
with this module.

=cut