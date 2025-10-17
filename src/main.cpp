/*
 * ========================================================================
 * WATER TANK MONITORING SYSTEM - Arduino Mega 2560
 * ========================================================================
 * 
 * SYSTEM OVERVIEW:
 * This embedded system monitors water quality and tank level using:
 * 1. Water Quality Sensor (Analog) - Detects contamination via conductivity
 * 2. HC-SR04 Ultrasonic Sensor - Measures distance to water surface
 * 3. LED Indicators (Active-Low) - Visual status feedback
 * 4. Buzzer - Audio alarm for critical conditions
 * 
 * OPERATION MODES:
 * - RED LED + BUZZER:    Water contamination detected (high conductivity)
 * - GREEN LED + BUZZER:  Overflow warning (water level 0-7.5cm from top)
 * - YELLOW LED:          Half-full warning (water level 7.5-15cm from top)
 * - ALL OFF:             Tank empty or no valid sensor readings
 * 
 * TIMING ARCHITECTURE:
 * - Main loop: 1ms cycle time
 * - Water sensor reading: Every 60ms (reduces ADC blocking)
 * - HC-SR04 trigger: Every 60ms (minimum sensor requirement)
 * - HC-SR04 echo capture: Interrupt-driven (non-blocking, <25ms max)
 * 
 * HARDWARE CONNECTIONS (Arduino Mega 2560):
 * Pin 2  (PE4) - RED LED (Active-Low)
 * Pin 3  (PE5) - YELLOW LED (Active-Low)
 * Pin 4  (PG5) - GREEN LED (Active-Low)
 * Pin 5  (PE3) - BUZZER
 * Pin 7  (PH4) - HC-SR04 TRIG
 * Pin 9  (PH6) - Water Sensor Power
 * Pin 48 (PL1) - HC-SR04 ECHO (Input Capture Pin 5 - ICP5)
 * Pin A0 (PF0) - Water Sensor Analog Input
 * 
 * HC-05 CONNECTIONS:
 * HC-05 VCC  → Arduino 5V
 * HC-05 GND  → Arduino GND
 * HC-05 TXD  → Pin 19 (RX1) - Arduino receives from HC-05
 * HC-05 RXD  → Pin 18 (TX1) - Arduino transmits to HC-05
 *                              (Use voltage divider: 5V → 3.3V for HC-05)
 * - HC-05 Bluetooth Module Communication
 * - Sends JSON-formatted sensor data every 500ms
 * - Bluetooth connection via Serial1 (UART1)
 * - Baud rate: 9600 (HC-05 default)
 * 
 * JSON DATA FORMAT:
 * {
 *   "distance": 12.5,
 *   "water": 523,
 *   "status": "HALF_FULL",
 *   "alert": 0
 * }
 * 
 * AUTHOR: [Wangoda Francis]
 * DATE: [13th October, 2025]
 * VERSION: 1.0
 * ========================================================================
 */


#include <avr/io.h>          // AVR I/O port definitions
#include <avr/interrupt.h>   // Interrupt service routine support
#include <util/delay.h>      // Delay functions (_delay_ms, _delay_us)

// ========================================================================
// PIN DEFINITIONS
// ========================================================================
#define WATER_SENSOR_POWER_PIN 9  // Controls power to water sensor (not used in current implementation)

// HC-SR04 Ultrasonic Sensor Pins
#define TRIG_PIN 7         // PH4 - Trigger pulse output (starts measurement)
#define ECHO_PIN 48        // PL1 - Echo pulse input (ICP5 - Timer5 Input Capture)

// LED Output Pins (Active-Low: LOW = ON, HIGH = OFF)
#define RED_LED_PIN 2      // PE4 - Contamination indicator
#define YELLOW_LED_PIN 3   // PE5 - Half-full indicator
#define GREEN_LED_PIN 4    // PG5 - Overflow warning indicator

// Buzzer Output Pin
#define BUZZER_PIN 5       // PE3 - Audio alarm (Active-High: HIGH = ON)

// ========================================================================
// SENSOR THRESHOLDS
// ========================================================================

// Water Quality Threshold
// Logic: ADC reading > 100 = contaminated (conductive water detected)
//        ADC reading < 100 = clean or no water
// Higher conductivity (more dissolved ions) = higher ADC value
#define WATER_CONTAMINATION_THRESHOLD 100

// Distance Thresholds (measured from sensor to water surface)
// These define the three zones of water level monitoring
#define HALFWAY_LEVEL_THRESHOLD 7.5f        // 0-7.5cm = Near overflow (GREEN LED + BUZZER)
#define OVERFLOW_WARNING_THRESHOLD 15.0f    // 7.5-15cm = Half full (YELLOW LED)
                                            // >15cm = Empty or no reading (ALL OFF)

