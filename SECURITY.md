# Security

Livery writes into other applications' bundles, and part of it runs as root. If you find a way to make it write
somewhere it should not, accept a caller it should refuse, or fetch something it should not fetch, please report it
privately.

## Reporting

Use GitHub's private vulnerability reporting on this repository (Security > Report a vulnerability). Please do not
open a public issue for anything exploitable.

Include the macOS version, how Livery was built and signed, and the steps that reproduce the problem. You will get a
reply within a week.

## What is in scope

- `LiveryHelper`, the root LaunchDaemon: its XPC gate, path validation, audit session handling and the two operations
  it exposes.
- `Paths` and `ManifestStore`: anything derived from another app's `Info.plist` that ends up in a file name or path.
- The catalog client: redirects, hosts, response size and image decoding.
- The install scripts.

## Out of scope

- Icons served by the third-party catalogs. Livery does not vet artwork; it only normalises its shape.
- Behaviour on an ad-hoc signed build, where the helper is inert by design.
