# Media HTTP contract

Beamly publishes a selected file or a generated HLS directory on an ephemeral TCP port, using the Mac's primary LAN IPv4 address. This lets an AirPlay receiver fetch the stream. If no LAN IPv4 is available, playback can still use the loopback address locally.

Every URL has `/launch-token/publication-id/filename`, with independent random UUIDs. Treat the whole URL as temporary access to the movie. Only explicitly published files are reachable. Removing playback publications closes their active requests; stopping the server invalidates its launch token. There is no upload, directory listing or administration endpoint.

| Request | Response |
| --- | --- |
| `GET` selected file / HLS playlist / segment | `200`, MIME type, exact `Content-Length`, `Accept-Ranges: bytes` |
| `HEAD` | Same headers as GET, without a body |
| Single `Range: bytes=first-last`, `first-`, or `-suffix` | `206`, exact `Content-Range` and selected bytes |
| Malformed / multiple / unsatisfiable range | `416`, `Content-Range: bytes */size`, empty body |
| Unknown capability or filename, traversal, symlink, hidden path, subdirectory, nonmedia file | `404`, empty body |
| Unsupported method | `405`, `Allow: GET, HEAD`, empty body |
| Malformed request / headers | `400`, empty body |
| Headers above 16 KiB | `431`, empty body |

Connections close after one response. File reads use at most 256 KiB at a time and wait for each network send before reading the next chunk. Clients that make no progress for 15 seconds are closed. Generated directory publications expose only root-level `.m3u8`, `.ts`, `.m4s`, `.mp4`, `.m4v`, `.mov`, `.vtt` and `.aac` regular files. The transcoder's `.inputs` directory and diagnostics are never served.

`MediaHTTPServerTests` exercises the actual listener via loopback URLSession requests: full files larger than one chunk, HEAD, explicit/open/suffix ranges, range failures, capability revocation, HLS MIME, confinement (including percent-encoded traversal), symlinks and empty files. These checks establish the local HTTP contract; they do not establish successful playback on physical Apple TV hardware.
