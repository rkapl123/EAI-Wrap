echo Toprow this is skipped > test.txt
echo ID1	ID2	Name	Number >> test.txt
echo 123	312	First1	234234.23 >> test.txt
echo 345	534	Second2	345345.12 >> test.txt
copy test.txt %HOMEPATH%
perl.exe test.pl
pause