// ========================================================================
// SIGNAL FILTERING CONFIGURATION
// ========================================================================
// Number of distance samples to average for stable readings
// Reduces noise and prevents false readings from ultrasonic reflections
#define DISTANCE_SAMPLES 3

// ========================================================================
// BLUETOOTH COMMUNICATION TIMING
// ========================================================================
#define BT_SEND_INTERVAL 500  // Send data every 500ms (500 x 1ms loop cycles)

// ========================================================================
// GLOBAL VARIABLES FOR HC-SR04 MEASUREMENT
// ========================================================================
volatile uint8_t measurement_ready = 0;  // Flag: 1 = new measurement available, 0 = processing
volatile uint32_t distance_cm = 0;       // Latest distance measurement in cm
volatile uint16_t pulse_start = 0;       // Timer5 count value when echo pulse started (rising edge)
volatile uint8_t edge_count = 0;         // State tracker: 0 = waiting for rising edge
                                         //                1 = waiting for falling edge


// ========================================================================
// SIGNAL FILTERING BUFFERS
// ========================================================================

// Circular buffer for distance measurements
// Stores last 3 readings for averaging to reduce sensor noise
uint32_t distance_buffer[DISTANCE_SAMPLES] = {0};
uint8_t distance_index = 0;  // Current position in circular buffer (0-2)


// ========================================================================
// SYSTEM STATUS TRACKING
// ========================================================================
// Enumeration for system operating states
typedef enum {
    STATUS_EMPTY = 0,              // No water detected or distance > 15cm
    STATUS_HALF_FULL,              // Water level between 7.5-15cm from sensor
    STATUS_OVERFLOW_WARNING,       // Water level 0-7.5cm from sensor (near overflow)
    STATUS_CONTAMINATED            // Water quality sensor detected contamination
} SystemStatus;

SystemStatus current_status = STATUS_EMPTY;  // Current system state
uint8_t alert_active = 0;                    // Alert flag: 1 = buzzer should be on, 0 = off

// ========================================================================
// FUNCTION PROTOTYPES
// ========================================================================

void initialise_ADC();              // Configure Analog-to-Digital Converter for water sensor
void init_timer5_input_capture();   // Configure Timer5 for HC-SR04 echo pulse timing
void trigger_hcsr04();              // Send 10μs trigger pulse to HC-SR04 to start measurement
uint16_t read_water_sensor();       // Read analog value (0-1023) from water quality sensor
uint32_t get_filtered_distance();   // Calculate average distance from circular buffer
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green);  // Control LED states (0=ON, 1=OFF)
void control_buzzer(uint8_t state); // Control buzzer on/off (1=ON, 0=OFF)

// Bluetooth communication functions
void init_uart1_bluetooth();        // Initialize UART1 for HC-05 communication
void uart1_send_char(char c);       // Send single character via Bluetooth
void uart1_send_string(const char* str);  // Send null-terminated string via Bluetooth
void uart1_send_number(uint32_t num);     // Send unsigned integer as ASCII via Bluetooth
void uart1_send_float(float num);         // Send float (1 decimal place) via Bluetooth
void send_sensor_data();                  // Send JSON-formatted sensor data via Bluetooth


