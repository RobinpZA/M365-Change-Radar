# M365 Change Radar

One filterable feed of Microsoft ecosystem changes — M365 Roadmap, Azure Updates, Tech Community blogs, Microsoft Dev Blogs, the Microsoft Graph API and GitHub changelogs, and PowerShell SDK releases — rebuilt daily by GitHub Actions and served as a static site from GitHub Pages.

**Live site:** https://robinpza.github.io/M365-Change-Radar/

## Why it beats a feed reader

The build merges each run against the previous output, so every item carries `firstSeen` and a `statusHistory`. The site can therefore answer the two questions an RSS reader cannot:

- what is **new since you last looked** (per-browser, via `localStorage`)
- what **moved status** this week (`In development → Rolling out → Launched`)

It also flags **retirements and breaking changes** across every source, which is usually the only category that needs a diary entry.

## No tenant data, by design

Every source is a public feed. Nothing in this repo authenticates, holds a secret, or touches Microsoft Graph with a tenant token.

That is deliberate: **a GitHub Pages site is publicly readable even when published from a private repository** — private Pages requires GitHub Enterprise Cloud. Message Center (`/admin/serviceAnnouncement/messages`) is therefore out of scope, because committing it would publish tenant data at a public URL. If you want Message Center alongside this, the safe pattern is a browser-side MSAL sign-in that calls Graph directly and commits nothing.

## Layout

```
config/sources.json              feed definitions
scripts/Get-FeedItems.ps1        RSS/Atom -> normalised objects
scripts/Update-Feeds.ps1         fetch, merge with previous run, write JSON
scripts/Test-Sources.ps1         health check for every feed
docs/                            GitHub Pages source (Settings -> Pages -> main /docs)
docs/data/updates.json           merged, deduped, pruned feed
docs/data/meta.json              last run, facets, per-source health
```

## Usage

```powershell
pwsh ./scripts/Test-Sources.ps1            # is every feed still alive?
pwsh ./scripts/Update-Feeds.ps1            # rebuild docs/data/*.json
pwsh ./scripts/Update-Feeds.ps1 -Id roadmap  # just one source, while iterating
python -m http.server 8080 --directory docs  # preview at localhost:8080
```

## Adding a Tech Community blog

Tech Community's Aurora migration in late 2024 broke every legacy RSS URL. The working form is:

```
https://techcommunity.microsoft.com/t5/s/gxcuf89792/rss/board?board.id=<slug>
```

`<slug>` is the path segment after `/blog/` in any post URL on that blog — for example `https://techcommunity.microsoft.com/blog/microsoft-entra-blog/...` gives `microsoft-entra-blog`.

**Slugs are not guessable.** A dead slug returns HTTP 200 with a stub feed whose channel description reads *"The resource you are trying to access has been deleted or never existed"*; `Get-FeedItems` treats that as a failure. Always confirm a new slug with `Test-Sources.ps1` before committing it.

## Failure behaviour

A source that fails is never fatal. Its previously collected items are kept, the failure is recorded in `meta.json` and shown in the site header, and the workflow raises a GitHub Actions warning annotation. Only an all-sources failure aborts the run, leaving the existing data untouched.

## Operational notes

- `meta.json` records `lastRun` on every run, so the workflow commits daily. That matters: GitHub disables scheduled workflows on public repos after 60 days with no repository activity.
- Commits pushed with `GITHUB_TOKEN` do not trigger workflows, so there is no run loop.
- Retention is 18 months (`retentionMonths` in `config/sources.json`), which keeps `updates.json` around 2 MB.

## License

MIT · Robin Pieterse · Turrito Networks
