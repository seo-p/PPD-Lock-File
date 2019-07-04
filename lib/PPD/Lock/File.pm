=pod

=encoding utf8

=head1 NAME

PPD::Lock::File - ファイルベースの排他制御機構を提供するモジュール

=head1 PPD::Lock::File

ファイルベースのロック機構 == 排他制御機構を提供するモジュールです。

=head2 CONCEPT

ファイルシステムの rename がアトミックである事に強く依存した排他制御モジュールです。

これは A というファイルを複数のプロセスからそれぞれ別の名前(たとえば A.lock.10 ,A.lock.11 ,A.lock.12)に rename しようとするとき､どれか一つのプロセスしか rename に成功しないという条件が成立することに依存しています。

他､配列コンテキストでの readdir と Path::Class::Dir->children がコールされたタイミングのスナップショットである事にも依存しています。（`children` は IO::Dir 経由で tie_hash を利用しているようです）
この特性が弱い場合､高負荷状態での排他制御に失敗する場合があります。

=head2 Notes for Unlock Dead lock

デッドロックとなったロックファイルのアンロックの仕組みは簡単です。

ロックされたファイルにはファイル名にロックを行ったプロセスのIDが付与されています。

従って、あるプロセスがロックファイルを得ようと数秒試みて全て失敗した場合､以下のフローを経てロックを奪う様試みます。

1. ロックされたファイルを見つけ出す
2. そのプロセスの生存を確認
3. 生存していない場合､自分のロックファイルとして直接 rename を試みる
4. 失敗した場合はロック失敗

直接 rename するのは同じ事をしようとした別のプロセスから排他制御するためです。

デフォルトの設定ではデストラクタで unlcok を行います。
プロセスが kill された場合も通所はデストラクタもコールされます。
しかし、シグナル発生時は基本的にはプロセスの緊急事態ですのでロックしたまま終了してしまう可能性もあります。

現在ロックを取得したプロセスがゾンビプロセス化している場合などのデッドロックへの対処は実装していません。

=head2 USAGE

```perl
use File::Spec;
my $locker = PPD::Lock::File->new( $semaphoreKeyword,{'directory' => dir("/var/tmp") });

if( $locker->getLock() )
{
	#  handle exclusive processing.
	
	$locker->unlock();
}
else
{
	warn $locker->because();
}
```

=head2 TODO

- いわゆるサーバー常駐型の WbApp で利用する場合､プロセスIDが変わらない可能性があります。この場合デッドロックのアンロック方法で PID ベースから変更する必要があります。クラス変数+コンストラクタインクリメントなどで対応可能だと思われますが。未対応です。
- readonly 系のための共用ロックは未実装です。以前の実装(MFLOCK)では'.lock'への open + flock(1) に依存したWIN版のみの実装。おそらくファイルシステムの挙動に依存するため、調査が必要です。
- ロックファイルが要らなくなったとき削除する機構はありません。

=head2 Initialize Config

コンフィグはコンストラクタ呼び出し時に設定します。

```perl
PPD::Lock::File->new( \%configParams );
```

**SEE ALSO** "constant for config key", `new`

=cut

package PPD::Lock::File;

use strict;
use warnings;
use Carp;

use File::Path qw(make_path);
use Path::Class;

use Time::HiRes qw(gettimeofday tv_interval usleep);

use constant kLockFile_extention => '.lock';

our $VERSION='1.01';


=head2 Static & Constants

=head3 constant for config key

- kConfigKey_directory : ファイルシステムベースの排他制御処理を行うディレクトリを指定するためのキーです。指定が無かった場合File::Spec が返すテンポラリディレクトリ/PPDLockFile が設定されます。
- kConfigKey_touchAtConstructor : コンストラクタで排他制御用のファイルへの touch を行うかどうかを指定するためのキーです。デフォルトは 1 で通常変更する必要はありません。ロックを行わない可能性があり､ディレクトリをなるべくクリーンに保ちたい場合`偽`を設定すると役に立ちます。
- kConfigKey_extention : 排他制御、つまりロック時のファイル拡張子を指定するためのキーです。デフォルトは kLockFile_extention 値です。
- kConfigKey_unlockOnDestructor : デストラクタで自動的に unlock するかどうかを指定するためのキーです。デフォルトは 1 です。あえてロック状態を保ったままプロセスを終了したい場合などは`偽`を設定します。

