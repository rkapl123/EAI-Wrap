package EAI::FTP 0.9;

use strict; use feature 'unicode_strings'; use warnings;
use Exporter qw(import); use Net::SFTP::Foreign (); use Net::SFTP::Foreign::Constants qw( SFTP_ERR_LOCAL_UTIME_FAILED ); use Net::FTP (); use Text::Glob qw(match_glob);
use Log::Log4perl qw(get_logger); use File::Temp qw(tempfile); use Data::Dumper qw(Dumper); use Scalar::Util 'blessed'; use Fcntl ':mode'; # for S_ISREG check in removeFilesOlderX
use EAI::DateUtil qw(get_curdatetime get_curdate addDatePart parseFromYYYYMMDD);
# for passwords that contain <#|>% we have to use shell quoting on windows (special "use" to make this optional on non-win environments)
BEGIN {
	if ($^O =~ /MSWin/) {require Win32::ShellQuote; Win32::ShellQuote->import();}
}

our @EXPORT = qw(removeFilesOlderX fetchFiles putFile moveTempFile archiveFiles removeFiles login getHandle setHandle);

my $ftp; # module static SFTP handle, will be dynamic when using OO-Style here
my $RemoteHost = ""; # module static RemoteHost string, will be dynamic when using OO-Style here

# wrappers for different FTP implementations

# wrapper for getting error/message
sub _error () {
	if ($ftp->isa('Net::SFTP::Foreign')) {
		return $ftp->error;
	} else {
		return $ftp->message;
	}
}

# wrapper for getting file
sub _get ($$;$) {
	my ($remoteFile, $localFile,$queue_size) = @_;
	if ($ftp->isa('Net::SFTP::Foreign')) {
		return $ftp->get($remoteFile, $localFile, queue_size => $queue_size);
	} else {
		return $ftp->get($remoteFile, $localFile);
	}
}

# wrapper for globbing files
sub _glob ($;$) {
	my ($remoteFile,$withoutPath) = @_;
	# separate glob from path
	my ($remotePath,$remoteGlob) = ($remoteFile =~ /^(.*)\/(.*?)$/);
	if ($ftp->isa('Net::SFTP::Foreign')) {
		my @returnedFiles = $ftp->glob($remoteFile, names_only => 1);
		if ($withoutPath and $remoteGlob) {
			return map {substr($_,length($remotePath)+1)} @returnedFiles;
		} else {
			return @returnedFiles;
		}
	} else {
		if ($remoteGlob eq "") {
			$remotePath = "."; # no path found in $remoteFile, so current working dir
			$remoteGlob = $remoteFile;
		}
		my @returnedFiles = match_glob ($remoteGlob, $ftp->ls($remotePath)); # get all files in remote path
		return map { (($remotePath eq "." or $withoutPath) ? $_ : $remotePath."/".$_) } @returnedFiles; # filter files by glob
	}
}

# wrapper for globbing files in current working dir older than given time
sub _ls_age ($) {
	my ($mtimeToKeep) = @_;
	my $logger = get_logger();
	if ($ftp->isa('Net::SFTP::Foreign')) {
		return $ftp->ls('.',
							wanted => sub {
								# callback function is being passed the read files in a reference to hash with 3 keys:
								# filename, longname (as from ls -l) and "a", which is a Net::SFTP::Foreign::Attributes object that contains atime, mtime, permissions and size of the file.
								my $attr = $_[1]->{a}; 
								# if "wanted" returns true (mod time is older than mtimeToKeep), then the file is being added to the returned array
								$logger->trace("file: ".$_[1]->{filename}.",mtime: ".$attr->mtime.",mtimeToKeep: ".$mtimeToKeep) if $logger->is_trace;
								return $attr->mtime < $mtimeToKeep && S_ISREG($attr->perm); # add file if mod time < required mod time AND it is a regular file...
							} );
	} else {
		my @returnedFiles = $ftp->ls('.');
		my $matchedFiles;
		for my $file (@returnedFiles) {
			$logger->trace("file: ".$file.",mtime: ".$ftp->mdtm($file).",mtimeToKeep: ".$mtimeToKeep) if $logger->is_trace;
			my %file = (filename => $file);
			push @$matchedFiles, \%file if $ftp->mdtm($file) < $mtimeToKeep;
		}
		return $matchedFiles;
	}
}