// ========================================================================
// MAIN PROGRAM
// ========================================================================
int main(){
    // ====================================================================
    // PORT CONFIGURATION (Direct Register Manipulation)
    // ====================================================================
    
    // Set pins as outputs by setting bits in Data Direction Registers (DDR)
    // DDR: 1 = Output, 0 = Input
    
    // Port E: RED LED (PE4), YELLOW LED (PE5), BUZZER (PE3)
    DDRE |= (1 << PE4) | (1 << PE5) | (1 << PE3);
    
    // Port G: GREEN LED (PG5)
    DDRG |= (1 << PG5);
    
    // Port H: TRIG (PH4) output, Water Sensor Power (PH6) output
    DDRH |= (1 << PH4) | (1 << PH6);
    
    // Port L: ECHO (PL1) input - Clear bit to set as input
    DDRL &= ~(1 << PL1);
    
    // Port F: Water Sensor Analog (PF0) input
    DDRF &= ~(1 << PF0);

    // ====================================================================
    // INITIALIZE OUTPUT STATES
    // ====================================================================
    
    // LEDs are Active-Low: Set HIGH to turn OFF initially
    PORTE |= (1 << PE4) | (1 << PE5);  // RED and YELLOW LEDs OFF
    PORTG |= (1 << PG5);                // GREEN LED OFF
    
    // Buzzer is Active-High: Set LOW to turn OFF initially
    PORTE &= ~(1 << PE3);               // BUZZER OFF
    
    // HC-SR04 Control Pins
    PORTH &= ~(1 << PH4);  // TRIG LOW (idle state)
    PORTH |= (1 << PH6);   // Water sensor power HIGH (powered on)

    // ====================================================================
    // INITIALIZE PERIPHERALS
    // ====================================================================
    
    initialise_ADC();              // Configure ADC for water sensor readings
    init_timer5_input_capture();   // Configure Timer5 for ultrasonic echo timing
    init_uart1_bluetooth();        // Configure UART1 for HC-05 Bluetooth communication
    
    // Enable Global Interrupts
    // Sets I-bit in Status Register (SREG)
    // Required for Timer5 Input Capture ISR to function
    sei();

    
    // ====================================================================
    // STABILIZATION DELAY
    // ====================================================================
    // Allow sensors to stabilize after power-up
    // - Water sensor capacitance needs time to charge
    // - HC-SR04 needs initialization time
    // - Bluetooth module needs time to establish connection
    _delay_ms(100);

    // ====================================================================
    // TIMING CONTROL VARIABLES
    // ====================================================================
    
    // Cycle counter for 60ms timing control (0-59, wraps at 60)
    // Used to trigger sensor measurements every 60ms
    uint8_t measurement_cycle = 0;

    // Counter for Bluetooth transmission timing (0-499, wraps at 500)
    // Each increment represents 1ms, so 500 = 500ms
    uint16_t bt_send_counter = 0;
    
    // Current water sensor reading (0-1023 ADC value)
    // Stored outside loop to maintain value between 60ms readings
    uint16_t water_level = 0;

    // ====================================================================
    // MAIN CONTROL LOOP (1ms cycle time)
    // ====================================================================
    while(1){
        
        // ================================================================
        // SENSOR READING (Every 60ms)
        // ================================================================
        // Trigger measurements at start of 60ms cycle (measurement_cycle == 0)
        if(measurement_cycle == 0){
            water_level = read_water_sensor();  // Read water quality sensor (ADC)
            trigger_hcsr04();                   // Start ultrasonic distance measurement
        }

        // Get filtered distance reading from circular buffer average
        uint32_t distance = get_filtered_distance();

        // ================================================================
        // DECISION LOGIC AND STATUS UPDATE
        // ================================================================
        // Priority order (highest to lowest):
        // 1. Water contamination (overrides all other conditions)
        // 2. Overflow warning (0-7.5cm from sensor)
        // 3. Half-full warning (7.5-15cm from sensor)
        // 4. Empty (>15cm or no reading)
        
        // CONDITION 1: Water Contamination Detected
        // water_level > 100 indicates high conductivity (contaminated water)
        if (water_level > WATER_CONTAMINATION_THRESHOLD) {
            control_LEDS(0, 1, 1);  // RED ON, YELLOW OFF, GREEN OFF
            control_buzzer(0);       // BUZZER ON (alert condition)
            current_status = STATUS_CONTAMINATED;
            alert_active = 1;        // Set alert flag for JSON transmission
            
        } 
        // CONDITION 2: Overflow Warning
        // Distance between 0-7.5cm indicates water very close to sensor (near overflow)
        else if (distance > 0 && distance <= HALFWAY_LEVEL_THRESHOLD) {
            control_LEDS(1, 1, 0);  // RED OFF, YELLOW OFF, GREEN ON
            control_buzzer(0);       // BUZZER ON (alert condition)
            current_status = STATUS_OVERFLOW_WARNING;
            alert_active = 1;        // Set alert flag for JSON transmission
            
        } 
        // CONDITION 3: Half-Full
        // Distance between 7.5-15cm indicates tank is approximately half full
        else if (distance > HALFWAY_LEVEL_THRESHOLD && distance <= OVERFLOW_WARNING_THRESHOLD) {
            control_LEDS(1, 0, 1);  // RED OFF, YELLOW ON, GREEN OFF
            control_buzzer(1);       // BUZZER OFF (no alert)
            current_status = STATUS_HALF_FULL;
            alert_active = 0;        // Clear alert flag
            
        } 
        // CONDITION 4: Empty or No Reading
        // Distance > 15cm or distance == 0 (no valid reading)
        else {
            control_LEDS(1, 1, 1);  // All LEDs OFF
            control_buzzer(1);       // BUZZER OFF (no alert)
            current_status = STATUS_EMPTY;
            alert_active = 0;        // Clear alert flag
        }

        // ================================================================
        // BLUETOOTH DATA TRANSMISSION (Every 500ms)
        // ================================================================
        bt_send_counter++;  // Increment every 1ms loop cycle
        
        // When counter reaches 500, send data and reset counter
        if(bt_send_counter >= BT_SEND_INTERVAL){
            send_sensor_data();     // Transmit JSON data via Bluetooth
            bt_send_counter = 0;    // Reset counter for next 500ms interval
        }

        // ================================================================
        // LOOP TIMING CONTROL
        // ================================================================
        _delay_ms(1);  // 1ms delay to maintain consistent loop timing
        
        // Increment measurement cycle counter
        measurement_cycle++;
        
        // Wrap counter at 60 (creates 60ms measurement interval)
        if(measurement_cycle >= 60) measurement_cycle = 0;
    }
    
    return 0;  // Never reached (infinite loop)
}

