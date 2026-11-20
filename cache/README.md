# The binary cache on Manta

`https://us-central.manta.mnx.io/nshalman/public/nix-cache`, signed by `nshalman-manta-1`
(`nshalman-manta-1:OP6w5Fj1u4UO0QE8es0e/SZvic2oy5GIwNOQBKVJb5k=`). The zone image (`zone/root.nix`) trusts that key
and uses the cache; `./push.sh` fills it with what a build used, and `./mupload.py` does the uploading.

## Keys

| What | Where it is used | Backup |
|---|---|---|
| `nshalman-manta-1` signing key | snow-nix-builds, `/root/.config/nix/cache-nshalman-manta-1.sec` (`CACHE_SECRET_KEY` for `push.sh`) | 1Password, Nahum's Employee vault: "Nix binary cache signing key nshalman-manta-1" |
| Manta key of the sub-user `nix_cache_ci` | snow-nix-ci, `/root/.ssh/nix-cache-ci` (RSA 4096, MD5 `6b:fd:45:8c:a0:91:62:63:c4:74:ad:a4:89:ac:f6:f6`) | 1Password, Employee vault: "Manta sub-user nix_cache_ci SSH private key"; the sub-user's (unused) password beside it |

Whoever holds the signing key can give every zone that trusts it any build output: keep it to the places above.
On a self-hosted runner, anyone who can push to the repository can reach what is on the runner's disk, whatever the
workflow's triggers say: the triggers are in the workflow file they push.

## The sub-user

`nix_cache_ci` is a Manta sub-user of the `nshalman` account, for uploading the cache without the account's own key:

```sh
triton -p mnx rbac info
# policy nix-cache-write: CAN getobject, getdirectory, putobject, putdirectory (no delete)
# role nix-cache-writer: policy nix-cache-write, member nix_cache_ci (a default role)
minfo /nshalman/public/nix-cache /nshalman/public/nix-cache/nar | grep role-tag   # nix-cache-writer on both
```

Manta checks the creation of an object or directory against the role tags of its parent directory, and a PUT over
an existing one against that object's own tags; what the sub-user makes is tagged with its roles. So `nix_cache_ci`
can add to `nix-cache` and `nix-cache/nar`, and replace what it added, but not replace what the account uploaded
itself, write anywhere else, or delete anything. `tests/mupload-subuser.sh` checks each of these against Manta.

To upload as the sub-user, with its key in an ssh agent:

```sh
MANTA_USER=nshalman MANTA_SUBUSER=nix_cache_ci MANTA_KEY_ID=6b:fd:45:8c:a0:91:62:63:c4:74:ad:a4:89:ac:f6:f6 \
  CACHE_SECRET_KEY=... ./push.sh /nshalman/public/nix-cache ...
```

A PUT on a directory that exists replaces its metadata, role tags too, and the sub-user is then refused there until
`mchmod -- +nix-cache-writer` puts the tag back. `mupload.py` makes only the directories that are missing; other
tools that make directories over `nix-cache` as the account (`mmkdir -p`, `mput -p`) may well remove the tag.

## Rotating

- The Manta key: generate a new one where it is used, `triton -p mnx rbac key -a nix_cache_ci NEW.pub`, then
  `triton -p mnx rbac key -d nix_cache_ci OLD-FINGERPRINT`, and update the 1Password item.
- The signing key: a new key needs a zone image that trusts it (`zone/root.nix`, `extra-trusted-public-keys`), and
  the cache re-signed or refilled; until zones have that image, keep both keys trusted.