# wrapper for getting time of file
sub _mtime ($) {
	my ($remoteFile) = @_;
	if ($ftp->isa('Net::SFTP::Foreign')) {
		my $attr = $ftp->stat($remoteFile);
		return $attr->mtime if $attr;
	} else {
		return $ftp->mdtm($remoteFile);
	}
}

# wrapper for putting file
sub _put ($$) {
	my ($localFile,$doSetStat) = @_;
	if ($ftp->isa('Net::SFTP::Foreign')) {
		return $ftp->put($localFile, $localFile, late_set_perm => 1, copy_perm => $doSetStat, copy_time => $doSetStat);
	} else {
		return $ftp->put($localFile, $localFile);
	}
}

# wrapper for removing file
sub _remove ($) {
	my ($remoteFile) = @_;
	if ($ftp->isa('Net::SFTP::Foreign')) {
		return $ftp->remove($remoteFile);
	} else {
		return $ftp->delete($remoteFile);
	}
}

# wrapper for setting current working directory
sub _setcwd ($) {
	my ($remoteDir) = @_;
	if ($ftp->isa('Net::SFTP::Foreign')) {
		return $ftp->setcwd($remoteDir);
	} else {
		return $ftp->cwd($remoteDir);
	}
}

# wrapper for getting status
sub _status () {
	if ($ftp->isa('Net::SFTP::Foreign')) {
		return $ftp->status;
	} else {
		return ""; # no equivalent in Net:FTP
	}
}


# remove all files in FTP server folders that are older than a given years/months/days
sub removeFilesOlderX ($) {
	my $FTP = shift;
	my $logger = get_logger();
	my @removeFolders = @{$FTP->{remove}{removeFolders}} if $FTP->{remove}{removeFolders};
	if (defined $ftp) {
		for my $folder (@removeFolders) {
			my $newDate = addDatePart(addDatePart(addDatePart(get_curdate(),-$FTP->{remove}{year},"y"),-$FTP->{remove}{mon},"m"),-$FTP->{remove}{day},"d");
			$logger->info("remove files in FTP (archive)folder older than $FTP->{remove}{year} years,$FTP->{remove}{mon} months and $FTP->{remove}{day} days (decreased in this order), resulting in cut off date $newDate");
			my $mtimeToKeep = parseFromYYYYMMDD($newDate);
			$logger->debug("changing into FTP remoteDir $FTP->{remoteDir}");
			_setcwd(undef) if (substr($FTP->{remoteDir},0,1) eq "/"); # starting / means start from home...
			my $remoteDir = (substr($FTP->{remoteDir},0,1) eq "/" ? substr($FTP->{remoteDir},1) : $FTP->{remoteDir});
			$remoteDir = ((substr($remoteDir,-1) eq "/" or $remoteDir eq "") ? $remoteDir : $remoteDir."/");
			if (_setcwd($remoteDir.$folder)) {
				my $files = _ls_age($mtimeToKeep) or $logger->error("can't get file list, reason: "._error().", status: "._status());
				for my $file (@$files) {
					$logger->info("$remoteDir$folder:".($FTP->{simulate} ? "simulate removal of: " : "removing: ").$file->{filename});
					unless ($FTP->{simulate}) {
						_remove($file->{filename}) or $logger->error("can't remove $file->{filename}: "._error().", status: "._status());
					}
				}
				$logger->info("$remoteDir$folder: no Files to remove !") if !@$files;
			} else {
				$logger->error("can't cwd to remove folder $remoteDir$folder: "._error().", status: "._status());
				return 0;
			}
		}
		$logger->info("remove files finished ...");
	} else {
		$logger->error("no ftp connection opened!");
		return 0;
	}
	return 1;
}

