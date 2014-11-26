use strict;
use warnings;
package AnyEvent::Proc;
# ABSTRACT: Run external commands

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Util ();
use Try::Tiny;
use POSIX;

our $VERSION = '0.1.0'; # VERSION


sub _rpipe(&) {
	my $on_eof = shift;
	my ($R, $W) = AnyEvent::Util::portable_pipe;
	my $cv = AE::cv;
	(
		$R,
		AnyEvent::Handle->new(
			fh => $W,
			on_error => sub {
				my ($handle, $fatal, $message) = @_;
				AE::log warn => "error writing to handle: $message";
				$cv->send($message);
			},
			on_eof => $on_eof,
		),
		$cv,
	);
}

sub _wpipe(&) {
	my $on_eof = shift;
	my ($R, $W) = AnyEvent::Util::portable_pipe;
	my $cv = AE::cv;
	(
		AnyEvent::Handle->new(
			fh => $R,
			on_error => sub {
				my ($handle, $fatal, $message) = @_;
				AE::log warn => "error reading from handle: $message";
				$cv->send($message);
			},
			on_eof => $on_eof,
		),
		$W,
		$cv,
	);
}

sub _reaper {
	my $waiters = shift;
	sub {
		# my $message = shift; # currently unused
		foreach (@$waiters) {
			if (ref $_ eq 'CODE') {
				$_->(undef);
			} elsif (ref $_ eq 'AnyEvent::CondVar') {
				$_->send(undef);
			} elsif (ref $_ eq 'Coro::Channel') {
				$_->shutdown;
			} else {
				AE::log note => "cannot reap $_";
			}
		}
	}
}

sub _push_waiter {
	my ($self, $what, $var) = @_;
	push @{$self->{waiters}->{$what}} => $var;
}

sub _run_cmd($$$$$) {
	my ($cmd, $stdin, $stdout, $stderr, $pidref) = @_;
 
	my $cv = AE::cv;
 
	my %redir = (
		0 => $stdin,
		1 => $stdout,
		2 => $stderr,
	);
	
	my $pid = fork;
	AE::log error => "cannot fork: $!" unless defined $pid;
 
	unless ($pid) {
		# move any existing fd's out of the way
		# this also ensures that dup2 is never called with fd1==fd2
		# so the cloexec flag is always cleared
	    my (@oldfh, @close);
		for my $fh (values %redir) {
			push @oldfh, $fh; # make sure we keep it open
			$fh = fileno $fh; # we only want the fd
 
			# dup if we are in the way
			# if we "leak" fds here, they will be dup2'ed over later
			defined ($fh = POSIX::dup ($fh)) or POSIX::_exit (124)
				while exists $redir{$fh};
		}
 
		# execute redirects
		while (my ($k, $v) = each %redir) {
			defined POSIX::dup2 ($v, $k)
				or POSIX::_exit (123);
		}
 
		# close everything else, except 0, 1, 2
        AnyEvent::Util::close_all_fds_except 0, 1, 2;
 
		my $bin = $cmd->[0];
 
		no warnings;

		exec { $bin } @$cmd;

		exit 126;
	}
 
	$$pidref = $pid;
 
	%redir = (); # close child side of the fds
 
	my $status;
	$cv->begin (sub {
		shift->send ($status)
	});
	
	my $cw;
	$cw = AE::child $pid => sub {
		$status = $_[1] >> 8;
		AE::log warn => "child exited with status $status" if $status;
		undef $cw;
		$cv->end;
	};
	
 	$cv;
}