// ========================================================================
// UART1 INITIALIZATION FOR BLUETOOTH (HC-05)
// ========================================================================
// Configures UART1 (Serial1) for 9600 baud communication with HC-05
// UART1 uses pins 18 (TX1) and 19 (RX1) on Arduino Mega
// Communication format: 8 data bits, No parity, 1 stop bit (8N1)
// ========================================================================
void init_uart1_bluetooth(){
    
    // ====================================================================
    // CALCULATE BAUD RATE REGISTER VALUE
    // ====================================================================
    // Formula: UBRR = (F_CPU / (16 * BAUD)) - 1
    // Where:
    //   F_CPU = 16,000,000 Hz (Arduino Mega clock frequency)
    //   BAUD = 9600 (desired baud rate)
    //   16 = UART clock divider for normal mode
    //
    // Calculation:
    //   UBRR = (16,000,000 / (16 * 9600)) - 1
    //   UBRR = (16,000,000 / 153,600) - 1
    //   UBRR = 104.167 - 1
    //   UBRR = 103.167 ≈ 103
    //
    // Actual baud rate achieved:
    //   BAUD_actual = 16,000,000 / (16 * (103 + 1))
    //   BAUD_actual = 16,000,000 / 1,664
    //   BAUD_actual = 9,615.38 baud
    //
    // Error calculation:
    //   Error = ((9615.38 - 9600) / 9600) * 100%
    //   Error = 0.16% (acceptable - should be < 2%)
    uint16_t ubrr_value = 103;
    
    // Set baud rate registers (split 16-bit value into high and low bytes)
    UBRR1H = (uint8_t)(ubrr_value >> 8);    // High byte (upper 8 bits)
    UBRR1L = (uint8_t)ubrr_value;            // Low byte (lower 8 bits)
    
    // ====================================================================
    // CONFIGURE UART1 FRAME FORMAT (UCSR1C Register)
    // ====================================================================
    // UCSZ11:0 = 11: 8 data bits per frame
    // USBS1 = 0: 1 stop bit (default when bit not set)
    // UPM11:0 = 00: No parity (default when bits not set)
    // Result: 8N1 format (8 data bits, No parity, 1 stop bit)
    UCSR1C = (1 << UCSZ11) | (1 << UCSZ10);
    
    // ====================================================================
    // ENABLE UART1 TRANSMITTER (UCSR1B Register)
    // ====================================================================
    // TXEN1 = 1: Enable transmitter (we only need to send data to app)
    // RXEN1 = 0: Receiver disabled (we don't need to receive commands from app)
    UCSR1B = (1 << TXEN1);
}

// ========================================================================
// UART1 SEND SINGLE CHARACTER
// ========================================================================
// Transmits one byte (character) via Bluetooth
// Blocking function: waits for transmit buffer to be empty before writing
// ========================================================================
void uart1_send_char(char c){
    // Wait for transmit buffer to be empty
    // UDRE1 (UART Data Register Empty) bit is set (1) when ready to transmit
    // Loop continues while UDRE1 is 0 (buffer full)
    while(!(UCSR1A & (1 << UDRE1)));
    
    // Put data into transmit buffer (UDR1 register)
    // Hardware automatically shifts data out serially via TX1 pin
    UDR1 = c;
}

// ========================================================================
// UART1 SEND STRING
// ========================================================================
// Transmits null-terminated string via Bluetooth
// Sends characters one-by-one until '\0' is encountered
// ========================================================================
void uart1_send_string(const char* str){
    // Send characters until null terminator
    while(*str){
        uart1_send_char(*str);  // Send current character
        str++;                   // Move to next character
    }
}

