#!/usr/bin/env bash
# =============================================================================
#  install.sh — deploy monitoring DGX B300 sekali jalan, sampai Grafana siap.
#
#  Yang dilakukan:
#    1. Cek prasyarat (Docker, Compose v2, NVIDIA container toolkit, GPU, python3, curl)
#    2. Siapkan .env (password Grafana dibuat acak bila belum ada)
#    3. Bereskan bentrok: container lama dengan nama sama, port yang terpakai
#    4. Pull image & jalankan stack
#    5. Verifikasi: target Prometheus UP, jumlah GPU = nvidia-smi, metrik profiling ada
#       (otomatis pindah ke mode hostengine host bila perlu), Grafana login/datasource/
#       dashboard OK, dan semua query dashboard mengembalikan data
#
#  Pemakaian:
#    ./install.sh                 instal / update (aman dijalankan ulang)
#    ./install.sh --yes           tanpa pertanyaan (jawab "ya" untuk semua)
#    ./install.sh --dcgm-mode hostengine   paksa mode dcgm (auto|embedded|hostengine)
#    ./install.sh --uninstall     hentikan & hapus container (data tetap disimpan)
#    ./install.sh --uninstall --purge      sekaligus hapus data Prometheus & Grafana
#    ./install.sh --fake-gpu      tes di mesin tanpa GPU (pakai exporter tiruan)
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$ROOT"

PROJECT="b300-monitoring"
YES=0
MODE="auto"
ACTION="install"
PURGE=0
FAKE="${MONITORING_FAKE_GPU:-0}"

# ---------------------------------------------------------------- tampilan ---
if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else
  C_B=""; C_G=""; C_Y=""; C_R=""; C_C=""; C_0=""
fi
STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s[%d] %s%s\n' "$C_B$C_C" "$STEP" "$*" "$C_0"; }
ok()   { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  %s!%s %s\n' "$C_Y" "$C_0" "$*"; WARNINGS+=("$*"); }
die()  { printf '\n%s✘ %s%s\n' "$C_R$C_B" "$*" "$C_0" >&2; exit 1; }
WARNINGS=()
trap 'printf "\n%s✘ Gagal di baris %s: %s%s\n" "$C_R" "$LINENO" "$BASH_COMMAND" "$C_0" >&2' ERR

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) YES=1 ;;
    --dcgm-mode) MODE="${2:-}"; shift ;;
    --dcgm-mode=*) MODE="${1#*=}" ;;
    --uninstall) ACTION="uninstall" ;;
    --purge) PURGE=1 ;;
    --fake-gpu) FAKE=1 ;;
    -h|--help) usage ;;
    *) die "Opsi tidak dikenal: $1 (lihat --help)" ;;
  esac
  shift
done
[[ "$MODE" =~ ^(auto|embedded|hostengine)$ ]] || die "--dcgm-mode harus auto, embedded, atau hostengine"

confirm() {
  [[ $YES == 1 ]] && return 0
  [[ -r /dev/tty ]] || die "Butuh konfirmasi tapi tidak ada terminal. Jalankan ulang dengan --yes."
  local a; read -r -p "  ? $1 [y/N] " a </dev/tty || true
  [[ "$a" =~ ^[YyJj] ]]
}

# ------------------------------------------------------------------ helper ---
DOCKER=(docker)
COMPOSE_FILES=(-f docker-compose.yaml)
[[ "$FAKE" == 1 ]] && COMPOSE_FILES+=(-f test/docker-compose.test.yaml)
dc() { "${DOCKER[@]}" compose "${COMPOSE_FILES[@]}" "$@"; }

env_get() { # KEY [default]
  local v
  v="$(grep -E "^$1=" .env 2>/dev/null | tail -1 | cut -d= -f2-)" || true
  printf '%s' "${v:-${2:-}}"
}
env_set() { # KEY VALUE
  if grep -qE "^$1=" .env 2>/dev/null; then
    local tmp; tmp="$(mktemp)"
    awk -v k="$1" -v v="$2" 'BEGIN{FS=OFS="="} $1==k{print k"="v; next} {print}' .env >"$tmp"
    cat "$tmp" >.env; rm -f "$tmp"
  else
    printf '%s=%s\n' "$1" "$2" >>.env
  fi
}

