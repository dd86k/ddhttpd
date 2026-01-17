module ddhttpd.server;

import bindbc.libmicrohttpd;
import bindbc.loader;
import std.string : toStringz, fromStringz;
import std.stdio;
import std.conv : text;
import std.encoding;

alias REQUEST_OK     = MHD_YES;
alias REQUEST_REFUSE = MHD_NO;

enum ContentType
{
    text_html   = "text/html",
    text_plain  = "text/plain",
}

class MHDException : Exception
{
    this(string funcname,
        size_t line = __LINE__, string file = __FILE__)
    {
        super(text(funcname, ": failed"), file, line);
    }
}

// NOTE: Having multiple classes only increases management on the client side
//       Having to check for specific exception classes suck both client and server side
//       These enums help when constructing a HttpServerException
enum HTTPStatus
{
    ok = 200,
    badRequest = 400,
    notFound = 404,
    methodNotAllowed = 405,
}
enum HTTPMsg
{
    ok = "OK",
    badRequest = "Bad Request",
    notFound = "Not Found",
    methodNotAllowed = "Method Not Allowed",
}

class HttpServerException : Exception
{
    this(int code_, string message_,
        HTTPRequest request,
        size_t line = __LINE__, string file = __FILE__)
    {
        code = code_;
        path = request.path;
        method = request.method;
        super(message_, file, line);
    }
    
    int code;
    string path;
    string method;
}

private
void libmicrohttpd_load()
{
    __gshared LibMicroHTTPDSupport support;
    
    // Already loaded
    if (support > LibMicroHTTPDSupport.badLibrary)
        return;
    
    support = loadLibMicroHTTPD();
    switch (support) with (LibMicroHTTPDSupport)
    {
        // No library found
        case LibMicroHTTPDSupport.noLibrary:
            foreach (const(ErrorInfo) err; errors)
            {
                throw new Exception(cast(string)fromStringz(err.error));
            }
            break;
        // Version loaded is missing symbols
        case LibMicroHTTPDSupport.badLibrary:
            foreach (const(ErrorInfo) err; errors)
            {
                // err.message should contain symbol
                throw new Exception(cast(string)fromStringz(err.error));
            }
            break;
        default:
    }
}

struct HTTPRequest
{
    string path;
    string method;
    ubyte[] payload;
    
    this(MHD_Connection *conn)
    {
        connection = conn;
    }
    
    void reply(int code, inout(void)[] content, inout(string) contentType, int mode = MHD_RESPMEM_PERSISTENT)
    {
        // MHD_RESPMEM_PERSISTENT
        // MHD_RESPMEM_MUST_FREE
        // MHD_RESPMEM_MUST_COPY
        MHD_Response *response = MHD_create_response_from_buffer(
            content.length, cast(void*)content.ptr,
            mode);
        if (response == null)
            throw new MHDException("MHD_create_response_from_buffer");
        
        MHD_Result result = void;
        
        result = MHD_add_response_header(response, "Content-Type", toStringz(contentType));
        if (result == MHD_NO)
            throw new MHDException("MHD_add_response_header");

        result = MHD_queue_response(connection, code, response);
        if (result == MHD_NO)
            throw new MHDException("MHD_queue_response");
        
        MHD_destroy_response(response);
    }
    
    string param(string key)
    {
        const(char)* value = MHD_lookup_connection_value(
            connection, 
            MHD_GET_ARGUMENT_KIND, 
            toStringz(key)
        );
        
        return value ? cast(string)fromStringz(value) : null;
    }
    
private:
    MHD_Connection *connection;
}

// TODO: struct URLMatcher (or similar) to help return Routes

private
struct Route
{
    string method;
    string path;
    int delegate(ref HTTPRequest) handler;
}

private
struct ServerState
{
    MHD_Daemon *daemon;
    // TODO: Change [string][string] to Path structure
    //       Path{method,url} or something else
    Route[string][string] routes;
    int delegate(ref HTTPRequest, Exception) on_error_exception;
}

// TODO: Mutex when adding/removing paths
class HTTPServer
{
    this()
    {
        libmicrohttpd_load();
    }
    
    typeof(this) onError(int delegate(ref HTTPRequest, Exception) handler)
    {
        if (!handler)
            throw new Exception("Need handler function");
        
        // Allow setting null or other handlers
        state.on_error_exception = handler;
        return this;
    }
    
