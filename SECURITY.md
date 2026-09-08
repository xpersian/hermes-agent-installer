# Security Policy

## Reporting a vulnerability

Please do not disclose security vulnerabilities in a public issue.

Open a private security report through GitHub's repository security features when available, or contact the repository owner privately.

## Scope

Security reports are especially welcome for:

- command injection or unsafe shell handling
- secret/API-key leakage
- unsafe Docker configuration
- unintended modification of unrelated host services
- unsafe dashboard exposure
- backup or rollback data exposure

## Secrets

Never commit `.env` files, API keys, Telegram bot tokens, OAuth secrets, passwords, private keys, or production backups to this repository.
