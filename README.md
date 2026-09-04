# WSO2 Agent Manager on a dedicated Colima VM

Run the WSO2 Agent Management Platform (AMP) locally on macOS, inside its own
Colima VM, with **snapshot backups you can actually restore from**.

One command brings the platform up. One command freezes it. One command puts it
back exactly as it was.

---

## Starting from scratch

**The five steps that matter.** Total: about 22 minutes, nearly all of it in step 4.

```bash
# 1. Destroy the VM and wipe .colima/        (~5 s)
./amp.sh nuke -y

# 2. Check that nothing is left behind       (~1 s)
./amp.sh doctor

# 3. Create the new VM                       (~35 s)
./amp.sh up

# 4. Install AMP                             (~20 min)
./amp.sh install

# 5. Snapshot it immediately, before touching anything   (~1 min)
./amp.sh backup clean-install
```

Then open **http://console.amp.localhost:8080** — user `admin`, password `admin`.

### Why each step

| Step | Why it is there |
|---|---|
| `nuke -y` | Deletes the VM, the data disk **and the whole `.colima/` directory**. `-y` skips the prompt; without it you are asked to type `yes` |
| `doctor` | The profile paths must read `MISSING` and no orphaned data disk may be reported. If one is, something survived the wipe |
| `up` | Creates a fresh VM: 4 CPU, 8 GB RAM, 60 GB disk |
| `install` | The only slow step — and the only one you will not repeat |
| `backup clean-install` | The step people skip and later regret. Do it **before** installing anything on top |

> **Step 5 is not optional.** Once that snapshot exists, getting back to a clean
> platform is `./amp.sh restore clean-install` — two minutes instead of twenty.
> Skip it and every reset costs you a full reinstall.

Starting fresh on a machine that has never run this before? Skip steps 1 and 2 —
there is nothing to destroy — and begin at step 3.

### From then on

```bash
./amp.sh up                      # start working
./amp.sh stop                    # stop the VM, keep everything
./amp.sh restore clean-install   # back to a clean platform, ~2 min
```

---

## Where everything lives

By default this project keeps **all** Colima and Lima state inside itself:

```
<project>/.colima/          the LIVE VM        — Colima writes here as you work
<project>/.colima_backups/  the SNAPSHOTS      — frozen copies you can restore
```

Nothing is written to `~/.colima`. That is deliberate: clone the repo, run it,
delete the folder, and your machine is exactly as it was.

### `.colima` — the live VM

This is the running machine, not a copy. A typical installation:

| Path (under `.colima/colima/`) | Size | What it is |
|---|---|---|
| `_lima/_disks/colima-<profile>/datadisk` | **11 GB** | `/var/lib/docker`: images, k3d containers, volumes — **all Kubernetes state** |
| `_lima/colima-<profile>/diffdisk` | 1.3 GB | The VM root filesystem (Ubuntu) |
| `_lima/colima-<profile>/basedisk` | 347 MB | The Ubuntu base image it was built from |
| `<profile>/` | KB | `colima.yaml` and the Docker socket |
| `_lima/_config/` | KB | SSH keys |
| `_store/colima-<profile>.json` | bytes | The `disk_formatted` flag |

**Never edit or delete anything in here by hand.** These are live virtual disks;
touching them while the VM is running corrupts it. To remove it, use
`./amp.sh nuke`.

If you moved an existing `~/.colima` into the project, any other Colima profiles
you had came along too — `_lima/colima/` and `_lima/_disks/colima/` are the
`default` profile, unrelated to AMP but sharing the directory.

### What `nuke` leaves behind

`./amp.sh nuke` removes the whole `.colima/` directory, so the project folder
goes back to just its own files:

```
amp.sh
amp.conf
README.md
.gitignore
.colima_backups/     <- untouched
```

The SSH keys and network configuration inside `.colima/` go with it; Lima
regenerates them on the next `up`.

Two things it deliberately will **not** do:

- **It never touches `.colima_backups/`.** Wiping the VM and losing your
  snapshots are different decisions. Use `./amp.sh rmbackup <name>` for those.
- **If another Colima profile still lives in the state directory, the directory
  is kept.** `nuke` deletes this project's profile only; it will not take out a
  `default` profile that happens to share the folder. It lists what remains and
  tells you how to remove it.

