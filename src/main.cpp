#include <avr/io.h>
#include <avr/interrupt.h>
#include <util/delay.h>
#include <stdio.h> // For sprintf

#define TRIG_PIN 7      // PH4 - Trigger pulse output (starts measurement)
#define ECHO_PIN 48     // PL1 - Echo pulse input (ICP5 - Timer5 Input Capture)

#define RED_LED_PIN 2    // PE4 - Contamination indicator
#define YELLOW_LED_PIN 3 // PE5 - Half-full indicator
#define GREEN_LED_PIN 4  // PG5 - Overflow warning indicator

#define BUZZER_PIN 5 // PE3 - Audio alarm (Active-Low: LOW = ON)

#define WATER_CONTAMINATION_THRESHOLD 100

// --- MODIFIED THRESHOLDS ---
// Define the total measurable height of the container (H in your formula)
// This is based on the previous 15.0f threshold, which represented "empty".
#define CONTAINER_HEIGHT_CM 15.0f

// Define thresholds based on percentage (L/H * 100)
// The old logic triggered "OVERFLOW" at D <= 7.5cm.
// L = 15.0 - 7.5 = 7.5cm. Percentage = (7.5 / 15.0) * 100 = 50.0%
#define LEVEL_OVERFLOW_PERCENT_THRESHOLD 50.0f

// Define a threshold for what is considered "empty" (e.g., 5%)
#define LEVEL_EMPTY_PERCENT_THRESHOLD 5.0f
// --- END MODIFICATIONS ---

// #define DISTANCE_SAMPLES 3 // <-- Removed
#define BT_SEND_INTERVAL 10 // Send data every 500ms (500 x 1ms loop cycles)

volatile uint8_t measurement_ready = 0;   // Flag: 1 = new measurement available, 0 = processing
volatile uint32_t distance_cm = 0;        // Latest distance measurement in cm
volatile uint16_t pulse_start = 0;        // Timer5 count value when echo pulse started (rising edge)
volatile uint8_t edge_count = 0;          // State tracker: 0 = waiting for rising edge
                                          //                1 = waiting for falling edge

// uint32_t distance_buffer[DISTANCE_SAMPLES] = {0}; // <-- Removed
// uint8_t distance_index = 0; // <-- Removed

// Timestamp counter (milliseconds since startup)
volatile uint32_t system_time_ms = 0;

// status info
typedef enum {
    STATUS_EMPTY = 0,
    STATUS_HALF_FULL,
    STATUS_OVERFLOW_WARNING,
    STATUS_CONTAMINATED
} SystemStatus;

SystemStatus current_status = STATUS_EMPTY;
uint8_t alert_active = 0;

void initialise_ADC();
void init_timer5_input_capture();
void trigger_hcsr04();
uint16_t read_water_sensor();
// uint32_t get_filtered_distance(); // <-- Removed
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green);
void control_buzzer(uint8_t state);

// Simplified Bluetooth communication functions
void init_uart1_bluetooth();
// MODIFIED: Send float percentage instead of uint32_t distance
void send_bluetooth_data(float percentage, uint16_t water, const char* status, uint8_t alert, uint32_t timestamp);

