# Web search

Small local models do not know local facts reliably: asked about a small town, they
often invent plausible details such as the wrong district or roads that do not exist.
With web search the model reads real search results instead of guessing.

`docker-compose.yml` ships [SearXNG](https://docs.searxng.org/), a self-hosted
meta search engine: no API key, no tracking, only reachable inside the compose network.

## Setup

```bash
git pull
docker compose up -d          # starts the new searxng container
```

**Fresh Open WebUI install:** web search is preconfigured through the environment
variables in `docker-compose.yml`.

**Existing install:** Open WebUI keeps its admin settings in its database, so the
environment variables are ignored. Set it once by hand:

1. *Admin → Settings → Web Search*
2. **Web search**: on
3. **Engine**: `searxng`
4. **SearXNG query URL**: `http://searxng:8080/search?q=<query>`
5. Save

Check that SearXNG answers:

```bash
docker compose exec open-webui curl -s "http://searxng:8080/search?q=K%C3%B6ln&format=json" | head -c 300
```

## Search per chat

Click **+ → Web search** in the chat input. Open WebUI searches first and gives the
model the results with sources.

## Let the model search by itself

Models with tool support (`gemma4`, `gpt-oss`, `qwen3.8`: tag *tools* in the Ollama
library) can decide on their own when to search, and search several times:

1. *Admin → Settings → Models → model → Advanced Params*: **Function Calling** `Native`
2. Same model: **Default Features** → tick **Web search**. Without it the search tool is
   not offered to the model at all, and it answers from memory.
3. Same model, **System Prompt**, for example:

   > Du hast Zugriff auf eine Websuche. Nutze sie IMMER, bevor du Fragen zu Orten,
   > Personen, Firmen, Zahlen, Daten oder aktuellen Ereignissen beantwortest. Verlasse
   > dich bei solchen Fakten nie nur auf dein Gedächtnis. Nenne deine Quellen.

4. Save and start a **new** chat.

The answer then shows *"View result from search_web"* above the text. Verified with
`gemma4:26b-qat` on an Arc 140T: asked about a small village, it searched on its own and
answered correctly; without search it had placed the village in the wrong district.

Alternative: Function Calling `Standard` + Default Feature *Web search* makes Open WebUI
search before **every** answer, whatever the model decides.

## Tips

- Set the language in `searxng/settings.yml` (`default_lang`); default is `de`.
- More results cost more context: `WEB_SEARCH_RESULT_COUNT=5` is a good trade-off.
- Without a container: Open WebUI can also use `duckduckgo` directly (no key), but it is
  rate-limited quickly.
