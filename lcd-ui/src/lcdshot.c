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

#define LCD_W 320
#define LCD_H 240

int main(void)
{
	int fd = open("/dev/lcd", O_RDWR);
	if (fd < 0) {
		perror("open /dev/lcd");
		return 1;
	}

	uint16_t *fb = mmap(NULL, LCD_W * LCD_H * 2, PROT_READ, MAP_SHARED, fd, 0);
	if (fb == MAP_FAILED) {
		perror("mmap");
		close(fd);
		return 1;
	}

	printf("P6\n%d %d\n255\n", LCD_W, LCD_H);
	for (int i = 0; i < LCD_W * LCD_H; i++) {
		uint16_t p = fb[i];
		unsigned char rgb[3];

		rgb[0] = ((p >> 11) & 0x1F) * 255 / 31;
		rgb[1] = ((p >> 5) & 0x3F) * 255 / 63;
		rgb[2] = (p & 0x1F) * 255 / 31;
		fwrite(rgb, 1, 3, stdout);
	}

	munmap(fb, LCD_W * LCD_H * 2);
	close(fd);
	return 0;
}
