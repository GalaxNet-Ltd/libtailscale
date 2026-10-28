# TailscaleKit

The TailscaleKit Swift package provides an embedded network interface that can be
used to listen for and dial connections to other [Tailscale](https://tailscale.com) nodes in addition 
to an extension to URLSession which allows you to make URL requests to nodes on you Tailnet directly.

The interfaces are similar in design to NWConnection, but are Swift 6 compliant and
designed to be used in modern async/await style code.  

## Build and Install

Build Requirements:
  - XCode 16.1 or newer

Building Tailscale.framework:

From /swift 
```bash
$ make macos
$ make ios
$ make ios-sim
$ make ios-fat
```

These recipes build different variants of TailscaleKit.framework into /swift/build/Build/Products.

Separate frameworks will be built for macOS and iOS and the iOS Simulator.  All dependencies (libtailscale*.a)
are built automatically.  Swift 6 is supported.

The ios and ios-sim frameworks are purposefully separated.  The former is free of any simulator segments
and is suitable for app-store submissions.   The latter is suitable for embedding when you 
wish to run on a simulator in dev though 'make ios-fat' will produce an xcframework bundle including
both simulator and device frameworks for development.

The frameworks are not signed and must be signed when they are embedded.

Alternatively, you may build from xCode using the Tailscale scheme but the 
libraries must be built first (since xCode will complain about paths and
permissions)

To build only the static libraries, from / 
```bash
$ make c-archive
$ make c-archive-ios 
$ make c-archive-ios-sim
```

If you're writing pure C, or C++, link these and use the generated tailscale.h header.  
make c-archive builds for the local machine architecture/platform (arm64 macOS from a mac)

Non-apple swift builds are not supported (yet) but should be possible with a little tweaking.

## Tests

From /swift
```bash
$ make test
```

To run the native LocalAPI bridge, IPN ordering, overflow and cancellation
regressions, first build the local Go archives and `tstestcontrol` library, then
run from `/swift`:

```bash
xcodebuild -project TailscaleKit.xcodeproj -scheme TailscaleKitXCTests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
  -only-testing:TailscaleKitXCTests/MessagePipelineTests \
  EXCLUDED_SOURCE_FILE_NAMES=TailscaleKitTests.swift \
  CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete test
```

The existing connection test file still references the removed `Listener` API,
so this focused command excludes that file from compilation. It does not verify
the legacy connection tests. The stream tests include real C/Go callbacks and disposable unauthenticated
tsnet nodes pointed at a loopback-only unavailable coordinator. They do not use
the app's configured tailnets or require authorization. Go tests additionally
exercise controlled HTTP handlers over memnet, node-close races and deadlines:
`go test -race . ./localproxy` from the repository root.

## NovaScale in-process LocalAPI bridge

Swift `LocalAPIClient` routes status, preferences, login, profiles, ping and IPN
watching through `tailscale_localapi_start/cancel` into the node's public
`tsnet.Server.LocalClient()`. That client uses tsnet's Go memnet listener: HTTP
semantics remain, with no LocalAPI TCP/Unix socket or URLSession dependency.
`loopback()` remains available for browser SOCKS consumers; foreground repair
can use `repairExistingLoopbackIfNeeded()` without creating a listener.

The C API requires an already started node. It copies request arguments before
returning, supplies an opaque operation ID, and delivers serial header/data/end
callbacks on Go workers. Callback bytes are borrowed for the call only. Callers
must copy them and must not synchronously wait for a Swift actor/main thread.
Callbacks may arrive before start returns; a failed start emits no callbacks.
Successful starts always terminate once, including cancellation and node close.
Close cancels only operations owned by that node. Swift uses numeric registry
tokens, never retained Go/Swift object pointers across the C boundary.

Unary calls keep their existing whole-request timeouts and HTTP status/error
bodies. Watches have a ten-second startup deadline, including the first initial
snapshot when requested, and no established-watch lifetime timeout. Cancellation
is explicit and idempotent. The Swift queue permits 24 notifications and 32 MiB
of retained payloads, including the message held by its consumer. Overflow, EOF,
malformed data or native failure closes the watch; callers must subscribe again
with initial state and netmap. Notifications are decoded and awaited in order.

This transport resumes with the existing process; it does not run or wake an app
while iOS suspends it. Callers still need node-generation checks, observer-health
state, initial-snapshot reconciliation and backend/network recovery. Process
termination always requires a new node and watch.

## NovaScale local-app proxy bridge

`tailscale_local_proxy_start/route/stats/stop` is a separate, explicit-opt-in
listener for other applications on the same device. It binds IPv4 loopback only;
it does not expose or change authenticated `Loopback()` / LocalAPI access.
SOCKS5 supports no-auth TCP CONNECT (no BIND/UDP). Go's standard HTTP stack handles
absolute-form requests, CONNECT, streaming and upgrades. Routes resolve only exact
peer IPs or unambiguous MagicDNS names from the selected node's current typed status;
there is no system DNS, public-internet, subnet-route or exit-node fallback.

The proxy ID owns the listener independently of a node handle. Call `route(id, -1)`
before replacing/closing a node; it closes accepted streams and cancels pending
work, but reserves the same port. Route to the replacement node only after its
Running state. Existing streams are never migrated/replayed. `stop` closes only
this listener and its streams. Its caller owns entitlement decisions and must not
start it silently after app relaunch. `stats` counts connected client sockets with
at least one successful upstream dial; an HTTP keep-alive socket can remain counted
until its 30-second idle timeout. This is not byte-activity telemetry.

Regression checks and artifact rebuild, without changing dependency versions:

```sh
# From the libtailscale root:
go test -race ./localproxy . -run 'Test(LocalProxy|HTTP|Reject|SOCKS|Switch|Client|Mapped)'
# From swift/ (force Go source/header changes through all framework slices):
make -B xcframework
```

The app imports the generated Release-xcframework artifact. Header declarations in
`tailscale.h` and `swift/TailscaleKit/TailscaleKit.h` must remain aligned. These new
files plus the appended C bridge comprise this feature's fork changes; neither the
Tailscale module revision nor the existing Swift node/dial/Loopback APIs changed.

## Usage

Nodes need to be authorized in order to function. Set an auth key via
the config.authKey parameter, or watch the ipn bus (see the example) for
the browseToURL field for interactive web-based auth.

Here's a working example using an auth key:

```Swift
func start() -> TailscaleNode {
    let dataDir = getDocumentDirectoryPath().absoluteString + "tailscale"
    let authKey = "tsnet-auth-put-your-auth-key-key-here"
    let config = Configuration(hostName: "TSNet-Test",
                               path: dataDir,
                               authKey: authKey,
                               controlURL: Configuration.defaultControlURL,
                               ephemeral: false)

    // The logger is configurable.  The default will just print.
    let node = try TailscaleNode(config: config, logger: DefaultLogger())
    
    // Bring the node up 
    try await node.up()
    return node
}

// Do a URL request via the loopback proxy
// Where url is a node on your tailnet such as https://server.fiesty-pangolin.ts.net/thing
func fetchURL(_ url: URL, tailscale: TailscaleNode) async throws -> Data {
    // You can cache this.  It will not change once the node is up.
    let sessionConfig = try await URLSessionConfiguration.tailscaleSession(tailscale)
    let session = URLSession(configuration: sessionConfig)
    
    // Make the request
    let req = URLRequest(url: url)
    let (data, _) = try await session.data(for: req)
    return data
}
```

The "node" created here should show up in the Tailscale admin panel as "TSNet-Test"

### LocalAPI

TailscaleKit.framework also includes a functional (though somewhat incomplete) implementation of 
LocalAPI which can be used to track the state of the embedded tailscale instance in much greater
detail.

Both the IPN watch and ordinary `LocalAPIClient` requests use the
[in-process LocalAPI bridge](#novascale-in-process-localapi-bridge). The watch has
a ten-second startup deadline and no established-subscription lifetime timeout.
Ordinary requests retain their per-request deadlines. Neither path uses
URLSession or the TCP `Loopback()` endpoint.

`Loopback()` still provides the authenticated SOCKS5 endpoint used for browser
traffic, and still exposes its legacy authenticated HTTP LocalAPI service. The
Swift LocalAPI client no longer calls that HTTP listener. The separately enabled
local-app proxy serves HTTP/CONNECT and SOCKS5 to other applications and owns a
different TCP listener; it is not part of the in-process migration.

Watch startup emits `IPN watch startup` records with a correlation ID,
`transport=in-process`, phase and monotonic elapsed milliseconds. Phases cover
native start, subscription acceptance, first notification, worker startup,
decode and consumer delivery. Credentials and notification payloads are not
logged by this trace. Compare elapsed times rather than cross-thread log order.
First delivery means the consumer callback returned; inspect the corresponding
backend state to establish readiness.

### Examples

See the TailscaleKitHello example for a relatively complete implementation demonstrating proxied
HTTP and usage of LocalAPI to track the tailnet state.

## Contributing

Pull requests are welcome on GitHub at https://github.com/tailscale/libtailscale

Please file any issues about this code or the hosted service on
[the issue tracker](https://github.com/tailscale/tailscale/issues).
