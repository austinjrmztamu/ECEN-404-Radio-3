import math
import threading
import time

import serial
from serial.tools import list_ports

BAUD_RATE = 2_000_000
SAMPLE_RATE = 48_000
BLOCK_SIZE = 480
HELP = "Commands: sine <Hz> <peak counts> [offset=2048] | dc <0-4095> | q"


def frame_code(code):
    if not 0 <= code <= 4095:
        raise ValueError("DAC code must be between 0 and 4095.")
    return bytes((0x40 | (code & 0x3F), 0x80 | ((code >> 6) & 0x3F)))


def parse_command(text):
    parts = text.lower().split()
    if len(parts) == 2 and parts[0] == "dc":
        code = int(parts[1], 16 if parts[1].startswith("0x") else 10)
        frame_code(code)
        return ("dc", 0.0, 0.0, code)
    if len(parts) in (3, 4) and parts[0] == "sine":
        frequency = float(parts[1])
        amplitude = float(parts[2])
        offset = float(parts[3]) if len(parts) == 4 else 2048.0
        if not all(math.isfinite(x) for x in (frequency, amplitude, offset)):
            raise ValueError("Settings must be finite numbers.")
        if not 0 < frequency < SAMPLE_RATE / 2:
            raise ValueError("Frequency must be greater than 0 and below 24000 Hz.")
        if not 0 <= offset <= 4095:
            raise ValueError("Offset must be between 0 and 4095.")
        if not 0 <= amplitude <= min(offset, 4095 - offset):
            raise ValueError("Amplitude must be nonnegative and keep offset +/- amplitude within 0-4095.")
        return ("sine", frequency, amplitude, offset)
    raise ValueError(HELP)


def make_block(settings, phase):
    mode, frequency, amplitude, offset = settings
    if mode == "dc":
        return frame_code(int(offset)) * BLOCK_SIZE, phase
    step = math.tau * frequency / SAMPLE_RATE
    block = bytearray()
    for _ in range(BLOCK_SIZE):
        code = round(offset + amplitude * math.sin(phase))
        block.extend(frame_code(code))
        phase = (phase + step) % math.tau
    return bytes(block), phase


def transmit(port, state, lock, stop):
    period = BLOCK_SIZE / SAMPLE_RATE
    deadline = time.perf_counter()
    phase = 0.0
    try:
        while not stop.is_set():
            with lock:
                settings = state["settings"]
            # Retain phase between blocks and frequency changes.
            block, phase = make_block(settings, phase)
            if port.write(block) != len(block):
                raise serial.SerialException("Incomplete serial write.")
            deadline += period
            delay = deadline - time.perf_counter()
            if delay > 0:
                stop.wait(delay)
            else:
                # Avoid a burst of catch-up blocks after a scheduling delay.
                deadline = time.perf_counter()
    except (serial.SerialException, OSError) as error:
        print(f"\nTransmission stopped: {error}\nPress Enter to exit.")
        stop.set()


def main():
    for device in list_ports.comports():
        print(f"{device.device}: {device.description}")
    port_name = input("FPGA COM port (example COM5): ").strip()
    print(HELP)
    print("Example: sine 1000 500  (codes 1548-2548)")
    while True:
        text = input("Initial command: ").strip()
        if text.lower() == "q":
            return
        try:
            settings = parse_command(text)
            break
        except ValueError as error:
            print(error)

    stop = threading.Event()
    lock = threading.Lock()
    state = {"settings": settings}
    with serial.Serial(port_name, BAUD_RATE, bytesize=serial.EIGHTBITS,
                       parity=serial.PARITY_NONE, stopbits=serial.STOPBITS_ONE,
                       timeout=0, write_timeout=1,
                       xonxoff=False, rtscts=False, dsrdtr=False) as port:
        worker = threading.Thread(target=transmit, args=(port, state, lock, stop))
        worker.start()
        try:
            print("Streaming. Enter a command to change the output.")
            while not stop.is_set():
                text = input("> ").strip()
                if stop.is_set() or text.lower() == "q":
                    break
                try:
                    settings = parse_command(text)
                    with lock:
                        state["settings"] = settings
                    print("Settings updated.")
                except ValueError as error:
                    print(f"{error} Previous output continues.")
        finally:
            stop.set()
            worker.join()
    print("Serial port closed. Final DAC voltage depends on FPGA idle behavior.")


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        print("\nStopped.")
    except (serial.SerialException, OSError) as error:
        print(f"Serial error: {error}")
