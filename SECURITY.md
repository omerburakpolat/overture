# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately via GitHub's
[Report a vulnerability](https://github.com/omerburakpolat/overture/security/advisories/new)
form, or email **omerburakpolat@gmail.com**.

Please include the Overture version (menu → About), your macOS version, and
steps to reproduce. You will get an acknowledgement within 72 hours and an
assessment within 7 days. Fixes ship in the next patch release; credit is given
in the release notes unless you ask otherwise.

## Supported versions

Overture is pre-1.0. Only the **latest release** receives security fixes.

## Threat model

Overture is a local, unsandboxed macOS app that supervises developer CLIs. That
shape is deliberate, and it has consequences worth stating plainly.

**What Overture does**

- Spawns your own installed `claude`, `git`, and `gh` binaries as child
  processes, in project directories you choose.
- Runs with **Hardened Runtime** enabled and **no App Sandbox** — sandboxing is
  incompatible with launching arbitrary user toolchains in arbitrary
  directories. See [`App/Overture.entitlements`](App/Overture.entitlements).
- Ships signed with a Developer ID certificate and notarized by Apple.

**What Overture does not do**

- It never reads, stores, transmits, or proxies your Claude credentials. It
  drives your existing local CLI login. See [NOTICE](NOTICE).
- It never writes to `~/.claude` — Claude Code owns that store.
- It has no telemetry, no analytics, and no backend. The only network calls are
  Sparkle's signed update check and, if you opt in, the Vercel and GitHub APIs
  using tokens you supply.

**Risks you are accepting**

- **Agents execute code.** Cards are Claude Code sessions with tool access. An
  agent can run commands and modify files in its working directory. Worktree
  mode isolates each card to its own branch and directory, which limits blast
  radius but is not a security boundary.
- **Prompt injection is real.** An agent that reads a malicious file, issue, or
  web page may be steered by its contents. Review diffs before merging, exactly
  as you would a pull request from a stranger.
- **Dev servers run your project's code.** The preview pane executes the command
  configured for the project, bound to `localhost`.

## Update integrity

Updates are delivered by [Sparkle](https://sparkle-project.org) over HTTPS and
verified with EdDSA signatures. The public key is pinned in the app bundle
(`SUPublicEDKey`); the private key exists only as a GitHub Actions secret. An
update that is not signed by that key is rejected.

Release DMGs are built by the
[release workflow](.github/workflows/release.yml) from a tagged commit, signed
with Developer ID, and notarized. Verify any download yourself:

```bash
spctl -a -vvv -t open --context context:primary-signature Overture-*.dmg
```
