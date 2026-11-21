#!/usr/bin/env python3
import json
import math
import multiprocessing
import os
import socket
import statistics
import subprocess
import sys
import time

HOST = "127.0.0.1"
PORT = 24121


def send_cmd(cmd: str) -> dict:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(4.0)
    s.connect((HOST, PORT))
    s.sendall((cmd + "\n").encode("utf-8"))
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data.decode("utf-8"))


def cpu_burn_worker(stop_evt):
    x = 1.0001
    while not stop_evt.is_set():
        for _ in range(20000):
            x = math.sin(x) * math.cos(x) + 1.0001


def measure_profile(label: str, codec: str, bitrate: int, speed: int, warmup: float = 2.0, samples: int = 4):
    send_cmd(f"SET codec={codec} bitrate={bitrate} speed={speed} resetdrop=1")
    time.sleep(warmup)
    send_cmd("SET resetdrop=1")

    fps_list, mbps_list, avg_list, p50_list, p95_list, rtt_list = [], [], [], [], [], []
    last_drop = 0
    for _ in range(samples):
        time.sleep(1.0)
        st = send_cmd("STATUS")
        fps_list.append(st["actualFPS"])
        mbps_list.append(st["actualMbps"])
        avg_list.append(st["encodeAvgMs"])
        p50_list.append(st["encodeP50Ms"])
        p95_list.append(st["encodeP95Ms"])
        rtt_list.append(st["usbRttMs"])
        last_drop = st["droppedFrames"]

    return {
        "label": label,
        "codec": codec,
        "bitrate": bitrate,
        "speed": speed,
        "fps": round(statistics.mean(fps_list), 1),
        "mbps": round(statistics.mean(mbps_list), 1),
        "enc_avg": round(statistics.mean(avg_list), 2),
        "enc_p50": round(statistics.mean(p50_list), 2),
        "enc_p95": round(statistics.mean(p95_list), 2),
        "rtt_ms": round(statistics.mean(rtt_list), 2),
        "oneway_usb_ms": round(statistics.mean(rtt_list) / 2.0, 2),
        "drops": last_drop,
    }


def main():
    st = send_cmd("STATUS")
    if not st.get("isStreaming"):
        print("ERROR: HyperDisplayMac is not streaming!", file=sys.stderr)
        sys.exit(1)

    print("Initial status:", st)
    results = []

    # Part 1: Codec x SpeedPriority x Bitrate sweep under idle Mac + Mode 1 (max entropy 120Hz)
    configs = [
        ("4:2:2 10b | 60M  | Quality", "hevc42210", 60, 0),
        ("4:2:2 10b | 220M | Quality", "hevc42210", 220, 0),
        ("4:2:2 10b | 400M | Quality", "hevc42210", 400, 0),
        ("4:2:2 10b | 600M | Quality", "hevc42210", 600, 0),
        ("4:2:2 10b | 220M | Speed",   "hevc42210", 220, 1),
        ("4:2:2 10b | 400M | Speed",   "hevc42210", 400, 1),
        ("4:2:0 10b | 220M | Speed",   "hevc10",    220, 1),
        ("8-bit     | 120M | Speed",   "hevc8",     120, 1),
        ("8-bit     | 220M | Speed",   "hevc8",     220, 1),
    ]

    print("\n=== PART 1: Idle MacBook (High-Entropy 120Hz Stress Mode 1) ===")
    for label, codec, br, sp in configs:
        r = measure_profile(label, codec, br, sp, warmup=2.0, samples=3)
        results.append(r)
        print(
            f"{r['label']:28s} | {r['fps']:5.1f} FPS | {r['mbps']:6.1f} Mbps | "
            f"Enc P50={r['enc_p50']:4.2f}ms P95={r['enc_p95']:4.2f}ms | "
            f"USB RTT={r['rtt_ms']:4.2f}ms | Drop={r['drops']}"
        )

    # Part 2: Heavy MacBook CPU Load (all cores 100%)
    cpu_count = os.cpu_count() or 16
    print(f"\n=== PART 2: Heavy MacBook Load ({cpu_count} CPU burn workers @ 100%) ===")
    stop_evt = multiprocessing.Event()
    procs = [multiprocessing.Process(target=cpu_burn_worker, args=(stop_evt,)) for _ in range(cpu_count)]
    for p in procs:
        p.start()
    time.sleep(1.5)

    load_configs = [
        ("LOAD | 4:2:2 10b | 220M | Speed", "hevc42210", 220, 1),
        ("LOAD | 4:2:2 10b | 400M | Speed", "hevc42210", 400, 1),
        ("LOAD | 4:2:2 10b | 600M | Speed", "hevc42210", 600, 1),
    ]
    load_results = []
    try:
        for label, codec, br, sp in load_configs:
            r = measure_profile(label, codec, br, sp, warmup=1.5, samples=4)
            load_results.append(r)
            print(
                f"{r['label']:34s} | {r['fps']:5.1f} FPS | {r['mbps']:6.1f} Mbps | "
                f"Enc P50={r['enc_p50']:4.2f}ms P95={r['enc_p95']:4.2f}ms | "
                f"USB RTT={r['rtt_ms']:4.2f}ms | Drop={r['drops']}"
            )
    finally:
        stop_evt.set()
        for p in procs:
            p.join(timeout=2.0)
            if p.is_alive():
                p.terminate()

    # Restore optimal daily profile: HEVC 4:2:2 10-bit @ 280 Mbps, Speed Priority ON
    send_cmd("SET codec=hevc42210 bitrate=280 speed=1 resetdrop=1")

    with open("/tmp/hyperdisplay_bench_results.json", "w") as f:
        json.dump({"idle": results, "heavy_load": load_results}, f, indent=2)
    print("\nSaved JSON to /tmp/hyperdisplay_bench_results.json")


if __name__ == "__main__":
    main()
