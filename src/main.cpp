#include <avr/io.h>
#include <avr/interrupt.h>
#include <util/delay.h>
#include <stdlib.h> // For atoi only

// ============================================================================
//                            PIN DEFINITIONS
// ============================================================================
#define TRIG_PIN        PH4     // Ultrasonic trigger
#define ECHO_PIN        PL1     // Ultrasonic echo (ICP5)

#define RED_LED         PE4     // Contamination indicator
#define YELLOW_LED      PE5     // Half-full indicator  
#define GREEN_LED       PG5     // Overflow warning

#define BUZZER          PE3     // Active-low buzzer

// ============================================================================
//                            THRESHOLDS
// ============================================================================
#define WATER_CONTAMINATION_ADC     100     // ADC threshold for dirty water
#define OVERFLOW_PERCENT            50      // Alert when ≥50% full
#define EMPTY_PERCENT               5       // Consider empty when ≤5%

#define BT_SEND_INTERVAL_MS         500     // Bluetooth update rate
#define SENSOR_READ_INTERVAL_MS     60      // Ultrasonic measurement rate

// ============================================================================
//                         GLOBAL VARIABLES
// ============================================================================
// Container height in cm (e.g., 10 = 10cm, 100 = 100cm)
volatile uint16_t container_height_cm = 10;  // Default: 10cm

// Ultrasonic sensor state (distance in cm)
volatile uint32_t distance_cm = 0;
volatile uint16_t pulse_start = 0;
volatile uint8_t edge_count = 0;

// UART RX buffer for height commands
volatile char rx_buffer[8];
volatile uint8_t rx_index = 0;
volatile uint8_t new_command = 0;

// Timestamp counter (milliseconds since startup)
volatile uint32_t system_time_ms = 0;

// System status
typedef enum {
    STATUS_EMPTY = 0,
    STATUS_HALF_FULL,
    STATUS_OVERFLOW,
    STATUS_CONTAMINATED
} Status_t;

// ============================================================================
//                         FUNCTION PROTOTYPES
// ============================================================================
void init_hardware(void);
void init_adc(void);
void init_timer5_capture(void);
void init_uart(void);

void trigger_ultrasonic(void);
uint16_t read_water_quality(void);

void set_leds(uint8_t red, uint8_t yellow, uint8_t green);
void set_buzzer(uint8_t on);

void uart_send_char(char c);
void uart_send_string(const char* str);
void uart_send_uint(uint16_t num);
void uart_send_ulong(uint32_t num);
void send_status_packet(uint32_t timestamp, uint16_t percent, uint16_t water_adc, Status_t status, uint8_t alert);

