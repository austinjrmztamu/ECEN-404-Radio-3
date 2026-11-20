import tkinter as tk
from collections import deque
from tkinter import ttk

import queue
import threading

import numpy as np
import serial
import sounddevice as sd
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
from matplotlib.figure import Figure
from scipy.signal import butter, sosfilt, sosfilt_zi
from serial.tools import list_ports


BAUD_RATE = 2_000_000
SAMPLE_RATE = 48_000
AUDIO_BLOCK_SIZE = 480       # 10 ms at 48 kHz
AUDIO_CHANNELS = 1

#fan control commands
FAN_OVERRIDE_OFF = 0xC0
FAN_OVERRIDE_ON = 0xC1

TX_QUEUE_BLOCKS = 20         # 200 ms maximum queued TX audio
RX_QUEUE_BLOCKS = 30         # 300 ms hard limit; oldest audio is dropped
RX_PREFILL_BLOCKS = 5        # 50 ms playback buffer before speaker starts

RX_FILTER_LOW_HZ = 200
RX_FILTER_HIGH_HZ = 20000
RX_FADE_SECONDS = 0.10
RX_GAIN_MAX = 50.0
RX_GAIN_RAMP_SAMPLES = int(0.010 * SAMPLE_RATE)

PLOT_WINDOW_SECONDS = 0.10
PLOT_SAMPLES = int(PLOT_WINDOW_SECONDS * SAMPLE_RATE)
PLOT_REFRESH_MS = 40

# Leave False for microphone transmission.  This remains available for the
# controlled DAC tests developed earlier.
TX_TEST_MODE = False
DAC_TEST_CODE = 2048

RX_FILTER_SOS = butter(
    4,
    [RX_FILTER_LOW_HZ, RX_FILTER_HIGH_HZ],
    btype="bandpass",
    fs=SAMPLE_RATE,
    output="sos",
)

uart = None
program_closing = False

#to prevent audio and GUI commands from writing UART at the same time
uart_write_lock = threading.Lock()

tx_input_stream = None
tx_audio_queue = None
tx_worker_thread = None

tx_blocks_sent = 0
tx_samples_sent = 0
tx_dropped_blocks = 0
rx_worker_thread = None
rx_stop_event = threading.Event()
rx_output_stream = None
rx_play_queue = None

rx_filter_state = None
rx_fade_position = 0
rx_playback_armed = False
rx_monitor_enabled = True
rx_gain_target = 1.0  # GUI writes this float; worker never accesses Tk variables.
rx_gain_current = 1.0
rx_gain_clipping = False

rx_blocks_received = 0
rx_samples_received = 0
rx_invalid_bytes = 0
rx_queue_overflows = 0
rx_output_underflows = 0

# Workers report errors through this queue.  Tkinter reads it from its own
# thread during the plot timer callback.
ui_event_queue = queue.Queue()
tx_plot_lock = threading.Lock()
rx_plot_lock = threading.Lock()

tx_plot_buffer = deque([0.0] * PLOT_SAMPLES, maxlen=PLOT_SAMPLES)
rx_plot_buffer = deque([0.0] * PLOT_SAMPLES, maxlen=PLOT_SAMPLES)


def reset_plot_buffer(plot_buffer, plot_lock):
    """Return one plot to a quiet, full-width trace."""
    with plot_lock:
        plot_buffer.clear()
        plot_buffer.extend([0.0] * PLOT_SAMPLES)


def append_plot_samples(plot_buffer, plot_lock, samples):
    """Append samples without allowing a worker to touch Matplotlib."""
    with plot_lock:
        plot_buffer.extend(np.asarray(samples).reshape(-1).tolist())


def queue_latest_block(work_queue, block):
    """Keep RX latency bounded by dropping the oldest queued block."""
    try:
        work_queue.put_nowait(block)
        return False
    except queue.Full:
        try:
            work_queue.get_nowait()
        except queue.Empty:
            pass

        try:
            work_queue.put_nowait(block)
        except queue.Full:
            return True

        return True


def place_worker_stop(work_queue):
    """Insert a worker sentinel without hanging if the queue is full."""
    if work_queue is None:
        return

    while True:
        try:
            work_queue.put_nowait(None)
            return
        except queue.Full:
            try:
                work_queue.get_nowait()
            except queue.Empty:
                return

def convert_to_dac_samples(audio_block):
    pcm_samples = audio_block[:, 0].astype(np.int32)
    dac_samples = (pcm_samples + 32768) >> 4
    return dac_samples.astype(np.uint16)


