use Mojo::Base -strict;

use Test::More;
use Mojo::IOLoop;
use Mojolicious::Lite;
use Test::Mojo;

require Mojolicious::Plugin::SizeLimit;

my ($total, $shared) = Mojolicious::Plugin::SizeLimit::check_size();

unless (ok $total, "OS ($^O) is supported") {
    done_testing();
    exit 0;
}

my $stopped = 0;

my $t = Test::Mojo->new;
my $shutdown_on_startup_occured = 0;
Mojo::IOLoop->singleton->on("sizelimit_shutdown", sub { $shutdown_on_startup_occured = 1;  });
plugin 'SizeLimit', max_process_size => 1, check_interval => 20, startup_check => 1, report_level => 'info';
ok($shutdown_on_startup_occured, "shutdown occured as expected");
done_testing();
