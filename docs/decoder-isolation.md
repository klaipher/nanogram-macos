# Isolated decoding (NanogramDecoder.xpc), first milestone

Goal: parse untrusted sticker and emoji bytes in a separate, sandboxed process, as Apple's BlastDoor does for
iMessage. A malicious sticker that corrupts memory or crashes a decoder then costs a helper process, not the app
with its session keys and chats. Spec: security review 2026-11-04, "isolated decoding".

## What ships in this milestone

| Piece | Where |
|---|---|
| Wire protocol, limits, client, service side, fallback | `packages/NanogramDecoder` (Swift 6, warnings as errors) |
| XPC service target `NanogramDecoder` (product `NanogramDecoder.xpc`) | `NanogramDecoderService/`, `Telegram.xcodeproj` |
| Entitlements: app sandbox only | `nanogram/entitlements/NanogramDecoder.entitlements` |
| Embedding | Copy Files phase "Embed XPC Services" of the `Telegram` target into `Contents/XPCServices`; both editions |
| App seam | `Telegram-Mac/packages-integration/hooks/LottieRenderHooksInstall.swift` (`makeLottieBridge`) |
| Switch | Nanogram, Debug Settings, Security, "Isolated sticker decoding" (`decoding.isolatedXPC`), off by default |
| Release tooling | `tg` stamps and re-signs the service with the archive; `tg editions` checks it is sandboxed, hardened and has no network or file entitlements |

Default behaviour is unchanged: with the switch off `makeLottieBridge` returns exactly the bridge the app created
before (TLottie, or RLottie when forced or when the server kill switch is set), with no wrapper.

## Decoder backend seam

`LottieRenderHooks.makeRenderer` (shared by cached thumbnails, the slot machine, call and recorder animations) and
`makeRLottie` (the animated sticker and emoji player) both call `makeLottieBridge(json:key:)`. With the switch on it
asks `IsolatedDecoderBackend.makeAnimation`, which returns:

1. a renderer backed by the XPC service, or
2. the legacy in-process bridge, wrapped, when the service is unavailable, refuses the input or fails to open.

`AnimationRendering` is the package-level abstraction both backends implement (start, end, fps, render a frame into
a caller buffer, set a colour). `StickerImageDecodeHooks` (TelegramMediaUtils) is the same seam for still WebP
sticker previews; it is `nil` unless the app installs it and the switch is on, and the cached-representation fetch
falls back to libwebp when it returns `nil`.

## Process boundary

- Sandbox: `com.apple.security.app-sandbox` only. No network, no file access, no mach-lookup exceptions, hardened
  runtime. The service gets compressed JSON bytes and returns pixels; it never sees a path.
- Connection: `NSXPCConnection(serviceName: "org.klaipher.Nanogram.Decoder")`. The interface carries only `Data`,
  `String` and numbers (no object graphs to deserialize). Each connection is its own service instance and its own
  session table.
- Wire: `openAnimation(Data)` returns a session, frame range and fps; `renderFrame(session, index, w, h,
  bytesPerRow)` returns `Data`; `setColor` and `closeAnimation` are one way.
- Limits, enforced by the client before sending and again by the service: animation 8 MB (the app's own unzip cap),
  frame sides 2048, frame 16 MB, 64 sessions per connection, image 8 MB, source image 36 Mpixel.
- Image decoding (still WebP) uses ImageIO inside the service, with the pixel-count check made from the header
  before any decode.

## Failure handling

Every call has a timeout (open 3 s, render 1.5 s, image 3 s). On a lost connection, a timeout or a malformed reply
the animation switches, for good, to an in-process renderer built from the same JSON with the colours replayed, and
the frame being asked for is rendered there, so the caller never sees a failure. The connection is invalidated, so
the next call starts a fresh service instance. Three failures in a row switch XPC off for 60 s (animations then go
straight in-process) and it is tried again afterwards. Content rejections (too large, unparsable, too many
sessions) are not service failures and never trip the breaker.

## Measurements

`DECODER-XPC-BENCH` in `DecoderXPCTests.test_perFrameOverhead_isMeasured`, 512x512 BGRA (1 MB) frame, 200 frames,
Apple Silicon: a fill costs about 50 us in process; through XPC the mean is 200 to 360 us, p95 230 to 700 us, so the
transport overhead is about 0.15 to 0.3 ms per frame (the test asserts the mean stays under 16 ms). These runs use an
in-process anonymous listener, so they include NSXPCConnection encoding, queue hops and the 1 MB reply copy but not
a real process switch; the number to confirm on the built app is the same measurement against the embedded service.
The real cost is the copy: sticker players render at 60 Hz for tens of visible stickers, so frame data must move to
shared memory before the switch is ever defaulted on (below).

## Not in this milestone, in order

1. Shared frames: pass an `xpc_shmem` ring or IOSurface per session so the service renders straight into memory the
   app maps, removing the per-frame copy and the `Data` allocation. The protocol already carries the geometry.
2. Gunzip in the service: the app still unzips `.tgs` (capped at 8 MB) and sends JSON. Sending the gzip bytes moves
   the inflate parser out too; zlib inflate needs the service to link zlib directly (not Compression's raw deflate).
3. Thumbnails and the rest of the sticker path: `makeLottieImage`, `fetchCachedRepresentation` for stickers, the
   `RenderedWebpFrame` animated WebP path in `LottiePlayer`, and chat-list and picker previews. Each goes through
   `IsolatedDecoderBackend` the same way; libwebp should be linked into the service so output is identical to the
   in-process path (ImageIO is used now only because it needs no extra linking).
4. Video stickers and FFmpeg probe: the highest-risk parser (VP9 and WebM demux in FFmpeg). A second service (or
   an operation on this one) with the same limits runs `avformat_open_input` on a memory buffer, rejects unknown
   containers and codecs, and returns decoded frames as IOSurface-backed pixel buffers. VideoToolbox decode of VP9
   stays where hardware access is allowed; the service only probes and, for the software path, decodes.
5. Caller identity: `setCodeSigningRequirement` on the service connection for the team, once local development
   signing identities are settled.
6. A watchdog in the service (kill itself if a render runs past a deadline) so a hung parser does not wait for the
   client to hang up.
7. Defaulting on: after steps 1 to 3, measure CPU and memory with 50 visible animated stickers and decide.

## iOS path

The iOS app cannot embed XPC services. From iOS 26 the supported way to run code in a separate sandboxed process is
ExtensionFoundation: define an `AppExtensionPoint` (`@AppExtensionPoint.Bind` in the host, `@AppExtensionPoint.Define`
in a shared module), ship the decoder as an extension target that conforms to it, and open it with
`AppExtensionProcess` / `AppExtensionIdentity` (the host launches the extension and talks over an
`NSXPCConnection` created from the process). The `NanogramDecoder` wire protocol, limits and fallback logic are
platform neutral; only `DecoderListenerDelegate.run()` (service entry) and `DecoderXPCClient.init(serviceName:)`
(connection factory) are macOS specific. Plan: move the package into the shared core, add an iOS extension target
that hosts the same listener, and give it the same entitlement discipline (no network, no app group file access).
tlottie and rlottie link into the extension as they do into the app. The iOS memory ceiling for extensions is low,
so frame size limits there should be tighter and the service should render at most one frame at a time.
Owner steps for iOS: none known for the capability, but the extension needs its own bundle identifier and
provisioning profile in the developer portal.
