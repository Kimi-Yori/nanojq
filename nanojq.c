/*
 * nanojq - ultra-lightweight JSON selector CLI
 *
 * Usage:
 *   echo '{"key":"val"}' | nanojq '.key'
 *   nanojq '.key.sub' file.json
 *
 * Default output is raw (unquoted strings). Use --json / -J for JSON repr.
 *
 * Exit codes:
 *   0 = found
 *   1 = path not found
 *   2 = error (invalid JSON, invalid query, I/O)
 */

#define _GNU_SOURCE  /* mremap */

#define JSMN_STATIC
#define JSMN_STRICT
#include "jsmn.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/* No stdio.h — all output via write(2) to avoid pulling in printf/fmt_fp (~10KB).
 * No stdlib.h — mmap/mremap replaces malloc/realloc (~7KB), manual int parse. */

/* ---------------- constants ---------------- */

#define NANOJQ_VERSION  "0.1.0"
#define STACK_TOKENS    4096
#define READ_BUF_INIT   (64 * 1024)
#define READ_BUF_MAX    (256 * 1024 * 1024)

#define EXIT_FOUND      0
#define EXIT_NOT_FOUND  1
#define EXIT_ERROR      2

/* ---------------- low-level I/O (no stdio) ---------------- */

static int io_error; /* stdout write failure flag */

static void wr(int fd, const char *buf, size_t len) {
    while (len > 0) {
        ssize_t n = write(fd, buf, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (fd == STDOUT_FILENO) io_error = 1;
            return;
        }
        buf += n;
        len -= (size_t)n;
    }
}

static void wrs(int fd, const char *s) {
    wr(fd, s, strlen(s));
}

/* buffered stdout */
static char outbuf[4096];
static int outpos;

static void out_flush(void) {
    if (outpos > 0) {
        wr(STDOUT_FILENO, outbuf, (size_t)outpos);
        outpos = 0;
    }
}

static void out(const char *buf, int len) {
    if (outpos + len > (int)sizeof(outbuf)) {
        out_flush();
        if (len >= (int)sizeof(outbuf)) {
            wr(STDOUT_FILENO, buf, (size_t)len);
            return;
        }
    }
    memcpy(outbuf + outpos, buf, (size_t)len);
    outpos += len;
}

static void outc(char c) {
    if (outpos >= (int)sizeof(outbuf)) out_flush();
    outbuf[outpos++] = c;
}

/* stderr helpers */
static void errmsg(const char *msg) {
    wrs(STDERR_FILENO, "nanojq: ");
    wrs(STDERR_FILENO, msg);
    wr(STDERR_FILENO, "\n", 1);
}

static void errmsg2(const char *ctx, const char *msg) {
    wrs(STDERR_FILENO, "nanojq: ");
    wrs(STDERR_FILENO, ctx);
    wr(STDERR_FILENO, ": ", 2);
    wrs(STDERR_FILENO, msg);
    wr(STDERR_FILENO, "\n", 1);
}

/* ---------------- query segment ---------------- */

enum seg_type { SEG_KEY, SEG_INDEX };

struct segment {
    enum seg_type type;
    const char   *key;
    int           key_len;
    int           index;
};

#define MAX_SEGMENTS 64

/* ---------------- parse query ---------------- */

/* Parse non-negative decimal integer from *pp. Advances *pp past digits.
 * Returns value, or -1 if no digits or overflow past INT32_MAX. */
static long parse_uint(const char **pp) {
    const char *p = *pp;
    if (*p < '0' || *p > '9') return -1;
    long val = 0;
    while (*p >= '0' && *p <= '9') {
        if (val > 214748364L || (val == 214748364L && *p > '7'))
            return -1;
        val = val * 10 + (*p - '0');
        p++;
    }
    *pp = p;
    return val;
}

