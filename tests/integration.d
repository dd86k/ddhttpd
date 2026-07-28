module tests.integration;

import std.stdio;
import std.net.curl;
import std.conv : text;
import ddhttpd;

immutable string HELLO_BODY = "hello integration";

int failures = 0;
string baseURL;

void check(bool cond, string msg, string file = __FILE__, size_t line = __LINE__)
{
    if (!cond)
    {
        writefln("  FAIL [%s:%s]: %s", file, line, msg);
        failures++;
    }
}

string url(string path)
{
    return baseURL ~ path;
}

void testBasicRoute()
{
    writeln("test: basic route");
    auto http = HTTP(url("/"));
    char[] body_;
    http.onReceive = (ubyte[] data) { body_ ~= cast(char[])data; return data.length; };
    http.perform();
    check(http.statusLine.code == 200, text("expected 200, got ", http.statusLine.code));
    check(body_ == HELLO_BODY, text("unexpected body: ", body_));
}

void testResponseHeaders()
{
    writeln("test: response headers");
    auto http = HTTP(url("/with-headers"));
    string xCustom;
    string cacheControl;
    http.onReceiveHeader = (in char[] key, in char[] value)
    {
        if (key == "x-custom")
            xCustom = value.idup;
        if (key == "cache-control")
            cacheControl = value.idup;
    };
    char[] body_;
    http.onReceive = (ubyte[] data) { body_ ~= cast(char[])data; return data.length; };
    http.perform();
    check(http.statusLine.code == 200, text("expected 200, got ", http.statusLine.code));
    check(xCustom == "test-value", text("expected x-custom 'test-value', got '", xCustom, "'"));
    check(cacheControl == "no-cache", text("expected cache-control 'no-cache', got '", cacheControl, "'"));
}

void testRequestHeaderEcho()
{
    writeln("test: request header echo");
    auto http = HTTP(url("/echo-header"));
    http.addRequestHeader("X-Echo-Me", "ping");
    char[] body_;
    http.onReceive = (ubyte[] data) { body_ ~= cast(char[])data; return data.length; };
    http.perform();
    check(http.statusLine.code == 200, text("expected 200, got ", http.statusLine.code));
    check(body_ == "ping", text("expected body 'ping', got '", body_, "'"));
}

void testRequestHeaderMissing()
{
    writeln("test: request header missing returns empty");
    auto http = HTTP(url("/echo-header"));
    char[] body_;
    http.onReceive = (ubyte[] data) { body_ ~= cast(char[])data; return data.length; };
    http.perform();
    check(http.statusLine.code == 200, text("expected 200, got ", http.statusLine.code));
    check(body_ == "", text("expected empty body, got '", body_, "'"));
}

void test404()
{
    writeln("test: 404 on unknown route");
    auto http = HTTP(url("/nonexistent"));
    http.onReceiveStatusLine = (HTTP.StatusLine status) {};
    http.onReceive = (ubyte[] data) { return data.length; };
    http.perform();
    check(http.statusLine.code == 404, text("expected 404, got ", http.statusLine.code));
}

void testContentType()
{
    writeln("test: content-type header");
    auto http = HTTP(url("/"));
    string contentType;
    http.onReceiveHeader = (in char[] key, in char[] value)
    {
        if (key == "content-type")
            contentType = value.idup;
    };
    http.onReceive = (ubyte[] data) { return data.length; };
    http.perform();
    check(contentType == "text/plain", text("expected 'text/plain', got '", contentType, "'"));
}

void testPostBody()
{
    writeln("test: POST body echo");
    auto http = HTTP(url("/echo"));
    http.method = HTTP.Method.post;
    char[] body_;
    http.onReceive = (ubyte[] data) { body_ ~= cast(char[])data; return data.length; };
    http.postData = "hello post";
    http.perform();
    check(http.statusLine.code == 200, text("expected 200, got ", http.statusLine.code));
    check(body_ == "hello post", text("expected 'hello post', got '", body_, "'"));
}

