# infra/bootstrap

One-time setup: S3 state backend (versioned, SSE-S3 encrypted, public access blocked) and native
state locking (OpenTofu >= 1.10 — no separate DynamoDB table). See
`docs/terraform-gate1-design.md` §7.

Applied once, with local state, outside the remote backend it creates (avoids the
bootstrap-your-own-backend chicken-and-egg problem). Never referenced as a managed resource from
`environments/lab` — only as backend configuration — so a workload `destroy` cannot touch it.

Owner: Platform owner for Cycle 1 (Meron) runs this first; it does not need to be re-applied by
whoever holds the Platform role in later cycles unless the backend itself changes.