static int parse_query(const char *q, struct segment *segs, int max) {
    int n = 0;

    if (!q || *q != '.') return -1;
    q++;

    if (*q == '\0') return 0;
    if (*q == '.') return -1;

    while (*q && n < max) {
        if (*q == '.') {
            q++;
            if (*q == '\0' || *q == '.') return -1;
        }

        if (*q == '[') {
            q++; /* skip '[' */
            if (*q == '"') {
                /* bracket key: ["key"] */
                q++; /* skip opening quote */
                const char *start = q;
                while (*q && *q != '"') {
                    if (*q == '\\' && *(q + 1)) q++; /* skip escaped char */
                    q++;
                }
                if (*q != '"') return -1;
                segs[n].type    = SEG_KEY;
                segs[n].key     = start;
                segs[n].key_len = (int)(q - start);
                segs[n].index   = 0;
                n++;
                q++; /* skip closing quote */
                if (*q != ']') return -1;
                q++; /* skip ']' */
            } else {
                /* array index: [N] */
                long idx = parse_uint(&q);
                if (idx < 0 || *q != ']') return -1;
                segs[n].type  = SEG_INDEX;
                segs[n].index = (int)idx;
                segs[n].key   = NULL;
                segs[n].key_len = 0;
                n++;
                q++; /* skip ']' */
            }
            if (*q && *q != '.' && *q != '[') return -1;
        } else {
            const char *start = q;
            while (*q && *q != '.' && *q != '[') q++;
            if (q == start) return -1;
            segs[n].type    = SEG_KEY;
            segs[n].key     = start;
            segs[n].key_len = (int)(q - start);
            segs[n].index   = 0;
            n++;
        }
    }
    if (*q) return -1;
    return n;
}

/* ---------------- JSON token walking ---------------- */

static int tok_span(const jsmntok_t *tok, int pos, int total) {
    if (pos >= total) return 0;
    int count = 0;
    int pending = 1;
    int cur = pos;
    while (pending > 0 && cur < total) {
        pending--;
        count++;
        if (tok[cur].type == JSMN_OBJECT)
            pending += tok[cur].size * 2;
        else if (tok[cur].type == JSMN_ARRAY)
            pending += tok[cur].size;
        cur++;
    }
    return count;
}

static int walk(const jsmntok_t *tok, int total, const char *json,
                const struct segment *segs, int nseg) {
    int pos = 0;

    for (int s = 0; s < nseg; s++) {
        if (pos >= total) return -1;

        if (segs[s].type == SEG_KEY) {
            if (tok[pos].type != JSMN_OBJECT) return -1;
            int children = tok[pos].size;
            int cur = pos + 1;
            int found = 0;
            for (int i = 0; i < children; i++) {
                if (cur >= total) return -1;
                int klen = tok[cur].end - tok[cur].start;
                if (klen == segs[s].key_len &&
                    memcmp(json + tok[cur].start, segs[s].key, klen) == 0) {
                    pos = cur + 1;
                    found = 1;
                    break;
                }
                cur++;
                cur += tok_span(tok, cur, total);
            }
            if (!found) return -1;

        } else {
            if (tok[pos].type != JSMN_ARRAY) return -1;
            int children = tok[pos].size;
            int idx = segs[s].index;
            if (idx < 0 || idx >= children) return -1;
            int cur = pos + 1;
            for (int i = 0; i < idx; i++)
                cur += tok_span(tok, cur, total);
            pos = cur;
        }
    }
    return pos;
}

/* ---------------- unicode / string unescape ---------------- */

