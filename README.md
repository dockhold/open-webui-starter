# Open WebUI on Dockhold

[Open WebUI](https://openwebui.com) is a chat interface for language models:
conversations, document upload and search, multiple users, an admin panel.
This template runs the maintained upstream image (version 0.11.3) on
[Dockhold](https://dockhold.eu) and adds a start script that wires it to
Dockhold's port, App storage, your admin account and your model provider.
Nothing else is changed. Deploy it as it is, or use it as the starting
point for your own copy.

[![Deploy to Dockhold](https://img.shields.io/badge/Deploy%20to-Dockhold-2563eb?style=for-the-badge)](https://app.dockhold.eu/new?repo=https://github.com/dockhold/open-webui-starter&name=open-webui)

## Deploy

1. Open the [Deploy link](https://app.dockhold.eu/new?repo=https://github.com/dockhold/open-webui-starter&name=open-webui)
   and sign in if asked.
2. Under **App size**, start at **2 GB**. This app needs a paid plan: its
   image is far larger than the free plan allows, and it runs a document
   search model in memory. Under **App storage**, turn it on and pick
   **10 GB**.
3. Under **Environment**, in the **Secrets** list, click **New secret**
   three times to store the three values, tick each one, and set its
   **Env var name** to the name Open WebUI expects. Give the entries names
   that belong to this app, for example `open-webui-admin-email`, because
   secrets are shared across your apps by name and two apps that share an
   entry would share a password.

   | Secret (your name) | Env var name | Value |
   | --- | --- | --- |
   | `open-webui-admin-email` | `WEBUI_ADMIN_EMAIL` | The email you will sign in with |
   | `open-webui-admin-password` | `WEBUI_ADMIN_PASSWORD` | 8 to 72 characters |
   | `open-webui-openai-key` | `OPENAI_API_KEY` | An API key from OpenAI, or from another OpenAI-compatible provider |

   To use a provider other than OpenAI, also add a plain variable
   `OPENAI_API_BASE_URL` with the provider's address, for example
   `https://openrouter.ai/api/v1` for OpenRouter. Any provider that speaks
   the OpenAI API works the same way.

4. Click **Deploy** and wait until the app shows as running. The first
   start takes a minute or two.
5. Open your app's URL, sign in with that email and password, pick a model
   at the top of the chat, and send a message.

If the app refuses to start, its page shows one line saying what is missing.
App storage is on the app's **Size** tab; secrets are attached on its
**Variables** tab and their values are edited under **Settings > Secrets**.
Fix it and click **Restart**.

## Two ways to use it

**Run Open WebUI.** Deploy this repository as it is. You get a hosted Open
WebUI with an admin panel, and you manage users, models and connections in
that panel. **Redeploy** rebuilds from this repository's `main`, so you pick
up starter updates when you choose to. `main` only moves for documented
upgrades; see [CHANGELOG.md](CHANGELOG.md) and "Backups, upgrading,
restoring" below.

**Develop your copy.** Click **Use this template** on GitHub to make your
own copy, connect that repository in Dockhold, and deploy it. From then on
every push redeploys the app. The repository's own checks
(`.github/workflows/check.yml`) run on every push to your copy, and the
weekly upstream check opens an issue when a new Open WebUI release is out.

Only the second path gives you push-to-deploy. The first path never reads
your GitHub account.

## What it runs

Chat goes to the provider you chose. Your prompts, and the relevant parts of
documents you upload, are sent to that provider; nothing about that is
different from using the provider directly. Document search runs inside the
app: a small embedding model (bundled with the image) indexes uploaded
files so the chat can quote from them, and that model is why the app needs
memory. There is no Ollama and no local chat model in this template. Beyond the
provider, the app's only routine outbound call is a release check against
GitHub, which fails quietly when unreachable; features you turn on later
(web search, sharing to the Open WebUI community site) make their own.

## Configuration ownership

Open WebUI reads the settings below from variables on its **first** start,
stores them in its database on App storage, and from then on the admin
panel owns them. Changing the variable in Dockhold afterwards does nothing
on an existing installation.

| Setting | Seeded from | Owned after the first start by |
| --- | --- | --- |
| Admin email and password | `WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_PASSWORD` | Open WebUI (Settings > Account). The variables are ignored once any account exists. |
| Provider key and address | `OPENAI_API_KEY`, `OPENAI_API_BASE_URL` | Open WebUI (Admin > Settings > Connections). **Rotating the key in Dockhold does not change the running app.** Rotate it in Connections. |
| Signup | closed | Open WebUI (Admin > Settings). Closed by the admin bootstrap; invite users from Admin > Users. |
| Ollama | off | Open WebUI (Admin > Settings > Connections) |
| Public URL | the app's Dockhold address | Open WebUI (Admin > Settings > General). After connecting a custom domain in Dockhold, set it there. |
| Session lifetime | 7 days | Open WebUI (Admin > Settings > General) |
| Session key | the file on App storage | the file (see "Session key") |

Dockhold sets `PORT` and `DATA_DIR` itself. Do not add them.

**Bootstrap is strict on purpose.** The start script refuses to start when
a secret is missing, when the admin email has no `@`, or when the password
is under 8 or over 72 characters, and it says so on the app page. Open
WebUI itself would log the failure and start without an admin, and the
first person to reach the URL could then register as the admin instead of
you. The start script checks the values first so that cannot happen.
Upstream sets no minimum password length; the 8-character floor is this
template's. 72 is upstream's limit.

## Sessions

A login lasts seven days. Changing a password does not sign out sessions
that already exist: Open WebUI would need a separate session store for
that, which this template does not run. If a device with an open session is
lost, change the password (Settings > Account); the old session ends within
seven days. A **Restart** or **Redeploy** does not sign anyone out.

## Session key

Open WebUI signs every login with one secret key. The start script keeps
it in `.dockhold/webui-secret-key` on App storage, creates it on the first
start, and never overwrites it. If the file is missing on an installation
that has run before, or is empty or damaged, the app refuses to start and
says so, rather than starting with a new key.

You can bind the key as a variable instead: a secret named
`WEBUI_SECRET_KEY` wins over the file. That is a recovery action, not a
setting. Binding it, changing it, or unbinding it signs every user out, and
any tokens stored for single sign-on under the other key become unreadable.
Use it to recover from a lost file: bind the value from your backup, or, if
you have no backup, bind any new value and accept that everyone signs in
again.

The key file is part of your backup set.

## Backups, upgrading, restoring

**Your backup set** is all of App storage, including
`.dockhold/webui-secret-key`, plus the three secrets. Admin > Settings >
Database > Export Database in the admin panel downloads a copy of the
database file (users, chats, settings); uploaded documents, the search
index and the key file live only on App storage, so the storage contents
are the complete set. App storage is not a backup of itself: take one
before you upgrade and on a schedule.

**Upgrading.** Take a backup first. On the Run path, click **Redeploy**
after this repository's `main` has moved; the [CHANGELOG](CHANGELOG.md)
entry says whether the upgrade changes your data. On the Develop path,
change the tag and the digest on the `FROM` line of the `Dockerfile`
together, set the same version in `entrypoint.sh`, and push. Read the
Open WebUI release notes: it moves quickly and releases sometimes migrate
the database on start.

If the app comes back on the previous version after an upgrade (Dockhold
rolls a deploy back when the new version does not become healthy), do not
keep using it: an old version on data a newer version already changed is
not safe. Restore the backup, then retry the upgrade.

**Restoring.** Deploy the version the backup was taken with, put the App
storage contents back (including `.dockhold/webui-secret-key`), and bind
the same three secrets. There is no import button for the database export;
it goes back as the `webui.db` file on App storage. On the Develop path
you pin that version in the `Dockerfile`. The Run path always builds the
current `main`, so to go back to an older version, switch to the Develop
path and pin it there.

## Limitations

* Needs a paid plan, because of the image size and the memory the document
  search model uses. Start at 2 GB and grow the app as usage grows.
* One running copy while App storage is attached. Open WebUI keeps its
  database in a file on that storage.
* No local chat models. Chat goes to an OpenAI-compatible provider you
  choose. Ollama is off.
* A password change ends existing sessions only when they expire, within
  seven days.
* Open WebUI's license restricts changes to its branding once an
  installation has more than fifty users in any thirty-day period. See
  "License". This template does not touch the branding.
* Realtime message streaming through Dockhold's edge is not yet covered by
  this template's checks.

## License

Open WebUI is distributed under the
[Open WebUI License](https://github.com/open-webui/open-webui/blob/v0.11.3/LICENSE),
which is the BSD 3-Clause license plus one clause: you may not alter or
remove the "Open WebUI" name, logo or other branding once your installation
has had more than fifty users in a rolling thirty-day period, unless you
have upstream's written permission. This template does not change the
branding and does not set `WEBUI_NAME`. Whether your use fits the license
is your responsibility as the operator.

This template's glue (Dockerfile, start script, workflows, README, tests)
is MIT, see [LICENSE](LICENSE).

## Full walkthrough

[Deploy Open WebUI](https://dockhold.eu/docs/recipes/deploy-open-webui): the
step-by-step recipe.
