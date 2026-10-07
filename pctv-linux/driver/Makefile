# SPDX-License-Identifier: GPL-2.0
#
# Wrapper around the kernel build system for the Pinnacle PCTV 320cx driver.
# The actual rules live in Kbuild.
#
#   make                      # build pctv320cx.ko against the running kernel
#   make KDIR=/path/to/build  # ... or against a prepared build tree
#   make install              # modules_install into that tree

KDIR ?= /lib/modules/$(shell uname -r)/build
INSTALL_MOD_PATH ?= $(DESTDIR)

all: modules

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

install:
	$(MAKE) -C $(KDIR) M=$(CURDIR) INSTALL_MOD_PATH=$(INSTALL_MOD_PATH) \
		modules_install

.PHONY: all modules clean install
