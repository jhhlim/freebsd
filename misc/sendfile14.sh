#!/bin/sh

#
# Copyright (c) 2018 Dell EMC Isilon
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
# $FreeBSD$
#

# Regression test scenario attempt for r328914:
# "Occasional cylinder-group check-hash errors were being reported on
# systems running with a heavy filesystem load."

# Assert seen in WiP code:
# https://people.freebsd.org/~pho/stress/log/mmacy016.txt

. ../default.cfg
[ `id -u` -ne 0 ] && echo "Must be root!" && exit 1

dir=/tmp
odir=`pwd`
cd $dir
sed '1,/^EOF/d' < $odir/$0 > $dir/sendfile14.c
mycc -o sendfile14 -Wall -Wextra -O0 -g sendfile14.c -lpthread || exit 1
rm -f sendfile14.c
cd $odir

set -e
size="$((`sysctl -n hw.usermem` / 2 / 1024 / 1024 / 1024))"
size="$((size * 8 / 10))g"
[ "$size" = "0g" ] && exit 0
[ "$newfs_flags" = "-U" ] || exit 0
newfs_flags="-j"

mp1=$mntpoint
mkdir -p $mp1
md1=$mdstart
mount | grep "on $mp1 " | grep -q /dev/md && umount -f $mp1
[ -c /dev/md$md1 ] && mdconfig -d -u $md1
mdconfig -a -t swap -s $size -u $md1
bsdlabel -w md$md1 auto
newfs $newfs_flags -n md${md1}$part > /dev/null 2>&1
mount /dev/md${md1}$part $mp1

md2=$((mdstart + 1))
mp2=${mntpoint}$md2
mkdir -p $mp2
mount | grep "on $mp2 " | grep -q /dev/md && umount -f $mp2
[ -c /dev/md$md2 ] && mdconfig -d -u $md2
mdconfig -a -t swap -s $size -u $md2
bsdlabel -w md$md2 auto
newfs $newfs_flags -n md${md2}$part > /dev/null 2>&1
mount /dev/md${md2}$part $mp2
set +e

free=`df $mp1 | tail -1 | awk '{print $4}'`
$dir/sendfile14 5432 $mp1 $mp2 $((free / 2)) &
$dir/sendfile14 5433 $mp2 $mp1 $((free / 2)) &
cd $odir
wait
s=0
[ -f sendfile14.core -a $s -eq 0 ] &&
    { ls -l sendfile14.core; mv sendfile14.core /tmp; s=1; }
pkill sendfile14
cd $odir

for i in `jot 6`; do
	mount | grep -q "on $mp1 " || break
	umount $mp1 && break || sleep 10
	[ $i -eq 6 ] &&
	    { echo FATAL; fstat -mf $mp1; exit 1; }
done
for i in `jot 6`; do
	mount | grep -q "on $mp2 " || break
	umount $mp2 && break || sleep 10
	[ $i -eq 6 ] &&
	    { echo FATAL; fstat -mf $mp2; exit 1; }
done
checkfs /dev/md${md1}$part || s=1
checkfs /dev/md${md2}$part || s=1
mdconfig -d -u $md1 || s=1
mdconfig -d -u $md2 || s=1

rm -rf $dir/sendfile14
exit $s

EOF
#include <sys/param.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include <netinet/in.h>

#include <err.h>
#include <fcntl.h>
#include <netdb.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define BUFSIZE 8192
#define MAXTHREADS 5

static volatile int active;
static volatile u_int *share;
static int files, port;
static char *fromdir, *todir;

