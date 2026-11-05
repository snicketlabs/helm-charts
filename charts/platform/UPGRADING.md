# Upgrade Notes

`platform` 1.0.0 is the first public release. There are no version-specific
upgrade notes yet.

## Coming from the `adsignal-match` chart?

There is no upgrade path, and this is deliberate. `platform` is a fork of
`adsignal-match`, not a rename of it: the chart name, the registry, the
namespace and most in-cluster resource names all changed, so Helm has no way to
reconcile one against the other.

Deploy `platform` into a fresh namespace. The `adsignal-match` chart continues
to be published from `ad-signalio/helm-match` for environments already running
it.
