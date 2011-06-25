use Test::More;

use_ok('Combust::Request::Plack');

my $env = {
   HTTP_HOST => 'example.com',
   SCRIPT_NAME => "",
   PATH_INFO => "/some/test.html",
};

ok(my $r = Combust::Request::Plack->new($env), 'new');
isa_ok($r->uri, 'Combust::Request::URI');
is($r->path, '/some/test.html', 'path');
is($r->hostname, 'example.com', 'hostname');
is($r->uri->host, 'example.com', 'uri->host');
ok('/some/test.html' eq $r->uri, 'stringify uri');
is($r->request_url, 'http://example.com/some/test.html', 'request_url');

is($r->path, '/some/test.html');
is($r->uri, '/some/test.html');
is($r->uri('/other/page'), '/other/page', 'change uri()');
is($r->path, '/other/page', 'path() got updated');
is($r->request_url, 'http://example.com/other/page', 'request_url got updated');
is($r->uri->path, '/other/page', 'uri->path got updated');


$env = {
   HTTP_HOST => 'example.com',
   SCRIPT_NAME => "",
   PATH_INFO => "/some/@",
};

ok($r = Combust::Request::Plack->new($env), 'new');
isa_ok($r->uri, 'Combust::Request::URI');
is($r->path, '/some/@', 'path');
is("" . $r->uri, '/some/@', 'stringify uri');

done_testing;