def frame_dac_samples(dac_samples):
    """Frame one 12-bit sample as 01LLLLLL followed by 10HHHHHH."""
    first_bytes = 0x40 | (dac_samples & 0x3F)
    second_bytes = 0x80 | ((dac_samples >> 6) & 0x3F)

    framed_bytes = np.empty(dac_samples.size * 2, dtype=np.uint8)
    framed_bytes[0::2] = first_bytes
    framed_bytes[1::2] = second_bytes
    return framed_bytes

def tx_audio_callback(indata, frames, time_info, status):
    """PortAudio producer callback; it must never block on serial traffic."""
    global tx_dropped_blocks

    if status:
        print("TX audio status:", status)

    work_queue = tx_audio_queue
    if work_queue is None:
        return

    if queue_latest_block(work_queue, indata.copy()):
        tx_dropped_blocks += 1


def tx_uart_worker(work_queue, serial_port):
    global tx_blocks_sent
    global tx_samples_sent

    print("TX worker started")

    try:
        while True:
            audio_block = work_queue.get()

            if audio_block is None:
                break

            if TX_TEST_MODE:
                dac_samples = np.full(
                    audio_block.shape[0],
                    DAC_TEST_CODE,
                    dtype=np.uint16,
                )
            else:
                dac_samples = convert_to_dac_samples(audio_block)

            serial_data = frame_dac_samples(dac_samples).tobytes()

            with uart_write_lock:
                bytes_written = serial_port.write(serial_data)

            if bytes_written != len(serial_data):
                raise serial.SerialTimeoutException(
                    f"Only {bytes_written} of {len(serial_data)} bytes written"
                )

            tx_blocks_sent += 1
            tx_samples_sent += len(dac_samples)

            # The TX trace represents blocks that were actually written.
            normalized_audio = (
                audio_block[:, 0].astype(np.float32) / 32768.0
            )
            append_plot_samples(
                tx_plot_buffer,
                tx_plot_lock,
                normalized_audio,
            )

    except (serial.SerialException, OSError) as error:
        ui_event_queue.put(("tx_error", str(error)))

    print("TX worker stopped")


def start_tx():
    global tx_input_stream
    global tx_audio_queue
    global tx_worker_thread
    global tx_blocks_sent
    global tx_samples_sent
    global tx_dropped_blocks

    if uart is None or not uart.is_open:
        serial_status_var.set("Connect to the FPGA first")
        return

    if tx_input_stream is not None:
        tx_status_var.set("TX is already running")
        return

    tx_blocks_sent = 0
    tx_samples_sent = 0
    tx_dropped_blocks = 0
    reset_plot_buffer(tx_plot_buffer, tx_plot_lock)

    tx_audio_queue = queue.Queue(maxsize=TX_QUEUE_BLOCKS)
    tx_worker_thread = threading.Thread(
        target=tx_uart_worker,
        args=(tx_audio_queue, uart),
        daemon=True,
    )
    tx_worker_thread.start()

    new_stream = None

    try:
        new_stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=AUDIO_CHANNELS,
            dtype="int16",
            blocksize=AUDIO_BLOCK_SIZE,
            callback=tx_audio_callback,
        )
        new_stream.start()
        tx_input_stream = new_stream

        tx_status_var.set("TX LIVE — microphone to FPGA")
        refresh_control_states()

    except sd.PortAudioError as error:
        if new_stream is not None:
            new_stream.close()

        place_worker_stop(tx_audio_queue)
        if tx_worker_thread is not None:
            tx_worker_thread.join(timeout=1.0)

        tx_audio_queue = None
        tx_worker_thread = None
        tx_status_var.set(f"TX start failed: {error}")
        refresh_control_states()


def stop_tx(update_status=True):
    global tx_input_stream
    global tx_audio_queue
    global tx_worker_thread

    stream = tx_input_stream
    tx_input_stream = None

    if stream is not None:
        try:
            stream.stop()
            stream.close()
        except sd.PortAudioError as error:
            print("TX stream stop error:", error)

    work_queue = tx_audio_queue
    worker = tx_worker_thread
    tx_audio_queue = None
    tx_worker_thread = None

    place_worker_stop(work_queue)

    if worker is not None and worker is not threading.current_thread():
        worker.join(timeout=2.0)

    if update_status:
        tx_status_var.set(
            f"TX stopped — {tx_samples_sent} samples sent"
        )

    refresh_control_states()


def set_rx_gain(value):
    """Called only on the Tk thread."""
    global rx_gain_target
    rx_gain_target = max(0.0, min(RX_GAIN_MAX, float(value)))
    rx_gain_label_var.set(f"{rx_gain_target:.1f}x")


def reset_rx_gain():
    rx_gain_var.set(1.0)
    set_rx_gain(1.0)


