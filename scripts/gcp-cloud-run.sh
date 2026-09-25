#!/usr/bin/env bash
# Guided setup and deploy of Paperclip on Google Cloud Run.
#
#   scripts/gcp-cloud-run.sh setup            # first-time setup, step by step (new or existing project)
#   scripts/gcp-cloud-run.sh deploy           # build the image and deploy/update the service
#   scripts/gcp-cloud-run.sh bootstrap-admin  # print a one-time invite URL for the first instance admin
#
# Options:
#   --config FILE    answers file (default: secrets/cloud-run.env; KEY=VALUE, no secret values)
#   --key-file FILE  use a service-account key for gcloud without changing your gcloud config
#   --yes            accept every default (non-interactive)
#   --dry-run        print the commands that change things; run only read-only checks
#   --local-build    build with the local docker daemon instead of Cloud Build
#
# Every step explains what it does, detects what already exists, shows the exact
# gcloud command, and asks before it runs. Guide: docs/deploy/gcp-cloud-run.md
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# gcloud must never wait on a hidden prompt; this script asks the questions.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1
CONFIG_FILE="$REPO_ROOT/secrets/cloud-run.env"
YES=0
DRY_RUN=0
LOCAL_BUILD=0
COMMAND=""
STEP=0
STEPS=17

CONFIG_KEYS="PROJECT PROJECT_NUMBER BILLING_ACCOUNT REGION SERVICE AR_REPO IMAGE_TAG RUNTIME_SA NETWORK SUBNET DB_MODE SQL_INSTANCE DB_NAME DB_USER BUCKET GOOGLE_AUTH ALLOWED_DOMAINS ALLOWED_EMAILS GEMINI_MODEL GEMINI_LOCATION PRIVATE_LLM_BASE_URL PRIVATE_LLM_MODELS PRIVATE_LLM_KEY_SECRET CPU MEMORY MIN_INSTANCES"
for key in $CONFIG_KEYS; do printf -v "$key" '%s' ""; done
ACCOUNT=""
PROJECT_CREATED=0
INVITE_URL=""
WORK_DIR=""

# ---------------------------------------------------------------- output ---

say() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

header() {
  STEP=$((STEP + 1))
  say ""
  say "[$STEP/$STEPS] $1"
}

print_cmd() {
  local arg
  printf '  $'
  for arg in "$@"; do
    case "$arg" in
      --password=*) printf ' %s' '--password=********' ;;
      *) printf ' %q' "$arg" ;;
    esac
  done
  printf '\n'
}

# Role an admin must grant when a command is denied.
hint_for() {
  local role=""
  case "$*" in
    "gcloud projects create"*) role="roles/resourcemanager.projectCreator (organization or folder)" ;;
    "gcloud billing projects link"*) role="roles/billing.user on the billing account and roles/billing.projectManager" ;;
    "gcloud services enable"*) role="roles/serviceusage.serviceUsageAdmin" ;;
    "gcloud artifacts"*) role="roles/artifactregistry.admin" ;;
    "gcloud iam service-accounts"*) role="roles/iam.serviceAccountAdmin" ;;
    "gcloud projects add-iam-policy-binding"*) role="roles/resourcemanager.projectIamAdmin" ;;
    "gcloud compute"*|"gcloud services vpc-peerings"*) role="roles/compute.networkAdmin (and roles/servicenetworking.networksAdmin for peering)" ;;
    "gcloud sql"*) role="roles/cloudsql.admin" ;;
    "gcloud storage"*) role="roles/storage.admin" ;;
    "gcloud secrets"*) role="roles/secretmanager.admin" ;;
    "gcloud builds"*) role="roles/cloudbuild.builds.editor" ;;
    "gcloud run"*) role="roles/run.admin and roles/iam.serviceAccountUser on the runtime service account" ;;
  esac
  if [ -n "$role" ]; then
    printf 'If this was a permission error, ask a project admin for %s,\nor ask them to run the command above.\n' "$role" >&2
  fi
  case "$*" in
    "gcloud run deploy"*)
      printf 'If the error mentions "permitted customer" or iam.allowedPolicyMemberDomains, your organization\nblocks public (allUsers) access. Ask an organization admin to allow allUsers for this project.\n' >&2 ;;
    "gcloud compute"*|"gcloud sql instances create"*)
      printf 'If the error names an organization policy (constraints/compute.* or constraints/sql.*),\nan organization admin must allow it for this project.\n' >&2 ;;
  esac
}

# Ask before a command that changes something (not with --yes or --dry-run).
approve() {
  if [ "$YES" = 1 ] || [ "$DRY_RUN" = 1 ]; then return 0; fi
  local answer=""
  read -r -p "  Run it? [Y/n] " answer || true
  case "$answer" in [Nn]*) return 1 ;; *) return 0 ;; esac
}

# Run a command that changes something: show it, ask, then run it (not in --dry-run).
run() {
  print_cmd "$@"
  [ "$DRY_RUN" = 1 ] && return 0
  approve || die "stopped before a required step; run the script again when you are ready"
  local rc=0
  "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    hint_for "$@"
    die "the command above failed (exit $rc)"
  fi
}

# Same as run, but a failure is reported and setup continues.
run_or_warn() {
  print_cmd "$@"
  [ "$DRY_RUN" = 1 ] && return 0
  approve || { warn "skipped"; return 0; }
  "$@" || { hint_for "$@"; warn "the command above failed; continuing"; }
}

# Run a command with a secret on its stdin. The value never reaches argv or output.
run_secret() {
  local value=$1
  shift
  print_cmd "$@"
  say "    (secret value passed on stdin, not shown)"
  [ "$DRY_RUN" = 1 ] && return 0
  approve || die "stopped before a required step; run the script again when you are ready"
  printf '%s' "$value" | "$@" || { hint_for "$@"; die "the command above failed"; }
}

# Read-only probe. Returns 0 when the resource exists, 1 when it does not,
# and 2 when it cannot be checked (for example, a permission error).
probe() {
  local err
  if err=$("$@" 2>&1 >/dev/null </dev/null); then return 0; fi
  case "$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')" in
    *not_found*|*"not found"*|*"does not exist"*) return 1 ;;
  esac
  PROBE_ERROR=$(printf '%s' "$err" | head -n 1)
  return 2
}
PROBE_ERROR=""

