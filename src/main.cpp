#include <avr/io.h>
#include <avr/interrupt.h>
#include <util/delay.h>

// Pin Definitions
#define WATER_SENSOR_POWER_PIN 9   // PB1
#define TRIG_PIN 7                 // PD7
#define ECHO_PIN 8                 // PB0 (ICP1 - Input Capture Pin)
#define RED_LED_PIN 2              // PD2
#define YELLOW_LED_PIN 3           // PD3
#define GREEN_LED_PIN 4            // PD4
#define BUZZER_PIN 5               // PD5

// Thresholds
#define WATER_CONTAMINATION_THRESHOLD 100
const float HALFWAY_LEVEL_THRESHOLD = 7.5;
const float OVERFLOW_WARNING_THRESHOLD = 15.0;

// HC-SR04 State Machine
volatile uint8_t measurement_ready = 0;
volatile uint32_t distance_cm = 0;
volatile uint16_t pulse_start = 0;
volatile uint8_t edge_count = 0;

// Function Declarations
void initialise_ADC();
void init_timer1_input_capture();
void trigger_hcsr04();
uint16_t read_water_sensor();
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green);
void control_buzzer(uint8_t state);

int main(){
    // Port Configuration
    DDRD |= (1 << RED_LED_PIN) | (1 << YELLOW_LED_PIN) | (1 << GREEN_LED_PIN) |
            (1 << BUZZER_PIN) | (1 << TRIG_PIN);
    DDRB |= (1 << WATER_SENSOR_POWER_PIN);
    DDRB &= ~(1 << ECHO_PIN);  // ICP1 input
    DDRC &= ~(1 << PC0);       // ADC input

    // Initialize outputs to LOW
    PORTD &= ~((1 << RED_LED_PIN) | (1 << YELLOW_LED_PIN) | (1 << GREEN_LED_PIN) |
               (1 << BUZZER_PIN) | (1 << TRIG_PIN));
    PORTB |= (1 << WATER_SENSOR_POWER_PIN);

    // Initialize peripherals
    initialise_ADC();
    init_timer1_input_capture();
    sei();  // Enable global interrupts

    uint8_t measurement_cycle = 0;

    while(1){
        // Read water sensor every cycle (very fast)
        uint16_t water_level = read_water_sensor();

        // Trigger HC-SR04 every 10ms (100Hz update rate - much faster than 50ms)
        if(measurement_cycle == 0){
            trigger_hcsr04();
        }

        // Use latest distance measurement (non-blocking)
        uint32_t distance = distance_cm;

        // Decision Logic
        if (water_level < WATER_CONTAMINATION_THRESHOLD) {
            // Water contamination detected - RED LED + BUZZER
            control_LEDS(0, 1, 1);
            control_buzzer(1);
        } else if (distance > 0 && distance <= HALFWAY_LEVEL_THRESHOLD) {
            // Near overflow (0-7.5cm) - GREEN LED + BUZZER
            control_LEDS(1, 1, 0);
            control_buzzer(1);
        } else if (distance > HALFWAY_LEVEL_THRESHOLD && distance <= OVERFLOW_WARNING_THRESHOLD) {
            // Halfway level (7.5-15cm) - YELLOW LED only
            control_LEDS(1, 0, 1);
            control_buzzer(0);
        } else {
            // Tank empty or no valid reading - ALL OFF
            control_LEDS(1, 1, 1);
            control_buzzer(0);
        }

        // Fast update: 1ms loop for instant response
        _delay_ms(1);
        measurement_cycle++;
        if(measurement_cycle >= 10) measurement_cycle = 0;  // Trigger every 10ms
    }
    return 0;
}

// Timer1 Input Capture Configuration
void init_timer1_input_capture(){
    // Timer1: Prescaler = 8 (0.5μs per tick at 16MHz)
    // CS11 = 1: clk/8
    TCCR1A = 0;
    TCCR1B = (1 << CS11);  // Start timer with /8 prescaler
    
    // Enable Input Capture Interrupt
    TIMSK1 = (1 << ICIE1);
    
    // Start with rising edge detection
    TCCR1B |= (1 << ICES1);  // Input Capture Edge Select: rising edge
    
    TCNT1 = 0;
    edge_count = 0;
}

// Trigger HC-SR04 Measurement
void trigger_hcsr04(){
    edge_count = 0;
    measurement_ready = 0;
    TCNT1 = 0;
    
    // Configure for rising edge
    TCCR1B |= (1 << ICES1);
    
    // Clear any pending input capture flag
    TIFR1 = (1 << ICF1);
    
    // Generate 10μs trigger pulse
    PORTD &= ~(1 << TRIG_PIN);
    _delay_us(2);
    PORTD |= (1 << TRIG_PIN);
    _delay_us(10);
    PORTD &= ~(1 << TRIG_PIN);
}

// Input Capture ISR - ULTRA FAST
ISR(TIMER1_CAPT_vect){
    if(edge_count == 0){
        // Rising edge detected - pulse start
        pulse_start = ICR1;
        edge_count = 1;
        
        // Switch to falling edge detection
        TCCR1B &= ~(1 << ICES1);
        
    } else {
        // Falling edge detected - pulse end
        uint16_t pulse_end = ICR1;
        uint16_t pulse_ticks;
        
        // Handle timer overflow
        if(pulse_end >= pulse_start){
            pulse_ticks = pulse_end - pulse_start;
        } else {
            pulse_ticks = (0xFFFF - pulse_start) + pulse_end;
        }
        
        // Convert to microseconds (0.5μs per tick)
        uint32_t pulse_us = (uint32_t)pulse_ticks >> 1;  // Divide by 2 (bit shift is faster)
        
        // Calculate distance: distance_cm = (pulse_us * 17) / 1000
        // Optimized: (pulse_us * 17) >> 10 ≈ divide by 1000 (actually 1024, close enough)
        if(pulse_us > 150 && pulse_us < 23500){  // Valid range: 2.5cm to 400cm
            distance_cm = (pulse_us * 17) / 1000;
        } else {
            distance_cm = 0;
        }
        
        measurement_ready = 1;
        edge_count = 0;
        
        // Switch back to rising edge
        TCCR1B |= (1 << ICES1);
    }
}

// ADC Initialization
void initialise_ADC(){
    ADMUX = (1 << REFS0);
    ADCSRA = (1 << ADEN) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);
}

// Read Water Sensor
uint16_t read_water_sensor(){
    ADMUX = (ADMUX & 0xF0) | 0x00;
    ADCSRA |= (1 << ADSC);
    while (ADCSRA & (1 << ADSC));
    return ADC;
}

// LED Control
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green){
    PORTD &= ~((1 << RED_LED_PIN) | (1 << YELLOW_LED_PIN) | (1 << GREEN_LED_PIN));
    if(red)    PORTD |= (1 << RED_LED_PIN);
    if(yellow) PORTD |= (1 << YELLOW_LED_PIN);
    if(green)  PORTD |= (1 << GREEN_LED_PIN);
}

// Buzzer Control
void control_buzzer(uint8_t state){
    if (state) {
        PORTD |= (1 << BUZZER_PIN);
    } else {
        PORTD &= ~(1 << BUZZER_PIN);
    }
}