void
create(char *path, size_t size)
{
	size_t s;
	int fd, i, ifd;
	char *cp, file[128], help[128];

	setproctitle("%s", __func__);
	i = 0;
	while (size > 0) {
		do {
			s =arc4random() % size + 1;
		} while (s > 1024 * 1024 * 1024);
		size -= s;
		sprintf(file, "%s/f%06d.%06d", path, getpid(), i++);
		if ((ifd = open("/dev/zero", O_RDONLY)) == -1)
			err(1, "open(/dev/zero)");
		if ((cp = mmap(0, s, PROT_READ, MAP_SHARED, ifd, 0)) ==
			(caddr_t) - 1)
			err(1, "mmap error for input");
		if ((fd = open(file, O_WRONLY | O_CREAT, 0640)) == -1)
			err(1, "create(%s)", file);
		if (write(fd, cp, s) != (ssize_t)s)
			err(1, "write(%s)", file);
		munmap(cp, s);
		close(fd);
		close(ifd);
		files++;
	}
	snprintf(help, sizeof(help),
	    "umount %s 2>&1 | grep -v 'Device busy'", path);
	system(help);
#if defined(DEBUG)
	fprintf(stderr, "%d files created\n", files);
#endif
}

void
server(void)
{
	pid_t pid[100];
        struct sigaction sa;
	struct sockaddr_in inetaddr, inetpeer;
	socklen_t len;
	int tcpsock, msgsock;
	int *buf, fd, idx, n, on, t;
	char ofile[128], nfile[128];

	setproctitle("%s", __func__);
        sa.sa_handler = SIG_IGN;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;
        if (sigaction(SIGCHLD, &sa, 0) == -1)
                err(1, "sigaction");

	on = 1;
	if ((tcpsock = socket(AF_INET, SOCK_STREAM, 0)) < 0)
		err(1, "socket(), %s:%d", __FILE__, __LINE__);

	if (setsockopt(tcpsock,
	    SOL_SOCKET, SO_REUSEADDR, (char *)&on, sizeof(on)) < 0)
		err(1, "setsockopt(), %s:%d", __FILE__, __LINE__);

	inetaddr.sin_family = AF_INET;
	inetaddr.sin_addr.s_addr = INADDR_ANY;
	inetaddr.sin_port = htons(port);
	inetaddr.sin_len = sizeof(inetaddr);

	if (bind(tcpsock,
	    (struct sockaddr *)&inetaddr, sizeof (inetaddr)) < 0)
		err(1, "bind(), %s:%d", __FILE__, __LINE__);

	if (listen(tcpsock, 5) < 0)
		err(1, "listen(), %s:%d", __FILE__, __LINE__);

	idx = 0;
	len = sizeof(inetpeer);
	for (;;) {
		alarm(600);
		if ((msgsock = accept(tcpsock,
		    (struct sockaddr *)&inetpeer, &len)) < 0)
			err(1, "accept(), %s:%d", __FILE__, __LINE__);

		if ((pid[idx] = fork()) == 0) {
			t = 0;
			if ((buf = malloc(BUFSIZE)) == NULL)
				err(1, "malloc(%d), %s:%d", BUFSIZE,
				    __FILE__, __LINE__);

			sprintf(ofile, "%s/g%06d.%06d", todir, getpid(), idx);
			sprintf(nfile, "%s/n%06d.%06d", todir, getpid(), idx);
			if ((fd = open(ofile, O_RDWR | O_CREAT | O_TRUNC,
			    0640)) == -1)
				err(1, "open(%s)", ofile);

			for (;;) {
				if ((n = read(msgsock, buf, BUFSIZE)) < 0)
					err(1, "read(), %s:%d", __FILE__,
					    __LINE__);
				t += n;
				if (n == 0) break;

				if ((write(fd, buf, n)) != n)
					err(1, "write");
			}
			close(msgsock);
			close(fd);
			if (rename(ofile, nfile) != 0)
				err(1, "rename(%s, %s)", ofile, nfile);
			_exit(0);
		}
		close(msgsock);
		if (++idx == files)
			break;
		if (idx == nitems(pid))
			errx(1, "pid overflow");
	}
	for (n = 0; n < idx; n++)
		if (waitpid(pid[n], NULL, 0) != pid[n])
			err(1, "waitpid(%d)", pid[n]);

	_exit(0);
}

