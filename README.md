# Arduino Water Level Monitoring System
## Complete Mini Project

A comprehensive water level monitoring system for Arduino Uno using HC-SR04 ultrasonic sensor and water level sensor with 100% bare metal programming (no Arduino libraries).

This project is designed to be simple yet educational.

### Project Overview
The system monitors water levels using two complementary sensors:
Water level sensor for direct water detection **(critically low levels)**

HC-SR04 ultrasonic sensor for distance measurement **(overflow prevention)**

The system provides real-time feedback through LED indicators and buzzer alarms, all controlled through direct register manipulation without any Arduino libraries.

# Makefile for compilation and upload
- Build system and compilation handled in the make file 
```
make          # Compile the project
make upload   # Upload to Arduino  
make clean    # Clean build files
```

### System Operation States
The system operates in three distinct states:

- ### Critical Low Water (Red LED + Buzzer ON)

    - Water sensor ADC reading < 100

    - Indicates tank needs immediate refilling

- ### Normal Operation (Yellow LED ON)

    - Adequate water level detected

    - Distance from HC-SR04 > 15cm (no overflow risk)

- ### High Water/Overflow Warning (Green LED + Buzzer ON)

    - HC-SR04 distance < 15cm from sensor

    - Prevents tank overflow

### System Logic Flow


### Schematic Diagram
