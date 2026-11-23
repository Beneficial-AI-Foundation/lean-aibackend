/* libcurl binding for the Anthropic Messages API with a persistent easy handle.
   One client owns one CURL handle. libcurl keeps the TLS connection open in that
   handle's connection cache, so later requests skip the TCP and TLS handshakes.
   A CURL easy handle is not thread safe. Use one client per thread. */
#include <lean/lean.h>
#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  CURL *curl;
  struct curl_slist *headers;
} client_t;

typedef struct {
  char *data;
  size_t len;
} buf_t;

static lean_external_class *g_client_class = NULL;

static void client_finalize(void *p) {
  client_t *c = p;
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

/* Client.new (url key : @& String) : IO Client */
LEAN_EXPORT lean_obj_res claude_client_new(b_lean_obj_arg url, b_lean_obj_arg key) {
  static int initialized = 0;
  if (!initialized) {
    if (curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) return io_error("curl_global_init failed");
    g_client_class = lean_register_external_class(client_finalize, client_foreach);
    initialized = 1;
  }
  client_t *c = calloc(1, sizeof *c);
  if (!c) return io_error("out of memory");
  c->curl = curl_easy_init();
  if (!c->curl) { free(c); return io_error("curl_easy_init failed"); }

  size_t klen = strlen(lean_string_cstr(key));
  char *auth = malloc(klen + 12);
  if (!auth) { client_finalize(c); return io_error("out of memory"); }
  strcpy(auth, "x-api-key: ");
  strcat(auth, lean_string_cstr(key));
  c->headers = curl_slist_append(c->headers, auth);
  memset(auth, 0, klen + 12); /* curl_slist_append copies the string */
  free(auth);
  c->headers = curl_slist_append(c->headers, "anthropic-version: 2023-06-01");
  c->headers = curl_slist_append(c->headers, "anthropic-beta: server-side-fallback-2026-07-01");
  c->headers = curl_slist_append(c->headers, "content-type: application/json");
  if (!c->headers) { client_finalize(c); return io_error("curl_slist_append failed"); }

  curl_easy_setopt(c->curl, CURLOPT_URL, lean_string_cstr(url));
  curl_easy_setopt(c->curl, CURLOPT_HTTPHEADER, c->headers);
  curl_easy_setopt(c->curl, CURLOPT_WRITEFUNCTION, on_data);
  curl_easy_setopt(c->curl, CURLOPT_TCP_KEEPALIVE, 1L);
  curl_easy_setopt(c->curl, CURLOPT_TIMEOUT, 600L);
  return lean_io_result_mk_ok(lean_alloc_external(g_client_class, c));
}

/* Client.postRaw (c : @& Client) (body : @& String) : IO (UInt32 × UInt32 × String)
   The result holds the HTTP status, the number of new connections the transfer
   opened (0 means libcurl reused a cached connection), and the response body. */
LEAN_EXPORT lean_obj_res claude_client_post(b_lean_obj_arg obj, b_lean_obj_arg body) {
  client_t *c = lean_get_external_data(obj);
  buf_t b = { calloc(1, 1), 0 };
  if (!b.data) return io_error("out of memory");
  curl_easy_setopt(c->curl, CURLOPT_POSTFIELDS, lean_string_cstr(body));
  curl_easy_setopt(c->curl, CURLOPT_WRITEDATA, &b);
  CURLcode rc = curl_easy_perform(c->curl);
  curl_easy_setopt(c->curl, CURLOPT_POSTFIELDS, NULL); /* body is borrowed and may be freed */
  if (rc != CURLE_OK) { free(b.data); return io_error(curl_easy_strerror(rc)); }
  long status = 0, connects = 0;
  curl_easy_getinfo(c->curl, CURLINFO_RESPONSE_CODE, &status);
  curl_easy_getinfo(c->curl, CURLINFO_NUM_CONNECTS, &connects);
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
