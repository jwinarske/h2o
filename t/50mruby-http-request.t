use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
use Net::EmptyPort qw(empty_port check_port);
use Test::More;
use t::Util;

plan skip_all => 'mruby support is off'
    unless server_features()->{mruby};

plan skip_all => 'curl not found'
    unless prog_exists('curl');

plan skip_all => 'plackup not found'
    unless prog_exists('plackup');

plan skip_all => 'Starlet not found'
    unless system('perl -MStarlet /dev/null > /dev/null 2>&1') == 0;

my $upstream_hostport = "127.0.0.1:@{[empty_port()]}";

sub create_upstream {
    my @args = (
        qw(plackup -s Starlet --keepalive-timeout 100 --access-log /dev/null --listen),
        $upstream_hostport,
        ASSETS_DIR . "/upstream.psgi",
    );
    spawn_server(
        argv     => \@args,
        is_ready =>  sub {
            $upstream_hostport =~ /:([0-9]+)$/s
                or die "failed to extract port number";
            check_port($1);
        },
    );
};

my $server = spawn_h2o(sub {
    my ($port, $tls_port) = @_;
    return << "EOT";
proxy.timeout.io: 1000
hosts:
  default:
    paths:
      /:
        mruby.handler: |
          Proc.new do |env|
            headers = {}
            env.each do |key, value|
              if /^HTTP_/.match(key)
                headers[\$'] = value
              end
            end
            headers["x-h2o-mruby"] = "1"
            http_request("http://$upstream_hostport#{env["PATH_INFO"]}#{env["QUERY_STRING"]}", {
              method: env["REQUEST_METHOD"],
              headers: headers,
              body: env["rack.input"],
            }).join
          end
      /as_str:
        mruby.handler: |
          Proc.new do |env|
            [200, {}, [http_request("http://$upstream_hostport/index.txt").join[2].join]]
          end
      /cl:
        mruby.handler: |
          Proc.new do |env|
            if !/^\\/([0-9]+)/.match(env["PATH_INFO"])
              raise "failed to parse PATH_INFO"
            end
            cl = \$1
            body = ["abc", "def", "ghi", "jkl", "mno"]
            if \$'.length != 0
              class T
                def initialize(a)
                  \@a = a
                end
                def each(&b)
                  \@a.each(&b)
                end
              end
              body = T.new(body)
            end
            [200, {"content-length" => cl}, body]
          end
      /esi:
        mruby.handler: |
          class ESIResponse
            def initialize(input)
              \@parts = input.split /(<esi:include +src=".*?" *\\/>)/
              \@parts.each_with_index do |part, index|
                if /^<esi:include +src=" *(.*?) *"/.match(part)
                  \@parts[index] = http_request("http://$upstream_hostport/#{\$1}")
                end
              end
            end
            def each(&block)
              \@parts.each do |part|
                if part.kind_of? String
                  block.call(part)
                else
                  part.join[2].each(&block)
                end
              end
            end
          end
          Proc.new do |env|
            resp = http_request("http://$upstream_hostport/esi.html").join
            resp[2] = ESIResponse.new(resp[2].join)
            resp
          end
      /partial:
        mruby.handler: |
          class PartialBody
            def initialize(body)
              \@body = body
            end
            def each
             \@body.each {|buf|
               if \@first_received
                 yield buf
               else
                 \@first_received = true
               end
             }
            end
          end
          Proc.new do |env|
            resp = http_request("http://$upstream_hostport/streaming-body").join
            [resp[0], resp[1], PartialBody.new(resp[2])]
          end
      /async-delegate:
        mruby.handler: |
          Proc.new do |env|
            resp = http_request("http://$upstream_hostport#{env["PATH_INFO"]}").join
            if resp[0] != 200
              resp = [399, {}, []]
            end
            resp
          end
        mruby.handler: |
          Proc.new do |env|
            [200, {}, ["delegated!"]]
          end
EOT
});

run_with_curl($server, sub {
    my ($proto, $port, $curl_cmd) = @_;
    $curl_cmd .= ' --silent --dump-header /dev/stderr';
    subtest "connection-error" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/index.txt");
        like $headers, qr{HTTP/[^ ]+ 500\s}is;
    };
    my $upstream = create_upstream();
    subtest "get" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/index.txt");
        like $headers, qr{HTTP/[^ ]+ 200\s}is;
        is $body, "hello\n";
    };
    subtest "headers" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/echo-headers");
        like $headers, qr{^HTTP/[^ ]+ 200\s}is;
        like $body, qr{^host: $upstream_hostport$}im;
        unlike $body, qr{^host: 127.0.0.1:$port$}im;
        like $body, qr{^user-agent: *curl/}im;
        like $body, qr{^accept: *\*/\*$}im;
        like $body, qr{^x-h2o-mruby:}im;
    };
    subtest "post" => sub {
        my ($headers, $body) = run_prog("$curl_cmd --data 'hello world' $proto://127.0.0.1:$port/echo");
        like $headers, qr{HTTP/[^ ]+ 200\s}is;
        is $body, 'hello world';
    };
    subtest "slow-chunked" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/streaming-body");
        like $headers, qr{HTTP/[^ ]+ 200\s}is;
        is $body, (join "", 1..30);
    };
    subtest "as_str" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/as_str/");
        like $headers, qr{HTTP/[^ ]+ 200\s}is;
        is $body, "hello\n";
    };
    subtest "content-length" => sub {
        subtest "non-chunked" => sub {
            for my $i (0..15) {
                subtest "cl=$i" => sub {
                    my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/cl/$i");
                    like $headers, qr{^HTTP/[^ ]+ 200\s.*\ncontent-length:\s*$i\r}is;
                    is $body, substr "abcdefghijklmno", 0, $i;
                }
            };
            for my $i (16..30) {
                subtest "cl=$i" => sub {
                    my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/cl/$i");
                    like $headers, qr{^HTTP/[^ ]+ 200\s.*\ncontent-length:\s*15\r}is;
                    is $body, "abcdefghijklmno";
                }
            };
        };
        subtest "chunked" => sub {
            for my $i (0..30) {
                subtest "cl=$i" => sub {
                    my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/cl/$i/chunked");
                    like $headers, qr{^HTTP/[^ ]+ 200\s.*\ncontent-length:\s*$i\r}is;
                    is $body, substr "abcdefghijklmno", 0, $i;
                }
            };
        };
    };
    subtest "esi" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/esi/");
        like $headers, qr{HTTP/[^ ]+ 200\s}is;
        is $body, "Hello to the world, from H2O!\n";
    };
    subtest "partial" => sub {
        my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/partial/");
        like $headers, qr{HTTP/[^ ]+ 200\s}is;
        is $body, join "", 2..30;
    };
    subtest "async-delegate" => sub {
        subtest "non-delegated" => sub {
            my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/async-delegate/index.txt");
            like $headers, qr{HTTP/[^ ]+ 200\s}is;
            is $body, "hello\n";
        };
        subtest "delegated" => sub {
            my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/async-delegate/notfound");
            like $headers, qr{HTTP/[^ ]+ 200\s}is;
            is $body, "delegated!";
        };
    };
});