wait_for() { # TIMEOUT_DETIK perintah...
  local end=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do
    ((SECONDS >= end)) && return 1
    sleep 3
  done
}

PROM_URL="" GRAFANA_URL=""
prom_query() { # PROMQL -> nilai pertama ("" jika kosong)
  curl -fsS --max-time 10 --get "$PROM_URL/api/v1/query" --data-urlencode "query=$1" |
    python3 -c 'import sys,json; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "")'
}
prom_has() { [[ -n "$(prom_query "$1")" ]]; }
prom_gt0() { local v; v="$(prom_query "$1")"; [[ -n "$v" ]] && python3 -c "import sys; sys.exit(0 if float('$v') > 0 else 1)"; }
target_health() { # JOB -> up/down/unknown
  curl -fsS --max-time 10 "$PROM_URL/api/v1/targets?state=active" |
    python3 -c 'import sys,json
t=[x for x in json.load(sys.stdin)["data"]["activeTargets"] if x["labels"].get("job")==sys.argv[1]]
print(t[0]["health"] if t else "missing")' "$1"
}
target_error() {
  curl -fsS --max-time 10 "$PROM_URL/api/v1/targets?state=active" |
    python3 -c 'import sys,json
t=[x for x in json.load(sys.stdin)["data"]["activeTargets"] if x["labels"].get("job")==sys.argv[1]]
print(t[0].get("lastError","") if t else "")' "$1"
}
is_up() { [[ "$(target_health "$1")" == "up" ]]; }

port_in_use() { ss -ltnH "( sport = :$1 )" 2>/dev/null | grep -q .; }

write_targets() { # MODE
  local dcgm_target node_port dcgm_port
  node_port="$(env_get NODE_EXPORTER_PORT 9100)"
  dcgm_port="$(env_get DCGM_EXPORTER_PORT 9400)"
  if [[ "$1" == "hostengine" ]]; then dcgm_target="host.docker.internal:$dcgm_port"; else dcgm_target="dcgm-exporter:9400"; fi
  printf "# Ditulis oleh install.sh (mode %s).\n- targets: ['%s']\n" "$1" "$dcgm_target" >prometheus/targets/dcgm.yml
  printf "# Ditulis oleh install.sh (port mengikuti NODE_EXPORTER_PORT di .env).\n- targets: ['host.docker.internal:%s']\n" "$node_port" >prometheus/targets/node.yml
}
reload_prometheus() { "${DOCKER[@]}" kill -s HUP prometheus >/dev/null 2>&1 || true; }

set_profiles() { # MODE
  local p="dcgm-$1" old
  old="$(env_get COMPOSE_PROFILES dcgm-embedded)"
  [[ ",$old," == *",portainer,"* ]] && p="$p,portainer"
  env_set COMPOSE_PROFILES "$p"
}

# =================================================================== mulai ===
printf '%sMonitoring DGX B300 — %s%s\n' "$C_B" "$ACTION" "$C_0"
[[ "$FAKE" == 1 ]] && printf '%s(mode tes --fake-gpu: GPU disimulasikan, BUKAN untuk produksi)%s\n' "$C_Y" "$C_0"

step "Cek prasyarat"
[[ "$(uname -s)" == "Linux" ]] || die "Script ini untuk Linux (DGX OS)."
for c in docker curl python3 ss awk; do
  command -v "$c" >/dev/null || die "Perintah '$c' tidak ditemukan. Instal dulu."
done
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1 || { [[ -r /dev/tty ]] && sudo docker info >/dev/null 2>&1; }; then
    DOCKER=(sudo docker); info "User ini belum di grup docker, memakai sudo."
  else
    die "Tidak bisa mengakses Docker. Pastikan Docker berjalan dan user ada di grup 'docker' (atau punya sudo)."
  fi
