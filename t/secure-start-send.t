use v6;

use Test;
use Net::SMTP::Client::Async;

use lib 't/lib';
use Test::Net::SMTP::Client::Async;

$*SCHEDULER.uncaught_handler = sub ($x) { $x.note }

my $port = await start-test-server(:secure);

my $smtp = await Net::SMTP::Client::Async.connect(:$port, :secure, :insecure);
isa-ok $smtp, Net::SMTP::Client::Async;

isa-ok $smtp.socket, IO::Socket::Async::SSL;
ok $smtp.secure, 'SMTP connection is secure';
nok $smtp.keywords, 'no keywords yet';

my $hello = await $smtp.hello;
isa-ok $hello, Net::SMTP::Client::Async::Response;
ok $smtp.keywords, 'keywords are now set';
is $smtp.keywords<TEST-SERVER>, $port + 42, 'running against the test server';

ok $hello.is-success, 'response from SMTP server is good';
is $hello.code, 250, 'response code is 250';

my $msg = await $smtp.send-message(
    from    => 'zostay',
    to      => [ 'oofoof' ],
    message => 'messages are cool\n. Dontcha know?',
);
ok $msg.is-success, 'repsonse from SMTP server send is good';
is $msg.code, 250, 'response code is 250';

await stop-test-server;

done-testing;

CATCH {
    .note;
    flunk("something went wrong: $_");
}

