#ifndef SM0_SHARED_H
#define SM0_SHARED_H

/*
 * SM0 I2C controller shared definitions for MT7621 Almond 3S.
 * Used by lcd_drv.ko (touch) and pic_battery.ko (PIC16 battery).
 * Both share the same SM0 bus — access must be mutex-protected.
 */

/* OLD SM0 auto mode registers (offset from palmbus base 0x1E000000) */
#define SM0_CFG       0x900
#define SM0_DATA      0x908  /* slave addr */
#define SM0_DATAOUT   0x910  /* write data */
#define SM0_DATAIN    0x914  /* read data */
#define SM0_POLLSTA   0x918
#define SM0_STATUS    0x91C  /* 0=write, 1=read */
#define SM0_START     0x920
#define SM0_CFG2      0x928  /* 0=manual, 1=auto */

/* NEW SM0 registers (kernel 6.12 i2c-mt7621) */
#define SM0_CTL1      0x940  /* same as NEW_CTL0 */
#define NEW_CTL0      0x940
#define NEW_CTL1      0x944
#define NEW_D0        0x950
#define NEW_D1        0x954

/* NEW SM0 command bits */
#define N_TRI         0x01
#define N_START       0x10
#define N_WRITE       0x20
#define N_STOP        0x30
#define N_READ_L      0x40  /* read last (NACK) */
#define N_READ        0x50  /* read with ACK */
#define N_PGLEN(x)    ((((x)-1)<<8) & 0x700)

/* I2C addresses */
#define SX8650_ADDR   0x48
#define PIC_ADDR      0x2A

/* Exported by lcd_drv.ko */
extern void lcd_sm0_lock(void);
extern void lcd_sm0_unlock(void);
extern void __iomem *lcd_sm0_get_base(void);

/* Callback: lcd_drv calls this from touch thread every 10s (after touch read).
 * pic_battery registers it. SM0 is in known-good state (after sx8650_read_xy). */
typedef void (*pic_poll_callback_t)(void __iomem *base);
extern void lcd_set_pic_callback(pic_poll_callback_t cb);
extern void lcd_clear_pic_callback(void);

#endif /* SM0_SHARED_H */