// ========================================================================
// UART1 SEND INTEGER NUMBER
// ========================================================================
// Converts unsigned integer to ASCII string and transmits via Bluetooth
// Supports numbers from 0 to 4,294,967,295 (32-bit unsigned)
// Example: 12345 is sent as ASCII characters '1', '2', '3', '4', '5'
// ========================================================================
void uart1_send_number(uint32_t num){
    char buffer[12];  // Max 10 digits + sign + null terminator
    uint8_t i = 0;
    
    // Special case for zero
    if(num == 0){
        uart1_send_char('0');
        return;
    }
    
    // ====================================================================
    // CONVERT NUMBER TO STRING (REVERSED)
    // ====================================================================
    // Extract digits from right to left using modulo and division
    // Example for num = 123:
    //   Iteration 1: buffer[0] = '3', num = 12
    //   Iteration 2: buffer[1] = '2', num = 1
    //   Iteration 3: buffer[2] = '1', num = 0
    while(num > 0){
        buffer[i++] = '0' + (num % 10);  // Get last digit and convert to ASCII
        num /= 10;                        // Remove last digit
    }
    
    // ====================================================================
    // SEND DIGITS IN CORRECT ORDER (REVERSE THE BUFFER)
    // ====================================================================
    // Send from end of buffer backwards to get correct digit order
    // Example: buffer = ['3', '2', '1'] → sends '1', '2', '3'
    while(i > 0){
        uart1_send_char(buffer[--i]);
    }
}

// ========================================================================
// UART1 SEND FLOAT NUMBER
// ========================================================================
// Converts float to string with 1 decimal place and transmits via Bluetooth
// Example: 12.5 is sent as '1', '2', '.', '5'
// Range: Handles negative numbers and values up to 32-bit integer limit
// ========================================================================
void uart1_send_float(float num){
    // ====================================================================
    // HANDLE NEGATIVE NUMBERS
    // ====================================================================
    if(num < 0){
        uart1_send_char('-');  // Send minus sign
        num = -num;             // Make positive for processing
    }
    
    // ====================================================================
    // EXTRACT AND SEND INTEGER PART
    // ====================================================================
    // Cast to uint32_t truncates decimal portion
    // Example: 12.5 → int_part = 12
    uint32_t int_part = (uint32_t)num;
    uart1_send_number(int_part);
    
    // Send decimal point
    uart1_send_char('.');
    
    // ====================================================================
    // EXTRACT AND SEND ONE DECIMAL PLACE
    // ====================================================================
    // Calculation:
    //   1. Subtract integer part: (12.5 - 12) = 0.5
    //   2. Multiply by 10: 0.5 * 10 = 5.0
    //   3. Cast to integer: (uint32_t)5.0 = 5
    //   4. Convert to ASCII: '0' + 5 = '5'
    uint32_t decimal_part = (uint32_t)((num - int_part) * 10);
    uart1_send_char('0' + decimal_part);
}

// ========================================================================
// SEND SENSOR DATA VIA BLUETOOTH
// ========================================================================
// Transmits JSON-formatted sensor data for Flutter app consumption
// Format: {"distance":12.5,"water":523,"status":"HALF_FULL","alert":0}
// Newline character '\n' at end allows app to detect complete message
// ========================================================================
void send_sensor_data(){
    
    // Get current sensor readings
    uint32_t distance = get_filtered_distance();  // Averaged distance in cm
    uint16_t water = read_water_sensor();         // Raw ADC value (0-1023)
    
    // ====================================================================
    // BUILD JSON STRING
    // ====================================================================
    
    // Start JSON object
    uart1_send_string("{");
    
    // ====================================================================
    // DISTANCE FIELD
    // ====================================================================
    // Format: "distance":12.5 (float with 1 decimal place)
    uart1_send_string("\"distance\":");
    if(distance > 0){
        uart1_send_float((float)distance);  // Send valid reading
    } else {
        uart1_send_char('0');                // Send 0 for invalid/no reading
    }
    uart1_send_char(',');  // Separator for next field
    
    // ====================================================================
    // WATER SENSOR FIELD
    // ====================================================================
    // Format: "water":523 (integer 0-1023)
    uart1_send_string("\"water\":");
    uart1_send_number(water);
    uart1_send_char(',');  // Separator for next field
    
    // ====================================================================
    // STATUS FIELD
    // ====================================================================
    // Format: "status":"HALF_FULL" (string based on current_status enum)
    uart1_send_string("\"status\":\"");
    switch(current_status){
        case STATUS_CONTAMINATED:
            uart1_send_string("CONTAMINATED");
            break;
        case STATUS_OVERFLOW_WARNING:
            uart1_send_string("OVERFLOW");
            break;
        case STATUS_HALF_FULL:
            uart1_send_string("HALF_FULL");
            break;
        case STATUS_EMPTY:
        default:
            uart1_send_string("EMPTY");
            break;
    }
    uart1_send_string("\",");  // Close string and add separator
    
    // ====================================================================
    // ALERT FIELD
    // ====================================================================
    // Format: "alert":1 (integer 0 or 1)
    // 0 = No alert (normal operation)
    // 1 = Alert active (contamination or overflow warning)
    uart1_send_string("\"alert\":");
    uart1_send_char('0' + alert_active);  // Convert 0/1 to ASCII '0'/'1'
    
    // End JSON object with newline for parsing
    // Newline allows Flutter app to detect complete message
    uart1_send_string("}\n");
}

