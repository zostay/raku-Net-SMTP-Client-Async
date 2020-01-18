use v6;

use Test;
use Net::SMTP::Client::Async;

use lib 't/lib';
use Test::Net::SMTP::Client::Async;

$*SCHEDULER.uncaught_handler = sub ($x) { $x.note }

my $port = await start-test-server;

my $smtp = await Net::SMTP::Client::Async.connect(:$port);
isa-ok $smtp, Net::SMTP::Client::Async;

isa-ok $smtp.socket, IO::Socket::Async;
nok $smtp.secure, 'SMTP connection is not secure';
nok $smtp.keywords, 'no keywords yet';

my $hello = await $smtp.hello;
isa-ok $hello, Net::SMTP::Client::Async::Response;
ok $smtp.keywords, 'keywords are now set';
is $smtp.keywords<TEST-SERVER>, $port + 42, 'running against the test server';

ok $hello.is-success, 'response from SMTP server is good';
is $hello.code, 250, 'response code is 250';
like $hello.text, /^^ STARTTLS $$/, 'response keyword STARTTLS';

my $start-tls = await $smtp.start-tls;
isa-ok $start-tls, Net::SMTP::Client::Async::Response;
ok $smtp.secure, 'SMTP connection is now secure';
nok $smtp.keywords, 'no keywords set again';

my $hello-again = await $smtp.hello;
isa-ok $hello-again, Net::SMTP::Client::Async::Response;
isa-ok $smtp.socket, IO::Socket::Async::SSL;
ok $smtp.keywords, 'keywords are not set again';
is $smtp.keywords<TEST-SERVER>, $port + 42, 'running against the test server still';

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
    fail("something went wrong: $_");
}

