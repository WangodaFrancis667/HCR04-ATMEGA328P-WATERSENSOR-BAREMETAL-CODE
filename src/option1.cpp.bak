#include <avr/io.h>
#include <avr/interrupt.h>
#include<util/delay.h>

// This uses busy wait to measure echos


// Defining constants
// Water level sensor
#define WATER_SENSOR_POWER_PIN 6   // PD6

// HCR04 port mapping
#define TRIG_PIN 7                 // PD7  
#define ECHO_PIN 0                 // PB0 (Pin 8)

// Feedback port mapping
#define RED_LED_PIN 2              // PD2
#define YELLOW_LED_PIN 3           // PD3
#define GREEN_LED_PIN 4            // PD4
#define BUZZER_PIN 5               // PD5

// Water level thresholds
#define CRITICAL_LOW_THRESHOLD 100    // ADC value for critically low water
#define HIGH_LEVEL_THRESHOLD 15       // Distance in cm for overflow warning

// function declarations
void initialise_ADC();
uint16_t read_water_sensor();
void send_trigger_pulse();
uint32_t measure_echo_pulse();
uint32_t read_HCSR04_distance();
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green);
void control_buzzer(uint8_t state);
void delay_ms(uint16_t ms);

int main(){
    // System initialisation
    // PORTD pins (PD0 - PD7) as outputs
    DDRD |= (1 << RED_LED_PIN) | (1 << YELLOW_LED_PIN) | (1 << GREEN_LED_PIN) |
            (1 << BUZZER_PIN) | (1 << WATER_SENSOR_POWER_PIN) | (1 << TRIG_PIN);

    // PORTB as inputs (PB8 - PB13) --> Echo pin as input
    DDRB &= ~(1 << ECHO_PIN);

    // PORTC (Analog pins A0 - A5) --> PC0 as input for water sensor
    DDRC &= ~(1 << PC0);

    // Iniitialise all outputs to low
    PORTD &= ~(1 << RED_LED_PIN) | (1 << YELLOW_LED_PIN) | (1 << GREEN_LED_PIN) |
              (1 << BUZZER_PIN) | (1 << TRIG_PIN);
    
    // Turn ON power to water sensor
    PORTD |= (1 << WATER_SENSOR_POWER_PIN);

    initialise_ADC();

    while(1){
        // Read water level sensor
        uint16_t water_level = read_water_sensor();

        // Read distance from HCSR04
        uint32_t distance = read_HCSR04_distance();

        // Decision logic for water level management
        if (water_level < CRITICAL_LOW_THRESHOLD) {
            // Critical low water level
            control_LEDS(1, 0, 0);  // Red LED on
            control_buzzer(1);      // buzzer on
        
        } else if(distance < HIGH_LEVEL_THRESHOLD && distance > 0){
            // water level too high
            control_LEDS(0, 0, 1);  // Green LED on
            control_buzzer(1);      // buzzer on

        } else{
            // Normal water level
            control_LEDS(0, 1, 0);  // Yellow LED ON
            control_buzzer(0);       // Buzzer OFF
        }

        // Delay before next measurement
        delay_ms(100);
    }
    return 0;
}

//  Initialize ADC for water level sensor reading
void initialise_ADC(){
    // Set voltage reference to AVCC (5V)
    ADMUX = (1 << REFS0);

    // Set ADC prescaler to 128 for 125KHz ADC clock (16MHz / 128)
    ADCSRA = (1 << ADEN) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);
}


// Read Water level sensor value using ADC
uint16_t read_water_sensor(){
    // Select ADC0 (PC0/A0)
    ADMUX = (ADMUX & 0xF0) | 0x00;

    // Start ADC conversion
    ADCSRA |= (1 << ADSC);

    // Wait for conversion to complete
    while (ADCSRA & (1 << ADSC));
    
    return ADC; 
}

// send 10 nano seconds pulse to HCSR04
void send_trigger_pulse(){
    // Clear the trigger pin
    PORTD &= ~(1 << TRIG_PIN);
    _delay_us(2);

    // send 10 nano senconds HIGH pulse
    PORTD |= (1 << TRIG_PIN);
    _delay_us(10);

    // clear the trigger pin
    PORTD &= ~(1 << TRIG_PIN);
}

// Measure echo pulse duration in micro seconds
uint32_t measure_echo_pulse(){
    uint32_t timeout = 30000;  // 30ms timeout
    uint32_t pulse_duration = 0;

    // Wait for echo pin to go HIGH (with timeout)
    while(!(PINB & (1 << ECHO_PIN)) && timeout > 0){
        _delay_us(1);
        timeout --;
    }

    if (timeout == 0) return 0;   // Timeout - no echo received

    // Measure pulse duration
    timeout = 30000;     // Reset timeout
    while ((PINB & (1 << ECHO_PIN)) && timeout > 0)
    {
        pulse_duration ++;
        _delay_us(1);
        timeout --;
    }

    return pulse_duration;
    
}

// Read Distance from HCSR04 sensor
uint32_t read_HCSR04_distance(){
    send_trigger_pulse();
    uint32_t pulse_duration = measure_echo_pulse();

    /*
       calculate distance in cm
       Sound spedd = 343 m/s = 0.0343 cm/nano seconds
       Distance = (time x 0.0343) / 2
       simplified: distance = time × 0.01715
       For integer math: distance = (time * 17) / 1000
     */

    if (pulse_duration > 0 && pulse_duration < 30000) { // Valid range check
        return (pulse_duration * 17) / 1000;
    }

    return 0;  // Invalid reading
}


// Control LED states
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green){
    // Turn off all LEDs initially
    PORTD &= ~(1 << RED_LED_PIN) | (1 << GREEN_LED_PIN) | (1 << YELLOW_LED_PIN);

    // Turn ON requested LEDs
    if(red) PORTD |= (1 << RED_LED_PIN);
    if(yellow) PORTD |= (1 << YELLOW_LED_PIN);
    if(green) PORTD |= (1 << GREEN_LED_PIN);
}

// Control buzzer states
void control_buzzer(uint8_t state){
    if (state){
        PORTD |= (1 << BUZZER_PIN);
    } else {
         PORTD &= ~(1 << BUZZER_PIN);
    }
}

// Millisecond delay using busy wait loop
void delay_ms(uint16_t ms){
    while(ms--){
        _delay_ms(1);
    }
}

// Microsecond delay using busy-wait loop
void delay_us(uint16_t us) {
    while(us--) {
        _delay_us(1);
    }
}