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
 * AUTHOR: [Wangoda Francis]
 * DATE: [13th October, 2025]
 * VERSION: 1.0
 * ========================================================================
 */

#include <avr/io.h>        // AVR Input/Output register definitions
#include <avr/interrupt.h> // Interrupt handling (ISR macros)
#include <util/delay.h>    // Precise delay functions (_delay_ms, _delay_us)

// ========================================================================
// PIN DEFINITIONS - Arduino Mega 2560 Port Mapping
// ========================================================================

// Water Quality Sensor - Monitors water contamination via conductivity
// Higher reading = More conductive (contaminated/salty water)
// Lower reading = Less conductive (clean water or dry sensor)
#define WATER_SENSOR_POWER_PIN 9   // PH6 - Powers water sensor (reduces electrolysis)

// HC-SR04 Ultrasonic Distance Sensor - Measures distance to water surface
#define TRIG_PIN 7                 // PH4 - Trigger pulse output (10μs pulse)
#define ECHO_PIN 48                // PL1 - Echo pulse input (ICP5 - Timer5 Input Capture)

// LED Visual Indicators (Active-Low: LOW = ON, HIGH = OFF)
#define RED_LED_PIN 2              // PE4 - Contamination alert
#define YELLOW_LED_PIN 3           // PE5 - Half-full warning
#define GREEN_LED_PIN 4            // PG5 - Overflow warning

// Audio Alert
#define BUZZER_PIN 5               // PE3 - Active buzzer for critical alerts

// ========================================================================
// SYSTEM THRESHOLDS AND CONFIGURATION
// ========================================================================

// Water Quality Threshold
// Water sensor produces 0-1023 ADC reading (10-bit)
// Threshold determines clean vs contaminated water
#define WATER_CONTAMINATION_THRESHOLD 100
// Logic: reading > 100 = contaminated (conductive water detected)
//        reading < 100 = clean or no water

// Distance Thresholds (in centimeters from sensor to water surface)
// These define the three zones of water level monitoring
#define HALFWAY_LEVEL_THRESHOLD 7.5f        // 0-7.5cm = Near overflow (GREEN LED)
#define OVERFLOW_WARNING_THRESHOLD 15.0f    // 7.5-15cm = Half full (YELLOW LED)
                                            // >15cm = Empty or no reading (ALL OFF)

// Signal Filtering Configuration
// Number of distance samples to average for stable readings
// Reduces noise and prevents false readings from ultrasonic reflections
#define DISTANCE_SAMPLES 3

// ========================================================================
// HC-SR04 STATE MACHINE VARIABLES (Volatile - Modified in ISR)
// ========================================================================

// Volatile qualifier required because these are modified in interrupt context
// and accessed in main loop - prevents compiler optimization issues

volatile uint8_t measurement_ready = 0;  // Flag: 1 = new measurement available
volatile uint32_t distance_cm = 0;       // Latest distance measurement in cm
volatile uint16_t pulse_start = 0;       // Timer value when echo pulse started
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
// FUNCTION PROTOTYPES
// ========================================================================

void initialise_ADC();              // Configure Analog-to-Digital Converter
void init_timer5_input_capture();   // Configure Timer5 for HC-SR04 echo timing
void trigger_hcsr04();              // Send 10μs trigger pulse to HC-SR04
uint16_t read_water_sensor();       // Read analog value from water sensor
uint32_t get_filtered_distance();   // Calculate average from distance buffer
void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green);  // Control LED states
void control_buzzer(uint8_t state); // Control buzzer on/off

// ========================================================================
// MAIN PROGRAM
// ========================================================================

