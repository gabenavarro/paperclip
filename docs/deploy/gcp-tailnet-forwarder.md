---
title: Tailnet Forwarder
summary: Reach services on a Tailscale tailnet from Paperclip on Cloud Run, with a free-tier VM
---

Paperclip on Cloud Run reaches private servers in its VPC, but not servers on a Tailscale tailnet: Cloud Run cannot run Tailscale's network device. The forwarder is a small VM in your VPC that joins your tailnet and forwards fixed ports. Cloud Run connects to the VM's internal IP, and the VM relays each connection to a tailnet address.

Use it for a self-hosted model server on your tailnet (an OpenAI-compatible endpoint such as vLLM), and for SSH to HPC boxes on your tailnet.

## How it works

- The VM is an `e2-micro` with a 10 GB standard disk. The Compute Engine free tier covers one such VM per billing account in `us-central1`, `us-east1` or `us-west1`.
- The VM has two network interfaces:
  - **NIC 0** is in a small VPC, `<service>-tailnet-fwd-egress`, whose subnet has external IPv6. This is the VM's only way to the internet, which Tailscale needs. External IPv6 is free. An external IPv4 address would cost about $3.65 a month.
  - **NIC 1** is in the Cloud Run subnet. Cloud Run reaches the forwarded ports at this interface's IP through Direct VPC egress. No routes and no proxy settings change.
- The VM joins your tailnet once, with a single-use auth key that the script stores in Secret Manager. The VM's service account can read only that secret.
- One firewall rule lets the Cloud Run subnet reach the forwarded ports. Another lets tailnet peers reach the VM's WireGuard port (UDP 41641) directly over IPv6, so traffic does not go through a relay.
- A systemd unit runs one `socat` forward per port and restarts it when it stops.

**Cost.** The VM, the disk and the IPv6 address are free. Traffic that the VM sends to your tailnet leaves Google Cloud: the first 1 GB a month is free, then it costs about $0.12 per GB.

## Before you start

1. **Add a tag and a grant to your tailnet policy** (https://login.tailscale.com/admin/acls/file). The grant allows the VM to reach only the destinations you forward:

   ```jsonc
   "tagOwners": { "tag:paperclip-forwarder": ["autogroup:admin"] },
   "grants": [
     { "src": ["tag:paperclip-forwarder"], "dst": ["<tailnet IP>"], "ip": ["tcp:<port>"] }
   ]
   ```

   If the policy still has the default allow-all rule (`"src": ["*"]`), change that rule's source to `autogroup:member`. Your own devices keep full access, and the tagged VM gets only the grant.
2. **Generate an auth key** (https://login.tailscale.com/admin/settings/keys): not reusable, not ephemeral, pre-approved, tagged `tag:paperclip-forwarder`, with a 1-day expiry.
3. **Save the key** to `secrets/tailscale-forwarder-authkey` without showing it. In bash:

   ```sh
   install -m 600 /dev/null secrets/tailscale-forwarder-authkey
   read -rs -p "Tailscale auth key: " key && printf '%s' "$key" >> secrets/tailscale-forwarder-authkey; unset key
   ```

   In fish:

   ```fish
   install -m 600 /dev/null secrets/tailscale-forwarder-authkey
   read --silent --prompt-str "Tailscale auth key: " key; printf '%s' $key >> secrets/tailscale-forwarder-authkey; set -e key
   ```

4. **Sign in `gcloud`** with an account that can create VMs, networks, firewall rules and service accounts in the project. The Cloud Run deploy key does not need these rights.

## Create the forwarder

```sh
scripts/gcp-cloud-run.sh forwarder
```

The script asks for the forwards as `VM_PORT=TAILNET_IPV4:PORT` pairs, for example `17434=100.64.1.5:17434`. It shows each `gcloud` command and asks before it runs it. Then it waits until the VM reports `paperclip-forwarder: ready`, and prints the VM's internal IP.

To change the forwards, run the command again. It updates the VM's settings and restarts the VM.

## Check it from Cloud Run

```sh
scripts/gcp-cloud-run.sh forwarder-verify
```

A one-off Cloud Run job in the same VPC sends an HTTP request to each forward. Any answer, even `401`, means that the path works. A failed connection fails the job.

## Use it

- **A model server.** In the private endpoint step of `scripts/gcp-cloud-run.sh setup`, give `http://<VM IP>:<VM_PORT>/v1` as the base URL, the model IDs, and their context window. Then run `scripts/gcp-cloud-run.sh deploy`, and create an OpenCode agent with the model `private/<model-id>`.
- **SSH to an HPC box.** Add a forward such as `2201=<box tailnet IP>:22`. In the Paperclip SSH environment, use the host `<VM IP>` and the port `2201`. See [HPC Agents](hpc-agents.md).

## Security notes

- Everything in the Cloud Run subnet can reach the forwarded ports, not only Paperclip, because a firewall rule cannot tell Cloud Run from other VMs in the same subnet. In a VPC with a broad internal allow rule, such as the default network's `default-allow-internal`, other internal ranges can reach them too. Keep authentication on each target: an API key on the model server, and key-based SSH on the box.
- The tag grant in your tailnet policy limits what the VM itself can reach.
- The VM has no external IPv4 address, so the default network's `default-allow-ssh` rule does not expose it to the internet.

## Remove it

```sh
scripts/gcp-cloud-run.sh forwarder-teardown
```

This deletes the VM, its firewall rules, the egress VPC, the auth-key secret, the service account and the check job. Then remove the device from your tailnet in the Tailscale admin console.

## Settings

The script keeps its answers in `secrets/cloud-run.env`:

| Key | Default | Meaning |
|---|---|---|
| `FORWARDS` | none | `VM_PORT=TAILNET_IPV4:PORT`, comma-separated |
| `FORWARDER` | `<service>-tailnet-fwd` | Name of the VM, and the prefix of the other resources |
| `FORWARDER_ZONE` | `<region>-a` | Zone of the VM |
| `FORWARDER_TAG` | `tag:paperclip-forwarder` | Tailscale tag of the VM |
| `FORWARDER_EGRESS_RANGE` | `172.31.254.0/29` | IPv4 range of the egress subnet. It must not overlap your other subnets. |
| `TS_AUTHKEY_FILE` | `secrets/tailscale-forwarder-authkey` | File with the auth key, read once |