=cut

use constant {
	 kConfigKey_directory			=> 'directory'
	,kConfigKey_touchAtConstructor	=> 'touch_at_constructor'
	,kConfigKey_extention			=> 'kConfigKey_extention'
	,kConfigKey_unlockOnDestructor	=> 'unlock_on_destructor'
};

=head3 kLockFile_configKeys - constant

コンフィグハッシュに使用出来るキーのリストを定義する定数です。

=cut

use constant kLockFile_configKeys => (	kConfigKey_directory
										,kConfigKey_touchAtConstructor
										,kConfigKey_extention
										,kConfigKey_unlockOnDestructor);

our $DEBUG_LOG = 0;

=head3 $defaultConfig

パッケージのデフォルトコンフィグです。

=cut

my $defaultConfig = 
{
	 kConfigKey_directory() => dir( File::Spec->tmpdir() ,dir('PPDLockFile') )
	,kConfigKey_touchAtConstructor() => 1
	,kConfigKey_extention()	=> kLockFile_extention()
	,kConfigKey_unlockOnDestructor() => 1
};

=head2 PRIVATE

=head3 $DEBUG_OUT->( @_ )

デバッグ出力用のプライベートメソッドです。

$PPD::Lock::File::DEBUG_LOG が真の時 warn と Data::Dumper を使ってメッセージを出力します。

=cut

my $DEBUG_OUT = sub
{
	return if(! $DEBUG_LOG);
	
	require Data::Dumper;
	Data::Dumper->import;
	$Data::Dumper::Terse = 1;
	
	warn sprintf("[%d]%s:%s - %s\n"
								,$$
								,(caller(1))[3]
								,(caller(1))[2]
								,Dumper(@_));
};


=head3 $getBaseFilePath->()

rename 元となるファイルへのフルパスを文字列で返します。

@code

my $str = $self->$getBaseFilePath();

@endcode

=cut

my $getBaseFilePath = sub
{
	my $self		= shift @_;
	
	return file( $self->configFor( kConfigKey_directory ),$self->{'baseFile'} )->stringify();
};

=head2 $genLockFilePath->()

rename 先、つまりロック済みファイルとなるファイルへのフルパス文字列をジェネレートして返します。

=cut

my $genLockFilePath = sub
{
	my $self		= shift @_;
	
	my $lockedName = sprintf("%s%s.%d.%d"	,$self->{'baseFile'}
											,$self->configFor( kConfigKey_extention )
											,$$
											,time());
	
	return file( $self->configFor( kConfigKey_directory ) ,$lockedName )->stringify();
	
};


=head2 $splitLockFilePath->( $lockedFilePath )

ロック済みのファイルパスを受け取り､basename,プロセスID,time
(今後Time::HiResに返る可能性もある)を取り出し､ハッシュに格納して返します。

=cut

my $splitLockFilePath = sub
{
	my $self = shift @_;
	my $lockedFilePath = shift @_;
	
	my $file = file($lockedFilePath);
	my $baseName = $file->basename;
	
	my $lockExtention = $self->configFor(kConfigKey_extention);
	my ( $pid , $time ) = $baseName =~ /\Q$lockExtention\E\.(\d+)\.(\d+\.{0,1}\d+)$/;
	
	$DEBUG_OUT->(
	{
		'$pid' => $pid
		,'$time'=> $time
		,'$lockedFilePath' => "$lockedFilePath"
		,'$baseName' => $baseName
	});
	
	return {
		basename	=> $baseName
		,pid		=> $pid		// -1
		,time		=> $time	// -1
	};
};

=head2 $touchLockFile->()

ロックファイルが存在しないとき､ロックファイルを `touch` します。

@return 動作未定義

=cut