fi
ok "Docker $("${DOCKER[@]}" version --format '{{.Server.Version}}')"

DC_VER="$("${DOCKER[@]}" compose version --short 2>/dev/null || true)"
[[ -n "$DC_VER" ]] || die "Docker Compose v2 (plugin 'docker compose') tidak ada. Instal paket docker-compose-plugin."
python3 - "$DC_VER" <<'PY' || die "Docker Compose $DC_VER terlalu lama; butuh >= 2.20."
import sys,re
v=[int(x) for x in re.findall(r"\d+", sys.argv[1])[:2]]
sys.exit(0 if v >= [2,20] else 1)
PY
ok "Docker Compose $DC_VER"

# ---------------------------------------------------------- uninstall ------
if [[ "$ACTION" == "uninstall" ]]; then
  step "Uninstall"
  export COMPOSE_PROFILES="dcgm-embedded,dcgm-hostengine,portainer"
  [[ -f .env ]] || export GRAFANA_ADMIN_PASSWORD=unused   # hanya agar compose bisa membaca file
  if [[ $PURGE == 1 ]]; then
    confirm "Hapus container DAN semua data (riwayat metrik Prometheus, data Grafana)?" || die "Dibatalkan."
    dc down -v --remove-orphans
    ok "Container dan volume data dihapus."
  else
    dc down --remove-orphans
    ok "Container dihapus. Data disimpan (pakai --purge untuk menghapus data)."
  fi
  exit 0
fi

GPU_COUNT=0
HOST_DCGM_ACTIVE=0
if [[ "$FAKE" == 1 ]]; then
  GPU_COUNT=8
  info "GPU disimulasikan: $GPU_COUNT"
else
  command -v nvidia-smi >/dev/null || die "nvidia-smi tidak ditemukan. Driver NVIDIA belum terpasang?"
  nvidia-smi >/dev/null 2>&1 || die "nvidia-smi gagal dijalankan. Cek driver NVIDIA."
  GPU_COUNT="$(nvidia-smi -L | grep -c '^GPU ' || true)"
  ((GPU_COUNT > 0)) || die "Tidak ada GPU terdeteksi oleh nvidia-smi."
  GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
  DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
  ok "$GPU_COUNT GPU: $GPU_NAME (driver $DRIVER)"
  [[ "$GPU_NAME" == *B300* ]] || warn "GPU bukan B300 ($GPU_NAME). Stack tetap dipasang, tapi dashboard dirancang untuk B300."
  MIG_ON="$(nvidia-smi --query-gpu=mig.mode.current --format=csv,noheader 2>/dev/null | grep -c Enabled || true)"
  ((MIG_ON > 0)) && info "MIG aktif di $MIG_ON GPU (dashboard menampilkannya otomatis)."

  if command -v nvidia-ctk >/dev/null || command -v nvidia-container-runtime-hook >/dev/null ||
     "${DOCKER[@]}" info --format '{{json .Runtimes}}' 2>/dev/null | grep -q nvidia; then
    ok "NVIDIA Container Toolkit terpasang"
  else
    die "NVIDIA Container Toolkit tidak ditemukan. Instal: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
  fi

  if systemctl is-active --quiet nvidia-dcgm 2>/dev/null || systemctl is-active --quiet dcgm 2>/dev/null || pgrep -x nv-hostengine >/dev/null; then
    HOST_DCGM_ACTIVE=1
    HV="$(dcgmi --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    info "nv-hostengine host aktif${HV:+ (DCGM $HV)}."
  fi
fi

# ---------------------------------------------------------------- .env -----
step "Konfigurasi (.env)"
if [[ ! -f .env ]]; then
  cp .env.example .env
  PW="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(20)))')"
  env_set GRAFANA_ADMIN_PASSWORD "$PW"
  ok ".env dibuat, password Grafana acak dibuat."
else
  ok ".env sudah ada, dipakai apa adanya."
  [[ "$(env_get GRAFANA_ADMIN_PASSWORD)" == "ganti-password-ini" ]] &&
    warn "GRAFANA_ADMIN_PASSWORD masih nilai contoh. Sebaiknya diganti di .env lalu jalankan ulang."