int main(){
    // Port E: RED LED (PE4), YELLOW LED (PE5), BUZZER (PE3)
    DDRE |= (1 << PE4) | (1 << PE5) | (1 << PE3);
    
    // Port G: GREEN LED (PG5)
    DDRG |= (1 << PG5);
    
    // Port H: TRIG (PH4) output
    DDRH |= (1 << PH4);
    
    // Port L: ECHO (PL1) input - Clear bit to set as input
    DDRL &= ~(1 << PL1);
    
    // Port F: Water Sensor Analog (PF0) input
    DDRF &= ~(1 << PF0);
    
    // LEDs are Active-Low: Set HIGH to turn OFF initially
    PORTE |= (1 << PE4) | (1 << PE5);
    PORTG |= (1 << PG5);
    
    // Buzzer is Active-Low: Set HIGH to turn OFF initially
    PORTE |= (1 << PE3); // BUZZER OFF
    
    // HC-SR04 Control Pins
    PORTH &= ~(1 << PH4); // TRIG LOW (idle state)
        
    initialise_ADC();
    init_timer5_input_capture();
    init_uart1_bluetooth();
    
    sei();

    // Stabilization delay
    _delay_ms(100);
    
    // Used to trigger sensor measurements every 60ms
    uint8_t measurement_cycle = 0;

    // Each increment represents 1ms, so 500 = 500ms
    uint16_t bt_send_counter = 0;
    
    // Current water sensor reading (0-1023 ADC value)
    uint16_t water_level = 0;
    
    while(1){
        if(measurement_cycle == 0){
            water_level = read_water_sensor(); // Read water quality sensor (ADC)
            trigger_hcsr04();                  // Start ultrasonic distance measurement
        }

        // Get the latest raw distance measurement
        // Copy volatile variable to a local one for stable calculations
        uint32_t distance = distance_cm;
        
        // --- START: Calculate Level Percentage ---
        // D = Echo distance from sensor to water
        float distance_cm_f = (float)distance;
        
        // L = Liquid level from bottom (H - D)
        float liquid_level_cm = CONTAINER_HEIGHT_CM - distance_cm_f;

        // Clamp liquid level to be between 0 and H
        if (liquid_level_cm < 0.0f) {
            liquid_level_cm = 0.0f;
        }
        // Handle cases where sensor distance is very small (e.g., dead zone)
        if (liquid_level_cm > CONTAINER_HEIGHT_CM) {
            liquid_level_cm = CONTAINER_HEIGHT_CM;
        }

        // Calculate percentage: (L / H) * 100
        float level_percentage = 0.0f;
        if (CONTAINER_HEIGHT_CM > 0.0f) { // Avoid divide-by-zero
            level_percentage = (liquid_level_cm / CONTAINER_HEIGHT_CM) * 100.0f;
        }
        // --- END: Calculate Level Percentage ---

        
        // --- MODIFIED: Logic now uses level_percentage ---
        if (water_level > WATER_CONTAMINATION_THRESHOLD) {
            control_LEDS(0, 1, 1); // RED ON
            control_buzzer(0);     // Buzzer ON
            current_status = STATUS_CONTAMINATED;
            alert_active = 1;
            
        }
        // Check for overflow (e.g., >= 50%)
        else if (level_percentage >= LEVEL_OVERFLOW_PERCENT_THRESHOLD) {
            control_LEDS(1, 1, 0); // GREEN ON
            control_buzzer(0);     // Buzzer ON
            current_status = STATUS_OVERFLOW_WARNING;
            alert_active = 1;
            
        }
        // Check for "half full" (e.g., > 5% and < 50%)
        else if (level_percentage > LEVEL_EMPTY_PERCENT_THRESHOLD) {
            control_LEDS(1, 0, 1); // YELLOW ON
            control_buzzer(1);     // Buzzer OFF
            current_status = STATUS_HALF_FULL;
            alert_active = 0;
            
        }
        // Otherwise, tank is "empty" (e.g., <= 5%)
        else {
            control_LEDS(1, 1, 1); // All LEDs OFF
            control_buzzer(1);     // Buzzer OFF
            current_status = STATUS_EMPTY;
            alert_active = 0;
        }
        // --- END MODIFIED LOGIC ---

        
        bt_send_counter++; // Increment every 1ms loop cycle
        system_time_ms++;  // Increment timestamp counter
        
        // When counter reaches 500, send data and reset counter
        if(bt_send_counter >= BT_SEND_INTERVAL){
            // Get status string based on current status
            const char* status_string;
            switch(current_status){
                case STATUS_CONTAMINATED:
                    status_string = "CONTAMINATED";
                    break;
                case STATUS_OVERFLOW_WARNING:
                    status_string = "OVERFLOW";
                    break;
                case STATUS_HALF_FULL:
                    status_string = "HALF_FULL";
                    break;
                case STATUS_EMPTY:
                default:
                    status_string = "EMPTY";
                    break;
            }
            
            // MODIFIED: Send level_percentage (float) instead of distance (uint32_t)
            send_bluetooth_data(level_percentage, water_level, status_string, alert_active, system_time_ms);
            bt_send_counter = 0;
        }

        
        _delay_ms(1); // 1ms delay to maintain consistent loop timing
        
        measurement_cycle++;
                
        if(measurement_cycle >= 60) measurement_cycle = 0;
    }
    
    return 0; // Never reached (infinite loop)
}