# Read-only value lookup; prints nothing on failure.
lookup() { "$@" 2>/dev/null </dev/null || true; }

# ensure_resource "what" -- probe-command...: 0 = already there, 1 = must be created.
ensure_resource() {
  local what=$1 rc=0
  shift
  probe "$@" || rc=$?
  case "$rc" in
    0) say "  ✓ $what already exists"; return 0 ;;
    1) return 1 ;;
    *) warn "cannot check $what ($PROBE_ERROR); assuming it exists"; return 0 ;;
  esac
}

# ---------------------------------------------------------------- prompts ---

ask() { # ask VAR "Question" "default"
  local var=$1 question=$2 default=$3 current answer=""
  current=${!var:-}
  [ -n "$current" ] && default=$current
  if [ "$YES" = 1 ]; then
    printf -v "$var" '%s' "$default"
    say "  $question: ${default:-(none)}"
    return 0
  fi
  read -r -p "  $question [${default}]: " answer || true
  printf -v "$var" '%s' "${answer:-$default}"
}

ask_secret() { # ask_secret VAR "Question" — hidden input
  local var=$1 answer=""
  if [ "$YES" = 1 ]; then printf -v "$var" '%s' ""; return 0; fi
  read -r -s -p "  $2: " answer || true
  printf '\n'
  printf -v "$var" '%s' "$answer"
}

confirm() { # default yes
  [ "$YES" = 1 ] && return 0
  local answer=""
  read -r -p "  $1 [Y/n] " answer || true
  case "$answer" in [Nn]*) return 1 ;; *) return 0 ;; esac
}

choose() { # choose VAR "Question" DEFAULT_INDEX option...
  local var=$1 question=$2 default=$3 i=1 answer="" option
  shift 3
  say "  $question"
  for option in "$@"; do say "    $i) $option"; i=$((i + 1)); done
  if [ "$YES" = 1 ]; then answer=$default; else read -r -p "  Choose [$default]: " answer || true; fi
  answer=${answer:-$default}
  case "$answer" in *[!0-9]*|'') answer=$default ;; esac
  [ "$answer" -ge 1 ] && [ "$answer" -le $# ] || answer=$default
  [ "$YES" = 1 ] && say "  Choice: $answer"
  printf -v "$var" '%s' "$answer"
}

matches() { printf '%s' "$1" | grep -Eq "$2"; }

# ---------------------------------------------------------------- config ---

load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case " $CONFIG_KEYS " in *" $key "*) printf -v "$key" '%s' "$value" ;; esac
  done < "$CONFIG_FILE"
}

save_config() {
  local key
  if [ "$DRY_RUN" = 1 ]; then say "  (dry run: not writing $CONFIG_FILE)"; return 0; fi
  mkdir -p "$(dirname "$CONFIG_FILE")"
  (
    umask 077
    {
      printf '# Paperclip on Cloud Run: answers from scripts/gcp-cloud-run.sh (no secret values).\n'
      for key in $CONFIG_KEYS; do
        [ -n "${!key}" ] && printf '%s=%s\n' "$key" "${!key}"
      done
    } > "$CONFIG_FILE"
  )
  say "  Saved your answers to $CONFIG_FILE"
}

apply_defaults() {
  SERVICE=${SERVICE:-paperclip}
  AR_REPO=${AR_REPO:-paperclip}
  RUNTIME_SA=${RUNTIME_SA:-paperclip-runtime@${PROJECT}.iam.gserviceaccount.com}
  BUCKET=${BUCKET:-${PROJECT}-${SERVICE}}
  DB_NAME=${DB_NAME:-paperclip}
  DB_USER=${DB_USER:-paperclip}
  GEMINI_MODEL=${GEMINI_MODEL:-gemini-3.8-flash}
  GEMINI_LOCATION=${GEMINI_LOCATION:-global}
  CPU=${CPU:-1}
  MEMORY=${MEMORY:-2Gi}
  MIN_INSTANCES=${MIN_INSTANCES:-1}
}

secret_name() { printf '%s-%s' "$SERVICE" "$1"; }

public_url() { printf 'https://%s-%s.%s.run.app' "$SERVICE" "${PROJECT_NUMBER:-PROJECT_NUMBER}" "$REGION"; }

require_config() {
  local key
  for key in PROJECT REGION SERVICE AR_REPO RUNTIME_SA NETWORK SUBNET BUCKET; do
    [ -n "${!key}" ] || die "$key is not set in $CONFIG_FILE; run: scripts/gcp-cloud-run.sh setup"
  done
}

resolve_project_number() {
  [ -n "$PROJECT_NUMBER" ] && return 0
  PROJECT_NUMBER=$(lookup gcloud projects describe "$PROJECT" --format='value(projectNumber)')
}

# ------------------------------------------------------------------ setup ---

step_tools() {
  header "Tools"
  say "  This script needs gcloud, openssl, curl and git on your PATH."
  command -v gcloud >/dev/null 2>&1 || die "gcloud is not installed. Install it from https://cloud.google.com/sdk/docs/install"
  local tool
  for tool in openssl curl git; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
  done
  say "  ✓ gcloud, openssl, curl and git found"
}

step_account() {
  header "Google Cloud sign-in"
  if [ -n "${CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE:-}" ]; then
    ACCOUNT=$(sed -n 's/.*"client_email": *"\([^"]*\)".*/\1/p' "$CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" | head -n 1)
    say "  Using the service-account key for $ACCOUNT (your gcloud config is not changed)."
    return 0
  fi
  ACCOUNT=$(lookup gcloud config get-value account)
  if [ -z "$ACCOUNT" ]; then
    say "  gcloud has no active account."
    confirm "Run 'gcloud auth login' now?" || die "sign in with 'gcloud auth login', then run setup again"
    run gcloud auth login
    ACCOUNT=$(lookup gcloud config get-value account)
  fi
  say "  Signed in as $ACCOUNT"
}

