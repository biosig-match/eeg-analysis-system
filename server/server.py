import os
import io
import base64
import zstandard
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from flask import Flask, request, jsonify
from collections import deque
import threading
import time
import queue
import sqlite3
import struct
import traceback

# MNEライブラリのインポート
try:
    import mne
    from mne_connectivity import spectral_connectivity_epochs
    from mne_connectivity.viz import plot_connectivity_circle
    MNE_AVAILABLE = True
except ImportError:
    MNE_AVAILABLE = False

# --- 設定 ---
HOST = '0.0.0.0'
PORT = 5000
SAMPLE_RATE = 300
NUM_EEG_CHANNELS = 8
# ★★★★★ 標準的な10-20法の名前に変更 ★★★★★
CHANNEL_NAMES = ['Fp1', 'Fp2', 'F7', 'F8', 'T7', 'T8', 'P7', 'P8'] 
ANALYSIS_WINDOW_SEC = 2.0
ANALYSIS_WINDOW_SAMPLES = int(SAMPLE_RATE * ANALYSIS_WINDOW_SEC)
DB_FILE = 'eeg_data.db'

# --- Flask & スレッド間データ共有のセットアップ ---
app = Flask(__name__)
db_queue = queue.Queue()
latest_analysis_results = {}
analysis_lock = threading.Lock()
initial_data_received = threading.Event()

if MNE_AVAILABLE:
    mne_info = mne.create_info(ch_names=CHANNEL_NAMES, sfreq=SAMPLE_RATE, ch_types='eeg')
    # ★★★★★ 10-20法の電極位置情報（モンタージュ）を設定 ★★★★★
    try:
        montage = mne.channels.make_standard_montage('standard_1020')
        mne_info.set_montage(montage, on_missing='warn')
    except Exception as e:
        print(f"Warning: Could not set montage. Spatial colors might not work. Error: {e}")

# (以降のコードは、MNE解析関数以外は変更ありません)
def init_db():
    if os.path.exists(DB_FILE):
        os.remove(DB_FILE)
    conn = sqlite3.connect(DB_FILE)
    c = conn.cursor()
    channel_cols = ', '.join([f'{name} INTEGER' for name in CHANNEL_NAMES])
    c.execute(f'''CREATE TABLE IF NOT EXISTS eeg_data (id INTEGER PRIMARY KEY AUTOINCREMENT, server_timestamp REAL DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f', 'NOW')), esp32_timestamp_us REAL, {channel_cols})''')
    conn.commit()
    conn.close()
def db_writer_thread():
    conn = sqlite3.connect(DB_FILE, check_same_thread=False)
    c = conn.cursor()
    placeholders = ', '.join(['?'] * NUM_EEG_CHANNELS)
    insert_sql = f'INSERT INTO eeg_data (esp32_timestamp_us, {", ".join(CHANNEL_NAMES)}) VALUES (?, {placeholders})'
    while True:
        try:
            records_to_insert = db_queue.get()
            c.executemany(insert_sql, records_to_insert)
            conn.commit()
            if not initial_data_received.is_set():
                initial_data_received.set()
        except Exception as e:
            print(f"DB Writer Error: {e}")
def create_analysis_thread(target_func, interval_sec):
    def worker():
        print(f"Analysis thread '{target_func.__name__}' waiting for initial data...")
        initial_data_received.wait() 
        print(f"Analysis thread '{target_func.__name__}' started.")
        while True:
            try:
                conn = sqlite3.connect(DB_FILE, check_same_thread=False)
                c = conn.cursor()
                query = f"SELECT {', '.join(CHANNEL_NAMES)} FROM eeg_data ORDER BY id DESC LIMIT {ANALYSIS_WINDOW_SAMPLES}"
                c.execute(query)
                rows = c.fetchall()
                conn.close()
                data = np.array(rows, dtype=np.float64)
                if data.shape[0] >= ANALYSIS_WINDOW_SAMPLES:
                    target_func(data)
            except Exception as e:
                print(f"Error in {target_func.__name__}: {e}")
            time.sleep(interval_sec)
    thread = threading.Thread(target=worker, daemon=True)
    return thread

def analyze_psd(data):
    global latest_analysis_results
    data_in_microvolts = (data.T.astype(np.float64) - 2048.0) * (200.0 / 2048.0)
    raw = mne.io.RawArray(data_in_microvolts * 1e-6, mne_info, verbose=False)
    
    fig_psd = raw.compute_psd(fmin=1.0, fmax=45.0, n_fft=SAMPLE_RATE, verbose=False).plot(
        average=False, spatial_colors=True, show=False
    )
    psd_img_base64 = fig_to_base64(fig_psd)
    with analysis_lock:
        latest_analysis_results['psd_image'] = psd_img_base64
    print(f"Analysis complete: PSD")

def analyze_coherence(data):
    global latest_analysis_results
    data_in_microvolts = (data.T.astype(np.float64) - 2048.0) * (200.0 / 2048.0)
    raw = mne.io.RawArray(data_in_microvolts * 1e-6, mne_info, verbose=False)
    epochs_data = raw.get_data()[np.newaxis, :, :]
    con = spectral_connectivity_epochs(epochs_data, method='coh', sfreq=SAMPLE_RATE, fmin=8, fmax=13, faverage=True, verbose=False) # Alpha band
    con_matrix = np.squeeze(con.get_data(output='dense'))
    fig_coh, ax = plt.subplots(figsize=(5, 5), subplot_kw=dict(polar=True))
    plot_connectivity_circle(con_matrix, CHANNEL_NAMES, n_lines=20, vmin=0, vmax=1, colormap='viridis', ax=ax, show=False)
    coh_img_base64 = fig_to_base64(fig_coh)
    with analysis_lock:
        latest_analysis_results['coherence_image'] = coh_img_base64
    print("Analysis complete: Coherence")

def fig_to_base64(fig):
    buf = io.BytesIO()
    fig.savefig(buf, format='png', bbox_inches='tight', pad_inches=0.1)
    plt.close(fig)
    buf.seek(0)
    return base64.b64encode(buf.getvalue()).decode('utf-8')

@app.route('/upload', methods=['POST'])
def upload_endpoint():
    json_data = request.get_json()
    if not json_data or 'data' not in json_data:
        return jsonify({"error": "Missing data"}), 400
    try:
        compressed_data = base64.b64decode(json_data['data'])
        raw_bytes = zstandard.ZstdDecompressor().decompress(compressed_data)
        point_size = 68
        struct_format = '<' + 'H'*NUM_EEG_CHANNELS + 'f'*12 + 'I'
        records = []
        for chunk in struct.iter_unpack(struct_format, raw_bytes):
            timestamp = chunk[-1]
            eeg_values = chunk[:NUM_EEG_CHANNELS]
            records.append((timestamp, *eeg_values))
        db_queue.put(records)
        return jsonify({"status": "data queued for db insert"})
    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": str(e)}), 500

@app.route('/results', methods=['GET'])
def results_endpoint():
    with analysis_lock:
        if not latest_analysis_results:
            return jsonify({"status": "analysis pending..."})
        return jsonify(latest_analysis_results)

if __name__ == '__main__':
    init_db()
    threading.Thread(target=db_writer_thread, daemon=True).start()
    create_analysis_thread(analyze_psd, 10.0).start()
    create_analysis_thread(analyze_coherence, 12.0).start()
    print("="*50)
    print(" EEG Analysis Server (Final Architecture)")
    print(f" Listening on http://{HOST}:{PORT}")
    print("="*50)
    app.run(host=HOST, port=PORT, debug=False)
