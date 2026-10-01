# Local model apps: LM Studio and Ollama

ViddyDictate's **Local** text provider runs cleanup, prompt-prep, email, local web answers, custom
modes, and Note to Handoff's image reading on a model on your Mac. The model runs in a separate
app: LM Studio or Ollama. Neither is required. Raw dictation needs no text provider at all, and
Claude or Codex can run every text mode instead.

## LM Studio or Ollama

| | LM Studio | Ollama |
| --- | --- | --- |
| In ViddyDictate | The simple install, recommended | The advanced option, for people who already use Ollama |
| Staff pick for cleanup, prompt-prep, and web-search retrieval | `qwen3-coder-30b-a3b-instruct-mlx` | `qwen3-coder:30b` (about 18.6 GB on disk) |
| Staff pick for email and web-answer synthesis | `google/gemma-4-e4b` | `gemma4:e4b` (about 6.6 GB on disk) |
| Image reading (Note to Handoff) | The smallest installed vision model | The smallest installed model whose capabilities include vision; `gemma4:e4b` qualifies |
| How ViddyDictate talks to it | The `lms` command and LM Studio's local server | Ollama's native HTTP API, `http://127.0.0.1:11434` by default |
| How idle models unload | Each load carries ViddyDictate's idle window (`lms load --ttl`) | Every request carries it (`keep_alive`) |

Both apps get the same model families. Most people run one app. You can run both; the route
pickers then list both catalogs.

The 30B cleanup and search model does not fit on a 16 GB Mac in either app. On modest hardware,
use Claude or Codex for those routes.

## How ViddyDictate picks the app

**Each route pins an app and a model.** On the Hotkeys tab, and on a Sticky Skill card, a route's
Local dropdown lists every running app's models. With both apps running, each row is labelled
`LM Studio · <model>` or `Ollama · <model>`; with one app, the label is left off. Picking a row pins
that route to that app's copy of the model, so the same model name in both apps is never confused.
Out of the box, the Local routes point at LM Studio's staff picks. Ollama's copy of a staff-pick
model is marked "Staff pick" in the dropdown too, so to run a route on Ollama, pick it there.

**Fallback crosses apps, never to the cloud.** When a route's model is not installed or does not
fit in memory, ViddyDictate takes the largest model that fits in the same app. When that app is not
running, or nothing in it fits, it takes the largest model that fits in the other local app and
says so, for example "ran on LM Studio, Ollama wasn't running". A Local route never falls back to
Claude or Codex: if neither app can run it, the transform is off and your raw dictation still lands.

**Preferred local app.** Settings > Setup has a **Preferred local app** choice: Automatic, LM
Studio, or Ollama. Automatic follows what is installed, and picks LM Studio when both or neither
are. When Ollama.app is the preferred app, or a Local route is pinned to it, and it is installed but
not running, ViddyDictate opens it once in the background and waits briefly for it. LM Studio's
server is started when a model is loaded, as before.

## Installing

On a fresh install, the first-run setup window asks you to pick one app (LM Studio, Ollama, or Skip
for now) and offers that app's two staff-pick models. A model is ticked only when your Mac has the
memory to run it. Later, use **Settings > Setup > Local model apps**: each app has a row with its
state and an Install, Open, or Start button. **Run first-run setup again…** on the same tab brings
the window back, models included.

ViddyDictate downloads both apps from their official sites and checks them before anything is
moved into place. For Ollama:

- It starts at `https://ollama.com/download/Ollama.dmg` and follows redirects only over HTTPS and
  only to `ollama.com`, `github.com`, and `release-assets.githubusercontent.com`. Each hop is checked
  before it is requested.
- The download must be a disk image of the announced length. The app inside must have the bundle ID
  `com.electron.ollama`, pass `codesign --verify --deep --strict`, and be signed by Team ID
  `3MU9H2V9Y9`.
- An existing `/Applications/Ollama.app` is never overwritten.
- Model downloads show real byte progress. A pull is only treated as stalled after 15 minutes with no
  bytes moving at all; shorter pauses are normal.

### Ollama's macOS prompt

The first time Ollama.app starts, macOS asks for Touch ID or your password because "Ollama is
trying to install its command line interface tool". Ollama does not start its server until you
answer. Approve it. Only you can; ViddyDictate never answers it for you.

While it waits, the install row reads "waiting for you to approve Ollama's macOS prompt". After 10
minutes without an answer, the row stops with "Open Ollama and approve its macOS prompt, then
choose Retry."

### Ollama installed with Homebrew

An `ollama` command at `/opt/homebrew/bin` or `/usr/local/bin`, without Ollama.app, is detected
and used whenever it is running. ViddyDictate never starts it, because it is a service you run. The
Setup tab shows it as "Installed as a command-line tool (Homebrew), not running" until you start it
with `ollama serve` or `brew services start ollama` and choose Check again.

## Memory

Both apps sit under the same guard: the **Model memory budget** on the Setup tab. Before a load,
ViddyDictate estimates what the model will take. For Ollama the estimate is the model's size from
Ollama's model list plus its context cache, times 1.15. If the load would go over the budget,
ViddyDictate first unloads models it loaded itself, least recently used first. It never unloads a
model another app or you loaded. If the load still does not fit, it refuses rather than risk the
Mac, and the route steps down once to a smaller installed model that fits. When nothing fits, you
see "Not enough space in RAM. Adjust local model settings under the Setup tab."

Models unload on their own after **Unload idle models after** on the Setup tab (10 minutes by
default). **Unload all** works per app. The details, and what was measured, are in
[model-residency.md](model-residency.md).

## The context window on Ollama

ViddyDictate always tells Ollama how much context to load (`num_ctx`). There is no setting:

- 16,384 tokens for web-search retrieval, whose search results need the room;
- 8,192 tokens for everything else: cleanup, prompt-prep, custom modes, email, web-answer
  synthesis, and image reading.

A model that is already loaded with at least that much context is used as it is, not reloaded. This
applies only to ViddyDictate's own requests; Ollama's defaults for other apps are unchanged. Without
it, Ollama loads at its own default context, which was 262,144 tokens on the one 64 GB Mac where
this was measured. On that Mac `gemma4:e4b` added about 7.3 GB of wired memory at 8k context and
about 11.3 GB at its 131k maximum. ViddyDictate does not set LM Studio's context; its loads are
unchanged.

## Optional: Ollama's MLX speed-up

On a Mac with 32 GB or more, Ollama can run faster with its MLX option. It is an Ollama setting that
you turn on yourself, following Ollama's documentation. ViddyDictate never sets it.