def apply_rx_gain(audio):
    """Ramp gain over 10 ms and limit output to the float audio range."""
    global rx_gain_current, rx_gain_clipping
    target = rx_gain_target
    count = min(len(audio), RX_GAIN_RAMP_SAMPLES)
    scaled = audio.copy()
    if count:
        ramp = np.linspace(rx_gain_current, target, count + 1,
                           dtype=np.float32)[1:]
        scaled[:count] *= ramp
        scaled[count:] *= target
        rx_gain_current = target
    rx_gain_clipping = bool(np.any(np.abs(scaled) > 1.0))
    return np.clip(scaled, -1.0, 1.0)


def process_received_block(samples_12bit):
    """Convert, filter, plot, and queue one decoded ADC block."""
    global rx_filter_state
    global rx_fade_position
    global rx_blocks_received
    global rx_samples_received
    global rx_queue_overflows

    # This produces the same full-scale mapping as the previous int16 path,
    # but keeps processing in float32 for the real-time speaker callback.
    pcm_normalized = (
        samples_12bit.astype(np.float32) - 2048.0
    ) / 2048.0

    if rx_filter_state is None:
        # Initialize the high-pass section at the measured DC level so a
        # large A0 offset does not create a startup transient.
        rx_filter_state = (
            sosfilt_zi(RX_FILTER_SOS) * pcm_normalized[0]
        )

    filtered_audio, rx_filter_state = sosfilt(
        RX_FILTER_SOS,
        pcm_normalized,
        zi=rx_filter_state,
    )
    filtered_audio = filtered_audio.astype(np.float32)

    fade_total = max(1, int(RX_FADE_SECONDS * SAMPLE_RATE))
    if rx_fade_position < fade_total:
        fade_count = min(
            len(filtered_audio),
            fade_total - rx_fade_position,
        )
        fade = (
            np.arange(
                rx_fade_position,
                rx_fade_position + fade_count,
                dtype=np.float32,
            )
            / float(fade_total)
        )
        filtered_audio[:fade_count] *= fade
        rx_fade_position += fade_count

    filtered_audio = apply_rx_gain(filtered_audio)

    append_plot_samples(
        rx_plot_buffer,
        rx_plot_lock,
        filtered_audio,
    )

    if rx_monitor_enabled and rx_play_queue is not None:
        playback_block = filtered_audio.reshape(-1, 1).copy()
        if queue_latest_block(rx_play_queue, playback_block):
            rx_queue_overflows += 1

    rx_blocks_received += 1
    rx_samples_received += len(samples_12bit)


def rx_uart_worker(serial_port):
    global rx_invalid_bytes

    low_six = None
    sample_block = []

    print("RX worker started")

    try:
        while not rx_stop_event.is_set():
            received_bytes = serial_port.read(2048)

            if not received_bytes:
                continue

            for received_byte in received_bytes:
                if rx_stop_event.is_set():
                    break

                identifier = received_byte >> 6

                if identifier == 0b01:
                    low_six = received_byte & 0x3F

                elif identifier == 0b10:
                    if low_six is None:
                        rx_invalid_bytes += 1
                        continue

                    sample_12bit = (
                        ((received_byte & 0x3F) << 6)
                        | low_six
                    )
                    sample_block.append(sample_12bit)
                    low_six = None

                else:
                    low_six = None
                    rx_invalid_bytes += 1

                if len(sample_block) == AUDIO_BLOCK_SIZE:
                    process_received_block(
                        np.asarray(sample_block, dtype=np.int32)
                    )
                    sample_block = []

    except (serial.SerialException, OSError) as error:
        if not rx_stop_event.is_set():
            ui_event_queue.put(("rx_error", str(error)))

    print("RX worker stopped")


def rx_output_callback(outdata, frames, time_info, status):
    """PortAudio consumer callback; silence is safer than blocking."""
    global rx_playback_armed
    global rx_output_underflows

    if status:
        print("RX playback status:", status)

    outdata.fill(0.0)

    work_queue = rx_play_queue
    if work_queue is None or not rx_monitor_enabled:
        return

    if not rx_playback_armed:
        if work_queue.qsize() < RX_PREFILL_BLOCKS:
            return
        rx_playback_armed = True

    try:
        playback_block = work_queue.get_nowait()
    except queue.Empty:
        rx_output_underflows += 1
        rx_playback_armed = False
        return

    copy_count = min(frames, len(playback_block))
    outdata[:copy_count, 0] = playback_block[:copy_count, 0]


