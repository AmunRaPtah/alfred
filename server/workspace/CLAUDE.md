# Alfred's map of the box

You start in /srv/alfred, your own scratch workspace. The owner's work lives
elsewhere on this machine; go to it with absolute paths. Look things up here
before asking the owner; ask only when the box can't answer.

## Where things are
- /root/application-career/README.md: every application (MSc, PhD, grants,
  fellowships, jobs) with its deadline and status. Read this first for any
  "what's due" question.
- /root/projects/<name>: one directory per project. The main ones:
  continuum (telepharmacy startup, live at continuum.zyco.org),
  neurocascade (receptor-to-behaviour brain simulation), priorbio (pharma
  company), grantfinder and jobfinder (autonomous search pipelines),
  pardalos (personal AI workspace), readout-forecast, psyche-twin,
  citrini-replication, alfred (you: server/, ios/, eval/).
- /root/zyco: Zyco holding company HQ; the ventures are its divisions.
- /root/bmf: BMF evidence graph (drug-discovery research framework).
- /root/datalake: research datasets; `dl` CLI (`dl q`, `dl card <name>`).
- /root/knowledge-base: the owner's Obsidian vault (use the vault skill).
- /root/docs: reference documents (e.g. docs/france-msc).
- /root/.claude/projects/-root/memory/*.md: detailed notes from the owner's
  other assistant, one fact per file, indexed in MEMORY.md there. Grep them
  for project history; treat them as background, check before relying on one.

## Tools on PATH
- `alfred ...`: your backend (reminders, notify, memory, email drafts).
- `bw-get <item>` / `bw-get --list`: credentials from the Bitwarden vault.
  Use a secret in a command; never print it in a reply.
- `gh-axi`: GitHub (the owner's account is AmunRaPtah).
- `doc <file|url>`: extract a PDF/DOCX/web page to /tmp and print an outline;
  `doc <file> -g PATTERN` greps it. Use this instead of reading whole documents.
- `cite-check FILE`: verifies the references in a document you wrote.
- Skills (load with the Skill tool): researcher, paper-lookup, knowledge-base,
  vault, pkpd-modeling, statistical-analysis, compute-scientist,
  molecular-science, chrome-devtools-axi, grantfinder, systematic-debugging,
  verification-before-completion, reality-checker, first-principles-thinking,
  content-quality-editor. Skill scripts written as `python skills/...` are
  relative to /root/projects/pardalos: run them as
  `cd /root/projects/pardalos && python skills/...`.

## Standing rules from the owner
- Email: the owner's address is ennyolutogun@gmail.com. Never use
  work@supercriticalbooks.com, anywhere.
- Never put the owner's PCN licence number on anything. Never mention Emcare
  in Continuum material.
- Never write a citation from memory: get it from paper-lookup or the
  knowledge base, then run `cite-check`.
- Don't stop, restart, or kill services you didn't start, and never kill
  processes by uid (uid 1000 is shared with Docker containers).
- Don't edit files inside a project's git repo without saying which files you
  changed; never commit or push unless asked.
