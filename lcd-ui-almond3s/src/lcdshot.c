/*
 * lcdshot - снимок экрана Almond 3S: mmap /dev/lcd и PPM в stdout.
 *
 * Драйвер отдаёт тот же самый framebuffer, из которого рисует kthread, так
 * что снимок показывает ровно то, что на панели, без обращения к железу.
 *
 *   lcdshot > shot.ppm
 */
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/ioctl.h>

int main(void)
{
	int fd = open("/dev/lcd", O_RDWR);
	int lcd_w = 320, lcd_h = 240, g;
	if (fd < 0) {
		perror("open /dev/lcd");
		return 1;
	}

	g = ioctl(fd, 34, 0);
	if (g > 0) { lcd_w = (g >> 16) & 0xFFFF; lcd_h = g & 0xFFFF; }

	uint16_t *fb = mmap(NULL, lcd_w * lcd_h * 2, PROT_READ, MAP_SHARED, fd, 0);
	if (fb == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return 1;
	}

	printf("P6\n%d %d\n255\n", lcd_w, lcd_h);
	for (int i = 0; i < lcd_w * lcd_h; i++) {
		uint16_t p = fb[i];
		unsigned char rgb[3];

		rgb[0] = ((p >> 11) & 0x1F) * 255 / 31;
		rgb[1] = ((p >> 5) & 0x3F) * 255 / 63;
		rgb[2] = (p & 0x1F) * 255 / 31;
		fwrite(rgb, 1, 3, stdout);
	}

	munmap(fb, lcd_w * lcd_h * 2);
	close(fd);
	return 0;
}
