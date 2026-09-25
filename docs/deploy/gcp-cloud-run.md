---
title: Google Cloud Run
summary: Deploy Paperclip to Google Cloud Run with Sign in with Google, Gemini on Vertex AI, Cloud SQL, and private LLM endpoints
---

Deploy Paperclip to Google Cloud with one guided script. The result:

- **Cloud Run** runs one always-on instance of the production image. Paperclip's schedulers and agent runs live in that process.
- **Cloud SQL for PostgreSQL** holds the data. The instance has a private IP only, and Cloud Run reaches it through **Direct VPC egress**.
- **Cloud Storage** holds uploads, agent instructions and skills (GCS FUSE volumes), so they survive redeploys.
- **Secret Manager** holds every secret. Nothing secret is baked into the image or passed on a command line you can see.
- **Sign in with Google** (OAuth 2.0) for board users, limited to the email domains or addresses you allow.
- **Gemini on Vertex AI** through the service's own identity (Application Default Credentials): no API key, no key file. Default model: `gemini-3.8-flash`.
- Optional: **self-hosted OpenAI-compatible LLMs** (vLLM, TGI, Ollama, LiteLLM) on private addresses in your VPC, for OpenCode agents.

## Prerequisites

- A Google account with a billing account. The script can create the project.
- `gcloud`, `openssl`, `curl` and `git` on your `PATH`. The script runs on bash 3.2+, so the macOS default works.
- On a new project you are the Owner, which is enough. On an existing project you need: Cloud Run Admin, Service Account User, Artifact Registry Writer, Cloud Build Editor, Secret Manager Admin, Cloud SQL Admin, Storage Admin, Logging Viewer. To create missing APIs, networks or service accounts you also need: Service Usage Admin, Compute Network Admin, Service Account Admin.

## Quick start

```sh
scripts/gcp-cloud-run.sh setup
```

Every step does the same four things:

1. It explains what it does and why.
2. It checks what already exists and skips it.
3. It prints the exact `gcloud` command.
4. It asks before running the command.

Your answers go to `secrets/cloud-run.env`. That file is gitignored and holds no secret values, only resource and secret names. Run `setup` again at any time: finished steps are skipped.

Useful options:

| Option | Effect |
|--------|--------|
| `--dry-run` | Print the commands that would change things; run only read-only checks |
| `--yes` | Accept every default (non-interactive) |
| `--key-file SA.json` | Use a service-account key for this run without changing your gcloud config |
| `--local-build` | Build with your local docker daemon instead of Cloud Build |
| `--config FILE` | Use another answers file |

After the first setup:

```sh
scripts/gcp-cloud-run.sh deploy           # rebuild and redeploy the current commit
scripts/gcp-cloud-run.sh bootstrap-admin  # print a new first-admin invite URL
```

## What setup does

| Step | What happens | Main command |
|------|--------------|--------------|
| Project and billing | Uses or creates the project and links billing | `gcloud projects create`, `gcloud billing projects link` |
| APIs | Enables Cloud Run, Artifact Registry, Cloud Build, Secret Manager, Cloud SQL Admin, Compute, Service Networking, Vertex AI, IAM, Logging | `gcloud services enable` |
| Artifact Registry | A Docker repository for the image | `gcloud artifacts repositories create` |
| Cloud Build identity | New projects build as the Compute Engine default service account. The script grants it `roles/cloudbuild.builds.builder`. | `gcloud projects add-iam-policy-binding` |
| Runtime service account | The identity Paperclip runs as, with `roles/aiplatform.user` for Gemini | `gcloud iam service-accounts create` |
| Network | A VPC and a subnet in the region, for Direct VPC egress | `gcloud compute networks (subnets) create` |
| Database | A new private-IP Cloud SQL instance, a new database on an existing instance, or a connection string you paste | `gcloud sql instances/databases/users create` |
| Storage bucket | Persistent files, mounted into the container | `gcloud storage buckets create` |
| Application secrets | Auth, JWT, encryption and signing keys, generated locally with `openssl` and sent to Secret Manager on stdin | `gcloud secrets create --data-file=-` |
| Sign in with Google | Stores the OAuth client and asks who may create accounts | Console links (see below) |
| Private LLM endpoint | Optional OpenAI-compatible server for OpenCode agents | — |
| Size and cost | CPU, memory, minimum instances, default Gemini model | — |
| Deploy | Cloud Build builds `--target production`. Cloud Run deploys the image. | `gcloud builds submit`, `gcloud run deploy` |
| First admin | A one-off Cloud Run job creates the first-admin invite | `gcloud run jobs deploy --execute-now` |

The build uploads the repository as `gcloud` filters it (`.gitignore` applies). Before uploading, the script checks that no `secrets/` or `.env` file would be included. `.dockerignore` also keeps them out of the image.

## Sign in with Google

Google creates OAuth clients only in the Cloud Console. The script prints these links for your project:

1. **Branding**: app name and support email.
2. **Audience**:
   - Choose **Internal** when the project belongs to your Google Workspace organization: only your organization's accounts can sign in.
   - Otherwise choose **External**. While the app is in *Testing*, add yourself as a test user (at most 100 test users), or publish it. The `openid`, `email` and `profile` scopes need no Google review.
