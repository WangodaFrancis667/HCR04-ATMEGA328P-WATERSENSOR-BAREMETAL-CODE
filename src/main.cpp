#include <avr/io.h>
#include <avr/interrupt.h>
#include<util/delay.h>

// This uses timer1 interrupt

// Defining constants and pin mappings
// Water level sensor
#define WATER_SENSOR_POWER_PIN 9   // PB1 (Digital Pin 9) - Power control for water sensor

// HC-SR04 ultrasonic sensor port mapping
#define TRIG_PIN 7                 // PD7 (Digital Pin 7) - Trigger pulse output
#define ECHO_PIN 0                 // PB0 (Digital Pin 8, ICP1) - Echo input for Timer1 Input Capture

// Visual and audio feedback port mapping
#define RED_LED_PIN 2              // PD2 (Digital Pin 2) - Water contamination indicator
#define YELLOW_LED_PIN 3           // PD3 (Digital Pin 3) - Halfway level indicator (15cm)
#define GREEN_LED_PIN 4            // PD4 (Digital Pin 4) - Near overflow warning (13cm)
#define BUZZER_PIN 5               // PD5 (Digital Pin 5) - Audio alert system

// Petrol tank level thresholds for system state determination
#define WATER_CONTAMINATION_THRESHOLD 100    // ADC value detecting water in petrol (0-1023 range)
#define TANK_HEIGHT_CM 15                    // Total tank height in centimeters
#define HALFWAY_LEVEL_THRESHOLD 7            // Distance in cm from HC-SR04 for halfway tank level (7.5cm, rounded down)
#define OVERFLOW_WARNING_THRESHOLD 13        // Distance in cm from HC-SR04 for near overflow warning (13cm)

// Global variables for Timer1 Input Capture interrupt-based HC-SR04 measurement
volatile uint32_t echo_start_time = 0;           // Timer1 count value when echo pulse starts (rising edge)
volatile uint32_t echo_duration = 0;             // Duration of echo pulse in Timer1 ticks
volatile uint8_t echo_measurement_complete = 0;  // Flag indicating measurement completion

// function declarations
void initialise_ADC();
uint16_t read_water_sensor();
void send_trigger_pulse();
uint32_t measure_echo_pulse();
uint32_t read_HCSR04_distance();
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green);
void control_buzzer(uint8_t state);
void delay_ms(uint16_t ms);
void init_timer1();

int main(){
    // ========== SYSTEM INITIALIZATION ==========
    
    // Configure PORTD pins (PD0-PD7) as outputs for LEDs, buzzer, and trigger
    DDRD |= (1 << RED_LED_PIN) | (1 << YELLOW_LED_PIN) | (1 << GREEN_LED_PIN) |
            (1 << BUZZER_PIN) | (1 << TRIG_PIN);

    // Configure PORTB pins
    DDRB |= (1 << WATER_SENSOR_POWER_PIN);  // PB1 (Pin 9) as output for water sensor power
    DDRB &= ~(1 << ECHO_PIN);               // PB0 (Pin 8, ICP1) as input for HC-SR04 echo

    // Configure PORTC pins - PC0 (A0) as input for water level sensor analog reading
    DDRC &= ~(1 << PC0);

    // Initialize all PORTD outputs to LOW state (LEDs off, buzzer off, trigger low)
    PORTD &= ~((1 << RED_LED_PIN) | (1 << YELLOW_LED_PIN) | (1 << GREEN_LED_PIN) |
               (1 << BUZZER_PIN) | (1 << TRIG_PIN));
    
    // Turn ON power to water level sensor (PB1/Pin 9)
    PORTB |= (1 << WATER_SENSOR_POWER_PIN);

    // Initialize ADC for water level sensor readings
    initialise_ADC();
    
    // Initialize Timer1 for Input Capture mode (HC-SR04 echo measurement)
    init_timer1();
    
    // Enable global interrupts for Timer1 Input Capture functionality
    sei();
    
    // ========== MAIN CONTROL LOOP ==========
    while(1){
        // Read analog water level sensor (0-1023 ADC range)
        uint16_t water_level = read_water_sensor();

        // Read distance from HC-SR04 ultrasonic sensor (in cm)
        uint32_t distance = read_HCSR04_distance();

        // ========== PETROL TANK MONITORING DECISION LOGIC ==========
        if (water_level < WATER_CONTAMINATION_THRESHOLD) {
            // WATER CONTAMINATION DETECTED: Water present in petrol tank - critical issue
            control_LEDS(1, 0, 0);  // Red LED ON (water contamination alert)
            control_buzzer(1);      // Buzzer ON (critical audio alert)
        } else if (distance <= OVERFLOW_WARNING_THRESHOLD && distance > 0) {
            // NEAR OVERFLOW: Petrol tank almost full - stop filling immediately
            control_LEDS(0, 0, 1);  // Green LED ON (near overflow warning at 13cm)
            control_buzzer(1);      // Buzzer ON (prevent overflow)
        } else if (distance <= HALFWAY_LEVEL_THRESHOLD && distance > OVERFLOW_WARNING_THRESHOLD) {
            // HALFWAY LEVEL: Petrol tank at halfway point (7.5cm) - continue filling with caution
            control_LEDS(0, 1, 0);  // Yellow LED ON (halfway status at 7.5cm)
            control_buzzer(0);      // Buzzer OFF (normal filling)
        } else {
            // NORMAL OPERATION: Tank has adequate space - safe to fill
            control_LEDS(0, 1, 0);  // Yellow LED ON (normal status)
            control_buzzer(0);      // Buzzer OFF (no alert needed)
        }

        // System update interval - 50ms between sensor readings for faster response
        delay_ms(50);
    }
    return 0;
}