int main(){
    
    // ====================================================================
    // STEP 1: PORT CONFIGURATION - Set Pin Directions
    // ====================================================================
    
    // Configure OUTPUT pins (set corresponding DDR bits to 1)
    // Port E outputs: RED LED, YELLOW LED, BUZZER
    DDRE |= (1 << PE4) | (1 << PE5) | (1 << PE3);
    
    // Port G outputs: GREEN LED
    DDRG |= (1 << PG5);
    
    // Port H outputs: HC-SR04 TRIG, Water Sensor Power
    DDRH |= (1 << PH4) | (1 << PH6);
    
    // Configure INPUT pins (clear corresponding DDR bits to 0)
    // Port L input: HC-SR04 ECHO (ICP5 - Timer5 Input Capture Pin)
    DDRL &= ~(1 << PL1);
    
    // Port F input: Water Sensor Analog (ADC0)
    DDRF &= ~(1 << PF0);

    // ====================================================================
    // STEP 2: INITIALIZE OUTPUT STATES
    // ====================================================================
    
    // LEDs are ACTIVE-LOW, so HIGH = OFF
    // Set RED and YELLOW LEDs to OFF initially
    PORTE |= (1 << PE4) | (1 << PE5);
    
    // Set BUZZER to OFF initially
    PORTE &= ~(1 << PE3);
    
    // Set GREEN LED to OFF initially
    PORTG |= (1 << PG5);
    
    // Set HC-SR04 TRIG to LOW (idle state)
    PORTH &= ~(1 << PH4);
    
    // Power ON the water sensor (HIGH = powered)
    // Note: Keeping sensor powered continuously can cause electrolysis
    // In production, consider pulsing power only during measurements
    PORTH |= (1 << PH6);

    // ====================================================================
    // STEP 3: INITIALIZE PERIPHERALS
    // ====================================================================
    
    initialise_ADC();              // Configure ADC for water sensor readings
    init_timer5_input_capture();   // Configure Timer5 for ultrasonic timing
    sei();                         // Enable Global Interrupts (set I-bit in SREG)
                                   // Required for Timer5 Input Capture ISR

    // Stabilization delay - Allow sensors to stabilize after power-up
    // Water sensor capacitance needs time to charge
    // HC-SR04 needs initialization time
    _delay_ms(100);

    // ====================================================================
    // STEP 4: MAIN CONTROL LOOP VARIABLES
    // ====================================================================
    
    // Cycle counter for timing control (0-59, wraps at 60)
    // Used to trigger measurements every 60ms
    uint8_t measurement_cycle = 0;
    
    // Current water sensor reading (0-1023 ADC value)
    // Stored outside loop to maintain value between 60ms readings
    uint16_t water_level = 0;

    // ====================================================================
    // STEP 5: INFINITE MAIN LOOP (1ms cycle time)
    // ====================================================================
    
    while(1){
        
        // ================================================================
        // SENSOR READING PHASE (Every 60ms)
        // ================================================================
        
        // Execute sensor readings only at start of 60ms cycle (when cycle = 0)
        // This reduces ADC blocking and ensures HC-SR04 gets proper timing
        if(measurement_cycle == 0){
            
            // Read water sensor (blocking ~100μs for ADC conversion)
            // Returns 10-bit value: 0 = no conductivity, 1023 = maximum
            water_level = read_water_sensor();
            
            // Trigger HC-SR04 ultrasonic measurement
            // Sends 10μs pulse, then ISR handles echo timing asynchronously
            trigger_hcsr04();
        }

        // ================================================================
        // DISTANCE RETRIEVAL PHASE (Non-blocking)
        // ================================================================
        
        // Get filtered distance (averaged from last 3 valid readings)
        // Returns 0 if no valid readings available
        // This is non-blocking - uses data from interrupt-driven measurements
        uint32_t distance = get_filtered_distance();

        // ================================================================
        // DECISION LOGIC PHASE - Determine System State
        // ================================================================
        
        // Priority order (highest to lowest):
        // 1. Water contamination (overrides all)
        // 2. Overflow warning (distance 0-7.5cm)
        // 3. Half-full warning (distance 7.5-15cm)
        // 4. Normal/Empty (distance >15cm or invalid)
        
        if (water_level > WATER_CONTAMINATION_THRESHOLD) {
            // ============================================================
            // STATE 1: WATER CONTAMINATION DETECTED
            // ============================================================
            // Condition: ADC reading > 100 (high conductivity detected)
            // Indicates: Contaminated water, salt water, or foreign material
            // Action: RED LED ON + BUZZER OFF (visual alert only)
            
            control_LEDS(0, 1, 1);  // RED=ON (0), YELLOW=OFF (1), GREEN=OFF (1)
            control_buzzer(0);       // BUZZER=ON
            
        } else if (distance > 0 && distance <= HALFWAY_LEVEL_THRESHOLD) {
            // ============================================================
            // STATE 2: OVERFLOW WARNING
            // ============================================================
            // Condition: Valid distance AND water is 0-7.5cm from sensor
            // Indicates: Tank nearly full, overflow risk imminent
            // Action: GREEN LED ON + BUZZER OFF
            
            control_LEDS(1, 1, 0);  // RED=OFF, YELLOW=OFF, GREEN=ON (0)
            control_buzzer(0);       // BUZZER=ON
            
        } else if (distance > HALFWAY_LEVEL_THRESHOLD && distance <= OVERFLOW_WARNING_THRESHOLD) {
            // ============================================================
            // STATE 3: HALF-FULL WARNING
            // ============================================================
            // Condition: Water is 7.5-15cm from sensor
            // Indicates: Tank is approximately half full
            // Action: YELLOW LED ON only (no buzzer)
            
            control_LEDS(1, 0, 1);  // RED=OFF, YELLOW=ON (0), GREEN=OFF
            // control_buzzer(0);       // BUZZER=ON
            
        } else {
            // ============================================================
            // STATE 4: TANK EMPTY OR NO VALID READING
            // ============================================================
            // Condition: distance > 15cm OR distance = 0 (invalid/out of range)
            // Indicates: Tank empty, sensor error, or no water detected
            // Action: ALL LEDS OFF + BUZZER ON (error condition alert)
            
            control_LEDS(1, 1, 1);  // All LEDs OFF (1,1,1)
            control_buzzer(1);       // BUZZER=OF (alert for no reading)
        }

        // ================================================================
        // TIMING CONTROL PHASE
        // ================================================================
        
        // Wait 1ms before next loop iteration
        // Creates consistent 1ms loop timing regardless of execution time
        _delay_ms(1);
        
        // Increment cycle counter (0 → 1 → 2 → ... → 59 → 0)
        measurement_cycle++;
        
        // Reset counter at 60 to trigger next measurement cycle
        // This creates 60ms interval between sensor readings
        if(measurement_cycle >= 60) measurement_cycle = 0;
    }
    
    // Unreachable code (infinite loop above)
    return 0;
}

