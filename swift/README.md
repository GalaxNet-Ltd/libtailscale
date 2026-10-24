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

To run only the IPN stream framing, ordering, overflow and cancellation
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
the legacy connection tests. The stream tests use an in-memory HTTP protocol
and do not contact a coordinator or require an authorized tailnet.

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

The IPN bus watch uses a dedicated copy of the HTTP configuration and an explicit
24-hour request and resource timeout. A quiet bus must not inherit the ordinary
[60-second request inactivity timeout](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforrequest).
The [resource timeout](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/timeoutintervalforresource)
bounds the whole subscription to 24 hours; its owner must resubscribe on failure
or expiry. HTTP subscription startup retains a separate 60-second deadline
until successful response headers arrive; a stalled startup fails with a timeout
so its owner can retry. `MessageProcessor.cancel()` still stops the watch immediately.
Ordinary LocalAPI requests and the caller's configuration retain their existing
timeout policy. The focused stream tests verify the request passed to URLSession,
configuration isolation, cancellation of that long-lived request, and the
startup deadline's failure and cancellation after accepted headers.
Replacement-watch tests also verify real HTTP cancellation while an old consumer
is suspended or startup is awaiting headers, and independent ordered delivery
on a new watch. Buffered and late old bytes use the reader's test injection path;
these tests do not simulate an actual control-server/tailnet switch or deliver
unsupported URLProtocol callbacks after cancellation.

Watch startup also emits a bounded set of `IPN watch startup` diagnostic records
through the existing LogSink. One correlation ID and monotonic elapsed milliseconds
cover reader queue entry, task resume, response headers, first body/frame,
startup continuation return, worker launch/entry and first consumer delivery.
The configuration record contains only connectivity-wait/proxy-present booleans;
no request headers, credentials or notification payloads are included. Reader
flags stay on its serial delegate queue and worker flags stay in the consumer
task. Resume-to-headers includes transport, local handler and delegate scheduling;
these timestamps alone cannot attribute that interval to the coordinator or
network. First delivery records the consumer callback returning; it does not
establish a Running event or readiness publication, particularly if cancellation
occurred during that callback. Compare elapsed times rather than cross-thread
log-line order. The focused tests distinguish accepted HTTP startup from a suspended
consumer and verify one-time first-event records without logging sensitive data.

### Examples

See the TailscaleKitHello example for a relatively complete implementation demonstrating proxied
HTTP and usage of LocalAPI to track the tailnet state.

## Contributing

Pull requests are welcome on GitHub at https://github.com/tailscale/libtailscale

Please file any issues about this code or the hosted service on
[the issue tracker](https://github.com/tailscale/tailscale/issues).