static void
writer(char *inputFile) {
	struct sockaddr_in inetaddr;
	struct hostent *hostent;
	struct stat statb;
	off_t off = 0;
	size_t size;
	int i, fd, on, r, tcpsock;

	on = 1;
	for (i = 1; i < 5; i++) {
		if ((tcpsock = socket(AF_INET, SOCK_STREAM, 0)) < 0)
			err(1, "socket(), %s:%d", __FILE__, __LINE__);

		if (setsockopt(tcpsock,
		    SOL_SOCKET, SO_REUSEADDR, (char *)&on, sizeof(on)) < 0)
			err(1, "setsockopt(), %s:%d", __FILE__, __LINE__);

		size = getpagesize();
		if (setsockopt(tcpsock,
		    SOL_SOCKET, SO_SNDBUF, (void *)&size, sizeof(size)) < 0)
			err(1, "setsockopt(SO_SNDBUF), %s:%d", __FILE__,
			    __LINE__);

		hostent = gethostbyname ("localhost");
		memcpy (&inetaddr.sin_addr.s_addr, hostent->h_addr,
			sizeof (struct in_addr));

		inetaddr.sin_family = AF_INET;
		inetaddr.sin_port = htons(port);
		inetaddr.sin_len = sizeof(inetaddr);

		r = connect(tcpsock, (struct sockaddr *) &inetaddr,
			sizeof(inetaddr));
		if (r == 0)
			break;
		sleep(1);
		close(tcpsock);
	}
	if (r < 0)
		err(1, "connect(), %s:%d", __FILE__, __LINE__);

        if (stat(inputFile, &statb) != 0)
                err(1, "stat(%s)", inputFile);

	if ((fd = open(inputFile, O_RDWR)) == -1)
		err(1, "open(%s)", inputFile);

	if (sendfile(fd, tcpsock, 0, statb.st_size, NULL, &off,
	    SF_NOCACHE) == -1)
		err(1, "sendfile");
	close(fd);

	return;
}

void *
move(void *arg)
{
	int num;
	char ifile[128];

	setproctitle("%s", __func__);
	while (active >= MAXTHREADS)
		usleep(100000);
	active++;
	num = (int)arg;

	sprintf(ifile, "%s/f%06d.%06d", fromdir, getpid(), num);
	writer(ifile);

	if (unlink(ifile) != 0)
		err(1, "unlink(%s)", ifile);
	active--;

	return (NULL);
}

int
main(int argc, char *argv[])
{
	pid_t spid;
	pthread_t *cp;
	size_t len, size;
	void *vp;
	int e, i;

	setproctitle("%s", __func__);
	if (argc != 5) {
		fprintf(stderr,
		    "Usage %s <port> <from dir> <to dir> <size in k>",
		    argv[0]);
		exit(1);
	}
	port = atoi(argv[1]);
	fromdir = argv[2];
	if (chdir(fromdir) == -1)
		err(1, "chdir(%s)", fromdir);
	todir = argv[3];
	e = 0;
	len = PAGE_SIZE;
	if ((share = mmap(NULL, len, PROT_READ | PROT_WRITE,
	    MAP_ANON | MAP_SHARED, -1, 0)) == MAP_FAILED)
		err(1, "mmap");
	sscanf(argv[4], "%zd", &size);
	size = size * 1024;
	create(fromdir, size);

	if ((spid = fork()) == 0)
		server();

	cp = malloc(files * sizeof(pthread_t));
	for (i = 0; i < files; i++) {
		vp = (void *)(long)i;
		if (pthread_create(&cp[i], NULL, move, vp) != 0)
			perror("pthread_create");
	}
	for (i = 0; i < files; i++) {
		pthread_join(cp[i], NULL);
	}
	if (waitpid(spid, NULL, 0) != spid)
		err(1, "waitpid");

	return (e);
}
