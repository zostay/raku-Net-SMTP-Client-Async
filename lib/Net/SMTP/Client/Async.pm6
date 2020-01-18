use v6;

unit class Net::SMTP::Client::Async;

use IO::Socket::Async::SSL;
use X::Net::SMTP::Client::Async;
use Net::SMTP::Client::Async::Response;

has Channel:D $!response .= new;
has Channel:D $!command .= new;
has Promise:D $!finished .= new;

has @!taps;

has Lock:D $!socket-lock .= new;

has $.socket;
has Bool $.secure;
has %.keywords;

method socket(::?CLASS:D: --> Any:D) { $!socket-lock.protect: { $!socket } }
method secure(::?CLASS:D: --> Bool:D) { $!socket-lock.protect: { $!secure } }
method keywords(::?CLASS:D: --> Hash:D) { $!socket-lock.protect: -> { %!keywords } }

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

multi method connect(::?CLASS:U:
    IO::Socket::Async::SSL $socket,
    --> Promise:D
) {
    start {
        my $self = self.bless: :$socket, :secure;
        $self!begin;
    }
}

multi method connect(::?CLASS:U:
    Str :$host = '127.0.0.1',
    Int :$port is copy,
    Bool :$secure = False,
    *%passthru,
    --> Promise:D
) {
    start {
        my $socket-class;
        if $secure {
            $socket-class = IO::Socket::Async::SSL;
            $port //= 465;
        }
        else {
            $socket-class = IO::Socket::Async;
            $port //= 25;
        }

        my $socket = await $socket-class.connect($host, $port, |%passthru);
        my $self = self.bless: :$socket, :$secure;
        $self!begin;
    }
}

method hello(::?CLASS:D: Str:D $domain = "localhost.localdomain" --> Promise:D) {
    start {

        # Attempt ESMTP first
        my $hello = await self.EHLO($domain);
        if $hello.code == 250 {
            self.populate-keywords($hello);
        }

        # Fallback to SMTP
        else {
            $hello = await self.HELO($domain);
            $!socket-lock.protect: { %!keywords = () }
        }

        die X::Net::SMTP::Client::Async::Handshake.new(response => $hello)
            unless $hello.is-success;

        $hello;
    }
}

method start-tls(::?CLASS:D: Bool:D :$require-keyword = True --> Promise:D) {
    start {
        # If they expect an upgraded connection to be upgraded, let them catch
        # the exception here and ignore it.
        die X::Net::SMTP::Client::Async::Upgraded.new
            if $!secure;

        # If keyword checking is required, make sure STARTTLS is not supported
        die X::Net::SMTP::Client::Async::Support.new
            if $require-keyword and not %!keywords<STARTTLS>;

        # TODO Check %!keywords for STARTTLS support
        self.STARTTLS.then: -> $p {
            if $p.success {
                $!socket-lock.protect: {
                    self.upgrade-client;

                    # do not handle the exception, just QUIT if TLS fails
                    CATCH {
                        start { self.quit }
                    }

                    # pretend we are starting over with our connection
                    %!keywords = ();
                }
            }
            else {
                die X::Net::SMTP::Client::Async::Secure.new(
                    response => $p.result,
                );
            }

            $p.result;
        }
    }
}

method send-message(::?CLASS:D:
    Str:D :$from,
    Str:D :@to,
    Str:D :$message,
    --> Promise:D
) {
    start sub {
        my $mail = await self.MAIL($from);
        die X::Net::SMTP::Client::Async::Send.new(response => $mail)
            unless $mail.is-success;

        for @to -> $to {
            my $rcpt = await self.RCPT($to);
            die X::Net::SMTP::Client::Async::Send.new(response => $rcpt)
                unless $rcpt.is-success;
        }

        my $data = await self.DATA;
        die X::Net::SMTP::Client::Async::Send.new(response => $data)
            unless $data.is-success;

        # dot stuffing
        $message ~~ s:g/^ '.' /../;

        my $data-sent = await self.send-raw-messagse($message);
        die X::Net::SMTP::Client::Async::Send.new(response => $data-sent)
            unless $data-sent.is-success;

        $data-sent;
    }.();
}

method quit(::?CLASS:D: --> Promise:D) {
    start {
        my $resp = await self.QUIT;
        self.disconnect;
        $resp;
    }
}

