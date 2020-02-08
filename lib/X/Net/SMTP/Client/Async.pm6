use v6;

unit package X::Net::SMTP::Client;

use Net::SMTP::Client::Async::Response;

class Async is Exception {
    has Net::SMTP::Client::Async::Response $.response;

    method has-response(--> Bool:D) { $!response.defined }

    method code(--> Int) { $.has-response ?? $!response.code !! Nil }
    method text(--> Str) { $.has-response ?? $!response.text !! Nil }

    method internal-message(--> Str:D) { "unknown SMTP error" }

    method message(--> Str:D) {
        with $!response {
            sprintf "%s (%d): %s",
                $.internal-message,
                $.code,
                $.text,
                ;
        }
        else {
            $.internal-message;
        }
    }
}

class Async::Connect is Async {
    method internal-message(--> Str:D) {
        "SMTP server reports error on connect"
    }
}

class Async::Handshake is Async {
    method internal-message(--> Str:D) {
        "SMTP EHLO and HELO handshake failed"
    }
}

class Async::Support is Async {
    has Str $.command is required;
    has Str $.detail;

    method internal-message(--> Str:D) {
        "SMTP command $!command is not supported"
            ~ do with $!detail { "; $!detail" } else { '' };
    }
}

class Async::Upgraded is Async {
    method internal-message(--> Str:D) {
        "SMTP connection is already secure";
    }
}

class Async::Secure is Async {
    method internal-message(--> Str:D) {
        "SMTP secure handshake failed";
    }
}

class Async::Send is Async {
    method internal-message(--> Str:D) {
        "SMTP mail message send failed";
    }
}

class Async::Auth is Async {
    method internal-message(--> Str:D) {
        "SMTP AUTH has failed"
    }
}

=begin pod

=head1 NAME

X::Net::SMTP::Client::Async - exceptions for Net::SMTP::Client::Async

=head1 DESCRIPTION

All the exceptions thrown by L<Net::SMTP::Client::Async> inherit from C<X::Net::SMTP::Client::Async> and provide the same interface. Unless otherwise documented here, only the message differs.

=head1 METHODS

=head2 method response

    has Net::SMTP::Client::Async::Response $.response

If set, this will be the SMTP server response that triggered the exception. You can check the L<.has-response|#method has-response> method to see if it has been set.

=head2 method has-response

    method has-response(--> Bool:D)

Returns C<True> only if this exception was caused by an SMTP server response.

=head2 method code

    method code(--> Int)

Returns the SMTP server response code that caused this exception if the SMTP server caused the exception. Otherwise it returns an C<Int> type object.

=head2 method text

    method text(--> Str)

Returns the SMTP server response message text of the SMTP server resopnse that caused this exception. If this exception was not caused by an SMTP server response, it will return a C<Str> type object instead.

=head2 method message

    method message(--> Str:D)

This returns the message of the exception. If an SMTP server response caused this exception, the text and code of the server response will be included in the message.

=head1 EXCEPTIONS

=head2 class X::Net::SMTP::Client:::Async

This is the parent class of all exceptions. This exception will not be thrown directly by L<Net::SMTP::Client::Async>.

=head2 class X::Net::SMTP::Client::Async::Handshake

This exception is thrown if there is an error performing the ESMTP C<EHLO> command and the SMTP C<HELO> command.

=head2 class X::Net::SMTP::Client::Async::Support

This exception will be thrown if a high-level API call requires the SMTP server to supported an extended command, but that server does not report support for that command.

=head2 class X::Net::SMTP::Client::Async::Upgraded

This excpetion will be thrown if the connection is already secure, but an upgrade is requested.

=head2 class X::Net::SMTP::Client::Async::Secure

This exception will be thrown if an error occurs while requesting a TLS upgrade. This occurs when an error response is returned by the server to the C<STARTTLS> command. SSL negotiation errors will be thrown directly.

=head2 class X::Net::SMTP::Client::Async::Send

This exception is thrown when an error occurs during any step of the C<MAIL>, C<RCPT>, C<DATA>, and mail sending process.

=end pod
