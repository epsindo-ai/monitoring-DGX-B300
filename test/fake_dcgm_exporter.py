"""dcgm-exporter tiruan untuk menguji stack tanpa GPU.

Meniru format /metrics dcgm-exporter (nama metrik + label gpu/UUID/device/modelName/Hostname,
plus GPU_I_PROFILE/GPU_I_ID untuk MIG instance). Nilai random, HANYA untuk tes.
Mode dibaca dari file /state/mig (isi: daftar index GPU yang di-MIG, mis. "0,1"; kosong = non-MIG),
jadi bisa diubah saat berjalan untuk mensimulasikan GPU yang tiba-tiba di-slice.
File /state/gpu_level_in_mig (ada = ya): untuk GPU yang di-MIG, kirim JUGA seri level-GPU
(tanpa label GPU_I_*). Dipakai untuk memastikan dashboard tidak menghitung dobel.
"""
import os
import random
from http.server import BaseHTTPRequestHandler, HTTPServer

NUM_GPUS = 8
MIG_LAYOUT = [("3g.144gb", 3, 147456), ("2g.72gb", 4, 73728), ("1g.36gb", 9, 36864), ("1g.36gb", 10, 36864)]


def mig_gpus():
    try:
        txt = open("/state/mig").read().strip()
    except OSError:
        return set()
    return {int(x) for x in txt.split(",") if x.strip()}


def line(name, labels, value):
    lab = ",".join(f'{k}="{v}"' for k, v in labels.items())
    return f"{name}{{{lab}}} {value}"


def render():
    out, migs = [], mig_gpus()
    for g in range(NUM_GPUS):
        base = {"gpu": g, "UUID": f"GPU-fake-{g:04d}", "pci_bus_id": f"00000000:{0x18 + g:02X}:00.0",
                "device": f"nvidia{g}", "modelName": "NVIDIA B300 (FAKE)", "Hostname": "fake-dgx"}
        # metrik level GPU (selalu ada)
        out.append(line("DCGM_FI_DEV_GPU_TEMP", base, random.randint(35, 75)))
        out.append(line("DCGM_FI_DEV_MEMORY_TEMP", base, random.randint(35, 80)))
        out.append(line("DCGM_FI_DEV_POWER_USAGE", base, round(random.uniform(200, 1100), 1)))
        out.append(line("DCGM_FI_DEV_SM_CLOCK", base, random.randint(1200, 2000)))
        out.append(line("DCGM_FI_DEV_MEM_CLOCK", base, 3996))
        out.append(line("DCGM_FI_DEV_XID_ERRORS", base, 0))
        out.append(line("DCGM_FI_PROF_PCIE_TX_BYTES", base, random.randint(10**8, 10**10)))
        out.append(line("DCGM_FI_PROF_PCIE_RX_BYTES", base, random.randint(10**8, 10**10)))
        out.append(line("DCGM_FI_PROF_NVLINK_TX_BYTES", base, random.randint(10**9, 10**11)))
        out.append(line("DCGM_FI_PROF_NVLINK_RX_BYTES", base, random.randint(10**9, 10**11)))
        if g in migs:
            # MIG: GPU_UTIL tidak ada; metrik util/memori per instance
            for prof, gid, mem in MIG_LAYOUT:
                lab = dict(base, GPU_I_PROFILE=prof, GPU_I_ID=gid)
                used = random.randint(0, mem)
                out.append(line("DCGM_FI_DEV_FB_USED", lab, used))
                out.append(line("DCGM_FI_DEV_FB_FREE", lab, mem - used))
                for m in ("GR_ENGINE_ACTIVE", "SM_ACTIVE", "PIPE_TENSOR_ACTIVE", "DRAM_ACTIVE"):
                    out.append(line(f"DCGM_FI_PROF_{m}", lab, round(random.random(), 3)))
            if os.path.exists("/state/gpu_level_in_mig"):
                out.append(line("DCGM_FI_DEV_FB_USED", base, 999999))   # nilai mencolok: tidak boleh ikut terjumlah
                out.append(line("DCGM_FI_DEV_FB_FREE", base, 0))
                out.append(line("DCGM_FI_PROF_GR_ENGINE_ACTIVE", base, 0.999))
        else:
            used = random.randint(0, 288 * 1024)
            out.append(line("DCGM_FI_DEV_GPU_UTIL", base, random.randint(0, 100)))
            out.append(line("DCGM_FI_DEV_FB_USED", base, used))
            out.append(line("DCGM_FI_DEV_FB_FREE", base, 288 * 1024 - used))
            for m in ("GR_ENGINE_ACTIVE", "SM_ACTIVE", "PIPE_TENSOR_ACTIVE", "DRAM_ACTIVE"):
                out.append(line(f"DCGM_FI_PROF_{m}", base, round(random.random(), 3)))
    return "\n".join(out) + "\n"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = render().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


HTTPServer(("0.0.0.0", 9400), H).serve_forever()