// ========================================================================
// TIMER5 INPUT CAPTURE INITIALIZATION
// ========================================================================
// Configures Timer5 for precise HC-SR04 echo pulse timing using hardware
// Input Capture functionality for microsecond-accurate measurements
// ========================================================================

void init_timer5_input_capture(){
    
    // Clear Timer/Counter Control Registers to known state
    TCCR5A = 0;  // Normal port operation, no PWM
    
    // Configure Timer5 Clock Source and Prescaler
    // CS51 = 1, CS50 = 0, CS52 = 0 → Prescaler = 8
    // Timer resolution: 16MHz / 8 = 2MHz → 0.5μs per tick
    // This provides sufficient resolution for HC-SR04 (needs ~1μs accuracy)
    TCCR5B = (1 << CS51);
    
    // Enable Input Capture Interrupt for Timer5
    // When edge detected on ICP5 (Pin 48), TIMER5_CAPT_vect ISR is called
    TIMSK5 = (1 << ICIE5);
    
    // Configure Input Capture Edge Select for RISING edge detection
    // ICES5 = 1: Trigger on rising edge (start of echo pulse)
    // This will be toggled to falling edge after first capture
    TCCR5B |= (1 << ICES5);
    
    // Initialize timer count to 0
    // 16-bit counter can count up to 65535 before overflow
    TCNT5 = 0;
    
    // Initialize state machine to wait for rising edge
    edge_count = 0;
}

// ========================================================================
// HC-SR04 TRIGGER FUNCTION
// ========================================================================
// Initiates ultrasonic measurement by sending 10μs trigger pulse
// HC-SR04 responds with echo pulse proportional to distance
// ========================================================================

