# php-rfc1867-guard

For PHP 5.4 to 8.1, which get no official fix, this extension is the stopgap. On PHP 8.2 to 8.5, it is a second layer while you wait for the official package, and it stays in place next to it afterwards.

## The vulnerability

CVE-2026-109618 and CVE-2026-109619, called "php2shell", are two bugs with a CVSS v4 score of 9.2 each. They allow unauthenticated remote code execution, according to watchTowr. Details leaked before the fix, and exploit code is circulating.

The vulnerable code is `php_session_rfc1867_callback` in `ext/session/session.c`, the handler for session upload progress. It runs on every `multipart/form-data` POST, before any application code.

The usual stopgap is weak. `session.upload_progress.enabled` is `PHP_INI_PERDIR`, so any site can switch it back on from `.user.ini` or `.htaccess`. The check also happens inside the vulnerable function, not in front of it.

## Who needs this

If you run PHP 5.4 to 8.1, there is no official fix from php.net for your branch. Some distributions have announced backports for some end-of-life branches, without dates. Check what your vendor ships before you rely on that.

If you run PHP 8.2 to 8.5, the official fix lands on 21 October 2026 at 14:00 UTC. Install this extension now, and keep it after the official package is in place.

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

The guard only helps as far as the bugs live in that handler, which is where researchers located them before the advisory. It does not cover a possible second bug inside the multipart parser itself. That bug is unconfirmed.

It does not undo a compromise that happened before the guard was installed. It does not replace the official patch, so install both.

PHP 5.1 to 5.3 do not have the upload-progress feature, so they are out of scope. If the PECL `uploadprogress` extension is loaded, it loses its function.

## Remove

Delete the ini file and the `.so`, then reload. `php-config --extension-dir` shows the directory that holds the `.so`.

## Credits and license

The idea comes from Hosted Power's php_uploadprogress_guard, MIT licensed.

This project is MIT licensed. Copyright (c) 2026 gputier. See [LICENSE](LICENSE).
