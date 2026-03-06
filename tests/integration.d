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
