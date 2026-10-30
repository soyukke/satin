// Draws one Satin page: the Markdown of a version's snapshot, with `mermaid`
// and `chart` fences, GFM alerts, task lists, inline SVG, and the images beside
// it. A host loads index.html?host under its Content-Security-Policy, then
// calls `satinPage.setLook` and `satinPage.open`.
(function () {
  "use strict";

  const alertNames = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"];
  const alertTitles = {
    en: { NOTE: "Note", TIP: "Tip", IMPORTANT: "Important", WARNING: "Warning", CAUTION: "Caution" },
    ja: { NOTE: "メモ", TIP: "ヒント", IMPORTANT: "重要", WARNING: "注意", CAUTION: "警告" },
  };
  // The series colors a chart takes when its datasets name none.
  const paletteTokens = ["--teal", "--violet", "--amber", "--rose", "--muted"];

  const root = document.documentElement;
  let source = "";
  let pageURL = null;
  let charts = [];
  let drawn = 0;

  function token(name) {
    return getComputedStyle(root).getPropertyValue(name).trim();
  }

  function palette() {
    return paletteTokens.map(token);
  }

  // A token's `#rrggbb` or `rgb()` color at `alpha`, for a fill under a series
  // line. A canvas does not take every CSS color syntax, so the result is
  // plain `rgba()`.
  function faded(color, alpha) {
    const hex = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(color);
    const parts = hex ? hex.slice(1).map((part) => parseInt(part, 16)) : (color.match(/[\d.]+/g) || []).slice(0, 3);
    return parts.length === 3 ? `rgba(${parts.join(", ")}, ${alpha})` : color;
  }

  const md = window.markdownit({ html: true, linkify: true });
  const escape = md.utils.escapeHtml;

  md.renderer.rules.fence = function (tokens, index) {
    const fence = tokens[index];
    const info = fence.info.trim();
    const space = info.search(/\s/);
    const lang = space < 0 ? info : info.slice(0, space);
    const caption = space < 0 ? "" : info.slice(space + 1).trim();
    const figcaption = caption ? `<figcaption>${escape(caption)}</figcaption>` : "";
    if (lang === "mermaid" || lang === "chart") {
      return (
        `<figure class="${lang === "mermaid" ? "diagram" : "chart"}" ` +
        `data-source="${escape(fence.content)}"><div class="plot"></div>${figcaption}</figure>\n`
      );
    }
    const label = lang ? ` data-lang="${escape(lang)}"` : "";
    return `<pre class="code"${label}><code>${escape(fence.content)}</code></pre>\n`;
  };

  // An image outside the page's own snapshot is shown as its text.
  const image = md.renderer.rules.image;
  md.renderer.rules.image = function (tokens, index, options, env, self) {
    const picture = tokens[index];
    const url = new URL(picture.attrGet("src"), pageURL);
    if (url.protocol !== pageURL.protocol || url.host !== pageURL.host) {
      return `<span class="omitted">${escape(picture.content || url.href)}</span>`;
    }
    picture.attrSet("src", url.href);
    return image(tokens, index, options, env, self);
  };

  function firstText(element) {
    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
    let node = walker.nextNode();
    while (node && !node.nodeValue.trim()) {
      node = walker.nextNode();
    }
    return node;
  }

  // `> [!NOTE]` and its kin become callouts.
  function setAlerts(page) {
    const lang = root.lang.startsWith("ja") ? "ja" : "en";
    for (const quote of page.querySelectorAll("blockquote")) {
      const text = firstText(quote);
      const match = text && /^\s*\[!(\w+)\][ \t]*\n?/.exec(text.nodeValue);
      if (!match || !alertNames.includes(match[1].toUpperCase())) {
        continue;
      }
      const kind = match[1].toUpperCase();
      text.nodeValue = text.nodeValue.slice(match[0].length);
      const paragraph = text.parentElement;
      if (paragraph.tagName === "P" && !paragraph.textContent.trim() && paragraph.children.length === 0) {
        paragraph.remove();
      }
      const callout = document.createElement("aside");
      callout.className = `callout ${kind.toLowerCase()}`;
      const title = document.createElement("p");
      title.className = "callout-title";
      title.textContent = alertTitles[lang][kind];
      callout.append(title, ...quote.childNodes);
      quote.replaceWith(callout);
    }
  }

  // `- [ ]` and `- [x]` list items become checkboxes.
  function setTasks(page) {
    for (const item of page.querySelectorAll("li")) {
      const text = firstText(item);
      const match = text && /^\[([ xX])\]\s+/.exec(text.nodeValue);
      if (!match || text.parentElement !== item && text.parentElement.parentElement !== item) {
        continue;
      }
      text.nodeValue = text.nodeValue.slice(match[0].length);
      const box = document.createElement("span");
      box.className = match[1] === " " ? "check" : "check done";
      box.setAttribute("role", "img");
      box.setAttribute("aria-label", match[1] === " " ? "not done" : "done");
      text.parentElement.prepend(box);
      item.classList.add("task");
      item.parentElement.classList.add("tasks");
    }
  }

  // A table scrolls on its own instead of widening the page.
  function wrapTables(page) {
    for (const table of page.querySelectorAll("table")) {
      const frame = document.createElement("div");
      frame.className = "table-frame";
      table.replaceWith(frame);
      frame.append(table);
    }
  }

  function showFailure(figure, error) {
    figure.classList.add("failed");
    const plot = figure.querySelector(".plot");
    plot.replaceChildren();
    const message = document.createElement("p");
    message.className = "failure";
    message.textContent = String(error && error.message ? error.message : error);
    const code = document.createElement("pre");
    code.className = "code";
    code.textContent = figure.dataset.source;
    plot.append(message, code);
  }

  async function drawDiagrams(page, pass) {
    const paper = root.dataset.look === "paper";
    window.mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: "base",
      fontFamily: token("--font-sans"),
      // A wide diagram keeps its type size and scrolls instead of shrinking.
      flowchart: { useMaxWidth: false },
      sequence: { useMaxWidth: false },
      gantt: { useMaxWidth: false },
      class: { useMaxWidth: false },
      state: { useMaxWidth: false },
      er: { useMaxWidth: false },
      themeVariables: {
        darkMode: !paper,
        background: token("--surface"),
        primaryColor: token("--raised"),
        primaryTextColor: token("--text"),
        primaryBorderColor: token("--violet"),
        secondaryColor: token("--surface"),
        secondaryTextColor: token("--text"),
        secondaryBorderColor: token("--teal"),
        tertiaryColor: token("--surface"),
        tertiaryTextColor: token("--text"),
        tertiaryBorderColor: token("--line"),
        lineColor: token("--muted"),
        textColor: token("--text"),
        mainBkg: token("--raised"),
        nodeBorder: token("--violet"),
        clusterBkg: token("--surface"),
        clusterBorder: token("--line"),
        edgeLabelBackground: token("--raised"),
        noteBkgColor: token("--raised"),
        noteTextColor: token("--text"),
        noteBorderColor: token("--amber"),
        actorBkg: token("--raised"),
        actorBorder: token("--violet"),
        actorTextColor: token("--text"),
        signalColor: token("--text"),
        signalTextColor: token("--text"),
        fontSize: "14px",
      },
    });
    let index = 0;
    for (const figure of page.querySelectorAll("figure.diagram")) {
      index += 1;
      try {
        const { svg } = await window.mermaid.render(`diagram-${pass}-${index}`, figure.dataset.source);
        if (pass !== drawn) {
          return;
        }
        const plot = figure.querySelector(".plot");
        plot.innerHTML = svg;
        // A wide diagram shrinks to the figure down to three quarters of its
        // size, so its type stays readable, and scrolls beyond that.
        const drawing = plot.querySelector("svg");
        const width = drawing.viewBox.baseVal.width;
        if (width > 0) {
          drawing.removeAttribute("width");
          drawing.style.maxWidth = "none";
          drawing.style.width = `clamp(${Math.round(width * 0.75)}px, 100%, ${Math.ceil(width)}px)`;
          drawing.style.height = "auto";
        }
      } catch (error) {
        showFailure(figure, error);
      }
    }
  }

  function drawCharts(page) {
    const Chart = window.Chart;
    const colors = palette();
    Chart.defaults.color = token("--muted");
    Chart.defaults.borderColor = token("--line");
    Chart.defaults.font.family = token("--font-sans");
    Chart.defaults.font.size = 12;
    for (const figure of page.querySelectorAll("figure.chart")) {
      let config;
      try {
        config = JSON.parse(figure.dataset.source);
      } catch (error) {
        showFailure(figure, error);
        continue;
      }
      const type = config.type || "bar";
      const perPoint = ["pie", "doughnut", "polarArea"].includes(type);
      (config.data?.datasets || []).forEach((dataset, number) => {
        const color = colors[number % colors.length];
        if (perPoint) {
          dataset.backgroundColor ??= dataset.data.map((_, point) => colors[point % colors.length]);
          dataset.borderColor ??= token("--surface");
        } else if ((dataset.type || type) === "line") {
          dataset.borderColor ??= color;
          dataset.backgroundColor ??= faded(color, 0.18);
          dataset.pointBackgroundColor ??= color;
        } else {
          dataset.backgroundColor ??= faded(color, 0.85);
          dataset.borderColor ??= color;
        }
      });
      config.options = { responsive: true, maintainAspectRatio: false, ...config.options };
      const plot = figure.querySelector(".plot");
      const canvas = document.createElement("canvas");
      plot.replaceChildren(canvas);
      try {
        charts.push(new Chart(canvas, config));
      } catch (error) {
        showFailure(figure, error);
      }
    }
  }

  async function draw() {
    const page = document.getElementById("page");
    drawn += 1;
    const pass = drawn;
    for (const chart of charts) {
      chart.destroy();
    }
    charts = [];
    page.innerHTML = md.render(source);
    setAlerts(page);
    setTasks(page);
    wrapTables(page);
    drawCharts(page);
    await drawDiagrams(page, pass);
  }

  // `look` is "datasheet" or "paper"; `colors` optionally overrides the look's
  // tokens, as `{ "--surface": "#fff", ... }`.
  function setLook(look, colors) {
    root.dataset.look = look === "paper" ? "paper" : "datasheet";
    for (const [name, value] of Object.entries(colors || {})) {
      root.style.setProperty(name, value);
    }
    return draw();
  }

  function render(markdown, url) {
    source = markdown;
    pageURL = new URL(url || location.href);
    return draw();
  }

  function addPreviewBar(params) {
    document.body.classList.add("preview");
    const bar = document.createElement("nav");
    bar.className = "preview-bar";
    for (const look of ["datasheet", "paper"]) {
      const button = document.createElement("button");
      button.textContent = look;
      button.addEventListener("click", () => {
        params.set("look", look);
        history.replaceState(null, "", `?${params}`);
        setLook(look);
      });
      bar.append(button);
    }
    document.body.prepend(bar);
  }

  // Fetches a version's Markdown, relative to this document, and draws it in
  // the page's language.
  async function open(path, lang) {
    if (lang) {
      root.lang = lang;
    }
    const url = new URL(path, location.href);
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`${url.pathname}: ${response.status}`);
    }
    await render(await response.text(), url);
  }

  async function start() {
    const params = new URLSearchParams(location.search);
    root.dataset.look = params.get("look") === "paper" ? "paper" : "datasheet";
    // A host sets the look and opens each page itself.
    if (params.has("host")) {
      return;
    }
    if (params.has("preview")) {
      addPreviewBar(params);
    }
    await open(params.get("page") || "artifact.md", params.get("lang"));
  }

  window.satinPage = { open, render, setLook };
  start()
    .then(() => {
      document.body.dataset.ready = "true";
    })
    .catch((error) => {
      const page = document.getElementById("page");
      page.textContent = String(error);
      document.body.dataset.ready = "failed";
    });
})();