# fetch files from FTP server
sub fetchFiles ($$) {
	my ($FTP,$param) = @_;
	my $logger = get_logger();
	my $suppressGetError = $param->{firstRunSuccess};
	my $queue_size = $FTP->{queue_size};
	$queue_size = 1 if !$queue_size; # queue_size bigger 1 causes often connection issues
	if (defined $ftp) {
		$logger->debug("changing into folder $FTP->{remoteDir}");
		_setcwd(undef) if (substr($FTP->{remoteDir},0,1) eq "/"); # starting / means start from home...
		my $remoteDir = (substr($FTP->{remoteDir},0,1) eq "/" ? substr($FTP->{remoteDir},1) : $FTP->{remoteDir});
		if (_setcwd($remoteDir)) {
			my $remoteFile = ($FTP->{path} ? $FTP->{path}."/" : "").$param->{fileToRetrieve};
			my $localPath = ($FTP->{localDir} ? $FTP->{localDir} : $param->{homedir});
			$localPath .= "/" if $localPath !~ /.*[\/\\]$/;
			my $localFile = $localPath.$param->{fileToRetrieve};
			if ($remoteFile =~ /\*/) { # if there is a glob character then glob and do multiple get !
				$logger->info("fetching fileglob $remoteFile");
				my @multipleRemoteFiles = _glob($remoteFile); # list retrieved files (including potential path) for fetching
				my @multipleFiles = _glob($remoteFile, 1); # list retrieved files (without path) for later processing
				$logger->debug("glob $remoteFile returned @multipleFiles");
				@{$param->{retrievedFiles}} = @multipleFiles;
				for (my $i = 0; $i < @multipleFiles; $i++) {
					$logger->debug("fetching file ".$multipleRemoteFiles[$i]);
					_get($multipleRemoteFiles[$i], $localPath.$multipleFiles[$i], $queue_size) or do {
						unless (_error() == SFTP_ERR_LOCAL_UTIME_FAILED || $suppressGetError) {
							$logger->error("error: can't get remote-file ".$multipleRemoteFiles[$i]." from glob $remoteFile, reason: "._error().", status: "._status());
							@{$param->{retrievedFiles}} = ();
							return 0;
						}
					};
				}
				$logger->info("multiple get with $remoteFile retrieved following files into $localPath: @multipleFiles");
			} else {
				$logger->info("fetching file $remoteFile");
				my $mod_time = _mtime($remoteFile);
				$logger->debug("get file $remoteFile");
				@{$param->{retrievedFiles}} = ($param->{fileToRetrieve});
				_get($remoteFile, $localFile, $queue_size) or do { 
					$logger->debug("ftp_get returned error: "._error().", status:"._status());
					if (!$param->{fileToRetrieveOptional} and !$FTP->{fileToRemove}) { # ignore errors for a file that was either removed or is optional
						unless (_error() == SFTP_ERR_LOCAL_UTIME_FAILED || $suppressGetError) {
							$logger->error("can't get remote-file $remoteFile, reason: "._error().", status: "._status());
							@{$param->{retrievedFiles}} = ();
							return 0;
						}
					}
				};
				$logger->info("fetched file $remoteFile to $localFile");
				if ($mod_time && !$FTP->{dontDoUtime}) {
					 utime($mod_time,$mod_time,$localFile) or $logger->warn("couldn't set time for $localFile: $!");
				}
			}
		} else {
			$logger->error("can't change into remote-directory $remoteDir, reason: "._error());
			return 0;
		}
	} else {
		$logger->error("no ftp connection opened!");
		return 0;
	}
	return 1;
}

