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
before (TLottie: Telegram 13.2 dropped RLottie on the Mac, and so did the decoder service), with no wrapper.

## Decoder backend seam

`LottieRenderHooks.makeRenderer` (shared by cached thumbnails, the slot machine, call and recorder animations) and
`makeLottieRenderer` (the animated sticker and emoji player) both call `makeLottieBridge(json:)`. With the switch on it
asks `IsolatedDecoderBackend.makeAnimation`, which returns:

1. a renderer backed by the XPC service,
2. the legacy in-process bridge, wrapped, only when the service could not be started at all in this run (it has
   never answered and the connection is invalid, for example a build without the embedded service), or
3. nothing (the sticker shows its placeholder) when the service refused the content, the content is quarantined, or
   the service has been switched off by the breaker after it had worked.

`AnimationRendering` is the package-level abstraction both backends implement (start, end, fps, render a frame into
a caller buffer, set a colour). `StickerImageDecodeHooks` (TelegramMediaUtils) is the same seam for still WebP
sticker previews. It answers `image`, `refused` (show nothing, never try an in-process decoder) or `notHandled`
(switch off, or service never started: the cached-representation fetch uses libwebp as before).

## Process boundary

- Sandbox: `com.apple.security.app-sandbox` only. No network, no file access, no mach-lookup exceptions, hardened
  runtime. The service gets compressed JSON bytes and returns pixels; it never sees a path.
- Connection: `NSXPCConnection(serviceName: "org.klaipher.Nanogram.Decoder")`. The interface carries only `Data`,
  `String` and numbers (no object graphs to deserialize). launchd runs one service process for the app; each
  connection has its own session table, which the service drops when the client hangs up. Session ids are random,
  and the client tags every session with its connection generation, so after a crash and relaunch a stale session
  can never address another animation.
- Wire: `openAnimation(Data)` returns a session, frame range and fps; `renderFrame(session, index, w, h,
  bytesPerRow)` returns `Data`; `setColor` and `closeAnimation` are one way.
- Limits, enforced by the client before sending and again by the service: animation 8 MB (the app's own unzip cap),
  frame sides 4096, frame 64 MB, 512 sessions per connection, image 8 MB, source image 36 Mpixel. The client treats
  the service as hostile: every reply (frame size, image geometry) is checked in overflow-safe arithmetic before use.
- Image decoding (still WebP) uses ImageIO inside the service, with the pixel-count check made from the header
  before any decode.

## Failure handling

The rule is the one BlastDoor follows: content that made the isolated decoder fail is never handed to an in-process
decoder, because a failed exploit attempt usually looks like a crash, and retrying it in the app would give the
attacker a second try in the process that holds the session keys.

- Every call has a timeout (open 3 s, render 1.5 s, image 3 s).
- A lost connection, a timeout or a malformed reply is a service failure. The connection is dropped, so the next
  call starts a fresh service instance, and the same content is retried once there (an innocent sticker that was on
  screen when another one crashed the service, or a jetsam kill, recovers this way, colours replayed).
- A second consecutive failure on the same content quarantines it (SHA-256 of the bytes, last 512 kept): the
  animation renders transparent frames, a still image is refused, and the bytes are not sent again in this run.
- Three failures in a row (counted once per service instance, so one crash with many stickers on screen is one
  failure) switch XPC off for 60 s. During that time new stickers are not decoded at all if the service had worked
  before in this run; only if it never started (missing or unlaunchable service) does the app decode in process, as it
  did before isolation. After the cool-down XPC is tried again.
- Content rejections (too large, unparsable, too many sessions) are not service failures: the sticker is not shown
  and the breaker is untouched.
- A frame larger than the frame limit renders transparent for that frame only.

The owner may prefer availability over this policy (fall back in process on a crash); that is a one-line change in
`IsolatedDecoderBackend`, but it removes most of the protection.

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
tlottie links into the extension as they do into the app. The iOS memory ceiling for extensions is low,
so frame size limits there should be tighter and the service should render at most one frame at a time.
Owner steps for iOS: none known for the capability, but the extension needs its own bundle identifier and
provisioning profile in the developer portal.