sub new($%) {
	my ($class, %options) = @_;
	
	$options{args} ||= [];
	
	my $eof_in;
	my $eof_out;
	my $eof_err;
	
	my ($rIN , $wIN , $cvIN ) = _rpipe { $$eof_in->(@_) };
	my ($rOUT, $wOUT, $cvOUT) = _wpipe { $$eof_out->(@_) };
	my ($rERR, $wERR, $cvERR) = _wpipe { $$eof_err->(@_) };
	
	my $pid;

	my $cv = _run_cmd([ delete $options{bin} => @{delete $options{args}} ], $rIN, $wOUT, $wERR, \$pid);
	
	my $self = bless {
		in => $wIN,
		out => $rOUT,
		err => $rERR,
		pid => $pid,
		listeners => {
			exit => delete $options{on_exit},
			ttl_exceed => delete $options{on_ttl_exceed},
			#eof_stdin  => delete $options{on_eof_stdin},
			#eof_stdout => delete $options{on_eof_stdout},
			#eof_stderr => delete $options{on_eof_stderr},
		},
		eol => "\n",
		cv => $cv,
		waiters => {
			in => [],
			out => [],
			err => [],
		},
	} => ref $class || $class;
	{
		my $eol = quotemeta $self->_eol;
		$self->{reol} = delete $options{reol} || qr{$eol};
	}
	
	my $w;
	if ($options{ttl}) {
		$w = AnyEvent->timer(after => delete $options{ttl}, cb => sub {
			return unless $self->alive;
			$self->kill;
			$self->_emit('ttl_exceed');
		});
	}
	
	my $kill = sub { $self->end };
	
	if ($options{timeout}) {
		$wIN->timeout($options{timeout});
		$rOUT->timeout($options{timeout});
		$rERR->timeout($options{timeout});
		delete $options{timeout};
		
		$self->_on(timeout => (delete ($options{on_timeout}) || $kill));
		my $cb = sub { $self->_emit('timeout') };
		$wIN->on_timeout($cb);
		$rOUT->on_timeout($cb);
		$rERR->on_timeout($cb);
	}
	
	if ($options{wtimeout}) {
		$wIN->wtimeout(delete $options{wtimeout});
		
		$self->_on(wtimeout => (delete($options{on_wtimeout}) || $kill));
		my $cb = sub { $self->_emit('wtimeout') };
		$wIN->on_wtimeout($cb);
	}
	
	if ($options{rtimeout}) {
		$rOUT->rtimeout(delete $options{rtimeout});
		
		$self->_on(rtimeout => (delete($options{on_rtimeout}) || $kill));
		my $cb = sub { $self->_emit('rtimeout') };
		$rOUT->on_rtimeout($cb);
	}

	if ($options{etimeout}) {
		$rERR->rtimeout(delete $options{etimeout});
		
		$self->_on(etimeout => (delete($options{on_etimeout}) || $kill));
		my $cb = sub { $self->_emit('etimeout') };
		$rERR->on_rtimeout($cb);
	}
	
	if ($options{errstr}) {
		my $sref = delete $options{errstr};
		$$sref = '';
		$self->pipe(err => $sref);
	}
	
	if ($options{outstr}) {
		my $sref = delete $options{outstr};
			$$sref = '';
		$self->pipe(out => $sref);
	}
	
	$cvIN->cb(_reaper($self->{waiters}->{in}));
	$cvOUT->cb(_reaper($self->{waiters}->{out}));
	$cvERR->cb(_reaper($self->{waiters}->{err}));
	
	$$eof_in  = sub { $self->_emit(eof_stdin  => @_); };
	$$eof_out = sub { $self->_emit(eof_stdout => @_); };
	$$eof_err = sub { $self->_emit(eof_stderr => @_); };
	
	$cv->cb(sub {
		undef $w;
		$self->_emit(exit => shift->recv);
	});
	
	if (keys %options) {
		AE::log note => "unknown left-over option(s): ".join ', ' =>  keys %options;
	}
	
	$self;
}

sub _on {
	my ($self, $name, $handler) = @_;
	$self->{listeners}->{$name} = $handler;
}


sub in  { shift->{in}  }


sub out { shift->{out} }


sub err { shift->{err} }

sub _eol { shift->{eol} }
sub _reol { shift->{reol} }

sub _emit($$@) {
	my ($self, $name, @args) = @_;
	if (exists $self->{listeners}->{$name} and defined $self->{listeners}->{$name}) {
		$self->{listeners}->{$name}->($self, @args);
	}
}


sub pid($) {
	shift->{pid};
}


sub fire($;$) {
	my ($self, $signal) = @_;
	$signal = 'INT' unless defined $signal;
	kill uc $signal => $self->pid;
	$self;
}


sub kill($) {
	my ($self) = @_;
	$self->fire('kill');
}


sub fire_and_kill($$;$) {
	my $self = shift;
	my $time = pop;
	my $signal = uc (pop || 'INT');
	my $w = AnyEvent->timer(after => $time, cb => sub {
		return unless $self->alive;
		$self->kill;
	});
	$self->fire($signal);
	my $exit = $self->wait;
	undef $w;
	$exit;
}


sub alive($) {
	shift->fire(0) ? 1 : 0;
}