# puts file to FTP server
sub putFile ($$) {
	my ($FTP,$param) = @_;
	my $logger = get_logger();
	my $localFile = $param->{fileToWrite} or do {
		$logger->error("no file to upload (fileToWrite parameter) !");
		return 0;
	};
	if (defined $ftp) {
		my $doSetStat = ($FTP->{dontDoSetStat} ? 0 : 1);
		$logger->debug("changing into folder $FTP->{remoteDir}");
		_setcwd(undef) if (substr($FTP->{remoteDir},0,1) eq "/"); # starting / means start from home...
		my $remoteDir = (substr($FTP->{remoteDir},0,1) eq "/" ? substr($FTP->{remoteDir},1) : $FTP->{remoteDir});
		if (_setcwd($remoteDir)) {
			if ($FTP->{dontUseTempFile}) {
				$logger->info("uploading file $localFile");
				if (!_put($localFile, $doSetStat)) {
					$logger->error("can't upload local file $localFile to remote dir $FTP->{remoteDir}, reason: "._error());
					return 0;
				}
			} else {
				# safe method for uploading in case a monitor "listens": upload temp file, then rename remotely to final name
				# first rename to temp... locally
				rename $localFile, "temp.".$localFile or $logger->error("can't rename local file $localFile to temp.$localFile, reason: $!") ;
				$logger->info("uploading file temp.$localFile");
				if (!_put("temp.$localFile", $doSetStat)) {
					$logger->error("error: can't upload local file temp.$localFile to ${remoteDir}/temp.$localFile, reason: "._error());
					return 0;
				}
				# then name back again remotely
				if (!$FTP->{dontMoveTempImmediately}) {
					$logger->debug("Sftp: remote rename temp file temp.$localFile auf $localFile ...");
					if ($ftp->rename("temp.".$localFile,$localFile)) {
						$logger->debug("Sftp: temporary file $remoteDir/temp.$localFile renamed to $localFile");
					} else {
						$logger->error("can't rename remote-file $remoteDir/temp.$localFile to $localFile, reason: "._error()) ;
					}
				}
				# last rename temp locally as well for further processing
				rename "temp.".$localFile, $localFile;
			}
		} else {
			$logger->error("can't change into remote-directory $remoteDir, reason: "._error());
			return 0;
		}
	} else {
		$logger->error("no ftp connection opened!");
		return 0;
	}
	$logger->info("finished uploading file ".($FTP->{dontUseTempFile} ? $localFile : "temp.".$localFile));
	return 1;
}

# move temp file on FTP server
sub moveTempFile ($$) {
	my ($FTP, $param) = @_;
	my $logger = get_logger();
	my $localFile = $param->{fileToWrite} or do {
		$logger->error("no file to upload (fileToWrite parameter) !");
		return 0;
	};
	$logger->info("final rename of temp Files for $localFile");
	if (defined $ftp) {
		$logger->debug("changing into folder $FTP->{remoteDir}");
		_setcwd(undef) if (substr($FTP->{remoteDir},0,1) eq "/"); # starting / means start from home...
		my $remoteDir = (substr($FTP->{remoteDir},0,1) eq "/" ? substr($FTP->{remoteDir},1) : $FTP->{remoteDir});
		if (_setcwd($remoteDir)) {
			if ($ftp->rename("temp.".$localFile,$localFile)) {
				$logger->debug("temporary file ${remoteDir}/temp.$localFile renamed to $localFile");
			} else {
				$logger->error("error: can't rename remote-file ${remoteDir}/temp.$localFile to $localFile, reason:"._error());
				return 0;
			}
		} else {
			$logger->error("can't change into remote-directory ${remoteDir}, reason: "._error());
			return 0;
		}
	} else {
		$logger->error("no ftp connection opened!");
		return 0;
	}
	return 1;
}