step_project() {
  header "Project and billing"
  say "  Paperclip gets its own Google Cloud project, or reuses one you already have."
  ask PROJECT "Project ID (6-30 characters: lowercase letters, digits, hyphens)" "paperclip-$(date +%y%m%d)"
  matches "$PROJECT" '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' || die "invalid project ID: $PROJECT"
  if ensure_resource "project $PROJECT" gcloud projects describe "$PROJECT"; then
    :
  else
    say "  Project $PROJECT does not exist yet; it will be created."
    run gcloud projects create "$PROJECT" --name="Paperclip"
    PROJECT_CREATED=1
  fi
  resolve_project_number
  [ -n "$PROJECT_NUMBER" ] || say "  (the project number is known after the project exists; the public URL uses it)"

  if [ "$PROJECT_CREATED" = 0 ]; then
    local billing
    if ! billing=$(gcloud billing projects describe "$PROJECT" --format='value(billingEnabled)' 2>/dev/null </dev/null); then
      warn "cannot read the billing status of $PROJECT (needs the Cloud Billing API and billing viewer access); assuming billing is enabled"
      return 0
    fi
    if [ "$billing" = "True" ]; then
      say "  ✓ billing is enabled"
      return 0
    fi
  fi
  say "  Cloud Run, Cloud SQL and Vertex AI need a billing account linked to the project."
  local accounts count
  accounts=$(lookup gcloud billing accounts list --filter='open=true' --format='value(name)' | sed 's#^billingAccounts/##')
  count=$(printf '%s\n' "$accounts" | grep -c . || true)
  if [ "$count" = 0 ]; then
    die "no open billing account is visible to $ACCOUNT. Create one at https://console.cloud.google.com/billing and run setup again"
  fi
  if [ -z "$BILLING_ACCOUNT" ]; then
    if [ "$count" = 1 ] || [ "$YES" = 1 ]; then
      BILLING_ACCOUNT=$(printf '%s\n' "$accounts" | head -n 1)
    else
      say "  Open billing accounts:"
      printf '%s\n' "$accounts" | sed 's/^/    /'
    fi
  fi
  ask BILLING_ACCOUNT "Billing account ID" "$BILLING_ACCOUNT"
  run gcloud billing projects link "$PROJECT" --billing-account="$BILLING_ACCOUNT"
}

step_region() {
  header "Region"
  say "  Cloud Run, the database, the network and the image registry all live in one region."
  ask REGION "Region" "us-central1"
  matches "$REGION" '^[a-z]+-[a-z]+[0-9]+$' || die "invalid region: $REGION"
  ask SERVICE "Cloud Run service name" "paperclip"
  matches "$SERVICE" '^[a-z][a-z0-9-]{0,48}[a-z0-9]$' || die "invalid service name: $SERVICE"
}

step_apis() {
  header "APIs"
  say "  Enabling the Google Cloud APIs Paperclip uses (skips the ones already on)."
  local needed="run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com sqladmin.googleapis.com compute.googleapis.com servicenetworking.googleapis.com aiplatform.googleapis.com iam.googleapis.com logging.googleapis.com"
  local enabled missing="" api
  enabled=" $(lookup gcloud services list --enabled --project="$PROJECT" --format='value(config.name)' | tr '\n' ' ') "
  for api in $needed; do
    case "$enabled" in *" $api "*) ;; *) missing="$missing $api" ;; esac
  done
  if [ -z "$missing" ]; then say "  ✓ all needed APIs are enabled"; return 0; fi
  # shellcheck disable=SC2086 # the API list is intentionally split into arguments
  run gcloud services enable $missing --project="$PROJECT"
}

step_registry() {
  header "Artifact Registry"
  say "  Container images are stored in a Docker repository in $REGION."
  apply_defaults
  ask AR_REPO "Docker repository name" "$AR_REPO"
  if ! ensure_resource "repository $AR_REPO" gcloud artifacts repositories describe "$AR_REPO" --location="$REGION" --project="$PROJECT"; then
    run gcloud artifacts repositories create "$AR_REPO" --repository-format=docker --location="$REGION" --project="$PROJECT" --description="Paperclip images"
  fi
}

step_build_identity() {
  header "Cloud Build identity"
  say "  Cloud Build builds the image in Google Cloud. Its service account must read the"
  say "  uploaded source, write build logs, and push to Artifact Registry."
  local build_sa
  build_sa=$(lookup gcloud builds get-default-service-account --project="$PROJECT" --format='value(serviceAccountEmail)')
  build_sa=${build_sa##*/}
  case "$build_sa" in
    '') warn "could not read the Cloud Build service account; if the build fails, use --local-build" ;;
    *@cloudbuild.gserviceaccount.com) say "  ✓ $build_sa (legacy Cloud Build account; it has these roles by default)" ;;
    *)
      say "  Cloud Build runs as $build_sa. New projects give it no roles; granting the"
      say "  Cloud Build Service Account role (source, logs, image push)."
      run_or_warn gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$build_sa" --role=roles/cloudbuild.builds.builder --condition=None --format=none
      ;;
  esac
}

step_runtime_identity() {
  header "Runtime service account"
  say "  Cloud Run runs Paperclip as this service account. Gemini on Vertex AI uses its"
  say "  identity (Application Default Credentials), so no API key or key file is needed."
  ask RUNTIME_SA "Runtime service account email" "$RUNTIME_SA"
  if ! ensure_resource "service account $RUNTIME_SA" gcloud iam service-accounts describe "$RUNTIME_SA" --project="$PROJECT"; then
    case "$RUNTIME_SA" in
      *@"$PROJECT".iam.gserviceaccount.com) ;;
      *) die "$RUNTIME_SA does not exist and is not in project $PROJECT" ;;
    esac
    run gcloud iam service-accounts create "${RUNTIME_SA%%@*}" --project="$PROJECT" --display-name="Paperclip runtime"
  fi
  say "  Granting Vertex AI User (Gemini calls) to the runtime service account."
  run_or_warn gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$RUNTIME_SA" --role=roles/aiplatform.user --condition=None --format=none
}

