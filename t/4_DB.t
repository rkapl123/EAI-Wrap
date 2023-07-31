# to use these testcases (only MS SQL server), create a database testDB in the local sql server instance where the current account has dbo rights (tables are created/dropped)
use strict; use warnings;
use EAI::DB; use Test::More; use Data::Dumper;

my $author = eval "no warnings; getlogin eq 'rolan'";
plan skip_all => "tests not automatic in non-author environment" if ($^O =~ /MSWin32/i and not $author);
use Test::More tests => 16;
require './setup.t';

newDBH({database => "testDB", DSN => 'driver={SQL Server};Server=.;database=$DB->{database};TrustedConnection=Yes;'}, {});
doInDB({doString => "DROP TABLE [dbo].[theTestTable];"});
my $createStmt = "CREATE TABLE [dbo].[theTestTable]([selDate] [datetime] NOT NULL,[ID0] [varchar](4) NOT NULL,[ID1] [bigint] NOT NULL,[ID2] [char](3) NOT NULL,[Number] [int] NOT NULL, [Amount] [decimal](28, 2) NOT NULL, CONSTRAINT [PK_theTestTable] PRIMARY KEY CLUSTERED (selDate ASC)) ON [PRIMARY]";
is(doInDB({doString => $createStmt}),1,'doInDB');
my $data = [{
             'selDate' => '20190618',
             'ID0' => 'ABCD',
             'ID1' => 5456,
			 'ID2' => 'ZYX',
			 'Number' => 1,
			 'Amount' => 123456.12
            },
            {
             'selDate' => '20190619',
             'ID0' => 'ABCD',
             'ID1' => 5856,
			 'ID2' => 'XYY',
			 'Number' => 1,
			 'Amount' => 65432.1
            },
           ];
# insert
is(storeInDB({tablename => "dbo.theTestTable", upsert=>0, primkey=>"selDate = ?"},$data),1,'storeInDB insert');
# upsert
is(storeInDB({tablename => "dbo.theTestTable", upsert=>1, primkey=>"selDate = ?"},$data),1,'storeInDB upsert');
# Syntax error
is(storeInDB({tablename => "dbo.theTestTable", upsert=>1, primkey=>"selDt = ?"},$data),0,'storeInDB error');
# duplicate error
is(storeInDB({tablename => "dbo.theTestTable", upsert=>0, primkey=>"selDate = ?"},$data,),0,'storeInDB duplicate error');

# Data error
$data = [{
             'selDate' => '20190620',
             'ID0' => 'ABCD_WayTooLongField',
             'ID1' => 5456,
			 'ID2' => 'XZY',
			 'Number' => 1,
			 'Amount' => 123456.12
            }
           ];
is(storeInDB({tablename => "dbo.theTestTable", upsert=>0, primkey=>"selDate = ?", debugKeyIndicator=>"selDate=? ID1=?"}, $data),0,'storeInDB Datenfehler');
# update in Database
my $upddata = {'20190618' => {
             'selDate' => '2019-06-18',
             'ID0' => 'ABCD',
             'ID1' => 5456,
			 'ID2' => 'ZYX',
			 'Number' => 2,
			 'Amount' => 123456789.12
           },
		   '20190619' => {
             'selDate' => '2019-06-19',
             'ID0' => 'ABCD',
             'ID1' => 5856,
			 'ID2' => 'XYZ',
			 'Number' => 1,
			 'Amount' => 65432.1
           },
         };
is(updateInDB({tablename => "dbo.theTestTable", keyfields=>["selDate"]},$upddata),1,'updateInDB');
my @columnnames;
my $query = "SELECT selDate,ID0,ID1,ID2,Number,Amount from dbo.theTestTable WHERE selDate = '20190619'";
my @result;
my $expected_result=[{Number=>1,ID0=>'ABCD',selDate=>'2019-06-19 00:00:00.000',Amount=>'65432.10',ID1=>'5856',ID2=>'XYZ'}];
readFromDB({query => $query, columnnames=>\@columnnames}, \@result);
is_deeply(\@result,$expected_result,"readFromDB");
is("@columnnames","selDate ID0 ID1 ID2 Number Amount","columnnames returned correctly from readFromDB");

my %result;
$expected_result={'2019-06-19 00:00:00.000'=>{Number=>1,ID0=>'ABCD',selDate=>'2019-06-19 00:00:00.000',Amount=>'65432.10',ID1=>'5856',ID2=>'XYZ'}};
readFromDBHash({query=>$query, keyfields=>["selDate"]}, \%result);
is_deeply(\%result,$expected_result,"readFromDBHash");

# return values in doInDB with parameters: returns ref to array of array, containing hash refs in retvals
my @retvals;
$expected_result=[[{ID0=>'ABCD',ID1=>'5456',Number=>2,ID2=>'ZYX',selDate=>'2019-06-18 00:00:00.000',Amount=>'123456789.12'}]];
doInDB({doString => "select * from [dbo].[theTestTable] where ID0 = ? AND ID1 = ? AND ID2 = ?", parameters => ['ABCD',5456,'ZYX']}, \@retvals);
is_deeply(\@retvals,$expected_result,"doInDB returned values");

# delete in Database
my $deldata = ['2019-06-18'];
$expected_result=[[{ID0=> 'ABCD',selDate=>'2019-06-19 00:00:00.000',Number=>1,Amount=>'65432.10',ID1=>'5856',ID2=>'XYZ'}]];
deleteFromDB({tablename => "dbo.theTestTable", keyfields=>["selDate"]},$deldata);
doInDB({doString => "select * from [dbo].[theTestTable]"}, \@retvals);
is_deeply(\@retvals,$expected_result,"deleteFromDB");

beginWork();
doInDB({doString => "update [dbo].[theTestTable] set ID1='9999' where selDate='2019-06-19'"}, \@retvals);
$expected_result=[{Number=>1,ID0=>'ABCD',selDate=>'2019-06-19 00:00:00.000',Amount=>'65432.10',ID1=>'9999',ID2=>'XYZ'}];
readFromDB({query => "select * from [dbo].[theTestTable]", columnnames=>\@columnnames}, \@retvals);
is_deeply(\@retvals,$expected_result,"transaction start");
commit();
$expected_result=[{Number=>1,ID0=>'ABCD',selDate=>'2019-06-19 00:00:00.000',Amount=>'65432.10',ID1=>'9999',ID2=>'XYZ'}];
readFromDB({query => "select * from [dbo].[theTestTable]", columnnames=>\@columnnames}, \@retvals);
is_deeply(\@retvals,$expected_result,"transaction commit");

beginWork();
doInDB({doString => "update [dbo].[theTestTable] set ID1='7777' where selDate='2019-06-19'"}, \@retvals);
$expected_result=[{Number=>1,ID0=>'ABCD',selDate=>'2019-06-19 00:00:00.000',Amount=>'65432.10',ID1=>'7777',ID2=>'XYZ'}];
readFromDB({query => "select * from [dbo].[theTestTable]", columnnames=>\@columnnames}, \@retvals);
is_deeply(\@retvals,$expected_result,"transaction start");
rollback();
$expected_result=[{Number=>1,ID0=>'ABCD',selDate=>'2019-06-19 00:00:00.000',Amount=>'65432.10',ID1=>'9999',ID2=>'XYZ'}];
readFromDB({query => "select * from [dbo].[theTestTable]", columnnames=>\@columnnames}, \@retvals);
is_deeply(\@retvals,$expected_result,"transaction rollback");

# cleanup
doInDB({doString => "DROP TABLE [dbo].[theTestTable]"});
unlink glob "*.config";

done_testing();