method !begin-listening(::?CLASS:D:) {
    push @!taps, $!socket.Supply.lines.tap: {
        when /^
                $<code> = [ \d ** 3 ]
                $<continuation> = [ '-' | ' ' ]
                $<text> = [ .* ]
            $/ {

            $!response.send([ val(~$<code>), $<continuation> eq "-", ~$<text> ]);
        }

        default {
            $!response.fail(X::Net::SMTP::Client::Async::CommunicationFailure.new);
        }
    }

    push @!taps, $!command.Supply.tap: -> $cmd {
        $!socket-lock.protect: {
            $!socket.print: $cmd;
        }
    }
}

method !begin(::?CLASS:D:) {
    $!socket-lock.protect: {
        self!begin-listening;

        $!finished.then: -> $p {
            given $p.result {
                self!end;
                $!socket-lock.protect: {
                    $!socket.close;
                }
            }
        }
    }

    self;
}

method !end-listening(::CLASS:D:) {
    .close for @!taps;
    @!taps = ();
}

method !end(::?CLASS:D:) {
    $!socket-lock.protect: {
        self!end-listening;
    }
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

multi method populate-keywords(::?CLASS:D: Net::SMTP::Client::Async::Response:D $hello) {
    self.populate-keywords($hello.text);
}

multi method populate-keywords(::?CLASS:D: Str:D $hello-text) {
    $!socket-lock.protect: {
        %!keywords = gather for $hello-text.lines {
            if /^
                $<keyword> = [ <[ a..z A..Z 0..9 ]> <[ a..z A..Z 0..9 - ]>* ]
                [ ' ' $<params> = [ \S+ ] ]*
            $/ {
                if $<params> {
                    take "$<keyword>" => $<params>.map({ .Str });
                }
                else {
                    take "$<keyword>" => True;
                }
            }
        }
    }
}

method clear-keywords(::?CLASS:D:) {
    $!socket-lock.protect: {
        %!keywords = ();
    }
}

method upgrade-client(::?CLASS:D: *%passthru --> Promise:D) {
    start {
        # Prepare to switch sockets
        self!end-listening;

        # Switch sockets
        $!socket = await IO::Socket::Async::SSL.upgrade-client($!socket);
        $!secure = True;

        # Resume listening with the new socket, even on failure
        LEAVE self!begin-listening;
    }
}

method disconnect(::?CLASS:D:) {
    start {
        self!end;
        $!socket.close;
    }
}

method escape-message(Str:D $message --> Str:D) {
    $message.subst(/^ '.' /, '..', :g);
}

method send-command(::?CLASS:D: Str:D $command, Str $argument? --> Promise:D) {
    start {
        my $command-line = $command;
        $command-line ~= " $_" with $argument;

        $!command.send("$command $argument\r\n");

        self!handle-response;
    }
}

method EHLO(::?CLASS:D: Str:D $domain --> Promise:D) {
    self.send-command("EHLO", $domain);
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

method send-raw(::?CLASS:D: Str:D $raw --> Promise:D) {
    start {
        $!command.send($raw);
        True;
    }
}

method receive-raw(::?CLASS:D: --> Promise:D) {
    start {
        self!handle-response;
    }
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

method STARTTLS(::?CLASS:D: --> Promise:D) {
    self.send-command('STARTTLS');
}

method ETRN(::?CLASS:D: Str:D $node-name --> Promise:D) {
    self.send-command('ETRN', $node-name);
}

method AUTH(::?CLASS:D: Str:D $mechanism --> Promise:D) {
    self.send-command('AUTH', $mechanism);
}

=begin pod

=head1 NAME

Net::SMTP::Client::Async - asynchronous communication client for SMTP

=head1 SYNOPSIS

    use Net::SMTP::Client::Async;

    with await Net::SMTP::Client::Async.connect('smtp.gmail.com', 465, :secure) {
        await .hello;

        my $message = q:to/END_OF_MESSAGE/;
        To: Sterling <hanenkamp@cpan.org>
        From: Sterling <hanenkamp@cpan.org>
        Subject: Hello World

        Goodbye.
        END_OF_MESSAGE

        await .send-message(
            from => "hanenkamp@cpan.org",
            to   => [ "hanenkamp@cpan.org" ],
            :$message,
        );

        .quit;

        CATCH {
            when X::Net::SMTP::Client::Async {
                note "Unable to send email message: $_";
                .quit
            }
        }
    }

=head1 DESCRIPTION

This is an SMTP client library written using asynchronous methods. This class provides two interfaces:

=item B<Simple Message Sending API>. A high-level interface is provided for doing the initial connection handshake, sending a message, and quitting. This is probably the usual use of this library where you just want to send an email message to an SMTP server.

=item B<Complete Low Level API>. A low-level interface is provided that gives you direct access to any command you want to send to an SMTP server. It also provides low-level access to the responses from the SMTP server.

These interfaces are completely interchangeable and can be interleaved.

For example, consider this program which will connect to an ESMTP server on port 587, upgrade a plaintext connection to TLS and then send a message:

    use Net::SMTP::Client::Async;

    my $smtp = Net::SMTP::Client::Async.connect('smtp.gmail.com', 587);

    await $smtp.hello;
    await $smtp.start-tls;

    # After TLS, you must say hello again.
    await $smtp.hello;

    await $smtp.send-message(
        from    => "hanenkamp@cpan.org",
        to      => [ "hanenkamp@cpan.org" ],
        message => q:to/END_OF_MESSAGE/,
            To: Sterling <hanenkamp@cpan.org>
            From: Sterling <hanenkamp@cpan.org>
            Subject: Hello World

            Goodbye.
            END_OF_MESSAGE
    );

    $smtp.quit;

    CATCH {
        when X::Net::SMTP::Client::Async {
            note "Unable to send email message: $_";
            .quit
        }
    }

Now consider a similar program, but written solely using the low-level interface API:

    use Net::SMTP::Client::Async;

    my $smtp = Net::SMTP::Client::Async.connect('smtp.gmail.com', 587);

    my $ehlo = await $smtp.EHLO('localhost.localdomain');

    die "unable to perform SMTP handshake" if $ehlo.is-error;

    $smtp.populate-keywords($ehlo.text);

    die "STARTTLS is not supported by SMTP server" unless $smtp.keywords<STARTTLS>;

    my $start-tls = await $smtp.STARTTLS;
    die "unable to perform upgrade to secure SMTP connection" if $start-tls.is-error;

    $smtp.clear-keywords;

    my $upgrade = try {
        await $smtp.upgrade-client;

        CATCH {
            default {
                die "unable to negotiate SSL upgrade with client";
            }
        }
    }

    my $ehlo-again = await $smtp.EHLO('localhost.localdomain');
    die "unable to perform secure SMTP handshake" if $ehlo-again.is-error;

    $smtp.populate-keywords($ehlo-again.text);

    my $mail = await $smtp.MAIL('hanenkamp@cpan.org');
    die "unable to send mail FROM hanenkamp@cpan.org" if $mail.is-error;

    my $rcpt = await $smtp.RCPT('hanenkamp@cpan.org');
    die "unable to send mail TO hanenkamp@cpan.org" if $rcpt.is-error;

    my $data = await $smtp.DATA;
    die "unable to initiate message send" if $data.is-error;

    # perform dot-stuffing of the message
    my $message = $smtp.escape-message(q:to/END_OF_MESSAGE/);
        To: Sterling <hanenkamp@cpan.org>
        From: Sterling <hanenkamp@cpan.org>
        Subject: Hello World

        Goodbye.
        END_OF_MESSAGE

    my $message-response = await $smtp.send-raw-message($message);

    $smtp.QUIT;
    $smtp.disconnect;

These programs are not equivalent as the high-level methods perform additional error checking and such that is not being deon in the second program. This second program is just for illustration purposes.

The primary difference between the high-level and low-level APIs is that the high-level API provides errors through C<X::Net::SMTP::Client::Async> exceptions. The low-level API, on the other hand does no error checking and leaves it to the developer to do the error checking. You can do that by looking at the returned C<Net::SMTP::Client::Async::Response> and checking the details of that response, which includes the response code, the full text of the response (which may span multiple lines for some commands, but has the code parts at the start of every line removed), and some convenience methods for detecting success and errors.

The only exception to the no error checking rule is the L<.upgrade-client|#method upgrade-client> method. This is due to the fact that this is a call-out to the method with the same name in L<IO::Socket::Async::SSL>, which passes SSL exception from failed SSL negotiation through to the caller.

The other difference between the high-level and low-level interfaces is that it is possible for the object to enter a state that is not consistent with the connection. The high-level interface works harder to prevent this by perform the state transitions required automatically.

For example, consider the situation where you use L<.STARTTLS|#method STARTTLS> to request SSL negotiation and receive a favorable 250 code response. However, you then call another method other than C<.upgrade-client>. Unless you have a non-conforming SMTP server, your client is almost certainly in the wrong state compared to the server. On the other hand, this also means you can use features of SMTP that the high-level interface does not implement or permit, which is the point.

If you have a SMTP server where you need to do something that takes you off the beaten path of sending a fairly simple email message, you should be able to do that with this library. For example, if you use the high-level C<.start-tls> command and SSL negotiation fails, the connection will close. However, if you use the low-level C<.STARTTLS> and C<.upgrade-client> methods, you can implement a client that gracefully recovers from a failure to negotiate SSL.

=head1 CONCURRENCY

This class is intended to be thread safe. However, it is also fairly immature, so there might be some bugs with that.

Internally, any command sent to the SMTP socket is queued up using a L<Channel>. This means all commands will be executed in the order they are received. Commands may be sent before the response has been received if you do not make sure to C<await> on the previous method call before calling another. For this resonse, it is recommended that you perform an C<await> prior to calling another method.

All state within the object is protected by a L<Lock> using a monitor pattern. The state of the object returned by the accessors will never be partially constructed. However, it is still possible to use the returned state in an unsafe way if a method, which changes state is called. This includes the following methods:

=item L<.hello|#method hello>

=item L<.start-tls|#method start-tls>

=item L<.upgrade-client|#method upgrade-client>

Other methods may also change state, but they will be clearly documented below.

Additional precautions should be taken around the calls of these methods or any state-changing methods to make sure that the operation is complete I<before> accessing the attributes of the method. Otherwise, you I<will> end up with thread safety problems.

=head1 METHODS

=head2 method socket

    has $.socket

This will be either a L<IO::Socket::Async> or a L<IO::Socket::Async::SSL> object which represents the underlying connection to the SMTP server. As long as the object is defined, this will also be defined. After L<.quit|#method quit> or L<.disconnect|#method disconnect> has been called, though, the object will be in a disconnected state.

=head2 method secure

    has Bool $.secure = False

This flag will be set to C<False> if the connection to the SMTP server is a plain text connection or to C<True> if the connection is currently secure. It will be set to C<True> if the socket is upgraded to use SSL.

=head2 method keywords

    has %.keywords

This hash will be populated after the client has successfully performed an ESMTP handshake during L<.hello|#method hello> or by calling L<.populate-keywords|#method populate-keywords>. If the SMTP object is used to initiate a plaintext connection and then upgraded using L<.start-tls|#method start-tls> or clared using L<.clear-keywords|#method clear-keywords>, these will be cleared again. This is because the ESMTP handshake must be performed again after upgrading the connection to a secure connection as the server may provide different keywords for secure connections than it provides for unsecure connections.

The keywords are typically the name of supported extended commands. The value of the keywords is set to C<True> if no parameters are provided. If parameters are provided, then the value of that keyword will be set to the list of those parameters:

    my $smtp = Net::SMTP::Client::Async.new;
    await $smtp.hello;
    say "Supports STARTTLS" if $smtp.keywords<STARTTLS>;
    say "Supports these SASL plugins: $smtp.keywords<AUTH>.join(', ')" if $smtp.keywords<AUTH>;

=head2 method connect

    multi method connect(IO::Socket::Async $socket --> Promise:D)
    multi method connect(IO::Socket::Async::SSL $socket --> Promise:D)
    multi method connect(Str :$host, UInt :$port, Bool :$secure --> Promise:D)

These are the constructors for L<Net::SMTP::Client::Async>. These establish a connection to the SMTP server or allow the object to adopt a previously established connection to an SMTP server. If an L<IO::Socket::Async> object is given, the L<.secure|#method secure> flag will be C<False>. If an L<IO::Socket::Async::SSL> object is given, the C<.secure> flag will be C<True>.

If called with no arguments or called with some combination of C<$host>, C<$port>, and C<$secure>, the constructor will make the connection for you. The default C<$host> is C<"localhost">. The default C<$port> is 25 if C<$secure> is not set or 465 if C<$secure> is set. The default value for C<$secure> is C<False>.

Each of these methods return a L<Promise>, which will be fulfilled once the connection has been established and the object constructed. The promise is kept with a L<Net::SMTP::Client::Async> object.

That constructed object will not have performed the initial SMTP handshake. Therefore, you will need to immediately call L<.hello|#method hello> or L<.EHLO|#method EHLO> or L<.HELO|#method HELO> to complete the connection process.

=head2 method hello

    method hello(Str:D $domain = "localhost.localdomain" --> Promise:D)

On success, this method updates the state of this object by either setting or clearing the C<keywords>.

This method will attempt to perform an ESMTP handshake (i.e., C<EHLO>) with the SMTP server. If that handshake succeeds, it will parse the response and place all the announced keywords and paramters into L<.keywords|#method keywords>.

If the ESMTP handshake fails, this method will attempt to fallback on SMTP handshake (i.e., C<HELO>). In this case, C<.keywords> will remain empty.

The method returns a L<Promise>. On failure, the C<Promise> will be broken with a L<X::Net::SMTP::Client::Async::Handshake|X::Net::SMTP::Client::Async#class X::Net::SMTP::Client::Async::Handshake> exception. On success, the C<Promise> is kept with a L<Net::SMTP::Client::Async::Response> containing a successful response.

=head2 method start-tls

    method start-tls(--> Promise:D)

On success, this method updates the state of this object by clearing the C<keywords> and setting the C<secure> flag to C<True>.

This method returns a L<Promise>, which will be kept if the operation completes successfully with the L<Net::SMTP::Client::Async::Response> object showing the successful response from the server. If the operation fails to secure the connection by first sending the C<STARTTLS> command and then performing a successful SSL negotiation, it will be broken with an exception.

If an ESMTP handshake has not completed or the ESMTP server does not list C<STARTTLS> support, the returned C<Promise> will be broken with an L<X::Net::SMTP::Client::Async::Support|X::Net::SMTP::Client::Async#class X::Net::SMTP::Client::Async::Support> exception.

If the connection is already secure or if the C<STARTTLS> command results in an error response, the returned C<Promise> will be broken with an L<X::Net::SMTP::Client::Async::Secure|x::SMTP::Client::Async#class X::Net::SMTP::Client::Async::Secure> exception.

If the SSL handshake fails, the returned C<Promise> will be broken with an exception from OpenSSL.

If the returned C<Promise> is broken fro any resonse, the connection to the SMTP server will also be disconnected and the L<Net::SMTP::Client::Async> object is now no longer in a usable state and should be discarded.

=head2 method send-message

    method send-message(
        Str:D :$from!,
        Str:D :@to!,
        Str:D :$message!,
        --> Promise:D
    )

This method performs the work required for sending an SMTP message. This means sending the C<MAIL> command with the given C<$from> address, teh C<RCPT> command for each given C<@to> address, the C<DATA> command to start sending data, and then the C<$message> itself followed by a line containing only a ".". The C<$message> will have "dot stuffing" performed on it as well.

The method returns a L<Promise> which will be kept with the final successful L<Net::SMTP::Client::Async::Response> received after transmitting the message. If any step of the process fails, the returned C<Promise> will be broken with the L<X::Net::SMTP::Client::Async::Send|X::Net::SMTP::Client::Async#class X::Net::SMTP::Client::Async::Send> exception.

=head2 method quit

    method quit(--> Promise:D)

After this method is called, no other method should be called on this object. The object should now be discarded and cannot be reused.

This sends a C<QUIT> command to the SMTP serer and disconnects the socket.

The returned C<Promise> will be kept with the result of the L<Net::SMTP::Client::Async::Result> returned by the server after sending teh C<QUIT> command.

=head2 method send-command

    method send-command(Str:D $command, Str $argument? --> Promise:D)

This is a low-level method.

This will send any arbitrary command to the SMTP server with the given argument. Nothing special is done to escape or prepare the values sent other than having a space inserted between C<$command> and C<$argument> (assuming C<$argument> is specified at all).

The returned L<Promise> will be kept with a L<Net::SMTP::Client::Async::Response> object containing the response from the server for that command. This class will not break the returned C<Promies>, so if it is broken, something unexpected has gone wrong.

=head2 method EHLO

    method EHLO(Str:D $domain --> Promise:D)

This is a low-level method.

This will send the C<EHLO> command and return a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method populate-keywords

    multi method populate-keywords(Net::SMTP::Client::Async::Response:D $text)
    multi method populate-keywords(Str:D $text)

This is a low-level method.

This will set the L<.keywords|#method keywords> attribute to the keywords found in the message. If passed as a string, it should be text the format returned by L<Net::SMTP::Client::Async::Response> by the C<.text> method.

=head2 method clear-keywords

    method clear-keywords()

This is a low-level method.

This will clear the L<.keywords|#method keywords> attribute. This should be called when the capabilities of the SMTP server were previously known, but now are not. (I.e., after C<STARTTLS>).

=head2 method HELO

    method HELO(Str:D $domain --> Promise:D)

This is a low-level method.

This will send the C<HELO> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method MAIL

    method MAIL(Str:D $from --> Promise:D)

This is a low-level method.

This will send the C<MAIL> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

The C<$from> argument will have the "FROM:" prefix added to it automatically before being sent to the SMTP server.

=head2 method RCPT

    method RCPT(Str:D $to --> Promise:D)

This is a low-level method.

This will send the C<RCPT> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

The C<$to> argument will have the "TO:" prefix added to it automatically before being sent to the SMTP server.

=head2 method DATA

    method DATA(--> Promise:D)

This is a low-level method.

This will send the C<DATA> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method escape-message

    method escape-message(Str:D $message --> Str:D)

This is a low-level method.

You only need this if you are using L<.send-raw-message|#method send-raw-message>. This performs "dot stuffing" on the given string. That is, SMTP uses a line containing a single period to mark the end of a message. In order to make sure that users never see this, the SMTP server will ignore the first period that starts any line that contains any text other than a single period. Therefore, dot stuffing is the process of escaping any line that starts with a period by adding an additional period to the start of those lines.

The string returned byt this method will have an extra period added to any line that starts with a period.

=head2 method send-raw-message

    method send-raw-message(Str:D $raw-message --> Promise:D)

This is a low-level method.

This will send message content to the SMTP server followed by a ".". This will not perform any "dot stuffing" on the message. See L<.escape-message|#method escape-message>.

This will return a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method RSET

    method RSET(--> Promise:D)

This is a low-level method.

This will send the C<RSET> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method SEND

    method SEND(Str:D $from --> Promise:D)

This is a low-level method.

This will send the C<SEND> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method SOML

    method SOML(Str:D $from --> Promise:D)

This is a low-level method.

This will send the C<SOML> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method SAML

    method SAML(Str:D $from --> Promise:D)

This is a low-level method.

This will send the C<SAML> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method VRFY

    method VRFY(Str:D $string --> Promise:D)

This is a low-level method.

This will send the C<VRFY> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method EXPN

    method EXPN(Str:D $string --> Promise:D)

This is a low-level method.

This will send the C<EXPN> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method HELP

    method HELP(Str:D $string? --> Promise:D)

This is a low-level method.

This will send the C<HELP> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method NOOP

    method NOOP(--> Promise:D)

This is a low-level method.

This will send the C<NOOP> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method QUIT

    method QUIT(--> Promise:D)

This is a low-level method.

This will send the C<QUIT> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method disconnect

    method disconnect(--> Promise:D)

This is a low-level method.

Normally, to close your connection, you should issue a call to the L<.quit|#method quit> method. This closes the connection to the SMTP server without issuing a C<QUIT> command. It also makes sure any internally queued actions stop working.

After this method has been called, the object is in an unusable state and should be discarded.

=head2 method TURN

    method TURN(--> Promise:D)

This is a low-level method.

This will send the C<TURN> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method STARTTLS

    method STARTTLS(--> Promise:D)

This is a low-level method.

This will send the C<STARTTLS> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method upgrade-client

    method upgrade-client(*%passthru --> Promise:D)

This is a low-level method.

This upgrades the current socket from L<IO::Socket::Async> to L<IO::Socket::Async::SSL>. All arguments are passed through to the C<.upgrade-client> method of L<IO::Socket::Async::SSL>.

=head2 method ETRN

    method ETRN(Str:D $node-name --> Promise:D)

This is a low-level method.

This will send the C<ETRN> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method AUTH

    method AUTH(Str:D $mechanism --> Promise:D)

This is a low-level method.

This will send the C<AUTH> command and returns a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response>.

=head2 method send-raw

    method send-raw(Str:D $string --> Promise:D)

This is a low-level method.

This queues a data send of the given string. The string is passed through, as is. The method returns a L<Promise> which will be kept with a C<True>, but makes no guarantee that the send has actually occurred. If you need that, then you need to work directly with the L<.socket|#method socket> itself.

=head2 method receive-raw

    method receive-raw(--> Promise:D)

This is a low-level method.

This will return a L<Promise> that will be kept with a L<Net::SMTP::Client::Async::Response> containing the next response sent by the SMTP server.

=end pod
