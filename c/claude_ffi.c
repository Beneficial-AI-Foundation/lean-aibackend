/* libcurl binding for the Anthropic Messages API with a persistent easy handle.
   One client owns one CURL handle. libcurl keeps the TLS connection open in that
   handle's connection cache, so later requests skip the TCP and TLS handshakes.
   A CURL easy handle is not thread safe. Use one client per thread.

   Every transfer uses TLS. The shim checks each precondition at run time and
   returns an IO error on a violation. It checks the result of every libcurl
   call. After each transfer it checks that the transfer used the https scheme
   and that the certificate verification succeeded. */
#include <lean/lean.h>
#include <curl/curl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  CURL *curl;
  struct curl_slist *headers;
  atomic_flag busy; /* set while a transfer runs on the handle */
} client_t;

typedef struct {
  char *data;
  size_t len;
} buf_t;

static lean_external_class *g_client_class = NULL;

/* The state of the one-time initialization: 0 before it, 1 during it, 2 after it. */
static atomic_int g_init_state = 0;

static void client_finalize(void *p) {
  client_t *c = p;
  if (!c) return;
  if (c->curl) curl_easy_cleanup(c->curl);
  /* The first header holds the API key. Overwrite every header before freeing. */
  for (struct curl_slist *s = c->headers; s; s = s->next)
    if (s->data) memset(s->data, 0, strlen(s->data));
  if (c->headers) curl_slist_free_all(c->headers);
  free(c);
}

static void client_foreach(void *p, b_lean_obj_arg f) { (void)p; (void)f; }

static lean_obj_res io_error(const char *msg) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

static size_t on_data(char *ptr, size_t size, size_t nmemb, void *userdata) {
  buf_t *b = userdata;
  size_t n = size * nmemb;
  char *grown = realloc(b->data, b->len + n + 1);
  if (!grown) return 0; /* a short count makes libcurl abort with CURLE_WRITE_ERROR */
  b->data = grown;
  memcpy(b->data + b->len, ptr, n);
  b->len += n;
  b->data[b->len] = '\0';
  return n;
}

/* The key configuration. lakefile.lean defines both macros. Neither is the key. */
#ifndef AIBACKEND_KEY_SERVICE
#define AIBACKEND_KEY_SERVICE "lean-aibackend-anthropic-api-key"
#endif
#ifndef AIBACKEND_KEY_HELPER
#define AIBACKEND_KEY_HELPER ""
#endif

/* Whether the shim checks the availability of TLS in libcurl. lakefile.lean
   defines the macro from `environmentChecks`. */
#ifndef AIBACKEND_ENV_CHECKS
#define AIBACKEND_ENV_CHECKS 1
#endif

/* keyServiceRaw : Unit → String */
LEAN_EXPORT lean_obj_res claude_key_service(lean_obj_arg unit) {
  (void)unit;
  return lean_mk_string(AIBACKEND_KEY_SERVICE);
}

/* keyHelperRaw : Unit → String. A newline separates the command and its arguments. */
LEAN_EXPORT lean_obj_res claude_key_helper(lean_obj_arg unit) {
  (void)unit;
  return lean_mk_string(AIBACKEND_KEY_HELPER);
}

/* Whether a Lean string holds no NUL byte, so that its C view is the whole string. */
static int has_no_nul(b_lean_obj_arg s) {
  return strlen(lean_string_cstr(s)) == lean_string_size(s) - 1;
}

/* Whether the key is nonempty and holds only printable ASCII without a space.
   A carriage return or a line feed would inject a header. */
static int key_is_well_formed(const char *key) {
  if (!*key) return 0;
  for (const unsigned char *p = (const unsigned char *)key; *p; p++)
    if (*p < 0x21 || *p > 0x7e) return 0;
  return 1;
}

/* Whether the URL has the https scheme and a host. The libcurl URL parser
   decides, so a URL such as https://127.0.0.1@example.com has host example.com. */
static int url_is_https(const char *url) {
  CURLU *u = curl_url();
  char *scheme = NULL, *host = NULL;
  int ok = 0;
  if (!u) return 0;
  if (curl_url_set(u, CURLUPART_URL, url, 0) == CURLUE_OK &&
      curl_url_get(u, CURLUPART_SCHEME, &scheme, 0) == CURLUE_OK &&
      curl_url_get(u, CURLUPART_HOST, &host, 0) == CURLUE_OK)
    ok = curl_strequal(scheme, "https") && host[0] != '\0';
  curl_free(scheme);
  curl_free(host);
  curl_url_cleanup(u);
  return ok;
}