fi
chmod 600 .env
for k in GRAFANA_PORT PROMETHEUS_PORT NODE_EXPORTER_PORT DCGM_EXPORTER_PORT; do
  [[ -n "$(env_get $k)" ]] || env_set "$k" "$(grep -E "^$k=" .env.example | cut -d= -f2)"
done
GRAFANA_PORT="$(env_get GRAFANA_PORT 3000)"
PROMETHEUS_PORT="$(env_get PROMETHEUS_PORT 9090)"
NODE_EXPORTER_PORT="$(env_get NODE_EXPORTER_PORT 9100)"
DCGM_EXPORTER_PORT="$(env_get DCGM_EXPORTER_PORT 9400)"
GF_USER="$(env_get GRAFANA_ADMIN_USER admin)"
GF_PASS="$(env_get GRAFANA_ADMIN_PASSWORD)"
PROM_URL="http://127.0.0.1:$PROMETHEUS_PORT"
GRAFANA_URL="http://127.0.0.1:$GRAFANA_PORT"

# Mode dcgm awal
if [[ "$MODE" == "auto" ]]; then
  CUR="$(env_get COMPOSE_PROFILES dcgm-embedded)"
  if [[ "$CUR" == *dcgm-hostengine* && "$FAKE" != 1 ]]; then DCGM_MODE="hostengine"; else DCGM_MODE="embedded"; fi
else
  DCGM_MODE="$MODE"
fi
[[ "$FAKE" == 1 && "$DCGM_MODE" == "hostengine" ]] && die "--fake-gpu hanya mendukung mode embedded."
info "Mode dcgm-exporter: $DCGM_MODE"

# ------------------------------------------------------ bentrok & port -----
step "Cek bentrok container & port"
OUR_NAMES=(prometheus grafana dcgm-exporter dcgm-exporter-hostengine node-exporter)
conflicts=()
for n in "${OUR_NAMES[@]}"; do
  proj="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$n" 2>/dev/null || true)"
  if "${DOCKER[@]}" inspect "$n" >/dev/null 2>&1 && [[ "$proj" != "$PROJECT" ]]; then
    conflicts+=("$n")
  fi
done