void testPostEmptyBody()
{
    writeln("test: POST empty body");
    auto http = HTTP(url("/echo"));
    http.method = HTTP.Method.post;
    char[] body_;
    http.onReceive = (ubyte[] data) { body_ ~= cast(char[])data; return data.length; };
    http.postData = "";
    http.perform();
    check(http.statusLine.code == 200, text("expected 200, got ", http.statusLine.code));
    check(body_ == "", text("expected empty body, got '", body_, "'"));
}

void testPostLargeBody()
{
    writeln("test: POST large body (multi-chunk)");
    // 256KB payload — large enough to force multiple MHD handler callbacks
    enum SIZE = 256 * 1024;
    char[] sent = new char[](SIZE);
    sent[] = 'A';
    auto http = HTTP(url("/echo"));
    http.method = HTTP.Method.post;
    ubyte[] body_;
    http.onReceive = (ubyte[] data) { body_ ~= data; return data.length; };
    http.postData = cast(string)sent;
    http.perform();
    check(http.statusLine.code == 200, text("expected 200, got ", http.statusLine.code));
    check(body_.length == SIZE, text("expected length ", SIZE, ", got ", body_.length));
    bool allA = true;
    foreach (b; body_)
        if (b != 'A') { allA = false; break; }
    check(allA, "payload corrupted — not all bytes are 'A'");
}

void testUploadLimit()
{
    import core.time : dur;
    writeln("test: upload size limit");

    // Separate server with a 1KB upload limit
    HTTPServer limited = new HTTPServer()
        .maxUploadSize(1024)
        .addRoute("POST", "/echo", (ref HTTPRequest req)
        {
            req.reply(200, HTTPReply.copyBuffer(req.payload), "application/octet-stream");
            return REQUEST_OK;
        });
    limited.start(0);
    scope(exit) limited.stop();
    string limitedURL = text("http://127.0.0.1:", limited.port());

    // Under limit — should succeed
    {
        auto http = HTTP(text(limitedURL, "/echo"));
        http.method = HTTP.Method.post;
        http.dataTimeout = dur!"seconds"(5);
        http.onReceiveStatusLine = (HTTP.StatusLine status) {};
        char[] body_;
        http.onReceive = (ubyte[] data) { body_ ~= cast(char[])data; return data.length; };
        http.postData = "small";
        http.perform();
        check(http.statusLine.code == 200, text("under limit: expected 200, got ", http.statusLine.code));
        check(body_ == "small", text("under limit: expected 'small', got '", body_, "'"));
    }

    // Over limit — should get 413
    {
        char[] big = new char[](2048);
        big[] = 'X';
        auto http = HTTP(text(limitedURL, "/echo"));
        http.method = HTTP.Method.post;
        http.dataTimeout = dur!"seconds"(5);
        http.onReceiveStatusLine = (HTTP.StatusLine status) {};
        http.onReceive = (ubyte[] data) { return data.length; };
        http.postData = cast(string)big;
        http.perform();
        check(http.statusLine.code == 413, text("over limit: expected 413, got ", http.statusLine.code));
    }
}

void testAddressBinding()
{
    writeln("test: address binding");

    HTTPServer bound = new HTTPServer()
        .addRoute("GET", "/", (ref HTTPRequest req)
        {
            req.reply(200, HTTPReply.staticBuffer("bound"), "text/plain");
            return REQUEST_OK;
        });
    bound.start("127.0.0.1", 0);
    scope(exit) bound.stop();

    auto http = HTTP(text("http://127.0.0.1:", bound.port(), "/"));
    char[] body_;
    http.onReceive = (ubyte[] data) { body_ ~= cast(char[])data; return data.length; };
    http.perform();
    check(http.statusLine.code == 200, text("expected 200, got ", http.statusLine.code));
    check(body_ == "bound", text("unexpected body: ", body_));

    // Binding twice on the same server is refused
    bool refused;
    try
        bound.start("127.0.0.1", 0);
    catch (Exception ex)
        refused = true;
    check(refused, "expected second start() to throw");

    // Unresolvable addresses are reported before reaching MHD
    HTTPServer bad = new HTTPServer()
        .addRoute("GET", "/", (ref HTTPRequest req) { return REQUEST_OK; });
    bool threw;
    try
        bad.start("no.such.host.invalid", 0);
    catch (Exception ex)
        threw = true;
    check(threw, "expected start() to throw on unresolvable address");
}

