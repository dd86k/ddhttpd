module ddhttpd.server;

import bindbc.libmicrohttpd;
static if (!bindbc.libmicrohttpd.staticBinding)
    import bindbc.loader;
import core.atomic : atomicLoad, atomicStore;
import core.memory : GC;
import core.thread.osthread : Thread;
import std.conv : text;
import std.encoding;
import std.socket : Address, Socket;
import std.stdio;
import std.string : toStringz, fromStringz, indexOf;
import ddhttpd.websocket : WebSocketConnection, WSUpgradeClosure, ws_upgrade_callback, ws_compute_accept;

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

    /// Set how many event loop threads serve requests. Must be called before
    /// start(). Default is 1.
    ///
    /// Handlers run on one thread each, so anything above 1 means handlers can
    /// run concurrently and whatever state they share needs its own
    /// synchronization. `std.parallelism.totalCPUs` is a reasonable value, but
    /// note it reports the machine's cores, not a container's CPU quota.
    typeof(this) threadPoolSize(uint size)
    {
        if (size == 0)
            throw new Exception("Need at least one thread");
        if (state.loops.length)
            throw new Exception("Already started");
        state.pool_size = size;
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

    /// Register a WebSocket handler for the given path.
    /// The handler receives a WebSocketConnection and runs in its own thread.
    typeof(this) websocket(string path, void delegate(WebSocketConnection) handler)
    {
        if (!path)
            throw new Exception("Path required");
        if (path[0] != '/')
            throw new Exception("Path needs to start with '/'");
        if (!handler)
            throw new Exception("Need handler function");
        state.ws_routes ~= WSRoute(PathPattern(null, path, null), handler);
        return this;
    }
    
    /// Get the port the server is listening on (useful when started with port 0).
    ushort port()
    {
        if (state.loops.length == 0)
            throw new Exception("Server not started");
        return state.bound_port;
    }

    /// Stop serving and wait for the event loop threads to finish.
    ///
    /// Worth calling before the program exits: the event loop threads are
    /// daemon threads, so termination does not wait for them and they may
    /// still be serving requests while the runtime shuts down.
    void stop()
    {
        if (state.loops.length == 0)
            return;

        foreach (ref DaemonLoop dl; state.loops)
            if (Thread.getThis() is dl.thread)
                throw new Exception("Cannot stop the server from a request handler");

        // The loops check this at most POLL_INTERVAL msecs from now
        foreach (ref DaemonLoop dl; state.loops)
        {
            atomicStore(dl.running, false);
        }

        foreach (ref DaemonLoop dl; state.loops)
        {
            if (dl.thread)
            {
                dl.thread.join(); // rethrows what the loop threw
                dl.thread = null;
            }
        }

        foreach (ref DaemonLoop dl; state.loops)
        {
            if (dl.daemon == null) // start() failed partway through
                continue;
            // Every daemon in a pool was handed the same listening socket, and
            // MHD_stop_daemon closes it. Quiescing hands it back to us first,
            // so it is only closed once, by us.
            if (state.listener)
                MHD_quiesce_daemon(dl.daemon);
            MHD_stop_daemon(dl.daemon);
            dl.daemon = null;
        }

        state.loops = null;
        if (state.listener)
        {
            state.listener.close();
            state.listener = null;
        }
    }
    
    // Start daemon mode
    void start(ushort port, int flags = 0)
    {
        startDaemon(null, port, flags);
    }

    /// Start daemon mode, binding the listening socket to a specific address.
    ///
    /// The address can be a numeric IPv4 address ("127.0.0.1"), a numeric IPv6
    /// address ("::1"), or a hostname ("localhost"), which is resolved to its
    /// first matching address.
    /// Params:
    ///   address = Address to bind the listening socket to.
    ///   port = Port to listen on, 0 to let the system pick one.
    ///   flags = Additional start flags.
    void start(string address, ushort port, int flags = 0)
    {
        if (!address)
            throw new Exception("Address required");

        startDaemon(resolveBindAddress(address, port, (flags & START_IPV6) != 0), port, flags);
    }

    /// Start daemon mode, binding the listening socket to an already resolved
    /// address, like `new InternetAddress("127.0.0.1", 8080)`.
    /// Params:
    ///   address = Address to bind the listening socket to.
    ///   flags = Additional start flags.
    void start(Address address, int flags = 0)
    {
        if (!address)
            throw new Exception("Address required");

        startDaemon(address, 0, flags);
    }

private:

    void startDaemon(Address address, ushort port, int flags)
    {
        // MHD runs in "external" polling mode: without
        // MHD_USE_INTERNAL_POLLING_THREAD it creates no threads of its own and
        // every callback runs on the thread calling MHD_run, which is a thread
        // we create and the D runtime therefore knows about.
        //
        // MHD_USE_POLL is an internal polling mode option only. epoll is
        // usable from an external loop, since MHD hands out the epoll
        // descriptor to wait on.
        version (linux)
            enum DEFAULT_FLAGS =
                MHD_USE_TCP_FASTOPEN | // >=3.6
                MHD_USE_EPOLL;
        else
            enum DEFAULT_FLAGS = 0;

        if (state.loops.length)
            throw new Exception("Already started");

        flags |= DEFAULT_FLAGS;
        // WS needs to allow upgrading for it to work, do it transparently
        if (state.ws_routes.length)
            flags |= MHD_ALLOW_UPGRADE;

        if (address)
        {
            import std.socket : AddressFamily;

            // The listening socket is created using the family selected by the
            // flags, so it must match the family of the address
            if (address.addressFamily == AddressFamily.INET6)
                flags |= MHD_USE_IPv6;
            else if (flags & MHD_USE_IPv6)
                throw new Exception(text("IPv6 requested with non-IPv6 address '",
                    address.toAddrString(), "'"));

            // MHD only reads the sockaddr while starting, but keep it around
            // for the lifetime of the daemon anyway
            state.listen_addr = address;
        }

        // Every daemon in a pool has to accept from the same socket: one
        // socket each would mean one port each when starting on port 0, and
        // MHD only splits a listening socket across threads it owns itself.
        if (state.pool_size > 1)
            state.listener = createListener(address, port, flags);

        // Undoes whatever got started before something failed
        scope(failure) stop();

        state.loops = new DaemonLoop[](state.pool_size);
        foreach (ref DaemonLoop dl; state.loops)
        {
            if (state.listener)
                dl.daemon = MHD_start_daemon(
                    flags, port,
                    null, null,
                    &ddhttpd_handler, &state,
                    MHD_OPTION_LISTEN_SOCKET, state.listener.handle,
                    MHD_OPTION_STRICT_FOR_CLIENT, 0,
                    MHD_OPTION_END);
            else if (address)
                // Port is taken from the address, MHD ignores its port argument
                // when given MHD_OPTION_SOCK_ADDR
                dl.daemon = MHD_start_daemon(
                    flags, port,
                    null, null,
                    &ddhttpd_handler, &state,
                    MHD_OPTION_SOCK_ADDR, address.name,
                    MHD_OPTION_LISTENING_ADDRESS_REUSE, 1,
                    MHD_OPTION_STRICT_FOR_CLIENT, 0,
                    MHD_OPTION_END);
            else
                dl.daemon = MHD_start_daemon(
                    flags, port,
                    null, null,
                    &ddhttpd_handler, &state,
                    MHD_OPTION_LISTENING_ADDRESS_REUSE, 1,
                    MHD_OPTION_STRICT_FOR_CLIENT, 0,
                    MHD_OPTION_END);

            if (dl.daemon == null)
                throw new MHDException("MHD_start_daemon");

            version (linux)
            {
                // Fail here rather than inside the loop thread
                const(MHD_DaemonInfo) *info =
                    MHD_get_daemon_info(dl.daemon, MHD_DAEMON_INFO_EPOLL_FD);
                if (info == null)
                    throw new MHDException("MHD_get_daemon_info");
                dl.epoll_fd = info.epoll_fd;
            }
        }

        state.bound_port = state.listener
            ? addressPort(state.listener.localAddress)
            : daemonPort(state.loops[0].daemon);

        foreach (ref DaemonLoop dl; state.loops)
        {
            atomicStore(dl.running, true);

            // The loop delegate points into the array, which is never resized,
            // and keeps this instance alive for as long as the thread runs
            dl.thread = new Thread(&dl.loop);
            // A program that never calls stop() should still be able to exit,
            // like it could when MHD owned the threads
            dl.thread.isDaemon = true;
            dl.thread.start();
        }
    }

    /// Create the socket a pool of daemons accepts from.
    static Socket createListener(Address address, ushort port, int flags)
    {
        import std.socket : AddressFamily, Internet6Address, InternetAddress,
            ProtocolType, SocketOption, SocketOptionLevel, SocketType;

        version (Windows)
            import core.sys.windows.winsock2 : SOMAXCONN;
        else
            import core.sys.posix.sys.socket : SOMAXCONN;

        AddressFamily family = address ? address.addressFamily :
            (flags & MHD_USE_IPv6 ? AddressFamily.INET6 : AddressFamily.INET);

        Socket sock = new Socket(family, SocketType.STREAM, ProtocolType.TCP);
        scope(failure) sock.close();

        sock.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);

        if (family == AddressFamily.INET6)
            sock.setOption(SocketOptionLevel.IPV6, SocketOption.IPV6_V6ONLY,
                (flags & MHD_USE_DUAL_STACK) == MHD_USE_DUAL_STACK ? 0 : 1);

        // MHD sets this on sockets it creates, do the same for ours
        version (linux)
            if (flags & MHD_USE_TCP_FASTOPEN)
            {
                import core.sys.linux.netinet.tcp : TCP_FASTOPEN;
                sock.setOption(SocketOptionLevel.TCP,
                    cast(SocketOption)TCP_FASTOPEN, FASTOPEN_QUEUE);
            }

        if (address)
            sock.bind(address);
        else if (family == AddressFamily.INET6)
            sock.bind(new Internet6Address(Internet6Address.ADDR_ANY, port));
        else
            sock.bind(new InternetAddress(InternetAddress.ADDR_ANY, port));

        sock.listen(SOMAXCONN);
        return sock;
    }

    ServerState state;
}