There is also a guard: if `STATE_DIR` were misconfigured to `/` or your home
directory, `nuke` refuses to delete anything.

### `.colima_backups` — the snapshots

Frozen copies, one directory per snapshot, listed with `./amp.sh backups`. These
are safe to inspect, copy elsewhere and delete (`./amp.sh rmbackup <name>`).

### Why the sizes do not add up

`du -sh` will report large numbers for both directories, but the real disk usage
is far smaller: snapshots are APFS clones that **share blocks** with the live VM
until the data diverges. Adding the two figures together double-counts almost
everything. Trust `df -h`, not the sum.

### How it works, and the one catch

Colima **ignores `COLIMA_HOME`**. The only supported way to relocate it is
`XDG_CONFIG_HOME`, and Colima honours that *only while `~/.colima` does not
exist*; otherwise it prints `found ~/.colima, ignoring $XDG_CONFIG_HOME` and
keeps using the home directory. `amp.sh` exports the variable for you and
refuses to run if `~/.colima` reappears, rather than silently using the wrong
directory.

The catch: **`colima` run by hand outside this project will not see these
profiles.** Use `./amp.sh` for everything, or export the variable yourself:

```bash
export XDG_CONFIG_HOME=/path/to/this/project/.colima
colima list
```

### The path length limit

macOS caps a Unix socket path at 104 characters, and ssh appends a random
17-character suffix to its control socket. The real constraint is:

```
len(state directory) + len(profile name) + 40  <=  104
```

Exceed it and the VM boots for ten minutes before dying with the unhelpful
`did not receive an event with the running status`. `amp.sh` checks this before
every start and refuses in a fraction of a second, telling you by how much you
are over and how to fix it. This is why the profile is called `amp` and not
something longer.

If you hit the limit, pick one of these in `amp.conf`:

```bash
: "${AMP_PROFILE:=amp}"              # a shorter profile name
: "${AMP_STATE_DIR:=~/.colima-amp}"  # or move the state out of the project
```

### Configuration

Edit `amp.conf`. Plain `KEY=value` lines — change a number and you are done:

```bash
CPU=4
MEMORY=8
DISK=60
STATE_DIR=.colima
PROFILE=amp
```

Anything exported in your shell still wins, so you can override a single run
without touching the file:

```bash
AMP_MEMORY=16 ./amp.sh up
```

A typo is reported rather than silently ignored. `.colima/` and
`.colima_backups/` are in `.gitignore`; `amp.conf` is committed so everyone
starts from the same settings.

---

## Requirements

