#!/usr/bin/env perl6

use v6;

use Net::SMTP::Client::Async;

my ($smtp-host, $smtp-port, $security, $auth, $user, $pass);

$smtp-host = prompt("SMTP Server: ") || 'localhost';

repeat { $smtp-port = prompt "SMTP Port: " } until $smtp-port == 25 | 465 | 587;

repeat { $security  = prompt "[S]SL, START[T]LS, or [P]lain: " }
    until $security.lc eq 's' | 't' | 'p';

repeat { $auth      = prompt "Auth [yn]: " }
    until $auth.lc eq 'y' | 'n';

if $auth.lc eq 'y' {
    repeat { $user = prompt "User: " } until $user.chars;
    repeat { $pass = prompt "Pass: " } until $pass.chars;
}

my ($from, $to, $subject);

repeat { $from    = prompt "From: "    } until $from.chars;
repeat { $to      = prompt "To: "      } until $to.chars;
repeat { $subject = prompt "Subject: " } until $subject.chars;

say "Type your message. End with a line containing only a period.";

my $done = False;
my @message = gather repeat {
    my $line = prompt;
    $done = ($line eq '.');
    take $line unless $done;
} until $done;

my $smtp = await Net::SMTP::Client::Async.connect(
    host   => $smtp-host,
    port   => $smtp-port,
    secure => ($security.lc eq 's'),
);

$smtp.debug = &Net::SMTP::Client::Async::std-debug;

await $smtp.hello;
await $smtp.start-tls(host => $smtp-host) if $security.lc eq 't';
await $smtp.hello;

if $auth.lc eq 'y' {
    await $smtp.authenticate(
        data => %(
            authname => $user,
            user     => $user,
            pass     => $pass,
        ),
    );
}

my $message = qq:to/./;
From: $from
To: $to
Subject: $subject

{@message.join("\n")}
.

await $smtp.send-message(:$from, to => [ $to ], :$message);

$smtp.quit;
