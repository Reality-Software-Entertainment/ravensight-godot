# Held combined release, October 17, 2026

Public-build support and typed events have been combined locally. This record
is verification evidence, not a publication or deployment record.

Validated: 404 checks in 66 Godot tests.

The merge preserves public-key consent and inert-without-key behavior,
stable event IDs, typed event helpers and opt-in performance sampling.
JavaScript now defers performance listeners until consent; Android health
summaries carry the same deduplication IDs as other events.

Physical-device and live-service validation is not implied by these checks.
Publishing, tags, marketplace submission and deployments remain held pending
owner approval. Older README test counts describe their earlier branch runs;
this file records the combined candidate.

Remote config wave: Godot headless behavior suite passed (see local godot-config-full.log), including scoped cache, strict getters, ETags, labels, consent and stale identity responses. Parse check passed. Version 0.3.1 remains held, not pushed or tagged.

Config identifier compatibility audit: 434 checks in 69 headless Godot tests passed. Tests require access to their user-data fixtures.
Config property keys reject constructor/prototype, including nested JSON properties.
Experiment keys and variant labels may use those words as string values, matching
the server contract. Regression coverage distinguishes those cases. Publishing remains held.

Screenshot Player Reports: 444 checks in 71 headless tests passed; all three GDScripts parse successfully. Includes upload/finalize, failure retry identity, credential-free multipart and stale-session rejection. No live storage provider or physical-device screenshot run was performed. Existing held 0.3.1 candidate now includes this feature; no tag, push or publication occurred.