def start_rx():
    global rx_worker_thread
    global rx_output_stream
    global rx_play_queue
    global rx_gain_current, rx_gain_clipping
    global rx_filter_state
    global rx_fade_position
    global rx_playback_armed
    global rx_blocks_received
    global rx_samples_received
    global rx_invalid_bytes
    global rx_queue_overflows
    global rx_output_underflows

    if uart is None or not uart.is_open:
        serial_status_var.set("Connect to the FPGA first")
        return

    if rx_worker_thread is not None and rx_worker_thread.is_alive():
        rx_status_var.set("RX is already running")
        return

    rx_blocks_received = 0
    rx_samples_received = 0
    rx_invalid_bytes = 0
    rx_queue_overflows = 0
    rx_output_underflows = 0

    rx_gain_current = rx_gain_target
    rx_gain_clipping = False
    rx_filter_state = None
    rx_fade_position = 0
    rx_playback_armed = False
    rx_play_queue = queue.Queue(maxsize=RX_QUEUE_BLOCKS)
    rx_stop_event.clear()
    reset_plot_buffer(rx_plot_buffer, rx_plot_lock)

    new_output_stream = None

    try:
        # The FPGA transmits continuously.  Remove samples from before this
        # independent RX capture was started.
        uart.reset_input_buffer()

        new_output_stream = sd.OutputStream(
            samplerate=SAMPLE_RATE,
            channels=AUDIO_CHANNELS,
            dtype="float32",
            blocksize=AUDIO_BLOCK_SIZE,
            callback=rx_output_callback,
        )
        new_output_stream.start()
        rx_output_stream = new_output_stream

        rx_worker_thread = threading.Thread(
            target=rx_uart_worker,
            args=(uart,),
            daemon=True,
        )
        rx_worker_thread.start()

        rx_status_var.set("RX LIVE — FPGA ADC to speaker")
        refresh_control_states()

    except (serial.SerialException, sd.PortAudioError) as error:
        if new_output_stream is not None:
            try:
                new_output_stream.close()
            except sd.PortAudioError:
                pass

        rx_output_stream = None
        rx_play_queue = None
        rx_status_var.set(f"RX start failed: {error}")
        refresh_control_states()


def stop_rx(update_status=True):
    global rx_worker_thread
    global rx_output_stream
    global rx_play_queue
    global rx_playback_armed

    rx_stop_event.set()

    worker = rx_worker_thread
    rx_worker_thread = None

    if worker is not None and worker is not threading.current_thread():
        worker.join(timeout=2.0)

    output_stream = rx_output_stream
    rx_output_stream = None

    if output_stream is not None:
        try:
            output_stream.stop()
            output_stream.close()
        except sd.PortAudioError as error:
            print("RX output stop error:", error)

    rx_play_queue = None
    rx_playback_armed = False

    if update_status:
        rx_status_var.set(
            f"RX stopped — {rx_samples_received} samples received"
        )

    refresh_control_states()


def toggle_rx_monitor():
    global rx_monitor_enabled
    global rx_playback_armed

    rx_monitor_enabled = bool(rx_monitor_var.get())
    rx_playback_armed = False

    work_queue = rx_play_queue
    if work_queue is not None:
        while True:
            try:
                work_queue.get_nowait()
            except queue.Empty:
                break

    if rx_monitor_enabled:
        rx_status_var.set("Speaker monitor enabled")
    else:
        rx_status_var.set("Speaker monitor muted; RX plot remains live")


def toggle_fan_override():
    #need a way to turn on fans without temperature control from FPGA

    #connection check
    if uart is None or not uart.is_open:
        fan_override_var.set(False)
        fan_status_var.set("Fan control unavailable — connect to FPGA")
        return

    #command statement
    command = (
        FAN_OVERRIDE_ON
        if fan_override_var.get()
        else FAN_OVERRIDE_OFF
    )

    #write lock to ensure full bytes transmit without interrupting audio
    try:
        with uart_write_lock:
            bytes_written = uart.write(bytes([command]))

        if bytes_written != 1:
            raise serial.SerialTimeoutException(
                "Fan command was not completely written"
            )

        if fan_override_var.get():
            fan_status_var.set("Fans forced ON — manual override")
        else:
            fan_status_var.set("Fan control AUTO — temperature controlled")

    except (serial.SerialException, OSError) as error:
        fan_override_var.set(False)
        fan_status_var.set(f"Fan command failed: {error}")


def refresh_ports():
    ports = [port.device for port in list_ports.comports()]
    port_box["values"] = ports

    if ports:
        if port_box.get() not in ports:
            port_box.set(ports[0])
        serial_status_var.set("Select a port and open the serial connection")
    else:
        port_box.set("")
        serial_status_var.set("No COM ports found")