void testIPv6Binding()
{
    writeln("test: IPv6 address binding");

    HTTPServer bound = new HTTPServer()
        .addRoute("GET", "/", (ref HTTPRequest req)
        {
            req.reply(200, HTTPReply.staticBuffer("v6"), "text/plain");
            return REQUEST_OK;
        });

    try
        bound.start("::1", 0);
    catch (Exception ex)
    {
        writeln("  skipped: ", ex.msg);
        return;
    }
    scope(exit) bound.stop();

    auto http = HTTP(text("http://[::1]:", bound.port(), "/"));
    char[] body_;
    http.onReceive = (ubyte[] data) { body_ ~= cast(char[])data; return data.length; };
    http.perform();
    check(http.statusLine.code == 200, text("expected 200, got ", http.statusLine.code));
    check(body_ == "v6", text("unexpected body: ", body_));
}

// Handlers run on the event loop thread, which the library owns. Nothing may
// be left registered with the runtime after stop(): a thread that exits while
// still registered hangs the next collection in thread_suspendAll, waiting for
// a suspend acknowledgement from a thread that no longer exists.
void testEventLoopThread()
{
    writeln("test: event loop thread");

    import core.memory : GC;
    import core.thread : Thread;

    size_t before = Thread.getAll().length;

    HTTPServer served = new HTTPServer()
        .addRoute("GET", "/", (ref HTTPRequest req)
        {
            // Allocate so the GC is exercised from the event loop thread
            ubyte[] junk = new ubyte[](64 * 1024);
            junk[0] = 1;
            check(Thread.getThis() !is null, "handler ran on an unregistered thread");
            req.reply(200, HTTPReply.staticBuffer("served"), "text/plain");
            return REQUEST_OK;
        });
    served.start("127.0.0.1", 0);

    string base = text("http://127.0.0.1:", served.port(), "/");
    foreach (i; 0 .. 64)
    {
        HTTP http = HTTP(base);
        http.onReceive = (ubyte[] data) { return data.length; };
        http.perform();
    }

    // Counted once the loop is definitely running: a thread only joins the
    // runtime's list when it starts, not when start() returns
    size_t serving = Thread.getAll().length;
    check(serving == before + 1,
        text("expected one event loop thread, got ", cast(long)serving - cast(long)before));

    served.stop();

    size_t after = Thread.getAll().length;
    check(after == before,
        text("expected ", before, " registered threads after stop, got ", after));

    // Would deadlock in thread_suspendAll if a dead thread was still listed
    GC.collect();
}

