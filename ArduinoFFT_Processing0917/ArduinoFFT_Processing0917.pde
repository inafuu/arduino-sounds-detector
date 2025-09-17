 
// FFT Matcher (Arduino only) — Multi-Ref, Bands + JSD, Noise Profile, SPACE録音
// - 入力は Arduino のみ（SAMPLES=128 → BINS=64 を想定）
// - 類似度: Jensen–Shannon（0..1, 高いほど似ている）
// - N: ノイズプロファイル採取（押している間に静音→離して確定）
// - Energy Gate: 現在エネルギー < noise×比（energyGateRatio）なら判定停止（ノイズ一致を防ぐ）
// - SPACE長押しで参照追加（複数回OK）、Mで AVG/MAX 切替、[ ] で閾値

import processing.serial.*;
import java.util.*;

// ===== シリアル =====
Serial port;
final int BAUD = 115200;

// ===== FFT / 特徴量設定 =====
final int BINS = 64;              // Arduino: SAMPLES=128 → 64bin
final int DROP_DC = 1;            // DC(0番)を捨てる
final int NUM_BANDS = 12;         // 8〜16で調整可
final float SMOOTH_ALPHA = 0.10f; // 時間平滑（小さめ）
float threshold = 0.60f;          // JSD類似度の閾値（0..1）

// ===== 参照バンク（バンド特徴を保持；比較時にノイズ減算） =====
ArrayList<float[]> refBank = new ArrayList<float[]>();

// ===== ノイズプロファイル（バンド空間） =====
final float LN2 = 0.6931472f;
float[] noiseProfile = null;         // 長さ = NUM_BANDS
boolean noiseCalibratingBand = false;
float[] noiseAccumBand = null;
int noiseFramesBand = 0;
float energyGateRatio = 1.2f;        // 現在エネルギー < ノイズ×比 で判定停止

// ===== 現在フレーム =====
float[] currRaw = new float[BINS];   // 受信（Arduino）スペクトル
float[] currFeat = null;             // サブバンド（log→平均）
float[] currFeatSmoothed = null;     // 平滑後

// ===== 録音 =====
boolean recActive = false;
float[] recAccum = null; int recFrames = 0;

// ===== UI =====
Button recBtn;
String currentPortName = "N/A";
int[] bandStarts;
int simMode = 1; // 0=AVG(参照平均), 1=MAX(参照中の最大)

void settings(){ size(980, 640); }

void setup() {
  surface.setTitle("FFT Matcher (Arduino only) [NoiseProfile/SPACE/M]");
  //日本語が表示できるフォント "Meiryo"を指定
  textFont(createFont("Meiryo", 14));

  // Serial
  println("Serial ports:"); println(Serial.list());
  //一時的に下二行を無効化
  //String picked = pickDefaultPort();
  //currentPortName = picked;
  //ポート名を手動で選択
  String picked = "COM3";
  currentPortName = picked;
  port = new Serial(this, picked, BAUD);
  port.bufferUntil('\n');

  recBtn = new Button(20, 20, 360, 44, "長押しで録音（参照に追加） / SPACE でも可");

  // サブバンド境界（DC除去後を等分）
  int usable = BINS - DROP_DC;
  bandStarts = new int[NUM_BANDS + 1];
  for (int b = 0; b <= NUM_BANDS; b++) {
    bandStarts[b] = DROP_DC + round(b * (usable / (float)NUM_BANDS));
  }
}

String pickDefaultPort() {
  String[] ports = Serial.list();
  if (ports == null || ports.length == 0) exitWithMsg("シリアルポートが見つかりません。");
  for (String p : ports) if (p.contains("usbmodem") || p.contains("usbserial")) return p;
  return ports[0];
}

