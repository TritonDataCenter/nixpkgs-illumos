#!/usr/bin/env python3
# mupload.py: upload files to Manta, signing each request with an RSA key held by the ssh agent ($SSH_AUTH_SOCK).
# Python standard library only.
#
#   mupload.py [-j JOBS] [-n] [-k] LOCAL_DIR /USER/public/DIR FILE...   (FILE relative to LOCAL_DIR)
#   mupload.py --ls /USER/public/DIR
#   mupload.py --rm /USER/public/PATH                               (an object, or an empty directory)
#
# It uploads a Nix binary cache made by `nix copy --to file://...` (./push.sh), where no Manta client runs: nixpkgs'
# node-manta needs a node.js that nixpkgs has not for illumos.
#
# MANTA_URL, MANTA_USER and MANTA_KEY_ID (the key's MD5 fingerprint, as node-manta takes it) as for node-manta, and
# MANTA_SUBUSER to sign as that sub-user of MANTA_USER's account, with its key (see ./README.md).
# Directories are made as needed. What each holds is read from its listing, a request a page, not one a file. A file
# whose remote copy has the same size is skipped, and with -k one whose remote copy exists at all (a binary cache's
# NARs are named by their hash, and a store path's narinfo is never replaced); -n only lists what would be uploaded.
# Exits non-zero if any upload failed (a directory Manta refuses, or will not list, fails the files in it).
import base64, concurrent.futures, email.utils, hashlib, http.client, json, os, socket, struct, sys, threading
import urllib.parse

url = urllib.parse.urlparse(os.environ.get("MANTA_URL", "https://us-central.manta.mnx.io"))
user = os.environ["MANTA_USER"]
signer = user + ("/" + os.environ["MANTA_SUBUSER"] if os.environ.get("MANTA_SUBUSER") else "")
key_id = os.environ["MANTA_KEY_ID"].removeprefix("MD5:")


def agent_call(msg):
    s = socket.socket(socket.AF_UNIX)
    s.connect(os.environ["SSH_AUTH_SOCK"])
    s.sendall(struct.pack(">I", len(msg)) + msg)
    n = struct.unpack(">I", recv(s, 4))[0]
    reply = recv(s, n)
    s.close()
    return reply


