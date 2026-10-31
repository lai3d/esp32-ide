"""Blink the ESP32's on-board LED (GPIO 2) and print a counter. Run it with ⌘R."""

import time

from machine import Pin

led = Pin(2, Pin.OUT)

for i in range(10):
    led.value(i % 2)
    print("blink", i)
    time.sleep(0.5)

led.off()
name = input("Your name? ")
print("Hello,", name or "stranger")