void draw() {
  background(250);

  // ===== 特徴抽出（log→バンド平均→平滑） =====
  float[] f = toBandFeature(currRaw);           // 生バンド
  // ノイズ採取中なら生バンドを蓄積（平滑前）
  if (noiseCalibratingBand) accumulateNoiseBand(f);

  if (currFeatSmoothed == null || currFeatSmoothed.length != f.length) {
    currFeatSmoothed = f.clone();
  } else {
    for (int i=0;i<f.length;i++) currFeatSmoothed[i] = lerp(currFeatSmoothed[i], f[i], SMOOTH_ALPHA);
  }
  currFeat = currFeatSmoothed;

  // 録音蓄積
  if (recActive && currFeat != null) {
    if (recAccum == null || recAccum.length != currFeat.length) { recAccum = new float[currFeat.length]; recFrames = 0; }
    for (int i=0;i<currFeat.length;i++) recAccum[i] += currFeat[i];
    recFrames++;
  }

  // ===== 類似度（内部でノイズ減算＆エネゲート） =====
  float sim = computeSimilarity(currFeat);

  // ===== 可視化 =====
  drawSpectraAutoScaled();        // 自動スケールの棒グラフ

  // バンド折れ線は「ノイズ減算後」を描く
  float[] visCurr = denoiseBand(currFeat);
  float[] visRef  = refBank.isEmpty() ? null : computeDenoisedCentroid();
  drawBands(visCurr, visRef);

  // ヘッダ
  fill(20);
  text("Port: " + currentPortName, 20, 90);
  if (noiseProfile != null) {
    text("Noise energy: " + nf(bandEnergy(noiseProfile),0,3) + "   EnergyGate×" + nf(energyGateRatio,0,2), 20, 110);
  } else {
    text("Noise profile: (未設定)  Nを押して静音サンプル→離して確定", 20, 110);
  }
  text("Refs: " + refBank.size() + "   Mode: " + (simMode==0?"AVG(参照平均)":"MAX(参照最大)") , 20, 130);
  text("Similarity (JSD): " + (Float.isNaN(sim)?"--":nf(sim,0,3)) +
       "   Threshold: " + nf(threshold,0,2) + "   ([ / ] で変更)", 20, 150);

  boolean match = (!Float.isNaN(sim) && sim >= threshold);
  noStroke(); fill(match ? color(60,200,80) : color(230,70,70)); circle(width-80, 60, 40);
  fill(255); textAlign(CENTER,CENTER); text(match?"一致":"非一致", width-80, 60); textAlign(LEFT,BASELINE);

  recBtn.setPressed(recActive); recBtn.draw();
  if (recActive) { fill(200,60,60); text("録音中: "+recFrames+" frames（離す→参照に追加 / SPACEでも可）", 320, 50); fill(20); }

  fill(80);
  text("操作: N=ノイズ採取 / 長押し=参照追加（ボタン or SPACE） / M=判定モード / C=参照クリア / [ ]=閾値", 20, height-20);
}

// ===== 類似度（JSDベース） =====
float computeSimilarity(float[] currRawBand) {
  if (currRawBand == null || refBank.isEmpty()) return Float.NaN;

  // 現在をノイズ減算
  float[] curr = denoiseBand(currRawBand);

  // エネルギーゲート（ノイズ比）
  if (noiseProfile != null) {
    float eCurr  = bandEnergy(curr);
    float eNoise = bandEnergy(noiseProfile);
    if (eCurr < eNoise * energyGateRatio) return Float.NaN; // ほぼノイズ
  }

  if (simMode == 0) { // AVG：参照（各項目を減算後）で動的にセントロイドを作る
    float[] cen = computeDenoisedCentroid();
    return jsdSimilarity(cen, curr);
  } else {            // MAX：各参照を減算して最大を採用
    float best = -1;
    for (float[] refRaw : refBank) {
      float[] ref = denoiseBand(refRaw);
      float s = jsdSimilarity(ref, curr);
      if (s > best) best = s;
    }
    return best;
  }
}

// ノイズ減算（マイナスは0にクリップ）
float[] denoiseBand(float[] band) {
  if (band == null) return null;
  if (noiseProfile == null) return band.clone();
  float[] out = new float[band.length];
  for (int i=0;i<band.length;i++) out[i] = max(0, band[i] - noiseProfile[i]);
  return out;
}

// バンドの総エネルギー（和）
float bandEnergy(float[] band) {
  float s = 0;
  for (float v : band) s += max(0, v);
  return s;
}

