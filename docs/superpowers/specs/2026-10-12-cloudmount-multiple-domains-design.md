# CloudMount multiple read-only macOS domains

## Intent and scope

Provide three separate Finder Cloud Storage locations for three configured
rclone selectors. The forcing setup contains two direct OneDrive Personal
selectors and a crypt wrapper over one of them; a combine selector is their
existing aggregate, not an additional mount. Selection is local acceptance
configuration, never committed account data. Existing remote content may only
be listed, stated, and read. No mutations, offline queues, polling, partial
hydration, public CLI design, or SMB write work are included.

Starting point: `4096935d48dff3312929f88f56d028cdd2e39ad8`. Retain macOS 13.0,
universal Agent, sandboxed Provider, unsandboxed App/Agent, mutually authenticated
separate CONTROL and DATA services, Agent-only Go runtime and selector/path
resolution, opaque item UUIDs, FD-only hydration, backend/all and direct fs.Fs.

## Approach

The existing Agent mapping, SQLite primary keys, discovery gates and Provider
instances already carry arbitrary domains. Change the App's fixed-domain
lifecycle, not the backend/data-plane architecture. Compared with a new domain
database or one helper per mount, this preserves one authoritative registry for
display names (NSFileProviderManager) and one existing Agent mapping store.

Generate canonical `org.rclone.cloudmount.domain.<lowercase UUID>` identifiers.
Do not derive them from selectors, names, paths, or account identifiers.
The development App interface becomes `domain-add <display-name> <remote:path>`,
`domain-list`, `domain-remove <domain-id>`, and `domain-path <domain-id>`.
The last queries Apple's user-visible URL from the installed containing App,
without guessing a filesystem location. Every add allocates a fresh UUID;
print it before side effects so a failed/interrupted attempt can be removed.
Do not accept caller-selected add IDs, which would need an atomic cross-process
reservation to prevent concurrent adds from remapping the same ID. Retain only
removal compatibility for existing owned-namespace IDs; no fixed test ID drives
any new registration or normal Provider request.

## Lifecycle and persistence

A small App lifecycle helper takes registry and control operations as closures
so ordering/failure behavior can be tested without registering system domains.
Validate ID, display name and nonempty selector before side effects. Refuse
existing IDs without changing either authority. Configure the Agent, then add
the File Provider domain. A failed configuration is rolled back for this fresh
ID. A failed registration is inspected for partial success: remove an observed
domain before removing its Agent mapping. If registry state/removal cannot be
established, retain mapping and return a safe error naming only the opaque ID.

Removal deregisters this exact domain before purging its Agent mapping/catalog.
If deregistration fails, retain the mapping. If Agent cleanup fails afterward,
report incomplete cleanup so the same explicit ID can be retried. Unknown IDs
fail without affecting other mounts. Names must be nonempty, bounded and free
of separators/control characters; Unicode and spaces are supported.

domains.json v1 already persists an arbitrary ID-to-selector dictionary. SQLite
v1 already scopes bindings/items by domain. Neither schema needs migration.
NSFileProviderManager persists IDs/display names; don't duplicate these in JSON.
All existing corruption/newer-version rejection and per-domain generations stay.

## Trust and isolation

Apple's replicated-extension SDK explicitly permits multiple domain instances
in one process. Public NSXPCConnection peer properties describe process, user
and audit session, not the extension instance. No supported domain-instance
attestation was found in the reviewed public interfaces. Use the authorized
provider-wide principal: this user's signed extension is trusted to service all
their CloudMount mappings. Do not claim cryptographic per-domain caller isolation
or invent shared-container secrets. Keep app-only CONTROL and provider-only DATA
requirements and mutual Agent authentication. Explicitly restrict accepted
connections to the Agent's effective user as well.

Domain plus item ID remains the lookup key, even if the same UUID representation
is present in multiple domain catalogs. A's removal/remap/generation cannot affect
B/C. Backend I/O stays outside the catalog lock; independent domain observations
remain concurrent. Test actual extension enumeration/fetch requests using multiple
domain contexts through a properly signed transient harness.

## Backend identity and future work

Characterize OneDrive ID(), directory IDs, normalized drive/item scoping,
delta/ChangeNotify and write preconditions from current source and official Graph
documentation. Observe repeat List/Stat identity without emitting backend IDs.
The crypt wrapper's identity behavior also needs characterization. Retain current
same-path UUID reconciliation; do not infer generic rename/move continuity from
an ID method name or introduce untested cross-directory reconciliation. External
rename/move runtime proof requires an authorized write fixture and is deferred.
Record exactly where source/API evidence supports future stable-ID reconciliation.

## Acceptance and handoff

Native tests cover generation/validation, Unicode display names, three mappings,
reopen, remap/removal isolation, identical UUIDs across domains, stale completion,
independent discovery, lifecycle partial failures, and Provider root contexts.
Existing seven suites and full-only conformance remain green. Go tests/race/full
suite and serial full build use the host's established Xcode SDK workaround.
Signed Debug and Release compile retain target 13.0 and both Agent architectures.

Register three real read-only mounts; verify Finder locations, root/nested
enumeration, stable IDs, parent IDs and no eager hydration. For suitable small
files, compare an ordinary-rclone local baseline with mounted bytes while logging
callback activity. Exercise Agent restart, practical Provider restart, remove/readd
one domain, domain-scoped negative requests, role/foreign XPC rejection and useful
concurrency. Do not disconnect unrelated user networking just to manufacture a
network fault; use an isolated safe test or explicitly report it untested.

Leave working mounts registered. Remove diagnostics and private local comparisons.
Preserve all remote content. Review, commit and push only origin/cloudmount-macos
after acceptance. No upstream PR. The prior SMB no-clobber finding remains deferred:
existing generic move can overwrite an external destination after an absence check.
