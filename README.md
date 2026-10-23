# php-rfc1867-guard

This extension closes one route of CVE-2026-109619, the session upload-progress handler. It does not fix either CVE. The only complete fix is a PHP build that carries the official patch: PHP 8.2.35, 8.3.36, 8.4.27, 8.5.12 or later, or a vendor backport (Sury, Remi, TuxCare, cPanel EA4, CloudLinux alt-php, distributions). Install that first. Use the guard as a partial stopgap where no patched build exists, and as a second layer next to the patched build.

## The vulnerability

CVE-2026-109618 and CVE-2026-109619, called "php2shell", are two bugs with a CVSS v4 score of 9.2 each. They allow unauthenticated remote code execution, according to watchTowr. Details leaked before the fix, and exploit code is circulating.

PHP's advisories describe two bugs. CVE-2026-109618 ([GHSA-w8hw-w9fx-j79w](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w)) is memory corruption when PHP runs out of memory while request memory is not fully initialized, reachable through the multipart parser itself during request startup. CVE-2026-109619 ([GHSA-6wmf-4rv5-p3rp](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)) is stale request state reused by the next request handled by the same worker. Its confirmed consumers are session upload progress (`php_session_rfc1867_callback` in `ext/session/session.c`, which runs on every `multipart/form-data` POST before any application code) and INI diagnostics raised before request initialization, for example from mod_php `php_value` in `.htaccess` or FPM `PHP_VALUE`.

The usual stopgap is weak. `session.upload_progress.enabled` is `PHP_INI_PERDIR`, so any site can switch it back on from `.user.ini` or `.htaccess`. The check also happens inside the vulnerable function, not in front of it.

## Who needs this

If you run PHP 8.2 to 8.5, update to 8.2.35, 8.3.36, 8.4.27, 8.5.12 or later. That closes both CVEs. The guard can stay next to it as a second layer.

If you run an end-of-life branch, check your vendor first: several ship patched builds of 7.4 to 8.1, some of older branches too. Read the package changelog for the CVE, the upstream version number does not change with a backport. Where no patched build exists, the guard closes the upload-progress route only. CVE-2026-109618 and the INI-diagnostic route of CVE-2026-109619 stay open, and the advisories list the configuration measures that reduce them. Hosted Power's [php_uploadprogress_guard](https://github.com/HOSTED-POWER/php_uploadprogress_guard) 3.x carries PHP's fixed parser and the request-state cleanup and covers more than this extension; check which branches it supports.

## What we run in production

On 22 October 2026, between 19:35 and 20:05 Paris time, we replaced this extension with php_uploadprogress_guard 3.1.0 from Hosted Power on nine hosts that had no patched PHP available: branches 5.6 to 7.4, under mod_php, PHP-FPM and CGI. We compiled the module ourselves from Hosted Power's source at commit 14d68597191be07151f041e3636fde63322fd2bb, with `phpize` in the official image of each branch. We never installed their binaries.

Before the swap, we tested the module in containers on 5.6, 7.0, 7.1, 7.2, 7.3 and 7.4, with the built-in server, php-fpm and mod_php. The three memory-exhaustion strategies of CVE-2026-109618 (a huge field, huge headers, nested empty files) end in a 413 with the module, and in "Allowed memory size exhausted" without it. A 5 MB upload stays identical byte for byte. A form with 15,000 fields produces the same `$_POST`. Upload progress stays cut, even when `.user.ini`, `.htaccess` or `PHP_VALUE` tries to switch it back on.

After the swap, the pages of each host's sites return the same HTTP code and the same content as before. The one exception is a webmail login page, which changes on every call because of its token. A multipart test upload passes unchanged on the canary host.

On these hosts we removed the old `rfc1867_guard.ini` in the same reload, so the two modules are never loaded together. If rfc1867_guard loads first, Hosted Power's module no longer locks `session.upload_progress.enabled`. The progress stays off, but the setting is no longer locked.

On a branch without a patch, Hosted Power's module covers more than this extension does: the fixed parser, the memory margin and the request-state cleanup. This extension closes only the upload-progress route.

## How it works

The multipart decoder (`main/rfc1867.c`) calls its hook only through the global pointer `php_rfc1867_callback`. All seven call sites check that the pointer is not NULL. The session extension installs its handler there at startup.

The guard declares an optional dependency on `session`, so it loads after session and clears the pointer at module init (MINIT). That startup order is what protects the session handler. No ini setting, `.user.ini`, `.htaccess` or user code can bring the handler back.

At the start of each request (RINIT) the guard clears the pointer again and counts it, in case another extension installed a hook after the guard started. That check runs after the multipart body of the current request has been parsed, so it does not cover the first request handled by a process against such a hook. It does not replace the MINIT order.

Uploads, `$_FILES`, `$_POST` and sessions keep working. Only the server-side `session.upload_progress` feature stops. Browsers have reported upload progress natively for years.

