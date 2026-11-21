# oci-a1-retry

Keeps trying to create an **Always Free Oracle Cloud A1 VM** (Ampere ARM, 2 OCPU / 12 GB RAM, Ubuntu 24.04, 50 GB boot volume) in the **Mumbai** region (`ap-mumbai-1`) until capacity frees up.

Free A1 capacity is usually sold out, and launching fails with `Out of host capacity`. This repo retries automatically with GitHub Actions, so you don't have to keep clicking "Create".

## How it works

- `oci-a1-retry.sh` makes one launch attempt per run, using the OCI CLI. It:
  - stops if an instance already exists, so it never goes over the Always Free limit
  - finds the availability domain and the latest Ubuntu 24.04 ARM image (not the Minimal one)
  - reuses a public subnet, or creates a free VCN, internet gateway and public subnet
  - launches the VM with the SSH public key embedded in the script
- `.github/workflows/oci-a1-retry.yml` runs the script about every 15 minutes (`7,22,37,52 * * * *`). You can also start it by hand.
- **On success**, the workflow opens an issue titled **"Oracle A1 VM created"** (GitHub notifies you) and **disables itself**.

GitHub may delay or skip scheduled runs when it's busy, so the gap between runs is often longer than 15 minutes.

## Setup

1. In the OCI console, create an **API key** for your user (Profile → API keys → Add API key) and download the private key.
2. In this repo, add these secrets under **Settings → Secrets and variables → Actions**:

   | Secret | Value |
   |---|---|
   | `OCI_USER_OCID` | Your user OCID (`ocid1.user...`) |
   | `OCI_TENANCY_OCID` | Your tenancy OCID (`ocid1.tenancy...`) |
   | `OCI_FINGERPRINT` | The API key fingerprint |
   | `OCI_PRIVATE_KEY` | The full contents of the API private key `.pem` file |

3. Go to **Actions → oci-a1-retry → Run workflow** to test it once. A normal result for now is
   `Out of capacity. Next scheduled run will try again.`
4. Leave it running. The schedule takes over from there.

To use your own SSH key, replace the `ssh-rsa ...` line in `oci-a1-retry.sh` with your **public** key.

## Running it yourself (Cloud Shell / any machine)

In OCI Cloud Shell, `OCI_TENANCY` is already set. This retries every 60 seconds until it succeeds:

```bash
bash oci-a1-retry.sh
```

On another machine with a configured OCI CLI and `jq`:

```bash
OCI_TENANCY=ocid1.tenancy.oc1..xxxx bash oci-a1-retry.sh
```

Optional environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `MAX_ATTEMPTS` | unset (forever) | Stop after this many capacity failures |
| `MAX_MINUTES` | `0` (no limit) | Stop after this many minutes |
| `QUIET` | `0` | `1` hides IDs and the IP in the output (used in CI because the logs are public) |

## After the VM is created

1. Find the public IP in the Oracle console: **Compute → Instances → surajvps**.
2. Connect with `ssh -i <your-private-key> ubuntu@<public-ip>`.
3. **Delete the OCI API key** used by this repo (Profile → API keys), and remove the repo secrets. The workflow will no longer need them.

## Notes

- **Cost:** everything the script creates fits inside Oracle's Always Free tier. The script never creates a second VM.
- **Actions minutes:** this repo is public, so GitHub Actions minutes are free and unlimited.
- **Security:** the OCI credentials are stored only as GitHub encrypted secrets. They aren't exposed in logs, and workflows from forks can't read them.
- GitHub turns off scheduled workflows in repos with no activity for 60 days. If that happens, re-enable the workflow from the Actions tab.