step_network() {
  header "Network (Direct VPC egress)"
  say "  Paperclip reaches the database and your private LLM servers through a VPC."
  say "  Traffic to private ranges (RFC 1918 and 100.64.0.0/10) goes through the VPC;"
  say "  everything else (Vertex AI, GitHub, npm) uses the normal internet path."
  ask NETWORK "VPC network" "${NETWORK:-default}"
  if ! ensure_resource "network $NETWORK" gcloud compute networks describe "$NETWORK" --project="$PROJECT"; then
    say "  Network $NETWORK was not found (organizations can turn off the default network)."
    NETWORK=paperclip
    say "  Creating network '$NETWORK' with one subnet in $REGION."
    run gcloud compute networks create "$NETWORK" --subnet-mode=custom --project="$PROJECT"
    SUBNET="paperclip-$REGION"
    run gcloud compute networks subnets create "$SUBNET" --network="$NETWORK" --region="$REGION" --range=10.8.0.0/24 --enable-private-ip-google-access --project="$PROJECT"
    return 0
  fi
  ask SUBNET "Subnet in $REGION (Direct VPC egress needs at least a /26)" "${SUBNET:-$NETWORK}"
  if ! ensure_resource "subnet $SUBNET" gcloud compute networks subnets describe "$SUBNET" --region="$REGION" --project="$PROJECT"; then
    say "  Subnet $SUBNET was not found; creating it (10.8.0.0/24) in $NETWORK."
    run gcloud compute networks subnets create "$SUBNET" --network="$NETWORK" --region="$REGION" --range=10.8.0.0/24 --enable-private-ip-google-access --project="$PROJECT"
  fi
}

# Private IP of a Cloud SQL instance, from "TYPE;TYPE<TAB>IP;IP".
sql_private_ip() {
  local raw types addrs type addr
  raw=$(lookup gcloud sql instances describe "$1" --project="$PROJECT" --format='value(ipAddresses.type,ipAddresses.ipAddress)')
  types=${raw%%$'\t'*}
  addrs=${raw#*$'\t'}
  while [ -n "$types" ]; do
    type=${types%%;*}
    addr=${addrs%%;*}
    if [ "$type" = PRIVATE ]; then printf '%s' "$addr"; return 0; fi
    [ "$types" = "$type" ] && break
    types=${types#*;}
    addrs=${addrs#*;}
  done
}

step_database() {
  header "Database (Cloud SQL for PostgreSQL)"
  say "  Paperclip keeps its data in PostgreSQL. Cloud Run has no persistent disk."
  local choice url_secret ip password
  url_secret=$(secret_name database-url)
  case "$DB_MODE" in new) choice=1 ;; existing) choice=2 ;; url) choice=3 ;; *) choice=1 ;; esac
  choose choice "Where should the database live?" "$choice" \
    "New Cloud SQL instance, private IP only (db-f1-micro, about \$10/month, 5-10 minutes to create)" \
    "Existing Cloud SQL instance with a private IP on this network (a new database and user)" \
    "An existing PostgreSQL 15+ connection string"
  case "$choice" in 1) DB_MODE=new ;; 2) DB_MODE=existing ;; 3) DB_MODE=url ;; esac

  if [ "$DB_MODE" = url ]; then
    if ensure_resource "secret $url_secret" gcloud secrets describe "$url_secret" --project="$PROJECT"; then return 0; fi
    local url=""
    ask_secret url "PostgreSQL connection string (postgres://user:pass@host:5432/db; hidden)"
    [ -n "$url" ] || { [ "$DRY_RUN" = 1 ] && url=dry-run; } || die "a connection string is required"
    run_secret "$url" gcloud secrets create "$url_secret" --project="$PROJECT" --data-file=-
    return 0
  fi

  if [ "$DB_MODE" = new ]; then
    ask SQL_INSTANCE "New Cloud SQL instance name" "${SQL_INSTANCE:-${SERVICE}-db}"
    if ! ensure_resource "Cloud SQL instance $SQL_INSTANCE" gcloud sql instances describe "$SQL_INSTANCE" --project="$PROJECT"; then
      say "  Private IP needs a private services access range and peering on $NETWORK."
      if [ -z "$(lookup gcloud services vpc-peerings list --network="$NETWORK" --project="$PROJECT" --format='value(peering)')" ]; then
        run gcloud compute addresses create paperclip-psa-range --global --purpose=VPC_PEERING --prefix-length=16 --network="$NETWORK" --project="$PROJECT"
        run gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com --ranges=paperclip-psa-range --network="$NETWORK" --project="$PROJECT"
      else
        say "  ✓ private services access is already set up on $NETWORK"
      fi
      say "  Creating Cloud SQL instance $SQL_INSTANCE (PostgreSQL 17, db-f1-micro, private IP only; 5-10 minutes)."
      run gcloud sql instances create "$SQL_INSTANCE" --project="$PROJECT" --region="$REGION" --database-version=POSTGRES_17 --edition=ENTERPRISE --tier=db-f1-micro --network="projects/$PROJECT/global/networks/$NETWORK" --no-assign-ip --storage-size=10
    fi
  else
    ask SQL_INSTANCE "Existing Cloud SQL instance name" "$SQL_INSTANCE"
    [ -n "$SQL_INSTANCE" ] || die "an instance name is required"
  fi

  ask DB_NAME "Database name" "$DB_NAME"
  ask DB_USER "Database user" "$DB_USER"
  if ! ensure_resource "database $DB_NAME" gcloud sql databases describe "$DB_NAME" --instance="$SQL_INSTANCE" --project="$PROJECT"; then
    run gcloud sql databases create "$DB_NAME" --instance="$SQL_INSTANCE" --project="$PROJECT"
  fi
  if ensure_resource "secret $url_secret" gcloud secrets describe "$url_secret" --project="$PROJECT"; then
    say "  (keeping the stored connection string; delete that secret to reset the user password)"
    return 0
  fi
  ip=$(sql_private_ip "$SQL_INSTANCE")
  if [ -z "$ip" ]; then
    [ "$DRY_RUN" = 1 ] || die "$SQL_INSTANCE has no private IP; add one on network $NETWORK (Cloud SQL > Connections)"
    ip=PRIVATE_IP
  fi
  password=$(openssl rand -hex 24)
  if probe gcloud sql users describe "$DB_USER" --instance="$SQL_INSTANCE" --project="$PROJECT"; then
    confirm "User $DB_USER exists. Set a new password for it?" || die "the connection string needs the user's password"
    run gcloud sql users set-password "$DB_USER" --instance="$SQL_INSTANCE" --project="$PROJECT" --password="$password"
  else
    run gcloud sql users create "$DB_USER" --instance="$SQL_INSTANCE" --project="$PROJECT" --password="$password"
  fi
  run_secret "postgres://$DB_USER:$password@$ip:5432/$DB_NAME" gcloud secrets create "$url_secret" --project="$PROJECT" --data-file=-
}

