#!/bin/sh
almond3s-lcd dim 0 >/dev/null 2>&1
almond3s-lcd panel 0x28 >/dev/null 2>&1
sync
poweroff
