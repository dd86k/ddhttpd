module ddhttpd.server;

import bindbc.libmicrohttpd;
static if (!bindbc.libmicrohttpd.staticBinding)
    import bindbc.loader;
import core.memory : GC; // to help manage post/put uploads
import core.thread.osthread : Thread, thread_attachThis;
import std.conv : text;
import std.encoding;
import std.stdio;
import std.string : toStringz, fromStringz, indexOf;

/// Printable ddhttpd version
enum DDHTTPD_VERSION = "0.0.1";

/// Request ok.
alias REQUEST_OK     = MHD_YES;
/// Request not ok to MHD.
alias REQUEST_REFUSE = MHD_NO;

// Start flags

/// Print MHD debug messages to a file (if set) or stderr.
alias START_DEBUG      = MHD_USE_DEBUG;
/// Use IPv4 and IPv6.
alias START_DUAL_STACK = MHD_USE_DUAL_STACK;
/// Use IPv6 only
alias START_IPV6       = MHD_USE_IPv6;

// Common Content-Type values
enum ContentType
{
    text_html   = "text/html",
    text_plain  = "text/plain",
    application_json = "application/json",
    application_xml  = "application/xml",
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
    payloadTooLarge = 413,
}
// NOTE: Uh, we can just use MHD_get_reason_phrase_for, but this is fine too.
enum HTTPMsg
{
    ok = "OK",
    badRequest = "Bad Request",
    notFound = "Not Found",
    methodNotAllowed = "Method Not Allowed",
    payloadTooLarge = "Content Too Large",
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

struct HTTPReply
{
    /// Create a reply that contains dynamically grown data and will be freed
    /// by MHD, best in most cases.
    /// MHD: Uses MHD_RESPMEM_MUST_FREE.
    static HTTPReply create(size_t init = 4096)
    {
        import core.stdc.stdlib : malloc;
        HTTPReply r;
        r.buffer = cast(char*)malloc(init);
        if (r.buffer == null)
            throw new Exception("malloc failed");
        r.capacity = init;
        r.mode = MHD_RESPMEM_MUST_FREE;
        return r;
    }

    /// Create a new reply with persistent static immutable data.
    /// MHD: Uses MHD_RESPMEM_PERSISTENT.
    static HTTPReply staticBuffer(inout(void)[] data)
    {
        HTTPReply r;
        r.buffer = cast(char*)data.ptr;
        r.length = data.length;
        r.mode = MHD_RESPMEM_PERSISTENT;
        return r;
    }

    /// Create a reply with small dynamic data, best for stack/temporary data.
    /// MHD: Uses MHD_RESPMEM_MUST_COPY.
    static HTTPReply copyBuffer(const(void)[] data)
    {
        HTTPReply r;
        r.buffer = cast(char*)data.ptr;
        r.length = data.length;
        r.mode = MHD_RESPMEM_MUST_COPY;
        return r;
    }

    void reserve(size_t newcap)
    {
        import core.stdc.stdlib : realloc;
        assert(mode == MHD_RESPMEM_MUST_FREE, "reserve only valid on dynamic replies");
        char *p = cast(char*)realloc(buffer, newcap);
        if (p == null)
            throw new Exception("realloc failed");
        buffer = p;
        capacity = newcap;
    }

    void ensurecap(size_t incoming)
    {
        if (length + incoming <= capacity)
            return;
        size_t newcap = capacity;
        while (newcap < length + incoming)
            newcap = newcap + (newcap >> 1) + PAGESIZE; // grow by 1.5x + page
        reserve(newcap);
    }

    void put(const(char)[] data)
    {
        ensurecap(data.length);
        buffer[length .. length + data.length] = data[];
        length += data.length;
    }

    void put(char c)
    {
        ensurecap(1);
        buffer[length] = c;
        length += 1;
    }

    void writef(Args...)(string fmt, Args args)
    {
        import std.format : formattedWrite;
        formattedWrite(this, fmt, args);
    }

    const(char)[] opSlice()
    {
        return buffer[0 .. length];
    }