sub wait($) {
	my ($self) = @_;
	my $status = $self->{cv}->recv;
	waitpid $self->{pid} => 0;
	$self->end;
	$status;
}


sub finish($) {
	my ($self) = @_;
	$self->in->destroy;
	$self;
}


sub end($) {
	my ($self) = @_;
	$self->in->destroy;
	$self->out->destroy;
	$self->err->destroy;
	$self;
}


sub stop_timeout($) {
	my ($self) = @_;
	$self->in->timeout(0);
	$self->out->timeout(0);
	$self->err->timeout(0);
}


sub stop_wtimeout($) {
	my ($self) = @_;
	$self->in->wtimeout(0);
}


sub stop_rtimeout($) {
	my ($self) = @_;
	$self->out->rtimeout(0);
}


sub stop_etimeout($) {
	my ($self) = @_;
	$self->err->rtimeout(0);
}


sub write($$;@) {
	my ($self, $type, @args) = @_;
	my $ok = 0;
	try {
		$self->{in}->push_write($type => @args);
		$ok = 1;
	} catch {
		AE::log warn => $_;
	};
	$ok;
}


sub writeln($@) {
	my ($self, @lines) = @_;
	$self->write($_.$self->_eol) for @lines;
	$self;
}


sub pipe($$;$) {
	my $self = shift;
	my $peer = pop;
	my $what = lc (pop || 'out');
	$what =~ s{^std}{};
	use Scalar::Util qw(blessed);
	my $sub;
	if (blessed $peer) {
		if ($peer->isa(__PACKAGE__)) {
			$sub = sub {
				$peer->write(shift)
			}
		} elsif ($peer->isa('AnyEvent::Handle')) {
			$sub = sub {
				$peer->push_write(shift)
			}
		} elsif ($peer->can('print')) {
			$sub = sub {
				$peer->print(shift)
			}
		}
	} elsif (ref $peer eq 'SCALAR') {
		$sub = sub {
			$$peer .= shift
		}
	} elsif (ref $peer eq 'GLOB') {
		$sub = sub {
			print $peer shift();
		}
	}
	if ($sub) {
		$self->$what->on_read(sub {
			local $_ = $_[0]->rbuf;
			$_[0]->rbuf = '';
			$sub->($_);
		})
	}
}

sub _push_read($$@) {
	my ($self, $what, @args) = @_;
	my $ok = 0;
	try {
		$self->{$what}->push_read(@args);
		$ok = 1;
	} catch {
		AE::log warn => "cannot push_read from std$what: $_";
	};
	$ok;
}

sub _unshift_read($$@) {
	my ($self, $what, @args) = @_;
	my $ok = 0;
	try {
		$self->{$what}->unshift_read(@args);
		$ok = 1;
	} catch {
		AE::log warn => "cannot unshift_read from std$what: $_";
	};
	$ok;
}

sub _readline($$$) {
	my ($self, $what, $sub) = @_;
	$self->_push_read($what => line => $self->_reol, $sub);
}

sub _readchunk($$$$) {
	my ($self, $what, $bytes, $sub) = @_;
	$self->_push_read($what => chunk => $bytes => $sub);
}

sub _sub_cb($) {
	my ($cb) = @_;
	sub { $cb->($_[1]) }
}

sub _sub_cv($) {
	my ($cv) = @_;
	sub { $cv->send($_[1]) }
}

sub _sub_ch($) {
	my ($ch) = @_;
	sub { $ch->put($_[1]) }
}

sub _readline_cb($$$) {
	my ($self, $what, $cb) = @_;
	$self->_push_waiter($what => $cb);
	$self->_readline($what => _sub_cb($cb));
}

sub _readline_cv($$;$) {
	my ($self, $what, $cv) = @_;
	$cv ||= AE::cv;
	$self->_push_waiter($what => $cv);
	$cv->send unless $self->_readline($what => _sub_cv($cv));
	$cv;
}