/* Sets one option and leaves the constructor with an IO error on a failure. */
#define SETOPT(c, opt, val)                                              \
  do {                                                                   \
    if (curl_easy_setopt((c)->curl, opt, val) != CURLE_OK) {             \
      client_finalize(c);                                                \
      return io_error("curl_easy_setopt failed for " #opt);              \
    }                                                                    \
  } while (0)

/* Appends one header and leaves the constructor with an IO error on a failure. */
#define ADD_HEADER(c, text)                                              \
  do {                                                                   \
    struct curl_slist *grown = curl_slist_append((c)->headers, text);    \
    if (!grown) {                                                        \
      client_finalize(c);                                                \
      return io_error("curl_slist_append failed");                       \
    }                                                                    \
    (c)->headers = grown;                                                \
  } while (0)

/* Whether the shim checks the availability of TLS in libcurl. */
static const char *check_libcurl(void) {
#if AIBACKEND_ENV_CHECKS
  /* The program links libcurl dynamically, so the library of the run can
     differ from the library of the build. CURLOPT_PROTOCOLS_STR needs 7.85.0. */
  curl_version_info_data *v = curl_version_info(CURLVERSION_NOW);
  if (!v || !(v->features & CURL_VERSION_SSL))
    return "environment check failed: libcurl has no TLS support";
  if (v->version_num < 0x075500)
    return "environment check failed: libcurl is older than 7.85.0";
#endif
  return NULL;
}

/* Initializes libcurl and registers the client class, once per process. Any
   number of threads may call it at the same time. One thread runs the
   initialization, and the others wait for its end. Returns NULL on success,
   or the text of the failure. A failure leaves the state at 0, so a later
   call tries again. */
static const char *initialize_once(void) {
  for (;;) {
    if (atomic_load(&g_init_state) == 2) return NULL;
    int expected = 0;
    if (atomic_compare_exchange_strong(&g_init_state, &expected, 1)) {
      const char *failure = NULL;
      if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) failure = "curl_global_init failed";
      if (!failure) failure = check_libcurl();
      if (!failure && !g_client_class) {
        g_client_class = lean_register_external_class(client_finalize, client_foreach);
        if (!g_client_class) failure = "lean_register_external_class failed";
      }
      atomic_store(&g_init_state, failure ? 0 : 2);
      return failure;
    }
    /* Another thread runs the initialization. Its end changes the state. */
  }
}

/* Client.newRaw (url key caFile : @& String) : IO Client
   Preconditions, each checked here.
   - No argument holds a NUL byte.
   - The URL has the https scheme and a host.
   - The key is nonempty printable ASCII without a space.
   - A nonempty caFile names a readable file. It replaces the system trust store. */
LEAN_EXPORT lean_obj_res claude_client_new(b_lean_obj_arg url, b_lean_obj_arg key,
                                           b_lean_obj_arg ca_file) {
  if (!has_no_nul(url) || !has_no_nul(key) || !has_no_nul(ca_file))
    return io_error("precondition violated: an argument holds a NUL byte");
  if (!key_is_well_formed(lean_string_cstr(key)))
    return io_error("precondition violated: the key must be nonempty printable ASCII without spaces");
  const char *failure = initialize_once();
  if (failure) return io_error(failure);
  if (!url_is_https(lean_string_cstr(url)))
    return io_error("precondition violated: the URL must have the https scheme and a host");
  const char *ca = lean_string_cstr(ca_file);
  if (*ca) {
    FILE *f = fopen(ca, "rb");
    if (!f) return io_error("precondition violated: the CA file is not readable");
    fclose(f);
  }

  client_t *c = calloc(1, sizeof *c);
  if (!c) return io_error("out of memory");
  c->curl = curl_easy_init();
  atomic_flag_clear(&c->busy);
  if (!c->curl) { free(c); return io_error("curl_easy_init failed"); }

  size_t klen = strlen(lean_string_cstr(key));
  char *auth = malloc(klen + 12);
  if (!auth) { client_finalize(c); return io_error("out of memory"); }
  strcpy(auth, "x-api-key: ");
  strcat(auth, lean_string_cstr(key));
  struct curl_slist *first = curl_slist_append(c->headers, auth);
  memset(auth, 0, klen + 12); /* curl_slist_append copies the string */
  free(auth);
  if (!first) { client_finalize(c); return io_error("curl_slist_append failed"); }
  c->headers = first;
  ADD_HEADER(c, "anthropic-version: 2023-06-01");
  ADD_HEADER(c, "anthropic-beta: server-side-fallback-2026-07-01");
  ADD_HEADER(c, "content-type: application/json");

  /* The transfer uses TLS 1.2 or later and validates the certificate chain and
     the host name. The handle refuses every scheme other than https and follows
     no redirect. */
  SETOPT(c, CURLOPT_PROTOCOLS_STR, "https");
  SETOPT(c, CURLOPT_REDIR_PROTOCOLS_STR, "https");
  SETOPT(c, CURLOPT_FOLLOWLOCATION, 0L);
  SETOPT(c, CURLOPT_SSLVERSION, (long)CURL_SSLVERSION_TLSv1_2);
  SETOPT(c, CURLOPT_SSL_VERIFYPEER, 1L);
  SETOPT(c, CURLOPT_SSL_VERIFYHOST, 2L);
  if (*ca) SETOPT(c, CURLOPT_CAINFO, ca);
  SETOPT(c, CURLOPT_URL, lean_string_cstr(url));
  SETOPT(c, CURLOPT_HTTPHEADER, c->headers);
  SETOPT(c, CURLOPT_WRITEFUNCTION, on_data);
  SETOPT(c, CURLOPT_TCP_KEEPALIVE, 1L);
  SETOPT(c, CURLOPT_TIMEOUT, 600L);
  return lean_io_result_mk_ok(lean_alloc_external(g_client_class, c));
}

