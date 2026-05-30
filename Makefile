CC         ?= cc
MUSL_CC    ?= musl-gcc
AARCH64_CC ?= aarch64-linux-gnu-gcc
CFLAGS     := -std=c11 -Wall -Wextra -Wpedantic
PREFIX     ?= /usr/local
UNAME_S    := $(shell uname -s)

# Use first available binary for test/bench
NJQ := $(shell if [ -x nanojq ]; then echo nanojq; \
               elif [ -x nanojq-apple ]; then echo nanojq-apple; \
               elif [ -x nanojq-dynamic ]; then echo nanojq-dynamic; fi)

.PHONY: all release apple dynamic debug graviton clean test bench install

ifeq ($(UNAME_S),Darwin)
all: apple
else
all: release
endif

release: nanojq

nanojq: nanojq.c jsmn.h
	$(MUSL_CC) $(CFLAGS) -Os -s -static -flto -ffunction-sections -fdata-sections \
		-fno-unwind-tables -fno-asynchronous-unwind-tables \
		-Wl,--gc-sections,--build-id=none -o $@ nanojq.c
	@ls -lh $@ | awk '{print "binary size:", $$5}'

apple: nanojq-apple

nanojq-apple: nanojq.c jsmn.h
	clang $(CFLAGS) -Os -flto -ffunction-sections -fdata-sections \
		-fno-unwind-tables -fno-asynchronous-unwind-tables \
		-Wl,-dead_strip -o $@ nanojq.c
	strip $@
	@ls -lh $@ | awk '{print "binary size:", $$5}'

dynamic: nanojq-dynamic

nanojq-dynamic: nanojq.c jsmn.h
	$(CC) $(CFLAGS) -Os -s -o $@ nanojq.c

graviton: nanojq-graviton

nanojq-graviton: nanojq.c jsmn.h
	$(AARCH64_CC) $(CFLAGS) -Os -s -static -flto -ffunction-sections -fdata-sections \
		-fno-unwind-tables -fno-asynchronous-unwind-tables \
		-Wl,--gc-sections,--build-id=none -o $@ nanojq.c
	@ls -lh $@ | awk '{print "binary size:", $$5}'

debug: nanojq-debug

nanojq-debug: nanojq.c jsmn.h
	$(CC) $(CFLAGS) -g -DDEBUG -o $@ nanojq.c

clean:
	rm -f nanojq nanojq-apple nanojq-dynamic nanojq-debug nanojq-graviton

test:
	@bash test.sh

bench:
	@bash bench.sh

install:
	@bin=""; \
	if [ -x nanojq ]; then bin=nanojq; \
	elif [ -x nanojq-apple ]; then bin=nanojq-apple; \
	elif [ -x nanojq-dynamic ]; then bin=nanojq-dynamic; \
	else echo "error: no binary found. run 'make' or 'make dynamic' first." >&2; exit 1; fi; \
	install -m 755 $$bin $(PREFIX)/bin/nanojq
