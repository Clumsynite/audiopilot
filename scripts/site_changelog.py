"""Turns CHANGELOG.md into the site's changelog page, handling what the changelog uses: version and section
headings, "- " items with indented continuations, bold, code and links."""
import html
import re
import sys

src, out = sys.argv[1], sys.argv[2]


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    return re.sub(r"\[(.+?)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', text)


body, items, started = [], [], False


def flush():
    if items:
        body.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
        items.clear()


for line in open(src, encoding="utf-8").read().splitlines():
    if line.startswith("## "):
        flush()
        if started:
            body.append("</article>")
        started = True
        body.append(f'<article class="release glass reveal"><h2>{inline(line[3:].strip())}</h2>')
    elif not started:
        continue
    elif line.startswith("### "):
        flush()
        body.append(f"<h3>{inline(line[4:].strip())}</h3>")
    elif line.startswith("- "):
        items.append(line[2:].strip())
    elif line.startswith("  ") and items:
        items[-1] += " " + line.strip()
    elif line.strip():
        flush()
        body.append(f"<p>{inline(line.strip())}</p>")
flush()
if started:
    body.append("</article>")

page = f"""<!doctype html>
<html lang="en" data-glass="on">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>AudioPilot Changelog</title>
  <meta name="description" content="What changed in each version of AudioPilot for Mac.">
  <link rel="canonical" href="%SITE_URL%/changelog">
  <meta name="color-scheme" content="light dark">
  <link rel="icon" href="/icon.png" type="image/png">
  <link rel="stylesheet" href="/site.css">
</head>
<body>
  <header class="site">
    <div class="wrap">
      <a class="brand" href="/"><img src="/icon.png" alt="" width="34" height="34">AudioPilot</a>
      <nav class="site"><a href="/">Home</a><a href="/download">Download</a></nav>
    </div>
  </header>
  <main class="wrap" style="max-width: 780px">
    <h1 style="font-size: clamp(1.8rem, 4vw, 2.4rem); margin: 32px 0 8px; letter-spacing: -.02em">What's new</h1>
    {"".join(body)}
  </main>
  <script src="/site.js"></script>
</body>
</html>
"""
open(out, "w", encoding="utf-8").write(page)
