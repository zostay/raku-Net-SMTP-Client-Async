use v6;

unit class Net::SMTP::Client::Async::Response;

has Int $.code;
has Str $.text;

method is-success(--> Bool:D) { 100 <= $!code < 400 }
method is-error(--> Bool:D) { 400 <= $!code }
method is-transient-error(--> Bool:D) { 400 <= $!code < 500 }
method is-permanent-error(--> Bool:D) { 500 <= $!code }

=begin pod

=head1 NAME

Net::SMTP::Client::Async::Response - SMTP server responses

=head1 SYNOPSIS

    use Net::SMTP::Client::Async;

    my $smtp = await Net::SMTP::Client::Async.connect;
    my Net::SMTP::Client::Async::Response $resp = await $smtp.hello;

    say "Success? $resp.is-success()";
    say "Error? $resp.is-error()";
    say "Transient? $resp.is-transient-error()";
    say "Permanent? $resp.is-permanent-error()";
    say "Code: $resp.code()";
    say "Text: $resp.text()";

=head1 DESCRIPTION

Most of the methods in L<Net::SMTP::Client::Async> return a L<Promise> which is kept with an object of this type. It will give you detailed information about the response by the SMTP server.

=head1 METHODS

=head2 method code

    has Int $.code

This will be the 3-digit code returned by the SMTP server. It is used to determine success or failure of command that was just run and can describe how the command succeeded or failed in some cases.

=head2 method text

    has Str $.text

This will be the textual part of the response from the SMTP server. This is an informative message that matches the code for most responses. Some responses contain additional data (particularly the response to C<EHLO>).

The text will be all lines of the response (usually just one line), but the first 4 characters containing the 3 digit code and either a dash or space will have been remoted, so it just includes the text of the message itself.

=head2 method is-success

    method is-success(--> Bool:D)

Returns C<True> if and only if the L<.code|#method code> is in the range of 100 to 399.

=head2 method is-error

    method is-error(--> Bool:D)

Returns C<True> if and only if the L<.code|#method code> is equal to or greater than 400.

=head2 method is-transient-error

    method is-transient-error(--> Bool:D)

Returns C<True> if and only if the L<.code|#method code> is in the range of 400 to 499.

=head2 method is-permanent-error

    method is-permanent-error(--> Bool:D)

Returns C<True> if and only if the L<.code|#method code> is greater than or equal to 500.

=end pod