step_bucket() {
  header "Storage bucket"
  say "  Uploads, agent instructions and skills are stored in Cloud Storage, so they"
  say "  survive restarts and redeploys (mounted into the container with GCS FUSE)."
  apply_defaults
  ask BUCKET "Bucket name" "$BUCKET"
  if ! ensure_resource "bucket gs://$BUCKET" gcloud storage buckets describe "gs://$BUCKET" --project="$PROJECT"; then
    run gcloud storage buckets create "gs://$BUCKET" --project="$PROJECT" --location="$REGION" --uniform-bucket-level-access --public-access-prevention
  fi
  run_or_warn gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="serviceAccount:$RUNTIME_SA" --role=roles/storage.objectUser --format=none
}

grant_secret() {
  run_or_warn gcloud secrets add-iam-policy-binding "$1" --project="$PROJECT" --member="serviceAccount:$RUNTIME_SA" --role=roles/secretmanager.secretAccessor --condition=None --format=none
}

step_app_secrets() {
  header "Application secrets"
  say "  Paperclip needs stable signing and encryption keys. They are generated here,"
  say "  stored only in Secret Manager, and never printed."
  local name value
  for name in better-auth-secret agent-jwt-secret secrets-master-key decision-signing-secret tool-action-signing-secret; do
    if ! ensure_resource "secret $(secret_name "$name")" gcloud secrets describe "$(secret_name "$name")" --project="$PROJECT"; then
      if [ "$name" = secrets-master-key ]; then value=$(openssl rand -base64 32); else value=$(openssl rand -hex 32); fi
      run_secret "$value" gcloud secrets create "$(secret_name "$name")" --project="$PROJECT" --data-file=-
    fi
  done
  for name in database-url better-auth-secret agent-jwt-secret secrets-master-key decision-signing-secret tool-action-signing-secret; do
    grant_secret "$(secret_name "$name")"
  done
}

step_google_signin() {
  header "Sign in with Google"
  resolve_project_number
  local url oauth_dir id_secret secret_secret client_id="" client_secret=""
  url=$(public_url)
  oauth_dir=$(dirname "$CONFIG_FILE")
  id_secret=$(secret_name google-oauth-client-id)
  secret_secret=$(secret_name google-oauth-client-secret)
  say "  Board users sign in with their Google account (OAuth 2.0). Google allows"
  say "  creating the OAuth client only in the Cloud Console:"
  say "    1. Branding (app name, support email): https://console.cloud.google.com/auth/branding?project=$PROJECT"
  say "    2. Audience: 'Internal' if the project belongs to your Google Workspace organization;"
  say "       otherwise 'External' (add yourself as a test user, or publish; basic scopes need no review):"
  say "       https://console.cloud.google.com/auth/audience?project=$PROJECT"
  say "    3. Create a client of type 'Web application': https://console.cloud.google.com/auth/clients/create?project=$PROJECT"
  say "         Authorized JavaScript origin: $url"
  say "         Authorized redirect URI:      $url/api/auth/callback/google"
  if probe gcloud secrets describe "$secret_secret" --project="$PROJECT"; then
    say "  ✓ an OAuth client is already stored in Secret Manager"
    GOOGLE_AUTH=yes
  else
    [ -f "$oauth_dir/google-oauth-client-id" ] && client_id=$(tr -d '[:space:]' < "$oauth_dir/google-oauth-client-id")
    [ -f "$oauth_dir/google-oauth-client-secret" ] && client_secret=$(tr -d '[:space:]' < "$oauth_dir/google-oauth-client-secret")
    if [ -z "$client_id" ] && [ "$YES" != 1 ]; then
      confirm "Set up Sign in with Google now? (answer n to use email and password only)" && {
        ask client_id "OAuth client ID" ""
        ask_secret client_secret "OAuth client secret (hidden)"
      }
    fi
    if [ -n "$client_id" ] && [ -n "$client_secret" ]; then
      run_secret "$client_id" gcloud secrets create "$id_secret" --project="$PROJECT" --data-file=-
      run_secret "$client_secret" gcloud secrets create "$secret_secret" --project="$PROJECT" --data-file=-
      GOOGLE_AUTH=yes
    else
      warn "no OAuth client yet: Sign in with Google stays off (email and password only)."
      warn "Put the ID and secret in $oauth_dir/google-oauth-client-id and -secret, then run setup again."
      GOOGLE_AUTH=no
    fi
  fi
  if [ "$GOOGLE_AUTH" = yes ]; then
    grant_secret "$id_secret"
    grant_secret "$secret_secret"
  fi

  say "  Who may create an account? New accounts are refused unless the email or its"
  say "  domain is listed. Existing accounts keep signing in."
  local domain=${ACCOUNT##*@}
  case "$ACCOUNT" in
    *.gserviceaccount.com|'') ;;
    *@gmail.com|*@googlemail.com) [ -n "$ALLOWED_DOMAINS$ALLOWED_EMAILS" ] || ALLOWED_EMAILS=$ACCOUNT ;;
    *) [ -n "$ALLOWED_DOMAINS$ALLOWED_EMAILS" ] || ALLOWED_DOMAINS=$domain ;;
  esac
  ask ALLOWED_DOMAINS "Allowed email domains (comma-separated, blank for none)" "$ALLOWED_DOMAINS"
  ask ALLOWED_EMAILS "Allowed individual emails (comma-separated, blank for none)" "$ALLOWED_EMAILS"
  if [ -z "$ALLOWED_DOMAINS$ALLOWED_EMAILS" ]; then
    warn "no allowlist: anyone who can reach the URL can create an account (with no company access until invited)"
  fi
}