static int utf8_encode(unsigned cp, char *buf) {
    if (cp <= 0x7F) {
        buf[0] = (char)cp;
        return 1;
    } else if (cp <= 0x7FF) {
        buf[0] = (char)(0xC0 | (cp >> 6));
        buf[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp <= 0xFFFF) {
        buf[0] = (char)(0xE0 | (cp >> 12));
        buf[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    } else if (cp <= 0x10FFFF) {
        buf[0] = (char)(0xF0 | (cp >> 18));
        buf[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        buf[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        buf[3] = (char)(0x80 | (cp & 0x3F));
        return 4;
    }
    buf[0] = '?';
    return 1;
}

static int parse_hex4(const char *s) {
    unsigned val = 0;
    for (int i = 0; i < 4; i++) {
        val <<= 4;
        char c = s[i];
        if (c >= '0' && c <= '9')      val += c - '0';
        else if (c >= 'a' && c <= 'f') val += c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') val += c - 'A' + 10;
        else return -1;
    }
    return (int)val;
}

static void write_unescaped(const char *src, int len) {
    const char *end = src + len;
    char buf[4];

    while (src < end) {
        if (*src != '\\') {
            const char *run = src;
            while (run < end && *run != '\\') run++;
            out(src, (int)(run - src));
            src = run;
            continue;
        }
        src++;
        if (src >= end) break;
        switch (*src) {
        case '"':  outc('"');  src++; break;
        case '\\': outc('\\'); src++; break;
        case '/':  outc('/');  src++; break;
        case 'b':  outc('\b'); src++; break;
        case 'f':  outc('\f'); src++; break;
        case 'n':  outc('\n'); src++; break;
        case 'r':  outc('\r'); src++; break;
        case 't':  outc('\t'); src++; break;
        case 'u': {
            src++;
            if (src + 4 > end) { outc('?'); break; }
            int cp = parse_hex4(src);
            src += 4;
            if (cp < 0) { outc('?'); break; }
            if (cp >= 0xD800 && cp <= 0xDBFF) {
                if (src + 6 <= end && src[0] == '\\' && src[1] == 'u') {
                    int lo = parse_hex4(src + 2);
                    if (lo >= 0xDC00 && lo <= 0xDFFF) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                        src += 6;
                    } else {
                        cp = 0xFFFD;
                    }
                } else {
                    cp = 0xFFFD;
                }
            } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                cp = 0xFFFD;
            }
            int n = utf8_encode((unsigned)cp, buf);
            out(buf, n);
            break;
        }
        default:
            outc(*src);
            src++;
            break;
        }
    }
}

/* ---------------- output ---------------- */

static void output_token(const jsmntok_t *tok, int pos,
                         const char *json, int raw) {
    int start = tok[pos].start;
    int end   = tok[pos].end;

    switch (tok[pos].type) {
    case JSMN_STRING:
        if (raw) {
            write_unescaped(json + start, end - start);
        } else {
            outc('"');
            out(json + start, end - start);
            outc('"');
        }
        break;
    case JSMN_PRIMITIVE:
        out(json + start, end - start);
        break;
    case JSMN_OBJECT:
    case JSMN_ARRAY:
        out(json + start, end - start);
        break;
    default:
        break;
    }
    outc('\n');
    out_flush();
}

/* ---------------- read input ---------------- */

static size_t stdin_mmap_cap; /* saved for cleanup */

static char *read_stdin(size_t *len) {
    size_t cap = READ_BUF_INIT;
    size_t sz  = 0;
    char  *buf = mmap(NULL, cap, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) return NULL;

    for (;;) {
        ssize_t n = read(STDIN_FILENO, buf + sz, cap - sz);
        if (n < 0) {
            if (errno == EINTR) continue;
            munmap(buf, cap);
            return NULL;
        }
        if (n == 0) break;
        sz += n;
        if (sz == cap) {
            if (cap >= (size_t)READ_BUF_MAX) {
                /* At limit. Probe for EOF to accept exactly READ_BUF_MAX. */
                char probe;
                ssize_t pn;
                do { pn = read(STDIN_FILENO, &probe, 1); } while (pn < 0 && errno == EINTR);
                if (pn != 0) { munmap(buf, cap); return NULL; }
                break;
            }
            size_t newcap = cap * 2;
            if (newcap > (size_t)READ_BUF_MAX) newcap = READ_BUF_MAX;
            char *tmp = mremap(buf, cap, newcap, MREMAP_MAYMOVE);
            if (tmp == MAP_FAILED) { munmap(buf, cap); return NULL; }
            buf = tmp;
            cap = newcap;
        }
    }
    stdin_mmap_cap = cap;
    *len = sz;
    return buf;
}

static char *read_file(const char *path, size_t *len) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        errmsg2(path, strerror(errno));
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) < 0 || st.st_size == 0) {
        close(fd);
        errmsg2(path, "cannot stat or empty file");
        return NULL;
    }
    if (st.st_size > 0x7FFFFFFF) {
        close(fd);
        errmsg2(path, "file too large");
        return NULL;
    }
    char *buf = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (buf == MAP_FAILED) {
        errmsg2(path, "mmap failed");
        return NULL;
    }
    *len = st.st_size;
    return buf;
}

/* ---------------- usage ---------------- */

static const char usage_text[] =
    "nanojq " NANOJQ_VERSION " - ultra-lightweight JSON selector\n"
    "\n"
    "usage:\n"
    "  nanojq <query> [file]\n"
    "  echo '{...}' | nanojq <query>\n"
    "\n"
    "query syntax:\n"
    "  .key            object key\n"
    "  .key.subkey     nested key\n"
    "  .[0]            array index\n"
    "  .[\"key\"]        bracket key (for dots/spaces in keys)\n"
    "  .key[0].name    mixed path\n"
    "  .               root (whole document)\n"
    "\n"
    "output:\n"
    "  strings are printed raw (unquoted) by default\n"
    "  use --json / -J for JSON representation\n"
    "\n"
    "exit codes:\n"
    "  0  value found\n"
    "  1  path not found\n"
    "  2  error\n";

static void usage(void) {
    wr(STDERR_FILENO, usage_text, sizeof(usage_text) - 1);
}

/* ---------------- main ---------------- */

static const char version_str[] = "nanojq " NANOJQ_VERSION "\n";