// A pool serves from several threads at once, all accepting from one shared
// listening socket.
void testThreadPool()
{
    writeln("test: thread pool");

    import core.thread : Thread, dur;
    import std.socket : InternetAddress, Socket, TcpSocket;

    enum POOL = 3;
    shared int[ulong] served; // handler thread -> requests it handled
    Object lock = new Object;

    size_t before = Thread.getAll().length;

    HTTPServer pooled = new HTTPServer()
        .addRoute("GET", "/slow", (ref HTTPRequest req)
        {
            ulong id = cast(ulong)cast(void*)Thread.getThis();
            synchronized (lock)
                (cast(int[ulong])served)[id]++;
            // Long enough that a single threaded server could not overlap them
            Thread.sleep(dur!"msecs"(200));
            req.reply(200, HTTPReply.staticBuffer("slow"), "text/plain");
            return REQUEST_OK;
        });
    pooled.threadPoolSize(POOL);
    pooled.start("127.0.0.1", 0);

    ushort port = pooled.port();
    string slowURL = text("http://127.0.0.1:", port, "/slow");

    Thread[] clients;
    foreach (i; 0 .. POOL)
    {
        Thread client = new Thread(()
        {
            HTTP http = HTTP(slowURL);
            http.onReceive = (ubyte[] data) { return data.length; };
            http.perform();
        });
        client.start();
        clients ~= client;
    }
    foreach (Thread client; clients)
        client.join();

    check(Thread.getAll().length == before + POOL,
        text("expected ", POOL, " loop threads, got ",
            cast(long)Thread.getAll().length - cast(long)before));

    size_t distinct = (cast(int[ulong])served).length;
    check(distinct > 1, text("requests were served by ", distinct, " thread(s)"));

    pooled.stop();

    check(Thread.getAll().length == before,
        text("expected ", before, " registered threads after stop, got ",
            Thread.getAll().length));

    // The shared listening socket belongs to us and must be closed by stop(),
    // MHD would otherwise close it once per daemon
    Socket probe = new TcpSocket();
    bool rebound = true;
    try
        probe.bind(new InternetAddress("127.0.0.1", port));
    catch (Exception ex)
        rebound = false;
    probe.close();
    check(rebound, "listening socket still open after stop");
}

void testPoolSizeValidation()
{
    writeln("test: pool size validation");

    bool refused;
    try
        new HTTPServer().threadPoolSize(0);
    catch (Exception ex)
        refused = true;
    check(refused, "expected threadPoolSize(0) to throw");

    HTTPServer running = new HTTPServer()
        .addRoute("GET", "/", (ref HTTPRequest req)
        {
            req.reply(200, HTTPReply.staticBuffer("ok"), "text/plain");
            return REQUEST_OK;
        });
    running.start("127.0.0.1", 0);
    scope(exit) running.stop();

    refused = false;
    try
        running.threadPoolSize(2);
    catch (Exception ex)
        refused = true;
    check(refused, "expected threadPoolSize() after start() to throw");
}

void main()
{
    HTTPServer server = new HTTPServer()
        .addRoute("GET", "/", (ref HTTPRequest req)
        {
            req.reply(200, HTTPReply.staticBuffer(HELLO_BODY), "text/plain");
            return REQUEST_OK;
        })
        .addRoute("GET", "/with-headers", (ref HTTPRequest req)
        {
            req.addHeader("X-Custom", "test-value")
               .addHeader("Cache-Control", "no-cache");
            req.reply(200, HTTPReply.staticBuffer("ok"), "text/plain");
            return REQUEST_OK;
        })
        .addRoute("GET", "/echo-header", (ref HTTPRequest req)
        {
            string val = req.header("X-Echo-Me");
            if (val)
                req.reply(200, HTTPReply.copyBuffer(val), "text/plain");
            else
                req.reply(200, HTTPReply.staticBuffer(""), "text/plain");
            return REQUEST_OK;
        })
        .addRoute("POST", "/echo", (ref HTTPRequest req)
        {
            req.reply(200, HTTPReply.copyBuffer(req.payload), "application/octet-stream");
            return REQUEST_OK;
        })
    ;

    server.start(0);
    scope(exit) server.stop();

    ushort port = server.port();
    baseURL = text("http://127.0.0.1:", port);
    writefln("Integration tests (server on port %d)", port);

    testBasicRoute();
    testResponseHeaders();
    testRequestHeaderEcho();
    testRequestHeaderMissing();
    test404();
    testContentType();
    testPostBody();
    testPostEmptyBody();
    testPostLargeBody();
    testUploadLimit();
    testAddressBinding();
    testIPv6Binding();
    testEventLoopThread();
    testThreadPool();
    testPoolSizeValidation();

    writeln();
    if (failures > 0)
    {
        writefln("%d test(s) FAILED", failures);
        import core.stdc.stdlib : exit;
        exit(1);
    }
    else
        writeln("All tests passed.");
}