is_private_host() {
  local host=$1 a b rest
  case "$host" in localhost|*.internal|*.local) return 0 ;; esac
  matches "$host" '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
  a=${host%%.*}; rest=${host#*.}; b=${rest%%.*}
  [ "$a" = 10 ] && return 0
  [ "$a" = 192 ] && [ "$b" = 168 ] && return 0
  [ "$a" = 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
  [ "$a" = 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
  return 1
}

step_private_llm() {
  header "Private OpenAI-compatible LLM endpoint (optional)"
  say "  OpenCode agents can use a self-hosted model server that speaks the OpenAI API"
  say "  (vLLM, TGI, Ollama, LiteLLM) on a private address in your VPC. Leave blank to skip."
  ask PRIVATE_LLM_BASE_URL "Base URL (for example http://10.128.0.5:8000/v1)" "$PRIVATE_LLM_BASE_URL"
  [ -n "$PRIVATE_LLM_BASE_URL" ] || { say "  Skipped."; return 0; }
  matches "$PRIVATE_LLM_BASE_URL" '^https?://[^/[:space:]]+' || die "the base URL must start with http:// or https://"
  local host=${PRIVATE_LLM_BASE_URL#*://}
  host=${host%%[/:]*}
  is_private_host "$host" || warn "$host is not a private address; this traffic will use the internet, not the VPC"
  ask PRIVATE_LLM_MODELS "Model IDs it serves (comma-separated)" "$PRIVATE_LLM_MODELS"
  matches "$PRIVATE_LLM_MODELS" '^[A-Za-z0-9._:/@-]+(,[A-Za-z0-9._:/@-]+)*$' || die "list model IDs separated by commas"
  ask PRIVATE_LLM_KEY_SECRET "Secret Manager secret holding its API key (blank: none, or a new name to create)" "$PRIVATE_LLM_KEY_SECRET"
  if [ -n "$PRIVATE_LLM_KEY_SECRET" ] && ! ensure_resource "secret $PRIVATE_LLM_KEY_SECRET" gcloud secrets describe "$PRIVATE_LLM_KEY_SECRET" --project="$PROJECT"; then
    local key=""
    ask_secret key "API key for the endpoint (hidden)"
    [ -n "$key" ] || [ "$DRY_RUN" = 1 ] || die "an API key is required for a new secret"
    run_secret "${key:-dry-run}" gcloud secrets create "$PRIVATE_LLM_KEY_SECRET" --project="$PROJECT" --data-file=-
  fi
  [ -n "$PRIVATE_LLM_KEY_SECRET" ] && grant_secret "$PRIVATE_LLM_KEY_SECRET"
  say "  On the endpoint side, allow TCP from subnet $SUBNET to the server port (VPC firewall)."
  say "  In Paperclip, create an OpenCode agent with model private/<model-id>."
}

step_size() {
  header "Size and cost"
  say "  Paperclip runs one always-on instance: its schedulers and agent runs live in"
  say "  the process. Approximate us-central1 list prices, after the free tier:"
  say "    1 vCPU / 1 GiB  ~ \$47 per month"
  say "    1 vCPU / 2 GiB  ~ \$53 per month (default; the container disk is RAM)"
  say "    2 vCPU / 4 GiB  ~ \$110 per month (heavier agent work)"
  say "  Minimum instances 0 saves money but pauses agent timers while nobody uses it."
  ask CPU "vCPUs (1 or more)" "$CPU"
  ask MEMORY "Memory" "$MEMORY"
  ask MIN_INSTANCES "Minimum instances (1 keeps it always on)" "$MIN_INSTANCES"
  ask GEMINI_MODEL "Default Gemini model on Vertex AI" "$GEMINI_MODEL"
}

cmd_setup() {
  step_tools
  step_account
  step_project
  step_region
  step_apis
  step_registry
  step_build_identity
  step_runtime_identity
  step_network
  step_database
  step_bucket
  step_app_secrets
  step_google_signin
  step_private_llm
  step_size
  header "Save and deploy"
  save_config
  confirm "Build and deploy now? (the first build takes about 20-40 minutes)" || { say "  Run later: scripts/gcp-cloud-run.sh deploy"; return 0; }
  cmd_deploy
  header "First instance admin"
  cmd_bootstrap_admin
  print_summary
}

# ----------------------------------------------------------------- deploy ---

image_ref() {
  local tag=$IMAGE_TAG
  [ -n "$tag" ] || tag=$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)
  printf '%s-docker.pkg.dev/%s/%s/%s:%s' "$REGION" "$PROJECT" "$AR_REPO" "$SERVICE" "$tag"
}

# Build from `git archive HEAD`: the upload holds exactly the committed tree. No
# local keys or .env files can leave the machine, and no tracked file is dropped
# by gitignore-style upload filtering (gcloud applies .gitignore to tracked files).
build_image() {
  local image=$1 commit src="$WORK_DIR/source.tgz" build_id status
  if probe gcloud artifacts docker images describe "$image"; then
    say "  ✓ $image is already built; skipping the build"
    return 0
  fi
  commit=$(git -C "$REPO_ROOT" rev-parse HEAD)
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
    warn "uncommitted changes are NOT part of this build; it uses the committed tree ($commit)"
  fi
  print_cmd git -C "$REPO_ROOT" archive --format=tar.gz --output="$src" HEAD
  [ "$DRY_RUN" = 1 ] || git -C "$REPO_ROOT" archive --format=tar.gz --output="$src" HEAD

  if [ "$LOCAL_BUILD" = 1 ]; then
    print_cmd docker build --target production --build-arg "PAPERCLIP_BUILD_COMMIT=$commit" --tag "$image" - "<" "$src"
    if [ "$DRY_RUN" != 1 ]; then
      approve || die "stopped before a required step; run the script again when you are ready"
      docker build --target production --build-arg "PAPERCLIP_BUILD_COMMIT=$commit" --tag "$image" - < "$src"
      gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin "https://$REGION-docker.pkg.dev"
    fi
    run docker push "$image"
    return 0
  fi

  cat > "$WORK_DIR/cloudbuild.yaml" <<EOF
steps:
  - name: gcr.io/cloud-builders/docker
    env: ["DOCKER_BUILDKIT=1"]
    args: ["build", "--target", "production", "--build-arg", "PAPERCLIP_BUILD_COMMIT=$commit", "--tag", "$image", "."]
images: ["$image"]
options:
  machineType: E2_HIGHCPU_8
timeout: 5400s
EOF
  say "  Cloud Build takes about 20-40 minutes the first time."
  # --async, then poll: waiting on the build needs cloudbuild.builds.get only,
  # while a blocking submit also needs permission to read the build logs.
  print_cmd gcloud builds submit "$src" --project="$PROJECT" --config="$WORK_DIR/cloudbuild.yaml" --async
  [ "$DRY_RUN" = 1 ] && return 0
  approve || die "stopped before a required step; run the script again when you are ready"
  build_id=$(gcloud builds submit "$src" --project="$PROJECT" --config="$WORK_DIR/cloudbuild.yaml" --async --format='value(id)') ||
    { hint_for gcloud builds submit; die "could not start the build"; }
  say "  Build $build_id: https://console.cloud.google.com/cloud-build/builds/$build_id?project=$PROJECT"
  while :; do
    status=$(lookup gcloud builds describe "$build_id" --project="$PROJECT" --format='value(status)')
    case "$status" in
      SUCCESS) say "  ✓ build succeeded"; return 0 ;;
      FAILURE|INTERNAL_ERROR|TIMEOUT|CANCELLED|EXPIRED) die "build $build_id ended with $status; open the link above for its log" ;;
    esac
    sleep 30
  done
}