// ========== TIMER1 INPUT CAPTURE INTERRUPT SERVICE ROUTINE ==========
// This ISR handles HC-SR04 echo pulse measurement using hardware timing
ISR(TIMER1_CAPT_vect) {
    if(TCCR1B & (1 << ICES1)) { 
        // RISING EDGE DETECTED: Echo pulse starts
        // ICES1 = 1 means we're configured to capture on rising edge
        echo_start_time = ICR1;     // Capture Timer1 count value when echo goes HIGH
        
        // Switch to capture falling edge for pulse end detection
        TCCR1B &= ~(1 << ICES1);    // Clear ICES1 to capture on falling edge next
        
    } else { 
        // FALLING EDGE DETECTED: Echo pulse ends
        // ICES1 = 0 means we're configured to capture on falling edge
        echo_duration = ICR1 - echo_start_time;    // Calculate pulse duration in timer ticks
        echo_measurement_complete = 1;             // Signal main loop that measurement is ready
        
        // Switch back to capture rising edge for next measurement cycle
        TCCR1B |= (1 << ICES1);    // Set ICES1 to capture on rising edge next
    }
}

// ========== TIMER1 INITIALIZATION FOR INPUT CAPTURE ==========
// Configure Timer1 for precision HC-SR04 echo pulse measurement
void init_timer1(void) {
    // Configure Timer1 Control Register A - Normal mode operation
    TCCR1A = 0;    // WGM11:10 = 00 (Normal mode, no PWM)
    
    // Configure Timer1 Control Register B - Prescaler and Input Capture settings
    // Prescaler options analysis:
    // - Prescaler 1:  16MHz/1  = 16MHz,   0.0625μs per tick (too fast, overflow issues)
    // - Prescaler 8:  16MHz/8  = 2MHz,    0.5μs per tick    ← CHOSEN (best resolution)
    // - Prescaler 64: 16MHz/64 = 250kHz,  4μs per tick      (good but lower resolution)
    TCCR1B = (1 << CS11);    // Set prescaler to 8 (CS12:10 = 010)
    
    // Input Capture configuration
    TCCR1B |= (1 << ICNC1);    // Enable Input Capture Noise Canceler (filters noise)
    TCCR1B |= (1 << ICES1);    // Set Input Capture Edge Select (start with rising edge)
    
    // Enable Timer1 Input Capture Interrupt
    TIMSK1 |= (1 << ICIE1);    // Enable Input Capture interrupt (calls ISR on edge detection)
    
    // Initialize Timer1 counter to zero
    TCNT1 = 0;    // Clear counter for clean start
}

// ========== ADC INITIALIZATION ==========
// Configure ADC for water level sensor analog readings
void initialise_ADC(){
    // Configure ADC voltage reference to AVCC (5V from Arduino's power supply)
    ADMUX = (1 << REFS0);    // REFS1:0 = 01 (AVCC with external capacitor at AREF pin)
    
    // Configure ADC prescaler for optimal conversion speed
    // ADC needs 50kHz - 200kHz for maximum resolution
    // 16MHz / 128 = 125kHz (optimal for 10-bit accuracy)
    ADCSRA = (1 << ADEN) |      // Enable ADC
             (1 << ADPS2) |     // Prescaler bits: 111 = divide by 128
             (1 << ADPS1) |     
             (1 << ADPS0);      
}


// ========== WATER LEVEL SENSOR READING ==========
// Read analog water level sensor value using ADC conversion
uint16_t read_water_sensor(){
    // Select ADC channel 0 (PC0/A0) for water level sensor input
    // Preserve voltage reference settings, clear channel selection bits (MUX3:0)
    ADMUX = (ADMUX & 0xF0) | 0x00;    // MUX3:0 = 0000 (select ADC0/PC0)
    
    // Start ADC conversion process
    ADCSRA |= (1 << ADSC);    // Set ADC Start Conversion bit
    
    // Wait for conversion to complete (hardware clears ADSC when done)
    while (ADCSRA & (1 << ADSC));    // Poll until conversion completes
    
    // Return 10-bit ADC result (0-1023 representing 0V-5V)
    return ADC;    // ADC register contains the conversion result
}

