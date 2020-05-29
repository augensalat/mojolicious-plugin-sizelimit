package Mojolicious::Plugin::SizeLimit;

use Mojo::Base 'Mojolicious::Plugin';

use Mojo::IOLoop;
use Time::HiRes ();

our $VERSION = '0.005';

our $start_timestamp;

my $PKG = __PACKAGE__;

if ($^O eq 'solaris') {
    # do not consider version number, cos it prolly does more harm than help
    *check_size = \&_solaris_size_check;
}
elsif ($^O eq 'linux') {
    *check_size = eval { require Linux::Smaps } && Linux::Smaps->new($$) ?
        \&_linux_smaps_size_check : \&_linux_size_check;
}
elsif ($^O eq 'netbsd') {
    die "$PKG is not implemented on $^O.\n";
}
elsif ($^O =~ /(?:bsd|aix)/i) {
    # on OSX, getrusage() is returning 0 for proc & shared size.
    _load('BSD::Resource');
    *check_size = \&_bsd_size_check;
}
elsif ($^O =~ /darwin/i) {
    _load('BSD::Resource');

    my ($ver) = (qx(sw_vers -productVersion) || 0) =~ /^10\.(\d+)\.\d+$/;

    # OSX 10.9+ has no concept of rshrd in top
    *check_size = $ver >= 9 ? \&_bsd_size_check : \&_darwin_size_check;
}
else {
    die "$PKG is not implemented on $^O.\n";
}

sub register {
    my ($self, $app, $conf) = @_;
    my ($total) = check_size($app->log);

    die "OS ($^O) not supported by $PKG: Can not determine memory usage.\n"
        unless $total;

    $app->log->info(__PACKAGE__ . '::VERSION = ' . $VERSION);

    # report_level needs a default value, we set it here
    if(!exists($conf->{report_level})) {
        $conf->{report_level}   = 'debug';
    };

    my %conf = %$conf;

    *_count_requests = _make_count_requests(\%$conf);
    *_limits_are_exceeded = _make_limits_are_exceeded(\%conf);

    if(defined($conf->{startup_check}) && $conf->{startup_check}) {
        if(_limits_are_exceeded($app->log,$app,0)) {
            $app->log->info("size limits failed at startup time, stopping");
            Mojo::IOLoop->singleton->emit("sizelimit_shutdown");
            Mojo::IOLoop->next_tick(sub { Mojo::IOLoop->singleton->stop_gracefully; });
        };
    };

    Mojo::IOLoop->singleton->next_tick(sub { $start_timestamp = Time::HiRes::time })
        if $conf{report_level};

    $app->hook(after_dispatch => sub {
        my $c = shift;
        my ($count, $is_check_applicable) = _count_requests();
        if($is_check_applicable) {
            return if !(_limits_are_exceeded($c->app->log,$app,$count));
        } else {
            return;
        };
        $c->res->headers->connection('close');
        Mojo::IOLoop->singleton->emit("sizelimit_shutdown");
        Mojo::IOLoop->singleton->stop_gracefully;
    });
}

# rss is in KB but ixrss is in BYTES.
# This is true on at least FreeBSD & OpenBSD
sub _bsd_size_check {
    my @results = BSD::Resource::getrusage();
    my $max_rss   = $results[2];
    my $max_ixrss = int ( $results[3] / 1024 );

    return ($max_rss, $max_ixrss);
}

sub _darwin_size_check {
    my ($size) = _bsd_size_check();
    my ($shared) = (`top -e -l 1 -stats rshrd -pid $$ -s 0`)[-1];
    $shared =~ s/^(\d+)M.*/$1 * 1024 * 1024/e
        or
    $shared =~ s/^(\d+)K.*/$1 * 1024/e
        or
    $shared =~ s/^(\d+)B.*/$1/;
    no warnings 'numeric';
    return ($size, int($shared));
}

