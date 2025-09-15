import serial
import time

# --- 設定項目 ---
# Arduinoが接続されているCOMポート名を指定してください
# (Arduino IDEの「ツール」>「シリアルポート」で確認できます)
ARDUINO_PORT = 'COM3'  

# Arduinoのコードで設定した通信速度（ボーレート）
BAUD_RATE = 115200
# --- 設定はここまで ---


try:
    # シリアルポートへの接続を開始
    # timeout=2 は、2秒間データが来なければ読み取りを中断するという設定
    ser = serial.Serial(ARDUINO_PORT, BAUD_RATE, timeout=2)
    
    # Arduinoのリセットや接続の安定を待つために少し待機
    time.sleep(2) 
    print(f"ポート {ARDUINO_PORT} に接続しました。データ受信を開始します...")
    print("プログラムを終了するには Ctrl+C を押してください。")

    # データを受信し続けるための無限ループ
    while True:
        # Arduinoから1行分のデータを受信する
        line = ser.readline()
        
        # 受信したデータが空でなければ処理する
        if line:
            # 受信データはバイト形式なので、文字列に変換（デコード）する
            # .strip() は、文字列の前後の余白（改行コードなど）を削除する
            decoded_line = line.strip().decode('utf-8')
            
            # 画面に表示する
            print(decoded_line)

except serial.SerialException as e:
    # ポートが見つからない、または開けない場合のエラー処理
    print(f"エラー: ポート {ARDUINO_PORT} を開けませんでした。")
    print("・ArduinoがPCに接続されているか確認してください。")
    print("・ポート名が正しいか確認してください。")
    print("・Arduino IDEのシリアルモニタを閉じていますか？")
    print(f"詳細情報: {e}")

except KeyboardInterrupt:
    # Ctrl+C が押されたときにプログラムを安全に終了する処理
    print("\nプログラムを終了します。")
    ser.close() # シリアルポートを閉じる

except Exception as e:
    # その他の予期せぬエラー
    print(f"予期せぬエラーが発生しました: {e}")
    if 'ser' in locals() and ser.is_open:
        ser.close()