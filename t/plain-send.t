use v6;

use Test;
use Net::SMTP::Client::Async;

use lib 't/lib';
use Test::Net::SMTP::Client::Async;

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

await stop-test-server;

done-testing;

CATCH {
    .note;
    fail("something went wrong: $_");
}