my $touchLockFile = sub
{
	my $self = shift @_;
	
	my $touchFilePath = $self->$getBaseFilePath();
	if(-e $touchFilePath )
	{
		# コール頻度と効率の面から､ロック対象となるファイルが存在する場合優先して return します。
		return;
	}
	
	# ディレクトリが無い場合作成します。
	if( ! -e $self->configFor(kConfigKey_directory)->stringify )
	{
		make_path( $self->configFor(kConfigKey_directory)->stringify );
	}
	
	# ロック対象となるファイルの有無をチェックし、無ければ touch 処理を行います。
	if( ! $self->isLockTargetFileExists() )
	{
		my $TOUCH	= undef;
		if( open($TOUCH,'>>',$touchFilePath ) )	# [memo] '>>' はオープン時にトランケートや書き込み位置の変更を行わなず、ファイルがなければ作成する特徴を持ちます。
		{
			$DEBUG_OUT->({'$touchFilePath' => $touchFilePath });
			close $TOUCH;
		}
	}
};

=head2 CONSTRUCTOR

=head3 new

- `new()`
- `new( \%configParams )`
- `new( $keyword )`
- `new( $keyword ,\%configParams )`

@param `$keyword`		ロックに使用するキーワード == ファイル名です。
						ファイルシステムごとに許容される条件は異なるため､無難な文字列・文字数で使用することをお勧めします。
						指定が無い場合スクリプト名から自動生成されます。

@param `%configParams`	コンフィグ用ハッシュです。
						詳細は「constant for config key」の項を参照して下さい。 **SEE ALSO** "constant for config key"


コンフィグの指定が無ければデフォルト値が使用されます。デフォルト値は以下の通りです。

- ワークディレクトリ : File::Spec->tmpdir() . dir('PPDLockFile')
- デストラクタで unlock する
- コンストラクタでロックファイルを touch 処理する
- 拡張子 **SEE ALSO** `kLockFile_extention`

=cut

sub new
{
	my $class = shift @_;
	
	# ロックファイルのbasenameを決定します。
	my $fileName = undef;
	my $inputedConfig = undef;
	
	if( @_ )
	{
		if( ref $_[0] eq 'HASH' )
		{
			$inputedConfig = $_[0];
		}
		else
		{
			$fileName = shift @_;
			$inputedConfig = shift @_ if( @_ && ref $_[0] eq 'HASH');
		}
	}
	
	if( ! $fileName )
	{
		# デフォルトのロックファイル名をセットします。
		$fileName = sprintf("_%s_",$0);#,$$,Time::HiRes::gettimeofday());
	}
	
	if( $fileName =~ /[^\w\-\.]/ )
	{
		$fileName =~ s/([^\w\-\.])/'%'.unpack('H2', $1)/eg;
	}
	
	my $file = file( $fileName );
	die $! if(! $file );
	
	my %instanceConfig = %$defaultConfig;# デフォルトコンフィグをインスタンス用にコピーします。
	
	my $self = 
	{
		'__config' => \%instanceConfig
		,'baseFile' => $file
	};
	
 	bless $self,ref $class || $class;
	
	# 入力されたコンフィグハッシュがあればそれらでコンフィグを上書きします。
	if( ref $inputedConfig eq 'HASH' )
	{
		for my $key (keys %$inputedConfig)
		{
			$self->setConfigFor($key , $inputedConfig->{$key} );
		}
	}
	
	# 指定があれば touch します。
	if( $self->configFor( kConfigKey_touchAtConstructor ) )
	{
		$touchLockFile->( $self );
	}
	
	return $self;
}

sub DESTROY
{
	my $self = shift @_;
	
	if( $self->configFor( kConfigKey_unlockOnDestructor ) )
	{
		$self->unlock();
	}
}

=head2 METHODS

=head3 setConfigFor( $configKey , $configValue )

コンフィグパラメータのセッターメソッドです。
設定不可能なパラメータキーを受け取った場合､croak(= die) します。

@param $configKey		コンフィグパラメータキーを指定します。
@param $configValue		`$configKey` で指定したコンフィグパラメータキーの値を指定します。
@return	未定義

=cut

sub setConfigFor
{
	my $self	= shift @_;
	
	my $key		= shift @_;
	my $val		= shift @_;
	
	croak "Ivalid configkey ".$key if( ! grep{ $key eq $_} kLockFile_configKeys );
	
	if( $key eq kConfigKey_directory 
	 && ! ref $val )
	{
		$self->{'__config'}->{$key} = dir( $val );
	}
	else
	{
		$self->{'__config'}->{$key} = $val;
	}
	
}

=head3 configFor( $configKey )

コンフィグパラメータのゲッターメソッドです。

