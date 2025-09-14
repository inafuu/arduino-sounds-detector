#include "arduinoFFT.h"

#define SAMPLES 64
#define SAMPLING_FREQUENCY 2048
#define MIC_PIN A0

ArduinoFFT<double> FFT = ArduinoFFT<double>();

unsigned int sampling_period_us;
double vReal[SAMPLES];
double vImag[SAMPLES];

void setup() {
  Serial.begin(115200);
  sampling_period_us = round(1000000 * (1.0 / SAMPLING_FREQUENCY));
}

void loop() {
  // 1. マイクから音をSAMPLESの数だけ連続で素早く拾う
  for (int i = 0; i < SAMPLES; i++) {
    vReal[i] = analogRead(MIC_PIN);
    vImag[i] = 0;
    delayMicroseconds(sampling_period_us);
  }

  // 2. FFTを実行して周波数成分に分解する（関数名を小文字始まりに修正）
  FFT.windowing(vReal, SAMPLES, FFT_WIN_TYP_HAMMING, FFT_FORWARD);
  FFT.compute(vReal, vImag, SAMPLES, FFT_FORWARD);
  FFT.complexToMagnitude(vReal, vImag, SAMPLES);

  // 3. 結果（各周波数帯の強さ）をPCに送信する
  for (int i = 0; i < (SAMPLES / 2); i++) {
    if (vReal[i] > 100) { 
      Serial.print(vReal[i]);
    } else {
      Serial.print(0);
    }
    Serial.print(" ");
  }
  Serial.println();
}