# Monitoring DGX B300 (1 node)

Stack: Prometheus + Grafana + dcgm-exporter (GPU) + node-exporter (host). Portainer opsional.

```
install.sh                     deploy + verifikasi sekali jalan
docker-compose.yaml            stack utama
prometheus/                    config Prometheus + file target (ditulis install.sh)
dcgm/counters.csv              field DCGM yang diekspor
grafana/provisioning/          datasource + dashboard otomatis
grafana/dashboards/            2 dashboard (lihat di bawah)
test/                          exporter GPU tiruan untuk tes di mesin tanpa GPU
```

## Deploy di DGX (sekali jalan)

```bash
git clone https://github.com/epsindo-ai/monitoring-DGX-B300.git && cd monitoring-DGX-B300
./install.sh
```

Selesai. Script ini:

1. Mengecek prasyarat: Docker, Compose v2 (>= 2.20), NVIDIA Container Toolkit, `nvidia-smi`, `python3`, `curl`.
2. Membuat `.env` dengan password Grafana acak (bila belum ada).
3. Membereskan bentrok: container monitoring lama dengan nama/port sama dihapus (setelah konfirmasi;
   volume datanya tidak disentuh). Port yang dipakai aplikasi lain -> berhenti dengan pesan jelas.
4. Pull image dan menjalankan stack.
5. Memverifikasi: target Prometheus UP, jumlah GPU di DCGM = `nvidia-smi`, metrik profiling keluar,
   login Grafana, datasource sehat, kedua dashboard termuat, dan semua query dashboard berisi data.

Hasil akhirnya mencetak URL Grafana. Password ada di `.env` (`GRAFANA_ADMIN_PASSWORD`).

Opsi:

| Perintah | Fungsi |
|---|---|
| `./install.sh --yes` | Tanpa pertanyaan (untuk otomasi) |
| `./install.sh --dcgm-mode hostengine` | Paksa dcgm-exporter memakai nv-hostengine host (lihat di bawah) |
| `./install.sh --uninstall` | Hapus container, data tetap disimpan |
| `./install.sh --uninstall --purge` | Hapus container dan seluruh data |
| `./install.sh --fake-gpu` | Tes di mesin tanpa GPU (exporter tiruan) |

Aman dijalankan ulang (mis. setelah `git pull` atau mengubah `.env`). Bila password di `.env` diganti
setelah Grafana pernah jalan, script me-reset password admin agar sesuai.

### Mode dcgm-exporter

- **embedded** (default): dcgm-exporter menjalankan hostengine sendiri di dalam container.
- **hostengine**: dcgm-exporter memakai `nv-hostengine` milik host (service `nvidia-dcgm`).

Dengan mode `auto` (default), script mencoba embedded dulu. Bila metrik GPU/profiling tidak keluar
dan `nv-hostengine` host aktif, script otomatis pindah ke mode hostengine. Mode tersimpan di `.env`
(`COMPOSE_PROFILES`), dan alamat target Prometheus ditulis ke `prometheus/targets/dcgm.yml`.

### Bila ada masalah

- **Port bentrok**: ubah `GRAFANA_PORT` / `PROMETHEUS_PORT` / `NODE_EXPORTER_PORT` di `.env`, jalankan ulang.
- **Versi DCGM**: B300 butuh DCGM >= 4.5. Bila host memakai DCGM lebih baru (`dcgmi --version`), set
  `DCGM_EXPORTER_IMAGE` di `.env` ke tag yang setara (daftar tag: `nvcr.io/nvidia/k8s/dcgm-exporter`).
- **Firewall**: Prometheus menjangkau node-exporter via `host.docker.internal:9100`. Bila ufw aktif,
  script menawarkan membuka akses dari subnet docker; untuk iptables lain, izinkan manual.
- **Field DCGM tidak didukung**: muncul sebagai warning di `docker logs dcgm-exporter`.
- Validasi manual kapan saja: `python3 test/check_dashboards.py http://localhost:9090`.

## MIG

Dashboard **GPU B300 Monitoring** otomatis menyesuaikan saat GPU di-slice MIG — tidak perlu edit dashboard:

- Panel per GPU fisik memakai `DCGM_FI_PROF_GR_ENGINE_ACTIVE` (bukan `DCGM_FI_DEV_GPU_UTIL`, yang tidak didukung di mode MIG).
  GPU yang di-MIG ditampilkan sebagai agregat instance-nya.
- Row **MIG** menampilkan layout profile per GPU, gauge memori per instance (kuning ≥80%, merah ≥90%),
  serta riwayat utilization, memori, tensor, dan DRAM per instance (label `GPU_I_PROFILE`, `GPU_I_ID`).
  Saat MIG mati: "MIG tidak aktif".
- Dropdown **GPU fisik** dan **Profile MIG** di atas dashboard untuk memfilter (default: All).

Format label MIG ini sama dengan yang teramati di DGX A100 (repo `epsindo-ai/nvidia-mig-monitoring`):
`gpu` = index GPU fisik, `GPU_I_ID` + `GPU_I_PROFILE` = MIG instance.

**Penting saat mengubah MIG:**
- dcgm-exporter membaca daftar GPU/instance saat start. Setelah membuat/menghapus MIG instance:
  `docker compose restart dcgm-exporter`.
- Mengaktifkan/mematikan MIG mode (`nvidia-smi -mig 1/0`) butuh GPU tanpa client; stop dulu:
  `docker compose stop dcgm-exporter`, ubah MIG, lalu `docker compose start dcgm-exporter`.

## Tes tanpa GPU

```bash
./install.sh --fake-gpu          # stack lengkap dengan 8 GPU tiruan
echo "0,1" > test/state/mig      # simulasi GPU 0 & 1 di-slice MIG (dashboard menyesuaikan otomatis)
touch test/state/gpu_level_in_mig   # simulasi exporter juga kirim seri level-GPU saat MIG (cek tidak dobel)
python3 test/check_dashboards.py
rm -f test/state/gpu_level_in_mig; : > test/state/mig
./install.sh --fake-gpu --uninstall --purge
```