    // Add a route
    typeof(this) addRoute(string method, string path, int delegate(ref HTTPRequest) handler)
    {
        if (!method)
            throw new Exception("Method required");
        if (!path)
            throw new Exception("Path required");
        if (path[0] != '/')
            throw new Exception("Path needs to start with '/'");
        if (!handler)
            throw new Exception("Need handler function");
        
        state.routes.update(path,
            {
                Route[string] routes;
                routes[method] = Route(method, path, handler);
                return routes;
            },
            (ref Route[string] routes)
            {
                routes[method] = Route(method, path, handler);
            }
        );
        
        return this;
    }
    
    void stop()
    {
        if (state.daemon)
        {
            MHD_stop_daemon(state.daemon);
            state.daemon = null;
        }
    }
    
    // Start daemon mode
    void start(ushort port)
    {
        version (linux)
            enum FLAGS =
                MHD_USE_TCP_FASTOPEN | // >=3.6
                MHD_USE_INTERNAL_POLLING_THREAD |
                MHD_USE_POLL |
                MHD_USE_DEBUG;
        else
            enum FLAGS = 
                MHD_USE_INTERNAL_POLLING_THREAD |
                MHD_USE_POLL |
                MHD_USE_DEBUG;
        
        if (state.daemon)
            throw new Exception("Already started");
        
        state.daemon = MHD_start_daemon(
            FLAGS, port,
            null, null,
            &ddhttpd_handler, &state,
                MHD_OPTION_LISTENING_ADDRESS_REUSE, 1,
                MHD_OPTION_STRICT_FOR_CLIENT, 0,
                MHD_OPTION_END);
        if (state.daemon == null)
            throw new MHDException("MHD_start_daemon");
    }
    
private:
    ServerState state;
}

// TODO: Headers
private
extern (C)
MHD_Result ddhttpd_handler(void *cls,
    MHD_Connection *connection,
    const(char) *url,
    const(char) *method,
    const(char) *version_,
    const(char) *upload_data,
    size_t *upload_data_size,
    void **ptr)
{
    HTTPRequest req = HTTPRequest(connection);
    req.path        = fromStringz(url).idup;
    req.method      = fromStringz(method).idup;
    
    // TODO: Better upload data handling
    //       *ptr is typically used to track connection state across multiple calls for POST data.
    //       Should it be tackled before path/method handling if reentering?
    if (upload_data_size)
    {
        req.payload = (cast(ubyte*)upload_data)[0..*upload_data_size];
    }
    
    ServerState *state = cast(ServerState*)cls;
    assert(state, "server state is NULL");
    
    try
    {
        if (state.routes is null)
        {
            throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);
        }
        
        // Get route by path
        Route[string] *routes = req.path in state.routes;
        if (routes == null)
        {
            throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);
        }
        
        // Get route by method
        Route *route = req.method in *routes;
        if (route == null)
        {
            throw new HttpServerException(HTTPStatus.methodNotAllowed, HTTPMsg.methodNotAllowed, req);
        }
        
        return route.handler(req);
    }
    catch (Exception ex)
    {
        if (state.on_error_exception)
        {
            return state.on_error_exception(req, ex);
        }
        else if (HttpServerException hex = cast(HttpServerException)ex)
        {
            import std.format : sformat;
            char[256] buffer = void;
            char[] res = sformat(buffer,
                `<!DOCTYPE html><html><body>%s - %s</body></html>`,
                hex.code, hex.msg);
            req.reply(hex.code, res, `text/html`, MHD_RESPMEM_MUST_COPY);
        }
        else
        {
            req.reply(
                500,
                `<!DOCTYPE html><html><body>Internal server error</body></html>`,
                `text/html`
            );
        }
        return MHD_YES;
    }
}

string escapeHtml(string text)
{
    import std.array : appender;
    auto result = appender!string;
    foreach (char c; text)
    {
        switch (c)
        {
            case '<':  result.put("&lt;");   break;
            case '>':  result.put("&gt;");   break;
            case '&':  result.put("&amp;");  break;
            case '"':  result.put("&quot;"); break;
            case '\'': result.put("&#39;");  break;
            default:   result.put(c);        break;
        }
    }
    return result.data;
}