/* Client.postRaw (c : @& Client) (body : @& String) : IO (UInt32 × UInt32 × String)
   The result holds the HTTP status, the number of new connections the transfer
   opened (0 means libcurl reused a cached connection), and the response body.
   Preconditions, each checked here.
   - The client holds a live handle.
   - No other transfer runs on the client.
   - The body is nonempty and holds no NUL byte.
   Postconditions, each checked here.
   - The transfer used the https scheme.
   - The certificate verification succeeded.
   - The status is an HTTP status. */
static lean_obj_res post_exclusive(client_t *c, b_lean_obj_arg body);

LEAN_EXPORT lean_obj_res claude_client_post(b_lean_obj_arg obj, b_lean_obj_arg body) {
  client_t *c = lean_get_external_data(obj);
  if (!c || !c->curl || !c->headers)
    return io_error("precondition violated: the client holds no live handle");
  if (atomic_flag_test_and_set(&c->busy))
    return io_error("precondition violated: another transfer runs on this client");
  lean_obj_res r = post_exclusive(c, body);
  atomic_flag_clear(&c->busy);
  return r;
}

/* The transfer itself. The caller holds the busy flag of the client. */
static lean_obj_res post_exclusive(client_t *c, b_lean_obj_arg body) {
  if (!has_no_nul(body))
    return io_error("precondition violated: the body holds a NUL byte");
  size_t blen = lean_string_size(body) - 1;
  if (blen == 0) return io_error("precondition violated: the body is empty");

  buf_t b = { calloc(1, 1), 0 };
  if (!b.data) return io_error("out of memory");
  if (curl_easy_setopt(c->curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)blen) != CURLE_OK ||
      curl_easy_setopt(c->curl, CURLOPT_POSTFIELDS, lean_string_cstr(body)) != CURLE_OK ||
      curl_easy_setopt(c->curl, CURLOPT_WRITEDATA, &b) != CURLE_OK) {
    free(b.data);
    return io_error("curl_easy_setopt failed for the request body");
  }
  CURLcode rc = curl_easy_perform(c->curl);
  /* The body is borrowed and the buffer is on the stack. Detach both. */
  curl_easy_setopt(c->curl, CURLOPT_POSTFIELDS, NULL);
  curl_easy_setopt(c->curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)0);
  curl_easy_setopt(c->curl, CURLOPT_WRITEDATA, NULL);
  if (rc != CURLE_OK) { free(b.data); return io_error(curl_easy_strerror(rc)); }

  long status = 0, connects = 0, verify = -1;
  char *scheme = NULL;
  if (curl_easy_getinfo(c->curl, CURLINFO_RESPONSE_CODE, &status) != CURLE_OK ||
      curl_easy_getinfo(c->curl, CURLINFO_NUM_CONNECTS, &connects) != CURLE_OK ||
      curl_easy_getinfo(c->curl, CURLINFO_SSL_VERIFYRESULT, &verify) != CURLE_OK ||
      curl_easy_getinfo(c->curl, CURLINFO_SCHEME, &scheme) != CURLE_OK) {
    free(b.data);
    return io_error("curl_easy_getinfo failed");
  }
  if (!scheme || !curl_strequal(scheme, "https")) {
    free(b.data);
    return io_error("postcondition violated: the transfer did not use the https scheme");
  }
  if (verify != 0) {
    free(b.data);
    return io_error("postcondition violated: the certificate verification did not succeed");
  }
  if (status < 100 || status > 599 || connects < 0) {
    free(b.data);
    return io_error("postcondition violated: the response carries no HTTP status");
  }
  lean_object *text = lean_mk_string_from_bytes(b.data, b.len); /* keeps embedded NUL bytes */
  free(b.data);
  lean_object *inner = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(inner, 0, lean_box_uint32((uint32_t)connects));
  lean_ctor_set(inner, 1, text);
  lean_object *outer = lean_alloc_ctor(0, 2, 0);
  lean_ctor_set(outer, 0, lean_box_uint32((uint32_t)status));
  lean_ctor_set(outer, 1, inner);
  return lean_io_result_mk_ok(outer);
}
