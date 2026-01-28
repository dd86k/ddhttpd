module ddhttpd.server;

import bindbc.libmicrohttpd;
import bindbc.loader;
import std.string : toStringz, fromStringz, indexOf;
import std.stdio;
import std.conv : text;
import std.encoding;

// This stuff is better in connection handling... Oh well

/// Request ok.
alias REQUEST_OK     = MHD_YES;
/// Request not ok to MHD.
alias REQUEST_REFUSE = MHD_NO;

// Start flags

/// Print MHD debug messages to a file (if set) or stderr.
alias START_DEBUG      = MHD_USE_DEBUG;
/// Use IPv4 and IPv6.
alias START_DUAL_STACK = MHD_USE_DUAL_STACK;
/// Use IPv6
alias START_IPV6       = MHD_USE_IPv6;

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
        import core.stdc.errno : errno;
        import core.stdc.string : strerror;
        import std.string : fromStringz;
        super(text(funcname, ": ", fromStringz(strerror(errno))), file, line);
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
// NOTE: Uh, we can just use MHD_get_reason_phrase_for, but this is fine too.
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

struct HTTPRequest
{
    string method;
    string path;
    ubyte[] payload;
    /// URL parameters
    string[string] params;
    
    // Constructed by this module on a new connection
    this(MHD_Connection *conn, string method_, string path_)
    {
        connection = conn;
        method = method_;
        path = path_;
    }
    
    // HACK: mode is a hack
    //       Need to do a "createReplyXYZ" that returns a struct to "properly" reply
    //       using appropriate strategy.
    //       This function specifically could be renamed to something else
    // Reply
    void reply(int http_code, inout(void)[] content, inout(string) contentType, int mode = MHD_RESPMEM_PERSISTENT)
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

        result = MHD_queue_response(connection, http_code, response);
        if (result == MHD_NO)
            throw new MHDException("MHD_queue_response");
        
        MHD_destroy_response(response);
    }
    
    /// GET parameter
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
        
        if (indexOf(path, ':') >= 0)
        {
            state.pattern_routes ~= PathPattern(method, path, handler);
            return this;
        }
        
        state.exact_routes.update(path,
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
    void start(ushort port, int flags = 0)
    {
        version (linux)
            enum DEFAULT_FLAGS =
                MHD_USE_TCP_FASTOPEN | // >=3.6
                MHD_USE_INTERNAL_POLLING_THREAD |
                MHD_USE_POLL;
        else
            enum DEFAULT_FLAGS = 
                MHD_USE_INTERNAL_POLLING_THREAD |
                MHD_USE_POLL;
        
        if (state.daemon)
            throw new Exception("Already started");
        
        flags |= DEFAULT_FLAGS;
        
        state.daemon = MHD_start_daemon(
            flags, port,
            null, null,
            &ddhttpd_handler, &state,
            MHD_OPTION_LISTENING_ADDRESS_REUSE, 1,  // Allows address reuse
            MHD_OPTION_STRICT_FOR_CLIENT, 0,        // Recommended be OFF in production
            MHD_OPTION_END);
        if (state.daemon == null)
            throw new MHDException("MHD_start_daemon");
    }
    
private:
    ServerState state;
}

//
// Private functions
//

private:

/// A single url path route
struct Route
{
    string method;
    string path;
    int delegate(ref HTTPRequest) handler;
}

struct ServerState
{
    MHD_Daemon *daemon;
    Route[string][string] exact_routes;
    PathPattern[] pattern_routes;
    int delegate(ref HTTPRequest, Exception) on_error_exception;
}

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

// TODO: Headers
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
    HTTPRequest req = HTTPRequest(
        connection,
        fromStringz(method).idup,
        fromStringz(url).idup
    );
    
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
        if (state.exact_routes)
            if (Route[string] *routes = req.path in state.exact_routes)
                if (Route *route = req.method in *routes)
                    return route.handler(req);
        
        foreach (route; state.pattern_routes)
        {
            if (req.method == route.method && route.match(req.path, req.params))
                return route.handler(req);
        }
        
        throw new HttpServerException(HTTPStatus.notFound, HTTPMsg.notFound, req);
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

struct PathPattern
{
    string[] segments;      // ["user", ":id", "posts"]
    bool[] isParam;         // [false, true, false]
    string[] paramNames;    // ["id"]
    string method;
    int delegate(ref HTTPRequest) handler;
    
    this(string method_, string pattern, int delegate(ref HTTPRequest) handler_)
    {
        method = method_;
        handler = handler_;
        
        if (pattern.length && pattern[0] == '/')
            pattern = pattern[1..$];
        
        import std.algorithm.iteration : splitter;
        import std.array : split;
        
        foreach (part; splitter(pattern, '/'))
        {
            if (part.length && part[0] == ':')
            {
                isParam ~= true;
                paramNames ~= part[1..$];  // Remove ':'
                segments   ~= part[1..$];
            }
            else
            {
                isParam  ~= false;
                segments ~= part;
            }
        }
    }
    
    // Match incoming path and extract parameters
    bool match(string path, out string[string] params)
    {
        if (path.length && path[0] == '/')
            path = path[1..$];
        
        import std.array : split;
        
        string[] parts = path.split('/');
        
        // Segment count must match
        if (parts.length != segments.length)
            return false;
        
        foreach (i, segment; segments)
        {
            if (isParam[i])
            {
                // Capture parameter value
                params[segment] = parts[i];
            }
            else
            {
                // Must match exactly
                if (parts[i] != segment)
                    return false;
            }
        }
        
        return true;
    }
}
unittest
{
    PathPattern pattern = PathPattern(null, "/user/:id/posts/:postId", null);
    
    string[string] params;
    
    // Should match
    assert(pattern.match("/user/123/posts/456", params));
    assert(params["id"] == "123");
    assert(params["postId"] == "456");
    
    // Should not match
    params.clear();
    assert(!pattern.match("/user/123/comments/456", params));
    assert(!pattern.match("/user/123", params));
}