//
// Private functions
//

private:

/// Resolve a numeric address or hostname into an address usable for binding.
/// Params:
///   address = Numeric address or hostname.
///   port = Port number.
///   prefer_ipv6 = Select the first IPv6 result, if any.
/// Returns: Resolved address.
Address resolveBindAddress(string address, ushort port, bool prefer_ipv6)
{
    import std.socket : AddressFamily, AddressInfo, getAddressInfo, SocketException, SocketType;

    AddressInfo[] infos;
    try
    {
        infos = getAddressInfo(address, text(port), SocketType.STREAM);
    }
    catch (SocketException ex)
    {
        throw new Exception(text("Could not resolve address '", address, "': ", ex.msg));
    }

    if (infos.length == 0)
        throw new Exception(text("No addresses found for '", address, "'"));

    if (prefer_ipv6)
        foreach (ref AddressInfo info; infos)
            if (info.family == AddressFamily.INET6)
                return info.address;

    return infos[0].address;
}

/// A single url path route
struct Route
{
    string method;
    string path;
    int delegate(ref HTTPRequest) handler;
}

struct WSRoute
{
    PathPattern pattern;
    void delegate(WebSocketConnection) handler;
}

struct ServerState
{
    Route[string][string] exact_routes;
    PathPattern[] pattern_routes;
    WSRoute[] ws_routes;
    /// Address the listening socket is bound to, null when binding to any address
    Address listen_addr;
    int delegate(ref HTTPRequest, Exception) on_error_exception;
    size_t max_upload_size;
    /// One daemon and one thread per pool slot, empty until start()
    DaemonLoop[] loops;
    /// Listening socket shared by a pool, null when MHD owns the socket
    Socket listener;
    ushort bound_port;
    uint pool_size = 1;
}