sub _readline_ch($$;$) {
	my ($self, $what, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->_readline($what => _sub_ch($channel));
	$channel;
}

sub _readlines_cb($$$) {
	my ($self, $what, $cb) = @_;
	$self->_push_waiter($what => $cb);
	$self->$what->on_read(sub {
		$self->_readline($what => _sub_cb($cb));
	});
}

sub _readlines_ch($$;$) {
	my ($self, $what, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->$what->on_read(sub {
		$self->_readline($what => _sub_ch($channel));
	});
	$channel;
}

sub _readchunk_cb($$$$) {
	my ($self, $what, $bytes, $cb) = @_;
	$self->_push_waiter($what => $cb);
	$self->_readchunk($what, $bytes, _sub_cb($cb));
}

sub _readchunk_cv($$$;$) {
	my ($self, $what, $bytes, $cv) = @_;
	$cv ||= AE::cv;
	$self->_push_waiter($what => $cv);
	$self->_readchunk($what, $bytes, _sub_cv($cv));
	$cv;
}

sub _readchunk_ch($$$;$) {
	my ($self, $what, $bytes, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->_readline($what => _sub_ch($channel));
	$channel;
}

sub _readchunks_ch($$$;$) {
	my ($self, $what, $bytes, $channel) = @_;
	unless ($channel) {
		require Coro::Channel;
		$channel ||= Coro::Channel->new;
	}
	$self->_push_waiter($what => $channel);
	$channel->shutdown unless $self->$what->on_read(sub {
		$self->_readline($what => _sub_ch($channel));
	});
	$channel;
}


sub readline_cb($$) {
	my ($self, $cb) = @_;
	$self->_readline_cb(out => $cb);
}


sub readline_cv($;$) {
	my ($self, $cv) = @_;
	$self->_readline_cv(out => $cv);
}


sub readline_ch($;$) {
	my ($self, $ch) = @_;
	$self->_readline_ch(out => $ch);
}


sub readlines_cb($$) {
	my ($self, $cb) = @_;
	$self->_readlines_cb(out => $cb);
}


sub readlines_ch($;$) {
	my ($self, $ch) = @_;
	$self->_readlines_ch(out => $ch);
}


sub readline($) {
	shift->readline_cv->recv
}


sub readline_error_cb($$) {
	my ($self, $cb) = @_;
	$self->_readline_cb(err => $cb);
}


sub readline_error_cv($;$) {
	my ($self, $cv) = @_;
	$self->_readline_cv(err => $cv);
}


sub readline_error_ch($;$) {
	my ($self, $ch) = @_;
	$self->_readline_ch(err => $ch);
}


sub readlines_error_cb($$) {
	my ($self, $cb) = @_;
	$self->_readlines_cb(out => $cb);
}


sub readlines_error_ch($;$) {
	my ($self, $ch) = @_;
	$self->_readlines_ch(out => $ch);
}


sub readline_error($) {
	shift->readline_error_cv->recv
}

1;

__END__

=pod

=head1 NAME

AnyEvent::Proc - Run external commands

=head1 VERSION

version 0.1.0

=head1 SYNOPSIS

	my $proc = AnyEvent::Proc->new(bin => 'cat');
	$proc->writeln('hello');
	my $hello = $proc->readline;
	$proc->fire;
	$proc->wait;

=head1 METHODS

=head2 new(%options)

=over 4

=item * I<bin> (mandatory)

Name (or path) to a binary

=item * I<args>

ArrayRef with command arguments

=item * I<ttl>

Time-to-life timeout after the process automatically gets killed

See also I<on_ttl_exceed> callback handler.

=item * I<timeout>

Inactive timeout value (fractional seconds) for all handlers.

See also I<on_timeout> callback handler. If omitted, after exceeding timeout all handlers will be closed and the subprocess can finish.

=item * I<wtimeout>

Like I<timeout> but sets only the write timeout value for STDIN.

Corresponding callback handler: I<on_wtimeout>

=item * I<rtimeout>

Like I<timeout> but sets only the read timeout value for STDOUT.

Corresponding callback handler: I<on_rtimeout>

=item * I<etimeout>

Like I<timeout> but sets only the read timeout value for STDERR.

Corresponding callback handler: I<on_etimeout>

=item * I<outstr>

When set to a ScalarRef, any output (STDOUT) will be appended to this scalar

=item * I<errstr>

Same as I<outstr>, but for STDERR.

=item * I<on_exit>

Callback handler called when process exits

=item * I<on_ttl_exceed>

Callback handler called when I<ttl> exceeds

=item * I<on_timeout>

Callback handler called when any inactivity I<timeout> value exceeds

=item * I<on_wtimeout>

Callback handler called when STDIN write inactivity I<wtimeout> value exceeds

=item * I<on_rtimeout>

Callback handler called when STDOUT read inactivity I<rtimeout> value exceeds

=item * I<on_etimeout>

Callback handler called when STDERR read inactivity I<etimeout> value exceeds

=back

=head2 in()

Returns a L<AnyEvent::Handle> for STDIN

=head2 out()

Returns a L<AnyEvent::Handle> for STDOUT

=head2 err()

Returns a L<AnyEvent::Handle> for STDERR

=head2 pid()

Returns the PID of the subprocess

=head2 fire([$signal])

Sends a named signal to the subprocess. C<$signal> defaults to I<INT> if omitted.

=head2 kill()

Kills the subprocess the most brutal way. Equals to

	$proc->fire('kill')

=head2 fire_and_kill([$signal, ]$time)

Fires specified signal C<$signal> (or I<INT> if omitted) and after C<$time> seconds kills the subprocess.

This is a synchronous call. After this call, the subprocess can be considered to be dead.

Returns the exit code of the subprocess.

=head2 alive()

Check whether is subprocess is still alive. Returns I<1> or I<0>

In fact, the method equals to

	$proc->fire(0)

=head2 wait()

Waits for the subprocess to be finished returns the exit code.

=head2 finish()

Closes STDIN of subprocess

=head2 end()

Closes all handles of subprocess

=head2 stop_timeout()

Stopps read/write timeout for STDIN, STDOUT and STDERR.

See I<timeout> and I<on_timeout> options in I<new()>.

=head2 stop_wtimeout()

Stopps write timeout for STDIN.

See I<wtimeout> and I<on_wtimeout> options in I<new()>.

=head2 stop_rtimeout()

Stopps read timeout for STDIN.

See I<rtimeout> and I<on_rtimeout> options in I<new()>.

=head2 stop_etimeout()

Stopps read timeout for STDIN.

See I<etimeout> and I<on_etimeout> options in I<new()>.

=head2 write($scalar)

Queues the given scalar to be written.

=head2 write($type => @args)

See L<AnyEvent::Handle>::push_write for more information.

=head2 writeln(@lines)

Queues one or more line to be written.

=head2 pipe([$fd, ]$peer)

Pipes any output of STDOUT to another handle. C<$peer> maybe another L<AnyEvent::Proc> instance, an L<AnyEvent::Handle>, an object that implements the I<print> method, a ScalarRef or a GlobRef.

C<$fd> defaults to I<stdout>.

	$proc->pipe(stderr => $socket);

=head2 readline_cb($callback)

Reads a single line from STDOUT and calls C<$callback>

=head2 readline_cv([$condvar])

Reads a single line from STDOUT and send the result to C<$condvar>. A condition variable will be created and returned, if C<$condvar> is omitted.

=head2 readline_ch([$channel])

Reads a singe line from STDOUT and put the result to coro channel C<$channel>. A L<Coro::Channel> will be created and returned, if C<$channel> is omitted.

=head2 readlines_cb($callback)

Read lines continiously from STDOUT and calls on every line the handler C<$callback>.

=head2 readlines_ch([$channel])

Read lines continiously from STDOUT and put every line to coro channel C<$channel>. A L<Coro::Channel> will be created and returned, if C<$channel> is omitted.

=head2 readline()

Reads a single line from STDOUT synchronously and return the result.

Same as

	$proc->readline_cv->recv

=head2 readline_error_cb($callback)

Bevahes equivalent as I<readline_cb>, but for STDERR.

=head2 readline_error_cv([$condvar])

Bevahes equivalent as I<readline_cv>, but for STDERR.

=head2 readline_error_ch([$channel])

Bevahes equivalent as I<readline_ch>, but for STDERR.

=head2 readlines_error_cb($callback)

Bevahes equivalent as I<readlines_cb>, but for STDERR.

=head2 readlines_error_ch([$channel])

Bevahes equivalent as I<readlines_ch>, but for STDERR.

=head2 readline_error()

Bevahes equivalent as I<readline>, but for STDERR.

=head1 BUGS

Please report any bugs or feature requests on the bugtracker website
https://github.com/zurborg/libanyevent-proc-perl/issues

When submitting a bug or request, please include a test-file or a
patch to an existing test-file that illustrates the bug or desired
feature.

=head1 AUTHOR

David Zurborg <zurborg@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2014 by David Zurborg.

This is free software, licensed under:

  The ISC License

=cut
