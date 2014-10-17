DESTDIR=/usr/local

all: man
lint:
	perl -MO=Lint,all kadadm.pl

man: kadadm.8

kadadm.8: kadadm.pl
	pod2man -s 8 -c "kadadm manual" $< $@

clean:
	rm -f kadadm.8

install: kadadm.8
	install -D -o root -g root -m 0755 kadadm.pl $(DESTDIR)/bin/kadadm
	install -D -o root -g root -m 0644 kadadm.8 $(DESTDIR)/share/man/man8/kadadm.8

uninstall:
	rm -f $(DESTDIR)/bin/kadadm
	rm -f $(DESTDIR)/share/man/man8/kadadm.8