    size_t size()
    {
        return length;
    }

private:
    enum PAGESIZE = 4096; // HACK
    char *buffer;
    size_t capacity;
    size_t length;
    // Modes:
    // MHD_RESPMEM_PERSISTENT: No free, no copy
    // MHD_RESPMEM_MUST_FREE : MHD will use free.3
    // MHD_RESPMEM_MUST_COPY : Copies into internal buffer
    int mode;
}
unittest
{
    // Dynamic reply
    HTTPReply reply = HTTPReply.create(128);
    assert(reply.size == 0);
    assert(reply.capacity >= 128);

    reply.put("hello");
    assert(reply.size == 5);
    assert(reply[] == "hello");

    reply.put(" world");
    assert(reply.size == 11);
    assert(reply[] == "hello world");

    reply.put("");
    assert(reply.size == 11);
    assert(reply[] == "hello world");
}
unittest
{
    // Growth beyond initial capacity
    HTTPReply reply = HTTPReply.create(4);
    reply.put("abcdef"); // exceeds initial capacity of 4
    assert(reply.size == 6);
    assert(reply[] == "abcdef");
}
unittest
{
    // Multiple puts triggering multiple growths
    HTTPReply reply = HTTPReply.create(8);
    foreach (i; 0 .. 1000)
        reply.put("x");
    assert(reply.size == 1000);

    const(char)[] data = reply[];
    foreach (c; data)
        assert(c == 'x');
}
unittest
{
    // Reserve explicitly
    HTTPReply reply = HTTPReply.create(16);
    reply.put("abc");
    reply.reserve(4096);
    assert(reply.capacity >= 4096);
    assert(reply.size == 3);
    assert(reply[] == "abc");
}
unittest
{
    // writef
    HTTPReply reply = HTTPReply.create(64);
    reply.writef("Hello, %s! You are %d years old.", "Alice", 30);
    assert(reply[] == "Hello, Alice! You are 30 years old.");

    reply.writef(" Score: %0.1f", 9.5);
    assert(reply[] == "Hello, Alice! You are 30 years old. Score: 9.5");
}
unittest
{
    // Static buffer
    immutable string data = "hello static";
    HTTPReply reply = HTTPReply.staticBuffer(data);
    assert(reply.size == 12);
    assert(reply[] == "hello static");
}
unittest
{
    // Copy buffer from stack data
    char[16] stackbuf = 0;
    stackbuf[0..5] = "stack";
    HTTPReply reply = HTTPReply.copyBuffer(stackbuf[0..5]);
    assert(reply.size == 5);
    assert(reply[] == "stack");
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
    
    void reply(int http_code, HTTPReply reply, inout(char) *contentType)
    {
        MHD_Response *response = MHD_create_response_from_buffer(
            reply.length, cast(void*)reply.buffer,
            reply.mode);
        if (response == null)
            throw new MHDException("MHD_create_response_from_buffer");

        MHD_Result result = void;

        result = MHD_add_response_header(response, "Content-Type", contentType);
        if (result == MHD_NO)
            throw new MHDException("MHD_add_response_header");

        foreach (h; response_headers)
        {
            result = MHD_add_response_header(response, h.key, h.value);
            if (result == MHD_NO)
                throw new MHDException("MHD_add_response_header");
        }

        result = MHD_queue_response(connection, http_code, response);
        if (result == MHD_NO)
            throw new MHDException("MHD_queue_response");

        MHD_destroy_response(response);
    }

    /// Get a request header value by name. Returns null if not found.
    string header(string key)
    {
        const(char)* value = MHD_lookup_connection_value(
            connection,
            MHD_HEADER_KIND,
            toStringz(key)
        );

        return value ? cast(string)fromStringz(value) : null;
    }

    /// Add a response header to be sent with the reply.
    ref typeof(this) addHeader(const(char)* key, const(char)* value) return
    {
        response_headers ~= ResponseHeader(key, value);
        return this;
    }

    /// Send a redirect response.
    void redirect(int http_code, string location)
    {
        MHD_Response *response = MHD_create_response_from_buffer(
            0, null, MHD_RESPMEM_PERSISTENT);
        if (response == null)
            throw new MHDException("MHD_create_response_from_buffer");

        MHD_Result result = void;

        result = MHD_add_response_header(response, "Location", toStringz(location));
        if (result == MHD_NO)
            throw new MHDException("MHD_add_response_header");

        foreach (h; response_headers)
        {
            result = MHD_add_response_header(response, h.key, h.value);
            if (result == MHD_NO)
                throw new MHDException("MHD_add_response_header");
        }

        result = MHD_queue_response(connection, http_code, response);
        if (result == MHD_NO)
            throw new MHDException("MHD_queue_response");

        MHD_destroy_response(response);
    }

    /// Send a JSON response.
    void replyJSON(int http_code, const(char)[] json_body)
    {
        reply(http_code, HTTPReply.copyBuffer(json_body), "application/json");
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
    ResponseHeader[] response_headers;
}

struct ResponseHeader
{
    const(char)* key;
    const(char)* value;
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
    
    /// Set the maximum allowed upload body size in bytes. 0 means unlimited.
    typeof(this) maxUploadSize(size_t limit)
    {
        state.max_upload_size = limit;
        return this;
    }

    /// Set the number of threads in MHD's internal thread pool.
    /// Must be called before start(). Default is 0 (single thread).
    typeof(this) threadPoolSize(uint size)
    {
        state.thread_pool_size = size;
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
    
    typeof(this) get(string path, int delegate(ref HTTPRequest) handler)
    {
        return addRoute("GET", path, handler);
    }
    
    typeof(this) head(string path, int delegate(ref HTTPRequest) handler)
    {
        return addRoute("HEAD", path, handler);
    }
    
    typeof(this) options(string path, int delegate(ref HTTPRequest) handler)
    {
        return addRoute("OPTIONS", path, handler);
    }
    
    typeof(this) trace(string path, int delegate(ref HTTPRequest) handler)
    {
        return addRoute("TRACE", path, handler);
    }
    
    typeof(this) put(string path, int delegate(ref HTTPRequest) handler)
    {
        return addRoute("PUT", path, handler);
    }
    
    typeof(this) post(string path, int delegate(ref HTTPRequest) handler)
    {
        return addRoute("POST", path, handler);
    }
    
    typeof(this) patch(string path, int delegate(ref HTTPRequest) handler)
    {
        return addRoute("PATCH", path, handler);
    }
    
    typeof(this) delete_(string path, int delegate(ref HTTPRequest) handler)
    {
        return addRoute("DELETE", path, handler);
    }
    
    // Not commonly use at application level
    typeof(this) connect(string path, int delegate(ref HTTPRequest) handler)
    {
        return addRoute("CONNECT", path, handler);
    }
    
    /// Get the port the server is listening on (useful when started with port 0).
    ushort port()
    {
        if (!state.daemon)
            throw new Exception("Server not started");
        const(MHD_DaemonInfo)* info = MHD_get_daemon_info(state.daemon, MHD_DAEMON_INFO_BIND_PORT);
        if (info == null)
            throw new MHDException("MHD_get_daemon_info");
        return info.port;
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
            MHD_OPTION_LISTENING_ADDRESS_REUSE, 1,
            MHD_OPTION_STRICT_FOR_CLIENT, 0,
            MHD_OPTION_THREAD_POOL_SIZE, state.thread_pool_size,
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
    size_t max_upload_size;
    uint thread_pool_size;
}

/// Per-request state for accumulating upload data across MHD callbacks.
struct ConnectionData
{
    ubyte[] payload;
    bool upload_too_large;
}

static if (bindbc.libmicrohttpd.staticBinding)
{
    void libmicrohttpd_load() {} // compiler is free to optimize this out
}
else
{
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
}

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
    // MHD uses its own thread pool: Register foreign threads with
    // the D runtime so the GC can scan their stacks and collect
    // allocations made during request handling.
    if (Thread.getThis() is null)
        thread_attachThis();

    // First call for this request: Initialize connection state.
    // MHD calls the handler multiple times per request: once to signal
    // a new request, then for each chunk of upload data, then a final
    // call with upload_data_size == 0 when all data has been received.
    if (*ptr is null)
    {
        ConnectionData *cd = new ConnectionData();
        GC.addRoot(cast(void*)cd);
        *ptr = cast(void*)cd;
        return MHD_YES;
    }

    ConnectionData *cd = cast(ConnectionData*)*ptr;
    ServerState *state = cast(ServerState*)cls;
    assert(state, "server state is NULL");

    // Accumulate upload data (POST/PUT body chunks)
    if (*upload_data_size > 0)
    {
        if (!cd.upload_too_large)
        {
            if (state.max_upload_size > 0 &&
                cd.payload.length + *upload_data_size > state.max_upload_size)
            {
                // Mark as too large — stop buffering but keep consuming
                // so MHD can finish receiving. Response is sent on final call.
                cd.upload_too_large = true;
                cd.payload = null;
            }
            else
            {
                cd.payload ~= (cast(ubyte*)upload_data)[0..*upload_data_size];
            }
        }
        *upload_data_size = 0;
        return MHD_YES;
    }

    // Final call — all upload data received, dispatch to route handler.
    scope(exit)
    {
        GC.removeRoot(cast(void*)cd);
        *ptr = null;
    }

    // Upload exceeded the configured limit — reject without dispatching.
    if (cd.upload_too_large)
    {
        // TODO: Could be interesting to hook a custom 413 handler eventually, if needed
        MHD_Response *response = MHD_create_response_from_buffer(
            0, null, MHD_RESPMEM_PERSISTENT);
        MHD_queue_response(connection, HTTPStatus.payloadTooLarge, response);
        MHD_destroy_response(response);
        return MHD_YES;
    }

    HTTPRequest req = HTTPRequest(
        connection,
        fromStringz(method).idup,
        fromStringz(url).idup
    );
    req.payload = cd.payload;

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
            char[256] buf = void;
            char[] res = sformat(buf,
                `<!DOCTYPE html><html><body>%s - %s</body></html>`,
                hex.code, hex.msg);
            req.reply(hex.code, HTTPReply.copyBuffer(res), `text/html`);
        }
        else
        {
            req.reply(
                500,
                HTTPReply.staticBuffer(
                    `<!DOCTYPE html><html><body>Internal server error</body></html>`),
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