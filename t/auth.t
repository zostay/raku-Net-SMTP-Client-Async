use v6;

use Test;
use Net::SMTP::Client::Async;

use lib 't/lib';
use Test::Net::SMTP::Client::Async;

my $port = await start-test-server;

my $smtp = await Net::SMTP::Client::Async.connect(:$port);
#$smtp.debug = &Net::SMTP::Client::Async::std-debug;
isa-ok $smtp, Net::SMTP::Client::Async;

my $hello = await $smtp.hello;
isa-ok $hello, Net::SMTP::Client::Async::Response;
ok $smtp.keywords, 'keywords are set';
nok $smtp.keywords<AUTH>, 'server does not support AUTH without SSL';
ok $hello.is-success, 'response from EHLO is good';

my $start-tls = await $smtp.start-tls(:insecure);
isa-ok $start-tls, Net::SMTP::Client::Async::Response;
ok $start-tls.is-success, 'response from STARTTLS is good';

my $hello2 = await $smtp.hello;
isa-ok $hello2, Net::SMTP::Client::Async::Response;
ok $smtp.keywords, 'keywords are set';
is $smtp.keywords<AUTH>, 'PLAIN ANONYMOUS', 'secure server supports SASL PLAIN and ANONYMOUS';
ok $hello2.is-success, 'response from second EHLO is good';

my $auth = await $smtp.authenticate(
    data => %(
        user => 'zostay',
        pass => 'secret',
    ),
);
isa-ok $auth, Net::SMTP::Client::Async::Response;
ok $auth.is-success, 'auth was successful';

await stop-test-server;

done-testing;

CATCH {
    .note;
    flunk("something went wrong: $_");
}
