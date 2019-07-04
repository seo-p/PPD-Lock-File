=head1 SUMMARY

Unit Test File for PPD::Lock::File
since 2015/10/02 by seo

=head1 USAGE

case1:
$ cd <here>
$ perl -I../lib <this_script_name>

case2
$ cd <parent dir>
$ prove -lc t/lib-PPD-Lock-File.pm.t

# l: Add 'lib' to the path for your tests (-Ilib).
# c: Colored test output (default).

=cut

use strict;
use warnings;

use Test::More tests	=> 5;
use Test::Exception;
use Test::SharedFork;	# for fork() in Test but not core module
use File::Spec;
use Path::Class;

use POSIX ":sys_wait_h";    # for WNOHANG
use Time::HiRes qw(usleep); # for usleep()
use Data::Dumper;
$Data::Dumper::Terse = 1;

use PPD::Lock::File;

main();

exit;

sub main
{
	my $fail = 0;

	my %attr = ();
	$attr{directory} = dir($ENV{LOCK_DIR})->resolve if( exists $ENV{LOCK_DIR} );
	
	# 最も基本的なロックストーリー
	subtest '01:Basic' => sub
	{
		use_ok('PPD::Lock::File');

	    my $lockFile	 = PPD::Lock::File->new( \%attr );
		
	    $fail ++ unless ok ($lockFile ,'Get 1st instance');
		
		unless( ok ($lockFile->getLock() ,'1st instance succeed get lock.') )
		{
			diag 'BECAUSE:'.$lockFile->because;
			$fail ++;
		}
		
		my $lockFile2 	= PPD::Lock::File->new( \%attr );
		$fail ++ unless ok ($lockFile2 ,'Get 2nd instance');
		
		$fail ++ unless ok ( ! $lockFile2->getLock() ,'2nd instance must fail get lock.'); # $lockFile がロックされているのでロック出来てはいけない。
		
		unless( ok( $lockFile->unlock() ,'unlock 1st. No problem even so faild.') ) # unlock は失敗しても構わないが、このテストのシーケンスでは成功する。
		{
			diag 'BECAUSE:'.$lockFile2->because;
			$fail ++;
		}
		unless( ok ( $lockFile2->getLock() ,'2nd instance get lock after 1st is unlocked.'))
		{
			diag 'BECAUSE:'.$lockFile2->because;
			$fail ++;
		}
	};
	
	# デストラクタで自動アンロックするテスト
	subtest '02:Unlock at destructor' => sub
	{
		SKIP:
		{
			skip 'Because forward tests not passed.' ,0 if( $fail );
			
			my $lockFile2 	= PPD::Lock::File->new( \%attr );
			{
				my $lockFile	 = PPD::Lock::File->new( \%attr );
				$fail ++ unless ok ($lockFile->getLock() ,'instance succeed get lock.');
			}
			
			$fail ++ unless ok ( $lockFile2->getLock() ,'2nd instance get lock succeed.');
		}
		
	};
	
	# デストラクタでアンロックしない && デッドロック解除テスト
	subtest  '03:Cancel dead lock' => sub
	{
		# PID が同じ場合強制アンロックできないため､子プロセスでロックしっぱなし状態を作成します。
		my $childPID = fork();
		if( $childPID )
		{
			# parent process
			waitpid $childPID,0;
			
			my $lockFile2 	= PPD::Lock::File->new( \%attr );
			$fail ++ unless ok( $lockFile2->isLockFileExists , 'parent check lock file exists' );
			$fail ++ unless ok( $lockFile2->getLock , 'parent getlock' );
			
		}
		elsif(! defined $childPID)
		{
			$fail ++ unless ok(undef,"Fork failed. ".$! );
		}
		else
		{
			# 子プロセス
			# ロックした状態を作成して終了します。
			my %copied = ( %attr , 'unlock_on_destructor'=> 0 );
			my $lockFile	 = PPD::Lock::File->new( \%copied );

			$fail ++ unless ok( $lockFile ,'Get 1st instance');
			$fail ++ unless ok( $lockFile->getLock() ,'getLock succeed.');
			
			diag Dumper( {'$lockFile->{locked}' => $lockFile->{'locked'}.''});
			
			exit;
		}
	};
	
	# 様々なコンストラクタオプション
	subtest '04:Various constructor' => sub
	{
		# $PPD::Lock::File::DEBUG_LOG = 1;
		
		diag "Lock with custom extention.";
		
		my $customExt = '.lck';
		
		my $keyword = "rock file name";
		my %copied_attr = ( %attr , kConfigKey_extention => $customExt );
		my $lock1 = PPD::Lock::File->new( $keyword , \%copied_attr );
		$fail ++ unless ok($lock1 , 'construct $lock1');
		
		my $lock2 = PPD::Lock::File->new( $keyword ,\%copied_attr );
		$fail ++ unless ok($lock2 , 'construct $lock2 using custom extention.');
		
		unless( ok($lock1->getLock , "lock 1 getLock") )
		{
			diag 'ref $lock1='.(ref $lock1);
			diag '$lock1->{baseFile}='.$lock1->{'baseFile'};
			diag 'BECAUSE:'.$lock1->because;
			diag $lock1->dumpStat;
			
			$fail ++
		}
		
		$fail ++ unless ok(! $lock2->getLock , "lock 2 fail getLock, because lock1 locked.");
		
		diag 'lock 1 unlock:'.$lock1->unlock;
		
		$fail ++ unless ok( $lock2->getLock , "lock 2 getLock after lock1 unlock.");
		
		my $isLockedExists = $lock2->isLockFileExists;
		$fail ++ unless ok($isLockedExists , 'exsits lock file' );
		
		my $locked = $lock2->locked;
		
		my $matchStr = $lock2->{baseFile}.$customExt;
		
		$fail ++ unless ok( $locked =~ /\Q$matchStr\E/,'check custom extention used. '.$locked );
		
		$lock2->unlock;
		
		# new(\%config) 方式は '03:Cancel dead lock' で使用されているため省略
	};
	
	# $fail++; # for skip stress test
	
	# マルチプロセスで無防備な read/write を行い､排他制御できているかテストします。
	subtest '99:Stress Test' => sub 
	{
		SKIP:
		{
			skip 'Because Basic tests not passed.' ,0 if($fail);
			
			my $testNum = 1000;
			my $maxFork = 6;
			my @queue = ();
			
			diag "Count up $testNum times with parallel $maxFork process.";
			
			my $counterFile = file( File::Spec->tmpdir() ,'ppd-lock-file-test' );
			$counterFile->remove;
			$counterFile->touch;
			
			diag " >> count file $counterFile";
			
			my $testCounter = $testNum;
			while( $testCounter )
			{
				my $pid = fork();
				
				if( $pid )
				{
					# parent process
					my $colNum = $ENV{'COLUMNS'} || 80;
					print "\x1B[".$colNum."D";
					print "\x1B[0K";
					printf "Fork process %d was established.",$testNum - $testCounter + 1;
					
					$testCounter --;
					push @queue,$pid;
					
					while( scalar(@queue) >= $maxFork )
					{
						usleep(0.1 * 1000);
						
						for my $pid ( @queue )
						{
							my $terminatedPID = waitpid( $pid ,WNOHANG );
							
							@queue = grep { $_ != $terminatedPID } @queue;
							last if( scalar(@queue) < $maxFork );
						}
					}
					
					next;
				}
				elsif(! defined $pid)
				{
					warn "Fork failed. ".$!;
					usleep(0.1 * 1000);
					next;
				}
				else
				{
					# child process
					# ロックが取得できたら flock 無しで read -> close -> インクリメント -> write -> close します。
					# $PPD::Lock::File::DEBUG_LOG = 1;
					my $lockFile	 = PPD::Lock::File->new( \%attr );
					
					while( 1 )
					{
						if( $lockFile->getLock() )
						{
							my $rd = undef;
							my $wt = undef;
							
							if( ! open( $rd ,'<',$counterFile->stringify ))
							{
								die $! ." < $counterFile";
							}
							
							my $cnt = <$rd>;
							close $rd;
							
							$cnt = 0 if(! $cnt );
							$cnt ++;
							
							if( ! open($wt,'>',$counterFile->stringify ))
							{
								die $!." > $counterFile";
							}
							print $wt $cnt;
							close $wt;
							
							$lockFile->unlock();
							last;
						}
					}
					
					exit;
				}
			}
			
			# 子プロセスがいなくなるまで待ちます。
			while( -1 != wait ){};
			
			my $fh = undef;
			if( open( $fh,'<',$counterFile->stringify) )
			{
				my $cnt = <$fh>;
				close $fh;
				
				diag "\n";
				diag '$cnt='.$cnt."\n";
				diag '$testNum='.$testNum."\n";
				
				is( $cnt , $testNum ,"$testNum == $cnt");
			}
			
		} # SKIP:
	};
	
	
	done_testing();
}
