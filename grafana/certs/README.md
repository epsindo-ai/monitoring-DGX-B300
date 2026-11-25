# Sertifikat HTTPS Grafana

Taruh dua file ini di folder ini, dengan nama persis:

| File | Isi |
|---|---|
| `grafana.crt` | Sertifikat (PEM). Bila ada intermediate CA, gabungkan: `cat server.crt intermediate.crt > grafana.crt` |
| `grafana.key` | Private key (PEM), tidak boleh dilindungi password |

## Bila file dari klien berformat lain

Cek isinya dulu: `grep -- '-----BEGIN' <file>`.

| Yang diterima | Yang dilakukan |
|---|---|
| `cert.pem` + `key.pem` (2 file) | Cukup ganti nama: `cp cert.pem grafana.crt`, `cp key.pem grafana.key` |
| 1 file `.pem` berisi `CERTIFICATE` dan `PRIVATE KEY` | Pisahkan (perintah di bawah) |
| `.pem` berisi beberapa `CERTIFICATE` (chain) | Pakai apa adanya sebagai `grafana.crt` (sertifikat server harus paling atas) |
| Key berisi `ENCRYPTED PRIVATE KEY` | Buka password: `openssl pkey -in key.pem -out grafana.key` |
| `.pfx` / `.p12` (biner, ber-password) | Konversi (perintah di bawah) |
| `.der` / `.cer` biner (`grep` tidak menemukan BEGIN) | `openssl x509 -inform der -in cert.cer -out grafana.crt` |

```bash
# 1 file .pem berisi sertifikat + key
awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' bundle.pem > grafana.crt
awk '/-----BEGIN .*PRIVATE KEY-----/,/-----END .*PRIVATE KEY-----/' bundle.pem > grafana.key

# .pfx / .p12 (diminta password dari klien)
openssl pkcs12 -in file.pfx -clcerts -nokeys | openssl x509 -out grafana.crt
openssl pkcs12 -in file.pfx -nocerts -nodes | openssl pkey -out grafana.key
```

## Setelah file siap

Jalankan ulang `./install.sh`. Installer akan:

- mendeteksi kedua file dan mengaktifkan HTTPS (`GRAFANA_PROTOCOL=https` di `.env`),
- mengecek sertifikat valid, key cocok dengan sertifikat, dan tanggal kedaluwarsa,
- mengubah pemilik `grafana.key` ke uid 472 (user Grafana di container) dengan mode 640.

Grafana lalu dibuka di `https://<ip-dgx>:3000`.

Tanpa kedua file, Grafana tetap jalan dengan HTTP. Untuk kembali ke HTTP, hapus kedua file lalu
jalankan ulang `./install.sh`. Untuk mengganti `grafana.key`, hapus dulu file lamanya (`rm -f`),
karena setelah chown file itu tidak bisa ditimpa langsung oleh user biasa.

Isi folder ini (selain README ini) tidak ikut di-commit ke git.
