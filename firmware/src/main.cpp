#include <Arduino.h>
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include "zstd.h"
#include <string.h>
#include <math.h>

// (中略：設定は変更なし)
#define NUM_EEG_CHANNELS 8
#define USE_DUMMY_DATA 1
const int EEG_PINS[NUM_EEG_CHANNELS] = {A0, A1, A2, A3, A4, A5, 7, 8}; 
#define MPU1_AD0_PIN 3
#define MPU2_AD0_PIN 4
#define SAMPLE_RATE 300
#define SAMPLES_PER_PACKET (SAMPLE_RATE / 2)
#define TIMER_INTERVAL_US (1000000 / SAMPLE_RATE)
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"

// ★★★★★ 構造体に `__attribute__((packed))` を追加 ★★★★★
struct __attribute__((packed)) SensorData { 
    uint16_t eeg[NUM_EEG_CHANNELS]; 
    float acc_x1, acc_y1, acc_z1; 
    float gyro_x1, gyro_y1, gyro_z1; 
    float acc_x2, acc_y2, acc_z2; 
    float gyro_x2, gyro_y2, gyro_z2; 
    uint32_t timestamp; 
};

// (中略：グローバル変数、コールバック、タイマー、MPU切り替え、データ生成関数は変更なし)
Adafruit_MPU6050 mpu; hw_timer_t *timer = nullptr; portMUX_TYPE timerMux = portMUX_INITIALIZER_UNLOCKED; volatile bool sampleFlag = false;
BLEServer* pServer = nullptr; BLECharacteristic* pTxCharacteristic = nullptr;
bool deviceConnected = false; bool oldDeviceConnected = false;
SensorData sensorDataBuffer[SAMPLES_PER_PACKET]; volatile int sampleCounter = 0; const size_t RAW_DATA_SIZE = sizeof(sensorDataBuffer);
uint8_t* compressedBuffer = nullptr; ZSTD_CCtx* cctx = NULL;
volatile bool canSendData = true;
class MyCharacteristicCallbacks: public BLECharacteristicCallbacks { void onWrite(BLECharacteristic *pCharacteristic) { std::string value = pCharacteristic->getValue(); if (value.length() > 0) { Serial.println("ACK received from client. Ready to send next packet."); canSendData = true; } } };
class MyServerCallbacks: public BLEServerCallbacks { void onConnect(BLEServer* pServer) { deviceConnected = true; canSendData = true; Serial.println("BLE Client Connected"); }; void onDisconnect(BLEServer* pServer) { deviceConnected = false; Serial.println("BLE Client Disconnected"); } };
void IRAM_ATTR onTimer() { portENTER_CRITICAL_ISR(&timerMux); if (sampleCounter < SAMPLES_PER_PACKET) { sampleFlag = true; } portEXIT_CRITICAL_ISR(&timerMux); }
void switchMPU(bool selectMPU1) { digitalWrite(MPU1_AD0_PIN, selectMPU1 ? LOW : HIGH); digitalWrite(MPU2_AD0_PIN, selectMPU1 ? HIGH : LOW); delayMicroseconds(100); }
void generate_dummy_sensor_data(SensorData* data_ptr, int index) { data_ptr->timestamp = micros(); float time = data_ptr->timestamp / 1000000.0f; for (int ch = 0; ch < NUM_EEG_CHANNELS; ch++) { float alpha_freq = 10.0f + sin(time / 15.0f + ch); float alpha_wave = sin(2.0 * PI * alpha_freq * time + ch * 0.5); float beta_freq = 20.0f + sin(time / 8.0f - ch); float beta_wave = sin(2.0 * PI * beta_freq * time + ch * 1.0); float theta_freq = 6.0f; float theta_wave = sin(2.0 * PI * theta_freq * time + ch * 1.5); float alpha_amplitude = 200.0f * (0.5f + 0.5f * sin(2.0 * PI * 0.1f * time + ch)); float beta_amplitude = 80.0f * (0.5f + 0.5f * cos(2.0 * PI * 0.07f * time + ch)); float theta_amplitude = 120.0f; float combined_wave = alpha_amplitude * alpha_wave + beta_amplitude * beta_wave + theta_amplitude * theta_wave; static float noise1 = 0, noise2 = 0, noise3 = 0; noise1 = noise1 * 0.95f + (random(-100, 100) / 10.0f); noise2 = noise2 * 0.85f + (random(-100, 100) / 10.0f); noise3 = noise3 * 0.75f + (random(-100, 100) / 10.0f); int16_t final_value = 2048 + (int16_t)(combined_wave + noise1 + noise2 + noise3 + random(-30, 30)); data_ptr->eeg[ch] = max(0, min(4095, (int)final_value)); } data_ptr->acc_x1 = sin(2.0 * PI * 2.0 * time); data_ptr->acc_y1 = cos(2.0 * PI * 2.0 * time); data_ptr->acc_z1 = sin(2.0 * PI * 2.0 * time) * -1.0; data_ptr->gyro_x1 = sin(2.0 * PI * 5.0 * time) * 10.0; data_ptr->gyro_y1 = cos(2.0 * PI * 5.0 * time) * 10.0; data_ptr->gyro_z1 = sin(2.0 * PI * 5.0 * time) * -10.0; data_ptr->acc_x2 = cos(2.0 * PI * 3.0 * time); data_ptr->acc_y2 = sin(2.0 * PI * 3.0 * time); data_ptr->acc_z2 = cos(2.0 * PI * 3.0 * time) * -1.0; data_ptr->gyro_x2 = cos(2.0 * PI * 6.0 * time) * 10.0; data_ptr->gyro_y2 = sin(2.0 * PI * 6.0 * time) * 10.0; data_ptr->gyro_z2 = cos(2.0 * PI * 6.0 * time) * -10.0; }
void read_real_sensor_data(SensorData* data_ptr) { data_ptr->timestamp = micros(); for (int i = 0; i < NUM_EEG_CHANNELS; i++) { data_ptr->eeg[i] = analogRead(EEG_PINS[i]); } sensors_event_t a, g, temp; switchMPU(true); mpu.getEvent(&a, &g, &temp); data_ptr->acc_x1 = a.acceleration.x; data_ptr->acc_y1 = a.acceleration.y; data_ptr->acc_z1 = a.acceleration.z; data_ptr->gyro_x1 = g.gyro.x; data_ptr->gyro_y1 = g.gyro.y; data_ptr->gyro_z1 = g.gyro.z; switchMPU(false); mpu.getEvent(&a, &g, &temp); data_ptr->acc_x2 = a.acceleration.x; data_ptr->acc_y2 = a.acceleration.y; data_ptr->acc_z2 = a.acceleration.z; data_ptr->gyro_x2 = g.gyro.x; data_ptr->gyro_y2 = g.gyro.y; data_ptr->gyro_z2 = g.gyro.z; }

