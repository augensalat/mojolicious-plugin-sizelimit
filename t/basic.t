use Mojo::Base -strict;

use Test::More;
use Mojolicious::Lite;
use Test::Mojo;

require Mojolicious::Plugin::SizeLimit;

my ($total, $shared) = Mojolicious::Plugin::SizeLimit::check_size();
my ($p, $v);

if ($shared) {
    $p = 'max_unshared_size';
    $v = int(($total - $shared) / 2);
}
else {
    # no information available for shared (Solaris)
    $p = 'max_process_size';
    $v = int($total / 2);
}

plugin 'SizeLimit', $p => $v, check_interval => 2, report_level => 'info';

get '/' => sub {
  my $c = shift;
  $c->render(text => $$);
};

my $t = Test::Mojo->new;

ok !$t->ua->ioloop->is_running, "IOLoop is running";

$t->get_ok('/')
    ->status_is(200)
    ->content_is($$)
    ->header_is(Connection => 'keep-alive');

ok !$t->ua->ioloop->is_running, "IOLoop is running";

$t->get_ok('/')
    ->status_is(200)
    ->content_is($$)
    ->header_is(Connection => 'close')
    ->or(
        sub {
            my ($size, $shared) = Mojolicious::Plugin::SizeLimit::check_size($t->app);
            diag "plugin 'SizeLimit', $p => '$v', check_interval => 2;";
            diag "current size = $size, shared = $shared";
        }
    );

ok !$t->ua->ioloop->is_running, "IOLoop is stopped";

done_testing();
