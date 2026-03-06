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