3. **Clients → Create client → Web application**:
   - Authorized JavaScript origin: `https://<service>-<project-number>.<region>.run.app`
   - Authorized redirect URI: `https://<service>-<project-number>.<region>.run.app/api/auth/callback/google`

Paste the client ID and secret when the script asks, or save them in `secrets/google-oauth-client-id` and `secrets/google-oauth-client-secret` before you run `setup`.

With Google sign-in on, the script turns email sign-up off (`PAPERCLIP_AUTH_DISABLE_SIGN_UP=true`), because email sign-up does not verify addresses. The allowlist (`PAPERCLIP_AUTH_ALLOWED_EMAIL_DOMAINS`, `PAPERCLIP_AUTH_ALLOWED_EMAILS`) is checked whenever an account is created. See [Deployment Modes](deployment-modes.md).

Use the `https://<service>-<project-number>.<region>.run.app` URL. Sign-in cookies and the OAuth redirect are bound to it.

## First admin

`authenticated` + `public` mode has no browser "claim admin" step. `setup` runs `bootstrap-admin` for you. It starts a one-off Cloud Run job, inside the VPC, that creates a single-use invite (valid 72 hours). It then reads the invite URL from the job logs, which needs `roles/logging.viewer`. Open the URL, choose **Continue with Google**, and accept: you are the instance admin. The invite stops working once an admin exists.

## Gemini on Vertex AI

The service sets these environment variables:

- `GOOGLE_GENAI_USE_VERTEXAI=true`
- `GOOGLE_CLOUD_PROJECT=<project>` and `GOOGLE_CLOUD_LOCATION=global`
- `ACPX_AUTH_VERTEX_AI=1`
- `GEMINI_MODEL=gemini-3.8-flash`
- `GEMINI_CLI_TRUST_WORKSPACE=true`

Gemini CLI agents therefore run on Vertex AI as the runtime service account. Vertex AI usage bills to the project. An agent whose model is `auto` uses `GEMINI_MODEL`, and an agent's own model setting wins. The newest Gemini models are served only from the `global` location. See the [Gemini CLI adapter](../adapters/gemini-local.md#vertex-ai-application-default-credentials).

## Private OpenAI-compatible endpoints

Cloud Run sends traffic for private ranges (RFC 1918 and `100.64.0.0/10`) into your VPC. Anything the VPC can reach at a private address is reachable, for example a vLLM server on a VM, an internal load balancer, or a GKE internal service. In the private endpoint step, give three answers:

- the base URL, for example `http://10.128.0.5:8000/v1`
- the model IDs it serves
- optionally, a Secret Manager secret that holds its API key

The script sets `PAPERCLIP_OPENCODE_PROVIDERS` to an OpenAI-compatible provider named `private`. In Paperclip, create an **OpenCode** agent with model `private/<model-id>`.

On the endpoint side, add a VPC firewall rule. It allows TCP from the Cloud Run subnet's range to the server port.

A server that is not in the VPC, for example on a Tailscale tailnet, is not reachable until you route it into the VPC. One way is a VM in the VPC that runs a Tailscale subnet router, plus a VPC route for `100.64.0.0/10`.

## Cost

Always-on means instance-based billing with one minimum instance. Approximate us-central1 list prices, after the free tier:

| Size | Monthly |
|------|---------|
| 1 vCPU / 1 GiB | ~$47 |
| 1 vCPU / 2 GiB (default) | ~$53 |
| 2 vCPU / 4 GiB | ~$110 |

A new `db-f1-micro` Cloud SQL instance adds about $10 per month. Vertex AI calls bill per token. With minimum instances 0 the service is almost free while idle, but agent timers and routines pause until someone opens it.

## Limits

- **One instance.** Paperclip keeps its event bus and schedulers in the process. `--max-instances=1` is required; a rollout briefly overlaps the old and new revision.
- **Ephemeral files.** Agent workspaces, git checkouts and run logs are on the container's in-memory disk, and a restart loses them. Workspaces are cloned again on demand.
- **Gemini CLI engine.** It needs `GEMINI_CLI_TRUST_WORKSPACE=true` on a headless host (the script sets it). Without it, Gemini CLI refuses to run in an untrusted folder.
- **Image drift.** The production image installs agent CLIs at their latest versions, so two builds of the same commit can differ.
- **Organization policies** can block steps. The script names the policy when a step fails:
  - `iam.allowedPolicyMemberDomains` blocks public (`allUsers`) access.
  - `compute.skipDefaultNetworkCreation` removes the `default` network. The script then creates its own.

## Remove everything

`setup` prints these commands with your names filled in. Review before running:

```sh
gcloud run services delete <service> --region=<region> --project=<project>
gcloud run jobs delete <service>-bootstrap-admin --region=<region> --project=<project>
gcloud storage rm -r gs://<bucket>
gcloud secrets list --project=<project> --filter='name~<service>-'   # then gcloud secrets delete NAME
gcloud sql instances delete <instance> --project=<project>            # only if setup created it
```