sub _linux_smaps_size_check {
    my $s = Linux::Smaps->new($$)->all;
    return ($s->size, $s->shared_clean + $s->shared_dirty);
}

sub _linux_size_check {
    my ($size, $share) = (0, 0);

    if (open my $fh, '<', '/proc/self/statm') {
        ($size, $share) = (split /\s/, scalar <$fh>)[0,2];
        close $fh;
    }
    else {
        $_[0]->error("Couldn't access /proc/self/statm");
    }

    # linux on intel x86 has 4KB page size...
    return ($size * 4, $share * 4);
}

sub _load {
    my $mod = shift;

    eval "require $mod"
        or die "You must install $mod for $PKG to work on your platform.";
}

sub _make_count_requests {
    my $conf = shift;
    return sub {
        state $count = 0;
        my $check_interval = $conf->{check_interval} // 1;
        my $is_check_applicable = 0;
        if($check_interval == 1) {
            ++$count;
            $is_check_applicable = 1;
        } else {
            ++$count;
            $is_check_applicable = (($count % $conf->{check_interval}) == 0);
        };
        return ($count,$is_check_applicable);
    };
}

sub _report {
    my ($size,$shared,$limit,$request_count) = @_;
    my $unshared = $size - $shared;
    my $now_timestamp = Time::HiRes::time;
    my $lifetime = sprintf("%5.3f",($now_timestamp-$start_timestamp));
    my $log_report = qq{
SizeLimit: Exceeding limit $limit KB. PID = $$, SIZE = $size KB
, SHARED = $shared KB, UNSHARED = $unshared KB
, REQUESTS = $request_count, LIFETIME = $lifetime s
};
    $log_report =~ s{\n}{}g;
    return $log_report;
}

sub _make_limits_are_exceeded {
    my ($conf) = @_;
    return sub {
        my ($log,$app,$request_count) = @_;
        my ($size,$shared) = check_size($app->log);
        my $log_level = $conf->{report_level};

        if(defined($conf->{max_process_size}) && $size > $conf->{max_process_size}) {
            my $limit = "max_process_size = $conf->{max_process_size}";
            my $log_report = _report($size,$shared,$limit,$request_count);
            $app->log->$log_level($log_report);
            return 1;
        };

        if(defined($conf->{min_shared_size}) && $shared < $conf->{min_shared_size}) {
            my $limit = "min_shared_size = $conf->{min_shared_size}";
            my $log_report = _report($size,$shared,$limit,$request_count);
            $app->log->$log_level($log_report);
            return 1;
        };

        if(defined($conf->{max_unshared_size}) && ($size-$shared) > $conf->{max_unshared_size}) {
            my $limit = "max_unshared_size = $conf->{max_unshared_size}";
            my $log_report = _report($size,$shared,$limit,$request_count);
            $app->log->$log_level($log_report);
            return 1;
        };

        return 0;
    };
}

sub _solaris_size_check {
    my $size = -s '/proc/self/as'
        or $_[0]->error("/proc/self/as doesn't exist or is empty");

    # Convert size from B to KB. Return 0 for share to avoid undef warnings.
    return (int($size / 1024), 0);
}

1;

__END__

=encoding utf8

=head1 NAME

Mojolicious::Plugin::SizeLimit - Terminate workers that grow too large

=head1 VERSION

Version 0.005

=head1 SYNOPSIS

  # Mojolicious
  if ($ENV{HYPNOTOAD_APP}) {
    $self->plugin('SizeLimit', max_unshared_size => 262_144); # 256M
  }

  # Mojolicious::Lite
  if ($ENV{HYPNOTOAD_APP}) {
    plugin 'SizeLimit', max_unshared_size => 262_144;
  }

=head1 DESCRIPTION

L<Mojolicious::Plugin::SizeLimit> is a L<Mojolicious> plugin that allows
to terminate L<hypnotoad> worker processes if they grow too large. The
decision to end a process can be based on its overall size, by setting
a minimum limit on shared memory, or a maximum on unshared memory.