| Tool | Notes |
|---|---|
| macOS on Apple Silicon | Uses the `vz` hypervisor + Rosetta |
| [Colima](https://github.com/abiosoft/colima) 0.6+ | Tested on 0.9.1 |
| Docker CLI | Any client works — the script always targets its own context |
| ~25 GB free disk | The VM and its data disk |
| APFS volume | Enables instant, zero-cost snapshots (see [Why backups are free](#why-backups-are-free)) |

```bash
brew install colima docker
chmod +x amp.sh
```

The script never touches your default Docker context. It creates and uses a
dedicated profile (`amp`) and context (`colima-agent-manager`), so it
coexists with Rancher Desktop, Docker Desktop, or another Colima profile.

---

## Daily use

```bash
./amp.sh up       # start working
./amp.sh stop     # stop the VM, keep everything
./amp.sh status   # VM, containers, nodes and pods
./amp.sh amp      # shell into the dev container
```

`up` tells you what to do next based on what it finds: `install` on an empty VM,
the console URL once the platform is there.

Run `install` **once**. After that, going back to a clean state is a `restore`.

---

## Commands

### Normal cycle

| Command | What it does |
|---|---|
| `./amp.sh up` | Creates or starts the VM, starts the k3d cluster in the correct order, waits until the pods are stable |
| `./amp.sh install` | Runs `install.sh` non-interactively inside the dev container (idempotent) |
| `./amp.sh amp` | Opens a shell in the dev container (persistent — it survives exits and restarts) |
| `./amp.sh stop` | Stops the cluster cleanly, then the VM. Nothing is lost |
| `./amp.sh status` | VM state, containers, Kubernetes nodes and pods |
| `./amp.sh k <args>` | `kubectl` against the cluster without entering anything — e.g. `./amp.sh k get pods -A` |
| `./amp.sh shell` | SSH into the VM |
| `./amp.sh ip` / `console` | VM IP / open the console in your browser |
| `./amp.sh uninstall` | Removes AMP and the k3d cluster (keeps the VM) |

### Backups

| Command | What it does |
|---|---|
| `./amp.sh backup <name>` | Full snapshot: VM disk + data disk + config + a YAML dump of every Kubernetes resource |
| `./amp.sh backups` | Lists every snapshot with its name, date and size — the names you pass to `restore` |
| `./amp.sh restore <name>` | Restores a snapshot and brings the cluster back up |
| `./amp.sh rmbackup <name>` | Deletes a snapshot |

### Diagnostics and rescue

| Command | What it does |
|---|---|
| `./amp.sh doctor` | Checks paths, profiles, disk space, `disk_formatted`, orphaned data disks |
| `./amp.sh rescue` | Rebuilds a VM on top of an orphaned data disk (VM gone, data still there) |
| `./amp.sh reset-container` | Deletes the dev container. VM and cluster stay untouched |
| `./amp.sh nuke [-y]` | **Destroys** the VM and wipes the state directory, leaving the project folder with only its own files. Does *not* delete your backups |

### Environment variables

```bash
AMP_PROFILE=agent-manager   # Colima profile name
AMP_CPU=4  AMP_MEMORY=8  AMP_DISK=60
AMP_IMAGE=ghcr.io/wso2/amp-quick-start:v1.0.0-rc2
AMP_BACKUP_DIR=./.colima_backups/<profile>
AMP_YES=1                   # never prompt for confirmation
AMP_WAIT_PODS=0             # don't wait for pods to settle
```

---

## Backup and restore

### What gets saved

Colima keeps your state in **two separate disks**. A backup that misses the
second one saves nothing of value:

| Path | Contents |
|---|---|
| `<state>/_lima/colima-<profile>/diffdisk` | The VM root filesystem |
| `<state>/_lima/_disks/colima-<profile>/datadisk` | **`/var/lib/docker`: images, k3d containers, volumes — all Kubernetes state** |
| `<state>/<profile>/colima.yaml` | Profile configuration |
| `<state>/_store/colima-<profile>.json` | `disk_formatted: true` |
| `<state>/_lima/_config/` | SSH keys |

That last JSON file matters more than its size suggests: **if it is missing,
Colima reformats the data disk on the next boot** and everything is gone.

Every backup also stores a logical YAML dump of the cluster
(`<backup>/k8s/`) — every namespace, deployment, config map, secret, PVC and
CRD. It is not needed for a restore, but it is invaluable for inspecting or
diffing what was running without booting anything.

### Why backups are free

On APFS the snapshot uses `clonefile(2)`: copy-on-write clones that are instant
and consume no extra space until the data diverges.

Measured on a real run: **12.4 GB backed up in 57 seconds, with no change in
free disk space.**

Because of that, there is no reason to be stingy. Take a snapshot before
anything risky.

### Listing what you have

```bash
./amp.sh backups
```

```
NAME             CREATED                VM      DATA
clean-install    2026-08-31 20:24:57    1,4G    11G
one-agent        2026-08-31 20:47:25    1,7G    17G
```

The first column is the name you pass to `restore`. `VM` is the virtual machine
disk, `DATA` is the data disk holding everything Kubernetes.

Full details of any snapshot live in its own manifest:

```bash
cat .colima_backups/amp/one-agent/manifest.txt
```

```
profile=amp
created=2026-08-31 20:47:25 +0200
colima=colima version 0.9.1
host=your-mac.local
size_instance=1,7G
size_datadisk=17G
k8s_dump=yes
```

Names are yours to choose, so make them mean something later:
`clean-install`, `before-gateway-upgrade`, `demo-ready`.

### Restoring

```bash
./amp.sh restore instalacion-base
```

Before overwriting anything, `restore` saves your current state to
`_pre-restore-<timestamp>` — so even an unwanted restore is reversible.

The restore is faithful in both directions. Verified end to end: a deleted
namespace comes back, and a config map created *after* the snapshot is gone
afterwards.

### Suggested routine

```bash
./amp.sh backup instalacion-base    # right after installing, before touching anything
# ...work...
./amp.sh backup before-upgrade      # before anything risky
./amp.sh restore instalacion-base   # whenever you need a clean slate
```

---

## Troubleshooting

**Always start here:**

```bash
./amp.sh doctor
```

It reports paths, profile state, free space, whether `disk_formatted` is safe,
and whether there is an orphaned data disk worth rescuing.

### Pods stuck in `Pending` after a restart

The node is cordoned. k3s does a cordon+drain on `SIGTERM` and never reverses it
on boot, so nothing can be scheduled (`1 node(s) were unschedulable`).

`up` and `restore` handle this automatically. Manually:

```bash
./amp.sh k uncordon k3d-amp-local-server-0
```

### The k3s node restarts in a loop

```
fatal: Failed to start networking: unable to initialize network policy
       controller: error getting node subnet: failed to find interface
       with specified node ip
```

When the Docker daemon comes up, the k3d containers start simultaneously under
their restart policy and race for IPs. If the load balancer grabs the server's
address (`172.18.0.2`), k3s cannot find its interface and dies repeatedly.

That is why this script always stops every node and restarts the cluster with
`k3d cluster start` (server → agents → load balancer) instead of trusting
Docker's restart policies. `./amp.sh up` fixes an already-broken cluster.

### Every start fails with a missing socket

```
fatal: dial unix .../_lima/_networks/user-v2/user-v2_fd.sock: no such file
```

Lima's network daemon is alive but its sockets are gone, and its PID file makes
Lima believe everything is fine. `up` and `restore` detect this and restart the
daemon. Note this daemon is **global to every Lima instance**, so the restart
briefly affects your other Colima profiles.

`_networks` is global runtime state and is deliberately never backed up or
restored.

### "My VM is gone but I never deleted it"

If the profile disappeared but `<state>/_lima/_disks/colima-<profile>/` is
still there, your work is recoverable:

```bash
./amp.sh doctor    # reports the orphaned data disk
./amp.sh rescue    # backs it up, then rebuilds a VM on top of it
```

`rescue` sets `disk_formatted=true` first, so Colima mounts the disk instead of
wiping it.

### The console does not answer

```bash
./amp.sh k get pods -n wso2-amp     # amp-api, amp-console, amp-postgresql
./amp.sh status
```

After a restart the ~52 pods need a few minutes. `up` waits for them and prints
`✔ Plataforma lista` when they are all stable.

---

## How it works

```
macOS host
└── Colima profile "agent-manager"      (VM: vz + Rosetta, 4 CPU / 8 GB)
    ├── dev container "amp-quick-start"  ← ./install.sh runs here
    └── k3d cluster "amp-local"
        ├── k3d-amp-local-server-0       ← k3s, all AMP workloads
        └── k3d-amp-local-serverlb       ← publishes ports to the VM
```

The dev container mounts the VM's Docker socket and uses host networking, so the
k3d cluster it creates lives in the **VM's** Docker daemon — not inside the
container. That is why the container itself is disposable while the cluster
state persists in the data disk.

Lima forwards the published ports to your Mac, which is why
`console.amp.localhost:8080` works from your browser.

### Ports

| Port | Service |
|---|---|
| 8080 / 8443 | OpenChoreo UI and API — the AMP console |
| 19080 / 19443 | Data plane gateway (your workloads) |
| 10082 | Workflow plane container registry |
| 11080 / 11082 / 11085 | Observability: Observer API, OpenSearch |

### Paths (Colima 0.9.x)

Colima does **not** use `~/.lima`. Lima state lives under `<state>/_lima/`, where `<state>` is
`<project>/.colima/colima` by default.
This trips up most hand-written backup scripts.

```
<state>/_lima/colima-<profile>/          VM instance
<state>/_lima/_disks/colima-<profile>/   data disk  ← the one that matters
<state>/_lima/_config/                   SSH keys (global to all instances)
<state>/_lima/_networks/                 network daemon (global, never back up)
<state>/<profile>/                       colima.yaml + docker.sock
<state>/_store/colima-<profile>.json     disk_formatted flag
```

---

## Measured timings

On an Apple Silicon Mac, from a real run:

| Operation | Time |
|---|---|
| Create the VM (`up`, first time) | 35 s |
| Install AMP (`install`) | ~20 min |
| Backup (12.4 GB) | 57 s |
| `stop` + `up` | ~2 min |
| Full `restore` | ~2 min |