/// One MHD daemon and the thread driving it. Handlers run on that thread,
/// which the D runtime knows about, unlike a thread MHD would have made.
struct DaemonLoop
{
    MHD_Daemon *daemon;
    Thread thread;
    /// Cleared by stop() to bring the loop down
    shared bool running;
    version (linux) int epoll_fd = -1;

    /// Longest a wait may last, so that stop() is noticed reasonably quickly
    enum int POLL_INTERVAL = 100;

    /// How long to wait for network activity, in msecs. MHD needs to run again
    /// once its timeout expires, or connections hang and never time out.
    int wait_time()
    {
        MHD_UNSIGNED_LONG_LONG timeout = void;
        if (MHD_get_timeout(daemon, &timeout) == MHD_NO)
            return POLL_INTERVAL;
        return timeout < POLL_INTERVAL ? cast(int)timeout : POLL_INTERVAL;
    }

    /// Wait for activity, then let MHD process it, until stop() says otherwise.
    void loop()
    {
        version (linux)
        {
            import core.sys.posix.poll : pollfd, poll, POLLIN;

            // MHD registers every socket it owns, including the listening one,
            // with this epoll descriptor
            pollfd pfd;
            pfd.fd     = epoll_fd;
            pfd.events = POLLIN;

            while (atomicLoad(running))
            {
                poll(&pfd, 1, wait_time());
                MHD_run(daemon);
            }
        }
        else
        {
            version (Windows)
                import core.sys.windows.winsock2 : fd_set, FD_ZERO, select, timeval;
            else
                import core.sys.posix.sys.select : fd_set, FD_ZERO, select, timeval;

            while (atomicLoad(running))
            {
                fd_set rs = void, ws = void, es = void;
                FD_ZERO(&rs);
                FD_ZERO(&ws);
                FD_ZERO(&es);

                // NOTE: select cannot watch descriptors past FD_SETSIZE, which
                //       caps how many connections MHD can serve here. Linux
                //       uses epoll and has no such limit.
                MHD_socket maxfd;
                if (MHD_get_fdset(daemon, &rs, &ws, &es, &maxfd) == MHD_NO)
                    throw new MHDException("MHD_get_fdset");

                int msecs = wait_time();
                timeval tv;
                tv.tv_sec  = cast(typeof(tv.tv_sec))(msecs / 1000);
                tv.tv_usec = cast(typeof(tv.tv_usec))((msecs % 1000) * 1000);

                select(cast(int)(maxfd + 1), &rs, &ws, &es, &tv);
                MHD_run_from_select(daemon, &rs, &ws, &es);
            }
        }
    }
}