def connect_uart():
    global uart

    if uart is not None and uart.is_open:
        return

    selected_port = port_box.get()
    if not selected_port:
        serial_status_var.set("Select a COM port")
        return

    try:
        uart = serial.Serial(
            port=selected_port,
            baudrate=BAUD_RATE,
            bytesize=8,
            parity="N",
            stopbits=1,
            timeout=0.05,
            write_timeout=1,
        )

        serial_status_var.set(
            f"Serial open: {selected_port} @ {BAUD_RATE:,} baud"
        )
        tx_status_var.set("TX idle")
        rx_status_var.set("RX idle")

        #start fan control in AUTO temp control
        fan_override_var.set(False)

        with uart_write_lock:
            uart.write(bytes([FAN_OVERRIDE_OFF]))

        fan_status_var.set(
            "Fan control AUTO — temperature controlled"
        )

    except serial.SerialException as error:
        uart = None
        serial_status_var.set(f"Connection failed: {error}")

    refresh_control_states()


def disconnect_uart():
    global uart

    # A shared physical port must be closed only after both independent paths
    # have stopped using it.
    stop_tx(update_status=False)
    stop_rx(update_status=False)

    serial_port = uart

    #release manual override before disconnection
    if serial_port is not None and serial_port.is_open:
        try:
            with uart_write_lock:
                serial_port.write(bytes([FAN_OVERRIDE_OFF]))
        except (serial.SerialException, OSError):
            pass

    #reset fan state on GUI
    fan_override_var.set(False)
    fan_status_var.set("Fan control unavailable")

    uart = None

    if serial_port is not None:
        try:
            serial_port.close()
        except serial.SerialException as error:
            print("Serial close error:", error)

    serial_status_var.set("Serial closed")
    tx_status_var.set("TX unavailable")
    rx_status_var.set("RX unavailable")
    refresh_control_states()


def refresh_control_states():
    connected = uart is not None and uart.is_open
    tx_running = tx_input_stream is not None
    rx_running = (
        rx_worker_thread is not None
        and rx_worker_thread.is_alive()
    )

    connect_button.config(
        state="disabled" if connected else "normal"
    )
    disconnect_button.config(
        state="normal" if connected else "disabled"
    )
    port_box.config(
        state="disabled" if connected else "readonly"
    )

    start_tx_button.config(
        state="normal" if connected and not tx_running else "disabled"
    )
    stop_tx_button.config(
        state="normal" if tx_running else "disabled"
    )

    start_rx_button.config(
        state="normal" if connected and not rx_running else "disabled"
    )
    stop_rx_button.config(
        state="normal" if rx_running else "disabled"
    )
    #enable override only when UART is connected
    fan_override_check.config(
        state="normal" if connected else "disabled"
    )


def handle_tx_worker_error(message):
    stop_tx(update_status=False)
    tx_status_var.set(f"TX error: {message}")


def handle_rx_worker_error(message):
    stop_rx(update_status=False)
    rx_status_var.set(f"RX error: {message}")


def process_ui_events():
    while True:
        try:
            event_name, message = ui_event_queue.get_nowait()
        except queue.Empty:
            return

        if event_name == "tx_error":
            handle_tx_worker_error(message)
        elif event_name == "rx_error":
            handle_rx_worker_error(message)


def update_oscilloscope_plots():
    if program_closing:
        return

    process_ui_events()
    rx_clip_var.set("CLIPPING — lower gain" if rx_gain_clipping else "")

    with tx_plot_lock:
        tx_samples = np.fromiter(
            tx_plot_buffer,
            dtype=np.float32,
            count=PLOT_SAMPLES,
        )

    with rx_plot_lock:
        rx_samples = np.fromiter(
            rx_plot_buffer,
            dtype=np.float32,
            count=PLOT_SAMPLES,
        )

    tx_line.set_ydata(tx_samples)
    rx_line.set_ydata(rx_samples)

    if tx_input_stream is not None:
        tx_status_var.set(
            f"TX LIVE — {tx_samples_sent:,} samples | "
            f"dropped blocks: {tx_dropped_blocks}"
        )

    if rx_worker_thread is not None and rx_worker_thread.is_alive():
        monitor_text = "speaker on" if rx_monitor_enabled else "speaker muted"
        rx_status_var.set(
            f"RX LIVE — {rx_samples_received:,} samples | "
            f"{monitor_text} | underflows: {rx_output_underflows}"
        )

    plot_canvas.draw_idle()
    root.after(PLOT_REFRESH_MS, update_oscilloscope_plots)


def close_program():
    global program_closing

    program_closing = True
    disconnect_uart()
    root.destroy()