Actually, there are two big reasons your L<hypnotoad> workers will grow.
First, your code could have a bug that causes the process to increase in
size very quickly. Second, you could just be doing operations that
require a lot of memory for each request. Since you can't rely that
Perl gives memory back to the system after using it, the process size
can grow quite large.

This module will not really help you with the first problem. For that
you should probably look into "BSD::Resource" or some other means of
setting a limit on the data size of your program. BSD-ish systems have
"setrlimit()", which will kill your memory gobbling processes. However,
it is a little violent, terminating your process in mid-request.

This module attempts to solve the second situation, where your process
slowly grows over time. It checks memory usage after every N requests,
and if it exceeds a threshold, calls L<Mojo::IOLoop/stop_gracefully>,
what as a result makes the worker stop accepting new connections and
terminate as soon as all its pending requests have been processed and
served.

By using this module, you should be able to set the configuration
directive L<Mojo::Server::Hypnotoad/accepts> to 0 (= unlimited).
This has the great advantage, that worker processes are not sig-killed
by the manager process at end-of-life if they do not finish within
L<Mojo::Server::Hypnotoad/graceful_timeout>.

=head1 OPTIONS

L<Mojolicious::Plugin::SizeLimit> supports the following options.

=head2 max_unshared_size

The maximum amount of unshared memory the process can use in KB. Usually
this option is all one needs, because it only terminates processes that
are truly using too much physical RAM, allowing most processes to live
longer and reducing the process churn rate.

On Solaris though unshared size is not available.

=head2 max_process_size

The maximum size of the process in KB, including both shared and
unshared memory. This must be used on Solaris.

=head2 min_shared_size

Sets the minimum amount of shared memory the process must have in KB.

=head2 check_interval

Since checking the process size can take a few system calls on some
platforms (e.g. linux), you may specify this option to check the process
size every N requests.

=head2 report_level

This plugin writes a message when a worker is about to terminate after
reaching a limit. The message is written using the L<Mojo::Log> method
given by C<report_level>, so any value documented in L<Mojo::Log/level>
is acceptable, C<undef> disables the message. The default is C<"debug">.

You might want to set C<report_level> at least to C<"info"> if you want
this message in your production log.

=head2 startup_check

Will perform the checks at startup-time. If the memory conditions are not
met, the application will shut down. This option can enable the startup
check if it has the value 1.

=head1 METHODS

L<Mojolicious::Plugin::SizeLimit> inherits all methods from
L<Mojolicious::Plugin> and implements the following new ones.

=head2 register

  $plugin->register(Mojolicious->new);

Register plugin in L<Mojolicious> application.

=head1 FUNCTIONS

=head2 check_size

  ($total, $shared) = Mojolicious::Plugin::SizeLimit::check_size();

Returns a list with two memory sizes in KB, first to total process size
and second the shared memory size. Not exported. Most usefull for tests.

=head2  _make_count_requests

This function is only intended to be called internally.

It will generate another function that will count the requests made.
This generated function will return a list with two integers
(count,is_check_applicable).

The first integer is the current request count for this process. The
second integer indicates whether the our limit check should be performed
on the current request.

=head2 _make_limits_are_exceeded

This function is only intended to be called internally.

It will generate a function that will check if the limits given in the
config are being met.

The return value of the generated function will indicate if the limits
are being met.

If one of the limits is not met, this function will also build a report
about the limits that were not met, and it will log that message.

=head1 SEE ALSO

L<Mojolicious>, L<http://mojolicio.us>,
L<Apache::SizeLimit>, L<Plack::Middleware::SizeLimit>,
L<Process::SizeLimit::Core>.

=head1 ACKNOWLEDGEMENTS

Andreas J. Koenig, who told me to write this Mojolicious plugin.

=head1 AUTHOR

Bernhard Graf <graf(a)cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015 Bernhard Graf

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/> for more information.

