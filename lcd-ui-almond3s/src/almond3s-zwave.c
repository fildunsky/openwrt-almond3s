#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <termios.h>
#include <time.h>
#include <sys/select.h>

#define SOF  0x01
#define ACK  0x06
#define NAK  0x15
#define CAN  0x18
#define REQ  0x00
#define RES  0x01

#define FN_VERSION   0x15
#define FN_CAPS      0x07
#define FN_MEMGETID  0x20

static int fd;

static int port_open(const char *dev, int baud)
{
	struct termios t;
	speed_t s = baud == 57600 ? B57600 : baud == 38400 ? B38400 : B115200;

	fd = open(dev, O_RDWR | O_NOCTTY | O_NONBLOCK);
	if (fd < 0)
		return -1;
	fcntl(fd, F_SETFL, 0);
	tcgetattr(fd, &t);
	cfmakeraw(&t);
	cfsetispeed(&t, s);
	cfsetospeed(&t, s);
	t.c_cflag |= CLOCAL | CREAD;
	t.c_cflag &= ~CRTSCTS;
	t.c_iflag &= ~(IXON | IXOFF | IXANY);
	tcsetattr(fd, TCSANOW, &t);
	tcflush(fd, TCIOFLUSH);
	return 0;
}

static int rd_byte(int ms)
{
	fd_set r;
	struct timeval tv = { ms / 1000, (ms % 1000) * 1000 };
	unsigned char c;

	FD_ZERO(&r);
	FD_SET(fd, &r);
	if (select(fd + 1, &r, 0, 0, &tv) <= 0)
		return -1;
	if (read(fd, &c, 1) != 1)
		return -1;
	return c;
}

static void send_frame(unsigned char fn, const unsigned char *data, int dn)
{
	unsigned char b[64];
	int i, n = 0, len = dn + 3;
	unsigned char ck;

	b[n++] = SOF;
	b[n++] = (unsigned char)len;
	b[n++] = REQ;
	b[n++] = fn;
	for (i = 0; i < dn; i++)
		b[n++] = data[i];
	ck = 0xFF;
	for (i = 1; i < n; i++)
		ck ^= b[i];
	b[n++] = ck;
	write(fd, b, n);
}

/* Читает один кадр ответа: пропускает ACK/мусор, ловит SOF, тело по LEN, шлёт
   ACK контроллеру. Возвращает длину полезной части (TYPE..data) или -1. */
static int recv_frame(unsigned char *out, int max, int *got_ack, int ms)
{
	long t0 = (long)time(0) * 1000;
	int c;

	while (1) {
		c = rd_byte(ms);
		if (c < 0)
			return -1;
		if (c == ACK) { if (got_ack) *got_ack = 1; continue; }
		if (c == NAK || c == CAN) continue;
		if (c != SOF) continue;
		int len = rd_byte(ms);
		if (len < 2 || len > max)
			continue;
		int i, ck = 0xFF ^ len;
		for (i = 0; i < len - 1; i++) {
			int d = rd_byte(ms);
			if (d < 0)
				return -1;
			out[i] = (unsigned char)d;
			ck ^= d;
		}
		int rxck = rd_byte(ms);
		unsigned char a = ACK;
		write(fd, &a, 1);
		(void)rxck; (void)t0;
		return len - 1;
	}
}

int main(int argc, char **argv)
{
	const char *dev = getenv("ZW_TTY") ? getenv("ZW_TTY") : "/dev/ttyS3";
	int baud = getenv("ZW_BAUD") ? atoi(getenv("ZW_BAUD")) : 115200;
	unsigned char buf[64];
	int n, ack = 0;
	char ver[48] = "";

	if (port_open(dev, baud) < 0) {
		printf("{\"ok\":0,\"error\":\"no port %s\"}\n", dev);
		return 1;
	}

	send_frame(FN_VERSION, 0, 0);
	n = recv_frame(buf, sizeof buf, &ack, 800);
	if (n < 3 || buf[1] != FN_VERSION) {
		printf("{\"ok\":0,\"ack\":%d,\"error\":\"no version response\"}\n", ack);
		return 1;
	}
	{
		int i, p = 2;
		for (i = 0; p + i < n && buf[p + i] && i < 40; i++)
			ver[i] = (buf[p + i] >= 32 && buf[p + i] < 127) ? buf[p + i] : '.';
		ver[i] = 0;
	}
	int libtype = (n >= 3) ? buf[n - 1] : -1;

	unsigned int home = 0, node = 0;
	send_frame(FN_MEMGETID, 0, 0);
	n = recv_frame(buf, sizeof buf, 0, 800);
	if (n >= 7 && buf[1] == FN_MEMGETID) {
		home = (buf[2] << 24) | (buf[3] << 16) | (buf[4] << 8) | buf[5];
		node = buf[6];
	}

	printf("{\"ok\":1,\"ack\":%d,\"version\":\"%s\",\"libtype\":%d,\"homeid\":\"%08X\",\"nodeid\":%u}\n",
	       ack, ver, libtype, home, node);
	return 0;
}