## Install

Built and tested on PHP 5.4, 5.5, 5.6, 7.0 to 7.4 and 8.0 to 8.5 (NTS, x86_64): without the guard the upload-progress entry appears in the session, with the guard it does not, the uploaded file arrives intact and the session keeps working. All 14 versions were tested with the CLI, and 7.4 and 8.3 also behind php-fpm with real FastCGI requests.

### With the installer

`install.sh` finds every PHP installation on the machine (distribution packages, Sury, Remi, cPanel EA4, alt-php, DirectAdmin, Plesk, and custom builds through `php-config`), checks that the binary matches each one, installs it, reloads the service and proves the guard is active in the running processes.

Prebuilt binaries are attached to each [release](https://github.com/gputier/php-rfc1867-guard/releases), built by GitHub Actions with a provenance attestation. Put them in `dist/`, or let the installer compile with `phpize` (needs the PHP development package):

```sh
git clone https://github.com/gputier/php-rfc1867-guard.git
cd php-rfc1867-guard
mkdir -p dist && cd dist
gh release download --repo gputier/php-rfc1867-guard   # or download the assets by hand
cd ..
sudo ./install.sh --dry-run   # show what would change
sudo ./install.sh             # or: sudo ./install.sh --build
sudo ./install.sh --check     # exit 0 when every installation is guarded
```

To check where a binary came from: `gh attestation verify dist/rfc1867_guard-8.3-nts-x86_64.so --repo gputier/php-rfc1867-guard`.

`--uninstall` removes everything the installer added. `--only <php binary or prefix>` limits it to one installation.

### By hand

```sh
cd src
phpize
./configure --enable-rfc1867_guard
make
make install
```

`phpize` always builds the extension as a shared object, so the `.so` is produced even without `--enable-rfc1867_guard`. The flag stays in the commands for the usual `config.m4` convention.

Then add `extension=rfc1867_guard.so` to the ini scan directory of every SAPI you run (fpm, apache2, cgi, cli), and restart. A reload is enough for php-fpm. mod_php needs a restart.

Where that ini file goes depends on the platform:

| Platform | Directory |
| --- | --- |
| Debian / Ubuntu | `/etc/php/X.Y/mods-available/`, then `phpenmod -v X.Y -s ALL rfc1867_guard` |
| RHEL / Remi | `/etc/php.d/` or `/etc/opt/remi/phpXY/php.d/` |
| cPanel EA4 | `/opt/cpanel/ea-phpXY/root/etc/php.d/` |
| CloudLinux alt-php (CageFS) | `/opt/alt/phpXY/etc/php.d.all/` |
| DirectAdmin | `/usr/local/phpXY/lib/php.conf.d/` |
| Plesk | `/opt/plesk/php/X.Y/etc/php.d/` |

The official Docker images do not use `docker-php-ext-install` for this extension. Copy the source into your Dockerfile and run `phpize` there.

## Verify

Check each PHP process, not the config files. `session.upload_progress.enabled` stays On in phpinfo after the guard is active, so it tells you nothing.

From the command line:

```sh
php --ri rfc1867_guard
```

The row "Multipart hook detached" must read `yes`.

From a web request, run a script containing:

```php
<?php
var_dump(rfc1867_guard_status());
```

The output must show `bool(true)` for `active`. The array has four keys, all read live:

- `active` (bool): the multipart hook is NULL right now.
- `detached_at_startup` (bool): the hook was set when the module started and the guard removed it. True when the session extension is loaded.
- `foreign_hooks_cleared` (int): hooks found and cleared at the start of a request since the process started. It stays at 0 unless another extension installs a hook after the guard.
- `version` (string): the guard version.

`php --ri rfc1867_guard` and `phpinfo()` show the same values.

To confirm that a running php-fpm master has the module mapped, check its memory maps:

```sh
grep rfc1867_guard /proc/<php-fpm master pid>/maps
```

## Limits

The guard detaches the session upload-progress handler and nothing else. PHP's advisories confirmed routes that it does not touch: out-of-memory corruption in the multipart parser itself (CVE-2026-109618), and stale request state consumed by INI diagnostics before request initialization (CVE-2026-109619). On a PHP without the official patch, both stay open with the guard installed.

It does not undo a compromise that happened before the guard was installed. It does not replace the official patch, so install both.

PHP 5.1 to 5.3 do not have the upload-progress feature, so they are out of scope. If the PECL `uploadprogress` extension is loaded, it loses its function.

## Remove

Delete the ini file and the `.so`, then reload. `php-config --extension-dir` shows the directory that holds the `.so`.

## Credits and license

The idea comes from Hosted Power's php_uploadprogress_guard, MIT licensed.

This project is MIT licensed. Copyright (c) 2026 gputier. See [LICENSE](LICENSE).
