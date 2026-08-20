# build-adr-index

Builds `docs/adr/README.md` in dependency order from ADR frontmatter.

Run it after you add, retitle, or supersede an ADR:

```
pwsh -NoProfile -File skills/build-adr-index/Build-AdrIndex.ps1
```

It overwrites the index every run. It stops and names the records when `depends-on`
forms a cycle or points at a missing ADR.