// ========================================================================
// TIMER5 INPUT CAPTURE INITIALIZATION
// ========================================================================
// Configures Timer5 for precise HC-SR04 echo pulse timing
// Uses Input Capture Unit (ICU) to timestamp rising/falling edges
// Timer5 is 16-bit counter running at 8MHz (prescaler = 8)
// ========================================================================
void init_timer5_input_capture(){
    
    // ====================================================================
    // TCCR5A: Timer/Counter Control Register A
    // ====================================================================
    // Set to 0 (no PWM, normal port operation)
    TCCR5A = 0;
    
    // ====================================================================
    // TCCR5B: Timer/Counter Control Register B
    // ====================================================================
    // CS51 = 1: Set prescaler to 8
    // Timer clock = 16MHz / 8 = 2MHz
    // Timer resolution = 1 / 2MHz = 0.5μs per tick
    TCCR5B = (1 << CS51);
    
    // ====================================================================
    // TIMSK5: Timer Interrupt Mask Register
    // ====================================================================
    // ICIE5 = 1: Enable Input Capture Interrupt
    // ISR(TIMER5_CAPT_vect) will be called on each edge detection
    TIMSK5 = (1 << ICIE5);
    
    // ====================================================================
    // TCCR5B: Input Capture Edge Select
    // ====================================================================
    // ICES5 = 1: Capture on rising edge (start of echo pulse)
    // Will be toggled to falling edge after first capture
    TCCR5B |= (1 << ICES5);
    
    // ====================================================================
    // RESET TIMER AND STATE
    // ====================================================================
    TCNT5 = 0;        // Clear timer counter
    edge_count = 0;   // Initialize state machine (waiting for rising edge)
}

// ========================================================================
// TRIGGER HC-SR04 ULTRASONIC SENSOR
// ========================================================================
// Sends 10μs trigger pulse to initiate distance measurement
// HC-SR04 responds by sending 8 ultrasonic pulses at 40kHz
// Echo pulse width is proportional to distance
// ========================================================================
void trigger_hcsr04(){
    
    // Reset measurement state
    edge_count = 0;           // Reset state machine to wait for rising edge
    measurement_ready = 0;    // Clear measurement complete flag
    
    // ====================================================================
    // CLEAR INPUT CAPTURE FLAG
    // ====================================================================
    // ICF5 = 1: Clear Input Capture Flag (write 1 to clear)
    // Ensures any previous capture events don't trigger false interrupts
    TIFR5 = (1 << ICF5);
    
    // ====================================================================
    // RESET TIMER AND CONFIGURE FOR RISING EDGE
    // ====================================================================
    TCNT5 = 0;                 // Reset timer counter to 0
    TCCR5B |= (1 << ICES5);    // Set to capture rising edge first
    
    // ====================================================================
    // GENERATE 10μs TRIGGER PULSE
    // ====================================================================
    // HC-SR04 requires minimum 10μs HIGH pulse on TRIG pin
    PORTH |= (1 << PH4);   // Set TRIG HIGH
    _delay_us(10);         // Wait 10 microseconds
    PORTH &= ~(1 << PH4);  // Set TRIG LOW
    
    // HC-SR04 now sends echo pulse, ISR will capture timing
}

