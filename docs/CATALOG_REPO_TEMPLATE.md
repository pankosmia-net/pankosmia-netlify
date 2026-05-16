# Catalog repo setup template

Concrete steps to create and run `pankosmia-org/catalog`, the central
repo that registers languages with a Pankosmia hosted deployment.

This is for the **catalog admin**. The catalog admin is the trust
root: by merging a PR that adds a language to the catalog, they're
saying "this language repo is part of the deployment and the people
behind it have been vetted."

---

## 1. Create the repo

1. Pick an org (`pankosmia-org` is the assumed name in this
   document; substitute your actual org).
2. Create a new public repo named `catalog`.
3. Initialize with a `README.md` describing what the repo is for
   (sample text in §6 below).
4. Add an empty `languages.yaml` at the root with just:
   ```yaml
   schema_version: 1
   languages: []
   ```

---

## 2. Branch protection on `main`

Settings → Branches → Add rule for `main`:

- ✅ Require a pull request before merging
- ✅ Require approvals (set to `1` minimum, `2` for stricter)
- ✅ Dismiss stale pull request approvals when new commits are pushed
- ✅ Require review from Code Owners (if you set up CODEOWNERS in §4)
- ✅ Require status checks to pass before merging
  - Required check: `validate-catalog`
- ✅ Require conversation resolution before merging
- ✅ Require linear history
- ✅ Do not allow bypassing the above settings (apply to admins too)
- ✅ Restrict who can push to matching branches (the catalog admin
      group only — but PRs from anyone with read access can still
      be merged through the normal flow)

---

## 3. The validate-catalog GitHub Action

`.github/workflows/validate-catalog.yml`:

```yaml
name: validate-catalog
on:
  pull_request:
    paths:
      - languages.yaml
      - .github/workflows/validate-catalog.yml

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: Install validators
        run: pip install pyyaml jsonschema requests
      - name: Run validate-catalog
        run: python .github/scripts/validate_catalog.py languages.yaml
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

`.github/scripts/validate_catalog.py`:

```python
#!/usr/bin/env python3
"""Validate languages.yaml against the catalog schema.

Checks:
  - YAML parses.
  - schema_version is recognized.
  - Each language entry has required fields.
  - `code` is a valid BCP 47 subset (alpha, digits, hyphens; max 16).
  - `repo` is `owner/name` and unique within the file.
  - GitHub API confirms each `repo` exists and is accessible.

Optional (commented out by default):
  - `git ls-remote` succeeds for each repo.
  - `metadata.json` exists at the root of each repo's main branch.
"""

import os
import re
import sys
import yaml
import requests

REQUIRED_FIELDS = {"code", "display_name", "repo", "added_at", "added_by"}
OPTIONAL_FIELDS = {"script", "direction", "notes"}
ALL_FIELDS = REQUIRED_FIELDS | OPTIONAL_FIELDS

CODE_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,14}[A-Za-z0-9])?$")
REPO_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
SUPPORTED_SCHEMA = {1}
DIRECTIONS = {"ltr", "rtl"}


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def main(path):
    with open(path) as f:
        try:
            doc = yaml.safe_load(f)
        except yaml.YAMLError as e:
            fail(f"YAML parse: {e}")

    if not isinstance(doc, dict):
        fail("top level is not a mapping")

    schema = doc.get("schema_version")
    if schema not in SUPPORTED_SCHEMA:
        fail(f"unknown schema_version: {schema}")

    languages = doc.get("languages")
    if not isinstance(languages, list):
        fail("`languages` must be a list")

    seen_codes = set()
    seen_repos = set()

    for i, entry in enumerate(languages):
        if not isinstance(entry, dict):
            fail(f"languages[{i}] is not a mapping")

        missing = REQUIRED_FIELDS - entry.keys()
        if missing:
            fail(f"languages[{i}] missing fields: {missing}")
        unknown = set(entry.keys()) - ALL_FIELDS
        if unknown:
            fail(f"languages[{i}] unknown fields: {unknown}")

        code = entry["code"]
        if not isinstance(code, str) or not CODE_RE.match(code):
            fail(f"languages[{i}] invalid code: {code!r}")
        if code in seen_codes:
            fail(f"duplicate code: {code}")
        seen_codes.add(code)

        repo = entry["repo"]
        if not isinstance(repo, str) or not REPO_RE.match(repo):
            fail(f"languages[{i}] invalid repo: {repo!r}")
        if repo in seen_repos:
            fail(f"duplicate repo: {repo}")
        seen_repos.add(repo)

        direction = entry.get("direction")
        if direction is not None and direction not in DIRECTIONS:
            fail(f"languages[{i}] invalid direction: {direction!r}")

        # Confirm repo exists and is accessible.
        token = os.environ.get("GH_TOKEN")
        headers = {"Authorization": f"token {token}"} if token else {}
        r = requests.get(f"https://api.github.com/repos/{repo}", headers=headers)
        if r.status_code == 404:
            fail(f"repo not found on GitHub: {repo}")
        if r.status_code != 200:
            fail(f"repo lookup failed for {repo}: {r.status_code} {r.text}")

    print(f"OK: {len(languages)} entries validated")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "languages.yaml")
```

---

## 4. CODEOWNERS

`.github/CODEOWNERS`:

```
# The catalog admin group must approve any change to languages.yaml.
languages.yaml @your-org/catalog-admins
```

Create the `catalog-admins` team in your GitHub org and put the
trusted humans in it.

---

## 5. PR template

`.github/PULL_REQUEST_TEMPLATE/register_language.md`:

```markdown
## New language registration

