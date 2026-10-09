// Pointer light on tiles, fade-in on scroll, and the release line.
(function () {
  document.documentElement.classList.add("js");

  document.querySelectorAll(".tile").forEach(tile => {
    tile.addEventListener("pointermove", e => {
      const r = tile.getBoundingClientRect();
      tile.style.setProperty("--mx", `${e.clientX - r.left}px`);
      tile.style.setProperty("--my", `${e.clientY - r.top}px`);
    });
  });

  const reveal = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(entries => entries.forEach(e => {
      if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
    }), { rootMargin: "0px 0px -8% 0px" });
    reveal.forEach(el => io.observe(el));
  } else {
    reveal.forEach(el => el.classList.add("in"));
  }

  // Version, date and size of the current download, from the same file the app checks.
  const meta = document.getElementById("release-meta");
  if (meta) {
    fetch("/update.json", { cache: "no-store" }).then(r => r.ok ? r.json() : null).then(u => {
      if (!u) return;
      const mb = u.size ? ` · ${(u.size / 1048576).toFixed(1)} MB` : "";
      const date = u.published ? ` · ${new Date(u.published).toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" })}` : "";
      meta.textContent = `Version ${u.version}${date}${mb} · macOS ${u.minimumSystemVersion || "14"} or later · Apple silicon`;
    }).catch(() => {});
  }
})();
