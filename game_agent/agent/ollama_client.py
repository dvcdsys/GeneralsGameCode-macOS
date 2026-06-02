"""OllamaChat — minimal stdlib wrapper over an Ollama server's /api/chat (native tool-calling).

No pip dependency (urllib, like GameClient). Defaults target the powerful LAN box the user set up
(192.168.1.168:11434, model qwen3:8b — tools + thinking). Override via args or env:

    GEN_OLLAMA_HOST=192.168.1.168:11434   GEN_OLLAMA_MODEL=qwen3:8b

`chat(messages, tools)` returns the assistant message dict ({"content", "tool_calls"}), or None on
failure. Thinking is disabled by default (`think=False`) to keep planner latency down; flip it on for
harder reasoning at the cost of slower ticks.
"""

import json
import os
import urllib.error
import urllib.request


class OllamaChat:
    def __init__(self, host=None, model=None, timeout=180.0, temperature=0.3, think=False):
        host = host or os.environ.get("GEN_OLLAMA_HOST", "192.168.1.168:11434")
        if not host.startswith("http"):
            host = "http://" + host
        self.base = host.rstrip("/")
        # gemma4:26b — smaller/faster than 9b, snappier strategic cadence; tools + thinking
        self.model = model or os.environ.get("GEN_OLLAMA_MODEL", "gemma4:26b")
        self.timeout = timeout
        self.temperature = temperature
        self.think = think

    # Ollama's Go-side tool-call template parser intermittently fails to parse a given sampling of
    # the model's XML-ish tool markup ("XML syntax error ... <function> closed by </parameter>").
    # It is a sampling artifact, not a real failure — re-sampling at a perturbed temperature clears
    # it, so we retry the whole call a few times instead of wasting the planning round.
    _RETRYABLE = ("xml syntax error", "unexpected eof", "invalid character", "tool call")

    def chat(self, messages, tools=None, options=None, _retries=3):
        last = None
        for attempt in range(_retries):
            opts = dict(options or {"temperature": self.temperature})
            if attempt:  # perturb sampling so the parser sees different markup next try
                opts["temperature"] = round(min(1.0, opts.get("temperature", 0.3) + 0.2 * attempt), 2)
                opts["seed"] = 1000 + attempt
            last = self._chat_once(messages, tools, opts)
            err = (last or {}).get("error", "") if isinstance(last, dict) else ""
            if last is not None and not (err and any(s in err.lower() for s in self._RETRYABLE)):
                return last
        return last

    def _chat_once(self, messages, tools, options):
        body = {
            "model": self.model,
            "messages": messages,
            "stream": False,
            "think": self.think,
            "options": options,
        }
        if tools:
            body["tools"] = tools
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(self.base + "/api/chat", data=data, method="POST")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
                return payload.get("message")
        except urllib.error.HTTPError as e:
            try:
                return {"error": e.read().decode("utf-8"), "code": e.code}
            except Exception:  # noqa: BLE001
                return {"error": "http {}".format(e.code)}
        except Exception as e:  # noqa: BLE001
            return {"error": str(e)}

    def ping(self):
        """True if the server answers /api/tags and has our model."""
        try:
            with urllib.request.urlopen(self.base + "/api/tags", timeout=8.0) as resp:
                tags = json.loads(resp.read().decode("utf-8"))
            names = {m.get("name") for m in tags.get("models", [])}
            return (self.model in names) or any(n.split(":")[0] == self.model.split(":")[0]
                                                for n in names)
        except Exception:  # noqa: BLE001
            return False