// ============================================================================
//                              MAIN PROGRAM
// ============================================================================
int main(void){
    init_hardware();
    
    sei(); // Enable interrupts
    _delay_ms(100); // Stabilization
    
    uint8_t sensor_cycle = 0;
    uint16_t bt_timer = 0;
    uint16_t water_adc = 0;
    
    while(1){
        // --- Process incoming height command ---
        if(new_command){
            cli();
            char cmd_local[8];
            for(uint8_t i = 0; i < 8; i++) cmd_local[i] = rx_buffer[i];
            new_command = 0;
            sei();
            
            // Parse integer (e.g., "100" = 100cm)
            int16_t new_height = atoi(cmd_local);
            
            if(new_height > 0 && new_height < 500){ // 1cm to 499cm
                container_height_cm = (uint16_t)new_height;
                
                // Send confirmation: "H:100\n" means 100cm
                uart_send_string("H:");
                uart_send_uint(container_height_cm);
                uart_send_char('\n');
            }
        }
        
        // --- Trigger sensors periodically ---
        if(sensor_cycle == 0){
            water_adc = read_water_quality();
            trigger_ultrasonic();
        }
        
        // --- Calculate percentage: (L/H) × 100 where L = H - D ---
        // All values in cm, no conversion needed
        uint32_t distance = distance_cm;
        uint16_t height = container_height_cm;
        uint32_t liquid_level_cm;
        
        // L = H - D
        if(distance >= height){
            liquid_level_cm = 0; // Empty or sensor error
        } else {
            liquid_level_cm = height - distance;
        }
        
        // Percentage = (L / H) × 100
        uint16_t level_percent = 0;
        if(height > 0){
            level_percent = (uint16_t)((liquid_level_cm * 100UL) / height);
        }
        
        // Limit to 100%
        if(level_percent > 100) level_percent = 100;
        
        // --- Determine status and control outputs ---
        Status_t status;
        uint8_t alert = 0;
        
        if(water_adc > WATER_CONTAMINATION_ADC){
            status = STATUS_CONTAMINATED;
            set_leds(1, 0, 0); // RED ON
            set_buzzer(1);     // BUZZER ON
            alert = 1;
        }
        else if(level_percent >= OVERFLOW_PERCENT){
            status = STATUS_OVERFLOW;
            set_leds(0, 0, 1); // GREEN ON
            set_buzzer(1);     // BUZZER ON
            alert = 1;
        }
        else if(level_percent > EMPTY_PERCENT){
            status = STATUS_HALF_FULL;
            set_leds(0, 1, 0); // YELLOW ON
            set_buzzer(0);     // BUZZER OFF
            alert = 0;
        }
        else {
            status = STATUS_EMPTY;
            set_leds(0, 0, 0); // ALL OFF
            set_buzzer(0);
            alert = 0;
        }
        
        // --- Send Bluetooth update ---
        bt_timer++;
        if(bt_timer >= BT_SEND_INTERVAL_MS){
            send_status_packet(system_time_ms, level_percent, water_adc, status, alert);
            bt_timer = 0;
        }
        
        // --- Timing ---
        _delay_ms(1); // 1ms loop cycle
        system_time_ms++; // Increment timestamp
        
        sensor_cycle++;
        if(sensor_cycle >= SENSOR_READ_INTERVAL_MS) sensor_cycle = 0;
    }
    
    return 0;
}

// ============================================================================
//                         HARDWARE INITIALIZATION
// ============================================================================
void init_hardware(void){
    // LEDs and Buzzer as outputs (Active-LOW, so set HIGH = OFF)
    DDRE |= (1 << RED_LED) | (1 << YELLOW_LED) | (1 << BUZZER);
    DDRG |= (1 << GREEN_LED);
    PORTE |= (1 << RED_LED) | (1 << YELLOW_LED) | (1 << BUZZER); // OFF
    PORTG |= (1 << GREEN_LED); // OFF
    
    // Ultrasonic pins
    DDRH |= (1 << TRIG_PIN);   // Output
    DDRL &= ~(1 << ECHO_PIN);  // Input
    PORTH &= ~(1 << TRIG_PIN); // LOW
    
    // Water sensor (ADC input)
    DDRF &= ~(1 << PF0);
    
    init_adc();
    init_timer5_capture();
    init_uart();
}

void init_adc(void){
    ADMUX = (1 << REFS0); // AVcc reference
    ADCSRA = (1 << ADEN) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0); // Prescaler 128
}

void init_timer5_capture(void){
    TCCR5A = 0;
    TCCR5B = (1 << CS51); // Prescaler 8 (0.5us per tick at 16MHz)
    TIMSK5 = (1 << ICIE5); // Enable capture interrupt
    TCCR5B |= (1 << ICES5); // Rising edge
    TCNT5 = 0;
    edge_count = 0;
}

void init_uart(void){
    uint16_t ubrr = 103; // 9600 baud @ 16MHz
    
    UBRR1H = (uint8_t)(ubrr >> 8);
    UBRR1L = (uint8_t)ubrr;
    
    UCSR1C = (1 << UCSZ11) | (1 << UCSZ10); // 8N1
    UCSR1B = (1 << TXEN1) | (1 << RXEN1) | (1 << RXCIE1); // TX, RX, RX interrupt
}

// ============================================================================
//                         SENSOR FUNCTIONS
// ============================================================================
void trigger_ultrasonic(void){
    edge_count = 0;
    TIFR5 = (1 << ICF5); // Clear flag
    TCNT5 = 0;
    TCCR5B |= (1 << ICES5); // Rising edge
    
    PORTH |= (1 << TRIG_PIN);
    _delay_us(10);
    PORTH &= ~(1 << TRIG_PIN);
}