void trigger_hcsr04(){
    
    // Reset state machine to initial state
    edge_count = 0;          // 0 = waiting for rising edge of echo
    measurement_ready = 0;   // Clear ready flag (new measurement starting)
    
    // Clear any pending Input Capture interrupt flag
    // Writing 1 to ICF5 clears the flag (prevents spurious interrupt)
    TIFR5 = (1 << ICF5);
    
    // Reset Timer5 counter to 0 for new measurement
    // Ensures accurate timing from start of echo pulse
    TCNT5 = 0;
    
    // Configure Input Capture for RISING edge detection
    // Echo pulse starts with rising edge (LOW → HIGH transition)
    TCCR5B |= (1 << ICES5);
    
    // ====================================================================
    // Generate 10μs Trigger Pulse (HC-SR04 specification)
    // ====================================================================
    // HC-SR04 requires minimum 10μs HIGH pulse on TRIG pin to initiate
    // ultrasonic burst. Sensor then sends 8-cycle 40kHz burst and listens
    // for echo return.
    
    PORTH |= (1 << PH4);     // Set TRIG HIGH (start pulse)
    _delay_us(10);           // Wait 10 microseconds (pulse width)
    PORTH &= ~(1 << PH4);    // Set TRIG LOW (end pulse)
    
    // After this, HC-SR04 will:
    // 1. Send ultrasonic burst (8 cycles at 40kHz = 200μs)
    // 2. Set ECHO pin HIGH
    // 3. Wait for reflection
    // 4. Set ECHO pin LOW when echo received
    // 5. Echo pulse width = time of flight = distance × 2 / speed of sound
}

// ========================================================================
// TIMER5 INPUT CAPTURE ISR - HC-SR04 ECHO PULSE TIMING
// ========================================================================
// Interrupt Service Routine called on both edges of echo pulse
// Measures pulse width with hardware precision (±0.5μs accuracy)
// This is a TWO-STAGE interrupt:
//   Stage 1 (rising edge):  Captures pulse start time
//   Stage 2 (falling edge): Calculates pulse width and distance
// ========================================================================

ISR(TIMER5_CAPT_vect){
    
    // ====================================================================
    // STAGE 1: RISING EDGE DETECTION (Echo pulse start)
    // ====================================================================
    if(edge_count == 0){
        
        // Capture exact timer value when echo pulse went HIGH
        // ICR5 (Input Capture Register) automatically latches TCNT5 on edge
        // This hardware capture has ±0.5μs accuracy (1 timer tick)
        pulse_start = ICR5;
        
        // Move to next state: now waiting for falling edge
        edge_count = 1;
        
        // Reconfigure Input Capture for FALLING edge detection
        // Clear ICES5 bit: trigger on falling edge (HIGH → LOW)
        // Next interrupt will fire when echo pulse ends
        TCCR5B &= ~(1 << ICES5);
        
    // ====================================================================
    // STAGE 2: FALLING EDGE DETECTION (Echo pulse end)
    // ====================================================================
    } else if(edge_count == 1){
        
        // Capture exact timer value when echo pulse went LOW
        uint16_t pulse_end = ICR5;
        
        // Variable to store calculated pulse width in timer ticks
        uint16_t pulse_ticks;
        
        // ================================================================
        // Calculate Pulse Width (handling potential timer overflow)
        // ================================================================
        // Timer5 is 16-bit (0-65535), running at 2MHz (0.5μs/tick)
        // Maximum measurable time: 65535 × 0.5μs = 32.7ms
        // HC-SR04 max echo: ~25ms (4.3m distance), so overflow unlikely
        
        if(pulse_end >= pulse_start){
            // Normal case: no timer overflow occurred
            // Simple subtraction gives pulse width
            pulse_ticks = pulse_end - pulse_start;
        } else {
            // Timer overflow occurred during measurement
            // Example: start=65000, end=500, actual width=1535 ticks
            // Calculation: (65535-65000) + 500 + 1 = 1536 ticks
            pulse_ticks = (0xFFFF - pulse_start) + pulse_end + 1;
        }
        
        // ================================================================
        // Convert Timer Ticks to Microseconds
        // ================================================================
        // Timer resolution: 0.5μs per tick (prescaler 8, 16MHz clock)
        // pulse_us = pulse_ticks × 0.5 = pulse_ticks >> 1 (bit shift = divide by 2)
        // Bit shift is faster than multiplication/division
        uint32_t pulse_us = (uint32_t)pulse_ticks >> 1;
        
        // ================================================================
        // Calculate Distance from Echo Pulse Width
        // ================================================================
        // Speed of sound: ~343 m/s at 20°C
        // Distance = (pulse_width × speed_of_sound) / 2
        // The /2 is because sound travels TO object and BACK
        //
        // Formula: distance_cm = pulse_us / 58
        // Derivation: 343 m/s = 0.0343 cm/μs
        //            distance = (pulse_us × 0.0343) / 2 = pulse_us / 58.14
        //
        // Valid measurement range for HC-SR04:
        // Minimum: 2.5cm → 150μs echo time
        // Maximum: 400cm → 23,500μs echo time
        
        if(pulse_us >= 150 && pulse_us <= 23500){
            // Valid measurement within HC-SR04 specifications
            
            // Calculate distance in centimeters
            uint32_t new_distance = pulse_us / 58;
            
            // ============================================================
            // Update Circular Buffer for Filtering
            // ============================================================
            // Store new reading in circular buffer at current index
            distance_buffer[distance_index] = new_distance;
            
            // Advance index for next reading (0→1→2→0→1→2...)
            // Modulo operation wraps index back to 0 after reaching max
            distance_index = (distance_index + 1) % DISTANCE_SAMPLES;
            
            // Update global distance variable immediately
            // This provides latest reading while buffer maintains history
            distance_cm = new_distance;
            
        } else {
            // Invalid measurement (out of range or sensor error)
            // Possible causes:
            // - No echo received (object too far or too close)
            // - Echo too weak (soft/angled surface)
            // - Noise or interference
            distance_cm = 0;  // Signal invalid reading
        }
        
        // Set flag indicating new measurement is ready
        measurement_ready = 1;
        
        // Reset state machine for next measurement cycle
        edge_count = 0;
        
        // Reconfigure Input Capture back to RISING edge detection
        // Ready for next trigger pulse
        TCCR5B |= (1 << ICES5);
    }
}