def recv(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError("ssh agent closed the connection")
        b += c
    return b


def string(b):
    return struct.pack(">I", len(b)) + b


def take(b, i):
    n = struct.unpack(">I", b[i : i + 4])[0]
    return b[i + 4 : i + 4 + n], i + 4 + n


def find_key():
    reply = agent_call(b"\x0b")  # SSH2_AGENTC_REQUEST_IDENTITIES
    assert reply[0] == 12, "unexpected agent reply %d" % reply[0]
    count, i = struct.unpack(">I", reply[1:5])[0], 5
    for _ in range(count):
        blob, i = take(reply, i)
        _, i = take(reply, i)
        md5 = hashlib.md5(blob).hexdigest()
        if ":".join(md5[j : j + 2] for j in range(0, 32, 2)) == key_id:
            return blob
    sys.exit("mupload: key %s is not in the ssh agent" % key_id)


blob = find_key()
lock = threading.Lock()


def sign(data):
    # SSH2_AGENTC_SIGN_REQUEST with SSH_AGENT_RSA_SHA2_256
    with lock:
        reply = agent_call(b"\x0d" + string(blob) + string(data) + struct.pack(">I", 2))
    assert reply[0] == 14, "agent refused to sign (reply %d)" % reply[0]
    sig, _ = take(reply, 1)
    algo, i = take(sig, 0)
    assert algo == b"rsa-sha2-256", algo
    raw, _ = take(sig, i)
    return base64.b64encode(raw).decode()


def request(method, path, body=None, headers=None, length=None, query=""):
    date = email.utils.formatdate(usegmt=True)
    h = {
        "Date": date,
        "Authorization": 'Signature keyId="/%s/keys/%s",algorithm="rsa-sha256",headers="date",signature="%s"'
        % (signer, key_id, sign(("date: " + date).encode())),
    }
    h.update(headers or {})
    if length is not None:
        h["Content-Length"] = str(length)
    c = http.client.HTTPSConnection(url.hostname, url.port or 443, timeout=600)
    c.request(method, urllib.parse.quote(path) + query, body=body, headers=h)
    r = c.getresponse()
    data = r.read()
    c.close()
    return r.status, r.headers, data


made = set()


def mkdirp(d):
    parts = d.strip("/").split("/")
    for n in range(3, len(parts) + 1):  # /USER/public exists
        p = "/" + "/".join(parts[:n])
        if p in made:
            continue
        # PUT on a directory that exists replaces its metadata, role tags too (./README.md): make only what is missing
        st, h, _ = request("HEAD", p)
        if st == 200 and h.get("Content-Type", "").endswith("type=directory"):
            made.add(p)
            continue
        st, _, data = request("PUT", p, headers={"Content-Type": "application/json; type=directory"}, length=0)
        if st not in (200, 204):
            raise RuntimeError("mkdir %s: %d %s" % (p, st, data[:200]))
        made.add(p)


def listing(d):
    # what Manta has in directory d, name -> size (None for a directory), read a page at a time (MUPLOAD_LIST_LIMIT
    # entries, at most Manta's 1024); empty if d does not exist. One request a page rather than one a file.
    # A page after the first starts at its marker, the last name of the one before: it asks for one more and drops it.
    limit = int(os.environ.get("MUPLOAD_LIST_LIMIT", "1024"))
    have, marker = {}, None
    while True:
        n = limit + (1 if marker else 0)
        query = "?limit=%d" % n + ("&marker=" + urllib.parse.quote(marker, safe="") if marker else "")
        st, _, data = request("GET", d, query=query)
        if st == 404:
            return have
        if st != 200:
            raise RuntimeError("list %s: %d %s" % (d, st, data[:200]))
        page = [json.loads(line) for line in data.decode().splitlines() if line]
        for e in page:
            have[e["name"]] = e.get("size") if e["type"] == "object" else None
        if len(page) < n:
            return have
        marker = page[-1]["name"]


def upload(local, remote, dry, keep, have):
    size = os.path.getsize(local)
    there = have.get(os.path.basename(remote), -1)
    if there is not None and there != -1 and (keep or there == size):
        return "skip"
    if dry:
        return "would upload"
    with open(local, "rb") as f:
        st, _, data = request("PUT", remote, body=f, length=size,
                              headers={"Content-Type": "application/octet-stream"})
    if st not in (200, 204):
        raise RuntimeError("PUT %s: %d %s" % (remote, st, data[:200]))
    return "uploaded"


def main(argv):
    if argv[0] == "--rm":
        st, _, data = request("DELETE", argv[1])
        if st not in (200, 204):
            sys.exit("mupload: rm %s: %d %s" % (argv[1], st, data[:200]))
        return 0
    if argv[0] == "--ls":
        st, _, data = request("GET", argv[1])
        for line in data.decode().splitlines():
            e = json.loads(line)
            print(e["name"] + ("/" if e["type"] == "directory" else ""))
        return 0 if st == 200 else 1
    jobs, dry, keep = 8, False, False
    while argv[0].startswith("-"):
        if argv[0] == "-j":
            jobs, argv = int(argv[1]), argv[2:]
        elif argv[0] == "-n":
            dry, argv = True, argv[1:]
        elif argv[0] == "-k":
            keep, argv = True, argv[1:]
        else:
            sys.exit("mupload: unknown option " + argv[0])
    local, remote, files = argv[0], argv[1].rstrip("/"), argv[2:]
    counts, failed = {}, 0
    for d in sorted({os.path.dirname(f) for f in files}):
        try:
            mkdirp(remote + ("/" + d if d else ""))
        except Exception as e:
            print("mupload: %s" % e, file=sys.stderr)
            refused = [f for f in files if os.path.dirname(f) == d]
            failed += len(refused)
            files = [f for f in files if f not in refused]
    have = {}
    for d in sorted({os.path.dirname(f) for f in files}):
        try:
            have[d] = listing(remote + ("/" + d if d else ""))
        except Exception as e:
            print("mupload: %s" % e, file=sys.stderr)
            refused = [f for f in files if os.path.dirname(f) == d]
            failed += len(refused)
            files = [f for f in files if f not in refused]
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        futs = {ex.submit(upload, os.path.join(local, f), remote + "/" + f, dry, keep, have[os.path.dirname(f)]): f
                for f in files}
        for fut in concurrent.futures.as_completed(futs):
            try:
                r = fut.result()
                counts[r] = counts.get(r, 0) + 1
            except Exception as e:
                failed += 1
                print("mupload: %s: %s" % (futs[fut], e), file=sys.stderr)
    print(" ".join("%s %d" % kv for kv in sorted(counts.items())) + " failed %d" % failed)
    return 1 if failed else 0


sys.exit(main(sys.argv[1:]))