// 参照のノイズ減算後セントロイド
float[] computeDenoisedCentroid() {
  if (refBank.isEmpty()) return null;
  int d = refBank.get(0).length;
  float[] sum = new float[d];
  for (float[] r : refBank) {
    float[] rd = denoiseBand(r);
    for (int i=0;i<d;i++) sum[i] += rd[i];
  }
  for (int i=0;i<d;i++) sum[i] /= refBank.size();
  return sum;
}

// JSD 類似度（1が完全一致、0が極端に不一致）
float jsdSimilarity(float[] aBand, float[] bBand) {
  int n = aBand.length;
  float eps = 1e-9f;
  // 確率分布に正規化
  float sp = 0, sq = 0;
  for (int i=0;i<n;i++){ sp += max(0, aBand[i]); sq += max(0, bBand[i]); }
  sp = max(sp, eps); sq = max(sq, eps);

  float js = 0;
  for (int i=0;i<n;i++){
    float p = max(0, aBand[i]) / sp + eps;
    float q = max(0, bBand[i]) / sq + eps;
    float m = 0.5f * (p + q);
    js += 0.5f * (p * log(p / m) + q * log(q / m));
  }
  float sim = 1.0f - sqrt(max(0, js) / LN2);
  return constrain(sim, 0, 1);
}

// ===== ノイズ採取 =====
void accumulateNoiseBand(float[] f) {
  if (f == null) return;
  if (noiseAccumBand == null || noiseAccumBand.length != f.length) {
    noiseAccumBand = new float[f.length];
    noiseFramesBand = 0;
  }
  for (int i=0;i<f.length;i++) noiseAccumBand[i] += max(0, f[i]);
  noiseFramesBand++;
}
void finishNoiseCalibration() {
  if (noiseFramesBand > 0 && noiseAccumBand != null) {
    noiseProfile = new float[noiseAccumBand.length];
    for (int i=0;i<noiseProfile.length;i++) noiseProfile[i] = noiseAccumBand[i] / noiseFramesBand;
    println("Noise profile updated. frames=" + noiseFramesBand + ", energy=" + bandEnergy(noiseProfile));
  }
  noiseAccumBand = null; noiseFramesBand = 0; noiseCalibratingBand = false;
}

// ===== 可視化（自動スケール棒グラフ） =====
void drawSpectraAutoScaled() {
  int left=20, right=width-20, top=210, bottom=height-80;
  stroke(200); noFill(); rect(left, top, right-left, bottom-top);

  int n = BINS - DROP_DC;
  float w = (right-left)/(float)n;

  // 表示用に log 圧縮後の最大値でスケール
  float[] disp = new float[n];
  float vmax = 1e-12f;
  for (int i=0;i<n;i++) {
    float v = currRaw[i+DROP_DC];
    float lv = log(1 + max(0, v));
    disp[i] = lv;
    if (lv > vmax) vmax = lv;
  }

  noStroke(); fill(120,160,255,180);
  if (vmax <= 1e-10f) return; // ほぼ0：棒は描かない
  for (int i=0;i<n;i++) {
    float h = map(disp[i], 0, vmax, 0, bottom-top); // 自動スケール
    rect(left + i*w, bottom - h, w*0.9, h);
  }
}

void drawBands(float[] curr, float[] refAvg) {
  int left=20, right=width-20, top=210, bottom=height-80;
  float wb = (right-left)/(float)NUM_BANDS;

  if (curr != null) {
    float vmax = 1e-9f; for (float v: curr) vmax = max(vmax, v);
    stroke(60,80,170,200); strokeWeight(2); noFill();
    beginShape();
    for (int i=0;i<curr.length;i++) {
      float y = map(curr[i], 0, vmax, bottom, top);
      float x = left + i*wb + wb*0.5f;
      vertex(x, y);
    }
    endShape();
    fill(60,80,170); noStroke(); text("現在(バンド, ノイズ減算後)", right-260, top-10);
  }
  if (refAvg != null) {
    float vmax = 1e-9f; for (float v: refAvg) vmax = max(vmax, v);
    stroke(40,180,120); strokeWeight(2); noFill();
    beginShape();
    for (int i=0;i<refAvg.length;i++) {
      float y = map(refAvg[i], 0, vmax, bottom, top);
      float x = left + i*wb + wb*0.5f;
      vertex(x, y);
    }
    endShape();
    fill(40,180,120); noStroke(); text("参照平均(バンド, ノイズ減算後)", right-320, top-28);
  }
}

