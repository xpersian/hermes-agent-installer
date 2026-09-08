# Hermes Agent Installer

Production-oriented Docker installer for [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent), designed to behave safely on low-resource VPS systems while keeping the official Hermes runtime intact.

## فارسی

این پروژه یک Installer مرحله‌ای برای Hermes Agent است که از ایمیج رسمی `nousresearch/hermes-agent` استفاده می‌کند و برای VPSهای ضعیف طراحی شده است.

### حداقل منابع رسمی Hermes

- Core بدون Browser: حداقل **1 GiB RAM**
- Browser automation: حداقل **2 GiB RAM**
- CPU: حداقل **1 core**
- فضای داده: حداقل **500 MiB**

اگر RAM کمتر از حداقل رسمی باشد، Installer آن را پنهان نمی‌کند و نصب را به‌عنوان unsupported/experimental اعلام می‌کند.

### ویژگی‌ها

- استفاده از Docker image رسمی Hermes
- تشخیص RAM / RAM available / Swap / CPU / Disk
- نصب Docker و Compose فقط در صورت نیاز
- نصب مرحله‌ای Core و قابلیت‌های اختیاری
- Backup قبل از Update
- Rollback image + data backup
- Health check
- Uninstall امن
- اجرای مجدد idempotent تا حد امکان
- بدون محدودیت مصنوعی CPU/RAM برای Docker
- عدم تغییر Apache و پورت‌های 80/443
- عدم دست‌کاری 9Router، 3x-ui، Mirza، MasterDNSVPN یا سرویس‌های نامرتبط
- Dashboard رسمی Hermes به‌صورت اختیاری
- حفظ Browser/Playwright داخل image رسمی؛ بدون ساخت image سفارشی
- پشتیبانی از Providerهای مختلف Hermes، از جمله endpointهای OpenAI-compatible مانند 9Router

## English

This project provides a staged Docker installer for Hermes Agent using the official `nousresearch/hermes-agent` image.

It checks system resources before optional stages, preserves persistent Hermes state, provides backup/update/rollback/health/uninstall helpers, and avoids modifying unrelated services.

The installer does not bind or modify ports 80/443 and does not impose artificial Docker CPU/RAM limits.

## Install

> The public one-line installer will be published after the first stable release has been tested.

```bash
curl -fsSL https://raw.githubusercontent.com/xpersian/hermes-agent-installer/main/install-hermes.sh | bash
```

For a pinned release, use a version tag instead of `main` once releases are available.

## Deployment location

The installer creates:

```text
/opt/hermes-agent/
├── compose/
├── data/
├── backups/
├── scripts/
├── .env
└── VERSION
```

## Management

```bash
/opt/hermes-agent/scripts/healthcheck.sh
/opt/hermes-agent/scripts/backup.sh
/opt/hermes-agent/scripts/update.sh
/opt/hermes-agent/scripts/rollback.sh
/opt/hermes-agent/scripts/uninstall.sh
```

## Security

Never commit API keys, Telegram bot tokens, OAuth secrets, passwords, private keys, or `.env` files.

The dashboard should not be exposed publicly without an authentication provider. Hermes recommends OAuth/OIDC for Internet-facing deployments; Basic Auth is intended for trusted networks/VPNs rather than direct public exposure.

See [SECURITY.md](SECURITY.md).

## Upstream

Hermes Agent is developed by Nous Research. This installer is an independent deployment helper and is not an official Nous Research project.

- Upstream project: https://github.com/NousResearch/hermes-agent
- Upstream Docker documentation: https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/docker.md

## License

MIT. See [LICENSE](LICENSE).