// ========================================================================
// GET FILTERED DISTANCE - Signal Processing
// ========================================================================
// Averages last 3 distance readings to reduce sensor noise
// HC-SR04 can give spurious readings due to:
// - Ultrasonic reflections from multiple surfaces
// - Temperature/humidity variations
// - Acoustic interference
// Averaging provides more stable, reliable measurements
// ========================================================================

uint32_t get_filtered_distance(){
    
    // Accumulator for sum of valid readings
    uint32_t sum = 0;
    
    // Counter for valid (non-zero) readings in buffer
    uint8_t valid_count = 0;
    
    // Iterate through all samples in circular buffer
    for(uint8_t i = 0; i < DISTANCE_SAMPLES; i++){
        
        // Only include non-zero readings in average
        // Zero indicates invalid/out-of-range measurement
        if(distance_buffer[i] > 0){
            sum += distance_buffer[i];  // Accumulate distance
            valid_count++;              // Count valid sample
        }
    }
    
    // Calculate and return average if we have valid samples
    if(valid_count > 0){
        return sum / valid_count;  // Integer division (truncates decimal)
    }
    
    // If no valid samples in buffer, return current raw reading
    // This ensures system responds immediately to first valid reading
    return distance_cm;
}

// ========================================================================
// ADC INITIALIZATION - Analog to Digital Converter Setup
// ========================================================================
// Configures 10-bit ADC for water sensor readings
// ========================================================================

void initialise_ADC(){
    
    // ====================================================================
    // ADC Multiplexer Selection Register (ADMUX)
    // ====================================================================
    // REFS0 = 1, REFS1 = 0: Use AVcc as voltage reference (typically 5V)
    // This gives 0-1023 range corresponding to 0-5V input
    // Resolution: 5V / 1024 = 4.88mV per ADC step
    ADMUX = (1 << REFS0);
    
    // ====================================================================
    // ADC Control and Status Register A (ADCSRA)
    // ====================================================================
    // ADEN = 1:  Enable ADC (powers up ADC circuitry)
    // ADPS2:0 = 111: Prescaler = 128
    //   ADC clock = 16MHz / 128 = 125kHz
    //   Conversion time: 13 ADC cycles = 13/125kHz = 104μs per reading
    //   (Prescaler 128 provides good balance of speed and accuracy)
    ADCSRA = (1 << ADEN) | (1 << ADPS2) | (1 << ADPS1) | (1 << ADPS0);
}

// ========================================================================
// READ WATER SENSOR - Analog Measurement
// ========================================================================
// Performs single ADC conversion on channel 0 (A0)
// Blocking function: waits ~100μs for conversion to complete
// ========================================================================

