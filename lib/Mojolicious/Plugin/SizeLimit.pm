package Mojolicious::Plugin::SizeLimit;

use Mojo::Base 'Mojolicious::Plugin';

use Mojo::IOLoop;

our $VERSION = '0.001';

my $PKG = __PACKAGE__;

if ($^O eq 'solaris') {
    # do not consider version number, cos it prolly does more harm than help
    *check_size = \&_solaris_size_check;
}
elsif ($^O eq 'linux') {
    *check_size = eval { require Linux::Smaps } && Linux::Smaps->new($$) ?
        \&_linux_smaps_size_check : \&_linux_size_check;
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

    # ... a sub that is true every $check_interval requests
    *_is_nth_request = _make_is_nth_request($conf);
    # ... a sub that is true if memory consumption exceeds conf values
    *_limits_are_exceeded = _make_limits_are_exceeded($conf);

    $app->hook(after_dispatch => sub {
        _is_nth_request() and _limits_are_exceeded($app)
            or return;

        shift->res->headers->connection('close');
        Mojo::IOLoop->singleton->stop_gracefully;
    });
}

# rss is in KB but ixrss is in BYTES.
# This is true on at least FreeBSD, OpenBSD, & NetBSD
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
        $_[0]->log->error("Couldn't access /proc/self/status");
    }

    # linux on intel x86 has 4KB page size...
    return ($size * 4, $share * 4);
}

sub _load {
    my $mod = shift;

    eval "require $mod"
        or die "You must install $mod for $PKG to work on your platform.";
}

sub _make_is_nth_request {
    my $conf = shift;

    return sub { 1 }
        if ($conf->{check_interval} // 1) == 1;

    return eval <<"_SUB_";
        sub {
            state \$count = 0;
            return ++\$count % $conf->{check_interval} == 0;
        };
_SUB_
}

sub _make_limits_are_exceeded {
    my $conf = shift;
    my $sub = <<'_SUB_';
        sub {
            my $app = shift;
            my ($size, $shared) = check_size($app);
_SUB_
    $sub .= <<"_SUB_" if $conf->{max_process_size};
            if (\$size > $conf->{max_process_size}) {
                \$app->log->debug("Process size (\$size K) exceeds max_process_size ($conf->{max_process_size} K)");
                return 1;
            }
_SUB_
    $sub .= <<'_SUB_';
            return 0 unless $shared;
_SUB_
    $sub .= <<"_SUB_" if $conf->{min_shared_size};
            if (\$shared < $conf->{min_shared_size}) {
                \$app->log->debug("Shared size (\$shared K) underruns min_shared_size ($conf->{min_shared_size} K)");
                return 1;
            }
_SUB_
    $sub .= <<"_SUB_" if $conf->{max_unshared_size};
            my \$unshared = \$size - \$shared;
            if (\$unshared > $conf->{max_unshared_size}) {
                \$app->log->debug("Unshared size (\$unshared K) exceeds max_unshared_size ($conf->{max_unshared_size} K)");
                return 1;
            }
_SUB_
    $sub .= <<'_SUB_';
            return 0;
        };
_SUB_

    return eval $sub;
}

sub _solaris_size_check {
    my $size = -s '/proc/self/as'
        or $_[0]->log->error("/proc/self/as doesn't exist or is empty");
    $size = int($size / 1024);

    # return 0 for share, to avoid undef warnings
    return ($size, 0);
}

1;

__END__

=encoding utf8

=head1 NAME

Mojolicious::Plugin::SizeLimit - Kill Your Children If They Grow Too Large

=head1 VERSION

Version 0.001

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
require a lot of memory for each request. Since Perl does not give
memory back to the system after using it, the process size can grow
quite large.

This module will not really help you with the first problem. For that
you should probably look into "BSD::Resource" or some other means of
setting a limit on the data size of your program. BSD-ish systems have
"setrlimit()", which will kill your memory gobbling processes. However,
it is a little violent, terminating your process in mid-request.

This module attempts to solve the second situation, where your process
slowly grows over time. It checks memory usage after every N requests,
and if it exceeds a threshold, exits gracefully.

By using this module, you should be able to set the configuration
directive L<Mojo::Server::Hypnotoad/accepts> to 0 (= unlimited).
This has the great advantage, that worker processes are not sig-killed
by the manager process at end-of-life if they do not finish within
L<Mojo::Server::Hypnotoad/graceful_timeout>.

=head1 OPTIONS

L<Mojolicious::Plugin::SizeLimit> supports the following options.

=head2 max_unshared_size

The maximum amount of unshared memory the process can use in KB. Usually
this option is all one needs, because it only kills off processes that
are truly using too much physical RAM, allowing most processes to live
longer and reducing the process churn rate.

=head2 max_process_size

The maximum size of the process in KB, including both shared and
unshared memory.

=head2 min_shared_size

Sets the minimum amount of shared memory the process must have in KB.

=head2 check_interval

Since checking the process size can take a few system calls on some
platforms (e.g. linux), you may specify this option to check the process
size every N requests.

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

