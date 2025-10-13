#include <avr/io.h>
#include <avr/interrupt.h>
#include <util/delay.h>

// Pin Definitions for Arduino Mega 2560
#define WATER_SENSOR_POWER_PIN 9   // PH6
#define TRIG_PIN 7                 // PH4
#define ECHO_PIN 48                // PL1 (ICP5 - Input Capture Pin 5)
#define RED_LED_PIN 2              // PE4
#define YELLOW_LED_PIN 3           // PE5
#define GREEN_LED_PIN 4            // PG5
#define BUZZER_PIN 5               // PE3

// Thresholds
#define WATER_CONTAMINATION_THRESHOLD 100
#define HALFWAY_LEVEL_THRESHOLD 7.5f
#define OVERFLOW_WARNING_THRESHOLD 15.0f

// Measurement filtering
#define DISTANCE_SAMPLES 3

// HC-SR04 State Machine
volatile uint8_t measurement_ready = 0;
volatile uint32_t distance_cm = 0;
volatile uint16_t pulse_start = 0;
volatile uint8_t edge_count = 0;

// Filtering buffers
uint32_t distance_buffer[DISTANCE_SAMPLES] = {0};
uint8_t distance_index = 0;

// Function Declarations
void initialise_ADC();
void init_timer5_input_capture();
void trigger_hcsr04();
uint16_t read_water_sensor();
uint32_t get_filtered_distance();
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green);
void control_buzzer(uint8_t state);

int main(){
    // Port Configuration for Mega 2560
    // LEDs and Buzzer
    DDRE |= (1 << PE4) | (1 << PE5) | (1 << PE3);  // RED, YELLOW, BUZZER
    DDRG |= (1 << PG5);                             // GREEN
    DDRH |= (1 << PH4) | (1 << PH6);               // TRIG, WATER_SENSOR_POWER
    DDRL &= ~(1 << PL1);                            // ECHO (ICP5 input)
    DDRF &= ~(1 << PF0);                            // ADC0 input

    // Initialize outputs - LEDs HIGH (off for active-low), others LOW
    PORTE |= (1 << PE4) | (1 << PE5);               // RED, YELLOW off
    PORTE &= ~(1 << PE3);                           // BUZZER off
    PORTG |= (1 << PG5);                            // GREEN off
    PORTH &= ~(1 << PH4);                           // TRIG low
    PORTH |= (1 << PH6);                            // WATER_SENSOR_POWER on

    // Initialize peripherals
    initialise_ADC();
    init_timer5_input_capture();
    sei();  // Enable global interrupts

    // Stabilization delay
    _delay_ms(100);

    uint8_t measurement_cycle = 0;
    uint16_t water_level = 0;

    while(1){
        // Read water sensor every 60ms (not every cycle) to avoid blocking HC-SR04 timing
        // This reduces ADC blocking from 1000x/sec to ~16x/sec
        if(measurement_cycle == 0){
            water_level = read_water_sensor();
            trigger_hcsr04();
        }

        // Get filtered distance measurement (non-blocking)
        uint32_t distance = get_filtered_distance();

        // Decision Logic - FIXED THRESHOLD LOGIC
        // Water sensor: HIGH reading (>100) = CONTAMINATED/CONDUCTIVE water detected
        //               LOW reading (<100) = NO water or clean water (sensor dry/minimal conductivity)
        if (water_level > WATER_CONTAMINATION_THRESHOLD) {
            // Water contamination detected (HIGH reading = conductive water) - RED LED + BUZZER
            control_LEDS(0, 1, 1);  // RED on
            control_buzzer(0);
            
        } else if (distance > 0 && distance <= HALFWAY_LEVEL_THRESHOLD) {
            // Near overflow (0-7.5cm) - GREEN LED + BUZZER
            control_LEDS(1, 1, 0);  // GREEN on
            control_buzzer(0);
            
        } else if (distance > HALFWAY_LEVEL_THRESHOLD && distance <= OVERFLOW_WARNING_THRESHOLD) {
            // Halfway level (7.5-15cm) - YELLOW LED only
            control_LEDS(1, 0, 1);  // YELLOW on
            // control_buzzer(0);
            
        } else {
            // Tank empty or no valid reading - ALL OFF
            control_LEDS(1, 1, 1);  // All LEDs off
            control_buzzer(1);
        }

        // 1ms loop delay
        _delay_ms(1);
        measurement_cycle++;
        if(measurement_cycle >= 60) measurement_cycle = 0;
    }
    return 0;
}