=cut

sub configFor
{
	my $self		= shift @_;	
	my $configKey	= shift @_;
	
	my $c = $self->{'__config'};
	
	if( exists $c->{$configKey} )
	{
		return $c->{$configKey};
	}
	
	return undef;
}


=head3 getLock()

ロックの取得を試みます。

=cut

sub getLock
{
	my $self = shift @_;
	
	$self->because('');
	
	if( $self->{'locked'} )
	{
		return 1;
	}
	
	# コンストラクタで touch していない場合 touch する
	if(! $self->configFor( kConfigKey_touchAtConstructor ) )
	{
		$self->$touchLockFile->();
	}
	
	my $renameFrom	= $self->$getBaseFilePath();
	my $renameTo	= $self->$genLockFilePath();
	
	$DEBUG_OUT->({'$renameFrom' => "$renameFrom",'$renameTo' => "$renameTo"});
	
	if( rename( $renameFrom , $renameTo ) )
	{
		$self->{'locked'} = $renameTo;

		$DEBUG_OUT->( { msg => "rename scceed from '$renameFrom' to '$renameTo'."} );
		return 1;
	}
	
	# ロック出来なかった場合でも､ロックしたプロセスが死んでいる場合、ロック取得を試みます。
	my $lockedFile = $self->isLockFileExists();
	if( $lockedFile )
	{
		$DEBUG_OUT->({'already locked' => "$lockedFile"});
		
		my $splited = $self->$splitLockFilePath($lockedFile);

		if( $splited->{pid} > 0			# 正しくプロセスIDが切り出せている
		 && $splited->{pid} != $$		# 自分自身ではない
		 && ! kill 0 ,$splited->{pid} )	# 対象プロセスは生存していない
		 {
			 if( rename( $lockedFile , $renameTo ) )
			 {
				 $DEBUG_OUT->({'force renameFrom' => "$lockedFile",'$renameTo' => "$renameTo"});
				 $self->{'locked'} = $renameTo;
	 			return 1;
			 }
			 else
			 {
				 # for debug
				  $self->because('fail rename '.$lockedFile.' to '.$renameTo.' because "'.$!.'".');
			 }
		 }
		 else
		 {
			# for debug
			my @becauses = ();
			if( $splited->{pid} <= 0 )
			{
				push @becauses , 'lock file pid <= 0';
			}
			if( $splited->{pid} != $$ )
			{
				push @becauses ,'lock file pid != $$'."($$)";
			}
			
			if( ! kill 0 ,$splited->{pid} )
			{
				push @becauses , 'kill 0,'.$splited->{pid}.' returns positive value.';
			}

			if( @becauses )
			{
				unshift @becauses ,'$splited->{pid} : '.$splited->{pid};
				$self->because( join("\n", map {$_ = "- $_"} @becauses ));
			}
		 }
	}
	
	return undef;
}

=head3 because([$message])

public method for debug

getLock や unlock などが失敗したとき､直前の原因メッセージを set/get するためのメソッドです。
引数無しでコールすると gtter として動き､引数がある場合 setter として動作します。

基本的には簡易デバッグの目的で作られたもので､必ずエラーメッセージを得られることを保証するものではありません。

=cut

my $becauseMsg = '';

sub because
{
	my $self = shift @_;
	
	if( @_ )
	{
		$becauseMsg = shift @_;
	}
	else
	{
		return $becauseMsg;
	}
}

=head3 unlock()

ロックしたファイルがあればアンロックします。

@return 基本的には rename 動作に倣い､成功時:真/失敗時：偽を返します。
		従ってロックしていない場合や、ロックファイルが存在しない場合 rename は成功しないので偽を返します。

=cut

sub unlock
{
	my $self = shift @_;
	
	if( ! $self->{'locked'} 
	 || ! -e $self->{'locked'} )
	{
		my $initializedVar = $self->{'locked'} // '';	# avoid warn "Use of uninitialized ..."
		$self->because('my locked"'.$initializedVar .'" is empty or not exists.');
		return 0;
	}
	
	if( rename( $self->{'locked'} ,$self->$getBaseFilePath() ) )
	{
		$DEBUG_OUT->({msg => "Unlock $self->{'locked'} to ".$self->$getBaseFilePath() });

		$self->{'locked'} = undef;
		return 1;
	}
	else
	{
		$self->because('fail to rename "'.$self->{'locked'}.'" to "'.$self->$getBaseFilePath().'"');
		return 0;
	}
}