// ============================================================================
//                       BLUETOOTH COMMUNICATION
// ============================================================================

// Initialize UART1 for Bluetooth communication at 9600 baud
void init_uart1_bluetooth(){
    // Calculate baud rate: UBRR = (F_CPU / (16 * BAUD)) - 1
    // For 16MHz clock and 9600 baud: UBRR = (16000000 / (16 * 9600)) - 1 = 103
    uint16_t ubrr_value = 103;
    
    UBRR1H = (uint8_t)(ubrr_value >> 8);
    UBRR1L = (uint8_t)ubrr_value;
    
    UCSR1C = (1 << UCSZ11) | (1 << UCSZ10); // 8 data bits, no parity, 1 stop bit
    
    UCSR1B = (1 << TXEN1); // Enable transmitter
}

// MODIFIED: Function signature changed to accept float 'percentage'
// This function builds the entire JSON message in a buffer, then sends it all at once
void send_bluetooth_data(float percentage, uint16_t water, const char* status, uint8_t alert, uint32_t timestamp){
    char buffer[120]; // Buffer to hold complete JSON string (increased size for timestamp)
    
    // --- MODIFICATION TO FIX SPRINTF WARNING ---
    // avr-libc sprintf often doesn't support %f by default.
    // We manually convert the float to integer and fractional parts.
    // Example: 50.1 -> int_part = 50, frac_part = 1
    
    // Get the integer part (e.g., 50)
    int int_part = (int)percentage;
    
    // Get the first fractional digit (e.g., (50.1 - 50) * 10 = 1)
    // Add 0.5f for correct rounding before casting to int
    int frac_part = (int)((percentage - (float)int_part) * 10.0f + 0.5f);

    // Handle potential rollover from rounding (e.g., 50.99 -> 50.10)
    if (frac_part >= 10) {
        frac_part = 0;
        int_part += 1;
    }

    // MODIFIED:
    // - Changed format specifier from %.1f to %d.%d
    // - Passed the integer and fractional parts
    // Format: {"timestamp":12345,"percentage":50.1,"water":45,"status":"EMPTY","alert":0}
    sprintf(buffer, "{\"timestamp\":%lu,\"percentage\":%d.%d,\"water\":%u,\"status\":\"%s\",\"alert\":%u}\n",
            timestamp, int_part, frac_part, water, status, alert);
    // --- END MODIFICATION ---
    
    // Send the complete string via UART
    char* ptr = buffer;
    while(*ptr){
        // Wait for transmit buffer to be ready
        while(!(UCSR1A & (1 << UDRE1)));
        // Send character
        UDR1 = *ptr;
        ptr++;
    }
}


// ============================================================================
//                     ULTRASONIC SENSOR (HC-SR04)
// ============================================================================

void init_timer5_input_capture(){
    //  normal port operation
    TCCR5A = 0;
    
    
    // CS51 = 1: Set prescaler to 8
    // 16,000,000 / 8 = 2,000,000 ticks per second (2MHz)
    // Each tick is 0.5 microseconds
    TCCR5B = (1 << CS51);
    
    // ICIE5 = 1: Enable Input Capture Interrupt
    TIMSK5 = (1 << ICIE5);
    
    
    // TCCR5B: Input Capture Edge Select
    // ICES5 = 1: Capture on rising edge (start of echo pulse)
    TCCR5B |= (1 << ICES5);
    

    TCNT5 = 0;     // Clear timer counter
    edge_count = 0; // Initialize state machine (waiting for rising edge)
}


