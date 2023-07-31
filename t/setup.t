# need to explicitly set environment and write our own site.config and log.config for testing
$ENV{EAI_WRAP_CONFIG_PATH} = ".";
open (LOGCONF, ">log.config");
print LOGCONF "log4perl.rootLogger = ERROR, SCREEN\nlog4perl.appender.SCREEN=Log::Log4perl::Appender::Screen\nlog4perl.appender.SCREEN.layout = PatternLayout\nlog4perl.appender.SCREEN.layout.ConversionPattern = %d	%P	%p	%M-%L	%m%n\n";
close LOGCONF;
open (SITECONF, ">site.config");
print SITECONF '%config = (folderEnvironmentMapping => {t => ""},logRootPath => {"" => ".",},historyFolder => {"" => "History",},historyFolderUpload => {"" => "HistoryUpload",},redoDir => {"" => "redo",},)';
close SITECONF;
Log::Log4perl::init("log.config"); 
