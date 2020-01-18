use v6;

use IO::Socket::Async::SSL;

multi handle-command('QUIT', $argument, :$session) {
    $session.quit.keep;
}

multi handle-command('HELO', $argument, :$session) {
    with $session.conn {
        .print: "250 OK\r\n";
    }
}

multi handle-command('EHLO', $argument, :$session) {
    with $session.conn {
        .print: "250-TEST-SERVER {$session.conn.socket-port + 42}\r\n";
        .print: "250-STARTTLS\r\n";
        .print: "250 OK\r\n";
    }
}

multi handle-command('MAIL', $argument, :$session) {
    with $session.conn {
        if $argument ~~ / 'FROM:' \S+ / {
            .print: "250 OK\r\n";
        }
        else {
            .print: "501 Syntax error in parameters or arguments\r\n";
        }
    }
}

multi handle-command('RCPT', $argument, :$session) {
    with $session.conn {
        if $argument ~~ / 'TO:' \S+ / {
            .print: "250 OK\r\n";
        }
        else {
            .print: "501 Syntax error in parameters or arguments\r\n";
        }
    }
}

multi handle-command('DATA', $argument, :$session) {
    with $session.conn {
        .print: "250 OK\r\n";
        $session.data++;
    }
}

multi handle-command('STARTTLS', $argument, :$session) {
    with $session.conn {
        .print: "250 OK\r\n";
    }

    try {
        $session.conn = await IO::Socket::Async::SSL.upgrade-client($session.conn);

        CATCH {
            .note;
        }
    }
}

multi handle-data('.', :$session) {
    with $session.conn {
        .print: "250 OK\r\n";
        $session.data--;
    }
}

multi handle-data($, :$session) { }

my $listener = Promise.new;
sub start-test-server(--> Promise:D) is export {
    start {
        react {
            my $tap = do whenever IO::Socket::Async.listen('127.0.0.1', 0) -> $c {
                my $session = class {
                    has $.conn is rw;
                    has $.quit = Promise.new;
                    has $.data is rw = False;
                }.new(:conn($c));

                whenever $c.Supply.lines -> $line {
                    if $session.data {
                        handle-data($line, :$session);
                    }
                    else {
                        my ($command, $argument) = $line.split(' ', 2);
                        handle-command(:$session, $command.uc, $argument);
                    }
                }

                whenever $session.quit {
                    $c.close;
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