/// TCP Fast Open queue length, MHD's own default.
enum FASTOPEN_QUEUE = 10;

/// Port an address is bound to.
ushort addressPort(Address address)
{
    import std.conv : to;
    return to!ushort(address.toPortString());
}

/// Port a daemon's listening socket is bound to.
ushort daemonPort(MHD_Daemon *daemon)
{
    const(MHD_DaemonInfo) *info = MHD_get_daemon_info(daemon, MHD_DAEMON_INFO_BIND_PORT);
    if (info == null)
        throw new MHDException("MHD_get_daemon_info");
    return info.port;
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
        
        if (state.ws_routes.length && req.method == "GET")
        {
            import std.uni : toLower;
            string upgrade_hdr = req.header("Upgrade");
            if (upgrade_hdr && toLower(upgrade_hdr) == "websocket")
            {
                foreach (ref wsroute; state.ws_routes)
                {
                    if (wsroute.pattern.match(req.path, req.params))
                        return ws_handle_upgrade(connection, req, wsroute.handler);
                }
            }
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

MHD_Result ws_handle_upgrade(MHD_Connection *connection, ref HTTPRequest req,
    void delegate(WebSocketConnection) handler)
{
    string key = req.header("Sec-WebSocket-Key");
    if (!key)
    {
        MHD_Response *resp = MHD_create_response_from_buffer(0, null, MHD_RESPMEM_PERSISTENT);
        MHD_queue_response(connection, HTTPStatus.badRequest, resp);
        MHD_destroy_response(resp);
        return MHD_YES;
    }

    string accept = ws_compute_accept(key);

    WSUpgradeClosure *cl = new WSUpgradeClosure(handler, req.params);
    GC.addRoot(cast(void*)cl);

    MHD_Response *resp = MHD_create_response_for_upgrade(&ws_upgrade_callback, cast(void*)cl);
    if (!resp)
    {
        GC.removeRoot(cast(void*)cl);
        return MHD_NO;
    }

    MHD_add_response_header(resp, MHD_HTTP_HEADER_UPGRADE, "websocket");
    MHD_add_response_header(resp, MHD_HTTP_HEADER_CONNECTION, "Upgrade");
    MHD_add_response_header(resp, MHD_HTTP_HEADER_SEC_WEBSOCKET_ACCEPT, toStringz(accept));

    MHD_Result result = MHD_queue_response(connection, MHD_HTTP_SWITCHING_PROTOCOLS, resp);
    MHD_destroy_response(resp);
    return result;
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