def configure_ttk_styles():
    style = ttk.Style(root)
    style.theme_use("clam")

    style.configure(
        "Dark.TFrame",
        background="#111a2b",
    )
    style.configure(
        "Panel.TFrame",
        background="#152136",
        relief="flat",
    )
    style.configure(
        "Dark.TLabel",
        background="#111a2b",
        foreground="#aebbd0",
        font=("Segoe UI", 9),
    )
    style.configure(
        "Panel.TLabel",
        background="#152136",
        foreground="#aebbd0",
        font=("Segoe UI", 9),
    )
    style.configure(
        "Title.TLabel",
        background="#111a2b",
        foreground="#eef5ff",
        font=("Segoe UI Semibold", 15),
    )
    style.configure(
        "Tx.TLabel",
        background="#152136",
        foreground="#36e0d0",
        font=("Segoe UI Semibold", 11),
    )
    style.configure(
        "Rx.TLabel",
        background="#152136",
        foreground="#ff68b4",
        font=("Segoe UI Semibold", 11),
    )
    #fan labeling
    style.configure(
        "Fan.TLabel",
        background="#152136",
        foreground="#ffb454",
        font=("Segoe UI Semibold", 11),
    )
    style.configure(
        "Status.TLabel",
        background="#0b1220",
        foreground="#8291a9",
        font=("Consolas", 9),
    )
    style.configure(
        "Dark.TButton",
        background="#25334b",
        foreground="#e8eef8",
        borderwidth=0,
        padding=(10, 6),
        font=("Segoe UI", 9),
    )
    style.map(
        "Dark.TButton",
        background=[
            ("active", "#314462"),
            ("disabled", "#1a2435"),
        ],
        foreground=[("disabled", "#607089")],
    )
    style.configure(
        "Accent.TButton",
        background="#68a9ff",
        foreground="#08111f",
        borderwidth=0,
        padding=(12, 6),
        font=("Segoe UI Semibold", 9),
    )
    style.map(
        "Accent.TButton",
        background=[
            ("active", "#8bbdff"),
            ("disabled", "#26364d"),
        ],
        foreground=[("disabled", "#64738b")],
    )
    style.configure(
        "Dark.TCombobox",
        fieldbackground="#0b1220",
        background="#25334b",
        foreground="#e8eef8",
        arrowcolor="#aebbd0",
        bordercolor="#40516d",
        lightcolor="#40516d",
        darkcolor="#40516d",
    )
    style.map(
        "Dark.TCombobox",
        fieldbackground=[("readonly", "#0b1220")],
        foreground=[("readonly", "#e8eef8")],
    )
    style.configure(
        "Dark.TCheckbutton",
        background="#152136",
        foreground="#b9c7da",
        indicatorcolor="#0b1220",
        font=("Segoe UI", 9),
    )
    style.map(
        "Dark.TCheckbutton",
        background=[("active", "#152136")],
        indicatorcolor=[("selected", "#36e0d0")],
    )


def style_scope_axis(axis, title, color):
    axis.set_facecolor("#090f1a")
    axis.set_title(
        title,
        loc="left",
        color="#aebbd0",
        fontsize=10,
        pad=10,
    )
    axis.set_xlim(-PLOT_WINDOW_SECONDS * 1000.0, 0.0)
    axis.set_ylim(-1.05, 1.05)
    axis.set_ylabel("Amplitude", color="#8291a9", fontsize=8)
    axis.grid(True, color="#203048", alpha=0.70, linewidth=0.6)
    axis.tick_params(colors="#8291a9", labelsize=8)

    for spine in axis.spines.values():
        spine.set_color("#24344c")

    axis.axhline(0.0, color="#34445d", linewidth=0.7)
    return axis.plot(
        plot_time_ms,
        np.zeros(PLOT_SAMPLES, dtype=np.float32),
        color=color,
        linewidth=1.0,
    )[0]


root = tk.Tk()
root.title("AM Radio — FPGA Audio Console")
root.geometry("1180x820")
root.minsize(920, 680)
root.configure(background="#0b1220")

configure_ttk_styles()

serial_status_var = tk.StringVar(value="Serial closed")
tx_status_var = tk.StringVar(value="TX unavailable")
rx_status_var = tk.StringVar(value="RX unavailable")
rx_monitor_var = tk.BooleanVar(value=True)
rx_gain_var = tk.DoubleVar(value=1.0)
rx_gain_label_var = tk.StringVar(value="1.0x")
rx_clip_var = tk.StringVar(value="")

fan_override_var = tk.BooleanVar(value=False)
fan_status_var = tk.StringVar(value="Fan control unavailable")

root.columnconfigure(0, weight=1)
root.rowconfigure(5, weight=1)

title_frame = ttk.Frame(root, style="Dark.TFrame", padding=(14, 10, 14, 4))
title_frame.grid(row=0, column=0, sticky="ew")
title_frame.columnconfigure(0, weight=1)

