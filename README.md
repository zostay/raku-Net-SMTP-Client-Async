NAME
====

Net::SMTP::Client::Async - asynchronous communication client for SMTP

SYNOPSIS
========

    use Net::SMTP::Client::Async;

    with await Net::SMTP::Client::Async.connect(:host<smtp.gmail.com>, :port(465), :secure) {
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

DESCRIPTION
===========

This is an SMTP client library written using asynchronous methods. This class provides two interfaces:

  * **Simple Message Sending API**. A high-level interface is provided for doing the initial connection handshake, sending a message, and quitting. This is probably the usual use of this library where you just want to send an email message to an SMTP server.

  * **Complete Low Level API**. A low-level interface is provided that gives you direct access to any command you want to send to an SMTP server. It also provides low-level access to the responses from the SMTP server.

These interfaces are completely interchangeable and can be interleaved.

For example, consider this program which will connect to an ESMTP server on port 587, upgrade a plaintext connection to TLS and then send a message:

    use Net::SMTP::Client::Async;

    my $smtp = Net::SMTP::Client::Async.connect(
        :host<smtp.gmail.com>, :port(587),
    );

    await $smtp.hello;
    await $smtp.start-tls(:host<smtp.gmail.com>);

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

    my $smtp = Net::SMTP::Client::Async.connect(
        :host<smtp.gmail.com>, :port(587),
    );

    my $ehlo = await $smtp.EHLO('localhost.localdomain');

    die "unable to perform SMTP handshake" if $ehlo.is-error;

    $smtp.populate-keywords($ehlo.text);

    die "STARTTLS is not supported by SMTP server" unless $smtp.keywords<STARTTLS>;

    my $start-tls = await $smtp.STARTTLS;
    die "unable to perform upgrade to secure SMTP connection" if $start-tls.is-error;

    $smtp.clear-keywords;

    my $upgrade = try {
        await $smtp.upgrade-client(:host<smtp.gmail.com>);

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

These programs are not equivalent as the high-level methods perform additional error checking and such that is not being deon in the second program. However, the second program illustrates what is possible.

Aside from the change in interface, the greatest difference between the high-level and low-level APIs is that the high-level API provides errors through `X::Net::SMTP::Client::Async` exceptions. The low-level API, on the other hand does no error checking and leaves it to the developer to do the error checking. You can do that by looking at the returned `Net::SMTP::Client::Async::Response` and checking the details of that response, which includes the response code, the full text of the response (which may span multiple lines for some commands, but has the code parts at the start of every line removed), and some convenience methods for detecting success and errors.

The only exception to the no error checking rule is the [.upgrade-client](#method upgrade-client) method. This is due to the fact that this is a call-out to the method with the same name in [IO::Socket::Async::SSL](IO::Socket::Async::SSL), which passes SSL exception from failed SSL negotiation through to the caller.

Another difference between the high-level and low-level interfaces is that the high-level interface guarantees thread safety. The high-level interface works to keep the object and connection consistent and prevents the state from being corrupted across threads. The low-level interface provides fewer guarantees.

For example, consider the situation where you use [.STARTTLS](#method STARTTLS) to request SSL negotiation and receive a favorable 250 code response. However, you then call another method other than `.upgrade-client`. If you do that, your client will be in the wrong state compared to the server. On the other hand, this also means you can use features of SMTP that the high-level interface does not implement or permit, which is the primary purpose of the low-level interface.

If you have an SMTP server where you need to do something that takes you off the beaten path of sending a fairly simple email message, you should be able to do that with this library.

CONCURRENCY
===========

This class is intended to be thread safe. However, it is also fairly immature, so there might be some bugs with that.

Internally, any command sent to the SMTP socket is queued up using a [Channel](Channel). This means all commands will be executed in the order they are received. Commands may be sent before the response has been received if you do not make sure to `await` on the previous method call before calling another, which could result in unrecoverable errors. For this reason, it is recommended that you perform an `await` prior to calling another method.

Internal state within the object is protected by a [Lock](Lock) using a monitor pattern. The state of the object returned by the accessors will never be partially constructed. However, it is still possible to use the returned state in an unsafe way if a method, which changes state is called. This includes the following methods:

  * [.hello](#method hello)

  * [.start-tls](#method start-tls)

  * [.upgrade-client](#method upgrade-client)

Other methods may also change state. Those changes are clearly documented in each method's documentation.

Additional precautions should be taken around the calls of these methods or any state-changing methods to make sure that the operation is complete *before* accessing the attributes of the method. Otherwise, you *will* end up with thread safety problems.

METHODS
=======

method socket
-------------

    has $.socket

This will be either a [IO::Socket::Async](IO::Socket::Async) or a [IO::Socket::Async::SSL](IO::Socket::Async::SSL) object which represents the underlying connection to the SMTP server. As long as the object is defined, this will also be defined. After [.quit](#method quit) or [.disconnect](#method disconnect) has been called, though, the object will be in a disconnected state.

method secure
-------------

    has Bool $.secure = False

This flag will be set to `False` if the connection to the SMTP server is a plain text connection or to `True` if the connection is currently secure. It will be set to `True` if the socket is upgraded to use SSL.

method keywords
---------------

    has %.keywords

This hash will be populated after the client has successfully performed an ESMTP handshake during [.hello](#method hello) or by calling [.populate-keywords](#method populate-keywords). If the SMTP object is used to initiate a plaintext connection and then upgraded using [.start-tls](#method start-tls) or clared using [.clear-keywords](#method clear-keywords), these will be cleared again. This is because the ESMTP handshake must be performed again after upgrading the connection to a secure connection as the server may provide different keywords for secure connections than it provides for unsecure connections.

The keywords are typically the name of supported extended commands. The value of the keywords is set to `True` if no parameters are provided. If parameters are provided, then the value of that keyword will be set to the list of those parameters:

    my $smtp = Net::SMTP::Client::Async.new;
    await $smtp.hello;
    say "Supports STARTTLS" if $smtp.keywords<STARTTLS>;
    say "Supports these SASL plugins: $smtp.keywords<AUTH>.join(', ')" if $smtp.keywords<AUTH>;

method connect
--------------

    multi method connect(IO::Socket::Async $socket --> Promise:D)
    multi method connect(IO::Socket::Async::SSL $socket --> Promise:D)
    multi method connect(Str :$host, UInt :$port, Bool :$secure --> Promise:D)

These are the constructors for [Net::SMTP::Client::Async](Net::SMTP::Client::Async). These establish a connection to the SMTP server or allow the object to adopt a previously established connection to an SMTP server. If an [IO::Socket::Async](IO::Socket::Async) object is given, the [.secure](#method secure) flag will be `False`. If an [IO::Socket::Async::SSL](IO::Socket::Async::SSL) object is given, the `.secure` flag will be `True`.

If called with no arguments or called with some combination of `$host`, `$port`, and `$secure`, the constructor will make the connection for you. The default `$host` is `"localhost"`. The default `$port` is 25 if `$secure` is not set or 465 if `$secure` is set. The default value for `$secure` is `False`.

Each of these methods return a [Promise](Promise), which will be fulfilled once the connection has been established and the object constructed. The promise is kept with a [Net::SMTP::Client::Async](Net::SMTP::Client::Async) object.

That constructed object will not have performed the initial SMTP handshake. Therefore, you will need to immediately call [.hello](#method hello) or [.EHLO](#method EHLO) or [.HELO](#method HELO) to complete the connection process.

method hello
------------

    method hello(Str:D $domain = "localhost.localdomain" --> Promise:D)

On success, this method updates the state of this object by either setting or clearing the `keywords`.

This method will attempt to perform an ESMTP handshake (i.e., `EHLO`) with the SMTP server. If that handshake succeeds, it will parse the response and place all the announced keywords and paramters into the [.keywords attribute](#method keywords).

If the ESMTP handshake fails, this method will attempt to fallback on SMTP handshake (i.e., `HELO`). In this case, `.keywords` will remain empty.

The method returns a [Promise](Promise). On failure, the `Promise` will be broken with a [X::Net::SMTP::Client::Async::Handshake](X::Net::SMTP::Client::Async#class X::Net::SMTP::Client::Async::Handshake) exception. On success, the `Promise` is kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response) containing a successful response.

method start-tls
----------------

    method start-tls(--> Promise:D)

On success, this method updates the state of this object by clearing the `keywords` and setting the `secure` flag to `True`.

This method returns a [Promise](Promise), which will be kept if the operation completes successfully with the [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response) object showing the successful response from the server. If the operation fails to secure the connection by first sending the `STARTTLS` command and then performing a successful SSL negotiation, it will be broken with an exception.

If an ESMTP handshake has not completed or the ESMTP server does not list `STARTTLS` support, the returned `Promise` will be broken with an [X::Net::SMTP::Client::Async::Support](X::Net::SMTP::Client::Async#class X::Net::SMTP::Client::Async::Support) exception.

If the connection is already secure or if the `STARTTLS` command results in an error response, the returned `Promise` will be broken with an [X::Net::SMTP::Client::Async::Secure](x::SMTP::Client::Async#class X::Net::SMTP::Client::Async::Secure) exception.

If the SSL handshake fails, the returned `Promise` will be broken with an exception from OpenSSL.

If the returned `Promise` is broken fro any resonse, the connection to the SMTP server will also be disconnected and the [Net::SMTP::Client::Async](Net::SMTP::Client::Async) object is now no longer in a usable state and should be discarded.

method send-message
-------------------

    method send-message(
        Str:D :$from!,
        Str:D :@to!,
        Str:D :$message!,
        --> Promise:D
    )

This method performs the work required for sending an SMTP message. This means sending the `MAIL` command with the given `$from` address, teh `RCPT` command for each given `@to` address, the `DATA` command to start sending data, and then the `$message` itself followed by a line containing only a ".". The `$message` will have "dot stuffing" performed on it as well.

The method returns a [Promise](Promise) which will be kept with the final successful [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response) received after transmitting the message. If any step of the process fails, the returned `Promise` will be broken with the [X::Net::SMTP::Client::Async::Send](X::Net::SMTP::Client::Async#class X::Net::SMTP::Client::Async::Send) exception.

method quit
-----------

    method quit(--> Promise:D)

After this method is called, no other method should be called on this object. The object should now be discarded and cannot be reused.

This sends a `QUIT` command to the SMTP serer and disconnects the socket.

The returned `Promise` will be kept with the result of the [Net::SMTP::Client::Async::Result](Net::SMTP::Client::Async::Result) returned by the server after sending teh `QUIT` command.

method send-command
-------------------

    method send-command(Str:D $command, Str $argument? --> Promise:D)

This is a low-level method.

This will send any arbitrary command to the SMTP server with the given argument. Nothing special is done to escape or prepare the values sent other than having a space inserted between `$command` and `$argument` (assuming `$argument` is specified at all).

The returned [Promise](Promise) will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response) object containing the response from the server for that command. This class will not break the returned `Promies`, so if it is broken, something unexpected has gone wrong.

method EHLO
-----------

    method EHLO(Str:D $domain --> Promise:D)

This is a low-level method.

This will send the `EHLO` command and return a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method populate-keywords
------------------------

    multi method populate-keywords(Net::SMTP::Client::Async::Response:D $text)
    multi method populate-keywords(Str:D $text)

This is a low-level method.

This will set the [.keywords](#method keywords) attribute to the keywords found in the message. If passed as a string, it should be text the format returned by [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response) by the `.text` method.

method clear-keywords
---------------------

    method clear-keywords()

This is a low-level method.

This will clear the [.keywords](#method keywords) attribute. This should be called when the capabilities of the SMTP server were previously known, but now are not. (I.e., after `STARTTLS`).

method HELO
-----------

    method HELO(Str:D $domain --> Promise:D)

This is a low-level method.

This will send the `HELO` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method MAIL
-----------

    method MAIL(Str:D $from --> Promise:D)

This is a low-level method.

This will send the `MAIL` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

The `$from` argument will have the "FROM:" prefix added to it automatically before being sent to the SMTP server.

method RCPT
-----------

    method RCPT(Str:D $to --> Promise:D)

This is a low-level method.

This will send the `RCPT` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

The `$to` argument will have the "TO:" prefix added to it automatically before being sent to the SMTP server.

method DATA
-----------

    method DATA(--> Promise:D)

This is a low-level method.

This will send the `DATA` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method escape-message
---------------------

    method escape-message(Str:D $message --> Str:D)

This is a low-level method.

You only need this if you are using [.send-raw-message](#method send-raw-message). This performs "dot stuffing" on the given string. That is, SMTP uses a line containing a single period to mark the end of a message. In order to make sure that users never see this, the SMTP server will ignore the first period that starts any line that contains any text other than a single period. Therefore, dot stuffing is the process of escaping any line that starts with a period by adding an additional period to the start of those lines.

The string returned byt this method will have an extra period added to any line that starts with a period.

method send-raw-message
-----------------------

    method send-raw-message(Str:D $raw-message --> Promise:D)

This is a low-level method.

This will send message content to the SMTP server followed by a ".". This will not perform any "dot stuffing" on the message. See [.escape-message](#method escape-message).

This will return a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method RSET
-----------

    method RSET(--> Promise:D)

This is a low-level method.

This will send the `RSET` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method SEND
-----------

    method SEND(Str:D $from --> Promise:D)

This is a low-level method.

This will send the `SEND` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method SOML
-----------

    method SOML(Str:D $from --> Promise:D)

This is a low-level method.

This will send the `SOML` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method SAML
-----------

    method SAML(Str:D $from --> Promise:D)

This is a low-level method.

This will send the `SAML` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method VRFY
-----------

    method VRFY(Str:D $string --> Promise:D)

This is a low-level method.

This will send the `VRFY` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method EXPN
-----------

    method EXPN(Str:D $string --> Promise:D)

This is a low-level method.

This will send the `EXPN` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method HELP
-----------

    method HELP(Str:D $string? --> Promise:D)

This is a low-level method.

This will send the `HELP` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method NOOP
-----------

    method NOOP(--> Promise:D)

This is a low-level method.

This will send the `NOOP` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method QUIT
-----------

    method QUIT(--> Promise:D)

This is a low-level method.

This will send the `QUIT` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method disconnect
-----------------

    method disconnect(--> Promise:D)

This is a low-level method.

Normally, to close your connection, you should issue a call to the [.quit](#method quit) method. This closes the connection to the SMTP server without issuing a `QUIT` command. It also makes sure any internally queued actions stop working.

After this method has been called, the object is in an unusable state and should be discarded.

method TURN
-----------

    method TURN(--> Promise:D)

This is a low-level method.

This will send the `TURN` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method STARTTLS
---------------

    method STARTTLS(--> Promise:D)

This is a low-level method.

This will send the `STARTTLS` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method upgrade-client
---------------------

    method upgrade-client(*%passthru --> Promise:D)

This is a low-level method.

This upgrades the current socket from [IO::Socket::Async](IO::Socket::Async) to [IO::Socket::Async::SSL](IO::Socket::Async::SSL). All arguments are passed through to the `.upgrade-client` method of [IO::Socket::Async::SSL](IO::Socket::Async::SSL).

method ETRN
-----------

    method ETRN(Str:D $node-name --> Promise:D)

This is a low-level method.

This will send the `ETRN` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method AUTH
-----------

    method AUTH(Str:D $mechanism --> Promise:D)

This is a low-level method.

This will send the `AUTH` command and returns a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response).

method send-raw
---------------

    method send-raw(Str:D $string --> Promise:D)

This is a low-level method.

This queues a data send of the given string. The string is passed through, as is. The method returns a [Promise](Promise) which will be kept with a `True`, but makes no guarantee that the send has actually occurred. If you need that, then you need to work directly with the [.socket](#method socket) itself.

method receive-raw
------------------

    method receive-raw(--> Promise:D)

This is a low-level method.

This will return a [Promise](Promise) that will be kept with a [Net::SMTP::Client::Async::Response](Net::SMTP::Client::Async::Response) containing the next response sent by the SMTP server.