// ========================================================================
// TIMER5 INPUT CAPTURE INTERRUPT SERVICE ROUTINE (ISR)
// ========================================================================
// Called automatically on each edge of echo pulse (rising and falling)
// Calculates distance from pulse width using sound speed formula
// ========================================================================
ISR(TIMER5_CAPT_vect){
    
    // ====================================================================
    // STATE 0: RISING EDGE DETECTED (START OF ECHO PULSE)
    // ====================================================================
    if(edge_count == 0){
        
        // Capture timer value at rising edge
        // ICR5 register contains timer count at moment of edge detection
        pulse_start = ICR5;
        
        // Move to next state (wait for falling edge)
        edge_count = 1;
        
        // Change to capture falling edge next
        // ICES5 = 0: Capture on falling edge (end of echo pulse)
        TCCR5B &= ~(1 << ICES5);
    } 
    
    // ====================================================================
    // STATE 1: FALLING EDGE DETECTED (END OF ECHO PULSE)
    // ====================================================================
    else if(edge_count == 1){
        
        // Capture timer value at falling edge
        uint16_t pulse_end = ICR5;
        uint16_t pulse_ticks;
        
        // ================================================================
        // CALCULATE PULSE WIDTH IN TIMER TICKS
        // ================================================================
        // Handle timer overflow case (16-bit counter wraps at 65535)
        if(pulse_end >= pulse_start){
            // Normal case: no overflow occurred
            pulse_ticks = pulse_end - pulse_start;
        } else {
            // Overflow case: timer wrapped from 65535 to 0
            // Calculate: (ticks to overflow) + (ticks after overflow) + 1
            pulse_ticks = (0xFFFF - pulse_start) + pulse_end + 1;
        }
        
        // ================================================================
        // CONVERT TIMER TICKS TO MICROSECONDS
        // ================================================================
        // Timer runs at 2MHz (0.5μs per tick)
        // Time (μs) = ticks * 0.5 = ticks / 2 = ticks >> 1
        // Right shift by 1 is equivalent to dividing by 2
        uint32_t pulse_us = (uint32_t)pulse_ticks >> 1;
        
        // ================================================================
        // VALIDATE PULSE WIDTH AND CALCULATE DISTANCE
        // ================================================================
        // HC-SR04 valid range: 150μs to 23500μs
        //   150μs = 2.58cm minimum distance
        //   23500μs = 405cm maximum distance
        // Reject readings outside this range (likely noise or invalid)
        if(pulse_us >= 150 && pulse_us <= 23500){
            
            // ============================================================
            // DISTANCE CALCULATION
            // ============================================================
            // Formula: Distance (cm) = (Pulse Width (μs) / 58)
            //
            // Derivation:
            //   - Speed of sound = 343 m/s at 20°C
            //   - Convert to cm/μs: 343 m/s = 34,300 cm/s = 0.0343 cm/μs
            //   - Distance = Speed × Time
            //   - Round trip distance = 0.0343 cm/μs × pulse_us
            //   - One-way distance = Round trip / 2
            //   - Distance = (0.0343 × pulse_us) / 2
            //   - Distance = 0.01715 × pulse_us
            //   - Distance = pulse_us / 58.31
            //   - Simplified: Distance ≈ pulse_us / 58
            //
            // Example calculation for pulse_us = 1160μs:
            //   Distance = 1160 / 58 = 20 cm
            //
            uint32_t new_distance = pulse_us / 58;
            
            // ============================================================
            // UPDATE CIRCULAR BUFFER
            // ============================================================
            // Store new reading in buffer at current index position
            distance_buffer[distance_index] = new_distance;
            
            // Increment index and wrap around using modulo
            // Example: 0 → 1 → 2 → 0 → 1 → 2 (circular)
            distance_index = (distance_index + 1) % DISTANCE_SAMPLES;
            
            // Update latest distance (used if buffer not full yet)
            distance_cm = new_distance;
        } else {
            // Invalid pulse width - set distance to 0 (no reading)
            distance_cm = 0;
        }
        
        // ================================================================
        // RESET STATE FOR NEXT MEASUREMENT
        // ================================================================
        measurement_ready = 1;      // Signal that measurement is complete
        edge_count = 0;             // Reset state machine
        TCCR5B |= (1 << ICES5);     // Configure for rising edge next time
    }
}

// ========================================================================
// GET FILTERED DISTANCE
// ========================================================================
// Returns average of valid readings in circular buffer
// Provides more stable reading by filtering out noise spikes
// ========================================================================
uint32_t get_filtered_distance(){
    uint32_t sum = 0;       // Sum of all valid readings
    uint8_t valid_count = 0; // Count of non-zero readings
    
    // ====================================================================
    // SUM ALL VALID READINGS IN BUFFER
    // ====================================================================
    // Loop through all 3 buffer positions
    for(uint8_t i = 0; i < DISTANCE_SAMPLES; i++){
        // Only include non-zero values (valid readings)
        if(distance_buffer[i] > 0){
            sum += distance_buffer[i];
            valid_count++;
        }
    }
    
    // ====================================================================
    // CALCULATE AND RETURN AVERAGE
    // ====================================================================
    // If we have at least one valid reading, return average
    // Example: buffer = [10, 12, 11]
    //   sum = 33, valid_count = 3
    //   average = 33 / 3 = 11 cm
    if(valid_count > 0){
        return sum / valid_count;
    }
    
    // If no valid readings in buffer, return most recent raw distance
    return distance_cm;
}