declare -A NEED_PORT=([grafana]="$GRAFANA_PORT" [prometheus]="$PROMETHEUS_PORT" [node-exporter]="$NODE_EXPORTER_PORT")
[[ "$DCGM_MODE" == "hostengine" ]] && NEED_PORT[dcgm-exporter-hostengine]="$DCGM_EXPORTER_PORT"
port_blockers=()
for svc in "${!NEED_PORT[@]}"; do
  p="${NEED_PORT[$svc]}"
  port_in_use "$p" || continue
  # dipakai oleh container stack ini sendiri (instal ulang) -> aman
  if [[ "$("${DOCKER[@]}" inspect -f '{{.State.Running}} {{index .Config.Labels "com.docker.compose.project"}}' "$svc" 2>/dev/null)" == "true $PROJECT" ]]; then
    continue
  fi
  owner="$("${DOCKER[@]}" ps --filter "publish=$p" --format '{{.Names}}' | head -1)"
  if [[ -n "$owner" ]]; then
    img="$("${DOCKER[@]}" inspect -f '{{.Config.Image}}' "$owner")"
    if [[ "$img" =~ prometheus|grafana|dcgm-exporter|node-exporter ]]; then
      conflicts+=("$owner")
      continue
    fi
    port_blockers+=("port $p ($svc) dipakai container '$owner' ($img)")
  else
    port_blockers+=("port $p ($svc) dipakai proses lain: $(ss -ltnpH "( sport = :$p )" 2>/dev/null | grep -oE 'users:\(\("[^"]+' | head -1 | cut -d'"' -f2)")
  fi
done
# node-exporter / dcgm lama yang jalan di network host tidak muncul di filter publish
for n in $("${DOCKER[@]}" ps --format '{{.Names}}'); do
  img="$("${DOCKER[@]}" inspect -f '{{.Config.Image}}' "$n")"
  proj="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$n")"
  if [[ "$proj" != "$PROJECT" && "$img" =~ dcgm-exporter ]]; then conflicts+=("$n"); fi
done

if ((${#port_blockers[@]})); then
  printf '  %s%s%s\n' "$C_R" "Port bentrok dengan aplikasi lain:" "$C_0"
  printf '    - %s\n' "${port_blockers[@]}"
  die "Ubah port di .env (GRAFANA_PORT / PROMETHEUS_PORT / NODE_EXPORTER_PORT / DCGM_EXPORTER_PORT) lalu jalankan ulang."
fi
if ((${#conflicts[@]})); then
  mapfile -t conflicts < <(printf '%s\n' "${conflicts[@]}" | sort -u)
  info "Container monitoring lama yang bentrok (nama/port/GPU):"
  for c in "${conflicts[@]}"; do info "   - $c ($("${DOCKER[@]}" inspect -f '{{.Config.Image}}' "$c"))"; done
  confirm "Hapus container lama di atas? (hanya container; volume datanya tidak disentuh)" ||
    die "Dibatalkan. Hapus/ganti nama container tersebut lalu jalankan ulang."
  "${DOCKER[@]}" rm -f "${conflicts[@]}" >/dev/null
  ok "Container lama dihapus."
else
  ok "Tidak ada bentrok."
fi

# -------------------------------------------------------------- deploy -----
deploy() { # MODE
  set_profiles "$1"
  write_targets "$1"
  # matikan container mode dcgm yang tidak dipakai
  if [[ "$1" == "hostengine" ]]; then
    "${DOCKER[@]}" rm -f dcgm-exporter >/dev/null 2>&1 || true
  else
    "${DOCKER[@]}" rm -f dcgm-exporter-hostengine >/dev/null 2>&1 || true
  fi
  local out
  if ! out="$(dc up -d --remove-orphans --quiet-pull 2>&1)"; then
    printf '%s\n' "$out" | sed 's/^/    /'
    if grep -qiE 'nvidia|device driver|gpu' <<<"$out"; then
      die "Docker gagal memberi akses GPU ke container. Cek NVIDIA Container Toolkit: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
    fi
    die "docker compose up gagal (lihat pesan di atas)."
  fi
  reload_prometheus
}

step "Pull image"
set_profiles "$DCGM_MODE"
for i in 1 2 3; do
  if dc pull --quiet 2>&1 | sed 's/^/    /'; then ok "Image siap."; break; fi
  ((i == 3)) && die "Gagal pull image (cek koneksi internet / akses nvcr.io)."
  warn "Pull gagal, coba lagi ($i/3)..."; sleep 5
done

step "Jalankan stack"
deploy "$DCGM_MODE"
ok "Container berjalan: $(dc ps --format '{{.Name}}' | sort | tr '\n' ' ')"

# ----------------------------------------------------------- verifikasi ----
step "Verifikasi Prometheus & node-exporter"
wait_for 90 curl -fsS "$PROM_URL/-/ready" || die "Prometheus tidak siap. Cek: docker logs prometheus"
ok "Prometheus siap ($PROM_URL)"
if ! wait_for 60 is_up node; then
  err="$(target_error node)"
  if command -v ufw >/dev/null && sudo -n ufw status 2>/dev/null | grep -q "Status: active"; then
    SUBNET="$("${DOCKER[@]}" network inspect "${PROJECT}_monitoring" -f '{{(index .IPAM.Config 0).Subnet}}')"
    if confirm "ufw aktif dan memblokir Prometheus -> node-exporter. Izinkan $SUBNET ke port $NODE_EXPORTER_PORT?"; then
      sudo ufw allow from "$SUBNET" to any port "$NODE_EXPORTER_PORT" proto tcp >/dev/null
      wait_for 60 is_up node || die "node-exporter tetap DOWN: $(target_error node)"
    else
      die "node-exporter DOWN: $err"
    fi
  else
    die "node-exporter DOWN: $err. Cek firewall (iptables) yang memblokir bridge docker ke port $NODE_EXPORTER_PORT."
  fi
fi
ok "node-exporter UP"

step "Verifikasi metrik GPU (dcgm-exporter)"
check_dcgm() { # -> 0 ok, 1 target/GPU gagal, 2 profiling tidak ada
  wait_for 120 is_up dcgm || return 1
  wait_for 60 prom_gt0 'count(count by (gpu) (DCGM_FI_DEV_GPU_TEMP{job="dcgm"}))' || return 1
  wait_for 90 prom_has 'count(DCGM_FI_PROF_GR_ENGINE_ACTIVE{job="dcgm"})' || return 2
  return 0
}
dcgm_container() { [[ "$1" == "hostengine" ]] && echo dcgm-exporter-hostengine || echo dcgm-exporter; }
show_dcgm_logs() { info "Log $(dcgm_container "$1") (30 baris terakhir):"; "${DOCKER[@]}" logs --tail 30 "$(dcgm_container "$1")" 2>&1 | sed 's/^/      /'; }

set +e; check_dcgm; rc=$?; set -e
if ((rc != 0)) && [[ "$MODE" == "auto" && "$DCGM_MODE" == "embedded" && $HOST_DCGM_ACTIVE == 1 ]]; then
  warn "Mode embedded: $([[ $rc == 1 ]] && echo 'metrik GPU tidak keluar' || echo 'metrik profiling tidak keluar'). nv-hostengine host aktif -> pindah ke mode hostengine."
  show_dcgm_logs embedded
  DCGM_MODE="hostengine"
  if port_in_use "$DCGM_EXPORTER_PORT"; then die "Port $DCGM_EXPORTER_PORT terpakai; set DCGM_EXPORTER_PORT lain di .env lalu jalankan ulang."; fi
  deploy hostengine
  set +e; check_dcgm; rc=$?; set -e
fi
case $rc in
  0) ok "dcgm-exporter UP (mode $DCGM_MODE), metrik GPU & profiling masuk" ;;
  2) warn "Metrik profiling (DCGM_FI_PROF_*) tidak keluar. Panel 'GPU Busy', SM/Tensor/DRAM, PCIe/NVLink akan kosong."
     show_dcgm_logs "$DCGM_MODE"
     info "Coba: ./install.sh --dcgm-mode hostengine   (atau samakan versi image dengan 'dcgmi --version' di DCGM_EXPORTER_IMAGE)" ;;
  *) show_dcgm_logs "$DCGM_MODE"
     die "dcgm-exporter tidak menghasilkan metrik GPU (target: $(target_health dcgm) $(target_error dcgm))." ;;
esac
SEEN="$(prom_query 'count(count by (gpu) (DCGM_FI_DEV_GPU_TEMP{job="dcgm"}))')"
if [[ "$SEEN" == "$GPU_COUNT" ]]; then ok "Jumlah GPU cocok: $SEEN dari $GPU_COUNT"
else warn "dcgm-exporter melihat $SEEN GPU, nvidia-smi melihat $GPU_COUNT."; fi
MIG_INST="$(prom_query 'count(DCGM_FI_PROF_GR_ENGINE_ACTIVE{job="dcgm",GPU_I_ID!=""}) or count(DCGM_FI_DEV_FB_USED{job="dcgm",GPU_I_ID!=""})')"
[[ -n "$MIG_INST" ]] && info "MIG instance terdeteksi: $MIG_INST"

step "Verifikasi Grafana"
wait_for 120 curl -fsS "$GRAFANA_URL/api/health" || die "Grafana tidak siap. Cek: docker logs grafana"
gf() { curl -fsS --max-time 15 -u "$GF_USER:$GF_PASS" "$@"; }
if ! gf "$GRAFANA_URL/api/user" >/dev/null 2>&1; then
  info "Login gagal (volume Grafana lama memakai password lain) -> reset password admin sesuai .env"
  "${DOCKER[@]}" exec grafana grafana cli admin reset-admin-password "$GF_PASS" >/dev/null 2>&1 ||
    die "Gagal reset password Grafana. Cek: docker logs grafana"
  gf "$GRAFANA_URL/api/user" >/dev/null || die "Login Grafana tetap gagal."
fi
ok "Login Grafana OK (user: $GF_USER)"
wait_for 60 gf "$GRAFANA_URL/api/datasources/uid/prometheus/health" || die "Datasource Prometheus di Grafana tidak sehat."
ok "Datasource Prometheus sehat"
for uid in dgx-b300-overview dgx-b300-host; do
  wait_for 60 gf "$GRAFANA_URL/api/dashboards/uid/$uid" || die "Dashboard $uid tidak termuat. Cek: docker logs grafana"
  ok "Dashboard termuat: $(gf "$GRAFANA_URL/api/dashboards/uid/$uid" | python3 -c 'import sys,json; print(json.load(sys.stdin)["dashboard"]["title"])')"
done
GQ="$(gf -X POST -H 'Content-Type: application/json' "$GRAFANA_URL/api/ds/query" \
  -d '{"from":"now-5m","to":"now","queries":[{"refId":"A","datasource":{"uid":"prometheus"},"expr":"count(count by (gpu) (DCGM_FI_DEV_GPU_TEMP{job=\"dcgm\"}))","instant":true}]}' |
  python3 -c 'import sys,json
f=json.load(sys.stdin)["results"]["A"].get("frames",[])
print(int(f[0]["data"]["values"][-1][0]) if f and f[0]["data"]["values"] else "")' 2>/dev/null || true)"
[[ -n "$GQ" ]] || die "Query lewat Grafana tidak mengembalikan data."
ok "Query lewat Grafana mengembalikan data ($GQ GPU)"

step "Cek semua panel dashboard"
info "Menunggu ~40 detik agar panel berbasis rate() punya cukup data..."
sleep 40
if CHECK_OUT="$(python3 test/check_dashboards.py "$PROM_URL" 2>&1)"; then
  ok "Semua query dashboard mengembalikan data ($(grep -c '^  ok' <<<"$CHECK_OUT") query OK)"
  OPT="$(grep 'empty (opsional)' <<<"$CHECK_OUT" | sed -E 's/.*series  //' | sed -E 's/ \[[A-Z]\]$//' | sort -u | paste -sd, | sed 's/,/, /g')"
  [[ -n "$OPT" ]] && info "Kosong tapi wajar (MIG off / tanpa IB / tanpa sensor): $OPT"
else
  warn "Ada panel yang kosong:"
  grep -E 'EMPTY|ERROR' <<<"$CHECK_OUT" | sed 's/^/      /'
fi

# ------------------------------------------------------------- ringkasan ---
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; IP="${IP:-localhost}"
printf '\n%s════════════════════════════════════════════════════════════%s\n' "$C_G$C_B" "$C_0"
if ((${#WARNINGS[@]})); then
  printf '%s Selesai dengan %d peringatan%s\n' "$C_Y$C_B" "${#WARNINGS[@]}" "$C_0"
else
  printf '%s Selesai — semua verifikasi lolos%s\n' "$C_G$C_B" "$C_0"
fi
printf '%s════════════════════════════════════════════════════════════%s\n' "$C_G$C_B" "$C_0"
printf '  Grafana     : http://%s:%s   (user: %s, password: lihat GRAFANA_ADMIN_PASSWORD di %s/.env)\n' "$IP" "$GRAFANA_PORT" "$GF_USER" "$ROOT"
printf '  Dashboard   : GPU B300 Monitoring (home), Node Host Monitoring\n'
printf '  Prometheus  : http://%s:%s\n' "$IP" "$PROMETHEUS_PORT"
printf '  Mode DCGM   : %s\n' "$DCGM_MODE"
if ((${#WARNINGS[@]})); then
  printf '  Peringatan  :\n'; printf '    - %s\n' "${WARNINGS[@]}"
fi
printf '  Setelah mengubah layout MIG: docker restart %s\n\n' "$(dcgm_container "$DCGM_MODE")"
