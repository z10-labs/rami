"""Live meeting cards: what was just said, and where the brain already knows about it.

Model-free, so a card shows up a moment after the words are heard. Each final
transcript sentence can give:
  LINK      it names an open task (words shared with the task's title, slug, goal or next)
  ANSWER    a question, with the closest line the brain holds (work done, decision, next step)
  TASK      a commitment ("I'll…", "can you…", "we need to…"), to send to the Inbox
  DECISION  "we decided / agreed / let's go with…", to log on a linked task
Cards carry refs (task slugs) so the page can link straight to them.
"""
import re

MIN_WORD = 4
LINK_MIN = 2         # distinct shared words for a task link
ANSWER_MIN = 2       # distinct shared words for an answer
STOP = set("""about above after again against also among another anyone anything around because been before
being below between both cannot could does doing done down during each either else even ever every from
further going gonna have having here hers herself himself into itself just kind know like maybe more most
much must myself need never next okay once only other ours ourselves over really right same says should
since some something still such sure than that thats their theirs them themselves then there these they
thing things think this those though through today tomorrow under until very want wanna well were what
whats when where which while will with within without would yeah your yours yourself quick sync call
meeting talk said tell yesterday week weeks good great thanks thank please""".split())
QUESTION_RE = re.compile(r"^(what|when|where|who|whom|whose|why|how|which|is|are|was|were|do|does|did|"
                         r"can|could|should|would|will|have|has|had|any)\b", re.I)
COMMIT_RE = re.compile(r"\b(i'll|i will|i'm going to|i am going to|i can|let me|we'll|we will|we need to|"
                       r"we should|you need to|can you|could you|please|action item|follow up|remind me)\b", re.I)
DECIDE_RE = re.compile(r"\b(we decided|decided to|decision is|let's go with|we'll go with|we agreed|agreed to|"
                       r"we're going with|final answer is)\b", re.I)
SENTENCE_RE = re.compile(r"(?<=[.!?])\s+|,\s+(?=(?:and |but |so )?(?:we|i|you|let's)\b)", re.I)


def stem(w):
    for suf in ("ing", "ed", "es", "s"):
        if len(w) - len(suf) >= MIN_WORD and w.endswith(suf):
            return w[: -len(suf)]
    return w


def content_words(text):
    """Distinct content words, stemmed. Adjacent pairs are joined too, so speech
    ("web hook", "plug in") meets writing ("webhook", "plug-in", "design-features")."""
    raw = re.findall(r"[a-z0-9]+", (text or "").lower().replace("'", ""))
    out = {stem(w) for w in raw if len(w) >= MIN_WORD and w not in STOP}
    out.update(stem(a + b) for a, b in zip(raw, raw[1:]) if len(a + b) >= 6 and a not in STOP and b not in STOP)
    return out


def sentences(text):
    return [s.strip() for s in SENTENCE_RE.split(text or "") if s and len(s.strip()) > 3]


class Corpus(object):
    """What the brain knows, as (words, item) pairs, built once per meeting refresh."""

    def __init__(self, core):
        self.tasks = []    # (slug, title, words, next)
        self.items = []    # (words, {kind, slug, text, hint})
        for x in core.all_tasks():
            if (x.get("status") or "active") == "done":
                continue
            title = x.get("title") or x.slug
            nxt = x.text_of("Next")
            tw = content_words(" ".join([title, x.slug.replace("-", " "), x.text_of("Goal"), nxt]))
            self.tasks.append((x.slug, title, tw, nxt))
            if nxt:
                self.items.append((content_words(nxt), {"kind": "next", "slug": x.slug, "text": nxt, "hint": title}))
            for line in x.work_done():
                self.items.append((content_words(line), {"kind": "work", "slug": x.slug, "text": line, "hint": title}))
        for d in core.parse_decisions():
            text = "%s: %s" % (d.get("title", ""), d.get("decision", ""))
            self.items.append((content_words(text + " " + d.get("why", "")),
                               {"kind": "decision", "slug": d.get("task", ""), "text": text, "hint": d.get("date", "")}))

    def best_task(self, ws):
        best, score = None, 0
        for slug, title, tw, nxt in self.tasks:
            n = len(ws & tw)
            if n > score:
                best, score = (slug, title, nxt), n
        return best if score >= LINK_MIN else None

    def best_item(self, ws, near=()):
        """The closest line; lines of the tasks this talk is about win ties and close calls."""
        best, score = None, 0
        for iw, item in self.items:
            n = len(ws & iw)
            if n >= ANSWER_MIN and item["slug"] in near:
                n += 1
            if n > score:
                best, score = item, n
        return best if score >= ANSWER_MIN else None


def card(kind, line, sentence, title, body, refs, act, **extra):
    c = {"type": kind, "t": line.get("t", 0), "who": line.get("who", ""), "heard": sentence,
         "title": title, "body": body, "refs": [r for r in refs if r], "act": act, "state": "new"}
    c.update(extra)
    return c


def cards_for(corpus, line, linked):
    """Cards for one transcript line. `linked`: task slugs already linked or suggested."""
    out = []
    for s in sentences(line.get("text", "")):
        ws = content_words(s)
        task = corpus.best_task(ws)
        near = set(linked)
        if task:
            near.add(task[0])
        if task and task[0] not in linked:
            slug, title, nxt = task
            linked.add(slug)
            out.append(card("LINK", line, s, "Sounds like " + title, ("Next: " + nxt) if nxt else "Open task.",
                            [slug], "link", slug=slug))
        if s.endswith("?") or QUESTION_RE.match(s):
            item = corpus.best_item(ws, near)
            if item:
                label = {"work": "work done on", "decision": "decision on", "next": "next step of"}[item["kind"]]
                out.append(card("ANSWER", line, s, item["text"], "From the %s %s." % (label, item["hint"] or item["slug"]),
                                [item["slug"]], "ask", question=s))
        if DECIDE_RE.search(s):
            out.append(card("DECISION", line, s, s, "Log it on a linked task, or send it to the Inbox.", [], "decide", text=s))
        elif COMMIT_RE.search(s):
            owner = "you" if line.get("who") == "you" or re.match(r"(?i)^(i|i'll|let me)\b", s) else "them"
            out.append(card("TASK", line, s, s, "Said by %s. Send to the Inbox to sort later." % owner, [owner],
                            "inbox", text=s))
    return out
