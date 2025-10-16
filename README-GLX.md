# Notes by GalaxNet

# Swift Binding

this libtailscale version is intended to be used inside an application, which differ with the regular use, including most desktop
version and iOS version which Network Extension is running in a dedicate process.

the swift binding leverage tailscale/tsnet's loopback function to create a tcp server which listen on a localhost(127.0.0.1) and
use a net/proxymux which dispatch connections based solely on first bytes. for socks5 conn it dispatch the connection to socks5
handler which will be used to dial into the tailnet network, for http conn, it dispatch it tsnet's local api server which is used
to interact with the embedded tailnet backend.

## URLSession+Tailscale.swift

this interface seems is intended for route user http request throught a socks5 proxy, but this actually does not work on iOS platform
due to kCFProxySocksEnable is not available on iOS; though LocalAPIClient.swift use this, it actuall does not work and total bypass 
the socks proxy, it work because it use the loopback ip/port(which is same for socks5 proxy) to make the HTTP request and that works.
