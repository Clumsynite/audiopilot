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
        body.append(f'<article><h2>{inline(line[3:].strip())}</h2>')
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
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>AudioPilot Changelog</title>
  <meta name="description" content="What changed in each version of AudioPilot for Mac.">
  <link rel="canonical" href="%SITE_URL%/changelog">
  <meta name="color-scheme" content="light dark">
  <link rel="icon" href="/icon.png" type="image/png">
  <style>
    :root {{ --bg: #f4f6f8; --surface: #ffffffcc; --surface-2: #e9eef2; --text: #14181c; --muted: #5b6670; --accent: #0f8f8a; --border: #d8dfe5; }}
    @media (prefers-color-scheme: dark) {{
      :root {{ --bg: #0d1114; --surface: #171d22cc; --surface-2: #1f272d; --text: #e9eef2; --muted: #9aa6b0; --accent: #3cc8bf; --border: #2a343c; }}
    }}
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; background: var(--bg); color: var(--text); font: 16px/1.6 -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }}
    .wrap {{ max-width: 760px; margin: 0 auto; padding: 0 16px 48px; }}
    header {{ display: flex; justify-content: space-between; align-items: center; padding: 18px 0 8px; }}
    header a {{ color: var(--text); text-decoration: none; font-weight: 650; display: flex; gap: 10px; align-items: center; }}
    header img {{ width: 28px; height: 28px; }}
    a {{ color: var(--accent); }}
    h1 {{ font-size: clamp(1.6rem, 4vw, 2.2rem); margin: 24px 0 8px; }}
    article {{ background: var(--surface); border: 1px solid var(--border); border-radius: 16px; padding: 18px 22px; margin: 16px 0; }}
    article h2 {{ margin: 0 0 6px; font-size: 1.25rem; }}
    h3 {{ margin: 14px 0 4px; font-size: .95rem; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }}
    ul {{ margin: 0; padding-left: 1.2em; }}
    li {{ margin: 4px 0; }}
    code {{ background: var(--surface-2); padding: 1px 5px; border-radius: 5px; font-size: .9em; overflow-wrap: anywhere; }}
  </style>
</head>
<body>
  <div class="wrap">
    <header><a href="/"><img src="/icon.png" alt="" width="28" height="28">AudioPilot</a><a href="/download" style="color:var(--accent)">Download</a></header>
    <h1>What's new</h1>
    {"".join(body)}
  </div>
</body>
</html>
"""
open(out, "w", encoding="utf-8").write(page)