=head3 isLockTargetFileExists()

排他制御に用いる目的のファイルがロックされているのか存在しないのかをチェックします。
ロックされているかどうかにかかわらず存在しているとき真を返します。

=cut

sub isLockTargetFileExists
{
	my $self = shift @_;
	
	my $searchDir	= ''.$self->configFor( kConfigKey_directory );
	my $baseFilePath = $self->$getBaseFilePath();
	my $basename		= ''.$self->{'baseFile'};
	my $lockExtention	= $self->configFor(kConfigKey_extention);
	
	return 1 if( -e $baseFilePath );
	return 1 if( $self->{'locked'} );
	
	my $dh;
	if( ! opendir($dh ,$searchDir ) )
	{
		return undef;
	}
	
	my @found = grep {$_ =~ /^\Q$basename\E(?:\Q$lockExtention\E.+){0,1}$/} readdir $dh;# 最適化オプション`o`を付けると変なマッチの仕方する @ perl v5.18.2 on Mac
	closedir $dh;
	
	if( @found )
	{
		$DEBUG_OUT->(
		{
			'@found' => \@found 
			,'$self->{baseFile}' => $self->{'baseFile'}.''
			,'$lockExtention' => $lockExtention
		});
		
		return shift @found || 1;
	}
	
	return undef;
}


=head2 isLockFileExists()

ロックされたファイルがあるのかどうかを調べ、ロックされたファイルがあるならばそのファイルパスを返します。

ロックされる前のファイルが存在する場合 0 を返しますが、事前に -e テストを行うべきでしょう。
ディレクトリが存在しないなどロック済み/ロック対象ファイルが存在し得ない場合 undef を返します。

=cut


sub isLockFileExists
{
	my $self		= shift @_;
	
	return 1 if($self->{'locked'});
	
	my $basename	= $self->{'baseFile'}.'';	# `.''` is for stringify if Path::Class object
	my $searchDir	= $self->configFor( kConfigKey_directory );
	
	if(! -e $searchDir )
	{
		return undef;
	}
	
	if(-e $self->$getBaseFilePath() )
	{
		return 0;
	}
	
	# quotemeta
	my $lockExtention = quotemeta $self->configFor(kConfigKey_extention);
	my $quotedBasename = quotemeta $basename;
	
	$searchDir = dir($searchDir) if( ! ref $searchDir );
	my @children = grep {$_->basename =~ /^$quotedBasename(?:$lockExtention.+){0,1}$/} $searchDir->children;
	if( @children )
	{
		if( scalar(@children) > 1 )
		{
			warn "[$$] WARN: exisits several lockfile : ".join(" , ", @children );
			if( $DEBUG_LOG )
			{
				opendir(my $dh , "$searchDir" );
				my @items = readdir $dh;
				closedir $dh;
				$DEBUG_OUT->({ '$searchDir' => "$searchDir" ,'dir list' => \@items });
			}
			
		}
		
		return shift @children;
	}
	
	$DEBUG_OUT->({ '$basename' => $basename
				,'$lockExtention' => $lockExtention
				,'$searchDir'	=> $searchDir.''
			});
	
	return undef;
}

=head2 locked()

$self->{'locked'} へのインスタントアクセサメソッドです。

=cut

sub locked
{
	return $_[0]->{'locked'};
}

=head2 dumpStat()

デバッグ向け情報を返すメソッドです。
コンフィグ情報の他､ private メソッドでしか取得できない情報などをダンプ済み文字列で返します。

=cut

sub dumpStat
{
	my $self = shift @_;
	
	no warnings 'once';
	
	require Data::Dumper;
	Data::Dumper->import;
	$Data::Dumper::Terse = 1;
	$Data::Dumper::Sortkeys = 1;
	
	my $dump = Dumper(
	{
		'__config' => $self->{'__config'}
		,'baseFile' => $self->{'baseFile'}
		,'$getBaseFilePath' => $self->$getBaseFilePath()
		,'locked' => $self->{'locked'} // ''
	});
	
	return $dump;
}

1;
