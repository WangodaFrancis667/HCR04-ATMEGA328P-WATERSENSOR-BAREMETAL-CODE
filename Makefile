# Makefile for Arduino Water Level Monitor (Bare Metal)
# Target: ATmega328P (Arduino Uno)

# Microcontroller settings
MCU = atmega328p
F_CPU = 16000000UL
BAUD = 115200

# Port settings (adjust for your system)
# Linux: /dev/ttyUSB0 or /dev/ttyACM0
# Windows: COM3, COM4, etc.
# macOS: /dev/tty.usbmodem* or /dev/tty.usbserial*
PORT = /dev/ttyUSB0

# Compiler and tools
CC = avr-gcc
OBJCOPY = avr-objcopy
AVRDUDE = avrdude

# Compiler flags
CFLAGS = -mmcu=$(MCU) -DF_CPU=$(F_CPU) -Os -Wall -Wextra
LDFLAGS = -mmcu=$(MCU)

# Programmer settings
PROGRAMMER = arduino
AVRDUDE_FLAGS = -c $(PROGRAMMER) -p $(MCU) -P $(PORT) -b $(BAUD)

# Source files
SRC = water_level_monitor_bare_metal.c
TARGET = water_level_monitor

# Default target
all: $(TARGET).hex

# Compile source to object file
$(TARGET).o: $(SRC)
	$(CC) $(CFLAGS) -c $< -o $@

# Link object file to ELF
$(TARGET).elf: $(TARGET).o
	$(CC) $(LDFLAGS) $< -o $@

# Convert ELF to HEX
$(TARGET).hex: $(TARGET).elf
	$(OBJCOPY) -O ihex -R .eeprom $< $@

# Upload to Arduino
upload: $(TARGET).hex
	$(AVRDUDE) $(AVRDUDE_FLAGS) -U flash:w:$<

# Check code size
size: $(TARGET).elf
	avr-size --mcu=$(MCU) -C $<

# Clean build files
clean:
	rm -rf .pio/build/ATmega328P/*.hex

# Verify connection
test:
	$(AVRDUDE) $(AVRDUDE_FLAGS) -v

# Show fuse settings (read-only)
fuses:
	$(AVRDUDE) $(AVRDUDE_FLAGS) -U lfuse:r:-:h -U hfuse:r:-:h -U efuse:r:-:h

.PHONY: all upload clean test fuses size