# move remote files being in a remote directory into the archive directory (relative to remote directory only if glob) or delete them
sub archiveFiles ($) {
	my ($param) = @_;
	my $logger = get_logger();
	my @filesToArchive = @{$param->{filesToArchive}} if $param->{filesToArchive};
	my $archiveTimestamp = $param->{timestamp};
	$archiveTimestamp = get_curdatetime()."." if !defined($param->{timestamp});
	if (defined $ftp and @filesToArchive) {
		$logger->info("archiving files @filesToArchive");
		$logger->debug("changing into ".$param->{remoteDir});
		_setcwd(undef) if (substr($param->{remoteDir},0,1) eq "/"); # starting / means start from home...
		my $remoteDir = (substr($param->{remoteDir},0,1) eq "/" ? substr($param->{remoteDir},1) : $param->{remoteDir});
		my $archiveDir = ((substr($param->{archiveDir},-1) eq "/" or $param->{archiveDir} eq "") ? $param->{archiveDir} : $param->{archiveDir}."/");
		if (_setcwd($remoteDir)) {
			for my $remoteFile (@filesToArchive) {
				$logger->debug("moving $remoteFile to $archiveDir");
				if ($remoteFile =~ /\*/) { # if glob character contained, then move multiple files
					my @remoteFiles = $ftp->glob($remoteFile, names_only => 1);
					for my $specFile (@remoteFiles) {
						# $specFile is a relative path to current folder (being $remoteDir, the names_only => 1 doesn't help here)
						my ($specFilePathOnly, $specFileNameOnly) = ($specFile =~ /^(.*\/)(.*?)$/);
						$specFileNameOnly = $specFile if $specFileNameOnly eq "";
						if ($ftp->rename($specFile,$specFilePathOnly.$archiveDir.$archiveTimestamp.$specFileNameOnly)) {
							$logger->debug("remote-file $specFile archived to $specFilePathOnly$archiveDir$archiveTimestamp$specFileNameOnly");
						} else {
							my $errmsg = _error();
							$logger->error("error: can't rename remote-file $specFile to $specFilePathOnly$archiveDir$archiveTimestamp$specFileNameOnly, reason: $errmsg") if $errmsg !~ /No such file or directory/;
							$logger->warn("error: $errmsg") if $errmsg =~ /No such file or directory/;
						}
					}
				} else {
					if ($ftp->rename($remoteFile,$archiveDir.$archiveTimestamp.$remoteFile)) {
						$logger->debug("remote-file $remoteDir/$remoteFile archived to $archiveDir$archiveTimestamp$remoteFile");
					} else {
						my $errmsg = _error();
						$logger->error("error: can't rename remote-file $remoteDir/$remoteFile to $archiveDir$archiveTimestamp$remoteFile, reason: $errmsg") if $errmsg !~ /No such file or directory/;
						$logger->warn("error: $errmsg") if $errmsg =~ /No such file or directory/;
					}
				}
			}
		} else {
			$logger->error("can't change into remote-directory ${remoteDir}, reason: "._error());
		}
	} else {
		$logger->error("no ftp connection opened") unless $ftp;
		$logger->error("no files to archive given") unless @filesToArchive;
		return 0;
	}
	return 1;
}

# delete remote files
sub removeFiles ($) {
	my ($param) = @_;
	my $logger = get_logger();
	my @filesToRemove = @{$param->{filesToRemove}} if $param->{filesToRemove};
	if (defined $ftp and @filesToRemove) {
		$logger->info("removing files @filesToRemove");
		$logger->debug("changing into ".$param->{remoteDir});
		_setcwd(undef) if (substr($param->{remoteDir},0,1) eq "/"); # starting / means start from home...
		my $remoteDir = (substr($param->{remoteDir},0,1) eq "/" ? substr($param->{remoteDir},1) : $param->{remoteDir});
		if (_setcwd($remoteDir)) {
			for my $remoteFile (@filesToRemove) {
				if (_remove($remoteFile)) {
					$logger->debug("removed remote-file $remoteFile");
				} else {
					my $errmsg = _error();
					$logger->error("error: can't remove remote-file $remoteFile, reason: $errmsg") if $errmsg !~ /no such file/i;
					$logger->warn("error: can't remove remote-file $remoteFile, reason: $errmsg") if $errmsg =~ /no such file/i;
				}
			}
		} else {
			$logger->error("can't change into remote-directory $remoteDir, reason: "._error());
		}
	} else {
		$logger->error("no ftp connection opened") unless $ftp;
		$logger->error("no files to remove given") unless @filesToRemove;
		return 0;
	}
	return 1;
}

