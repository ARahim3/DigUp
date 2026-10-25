/* DigUp's website. No libraries, no analytics, nothing sent anywhere: the theme switch, the visitor's system, tabs,
   copy buttons, the panel on the home page, the "one space" map, filters, and the site search (⌘K), which looks
   like DigUp's own panel and searches an index the build writes (search.json). */
(function () {
  "use strict";
  var root = document.documentElement;
  var CFG = window.DIGUP || { base: "/", repo: "ARahim3/DigUp", search: "/search.json" };
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var os = root.getAttribute("data-os") || "";
  var $ = function (sel, el) { return (el || document).querySelector(sel); };
  var $$ = function (sel, el) { return Array.prototype.slice.call((el || document).querySelectorAll(sel)); };

  function store(key, value) {
    try {
      if (value === undefined) return window.localStorage.getItem(key);
      window.localStorage.setItem(key, value);
    } catch (e) { return null; }
    return null;
  }
  function escapeHtml(s) { return String(s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }

  /* ---------------------------------------------------------------- theme */
  $$("[data-theme-toggle]").forEach(function (button) {
    button.addEventListener("click", function () {
      var dark = root.getAttribute("data-theme") === "dark" ||
        (!root.getAttribute("data-theme") && window.matchMedia("(prefers-color-scheme: dark)").matches);
      var next = dark ? "light" : "dark";
      root.setAttribute("data-theme", next);
      store("digup-theme", next);
    });
  });

  /* ---------------------------------------------------------------- the visitor's download */
  // The hero shows all three systems; the visitor's own goes first, as the direct download. On a phone or an
  // unknown system the Mac stays first and points at the download page.
  $$("[data-download-row]").forEach(function (row) {
    var primary = os || "mac";
    var buttons = $$("[data-system]", row);
    buttons.forEach(function (b) {
      var mine = b.getAttribute("data-system") === primary;
      var label = $("[data-label]", b);
      b.classList.toggle("btn-primary", mine);
      b.classList.toggle("btn-quiet", !mine);
      if (label) label.textContent = label.getAttribute(mine ? "data-long" : "data-short");
      var direct = b.getAttribute("data-direct");
      b.href = mine && os && direct ? direct : b.getAttribute("data-page");
      if (mine) row.insertBefore(b, row.firstChild);
    });
  });
  var downloads = window.DIGUP_DOWNLOADS;
  if (downloads) {
    $$("[data-download-primary]").forEach(function (link) {
      var label = $("[data-download-label]", link);
      var choice = downloads[os];
      if (choice && choice.url) {
        link.href = choice.url;
        if (label) label.textContent = choice.label;
      } else if (!os) {
        link.href = CFG.base + "download/";
        if (label) label.textContent = "Download";
      }
    });
  }
  if (os) {
    $$("[data-platform-card]").forEach(function (card) {
      card.classList.toggle("mine", card.getAttribute("data-platform-card") === os);
    });
  }

  /* ---------------------------------------------------------------- the star count, kept fresh for an hour */
  var stars = $$("[data-stars]");
  if (stars.length && window.fetch) {
    var key = "digup-stars", cached = null;
    try { cached = JSON.parse(window.sessionStorage.getItem(key) || "null"); } catch (e) {}
    var show = function (n) {
      var text = n >= 1000 ? (n / 1000).toFixed(1).replace(/\.0$/, "") + "k" : String(n);
      stars.forEach(function (el) { el.textContent = text; });
    };
    if (cached && Date.now() - cached.t < 3600 * 1000) show(cached.n);
    else fetch("https://api.github.com/repos/" + CFG.repo, { headers: { Accept: "application/vnd.github+json" } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) {
        if (!data || !data.stargazers_count) return;
        show(data.stargazers_count);
        try { window.sessionStorage.setItem(key, JSON.stringify({ t: Date.now(), n: data.stargazers_count })); } catch (e) {}
      }).catch(function () {});
  }

  /* ---------------------------------------------------------------- the menu on small screens */
  var menu = $(".nav-menu");
  if (menu) {
    document.addEventListener("click", function (e) { if (menu.open && !menu.contains(e.target)) menu.open = false; });
    $$("a", menu).forEach(function (a) { a.addEventListener("click", function () { menu.open = false; }); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") menu.open = false; });
  }

  /* ---------------------------------------------------------------- tabs: one choice of system for the whole site */
  var SYSTEMS = ["mac", "windows", "linux"];
  function selectTab(group, name, remember) {
    var tabs = $$(":scope > .tab", group);
    var buttons = $$(":scope > .tab-list > button", group);
    tabs.forEach(function (tab, i) {
      var on = tab.getAttribute("data-tab") === name;
      tab.hidden = !on;
      buttons[i].setAttribute("aria-selected", on ? "true" : "false");
      buttons[i].tabIndex = on ? 0 : -1;
    });
    if (remember && SYSTEMS.indexOf(name) >= 0) {
      store("digup-system", name);
      $$("[data-tabs].ready").forEach(function (other) {
        if (other !== group && $(":scope > .tab[data-tab='" + name + "']", other)) selectTab(other, name, false);
      });
    }
  }
  $$("[data-tabs]").forEach(function (group, n) {
    var tabs = $$(":scope > .tab", group);
    if (tabs.length < 2) return;
    var list = document.createElement("div");
    list.className = "tab-list";
    list.setAttribute("role", "tablist");
    tabs.forEach(function (tab, i) {
      var name = tab.getAttribute("data-tab");
      var id = "tabs-" + n + "-" + name;
      var button = document.createElement("button");
      button.type = "button";
      button.textContent = tab.getAttribute("aria-label");
      button.setAttribute("role", "tab");
      button.id = id + "-tab";
      button.setAttribute("aria-controls", id);
      tab.setAttribute("role", "tabpanel");
      if (!tab.id) tab.id = id;
      button.setAttribute("aria-controls", tab.id);
      tab.setAttribute("aria-labelledby", button.id);
      button.addEventListener("click", function () { selectTab(group, name, true); });
      button.addEventListener("keydown", function (e) {
        if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
        var next = (i + (e.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length;
        var target = tabs[next].getAttribute("data-tab");
        selectTab(group, target, true);
        $$(":scope > .tab-list > button", group)[next].focus();
      });
      list.appendChild(button);
    });
    group.insertBefore(list, tabs[0]);
    group.classList.add("ready");
    var names = tabs.map(function (t) { return t.getAttribute("data-tab"); });
    var hash = window.location.hash.slice(1);
    var saved = store("digup-system");
    var pick = names.indexOf(hash) >= 0 ? hash : names.indexOf(saved) >= 0 ? saved : names.indexOf(os) >= 0 ? os : names[0];
    selectTab(group, pick, false);
  });

  /* ---------------------------------------------------------------- copy buttons */
  function copy(text, button) {
    var done = function () {
      button.classList.add("done");
      setTimeout(function () { button.classList.remove("done"); }, 1400);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, function () {});
  }
  $$(".prose pre").forEach(function (pre) {
    var button = document.createElement("button");
    button.type = "button";
    button.className = "copy";
    button.setAttribute("aria-label", "Copy");
    button.innerHTML = '<svg class="icon" aria-hidden="true"><use href="#i-copy"/></svg>';
    button.addEventListener("click", function () { copy(pre.innerText.trim(), button); });
    pre.appendChild(button);
  });
  $$("[data-copy]").forEach(function (button) {
    button.addEventListener("click", function () { copy(button.getAttribute("data-copy"), button); });
  });

  /* ---------------------------------------------------------------- filters on the help and changelog pages */
  $$("[data-filter]").forEach(function (bar) {
    var buttons = $$("button[data-filter-value]", bar);
    buttons.forEach(function (button) {
      button.addEventListener("click", function () {
        var value = button.getAttribute("data-filter-value");
        buttons.forEach(function (b) { b.setAttribute("aria-pressed", b === button ? "true" : "false"); });
        $$("[data-platforms]").forEach(function (item) {
          var list = (item.getAttribute("data-platforms") || "").split(" ");
          item.classList.toggle("hide", value !== "all" && list.indexOf(value) < 0);
        });
        $$("[data-filter-group]").forEach(function (group) {
          group.classList.toggle("hide", !$("[data-platforms]:not(.hide)", group));
        });
      });
    });
  });

  /* ---------------------------------------------------------------- questions open from a link */
  function openTarget() {
    var id = decodeURIComponent(window.location.hash.slice(1));
    if (!id) return;
    var el = document.getElementById(id);
    if (el && el.tagName === "DETAILS") el.open = true;
  }
  openTarget();
  window.addEventListener("hashchange", openTarget);

  /* ---------------------------------------------------------------- "on this page" follows the reader */
  var toc = $(".docs-toc");
  if (toc && "IntersectionObserver" in window) {
    var links = $$("a[href^='#']", toc);
    var byId = {};
    links.forEach(function (a) { byId[decodeURIComponent(a.getAttribute("href").slice(1))] = a; });
    var current = null;
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) { if (entry.isIntersecting) current = entry.target.id; });
      links.forEach(function (a) { a.classList.toggle("here", byId[current] === a); });
    }, { rootMargin: "-90px 0px -70% 0px" });
    Object.keys(byId).forEach(function (id) { var el = document.getElementById(id); if (el) observer.observe(el); });
  }

  /* ---------------------------------------------------------------- the panel on the home page */
  var demo = $("[data-demo]");
  if (demo) {
    var scenes = $$("[data-scene]", demo);
    var chips = $$("[data-scene-chip]");
    var query = $("[data-query]", demo);
    var caption = $("[data-caption]");
    var index = 0, timer = null, typing = null, userTook = false, visible = true, step = 0;
    var later = function (fn, ms) { clearTimeout(timer); timer = setTimeout(fn, ms); };
    var captionFor = function (id) { var t = $("template[data-caption-for='" + id + "']"); return t ? t.innerHTML.trim() : ""; };

    var typeText = function (text, done) {
      clearInterval(typing);
      if (reduceMotion) { query.textContent = text; done(); return; }
      var chars = Array.from(text), n = 0;
      query.textContent = "";
      typing = setInterval(function () {
        n += 1;
        query.textContent = chars.slice(0, n).join("");
        if (n >= chars.length) { clearInterval(typing); done(); }
      }, 46);
    };

    var show = function (i, animate) {
      index = (i + scenes.length) % scenes.length;
      step = 0;
      var scene = scenes[index];
      var id = scene.getAttribute("data-scene");
      var queries = JSON.parse(scene.getAttribute("data-queries"));
      chips.forEach(function (chip) { chip.setAttribute("aria-selected", chip.getAttribute("data-scene-chip") === id ? "true" : "false"); });
      if (caption) caption.textContent = captionFor(id);
      var reveal = function () {
        scenes.forEach(function (s) { s.hidden = s !== scene; s.classList.remove("showing"); });
        if (animate && !reduceMotion) { void scene.offsetWidth; scene.classList.add("showing"); }
        if (queries.length > 1) cycleQueries(queries);
        else if (!userTook) later(function () { if (visible) show(index + 1, true); }, 4200);
      };
      if (animate) typeText(queries[0], reveal); else { query.textContent = queries[0]; reveal(); }
    };
    var cycleQueries = function (queries) {
      later(function () {
        step += 1;
        if (step < queries.length) typeText(queries[step], function () { cycleQueries(queries); });
        else if (!userTook && visible) show(index + 1, true);
      }, 2000);
    };

    chips.forEach(function (chip, i) {
      chip.addEventListener("click", function () { userTook = true; clearTimeout(timer); show(i, true); });
      chip.addEventListener("keydown", function (e) {
        if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
        var next = (i + (e.key === "ArrowRight" ? 1 : chips.length - 1)) % chips.length;
        chips[next].focus();
        chips[next].click();
      });
    });
    if ("IntersectionObserver" in window && !reduceMotion) {
      new IntersectionObserver(function (entries) {
        var was = visible;
        visible = entries[0].isIntersecting && !document.hidden;
        if (visible && !was && !userTook) later(function () { show(index + 1, true); }, 1500);
      }, { threshold: 0.35 }).observe(demo);
      document.addEventListener("visibilitychange", function () { if (document.hidden) visible = false; });
      later(function () { if (visible) show(1, true); }, 4500);
    }
  }

  /* ---------------------------------------------------------------- the product video: the poster becomes YouTube's
     player when clicked, so nothing comes from YouTube before someone asks for the video */
  $$("[data-yt-play]").forEach(function (poster) {
    poster.addEventListener("click", function (e) {
      e.preventDefault();
      var frame = document.createElement("iframe");
      frame.src = poster.getAttribute("data-embed") + "?autoplay=1&rel=0&playsinline=1";
      frame.title = poster.getAttribute("data-title");
      frame.allow = "autoplay; encrypted-media; picture-in-picture; fullscreen";
      frame.allowFullscreen = true;
      frame.referrerPolicy = "strict-origin-when-cross-origin";
      var box = document.createElement("div");
      box.className = "video-player";
      box.appendChild(frame);
      poster.replaceWith(box);
      frame.focus();
    });
  });

  /* ---------------------------------------------------------------- the demo recording, in a dialog */
  var videoDialog = $("[data-video]");
  if (videoDialog && videoDialog.showModal) {
    var demoVideo = $("[data-video-demo]", videoDialog);
    var closeVideo = function () { demoVideo.pause(); if (videoDialog.open) videoDialog.close(); };
    $$("[data-video-open]").forEach(function (opener) {
      opener.addEventListener("click", function (e) {
        e.preventDefault();
        videoDialog.showModal();
        demoVideo.play().catch(function () {});
      });
    });
    $$("[data-video-close]").forEach(function (b) { b.addEventListener("click", closeVideo); });
    videoDialog.addEventListener("click", function (e) { if (e.target === videoDialog) closeVideo(); });
    videoDialog.addEventListener("close", function () { demoVideo.pause(); });
  }

  /* ---------------------------------------------------------------- one space: real vectors of the demo files; a
     search drops into the space among what it finds, with lines to its best matches and their cosine similarity */
  var space = $("[data-space]");
  var spaceData = $("#space-data");
  if (space && spaceData) {
    var data = JSON.parse(spaceData.textContent);
    var plane = $(".space-plane", space);
    var qPoint = $("[data-space-query]", space), qGlow = $("[data-space-glow]", space), qText = $("[data-space-q]", space);
    var lines = $("[data-space-lines]", space), leads = $("[data-space-leads]", space), hits = $("[data-space-hits]", space);
    var cardsBox = $("[data-space-cards]", space), spaceList = $("[data-space-results]", space);
    var labels = $$(".space-label", space);
    var spaceChips = $$("[data-space-chip]", space);
    var spaceAt = 0, started = false, typingTimer = null, frame = 0;
    var card = function (c) {
      var media = "";
      if (c.src) media = '<img src="' + c.src + '" alt="" loading="lazy">' + (c.at ? '<span class="sc-at">' + escapeHtml(c.at) + "</span>" : "");
      else if (c.peaks) media = '<span class="sc-wave">' + c.peaks.map(function (h) { return '<i style="height:' + Math.round(h * 100) + '%"></i>'; }).join("") + "</span>" + (c.at ? '<span class="sc-at">' + escapeHtml(c.at) + "</span>" : "");
      else if (c.excerpt) media = '<span class="sc-text" dir="auto">' + escapeHtml(c.excerpt) + "</span>";
      var page = c.at && c.at.indexOf("p.") === 0 ? " sc-page" : "";
      return '<div class="space-card" style="left:' + c.x + "%;top:" + c.y + '%"><div class="sc-media sc-' + c.kind + page + '">' + media +
        '</div><p class="sc-foot"><span class="sc-role">' + escapeHtml(c.role) + '</span><span class="sc-cos" title="cosine similarity">' +
        c.cos.toFixed(2) + '</span></p><p class="sc-name" dir="auto">' + escapeHtml(c.name) + "</p></div>";
    };
    // From the map as drawn: a dashed lead from each match to its card, and the names that a card or the search covers.
    var arrange = function () {
      var s = data.searches[spaceAt], W = plane.clientWidth, H = plane.clientHeight;
      if (!started || !W || !H) return;
      var qx = s.x / 100 * W, qy = s.y / 100 * H;
      var covered = [[qx - 24, qy - 24, qx + 24, qy + 24]];
      leads.innerHTML = $$(".space-card", cardsBox).map(function (el, j) {
        var c = s.cards[j], px = c.px / 100 * W, py = c.py / 100 * H;
        var l = el.offsetLeft, t = el.offsetTop, r = l + el.offsetWidth, b = t + el.offsetHeight;
        covered.push([l - 6, t - 6, r + 6, b + 6]);
        var x = Math.min(Math.max(px, l + 4), r - 4), y = Math.min(Math.max(py, t + 4), b - 4);
        if (Math.hypot(x - px, y - py) < 10) return "";
        return '<line x1="' + (px / W * 1600).toFixed(1) + '" y1="' + (py / H * 900).toFixed(1) + '" x2="' + (x / W * 1600).toFixed(1) +
          '" y2="' + (y / H * 900).toFixed(1) + '"/>';
      }).join("");
      labels.forEach(function (l) {
        var w = l.offsetWidth, x0 = l.offsetLeft - w / 2, y0 = l.offsetTop, x1 = x0 + w, y1 = y0 + l.offsetHeight;
        l.classList.toggle("hide", w > 0 && covered.some(function (b) { return x0 < b[2] && x1 > b[0] && y0 < b[3] && y1 > b[1]; }));
      });
    };
    var showSearch = function (n) {
      var s = data.searches[n];
      spaceAt = n;
      started = true;
      spaceChips.forEach(function (c, i) { c.setAttribute("aria-selected", i === n ? "true" : "false"); });
      [qPoint, qGlow].forEach(function (el) { el.style.left = s.x + "%"; el.style.top = s.y + "%"; });
      var x1 = s.x * 16, y1 = s.y * 9;
      lines.innerHTML = s.cards.map(function (c) {
        var x2 = c.px * 16, y2 = c.py * 9;
        return '<line x1="' + x1.toFixed(1) + '" y1="' + y1.toFixed(1) + '" x2="' + x2.toFixed(1) + '" y2="' + y2.toFixed(1) +
          '" style="--len:' + Math.hypot(x2 - x1, y2 - y1).toFixed(1) + '"/>';
      }).join("");
      hits.innerHTML = s.cards.map(function (c) {
        return '<circle class="k-' + data.points[c.i].k + '" cx="' + (c.px * 16).toFixed(1) + '" cy="' + (c.py * 9).toFixed(1) + '" r="5.6"/>';
      }).join("");
      cardsBox.innerHTML = s.cards.map(card).join("");
      spaceList.innerHTML = s.cards.map(function (c) {
        return '<li><span class="sr-role">' + escapeHtml(c.role) + '</span> <span class="sr-name" dir="auto">' + escapeHtml(c.name) +
          '</span> <span class="sr-cos">' + c.cos.toFixed(2) + "</span></li>";
      }).join("");
      arrange();
      space.classList.remove("settled");
      void space.offsetWidth;
      space.classList.add("settled");
      clearInterval(typingTimer);
      if (reduceMotion) { qText.textContent = s.q; return; }
      var chars = Array.from(s.q), k = 0;
      qText.textContent = "";
      typingTimer = setInterval(function () {
        k += 1;
        qText.textContent = chars.slice(0, k).join("");
        if (k >= chars.length) clearInterval(typingTimer);
      }, 28);
    };
    spaceChips.forEach(function (chip, i) {
      chip.addEventListener("click", function () { showSearch(i); });
      chip.addEventListener("keydown", function (e) {
        if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
        var next = (i + (e.key === "ArrowRight" ? 1 : spaceChips.length - 1)) % spaceChips.length;
        spaceChips[next].focus();
        showSearch(next);
      });
    });
    // The first search is typed and drops in from the search field when the map comes into view, as in the video.
    if (!reduceMotion && "IntersectionObserver" in window) {
      [qPoint, qGlow].forEach(function (el) { el.style.left = "50%"; el.style.top = "9%"; });
      qText.textContent = "";
      var seen = new IntersectionObserver(function (entries) {
        if (!entries.some(function (e) { return e.isIntersecting; })) return;
        seen.disconnect();
        if (!started) showSearch(0);
      }, { threshold: 0.4 });
      seen.observe(plane);
    } else {
      showSearch(0);
    }
    window.addEventListener("resize", function () { cancelAnimationFrame(frame); frame = requestAnimationFrame(arrange); });
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(arrange);
  }

  /* ---------------------------------------------------------------- the site search */
  var finder = $("[data-finder]");
  if (!finder || !finder.showModal) {
    $$("[data-search-open]").forEach(function (b) { b.hidden = true; });
    return;
  }
  var input = $("#finder-input", finder);
  var list = $(".finder-list", finder);
  var preview = $(".finder-preview", finder);
  var count = $(".finder-count", finder);
  var records = null, loading = null, results = [], selected = 0;
  var STOP = new Set("a an and are as at be but by can could do does did for from get got had has have how i if in into is it its just me my no not of on or our so than that the their them then there these they this to too was we what when where which who why will with would you your doesn don isn aren wasn weren won couldn didn shouldn wouldn haven hasn ll ve re".split(" "));
  var SYNONYMS = {
    donate: ["donation", "support", "sponsor"], sponsor: ["donate", "donation"], donation: ["donate"], tip: ["donate"],
    uninstall: ["remove", "delete"], remove: ["uninstall", "delete"], delete: ["remove", "uninstall"],
    shortcut: ["hotkey", "keyboard", "keys"], hotkey: ["shortcut"], keyboard: ["shortcut"],
    gpu: ["graphics", "vulkan", "metal"], graphics: ["gpu", "vulkan"], cpu: ["processor"], processor: ["cpu"],
    slow: ["speed", "hours", "long", "time"], fast: ["speed"], speed: ["slow", "time"],
    battery: ["power", "energy"], power: ["battery"], crash: ["crashes", "stops", "quits"], crashes: ["crash", "stops"],
    blocked: ["firewall", "network", "fails"], firewall: ["blocked", "network"], proxy: ["network", "firewall"],
    privacy: ["private", "network", "telemetry", "upload"], private: ["privacy", "network"], upload: ["leaves", "network"],
    update: ["updates", "upgrade", "version"], upgrade: ["update", "updates"], logs: ["log", "report"], bug: ["report", "issue"],
    install: ["download", "installer", "setup"], download: ["install", "downloads"], requirements: ["needs", "requires"],
    ocr: ["text", "screenshots", "scans"], screenshot: ["screenshots"], photo: ["photos", "pictures", "image", "images"],
    photos: ["photo", "pictures", "images"], picture: ["pictures", "photo", "image"], video: ["videos", "moment"],
    audio: ["recording", "recordings", "podcast", "sound"], recording: ["audio", "recordings"], pdf: ["pdfs", "page"],
    excel: ["xlsx", "spreadsheets"], powerpoint: ["pptx", "slides"], word: ["docx", "doc", "documents"],
    language: ["languages", "bengali", "arabic", "chinese"], languages: ["language"], chinese: ["cjk", "japanese"],
    wayland: ["gnome", "kde", "shortcut"], tray: ["appindicator", "icon"], icloud: ["cloud"], onedrive: ["cloud"],
    index: ["indexing", "indexed"], indexing: ["index", "indexed"], memory: ["ram"], ram: ["memory"], disk: ["size", "ssd"],
    free: ["price", "cost", "license"], cost: ["free"], mac: ["macos"], macos: ["mac"], intel: ["x86"]
  };
  var PROBLEM = /\b(not|doesn|don|won|can|cannot|error|fail|fails|failed|stuck|crash|crashes|broken|missing|nothing|blocked|slow|never|stopped|stops|drain|drains|hot|high|wrong|empty)\b/;

  var norm = function (s) { return String(s).toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, ""); };
  var tokens = function (s) {
    var out = [];
    norm(s).split(/[^\p{L}\p{N}\p{M}.]+/u).forEach(function (piece) {
      piece = piece.replace(/^\.+|\.+$/g, "");
      if (/^\d+(\.\d+)+$/.test(piece)) out.push(piece);
      else piece.split(".").forEach(function (w) { if (w.length > 1 || /\d/.test(w)) out.push(w); });
    });
    return out;
  };
  var terms = function (q) { var t = tokens(q).filter(function (w) { return !STOP.has(w); }); return t.length ? t : tokens(q); };

  var load = function () {
    if (records) return Promise.resolve(records);
    if (!loading) loading = fetch(CFG.search).then(function (r) { return r.json(); }).then(function (data) {
      records = data.map(function (r) {
        return { r: r, t: new Set(tokens(r.t + " " + r.h)), s: new Set(tokens(r.s)), x: new Set(tokens(r.x)), all: norm(r.t + " " + r.h + " " + r.x) };
      });
      return records;
    });
    return loading;
  };
  var hasPrefix = function (set, term) {
    if (term.length < 3) return false;
    var found = false;
    set.forEach(function (w) { if (!found && w.length > term.length && w.indexOf(term) === 0) found = true; });
    return found;
  };
  var scoreOf = function (entry, qterms, phrase, problem) {
    var score = 0, matched = 0, hits = [];
    qterms.forEach(function (term) {
      var best = 0, hit = null;
      var own = 0;
      [term].concat(SYNONYMS[term] || []).forEach(function (v, i) {
        var w = i === 0 ? 1 : 0.5;
        var s = entry.t.has(v) ? 6 : entry.s.has(v) ? 2.5 : entry.x.has(v) ? 1.8 :
          hasPrefix(entry.t, v) ? 4 : hasPrefix(entry.x, v) ? 1 : 0;
        if (i === 0) own = s;
        if (s * w > best) { best = s * w; hit = v; }
      });
      if (best > 0) { matched += 1; score += best; hits.push(own > 0 ? term : hit); }
    });
    if (!matched) return null;
    var coverage = matched / qterms.length;
    score *= 0.35 + Math.pow(coverage, 1.5);
    if (phrase && entry.all.indexOf(phrase) >= 0) score += 5;
    var kind = entry.r.k;
    if (kind === "Help") score *= problem ? 1.45 : 1.1;
    if (kind === "Changelog") score *= /\d+\.\d+/.test(phrase) ? 2 : 0.55;
    if (kind === "FAQ") score *= 1.05;
    return { score: score, hits: hits, entry: entry };
  };

  var KIND_ICON = { Docs: "book", Help: "question", FAQ: "info", Changelog: "refresh" };
  var KIND_NAME = { Docs: "Docs", Help: "Troubleshooting", FAQ: "Questions", Changelog: "Changelog" };
  var SUGGESTIONS = ["The model download is blocked", "Shortcut on Wayland", "Nothing gets indexed", "Run on the processor", "Which files does it read?", "Does anything leave my computer?", "Uninstall", "Code search"];

  var mark = function (text, hits) {
    var safe = escapeHtml(text);
    hits.forEach(function (h) {
      if (h.length < 2) return;
      var re = new RegExp("(^|[^\\p{L}\\p{N}])(" + h.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "[\\p{L}\\p{N}]*)", "giu");
      safe = safe.replace(re, "$1<mark>$2</mark>");
    });
    return safe;
  };
  var excerpt = function (text, hits) {
    var low = norm(text), at = -1;
    hits.forEach(function (h) { var i = low.indexOf(h); if (i >= 0 && (at < 0 || i < at)) at = i; });
    if (at < 0) return text.slice(0, 280) + (text.length > 280 ? "…" : "");
    var start = Math.max(0, at - 90);
    while (start > 0 && text[start] !== " ") start -= 1;
    var piece = text.slice(start, start + 300);
    return (start > 0 ? "…" : "") + piece.trim() + (start + 300 < text.length ? "…" : "");
  };
  var urlOf = function (r) { return CFG.base + r.u; };

  var renderPreview = function () {
    var item = results[selected];
    if (!item) { preview.innerHTML = ""; return; }
    var r = item.entry.r;
    var why = item.hits.length ? "Has your words: " + Array.from(new Set(item.hits)).slice(0, 4).join(", ") : "";
    preview.innerHTML =
      '<p class="fp-kind">' + escapeHtml(KIND_NAME[r.k] || r.k) + (r.s ? " · " + escapeHtml(r.s) : "") + "</p>" +
      '<p class="fp-title">' + escapeHtml(r.h && r.k !== "Changelog" ? r.h : r.t) + "</p>" +
      '<p class="fp-where">' + escapeHtml(r.k === "Changelog" ? "Release " + r.t : r.h ? r.t : "") + "</p>" +
      (why ? '<p class="fp-why"><svg class="icon" aria-hidden="true"><use href="#i-find"/></svg>' + escapeHtml(why) + "</p>" : "") +
      '<p class="fp-text">' + mark(excerpt(r.x, item.hits), item.hits) + "</p>" +
      '<a class="fp-open" href="' + urlOf(r) + '">Open</a>';
  };
  var select = function (i, scroll) {
    if (!results.length) return;
    selected = (i + results.length) % results.length;
    $$(".finder-row", list).forEach(function (row, n) {
      row.setAttribute("aria-selected", n === selected ? "true" : "false");
      if (n === selected && scroll) row.scrollIntoView({ block: "nearest" });
    });
    input.setAttribute("aria-activedescendant", "finder-row-" + selected);
    renderPreview();
  };
  var empty = function (q) {
    results = [];
    preview.innerHTML = "";
    if (!q) {
      list.innerHTML = '<div class="finder-empty"><p>Describe what you\'re looking for.</p><p>The docs, troubleshooting, questions and changelog are all here. Try one:</p><div class="finder-suggest">' +
        SUGGESTIONS.map(function (s) { return '<button type="button">' + escapeHtml(s) + "</button>"; }).join("") + "</div></div>";
      $$(".finder-suggest button", list).forEach(function (b) {
        b.addEventListener("click", function () { input.value = b.textContent; run(); input.focus(); });
      });
      count.textContent = "";
    } else {
      list.innerHTML = '<div class="finder-empty"><p>Nothing here matches “' + escapeHtml(q) + '”.</p><p>Try other words, or <a href="https://github.com/' +
        CFG.repo + "/issues?q=" + encodeURIComponent(q) + '">search the issues on GitHub</a>.</p></div>';
      count.textContent = "No results";
    }
  };
  var run = function () {
    var q = input.value.trim();
    if (!q) { empty(""); return; }
    load().then(function (all) {
      if (input.value.trim() !== q) return;
      var qterms = terms(q), phrase = qterms.length > 1 ? norm(q) : "", problem = PROBLEM.test(norm(q));
      var scored = [];
      all.forEach(function (entry) { var s = scoreOf(entry, qterms, phrase, problem); if (s) scored.push(s); });
      scored.sort(function (a, b) { return b.score - a.score; });
      var seen = {}, perKind = {}, picked = [];
      scored.forEach(function (s) {
        var r = s.entry.r, key = r.u + "|" + r.h;
        var cap = r.k === "Changelog" ? 3 : 6;
        if (seen[key] || (perKind[r.k] || 0) >= cap || picked.length >= 14) return;
        if (s.score < (scored[0].score * 0.18)) return;
        seen[key] = true;
        perKind[r.k] = (perKind[r.k] || 0) + 1;
        picked.push(s);
      });
      if (!picked.length) { empty(q); return; }
      var order = [];
      picked.forEach(function (s) { if (order.indexOf(s.entry.r.k) < 0) order.push(s.entry.r.k); });
      results = [];
      var html = "";
      order.forEach(function (kind) {
        html += '<p class="finder-kind">' + escapeHtml(KIND_NAME[kind] || kind) + "</p>";
        picked.forEach(function (s) {
          if (s.entry.r.k !== kind) return;
          var r = s.entry.r, n = results.length;
          results.push(s);
          var name = r.k === "Changelog" ? r.h : r.h || r.t;
          var where = r.k === "Changelog" ? r.t + (r.s ? " · " + r.s : "") : r.h ? r.t : r.s;
          html += '<a class="finder-row" role="option" id="finder-row-' + n + '" href="' + urlOf(r) + '" aria-selected="false">' +
            '<span class="row-thumb glyph"><svg class="icon" aria-hidden="true"><use href="#i-' + (KIND_ICON[r.k] || "doc") + '"/></svg></span>' +
            '<span class="row-text"><span class="row-name">' + escapeHtml(name) + '</span><span class="row-where">' + escapeHtml(where || "") + "</span></span></a>";
        });
      });
      list.innerHTML = html;
      $$(".finder-row", list).forEach(function (row, n) {
        row.addEventListener("mousemove", function () { if (selected !== n) select(n, false); });
        row.addEventListener("click", function () { finder.close(); });
      });
      count.textContent = results.length + (results.length === 1 ? " result" : " results");
      select(0, false);
    });
  };

  var openFinder = function (text) {
    if (finder.open) return;
    finder.showModal();
    input.value = text || "";
    input.focus();
    if (input.value) run(); else empty("");
    load();
  };
  $$("[data-search-open]").forEach(function (b) { b.addEventListener("click", function () { openFinder(); }); });
  $$("[data-finder-close]").forEach(function (b) { b.addEventListener("click", function () { finder.close(); }); });
  finder.addEventListener("click", function (e) { if (e.target === finder) finder.close(); });
  var debounce = null;
  input.addEventListener("input", function () { clearTimeout(debounce); debounce = setTimeout(run, 90); });
  input.addEventListener("keydown", function (e) {
    if (e.key === "ArrowDown") { e.preventDefault(); select(selected + 1, true); }
    else if (e.key === "ArrowUp") { e.preventDefault(); select(selected - 1, true); }
    else if (e.key === "Enter") {
      var item = results[selected];
      if (item) { e.preventDefault(); finder.close(); window.location.href = urlOf(item.entry.r); }
    }
  });
  document.addEventListener("keydown", function (e) {
    var typingInField = /^(INPUT|TEXTAREA|SELECT)$/.test((e.target && e.target.tagName) || "") || (e.target && e.target.isContentEditable);
    if ((e.key === "k" || e.key === "K") && (e.metaKey || e.ctrlKey)) { e.preventDefault(); if (finder.open) finder.close(); else openFinder(); }
    else if (e.key === "/" && !typingInField && !finder.open) { e.preventDefault(); openFinder(); }
  });
  if (/^#search=/.test(window.location.hash)) openFinder(decodeURIComponent(window.location.hash.slice(8)));
})();
