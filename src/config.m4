PHP_ARG_ENABLE([rfc1867_guard],
  [whether to enable rfc1867_guard],
  [AS_HELP_STRING([--enable-rfc1867_guard],
    [Enable rfc1867_guard (detaches the multipart upload hook)])])

if test "$PHP_RFC1867_GUARD" != "no"; then
  PHP_NEW_EXTENSION(rfc1867_guard, rfc1867_guard.c, $ext_shared)
fi
