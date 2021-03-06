use strict;
use lib 'lib', 't/app/trivial/lib';
use Test::More;
use Plack::Test;
use HTTP::Request::Common;

BEGIN {
  $ENV{CBCONFIG} = "$ENV{CBROOT}/t/app/trivial/combust.conf";
  $ENV{CBROOTLOCAL} = "$ENV{CBROOT}/t/app/trivial/";
}

use_ok('Trivial::App');
ok(my $app = Trivial::App->new, 'new app');

   test_psgi
     app => $app->reference,
     client => sub {
       my $cb = shift;
       my $res = $cb->(GET "/three.html");
       like $res->content, qr/Hello World/, "three.html";

       $res = $cb->(GET "/three");
       like $res->content, qr/Hello Static/, "/three";

       $res = $cb->(GET "/two/redirect");
       like $res->content, qr/The document has moved/, "/two/redirect";
       is $res->header('location'), "http://www.cpan.org/";

       $res = $cb->(GET "/four");
       like $res->content, qr/The document has moved/, "/four redirect via .htredirects";
       is $res->header('location'), "http://one.example.com/two";

       $res = $cb->(GET "/five");
       like $res->content, qr/The time is now/, "/two internal redirect via .htredirects";
       is $res->header('location'), undef, "No redirection header";

       ok($res = $cb->(GET "/six"), "/six - perm redirect via .htredirects");
       is $res->header('location'), 'http://www.perl.org/', "Correct redirect header";
       is $res->code, 301, "301 response";

       ok($res = $cb->(GET "http://two.example.com/"), "site 'two' homepage");
       is $res->code, 200, "200 response";
       like $res->content, qr/site: two/, "correct content";



   };


done_testing();