// Sends 10μs trigger pulse to initiate distance measurement
void trigger_hcsr04(){
    
    edge_count = 0;        // Reset state machine to wait for rising edge
    measurement_ready = 0; // Clear measurement complete flag
    

    // ICF5 = 1: Clear Input Capture Flag (write 1 to clear)
    TIFR5 = (1 << ICF5);
    
    
    TCNT5 = 0;             // Reset timer counter to 0
    TCCR5B |= (1 << ICES5); // Set to capture rising edge first
    
    
    // Generate 10μs trigger pulse
    PORTH |= (1 << PH4);  // Set TRIG HIGH
    _delay_us(10);        // Wait 10 microseconds
    PORTH &= ~(1 << PH4); // Set TRIG LOW
}



ISR(TIMER5_CAPT_vect){
    
    // Rising edge detected (echo pulse started)
    if(edge_count == 0){
        
        pulse_start = ICR5; // Capture timer value at rising edge
        edge_count = 1;     // Move to next state (wait for falling edge)
        TCCR5B &= ~(1 << ICES5); // Change to capture falling edge next
    }
    
    
    // Falling edge detected (echo pulse ended)
    else if(edge_count == 1){
        
        uint16_t pulse_end = ICR5; // Capture timer value at falling edge
        uint16_t pulse_ticks;
        
        

        // Handle timer overflow case (16-bit counter wraps at 65535)
        if(pulse_end >= pulse_start){
            pulse_ticks = pulse_end - pulse_start; // Normal case
        } else {
            pulse_ticks = (0xFFFF - pulse_start) + pulse_end + 1; // Overflow case
        }
        
        // Convert timer ticks to microseconds
        // Timer runs at 2MHz (0.5μs per tick) -> divide by 2
        uint32_t pulse_us = (uint32_t)pulse_ticks >> 1;
        
        
        // Validate pulse width (HC-SR04 valid range: 150μs to 23500μs)
        // 23500μs / 58 = ~405cm (max range)
        if(pulse_us >= 150 && pulse_us <= 23500){
            
            // Calculate distance in cm
            // Formula: Distance (cm) = (Pulse Width (μs) / 58)
            uint32_t new_distance = pulse_us / 58;
            
            // Update the raw distance variable directly
            distance_cm = new_distance;
        } else {
            // Invalid pulse width (out of range)
            distance_cm = 0;
        }
        
        
        measurement_ready = 1;     // Signal that measurement is complete
        edge_count = 0;            // Reset state machine
        TCCR5B |= (1 << ICES5);   // Configure for rising edge next time
    }
}


// ============================================================================
//                     WATER QUALITY SENSOR (ADC)
// ============================================================================

void initialise_ADC(){
    // REFS0 = 1: Use AVCC (5V) as voltage reference
    ADMUX = (1 << REFS0);
    
    // ADEN = 1: Enable ADC
    // ADPS2:0 = 111: Set prescaler to 128 (ADC Clock = 16MHz / 128 = 125kHz)
    ADCSRA = (1 << ADEN) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);
}

uint16_t read_water_sensor(){
    // Select ADC0 channel (A0)
    ADMUX = (ADMUX & 0xF0) | 0x00;
    
    // Start conversion
    ADCSRA |= (1 << ADSC);
    
    // Wait for conversion to complete
    while (ADCSRA & (1 << ADSC));
    
    // Return ADC value
    return ADC;
}


// ============================================================================
//                     LED AND BUZZER CONTROL
// ============================================================================

void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green){
    // LEDs are Active-Low: 0 = ON, 1 = OFF
    if(!red) PORTE &= ~(1 << PE4); else PORTE |= (1 << PE4);
    if(!yellow) PORTE &= ~(1 << PE5); else PORTE |= (1 << PE5);
    if(!green) PORTG &= ~(1 << PG5);  else PORTG |= (1 << PG5);
}

void control_buzzer(uint8_t state){
    // Buzzer is Active-Low: 0 = ON, 1 = OFF
    if (state) PORTE |= (1 << PE3); else  PORTE &= ~(1 << PE3);
}

