/*
 * rfc1867_guard: detaches PHP's multipart upload hook so that the session
 * upload-progress handler (php_session_rfc1867_callback) never runs.
 *
 * Inspired by Hosted Power's php_uploadprogress_guard (MIT).
 *
 * The multipart decoder (main/rfc1867.c) only calls its hook while the global
 * pointer php_rfc1867_callback is non-NULL. Keeping it NULL removes the whole
 * code path: session.upload_progress stops working, uploads keep working.
 *
 * The session hook is removed at module init (MINIT). The session extension
 * installs it in its own MINIT, and ZEND_MOD_OPTIONAL("session") makes it start
 * before this module: that ordering is what protects the session handler.
 *
 * RINIT clears the pointer again at the start of each request, which catches a
 * hook installed by another extension that starts after us. It runs after the
 * multipart body of the current request has been parsed (php_hash_environment
 * precedes zend_activate_modules), so it does not protect the first request
 * handled by a process against such a hook. It does not replace the MINIT order.
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "php.h"
#include "ext/standard/info.h"
#include "main/rfc1867.h"

#define RFC1867_GUARD_VERSION "1.0.1"

static int guard_detached_at_startup = 0;
static long guard_foreign_hooks_cleared = 0;

ZEND_BEGIN_ARG_INFO_EX(arginfo_rfc1867_guard_status, 0, 0, 0)
ZEND_END_ARG_INFO()

/* The session extension must start first so that we clear its hook, not the reverse. */
static const zend_module_dep rfc1867_guard_deps[] = {
	ZEND_MOD_OPTIONAL("session")
	ZEND_MOD_END
};

PHP_MINIT_FUNCTION(rfc1867_guard)
{
	(void) type;
	(void) module_number;

	if (php_rfc1867_callback != NULL) {
		php_rfc1867_callback = NULL;
		guard_detached_at_startup = 1;
	}

	return SUCCESS;
}

PHP_RINIT_FUNCTION(rfc1867_guard)
{
	(void) type;
	(void) module_number;

	if (php_rfc1867_callback != NULL) {
		php_rfc1867_callback = NULL;
		guard_foreign_hooks_cleared++;
	}

	return SUCCESS;
}

PHP_MINFO_FUNCTION(rfc1867_guard)
{
	char cleared[32];

	snprintf(cleared, sizeof(cleared), "%ld", guard_foreign_hooks_cleared);

	php_info_print_table_start();
	php_info_print_table_row(2, "rfc1867_guard", "enabled");
	php_info_print_table_row(2, "Version", RFC1867_GUARD_VERSION);
	php_info_print_table_row(2, "Multipart hook detached", php_rfc1867_callback == NULL ? "yes" : "no");
	php_info_print_table_row(2, "Detached at startup", guard_detached_at_startup ? "yes" : "no");
	php_info_print_table_row(2, "Foreign hooks cleared at request start", cleared);
	php_info_print_table_end();
}

PHP_FUNCTION(rfc1867_guard_status)
{
	if (zend_parse_parameters_none() == FAILURE) {
		return;
	}

	array_init(return_value);
	add_assoc_bool(return_value, "active", php_rfc1867_callback == NULL);
	add_assoc_bool(return_value, "detached_at_startup", guard_detached_at_startup);
	add_assoc_long(return_value, "foreign_hooks_cleared", guard_foreign_hooks_cleared);
#if PHP_VERSION_ID < 70000
	add_assoc_string(return_value, "version", RFC1867_GUARD_VERSION, 1);
#else
	add_assoc_string(return_value, "version", RFC1867_GUARD_VERSION);
#endif
}

static const zend_function_entry rfc1867_guard_functions[] = {
	PHP_FE(rfc1867_guard_status, arginfo_rfc1867_guard_status)
	PHP_FE_END
};

zend_module_entry rfc1867_guard_module_entry = {
	STANDARD_MODULE_HEADER_EX, NULL, rfc1867_guard_deps,
	"rfc1867_guard",
	rfc1867_guard_functions,
	PHP_MINIT(rfc1867_guard),
	NULL,
	PHP_RINIT(rfc1867_guard),
	NULL,
	PHP_MINFO(rfc1867_guard),
	RFC1867_GUARD_VERSION,
	STANDARD_MODULE_PROPERTIES
};

#ifdef COMPILE_DL_RFC1867_GUARD
ZEND_GET_MODULE(rfc1867_guard)
#endif