// ========================================================================
// INITIALIZE ADC (ANALOG-TO-DIGITAL CONVERTER)
// ========================================================================
// Configures ADC for reading water quality sensor on A0 (PF0)
// ADC converts 0-5V analog signal to 10-bit digital value (0-1023)
// ========================================================================
void initialise_ADC(){
    
    // ====================================================================
    // ADMUX: ADC Multiplexer Selection Register
    // ====================================================================
    // REFS0 = 1: Use AVCC (5V) as voltage reference
    // REFS1 = 0: (default) Use AVCC reference
    // MUX[4:0] = 00000: Select ADC0 (A0 pin) as input
    // Right-adjusted result (10 bits in ADCL and ADCH)
    ADMUX = (1 << REFS0);
    
    // ====================================================================
    // ADCSRA: ADC Control and Status Register A
    // ====================================================================
    // ADEN = 1: Enable ADC
    // ADPS2:0 = 111: Set prescaler to 128
    //
    // ADC Clock Calculation:
    //   ADC_Clock = F_CPU / Prescaler
    //   ADC_Clock = 16MHz / 128
    //   ADC_Clock = 125kHz
    //
    // Why 125kHz?
    //   - ADC requires clock between 50kHz-200kHz for 10-bit accuracy
    //   - 125kHz is optimal for maximum accuracy
    //
    // Conversion Time:
    //   - First conversion: 25 ADC clock cycles
    //   - Subsequent: 13 ADC clock cycles
    //   - Time = 13 / 125kHz = 104μs per reading
    ADCSRA = (1 << ADEN) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);
}

// ========================================================================
// READ WATER SENSOR
// ========================================================================
// Reads analog voltage from water quality sensor on A0
// Returns 10-bit value (0-1023) representing water conductivity
// Higher values indicate higher conductivity (contaminated water)
// ========================================================================
uint16_t read_water_sensor(){
    
    // ====================================================================
    // SELECT ADC CHANNEL
    // ====================================================================
    // Clear lower 4 bits (MUX[3:0]) and set to 0x00 (ADC0/A0)
    // Preserves REFS bits (voltage reference selection)
    // 0xF0 = 11110000 (keeps upper 4 bits, clears lower 4)
    // 0x00 = channel A0
    ADMUX = (ADMUX & 0xF0) | 0x00;
    
    // ====================================================================
    // START CONVERSION
    // ====================================================================
    // ADSC = 1: Start ADC conversion
    // Hardware automatically clears this bit when conversion complete
    ADCSRA |= (1 << ADSC);
    
    // ====================================================================
    // WAIT FOR CONVERSION COMPLETE
    // ====================================================================
    // Poll ADSC bit - stays HIGH during conversion, goes LOW when done
    // Typical conversion time: ~104μs
    while (ADCSRA & (1 << ADSC));
    
    // ====================================================================
    // RETURN CONVERSION RESULT
    // ====================================================================
    // ADC register contains 10-bit result (0-1023)
    // Maps 0V → 0, 5V → 1023
    // For water sensor:
    //   - Low values (< 100): Clean water or no water
    //   - High values (> 100): Contaminated water (high conductivity)
    return ADC;
}

// ========================================================================
// CONTROL LEDs
// ========================================================================
// Controls three LEDs using Active-Low logic
// Parameters: 0 = LED ON, 1 = LED OFF
// ========================================================================
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green){
    
    // ====================================================================
    // RED LED CONTROL (PE4)
    // ====================================================================
    if(!red)
        PORTE &= ~(1 << PE4);  // Clear bit → LOW → LED ON
    else
        PORTE |= (1 << PE4);   // Set bit → HIGH → LED OFF
    
    // ====================================================================
    // YELLOW LED CONTROL (PE5)
    // ====================================================================
    if(!yellow)
        PORTE &= ~(1 << PE5);  // Clear bit → LOW → LED ON
    else
        PORTE |= (1 << PE5);   // Set bit → HIGH → LED OFF
    
    // ====================================================================
    // GREEN LED CONTROL (PG5)
    // ====================================================================
    if(!green)
        PORTG &= ~(1 << PG5);  // Clear bit → LOW → LED ON
    else
        PORTG |= (1 << PG5);   // Set bit → HIGH → LED OFF
}

// ========================================================================
// CONTROL BUZZER
// ========================================================================
// Controls buzzer using Active-High logic
// Parameter: 1 = Buzzer OFF, 0 = Buzzer ON
// Note: Parameter logic matches LED convention for consistency in main code
// ========================================================================
void control_buzzer(uint8_t state){
    if (state) {
        // state = 1 → Buzzer OFF
        PORTE |= (1 << PE3);   // Set bit → HIGH → Buzzer OFF
    } else {
        // state = 0 → Buzzer ON
        PORTE &= ~(1 << PE3);  // Clear bit → LOW → Buzzer ON
    }
}