ttk.Label(
    title_frame,
    text="AM Radio Audio Console",
    style="Title.TLabel",
).grid(row=0, column=0, sticky="w")

ttk.Label(
    title_frame,
    text="Independent TX and RX signal paths",
    style="Dark.TLabel",
).grid(row=0, column=1, sticky="e")

connection_frame = ttk.Frame(
    root,
    style="Panel.TFrame",
    padding=(12, 10),
)
connection_frame.grid(row=1, column=0, padx=14, pady=(8, 4), sticky="ew")

for column in range(12):
    connection_frame.columnconfigure(column, weight=0)
connection_frame.columnconfigure(11, weight=1)

ttk.Label(connection_frame, text="Port", style="Panel.TLabel").grid(
    row=0, column=0, padx=(0, 5)
)

port_box = ttk.Combobox(
    connection_frame,
    state="readonly",
    width=10,
    style="Dark.TCombobox",
)
port_box.grid(row=0, column=1, padx=(0, 8))

refresh_button = ttk.Button(
    connection_frame,
    text="Refresh",
    command=refresh_ports,
    style="Dark.TButton",
)
refresh_button.grid(row=0, column=2, padx=(0, 16))

ttk.Label(connection_frame, text="Baud", style="Panel.TLabel").grid(
    row=0, column=3, padx=(0, 5)
)
ttk.Label(
    connection_frame,
    text=f"{BAUD_RATE:,}",
    style="Panel.TLabel",
).grid(row=0, column=4, padx=(0, 16))

ttk.Label(connection_frame, text="Fs", style="Panel.TLabel").grid(
    row=0, column=5, padx=(0, 5)
)
ttk.Label(
    connection_frame,
    text=f"{SAMPLE_RATE:,} Hz",
    style="Panel.TLabel",
).grid(row=0, column=6, padx=(0, 16))

ttk.Label(connection_frame, text="Block", style="Panel.TLabel").grid(
    row=0, column=7, padx=(0, 5)
)
ttk.Label(
    connection_frame,
    text=str(AUDIO_BLOCK_SIZE),
    style="Panel.TLabel",
).grid(row=0, column=8, padx=(0, 16))

connect_button = ttk.Button(
    connection_frame,
    text="Open Serial",
    command=connect_uart,
    style="Accent.TButton",
)
connect_button.grid(row=0, column=9, padx=(0, 8))

disconnect_button = ttk.Button(
    connection_frame,
    text="Close Serial",
    command=disconnect_uart,
    state="disabled",
    style="Dark.TButton",
)
disconnect_button.grid(row=0, column=10)

path_frame = ttk.Frame(root, style="Dark.TFrame", padding=(14, 4))
path_frame.grid(row=2, column=0, sticky="ew")
path_frame.columnconfigure(0, weight=1)
path_frame.columnconfigure(1, weight=1)

tx_panel = ttk.Frame(path_frame, style="Panel.TFrame", padding=(12, 10))
tx_panel.grid(row=0, column=0, padx=(0, 5), sticky="ew")
tx_panel.columnconfigure(3, weight=1)

ttk.Label(tx_panel, text="●  TX", style="Tx.TLabel").grid(
    row=0, column=0, padx=(0, 12), sticky="w"
)

start_tx_button = ttk.Button(
    tx_panel,
    text="Start TX",
    command=start_tx,
    state="disabled",
    style="Dark.TButton",
)
start_tx_button.grid(row=0, column=1, padx=(0, 6))

stop_tx_button = ttk.Button(
    tx_panel,
    text="Stop TX",
    command=stop_tx,
    state="disabled",
    style="Dark.TButton",
)
stop_tx_button.grid(row=0, column=2, padx=(0, 12))

ttk.Label(
    tx_panel,
    textvariable=tx_status_var,
    style="Panel.TLabel",
).grid(row=0, column=3, sticky="e")

rx_panel = ttk.Frame(path_frame, style="Panel.TFrame", padding=(12, 10))
rx_panel.grid(row=0, column=1, padx=(5, 0), sticky="ew")
rx_panel.columnconfigure(4, weight=1)

ttk.Label(rx_panel, text="●  RX", style="Rx.TLabel").grid(
    row=0, column=0, padx=(0, 12), sticky="w"
)

start_rx_button = ttk.Button(
    rx_panel,
    text="Start RX",
    command=start_rx,
    state="disabled",
    style="Dark.TButton",
)
start_rx_button.grid(row=0, column=1, padx=(0, 6))

stop_rx_button = ttk.Button(
    rx_panel,
    text="Stop RX",
    command=stop_rx,
    state="disabled",
    style="Dark.TButton",
)
stop_rx_button.grid(row=0, column=2, padx=(0, 8))