subtest 'cache-response' => sub {
    my $upstream = create_upstream();
    my $server = spawn_h2o(sub {
        my ($port, $tls_port) = @_;
        return << "EOT";
hosts:
  default:
    paths:
      /cache-response:
        mruby.handler: |
          resp = http_request("http://$upstream_hostport/index.txt").join
          resp[2] = [resp[2].join]
          Proc.new do |env|
            resp
          end
EOT
    });

    run_with_curl($server, sub {
        my ($proto, $port, $curl_cmd) = @_;
        $curl_cmd .= ' --silent --dump-header /dev/stderr';

        subtest "cache-response" => sub {
            my ($headers, $body) = run_prog("$curl_cmd $proto://127.0.0.1:$port/cache-response");
            like $headers, qr{HTTP/[^ ]+ 200\s}is;
            is $body, "hello\n";
        };
    });
};

subtest 'double consume' => sub {
    my $upstream = create_upstream();
    my $server = spawn_h2o(sub {
        my ($port, $tls_port) = @_;
        return << "EOT";
num-threads: 1
hosts:
  default:
    paths:
      /check-alive:
        mruby.handler: proc { [200, {}, []] }
      /join-join:
        mruby.handler: |
          Proc.new do |env|
            resp = http_request("http://$upstream_hostport/index.txt").join
            resp[2].join
            resp[2].join
            [200, {}, []]
          end
      /join-chunked:
        mruby.handler: |
          Proc.new do |env|
            resp = http_request("http://$upstream_hostport/index.txt").join
            resp[2].join
            [200, {}, resp[2]]
          end
      /chunked-join:
        mruby.handler: |
          resp = nil
          Proc.new do |env|
            if resp
              resp[2].join
            else
              resp = http_request("http://$upstream_hostport/index.txt").join
            end
            [200, {}, resp[2]]
          end
      /chunked-chunked:
        mruby.handler: |
          resp = nil
          Proc.new do |env|
            resp ||= http_request("http://$upstream_hostport/index.txt").join
            [200, {}, resp[2]]
          end
EOT
    });

    my $tester = sub {
        local $Test::Builder::Level = $Test::Builder::Level + 1;
        my ($path, $expected) = @_;
        my ($headers, $body) = run_prog("curl --silent --dump-header /dev/stderr http://127.0.0.1:@{[$server->{port}]}$path");
        like $headers, qr{HTTP/[^ ]+ $expected\s}is;
    };

    subtest "join-join" => sub {
        $tester->('/join-join', 500);
        $tester->('/check-alive', 200);
    };
    subtest "join-chunked" => sub {
        $tester->('/join-chunked', 500);
        $tester->('/check-alive', 200);
    };
    subtest "chunked-join" => sub {
        $tester->('/chunked-join', 200);
        $tester->('/chunked-join', 500);
        $tester->('/check-alive', 200);
    };
    subtest "chunked-chunked" => sub {
        $tester->('/chunked-chunked', 200);
        $tester->('/chunked-chunked', 500);
        $tester->('/check-alive', 200);
    };
};

done_testing();
