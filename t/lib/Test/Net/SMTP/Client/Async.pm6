use v6;

use IO::Socket::Async::SSL;
use Test;

constant KEY-FILE  = 't/ssl/key.pem';
constant CERT-FILE = 't/ssl/cert.pem';

my class TestServerSession {
    has $.secure;
    has $.conn;
    has $.quit = Promise.new;
    has $!data = False;

    has $!line-tap;

    method tap-lines() {
        .close with $!line-tap;

        $!line-tap = $!conn.Supply.lines.tap: -> $line {
            if $!data {
                self.handle-data($line);
            }
            else {
                my ($command, $argument) = $line.split(' ', 2);
                self.handle-command($command.uc, $argument);
            }
        }
    }
    method untap-lines() {
        with $!line-tap {
            $!line-tap.close;
            $!line-tap = Nil;
        }
    }

    method start(&finally) {
        self.tap-lines;
        $!quit = $!quit.then({ $!line-tap.close; $!conn.close }).then(&finally);
    }

    multi method handle-command('QUIT', $argument) {
        $!quit.keep;
    }

    multi method handle-command('HELO', $argument) {
        with $!conn {
            .print: "250 OK\r\n";
        }
    }

    multi method handle-command('EHLO', $argument) {
        with $!conn {
            .print: "250-TEST-SERVER {.socket-port + 42}\r\n";
            .print: "250-STARTTLS\r\n" unless $!secure;
            .print: "250 OK\r\n";
        }
    }

    multi method handle-command('MAIL', $argument) {
        with $!conn {
            if $argument ~~ / 'FROM:' \S+ / {
                .print: "250 OK\r\n";
            }
            else {
                .print: "501 Syntax error in parameters or arguments\r\n";
            }
        }
    }

    multi method handle-command('RCPT', $argument) {
        with $!conn {
            if $argument ~~ / 'TO:' \S+ / {
                .print: "250 OK\r\n";
            }
            else {
                .print: "501 Syntax error in parameters or arguments\r\n";
            }
        }
    }

    multi method handle-command('DATA', $argument) {
        with $!conn {
            .print: "250 OK\r\n";
            $!data++;
        }
    }

    multi method handle-command('STARTTLS', $argument) {
        with $!conn {
            .print: "250 OK\r\n";
        }
        self.untap-lines;

        IO::Socket::Async::SSL.upgrade-server($!conn,
            private-key-file => KEY-FILE,
            certificate-file => CERT-FILE,
        ).tap: -> $conn {
            $!conn = $conn;

            self.tap-lines;
            $!secure++;
        }
    }

    multi method handle-data('.', :$session) {
        with $!conn {
            .print: "250 OK\r\n";
            $!data--;
        }
    }

    multi method handle-data($) { }

}

my $listener = Promise.new;
sub start-test-server(:$secure = False --> Promise:D) is export {
    start {
        react {
            my $counter = 1;
            my %sessions;

            my sub start-session(:$conn, :$secure) {
                my $session = TestServerSession.new(
                    :$conn,
                    :$secure,
                );

                %sessions{ $counter } = $session;
                $session.start({ %sessions{ $counter }:delete });
                $counter++;
            }


            my $tap = do whenever IO::Socket::Async.listen('127.0.0.1', 0) -> $c {
                if $secure {
                    whenever IO::Socket::Async::SSL.upgrade-server($c,
                        private-key-file => KEY-FILE,
                        certificate-file => CERT-FILE,
                    ) -> $conn {
                        start-session(:$conn, :secure);
                    }
                }
                else {
                    start-session(conn => $c);
                    $c;
                }
            }

            $listener.keep($tap);
        }
    }

    start {
        my $port = await (await $listener).socket-port;

        my $tries = 10;
        loop {
            sleep 5 / $tries;

            die "test server never started" unless $tries-- > 1;

            await IO::Socket::Async.connect('127.0.0.1', $port).then: -> $p {
                $p.result.close;
            }

            CATCH {
                when / << "connection refused" >> / {
                    next;
                }
            }

            last;
        }

        $port;
    }
}

sub stop-test-server(--> Promise:D) is export {
    start {
        (await $listener).close;
    }
}
