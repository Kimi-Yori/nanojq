CC      ?= cc
MUSL_CC ?= musl-gcc
CFLAGS  := -std=c11 -Wall -Wextra -Wpedantic
PREFIX  ?= /usr/local

# Use static musl binary if available, otherwise fall back to dynamic
NJQ     := $(shell if [ -x nanojq ]; then echo nanojq; elif [ -x nanojq-dynamic ]; then echo nanojq-dynamic; fi)

.PHONY: all release dynamic debug clean test bench install

all: release

release: nanojq

nanojq: nanojq.c jsmn.h
	$(MUSL_CC) $(CFLAGS) -Os -s -static -flto -ffunction-sections -fdata-sections \
		-fno-unwind-tables -fno-asynchronous-unwind-tables \
		-Wl,--gc-sections,--build-id=none -o $@ nanojq.c
	@ls -lh $@ | awk '{print "binary size:", $$5}'

dynamic: nanojq-dynamic

nanojq-dynamic: nanojq.c jsmn.h
	$(CC) $(CFLAGS) -Os -s -o $@ nanojq.c

debug: nanojq-debug

nanojq-debug: nanojq.c jsmn.h
	$(CC) $(CFLAGS) -g -DDEBUG -o $@ nanojq.c

clean:
	rm -f nanojq nanojq-dynamic nanojq-debug

test:
	@bash test.sh

bench:
	@bash bench.sh

install:
	@bin=""; \
	if [ -x nanojq ]; then bin=nanojq; \
	elif [ -x nanojq-dynamic ]; then bin=nanojq-dynamic; \
	else echo "error: no binary found. run 'make' or 'make dynamic' first." >&2; exit 1; fi; \
	install -m 755 $$bin $(PREFIX)/bin/nanojq
