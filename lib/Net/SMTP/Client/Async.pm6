use v6;

unit class Net::SMTP::Client::Async;

use IO::Socket::Async::SSL;

class Response {
    has Int $.code;
    has Str $.text;

    method is-success(--> Bool:D) { 100 <= $!code < 400 }
    method is-error(--> Bool:D) { 400 <= $!code }
    method is-transient-error(--> Bool:D) { 400 <= $!code < 500 }
    method is-permanent-error(--> Bool:D) { 500 <= $!code }
}

has Channel:D $!command .= new;
has Promise:D $!finished .= new;

has @!taps;

has $.socket;
has Bool $.secure;

my subset PortNumber of UInt where * > 0;

method new(::?CLASS:U:) {
    die "Do not use .new to construct a Net::SMTP::Client::Async object. Use .connect instead.";
}

multi method connect(::?CLASS:U:
    IO::Socket::Async $socket,
    --> Promise:D
) {
    start {
        my $self = self.bless: :$socket, :!secure;
        $self!begin;
    }
}

method connect(::?CLASS:U:
    IO::Socket::Async::SSL $socket,
    --> Promise:D
) {
    start {
        my $self = self.bless: :$socket, :secure;
        $self!begin;
    }
}

method connect(::?CLASS:U:
    Str :$host = 'localhost',
    Int :$port = 25,
    Bool :$secure = False,
    *%passthru,
    --> Promise:D
) {
    start {
        my $socket-class = $secure ?? IO::Socket::Async::SSL !! IO::Socket::Async;
        my $socket = await $socket-class.connect($host, $port, |%passthru);
        my $self = self.bless: :$socket, :secure;
        $self!begin;
    }
);

method !begin(::?CLASS:D:) {
    push @!taps, $!socket.Supply.lines.tap: {
        when /^
                $<code> = [ \d ** 3 ]
                $<continuation> = [ '-' | ' ' ]
                $<text> = [ .* ]
            $/ {

            $!response.send([ val($<code>), "$<continuation>" eq "-", ~$<text> ]);
        }

        default {
            $!response.fail(X::Net::SMTP::Client::Async::CommunicationFailure.new);
        }
    }

    push @!taps, $!command.Supply.tap: {
        $!socket.print: $cmd;
    }

    $!finished.then: -> $p {
        given $p.result {
            self!end;
            $!socket.close;
        }
    }

    self;
}

method !end(::?CLASS:D:) {
    .close for @!taps;
}

method !handle-response(::?CLASS:D:) {
    my ($code, $continue, @text);
    repeat {
        my @res := $!response.receive;

        $code = @res[0];
        $continue = @res[1];
        push @text, @res[2];
    } while $continue;

    my $text = @text.join("\n");

    Response.new(:$code, :$text);
}

method send-command(::?CLASS:D: Str:D $command, Str $argument? --> Promise:D) {
    start {
        my $command-line = $command;
        $command-line ~= " $_" with $argument;

        $!command.send("$command $argument\r\n");

        self!handle-response;
    }
}

method HELO(::?CLASS:D: Str:D $domain --> Promise:D) {
    self.send-command("HELO", $domain);
}

method MAIL(::?CLASS:D: Str:D $from --> Promise:D) {
    self.send-command("MAIL", "FROM:$from");
}

method RCPT(::?CLASS:D: Str:D $to --> Promise:D) {
    self.send-command("RCPT", "TO:$to");
}

method DATA(::?CLASS:D: --> Promise:D) {
    self.send-command("DATA");
}

method send-raw-message(::?CLASS:D: Str:D $message --> Promise:D) {
    start {
        $!command.send("$message\r\n.\r\n");
        self!handle-response;
    }
}

method RSET(::?CLASS:D: --> Promise:D) {
    self.send-command("RSET");
}

method SEND(::?CLASS:D: Str:D $from --> Promise:D) {
    self.send-command('SEND', "FROM:$from");
}

method SOML(::?CLASS:D: Str:D $from --> Promise:D) {
    self.send-command('SOML', "FROM:$from");
}

method SAML(::?CLASS:D: Str:D $from --> Promise:D) {
    self.send-command('SAML', "FROM:$from");
}

method VRFY(::?CLASS:D: Str:D $string --> Promise:D) {
    self.send-command('VRFY', $string);
}

method EXPN(::?CLASS:D: Str:D $string --> Promise:D) {
    self.send-command('EXPN', $string);
}

method HELP(::?CLASS:D: Str $string? --> Promise:D) {
    self.send-command('HELP', $string);
}

method NOOP(::?CLASS:D: --> Promise:D) {
    self.send-command('NOOP');
}

method QUIT(::?CLASS:D: --> Promise:D) {
    self.send-command('QUIT');
}

method TURN(::?CLASS:D: --> Promise:D) {
    self.send-command('TURN');
}
