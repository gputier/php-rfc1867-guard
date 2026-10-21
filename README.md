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

The guard declares an optional dependency on `session`, so it loads after session and clears the pointer at module init. It checks the pointer again on every request, at RINIT, in case something reinstalled a hook. No ini setting, `.user.ini`, `.htaccess` or user code can bring the handler back.

Uploads, `$_FILES`, `$_POST` and sessions keep working. Only the server-side `session.upload_progress` feature stops. Browsers have reported upload progress natively for years.

## Install

Tested so far on PHP 7.4 and 8.3, CLI and php-fpm: without the guard the upload-progress entry appears in the session, with the guard it does not, and the uploaded file arrives intact. The source targets PHP 5.4 to 8.5; the other versions are being built and tested now, and this line will list them.

```sh
cd src
phpize
./configure --enable-rfc1867_guard
make
make install
```

The `--enable-rfc1867_guard` flag is required. Without it, `configure` leaves the extension out, and `make` builds nothing.

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

Prebuilt binaries, a universal installer and CI builds with provenance attestations: coming soon.

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

The output must show `bool(true)` for `active`.

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