rx_monitor_check = ttk.Checkbutton(
    rx_panel,
    text="Live speaker",
    variable=rx_monitor_var,
    command=toggle_rx_monitor,
    style="Dark.TCheckbutton",
)
rx_monitor_check.grid(row=0, column=3, padx=(0, 12))

ttk.Label(
    rx_panel,
    textvariable=rx_status_var,
    style="Panel.TLabel",
).grid(row=0, column=4, sticky="e")

# Receive gain affects the filtered audio and RX plot before playback.
rx_gain_frame = ttk.Frame(rx_panel, style="Panel.TFrame")
rx_gain_frame.grid(row=1, column=0, columnspan=5, sticky="ew", pady=(10, 0))
rx_gain_frame.columnconfigure(1, weight=1)
ttk.Label(rx_gain_frame, text="RX gain", style="Panel.TLabel").grid(
    row=0, column=0, padx=(0, 8))
rx_gain_slider = tk.Scale(
    rx_gain_frame, from_=0.0, to=RX_GAIN_MAX, resolution=0.1,
    orient="horizontal", variable=rx_gain_var, command=set_rx_gain,
    showvalue=False, bg="#152136", fg="#ff68b4",
    troughcolor="#0b1220", activebackground="#ff68b4",
    highlightthickness=0, bd=0, length=180)
rx_gain_slider.grid(row=0, column=1, sticky="ew")
ttk.Label(rx_gain_frame, textvariable=rx_gain_label_var,
          style="Panel.TLabel", width=6).grid(row=0, column=2, padx=8)

ttk.Button(rx_gain_frame, text="Reset 1x", command=reset_rx_gain,
           style="Dark.TButton").grid(row=0, column=3)

ttk.Label(rx_gain_frame, textvariable=rx_clip_var,
          style="Panel.TLabel", foreground="#ffb454").grid(
    row=1, column=0, columnspan=4, sticky="w")


#fan control panel
fan_panel = ttk.Frame(
    root,
    style="Panel.TFrame",
    padding=(12, 9),
)

fan_panel.grid(
    row=3,
    column=0,
    padx=14,
    pady=(4, 4),
    sticky="ew",
)

fan_panel.columnconfigure(2, weight=1)

ttk.Label(
    fan_panel,
    text="●  FAN CONTROL",
    style="Fan.TLabel",
).grid(
    row=0,
    column=0,
    padx=(0, 18),
    sticky="w",
)

fan_override_check = ttk.Checkbutton(
    fan_panel,
    text="Force Fans ON",
    variable=fan_override_var,
    command=toggle_fan_override,
    state="disabled",
    style="Dark.TCheckbutton",
)

fan_override_check.grid(
    row=0,
    column=1,
    padx=(0, 18),
    sticky="w",
)

ttk.Label(
    fan_panel,
    textvariable=fan_status_var,
    style="Panel.TLabel",
).grid(
    row=0,
    column=2,
    sticky="e",
)

status_frame = ttk.Frame(root, style="Dark.TFrame", padding=(16, 2, 16, 5))
status_frame.grid(row=4, column=0, sticky="ew")

ttk.Label(
    status_frame,
    textvariable=serial_status_var,
    style="Status.TLabel",
).pack(side="left")

plot_frame = tk.Frame(
    root,
    background="#090f1a",
    highlightbackground="#17243a",
    highlightthickness=1,
)
plot_frame.grid(row=5, column=0, padx=14, pady=(4, 14), sticky="nsew")

figure = Figure(figsize=(10.8, 6.1), dpi=100, facecolor="#090f1a")
figure.subplots_adjust(left=0.075, right=0.98, top=0.95, bottom=0.09, hspace=0.36)

tx_axis = figure.add_subplot(211)
rx_axis = figure.add_subplot(212)

plot_time_ms = np.linspace(
    -PLOT_WINDOW_SECONDS * 1000.0,
    0.0,
    PLOT_SAMPLES,
    endpoint=False,
)

tx_line = style_scope_axis(
    tx_axis,
    "TX SIGNAL — microphone samples written to UART",
    "#36e0d0",
)
rx_line = style_scope_axis(
    rx_axis,
    "RX SIGNAL — filtered ADC samples after RX gain / limiting",
    "#ff68b4",
)
rx_axis.set_xlabel("Time (ms)", color="#8291a9", fontsize=8)

plot_canvas = FigureCanvasTkAgg(figure, master=plot_frame)
plot_canvas.get_tk_widget().pack(fill="both", expand=True)

root.protocol("WM_DELETE_WINDOW", close_program)

refresh_ports()
refresh_control_states()
root.after(PLOT_REFRESH_MS, update_oscilloscope_plots)
root.mainloop()