# need to explicitly set environment and write our own site.config and log.config for testing
$ENV{EAI_WRAP_CONFIG_PATH} = "./t/config";
mkdir "./t/config";
open (LOGCONF, ">./t/config/log.config");
print LOGCONF "log4perl.rootLogger = ERROR, SCREEN\nlog4perl.appender.SCREEN=Log::Log4perl::Appender::Screen\nlog4perl.appender.SCREEN.layout = PatternLayout\nlog4perl.appender.SCREEN.layout.ConversionPattern = %d	%P	%p	%M-%L	%m%n\n";
close LOGCONF;
open (SITECONF, ">./t/config/site.config");
print SITECONF '%config = (folderEnvironmentMapping => {t => ""},logRootPath => {"" => ".",},historyFolder => {"" => "History",},historyFolderUpload => {"" => "HistoryUpload",},redoDir => {"" => "redo",},)';
close SITECONF;
Log::Log4perl::init("./t/config/log.config"); 