void setup() {
    Serial.begin(115200); delay(2000); 
    Serial.println("--- ESP32-S3 BLE Sensor Device v5.1 (Packed Struct) ---");
    
    // ★★★★★ 構造体の実際のサイズをシリアルに出力 ★★★★★
    Serial.printf("Size of SensorData struct: %d bytes\n", sizeof(SensorData));

    Serial.printf("Mode: %s, Channels: %d\n", USE_DUMMY_DATA ? "Dummy" : "Real", NUM_EEG_CHANNELS);
    #if !USE_DUMMY_DATA
      for(int i=0; i<NUM_EEG_CHANNELS; i++) { pinMode(EEG_PINS[i], INPUT); }
    #endif
    pinMode(MPU1_AD0_PIN, OUTPUT); pinMode(MPU2_AD0_PIN, OUTPUT);
    #if !USE_DUMMY_DATA
        Wire.begin(); Wire.setClock(400000);
        switchMPU(true); delay(50); if (!mpu.begin()) { Serial.println("MPU6050 #1 failed!"); } else { Serial.println("MPU6050 #1 initialized"); mpu.setAccelerometerRange(MPU6050_RANGE_8_G); mpu.setGyroRange(MPU6050_RANGE_500_DEG); mpu.setFilterBandwidth(MPU6050_BAND_94_HZ); }
        switchMPU(false); delay(50); if (!mpu.begin()) { Serial.println("MPU6050 #2 failed!"); } else { Serial.println("MPU6050 #2 initialized"); mpu.setAccelerometerRange(MPU6050_RANGE_8_G); mpu.setGyroRange(MPU6050_RANGE_500_DEG); mpu.setFilterBandwidth(MPU6050_BAND_94_HZ); }
    #endif
    Serial.printf("Raw data size per packet: %u bytes\n", (unsigned int)RAW_DATA_SIZE); size_t const compressedBufferSize = ZSTD_compressBound(RAW_DATA_SIZE); compressedBuffer = new uint8_t[compressedBufferSize]; if (compressedBuffer == NULL) { Serial.println("Failed to allocate memory for compression! Halting."); while(1); } cctx = ZSTD_createCCtx(); if (cctx == NULL) { Serial.println("ZSTD_createCCtx() failed! Halting."); while(1); } Serial.printf("Compression buffer allocated: %u bytes\n", (unsigned int)compressedBufferSize);
    BLEDevice::init("ESP32_Sensor_Compressed");
    pServer = BLEDevice::createServer(); pServer->setCallbacks(new MyServerCallbacks());
    BLEService *pService = pServer->createService(SERVICE_UUID);
    pTxCharacteristic = pService->createCharacteristic(CHARACTERISTIC_UUID_TX, BLECharacteristic::PROPERTY_NOTIFY);
    pTxCharacteristic->addDescriptor(new BLE2902());
    BLECharacteristic *pRxCharacteristic = pService->createCharacteristic(CHARACTERISTIC_UUID_RX, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
    pRxCharacteristic->setCallbacks(new MyCharacteristicCallbacks());
    pService->start();
    BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID); pAdvertising->setScanResponse(false); pAdvertising->setMinPreferred(0x0);
    BLEDevice::startAdvertising(); Serial.println("BLE advertising started. Waiting for client...");
    timer = timerBegin(0, 80, true);
    timerAttachInterrupt(timer, &onTimer, true);
    timerAlarmWrite(timer, TIMER_INTERVAL_US, true);
    timerAlarmEnable(timer);
    Serial.println("-------------------------------------------"); Serial.println("System ready.");
}

