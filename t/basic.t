use Mojo::Base -strict;

use Test::More;
use Mojolicious::Lite;
use Test::Mojo;

plugin 'SizeLimit', max_unshared_size => 16384, check_interval => 2;

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
    ->header_is(Connection => 'close');

ok !$t->ua->ioloop->is_running, "IOLoop is stopped";

done_testing();