Thank you for proposing to register a new language! Please fill in
the questions below so the catalog admin can vet the request.

### About the repo

- Language code (BCP 47, e.g. `fr`, `zh-Hans`, `gn`):
- GitHub repo (`owner/name`):
- Repo URL:
- Repo is public: yes / no (private requires paid GitHub Teams)

### About you

- Your name:
- Organization or community you represent:
- Languages you work with:
- How can the catalog admin verify your identity? (e.g. project
  page, public statement linking your GitHub username, prior
  collaboration history)

### About the content

- Where does the source content come from?
- Is the content licensed for redistribution? (link the license)
- Sample file for review (link to a file in the proposed repo):
- Approximate size (number of ingredients, MB of text):

### Audio (if applicable)

- Will this repo include audio? (yes / no)
- If yes: where is the audio hosted? (Pankosmia uses object
  storage for audio; the repo only holds text + metadata)

### Acknowledgements

- [ ] I understand registration is irrevocable in the sense that
      git history of the catalog repo will retain it; removal is
      possible but past commits remain visible.
- [ ] I agree to ensure my repo's content licensing is honored by
      the Pankosmia hosted deployment.
- [ ] I understand the language admin (myself or a delegate) is
      responsible for reviewing PRs to my repo from translators.
```

---

## 6. README.md content

```markdown
# Pankosmia language catalog

This repo is the canonical list of languages registered with the
Pankosmia hosted deployment. It contains exactly one file:

- `languages.yaml` — the registry.

## How to register a new language

1. Create a public GitHub repo for your language. The repo must
   contain a `metadata.json` at the root and an `ingredients/`
   directory at minimum. (See `docs/DATA_MODEL.md` for the full
   structure.)
2. Open a pull request to this repo adding an entry to
   `languages.yaml`. Use the registration PR template.
3. The catalog admin will review your PR and may ask follow-up
   questions about identity, licensing, and content.
4. Once approved and merged, the Pankosmia hosted server will pick
   up your language within ~15 minutes (or immediately if webhooks
   are healthy).

## Trust model

The catalog admin's role is to vet identity and content
appropriateness, not to police the content of every commit on every
language repo. Per-repo admin authority lies with that repo's
GitHub maintainers.

## How to remove a language

Open a PR removing the entry. Provide a reason. After merge, the
hosted server stops serving that language within ~15 minutes. The
language's GitHub repo is unaffected; only the registration is
removed.
```

---

## 7. Webhook setup (one-time, after server is running)

For each language repo AND for the catalog repo, a GitHub webhook
points at the Pankosmia server:

- Repo settings → Webhooks → Add webhook
- Payload URL:
  - For catalog repo: `https://<your-server>/webhook/catalog`
  - For language repos: `https://<your-server>/webhook/language/<code>`
- Content type: `application/json`
- Secret: paste the `GITHUB_WEBHOOK_SECRET` value the server uses.
- SSL verification: enabled.
- Events:
  - Catalog repo: send `push` events only.
  - Language repos: send `push` and `pull_request` events.

The catalog admin sets up the catalog webhook once. Each language
admin sets up their own repo's webhook (a one-line task in the
language repo's settings). Without webhooks, propagation falls
back to the 15-minute periodic fetch — usable but slower.

---

## 8. The vetting checklist (for the catalog admin)

When a registration PR arrives:

- [ ] Read the PR template responses.
- [ ] Click through to the proposed GitHub repo. Confirm:
  - It is public (or paid org if private).
  - It has a `metadata.json` at the root.
  - It has an `ingredients/` directory.
  - The license is reasonable for the use case.
- [ ] Verify the requester's identity. Look at:
  - Their GitHub profile, age of account, contribution history.
  - Cross-references they provided.
  - Public statements (org page, prior projects).
- [ ] Confirm the language code matches the content.
- [ ] Run the validate-catalog action manually if needed (it runs
      automatically on PR sync).
- [ ] If everything checks out, approve and merge.
- [ ] After merge, optionally post a welcome message in the
      language repo via a follow-up issue.

A "no" decision is closed with a respectful comment explaining
what's missing or what concerns remain. The PR author can update
and resubmit.

---

## 9. What the catalog admin does NOT do

- Police edits inside language repos. That's the language admin's
  job.
- Manage user accounts. Pankosmia uses GitHub OAuth; users sign up
  via GitHub, no central account management.
- Configure the Pankosmia server. Server ops is a separate role
  (devops).
- Adjudicate translation disputes. Linguistic / theological
  disputes belong to the language community, not the catalog.

---

## 10. Operational notes

- Keep an emergency "remove all entries" PR ready as a kill switch
  if a deployment-wide issue arises (e.g. the server is misbehaving
  and you need to stop serving any content fast). Cleaner than
  shutting the server down.
- Periodically (quarterly?) re-run the validate-catalog action on
  the current `main` to detect repos that have been deleted or
  privatized after registration.
- The catalog-admin group should be at least 2 humans for
  bus-factor. Single-admin setups are fragile.

---

See also:

- `docs/ARCHITECTURE.md` — the architecture this catalog plugs into.
- `docs/CLIENT_INTEGRATION.md` — what the client UI does on top
  of all this.