// Timer5 Input Capture Configuration (Mega 2560)
void init_timer5_input_capture(){
    // Timer5: Prescaler = 8 (0.5μs per tick at 16MHz)
    TCCR5A = 0;
    TCCR5B = (1 << CS51);  // clk/8 prescaler
    
    // Enable Input Capture Interrupt for Timer5
    TIMSK5 = (1 << ICIE5);
    
    // Start with rising edge detection
    TCCR5B |= (1 << ICES5);
    
    TCNT5 = 0;
    edge_count = 0;
}

// Trigger HC-SR04 Measurement
void trigger_hcsr04(){
    // Reset state
    edge_count = 0;
    measurement_ready = 0;
    
    // Clear input capture flag before triggering
    TIFR5 = (1 << ICF5);
    
    // Reset timer
    TCNT5 = 0;
    
    // Configure for rising edge
    TCCR5B |= (1 << ICES5);
    
    // Generate 10μs trigger pulse
    PORTH |= (1 << PH4);
    _delay_us(10);
    PORTH &= ~(1 << PH4);
}

// Input Capture ISR for Timer5 (Mega 2560) - NON-BLOCKING
ISR(TIMER5_CAPT_vect){
    if(edge_count == 0){
        // Rising edge - pulse start
        pulse_start = ICR5;
        edge_count = 1;
        
        // Switch to falling edge detection
        TCCR5B &= ~(1 << ICES5);
        
    } else if(edge_count == 1){
        // Falling edge - pulse end
        uint16_t pulse_end = ICR5;
        uint16_t pulse_ticks;
        
        // Calculate pulse width (handle overflow)
        if(pulse_end >= pulse_start){
            pulse_ticks = pulse_end - pulse_start;
        } else {
            pulse_ticks = (0xFFFF - pulse_start) + pulse_end + 1;
        }
        
        // Convert to microseconds (0.5μs per tick with prescaler 8)
        uint32_t pulse_us = (uint32_t)pulse_ticks >> 1;
        
        // Calculate distance: distance_cm = pulse_us / 58
        // Valid range check: 150μs (2.5cm) to 23500μs (400cm)
        if(pulse_us >= 150 && pulse_us <= 23500){
            uint32_t new_distance = pulse_us / 58;
            
            // Add to circular buffer for filtering
            distance_buffer[distance_index] = new_distance;
            distance_index = (distance_index + 1) % DISTANCE_SAMPLES;
            
            distance_cm = new_distance;  // Update immediately
        } else {
            distance_cm = 0;  // Invalid reading
        }
        
        measurement_ready = 1;
        edge_count = 0;
        
        // Switch back to rising edge for next measurement
        TCCR5B |= (1 << ICES5);
    }
}

// Get filtered distance (simple averaging - fast and non-blocking)
uint32_t get_filtered_distance(){
    uint32_t sum = 0;
    uint8_t valid_count = 0;
    
    for(uint8_t i = 0; i < DISTANCE_SAMPLES; i++){
        if(distance_buffer[i] > 0){
            sum += distance_buffer[i];
            valid_count++;
        }
    }
    
    if(valid_count > 0){
        return sum / valid_count;
    }
    return distance_cm;  // Return current if no valid samples
}

// ADC Initialization
void initialise_ADC(){
    ADMUX = (1 << REFS0);  // AVcc reference
    ADCSRA = (1 << ADEN) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);  // Enable, prescaler 128
}

// Read Water Sensor - FAST, no delays
uint16_t read_water_sensor(){
    ADMUX = (ADMUX & 0xF0) | 0x00;  // Select ADC0
    ADCSRA |= (1 << ADSC);           // Start conversion
    while (ADCSRA & (1 << ADSC));    // Wait for completion (~100μs)
    return ADC;
}

// LED Control - Active LOW (0 = ON, 1 = OFF)
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green){
    // RED LED (PE4)
    if(!red)
        PORTE &= ~(1 << PE4);
    else
        PORTE |= (1 << PE4);
    
    // YELLOW LED (PE5)
    if(!yellow)
        PORTE &= ~(1 << PE5);
    else
        PORTE |= (1 << PE5);
    
    // GREEN LED (PG5)
    if(!green)
        PORTG &= ~(1 << PG5);
    else
        PORTG |= (1 << PG5);
}

// Buzzer Control
void control_buzzer(uint8_t state){
    if (state) {
        PORTE |= (1 << PE3);
    } else {
        PORTE &= ~(1 << PE3);
    }
}