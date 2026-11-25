"""Jalankan semua query PromQL di dashboard terhadap Prometheus dan laporkan panel yang kosong.
Pemakaian: python3 test/check_dashboards.py [http://localhost:9090]
"""
import glob, json, sys, urllib.parse, urllib.request

PROM = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:9090"
# Panel yang memang boleh kosong di kondisi tertentu (mis. MIG off, mesin tanpa InfiniBand).
OPTIONAL_HINTS = ("MIG", "InfiniBand", "Infiniband", "IB", "hwmon")
# Query tertentu yang boleh kosong (mis. NIC virtual melaporkan speed -1 sehingga disaring).
OPTIONAL_TARGETS = {("Status interface", "B")}


def query(expr):
    expr = expr.replace("$__rate_interval", "1m").replace("$__interval", "1m")
    # variabel dashboard = "All"
    expr = expr.replace("$gpu", ".*").replace("$mig_profile", ".*")
    url = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url) as r:
        res = json.load(r)
    if res["status"] != "success":
        raise RuntimeError(res)
    return res["data"]["result"]


def panels(ps):
    for p in ps:
        yield p
        yield from panels(p.get("panels", []))


fail = 0
for f in sorted(glob.glob("grafana/dashboards/*.json")):
    print(f"== {f}")
    for p in panels(json.load(open(f))["panels"]):
        for t in p.get("targets", []):
            if not t.get("expr"):
                continue
            try:
                n = len(query(t["expr"]))
            except Exception as e:  # query error = selalu gagal
                print(f"  ERROR {p['title']!r}: {e}")
                fail += 1
                continue
            optional = any(h in p["title"] for h in OPTIONAL_HINTS) or (p["title"], t["refId"]) in OPTIONAL_TARGETS
            status = "ok" if n else ("empty (opsional)" if optional else "EMPTY")
            if status == "EMPTY":
                fail += 1
            print(f"  {status:<17} {n:>3} series  {p['title']} [{t['refId']}]")
sys.exit(1 if fail else 0)
