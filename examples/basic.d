module examples.basic;

import std.stdio;
import ddhttpd;

immutable string INDEX =
    `<!DOCTYPE html>`~
    `<html>`~
        `<head><title>ddhttpd demo</title></head>`~
        `<body><h1>ddhttpd demo</h1><a href="/page2">page2</body>`~
    `</html>`;
immutable string PAGE2 =
    `<!DOCTYPE html>`~
    `<html>`~
        `<head><title>page 2</title></head>`~
        `<body><p>welcome to page2</p><a href="/">home</a></body>`~
    `</html>`;

void main()
{
    enum PORT = 8080;
    
    HTTPServer server = new HTTPServer()
        .addRoute(`GET`, `/`, (ref HTTPRequest req)
        {
            req.reply(200, INDEX, "text/html");
            return REQUEST_OK;
        })
        .addRoute(`GET`, `/page2`, (ref HTTPRequest req)
        {
            req.reply(200, PAGE2, "text/html");
            return REQUEST_OK;
        })
    ;
    
    server.start(PORT);
    
    writef(`Listening on %d, press Return to quit`, PORT); stdout.flush();
    cast(void)readln();
}