void loop() {
    if (sampleFlag) {
        portENTER_CRITICAL(&timerMux); sampleFlag = false; portEXIT_CRITICAL(&timerMux);
#if USE_DUMMY_DATA
        generate_dummy_sensor_data(&sensorDataBuffer[sampleCounter], sampleCounter);
#else
        read_real_sensor_data(&sensorDataBuffer[sampleCounter]);
#endif
        sampleCounter++;
    }

    if (sampleCounter >= SAMPLES_PER_PACKET) {
        if (deviceConnected && canSendData) {
            canSendData = false;
            
            // ★★★★★ 最初の数バイトをデバッグ出力 ★★★★★
            Serial.println("First 20 bytes of raw data buffer (HEX):");
            for(int i=0; i<20; i++) {
                Serial.printf("%02X ", ((uint8_t*)sensorDataBuffer)[i]);
            }
            Serial.println();

            Serial.printf("Packet full. Compressing %d samples (%d bytes)...\n", SAMPLES_PER_PACKET, RAW_DATA_SIZE);
            size_t const compressedSize = ZSTD_compress2(cctx, compressedBuffer, ZSTD_compressBound(RAW_DATA_SIZE), sensorDataBuffer, RAW_DATA_SIZE);
            if (ZSTD_isError(compressedSize)) {
                Serial.printf("Compression failed: %s\n", ZSTD_getErrorName(compressedSize));
                canSendData = true;
            } else {
                Serial.printf("Compression successful. Compressed size: %u bytes\n", (unsigned int)compressedSize);
                uint32_t header = (uint32_t)compressedSize;
                size_t totalSize = sizeof(header) + compressedSize;
                uint8_t* sendBuffer = new uint8_t[totalSize];
                if (sendBuffer != NULL) {
                    memcpy(sendBuffer, &header, sizeof(header));
                    memcpy(sendBuffer + sizeof(header), compressedBuffer, compressedSize);
                    const int max_chunk_size = 500;
                    size_t bytes_sent = 0;
                    while(bytes_sent < totalSize) {
                        size_t chunk_size = totalSize - bytes_sent;
                        if (chunk_size > max_chunk_size) { chunk_size = max_chunk_size; }
                        pTxCharacteristic->setValue(sendBuffer + bytes_sent, chunk_size);
                        pTxCharacteristic->notify();
                        bytes_sent += chunk_size;
                    }
                    Serial.printf("Header (%d bytes) + Data (%d bytes) sent. Waiting for ACK...\n", sizeof(header), compressedSize);
                    delete[] sendBuffer;
                    sampleCounter = 0;
                } else { 
                    Serial.println("Failed to allocate sendBuffer!");
                    canSendData = true;
                }
            }
        } else if (!deviceConnected) {
             sampleCounter = 0;
             Serial.println("Packet full, but no BLE client connected. Discarding data."); 
        }
    }
    
    if (!deviceConnected && oldDeviceConnected) { 
        delay(500); 
        pServer->startAdvertising(); 
        Serial.println("Restart advertising"); 
        oldDeviceConnected = deviceConnected; 
    }
    if (deviceConnected && !oldDeviceConnected) { 
        oldDeviceConnected = deviceConnected; 
    }
}