uint16_t read_water_quality(void){
    ADMUX = (ADMUX & 0xF0); // Select ADC0
    ADCSRA |= (1 << ADSC);
    while(ADCSRA & (1 << ADSC)); // Wait
    return ADC;
}

// ============================================================================
//                         OUTPUT CONTROL
// ============================================================================
void set_leds(uint8_t red, uint8_t yellow, uint8_t green){
    // Active-LOW: 1 = turn ON
    if(red)    PORTE &= ~(1 << RED_LED);    else PORTE |= (1 << RED_LED);
    if(yellow) PORTE &= ~(1 << YELLOW_LED); else PORTE |= (1 << YELLOW_LED);
    if(green)  PORTG &= ~(1 << GREEN_LED);  else PORTG |= (1 << GREEN_LED);
}

void set_buzzer(uint8_t on){
    // Active-LOW: 1 = turn ON
    if(on) PORTE &= ~(1 << BUZZER);
    else   PORTE |= (1 << BUZZER);
}

// ============================================================================
//                         UART FUNCTIONS
// ============================================================================
void uart_send_char(char c){
    while(!(UCSR1A & (1 << UDRE1))); // Wait for buffer
    UDR1 = c;
}

void uart_send_string(const char* str){
    while(*str) uart_send_char(*str++);
}

void uart_send_uint(uint16_t num){
    char buffer[6];
    uint8_t i = 0;
    
    // Convert to string (reverse order)
    do {
        buffer[i++] = '0' + (num % 10);
        num /= 10;
    } while(num > 0);
    
    // Send in correct order
    while(i > 0){
        uart_send_char(buffer[--i]);
    }
}

void uart_send_ulong(uint32_t num){
    char buffer[11]; // Max 10 digits for uint32_t + null
    uint8_t i = 0;
    
    // Convert to string (reverse order)
    do {
        buffer[i++] = '0' + (num % 10);
        num /= 10;
    } while(num > 0);
    
    // Send in correct order
    while(i > 0){
        uart_send_char(buffer[--i]);
    }
}

void send_status_packet(uint32_t timestamp, uint16_t percent, uint16_t water_adc, Status_t status, uint8_t alert){
    // Format: T:12345,P:50,W:123,S:2,A:1\n
    // T = timestamp (ms), P = percentage, W = water ADC, S = status code, A = alert
    
    uart_send_string("T:");
    uart_send_ulong(timestamp);
    uart_send_string(",P:");
    uart_send_uint(percent);
    uart_send_string(",W:");
    uart_send_uint(water_adc);
    uart_send_string(",S:");
    uart_send_char('0' + status);
    uart_send_string(",A:");
    uart_send_char('0' + alert);
    uart_send_char('\n');
}

// ============================================================================
//                         INTERRUPT HANDLERS
// ============================================================================
ISR(TIMER5_CAPT_vect){
    if(edge_count == 0){
        pulse_start = ICR5;
        edge_count = 1;
        TCCR5B &= ~(1 << ICES5); // Falling edge next
    }
    else {
        uint16_t pulse_end = ICR5;
        uint16_t pulse_ticks;
        
        if(pulse_end >= pulse_start){
            pulse_ticks = pulse_end - pulse_start;
        } else {
            pulse_ticks = (0xFFFF - pulse_start) + pulse_end + 1;
        }
        
        uint32_t pulse_us = (uint32_t)pulse_ticks >> 1; // Convert to microseconds
        
        if(pulse_us >= 150 && pulse_us <= 23500){
            distance_cm = pulse_us / 58; // Result in cm
        } else {
            distance_cm = 0;
        }
        
        edge_count = 0;
        TCCR5B |= (1 << ICES5); // Rising edge next
    }
}

ISR(USART1_RX_vect){
    char c = UDR1;
    
    // End of command (newline or carriage return)
    if(c == '\n' || c == '\r'){
        if(rx_index > 0){
            rx_buffer[rx_index] = '\0';
            new_command = 1;
            rx_index = 0;
        }
    }
    // Valid characters (digits only for integer input)
    else if(c >= '0' && c <= '9'){
        if(rx_index < sizeof(rx_buffer) - 1){
            rx_buffer[rx_index++] = c;
        } else {
            rx_index = 0; // Buffer overflow, reset
        }
    }
}