// ===== 特徴量処理 =====
float[] toBandFeature(float[] raw) {
  float[] logmag = new float[BINS];
  for (int i=0;i<BINS;i++) logmag[i] = (i < DROP_DC) ? 0 : log(1 + max(0, raw[i]));
  float[] band = new float[NUM_BANDS];
  for (int b=0;b<NUM_BANDS;b++) {
    int s = bandStarts[b], e = bandStarts[b+1];
    float sum = 0; int cnt = max(1, e - s);
    for (int i=s;i<e;i++) sum += logmag[i];
    band[b] = sum / cnt;
  }
  return band;
}

// ===== 参照管理 =====
void addReference(float[] feat) {
  // 参照は"生のバンド"で保持（比較時に最新ノイズで減算）
  refBank.add(feat.clone());
  println("Added reference. Refs=" + refBank.size() + ", energy=" + bandEnergy(feat));
}
void clearReferences(){
  refBank.clear();
  println("References cleared.");
}

// ===== Serial (Arduino) =====
void serialEvent(Serial p) {
  String line = p.readStringUntil('\n');
  if (line == null) return;
  line = trim(line);
  if (line.isEmpty()) return;
  String[] toks = splitTokens(line, " \t,;");
  int n = min(toks.length, BINS);
  if (n < BINS*0.6f) return;
  for (int i=0;i<n;i++) {
    try { currRaw[i] = float(toks[i]); } catch(Exception e) {}
  }
}

// ===== 録音（ボタン/SPACE 共通） =====
void startRecording() {
  if (recActive) return;
  recActive = true; recAccum = null; recFrames = 0;
}
void stopRecordingAndAdd() {
  if (!recActive) return;
  recActive = false;
  float[] capture = null;
  if (recFrames > 0 && recAccum != null) {
    capture = new float[recAccum.length];
    for (int i=0;i<capture.length;i++) capture[i] = recAccum[i] / recFrames;
  } else if (currFeat != null) {
    capture = currFeat.clone();
  }
  if (capture != null) addReference(capture);
}

// ===== キーイベント =====
void keyPressed() {
  if (key == ' ') { startRecording(); return; }
  if (key == '[') threshold = max(0.0f, threshold - 0.01f);
  if (key == ']') threshold = min(1.0f, threshold + 0.01f);
  if (key == 'c' || key == 'C') clearReferences();
  if (key == 'm' || key == 'M') simMode = 1 - simMode;   // AVG ↔ MAX
  if (key == 'n' || key == 'N') { noiseCalibratingBand = true; noiseAccumBand = null; noiseFramesBand = 0; }
}
void keyReleased() { 
  if (key == ' ') stopRecordingAndAdd(); 
  if (key == 'n' || key == 'N') { finishNoiseCalibration(); }
}

void exitWithMsg(String msg){ println(msg); exit(); }

// ========== はみ出し防止つきボタン ==========
class Button {
  int x, y, w, h; String label; boolean pressed = false;
  int corner = 10; float padX = 12, padY = 8; float baseSize = 14; float minSize = 10;
  Button(int x, int y, int w, int h, String label){ this.x=x; this.y=y; this.w=w; this.h=h; this.label=label; }
  void setPressed(boolean v){ pressed=v; }
  boolean hit(int mx,int my){ return (mx>=x && mx<=x+w && my>=y && my<=y+h); }
  void draw(){
    pushStyle();
    textSize(baseSize);
    float neededW = textWidth(label) + padX * 2;
    int maxW = width - x - 20;
    if (neededW > w) w = (int)min(neededW, maxW);
    float availW = w - padX * 2, tw = textWidth(label), drawSize = baseSize;
    if (tw > availW) drawSize = max(minSize, baseSize * (availW / (tw + 0.0001f)));
    stroke(180); fill(pressed ? color(255,120,120) : color(255)); rect(x,y,w,h,corner);
    fill(pressed ? 255 : 30); textAlign(CENTER,CENTER); textSize(drawSize); text(label, x+w/2f, y+h/2f);
    popStyle();
  }
}