int main(int argc, char **argv) {
    const char *query = NULL;
    const char *file  = NULL;
    int raw_output    = 1;

    int argi = 1;
    while (argi < argc) {
        if (strcmp(argv[argi], "--help") == 0 || strcmp(argv[argi], "-h") == 0) {
            usage();
            return EXIT_FOUND;
        }
        if (strcmp(argv[argi], "--version") == 0) {
            wr(STDOUT_FILENO, version_str, sizeof(version_str) - 1);
            return EXIT_FOUND;
        }
        if (strcmp(argv[argi], "--json") == 0 || strcmp(argv[argi], "-J") == 0) {
            raw_output = 0;
            argi++;
            continue;
        }
        if (argv[argi][0] == '-' && argv[argi][1] != '\0'
            && strcmp(argv[argi], "--") != 0) {
            errmsg2(argv[argi], "unknown option");
            return EXIT_ERROR;
        }
        if (strcmp(argv[argi], "--") == 0) { argi++; break; }
        break;
    }

    if (argi < argc) { query = argv[argi++]; }
    if (argi < argc) { file  = argv[argi++]; }
    if (argi < argc) {
        errmsg2(argv[argi], "unexpected argument");
        return EXIT_ERROR;
    }

    if (!query) {
        usage();
        return EXIT_ERROR;
    }

    struct segment segs[MAX_SEGMENTS];
    int nseg = parse_query(query, segs, MAX_SEGMENTS);
    if (nseg < 0) {
        errmsg2(query, "invalid query syntax");
        return EXIT_ERROR;
    }

    char  *json = NULL;
    size_t json_len = 0;
    int    from_stdin = 0;
    int    from_mmap  = 0;

    if (file) {
        json = read_file(file, &json_len);
        if (!json) return EXIT_ERROR;
        from_mmap = 1;
    } else {
        if (isatty(STDIN_FILENO)) {
            errmsg("no input (pipe JSON or specify a file)");
            return EXIT_ERROR;
        }
        json = read_stdin(&json_len);
        if (!json) {
            errmsg("stdin: read error or input too large");
            return EXIT_ERROR;
        }
        from_stdin = 1;
    }

    jsmn_parser parser;
    jsmntok_t stack_tokens[STACK_TOKENS];
    jsmntok_t *tokens = stack_tokens;
    int num_tokens = STACK_TOKENS;
    int mmap_tokens = 0;

    jsmn_init(&parser);
    int r = jsmn_parse(&parser, json, json_len, tokens, num_tokens);

    if (r == JSMN_ERROR_NOMEM) {
        jsmn_init(&parser);
        int needed = jsmn_parse(&parser, json, json_len, NULL, 0);
        if (needed <= 0) {
            errmsg("invalid JSON");
            r = -1;
            goto cleanup;
        }
        size_t tok_bytes = (size_t)needed * sizeof(jsmntok_t);
        tokens = mmap(NULL, tok_bytes, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (tokens == MAP_FAILED) {
            errmsg("out of memory");
            tokens = stack_tokens;
            r = -1;
            goto cleanup;
        }
        mmap_tokens = 1;
        num_tokens = needed;
        jsmn_init(&parser);
        r = jsmn_parse(&parser, json, json_len, tokens, num_tokens);
    }

    if (r < 0) {
        errmsg("invalid JSON");
        r = -1;
        goto cleanup;
    }

    if (r == 0) {
        errmsg("invalid JSON");
        r = -1;
        goto cleanup;
    }

    /* Reject multiple top-level JSON documents (e.g. "1 2", "{} []") */
    if (tok_span(tokens, 0, r) != r) {
        errmsg("multiple top-level values");
        r = -1;
        goto cleanup;
    }

    int found;
    if (nseg == 0) {
        found = 0;
    } else {
        found = walk(tokens, r, json, segs, nseg);
    }

    if (found < 0 || found >= r) {
        r = -2;
        goto cleanup;
    }

    output_token(tokens, found, json, raw_output);
    r = 0;

cleanup:
    if (mmap_tokens && tokens != stack_tokens) {
        munmap(tokens, (size_t)num_tokens * sizeof(jsmntok_t));
    }
    if (from_mmap && json) {
        munmap(json, json_len);
    }
    if (from_stdin && json) {
        munmap(json, stdin_mmap_cap);
    }

    if (r == 0)  return io_error ? EXIT_ERROR : EXIT_FOUND;
    if (r == -2) return EXIT_NOT_FOUND;
    return EXIT_ERROR;
}
