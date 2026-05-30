# Security Policy

## Supported versions

Security fixes apply to the latest code on `main`. Older release tags are not maintained unless noted.

## Reporting a vulnerability

**Do not open public issues for undisclosed security bugs.**

Use a [private security advisory](https://github.com/Rahuletto/moviebox/security/advisories/new) or contact the maintainer via [GitHub](https://github.com/Rahuletto).

Include description, impact, reproduction steps, and affected component (app / backend).

## Scope

In scope:

- Authentication bypass on `/api/*`  
- SSRF or abuse on `/img` or subtitle routes  
- Secret leakage in the repository  
- RCE in the macOS app from network input  

Out of scope (generally):

- Torrent copyright or indexer uptime  
- Abuse of **your** self-hosted Worker with a token you shared  
- Issues requiring physical access to an unlocked Mac  

## Secrets

- `APP_SECRET` / app token — rotate if exposed  
- `Backend/.dev.vars` — never commit  
- `DevelopmentSecrets.swift` — gitignored  

## Self-hosted operators

If you expose a Worker publicly, use a strong `APP_SECRET`, rate limits, and do not publish tokens. The stock app stores tokens in SwiftData (plaintext) — see threat notes in repo discussions/issues if you need Keychain hardening.