# login, creating a new ftp connection
sub login ($$) {
	my ($FTP,$setRemoteHost) = @_;
	my $logger = get_logger();
	$setRemoteHost = "" if !defined($setRemoteHost);
	if ($RemoteHost ne $setRemoteHost or !defined($ftp)) {
		$RemoteHost = $setRemoteHost;
		undef $ftp if defined($ftp); # close ftp connection if open.
	} else {
		$logger->debug("ftp connection already open, using $RemoteHost");
		return 1;
	}
	(!$RemoteHost) and do {
		$logger->error("no existing connection and remote host not set in \$setRemoteHost for new connection");
		return 0;
	};
	my $maxConnectionTries = $FTP->{maxConnectionTries};
	# for unstable connections, retry connecting max $maxConnectionTries.
	my $connectionTries = 0;
	# quote passwords containing chars that can't be passed via windows shell to ssh_cmd (\"....\>...\")
	my $pwd = $FTP->{pwd};
	if ($^O =~ /MSWin/ and !$FTP->{dontUseQuoteSystemForPwd}) {
		$pwd = Win32::ShellQuote::quote_system($pwd) if ($pwd and $pwd =~ /[()"<>&]/);
	}
	my $debugLevel = $FTP->{FTPdebugLevel};
	if (defined($FTP->{hostkey}) || defined($FTP->{privKey}) || $FTP->{SFTP}) {
		if (!$FTP->{sshInstallationPath}) {
			$logger->error("no \$FTP->{sshInstallationPath} defined!");
			return 0;
		}
		if (!defined($FTP->{pwd}) and !$FTP->{privKey}) {
			$logger->error("neither \$FTP->{pwd} nor \$FTP->{privKey} defined!");
			return 0;
		}
		$logger->info("connecting to $RemoteHost using SFTP");
		$logger->debug("FTP parameters:".Dumper($FTP));
		my @moreparams;
		push @moreparams, ("-hostkey", $FTP->{hostkey}) if $FTP->{hostkey};
		push @moreparams, ("-i", $FTP->{privKey}) if $FTP->{privKey};
		push @moreparams, ("-v", "") if $debugLevel;
		push @moreparams, @{$FTP->{moreparams}} if $FTP->{moreparams} and ref($FTP->{moreparams}) eq "ARRAY";
		push @moreparams, %{$FTP->{moreparams}} if $FTP->{moreparams} and ref($FTP->{moreparams}) eq "HASH";
		do {
			$logger->debug("connection try: $connectionTries");
			my $ssherr = File::Temp::tempfile() or $logger->error("couldn't open temp file for ftperrlog");
			# separate setting of debug level, additional to "-v" verbose
			$Net::SFTP::Foreign::debug = $debugLevel;
			no warnings 'Net::SFTP::Foreign'; # suppress warning on using insecure password authentication with plink
			$ftp = Net::SFTP::Foreign->new(
				host => $RemoteHost,
				user => $FTP->{user},
				password => $pwd,
				port => ($FTP->{port} ? $FTP->{port} : '22'),
				ssh_cmd => $FTP->{sshInstallationPath},
				more => \@moreparams,
				stderr_fh => $ssherr
			);
			$connectionTries++;
			$ftp->error and do {
				$logger->warn("connection failed: ".$ftp->error.", output from Net::SFTP::Foreign:");
				seek($ssherr, 0, 0);
				$logger->warn($_) while (<$ssherr>);
				close($ssherr);
				# after first failure set full debug ...
				if ($connectionTries == 1) {
					$logger->warn("first call to Net::SFTP::Foreign->new failed, redoing with full debug..");
					$debugLevel = -1;
				} else {
					$debugLevel = $FTP->{FTPdebugLevel};
				}
			};
		} until (!$ftp->error or $connectionTries == $maxConnectionTries);
		if ($connectionTries == $maxConnectionTries and $ftp->error) {
			$logger->error("connection finally failed after $maxConnectionTries connection tries: ".$ftp->error);
			undef $ftp;
			return 0;
		}
	} else {
		$logger->info("connecting to $RemoteHost using FTP (neither defined \$FTP->{hostkey} nor defined \$FTP->{privKey} nor set \$FTP->{SFTP})");
		$logger->debug("FTP parameters:".Dumper($FTP));
		my $connectionTries = 0; my $loginSuccess;
		do {
			$ftp = Net::FTP->new($RemoteHost,Debug => $FTP->{FTPdebugLevel}, Port => ($FTP->{port} ? $FTP->{port} : '21'));
			if (! defined($ftp)) {
				$logger->error("connection to ".$RemoteHost." failed, reason: $@ $!");
				undef $ftp;
				return 0;
			}
			$loginSuccess = $ftp->login($FTP->{user},$FTP->{pwd});
			if (!$loginSuccess) { 
				$logger->error("login failed, reason: ".$ftp->message);
				undef $ftp;
				return 0;
			}
			$connectionTries++;
		} until ($loginSuccess or $connectionTries == $maxConnectionTries);
		if ($connectionTries == $maxConnectionTries and !$loginSuccess) {
			$logger->error("connection finally failed after $maxConnectionTries connection tries: ".$ftp->message);
			undef $ftp;
			return 0;
		}
		if (defined($FTP->{translationtype}) and $FTP->{translationtype} eq "A") {
			if (!$$ftp->ascii()) {
				$logger->error("can't switch to ascii, reason: ".$ftp->message);
				undef $ftp;
				return 0;
			}
		} else {
			if (!$$ftp->binary()) {
				$logger->error("can't switch to binary, reason: ".$ftp->message);
				undef $ftp;
				return 0;
			}
		}
	}
	$logger->info("login successful, ftp connection established");
	return 1;
}

# set handle with externally created Net::FTP or Net::SFTP::Foreign handle (if EAI::FTP::login capabilities are not sufficient)
sub setHandle ($;$) {
	my ($handle,$rhost) = @_;
	my $logger = get_logger();
	eval {
		die "neither Net::SFTP::Foreign nor Net::FTP handle passed to setHandle, argument is '".(defined($handle) ? ref($handle) : "undefined")."'" unless $handle && blessed $handle && ($handle->isa('Net::SFTP::Foreign') or $handle->isa('Net::FTP')) ;
		$ftp = $handle;
		$RemoteHost = $rhost;
	};
	if ($@) {
		$logger->error($@);
		return 0;
	} else {
		return 1;
	}
}

# used to get the raw ftp handler, mainly for testability
sub getHandle {
	return ($ftp, $RemoteHost);
}
1;

__END__

=head1 NAME

EAI::FTP - wrapper for Net::SFTP::Foreign and Net::FTP

=head1 SYNOPSIS

 removeFilesOlderX ($FTP)
 fetchFiles ($FTP,$param)
 putFile ($FTP,$param)
 moveTempFile ($FTP,$param)
 archiveFiles ($FTP,$param)
 login ($FTP,$setRemoteHost)
 setHandle ($handle,$remoteHost)
 getHandle

=head1 DESCRIPTION

EAI::FTP contains all (secure) FTP related API-calls. This is for logging in to a FTP Server, getting files from a remote folder, writing files to a remote folder, archiving/deleting files from/on a remote folder (to an archive folder) and removing files on an FTP server being older than a Date X.

=head2 API

=over

=item removeFilesOlderX

remove files on FTP server being older than a time back (given in remove)

 $param .. ref to hash with function parameters:
 $param->{remove}{removeFolders} .. list of folders where files should be removed
 $param->{remove}{day} .. days back to remove
 $param->{remove}{mon} .. months back to remove
 $param->{remove}{year} .. years back to remove
 $param->{remoteDir} .. remote directory where files are located

returns 1 if ALL files were removed successfully, 0 on error (doesn't exit early)

=item fetchFiles

fetch files from FTP server

 $param .. ref to hash with function parameters:
 $param->{fileToRetrieve} .. file to retrieve. if a glob (*) is contained, then multiple files are retrieved
 $param->{fileToRetrieveOptional} .. flag that file is optional
 $param->{firstRunSuccess} .. used to suppress fetching errors (if first run was already successful)
 $param->{homedir} .. standard storage path
 $param->{retrievedFiles} .. returned array with retrieved file (or files if glob was given)
 
additionally following parameters from $FTP are important

 $FTP->{queue_size} .. queue_size for Net::SFTP::Foreign, if > 1 this causes often connection issues
 $FTP->{remoteDir} .. remote directory where files are located
 $FTP->{path} .. path of folder of file below remoteDir
 $FTP->{localDir} .. alternative storage path, if not given then files are stored to
 $FTP->{fileToRemove} .. ignore errors for a file that was either removed or is optional 
 $FTP->{dontDoUtime} .. don't set time stamp of local file to that of remote file

returns 1 if ALL files were fetched successfully, 0 on error (doesn't exit early)

=item putFile

put file to FTP server

The file is written either directly ($FTP->{dontUseTempFile} 1) or as temp.<name> file ($FTP->{dontUseTempFile} = 0 or not set),
these temp files are immediately renamed on the server (if $FTP->{dontMoveTempImmediately} = 0 or not set),
when $FTP->{dontMoveTempImmediately} =1 then this waits until moveTempFile is called. This is needed to have an atomic transaction for file monitoring jobs on the FTP site!
when $FTP->{dontDoSetStat} is set for Net::SFTP::Foreign handles, no setting of time stamp of remote file to that of local file is done (avoid error messages of FTP Server if it doesn't support this)

 $param .. ref to hash with function parameters:
 $param->{fileToWrite} .. file to upload. this has to exist in local folder
 $param->{remoteDir} .. remote directory where files are located

returns 1 if ALL files were written successfully, 0 on error (exits on first error !)

=item moveTempFile

separately rename temp file on FTP Server to final name (atomic transaction !)

 $param .. ref to hash with function parameters:
 $param->{fileToWrite} ..  file to rename from temp to final
 $param->{remoteDir} .. remote directory where files are located
 
returns 1 if ALL files were renamed successfully, 0 on error (exits on first error !)

=item archiveFiles

archive files on FTP server, given in $param->{filesToArchive}

 $param .. ref to hash with function parameters:
 $param->{filesToArchive} .. ref to array with files to be archived if a glob is given, it is being resolved and all retrieved files are archived separately
 $param->{timestamp} .. timestamp to prepend to file, if undef this is done with the current datetime (YYYYMMDD_hhmmss)
 $param->{remoteDir} .. remote directory where files are located
 $param->{archiveDir} .. folder for archived files on the FTP server

returns 1 if ALL files were archived successfully, 0 on error (doesn't exit early), except for "No such file or directory" errors, only warning is logged here

=item removeFiles

delete files on FTP server, given in $param->{filesToRemove}

 $param .. ref to hash with function parameters:
 $param->{filesToRemove} .. ref to array with files to be deleted
 $param->{remoteDir} .. remote directory where files are located

returns 1 if ALL files were deleted successfully, 0 on error (doesn't exit early), except for "No such file or directory" errors, only warning is logged here

=item login

log in to FTP server, stores the handle of the ftp connection

 $FTP .. ref to hash with function parameters:
 $FTP->{maxConnectionTries} ..  maximum number of tries for connecting in login procedure
 $FTP->{sshInstallationPath} .. path were ssh/plink exe to be used by Net::SFTP::Foreign is located
 $FTP->{user} .. for setting user directly
 $FTP->{pwd} .. for setting password directly
 $FTP->{dontUseQuoteSystemForPwd} .. for windows, a special quoting is used for passing passwords to Net::SFTP::Foreign that contain [()"<>& . This flag can be used to disable this quoting.
 $FTP->{FTPdebugLevel} .. debug sftp:  0||~(1|2|4|8|16|1024|2048) for Net::SFTP:Foreign or 0||1 for Net::FTP, loglevel automatically set to debug for module EAI::FTP if FTPdebugLevel > 0
 $FTP->{hostkey} .. hostkey to present to the server for Net::SFTP::Foreign, either directly (insecure -> visible) or via sensitive lookup
 $FTP->{privKey} .. sftp key file location for Net::SFTP::Foreign, either directly (insecure -> visible) or via sensitive lookup
 $FTP->{port} .. ftp/sftp port (leave empty for default ports 22 or 21)
 $FTP->{SFTP} .. to explicitly use SFTP, if not given SFTP will be derived from existence of privKey or hostkey. If neither exists, an FTP connection will be opened.
 $setRemoteHost .. remote host to be set

returns 1 if login was successful, 0 on error

=item setHandle

sets externally created Net::SFTP:Foreign or Net::FTP handle to be further used by EAI::FTP. Additionally the RemoteHost used in the handle can be passed (used for calls to login)

 $handle .. ref to handle
 $remoteHost .. remote Host

=item getHandle

returns the net-sftp-foreign/ftp handler and the RemoteHost string to allow direct commands with the handler

=back

=head1 COPYRIGHT

Copyright (c) 2023 Roland Kapl

All rights reserved.  This program is free software; you can
redistribute it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the LICENSE file included
with this module.

=cut