yaml_line() { printf "%s: '%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/''/g")"; }

opencode_providers_json() {
  local models="" model rest=$PRIVATE_LLM_MODELS
  while [ -n "$rest" ]; do
    model=${rest%%,*}
    models="$models${models:+,}\"$model\":{}"
    [ "$rest" = "$model" ] && break
    rest=${rest#*,}
  done
  printf '{"private":{"npm":"@ai-sdk/openai-compatible","name":"Private LLM","options":{"baseURL":"{env:PRIVATE_LLM_BASE_URL}","apiKey":"{env:PRIVATE_LLM_API_KEY}"},"models":{%s}}}' "$models"
}

cmd_deploy() {
  require_config
  apply_defaults
  resolve_project_number
  [ -n "$PROJECT_NUMBER" ] || [ "$DRY_RUN" = 1 ] || die "cannot read the project number of $PROJECT"
  local url image env_file secrets mount_root=/paperclip/instances/default
  url=$(public_url)
  image=$(image_ref)
  say "  Image: $image"
  build_image "$image"

  env_file="$WORK_DIR/env.yaml"
  {
    yaml_line PAPERCLIP_DEPLOYMENT_MODE authenticated
    yaml_line PAPERCLIP_DEPLOYMENT_EXPOSURE public
    yaml_line PAPERCLIP_PUBLIC_URL "$url"
    yaml_line TRUST_PROXY 1
    yaml_line PAPERCLIP_MIGRATION_AUTO_APPLY true
    yaml_line PAPERCLIP_DB_BACKUP_ENABLED false
    yaml_line PAPERCLIP_TRUSTED_MCP_RUNTIME_HOST cloud-run
    [ "$GOOGLE_AUTH" = yes ] && yaml_line PAPERCLIP_AUTH_DISABLE_SIGN_UP true
    [ -n "$ALLOWED_DOMAINS" ] && yaml_line PAPERCLIP_AUTH_ALLOWED_EMAIL_DOMAINS "$ALLOWED_DOMAINS"
    [ -n "$ALLOWED_EMAILS" ] && yaml_line PAPERCLIP_AUTH_ALLOWED_EMAILS "$ALLOWED_EMAILS"
    yaml_line GOOGLE_GENAI_USE_VERTEXAI true
    yaml_line GOOGLE_CLOUD_PROJECT "$PROJECT"
    yaml_line GOOGLE_CLOUD_LOCATION "$GEMINI_LOCATION"
    yaml_line ACPX_AUTH_VERTEX_AI 1
    yaml_line GEMINI_MODEL "$GEMINI_MODEL"
    yaml_line GEMINI_CLI_TRUST_WORKSPACE true
    if [ -n "$PRIVATE_LLM_BASE_URL" ]; then
      yaml_line PRIVATE_LLM_BASE_URL "$PRIVATE_LLM_BASE_URL"
      yaml_line PAPERCLIP_OPENCODE_PROVIDERS "$(opencode_providers_json)"
      [ -n "$PRIVATE_LLM_KEY_SECRET" ] || yaml_line PRIVATE_LLM_API_KEY none
    fi
    true
  } > "$env_file"

  secrets="DATABASE_URL=$(secret_name database-url):latest"
  secrets="$secrets,BETTER_AUTH_SECRET=$(secret_name better-auth-secret):latest"
  secrets="$secrets,PAPERCLIP_AGENT_JWT_SECRET=$(secret_name agent-jwt-secret):latest"
  secrets="$secrets,PAPERCLIP_SECRETS_MASTER_KEY=$(secret_name secrets-master-key):latest"
  secrets="$secrets,PAPERCLIP_DECISION_SIGNING_SECRET=$(secret_name decision-signing-secret):latest"
  secrets="$secrets,PAPERCLIP_TOOL_ACTION_SIGNING_SECRET=$(secret_name tool-action-signing-secret):latest"
  if [ "$GOOGLE_AUTH" = yes ]; then
    secrets="$secrets,PAPERCLIP_AUTH_GOOGLE_CLIENT_ID=$(secret_name google-oauth-client-id):latest"
    secrets="$secrets,PAPERCLIP_AUTH_GOOGLE_CLIENT_SECRET=$(secret_name google-oauth-client-secret):latest"
  fi
  if [ -n "$PRIVATE_LLM_BASE_URL" ] && [ -n "$PRIVATE_LLM_KEY_SECRET" ]; then
    secrets="$secrets,PRIVATE_LLM_API_KEY=$PRIVATE_LLM_KEY_SECRET:latest"
  fi

  say "  Environment for the service:"
  sed 's/^/    /' "$env_file"
  run gcloud run deploy "$SERVICE" --project="$PROJECT" --region="$REGION" --image="$image" \
    --service-account="$RUNTIME_SA" --execution-environment=gen2 --no-cpu-throttling --cpu-boost \
    --cpu="$CPU" --memory="$MEMORY" --min-instances="$MIN_INSTANCES" --max-instances=1 \
    --timeout=3600 --port=3100 --allow-unauthenticated \
    --network="$NETWORK" --subnet="$SUBNET" --vpc-egress=private-ranges-only \
    --startup-probe=httpGet.path=/api/health,httpGet.port=3100,periodSeconds=10,failureThreshold=60,timeoutSeconds=5 \
    --clear-volumes --clear-volume-mounts \
    --add-volume="name=companies,type=cloud-storage,bucket=$BUCKET,mount-options=only-dir=companies;uid=1000;gid=1000" \
    --add-volume-mount="volume=companies,mount-path=$mount_root/companies" \
    --add-volume="name=storage,type=cloud-storage,bucket=$BUCKET,mount-options=only-dir=storage;uid=1000;gid=1000" \
    --add-volume-mount="volume=storage,mount-path=$mount_root/data/storage" \
    --add-volume="name=skills,type=cloud-storage,bucket=$BUCKET,mount-options=only-dir=skills;uid=1000;gid=1000" \
    --add-volume-mount="volume=skills,mount-path=$mount_root/skills" \
    --env-vars-file="$env_file" \
    --set-secrets="$secrets"

  [ "$DRY_RUN" = 1 ] && return 0
  local health
  health=$(curl -fsS --max-time 20 "$url/api/health" || true)
  say "  Health: ${health:-no response yet}"
  case "$health" in
    *'"status":"ok"'*) say "  ✓ Paperclip is up at $url" ;;
    *) warn "the service did not report status ok yet; check the logs: gcloud run services logs read $SERVICE --region=$REGION --project=$PROJECT" ;;
  esac
}

