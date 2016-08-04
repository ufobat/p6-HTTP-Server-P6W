use HTTP::Request::Supply;
use HTTP::Status;
use URI::Encode;


class HTTP::Server::P6W {
    has Str $.host = "localhost";
    has Int $.port = 3000;

    method run($app) {
        my $socket = IO::Socket::Async.listen($.host, $.port);
        react {
            whenever $socket.Supply -> $conn {
                my $s = $conn.Supply(:bin);
                my $envs = parse-http1-request($s);
                $envs.tap(-> %env { self.handle-request($app, %env, $conn) });
            }
        }
    }

    method handle-request($app, %env, $conn) {
        my Promise $header-done-promise .= new;
        my $header-done = $header-done-promise.vow;

        my Promise $body-done-promise .= new;
        my $body-done = $body-done-promise.vow;

        my Promise $ready-promise .= new;
        my $ready = $ready-promise.vow;

        my Str $req-debug = Str.new;
        $req-debug ~= "invoking app with env:\n";
        my $max = %env.keys».chars.max;
        for %env.keys -> $k {
            my $padding = " " x $max - $k.chars;
            $req-debug ~= $k ~ $padding ~ " -> " ~ %env{$k}.perl ~ "\n";
        }
        $req-debug ~= "---------------------\n";
        say $req-debug;
        my $uri = %env<REQUEST_URI>;
        my ($path, $query-string) = $uri.split('?', 2);
        %env<PATH_INFO>       = uri_decode($path);
        %env<QUERY_STRING>    = $query-string;

        my Promise $p = $app.(%env);
        self.handle-response($p, :$conn, :%env, :$ready, :$header-done, :$body-done);
    }


    method handle-response(Promise() $promise, :$conn, :%env, :$ready, :$header-done, :$body-done) {
        $promise.then({
            try {
                my (Int() $status, List() $headers, Supply() $body) := $promise.result;
                self.handle-inner($status, $headers, $body, $conn, :$ready, :$header-done, :$body-done);

                # consume and discard the bytes in the iput stream, just in case the app
                # didn't read from it.
                %env<p6w.input>.tap if %env<p6w.input> ~~ Supply:D;
                CATCH {
                    default {
                        say $promise.cause;
                        say "---";
                        say $promise.cause.backtrace.full.Str;
                    }
                }
            }
        });
    }

    method handle-inner(Int $status, @headers, Supply $body, $conn, :$ready, :$header-done, :$body-done) {
       my $charset = self.send-header($status, @headers, $conn);
       $header-done andthen $header-done.keep(True);

       react {
           whenever $body -> $v {
               my Blob $buf = do given ($v) {
                   when Cool { $v.Str.encode($charset) }
                   when Blob { $v }
                   default {
                      warn "Application emitted unknown message.";
                      Nil;
                   }
               }
               $conn.write($buf) if $buf;

               LAST {
                   say "conn close A " ~ $*THREAD;
                   say $conn;
                   $conn.close;
                   $body-done andthen $body-done.keep(True);
               }

               QUIT {
                   say "conn close B " ~ $*THREAD;
                   say $conn;
                   my $x = $_;
                   $conn.close;
                   CATCH {
                       # this is stupid, IO::Socket needs better exceptions
                       when "Not connected!" {
                           # ignore it
                       }
                   }
                   $body-done andthen $body-done.break($x);
               }
           }
           $ready andthen $ready.keep(True);
       }
    }

    method send-header($status, @headers, $conn) returns Str:D {
        my $status-msg = get_http_status_msg($status);

        # Header SHOULD be ASCII or ISO-8859-1, in theory, right?
        $conn.write("HTTP/1.0 $status $status-msg\x0d\x0a".encode('ISO-8859-1'));
        $conn.write("{.key}: {.value}\x0d\x0a".encode('ISO-8859-1')) for @headers;
        $conn.write("\x0d\x0a".encode('ISO-8859-1'));

        # Detect encoding
        my $ct = @headers.first(*.key.lc eq 'content-type');
        my $charset = $ct.value.comb(/<-[;]>/)».trim.first(*.starts-with("charset="));
        $charset.=substr(8) if $charset;
        $charset //= 'UTF-8';
    }

}