// ========== HC-SR04 TRIGGER PULSE GENERATION ==========
// Send precise 10μs trigger pulse to initiate HC-SR04 distance measurement
void send_trigger_pulse(){
    // Ensure trigger pin starts LOW (required by HC-SR04 specification)
    PORTD &= ~(1 << TRIG_PIN);
    _delay_us(2);    // Wait 2μs for clean LOW state
    
    // Generate 10μs HIGH pulse (HC-SR04 trigger requirement: min 10μs)
    PORTD |= (1 << TRIG_PIN);     // Set trigger HIGH
    _delay_us(10);                // Hold HIGH for exactly 10μs
    
    // Return trigger pin to LOW state (HC-SR04 will now send echo pulse)
    PORTD &= ~(1 << TRIG_PIN);    // Clear trigger LOW
}


// ========== HC-SR04 DISTANCE MEASUREMENT ==========
// Measure distance using interrupt-based Timer1 Input Capture for precision timing
uint32_t read_HCSR04_distance(){
    // Initialize measurement state for new reading
    echo_measurement_complete = 0;    // Clear completion flag
    TCNT1 = 0;                       // Reset Timer1 counter for clean measurement
    
    // Initiate HC-SR04 measurement cycle
    send_trigger_pulse();            // Send 10μs trigger pulse to HC-SR04
    
    // Wait for interrupt-based measurement completion with optimized timeout
    // Reduced timeout for faster response - 30cm max range = ~1.8ms round trip
    uint32_t timeout_count = 5000;   // 5ms timeout (covers ~85cm max range, optimized for faster response)
    while(!echo_measurement_complete && timeout_count > 0) {
        _delay_us(1);                // 1μs delay per iteration
        timeout_count--;             // Decrement timeout counter
    }
    
    // Process measurement results if valid
    if (echo_measurement_complete && timeout_count > 0) {
        // Convert Timer1 ticks to microseconds
        // Timer1 configuration: 16MHz / 8 prescaler = 2MHz = 0.5μs per tick
        uint32_t pulse_us = echo_duration / 2;    // Convert ticks to microseconds
        
        /*
         * HC-SR04 Distance Calculation:
         * - Sound travels at ~343 m/s (0.0343 cm/μs)
         * - Echo time = round trip, so actual distance = (time × speed) / 2
         * - Distance (cm) = (time_μs × 0.0343) / 2 = time_μs × 0.01715
         * - For integer math: distance = (time_μs × 17) / 1000
         */
        
        // Validate pulse duration range (optimized for tank monitoring: 150μs-5000μs for 2.5cm-85cm)
        if (pulse_us > 150 && pulse_us < 5000) {     // Valid range optimized for petrol tank
            return (pulse_us * 17) / 1000;           // Calculate distance in centimeters
        }
    }
    
    // Return 0 for invalid reading, timeout, or out-of-range measurement
    return 0;
}


// ========== LED CONTROL SYSTEM ==========
// Control visual status indicators based on petrol tank level and water contamination
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green){
    // Turn OFF all LEDs first to ensure clean state transitions
    PORTD &= ~((1 << RED_LED_PIN) | (1 << YELLOW_LED_PIN) | (1 << GREEN_LED_PIN));
    
    // Activate requested LED indicators
    if(red)    PORTD |= (1 << RED_LED_PIN);     // Water contamination detected
    if(yellow) PORTD |= (1 << YELLOW_LED_PIN);  // Halfway level or normal operation
    if(green)  PORTD |= (1 << GREEN_LED_PIN);   // Near overflow warning (13cm)
}

// ========== BUZZER CONTROL SYSTEM ==========
// Control audio alert system for water contamination and overflow warnings
void control_buzzer(uint8_t state){
    if (state) {
        PORTD |= (1 << BUZZER_PIN);     // Turn ON buzzer for audio alert
    } else {
        PORTD &= ~(1 << BUZZER_PIN);    // Turn OFF buzzer (normal operation)
    }
}

// ========== TIMING UTILITY FUNCTIONS ==========

// Millisecond delay function for system timing control
void delay_ms(uint16_t ms){
    while(ms--){
        _delay_ms(1);    // Use AVR library 1ms delay in loop
    }
}

// Microsecond delay function for precise timing requirements  
void delay_us(uint16_t us) {
    while(us--) {
        _delay_us(1);    // Use AVR library 1μs delay in loop
    }
}