uint16_t read_water_sensor(){
    
    // ====================================================================
    // Select ADC Channel 0 (Pin A0 / PF0)
    // ====================================================================
    // Keep upper 4 bits of ADMUX (reference voltage settings)
    // Set lower 4 bits to 0000 (selects ADC0)
    ADMUX = (ADMUX & 0xF0) | 0x00;
    
    // ====================================================================
    // Start ADC Conversion
    // ====================================================================
    // Set ADSC (ADC Start Conversion) bit
    // Hardware automatically clears this bit when conversion completes
    ADCSRA |= (1 << ADSC);
    
    // ====================================================================
    // Wait for Conversion to Complete (Blocking)
    // ====================================================================
    // Poll ADSC bit: remains HIGH during conversion, goes LOW when done
    // Typical conversion time: 104μs (13 ADC clock cycles at 125kHz)
    while (ADCSRA & (1 << ADSC));
    
    // ====================================================================
    // Return 10-bit Result
    // ====================================================================
    // ADC register contains result: 0-1023 (0x000-0x3FF)
    // Higher value = higher voltage = more conductive water
    return ADC;
}

// ========================================================================
// LED CONTROL - Active-Low Output
// ========================================================================
// Controls three LEDs with active-low logic (common anode configuration)
// Parameters: 0 = LED ON (pin LOW), 1 = LED OFF (pin HIGH)
// ========================================================================

void control_LEDS(uint8_t red, uint8_t yellow, uint8_t green){
    
    // ====================================================================
    // RED LED Control (Pin 2 - PE4)
    // ====================================================================
    if(!red)  // If red = 0 (turn on)
        PORTE &= ~(1 << PE4);  // Clear bit (set pin LOW) → LED ON
    else      // If red = 1 (turn off)
        PORTE |= (1 << PE4);   // Set bit (set pin HIGH) → LED OFF
    
    // ====================================================================
    // YELLOW LED Control (Pin 3 - PE5)
    // ====================================================================
    if(!yellow)
        PORTE &= ~(1 << PE5);  // Clear bit → LED ON
    else
        PORTE |= (1 << PE5);   // Set bit → LED OFF
    
    // ====================================================================
    // GREEN LED Control (Pin 4 - PG5)
    // ====================================================================
    if(!green)
        PORTG &= ~(1 << PG5);  // Clear bit → LED ON
    else
        PORTG |= (1 << PG5);   // Set bit → LED OFF
}

// ========================================================================
// BUZZER CONTROL - Digital Output
// ========================================================================
// Controls active buzzer (or can drive transistor for passive buzzer)
// Parameter: 1 = buzzer ON, 0 = buzzer OFF
// ========================================================================

void control_buzzer(uint8_t state){
    
    if (state) {
        // Turn buzzer ON
        // Set PE3 HIGH (5V output)
        // For active buzzer: directly powers buzzer
        // For passive buzzer: would need PWM for tone generation
        PORTE |= (1 << PE3);
    } else {
        // Turn buzzer OFF
        // Set PE3 LOW (0V output)
        PORTE &= ~(1 << PE3);
    }
}

/*
 * ========================================================================
 * END OF PROGRAM
 * ========================================================================
 * 
 * PERFORMANCE CHARACTERISTICS:
 * - Water sensor read time: ~100μs (ADC conversion)
 * - HC-SR04 measurement time: 150-23,500μs (2.5-400cm range)
 * - Main loop cycle: 1ms fixed
 * - Sensor update rate: 16.7Hz (60ms period)
 * - Distance averaging: 3-sample rolling average
 * - CPU utilization: <5% (mostly idle in delay loops)
 * 
 * TIMING DIAGRAM:
 * |<------- 60ms cycle ------->|
 * |  ADC  |  TRIG |    ISR     | Main Loop (×60)
 * |100μs  | 10μs  | <25ms max  | 1ms each
 * 
 * FUTURE IMPROVEMENTS:
 * 1. Add temperature compensation for ultrasonic measurements
 * 2. Implement median filter instead of average for better outlier rejection
 * 3. Add UART debug output for system diagnostics
 * 4. Power-cycle water sensor to reduce electrolysis
 * 5. Add PWM tone generation for passive buzzer support
 * 6. Implement exponential moving average for smoother distance readings
 * 7. Add calibration routine for water sensor threshold adjustment
 * 
 * ========================================================================
 */