# -------------------------------------------------------- bootstrap-admin ---

cmd_bootstrap_admin() {
  require_config
  apply_defaults
  resolve_project_number
  local job="$SERVICE-bootstrap-admin" url image line=""
  url=$(public_url)
  image=$(lookup gcloud run services describe "$SERVICE" --region="$REGION" --project="$PROJECT" --format='value(spec.template.spec.containers[0].image)')
  [ -n "$image" ] || image=$(image_ref)
  say "  A one-off Cloud Run job creates a single-use invite for the first instance admin"
  say "  (valid 72 hours). It runs inside the VPC, next to the database."
  run gcloud run jobs deploy "$job" --project="$PROJECT" --region="$REGION" --image="$image" \
    --service-account="$RUNTIME_SA" --network="$NETWORK" --subnet="$SUBNET" --vpc-egress=private-ranges-only \
    --set-secrets="DATABASE_URL=$(secret_name database-url):latest" --memory=1Gi \
    --args="node,--import,./server/node_modules/tsx/dist/loader.mjs,packages/db/scripts/create-auth-bootstrap-invite.ts,--base-url,$url" \
    --max-retries=0 --task-timeout=600 --execute-now --wait
  [ "$DRY_RUN" = 1 ] && return 0
  for _ in 1 2 3 4 5 6; do
    line=$(lookup gcloud run jobs logs read "$job" --region="$REGION" --project="$PROJECT" --limit=50 | grep -o 'https://[^[:space:]"]*/invite/pcp_bootstrap_[0-9a-f]*' | tail -n 1)
    [ -n "$line" ] && break
    sleep 5
  done
  if [ -z "$line" ]; then
    warn "could not read the invite from the job logs (reading them needs roles/logging.viewer)."
    warn "Open https://console.cloud.google.com/run/jobs/details/$REGION/$job/executions?project=$PROJECT and copy the /invite/ URL."
    return 0
  fi
  INVITE_URL=$line
  say "  First-admin invite (single use, 72 hours): $INVITE_URL"
  say "  It stops working once an instance admin exists."
}

print_summary() {
  local url
  url=$(public_url)
  say ""
  say "Done."
  say "  Paperclip:     $url"
  [ -n "$INVITE_URL" ] && say "  Admin invite:  $INVITE_URL"
  if [ "$GOOGLE_AUTH" = yes ]; then
    say "  Open the invite and choose 'Continue with Google' to become the instance admin."
  else
    say "  Open the invite and create an account to become the instance admin."
  fi
  say "  Then create a company and an agent:"
  say "    - Gemini CLI agent: model $GEMINI_MODEL (or auto), billed to Vertex AI in $PROJECT"
  [ -n "$PRIVATE_LLM_BASE_URL" ] && say "    - OpenCode agent: model private/<one of $PRIVATE_LLM_MODELS>"
  say "  Redeploy after changes:  scripts/gcp-cloud-run.sh deploy"
  say "  New admin invite:        scripts/gcp-cloud-run.sh bootstrap-admin"
  say "  Remove everything (review first):"
  say "    gcloud run services delete $SERVICE --region=$REGION --project=$PROJECT"
  say "    gcloud run jobs delete $SERVICE-bootstrap-admin --region=$REGION --project=$PROJECT"
  say "    gcloud storage rm -r gs://$BUCKET"
  say "    gcloud secrets list --project=$PROJECT --filter='name~$SERVICE-'   # then gcloud secrets delete NAME"
  [ "$DB_MODE" = new ] && say "    gcloud sql instances delete $SQL_INSTANCE --project=$PROJECT"
  [ "$DB_MODE" = existing ] && say "    gcloud sql databases delete $DB_NAME --instance=$SQL_INSTANCE --project=$PROJECT"
  return 0
}

# ------------------------------------------------------------------- main ---

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    setup|deploy|bootstrap-admin) COMMAND=$1 ;;
    --config) CONFIG_FILE=${2:?--config needs a file}; shift ;;
    --key-file) export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE; CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$(cd "$(dirname "${2:?--key-file needs a file}")" && pwd)/$(basename "$2")"; shift ;;
    --yes|-y) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --local-build) LOCAL_BUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done
[ -n "$COMMAND" ] || { usage >&2; exit 2; }

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
load_config
[ "$DRY_RUN" = 1 ] && say "DRY RUN: commands that change things are printed, not run."

case "$COMMAND" in
  setup) cmd_setup ;;
  deploy) cmd_deploy ;;
  bootstrap-admin) cmd_bootstrap_admin ;;
esac
