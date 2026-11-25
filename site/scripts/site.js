(() => {
  "use strict";

  const REPO_URL = "https://github.com/Nitinx12/Banking-Delta-Lakehouse";
  const SVG_NS = "http://www.w3.org/2000/svg";
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const select = (selector, root = document) => root.querySelector(selector);
  const selectAll = (selector, root = document) => Array.from(root.querySelectorAll(selector));

  const DETAILS = {
    sources: "Three systems contribute 10 tables: 5 full MySQL tables, 2 incremental MongoDB collections and 3 incremental Databricks public tables.",
    extract: "run_jobs.py extracts MongoDB, then Databricks public, then MySQL. Each attempt uses 3 tries, 30-second backoff and a 300-second timeout.",
    raw: "PySpark writes idempotent run-tagged snapshots to PostgreSQL raw. Full MySQL loads truncate and insert atomically.",
    "dq-raw": "The raw SQL suite has 10 checks. A critical failure stops the run before staging work starts.",
    staging: "Stored procedures conform types and keys into staging.stg_* tables, preparing SCD2 hashes for core.",
    "dq-staging": "The staging SQL suite has 10 checks. A critical failure stops the run before core loads.",
    analytics: "Core contains 7 dimensions and 4 facts. Money is NUMERIC(18,2) and times are timestamptz.",
    "dq-analytics": "The analytics SQL suite has 13 checks. A critical failure stops the run before mart builds.",
    marts: "Eight business marts cover customer 360, loans, transactions and related aggregates.",
    "dq-marts": "The mart SQL suite has 11 checks. A critical failure blocks publication to Databricks.",
    publish: "Each mart is exported to Parquet, staged in a UC volume and written to Delta with an overwrite. The implementation does not use a keyed MERGE.",
    consumer: "Published marts land in Databricks core and mart and are consumed by Streamlit and reporting jobs.",
    airflow: "Three DAGs are present: banking_delta_daily, banking_watchdog and banking_report_weekly.",
    main: "main.py runs 10 gated steps. A failing step stops the run unless the caller explicitly keeps going.",
    "run-order": "The canonical extract order is mongo, databricks, mysql.",
    retry: "Extraction uses 3 attempts, 30-second backoff and a 300-second timeout per attempt.",
    watchdog: "banking_watchdog runs every three hours with the schedule 0 */3 * * *.",
    weekly: "banking_report_weekly runs Monday at 08:00 with the schedule 0 8 * * 1.",
    audit: "SQL suites write to audit.dq_* tables. A critical data quality failure blocks publish.",
    "attempt-rollup": "finish_pipeline_run rolls up using only the latest attempt per table.",
    "orphan-reap": "finalize_dag_run reaps orphaned RUNNING rows before finalising a DAG run."
  };

  const STEPS = [
    ["sources", "sources · 5 MySQL + 2 Mongo + 3 public tables resolved"],
    ["extract", "extract · mongo then databricks then mysql"],
    ["raw", "raw · 10 idempotent landing writes tagged by run"],
    ["dq-raw", "gate 1 · raw suite 10 checks passed"],
    ["staging", "staging · 10 conformed tables prepared"],
    ["dq-staging", "gate 2 · staging suite 10 checks passed"],
    ["analytics", "core · 7 dimensions and 4 facts loaded"],
    ["dq-analytics", "gate 3 · analytics suite 13 checks passed"],
    ["marts", "marts · 8 business tables built"],
    ["dq-marts", "gate 4 · mart suite 11 checks passed"],
    ["publish", "publish · Parquet to UC volume to Delta overwrite"],
    ["consumer", "complete · Databricks core and mart refreshed"]
  ];

  function readTheme() {
    try {
      return window.localStorage.getItem("site-theme");
    } catch {
      return null;
    }
  }

  function storeTheme(theme) {
    try {
      window.localStorage.setItem("site-theme", theme);
    } catch {
      return;
    }
  }

  function setTheme(theme) {
    document.documentElement.dataset.theme = theme;
    const button = select("#theme-toggle");
    if (!button) return;
    const light = theme === "light";
    button.setAttribute("aria-pressed", String(light));
    button.setAttribute("aria-label", light ? "Switch to dark theme" : "Switch to light theme");
  }

  function initTheme() {
    const stored = readTheme();
    setTheme(stored === "light" ? "light" : "dark");
    const button = select("#theme-toggle");
    if (!button) return;
    button.addEventListener("click", () => {
      const next = document.documentElement.dataset.theme === "light" ? "dark" : "light";
      setTheme(next);
      storeTheme(next);
    });
  }

  function wireLinks() {
    selectAll("[data-repo-link]").forEach((link) => {
      link.href = REPO_URL;
    });
    selectAll("[data-doc]").forEach((link) => {
      link.href = `${REPO_URL}/blob/main/${link.dataset.doc}`;
    });
  }

  function focusable(container) {
    return selectAll("a[href], button:not([disabled]), input:not([disabled])", container)
      .filter((element) => element.getClientRects().length > 0);
  }

  function trapFocus(event, container) {
    if (event.key !== "Tab") return false;
    const items = focusable(container);
    if (!items.length) return false;
    const first = items[0];
    const last = items[items.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
    return true;
  }

  function initMobileNav() {
    const button = select("#menu-button");
    const panel = select("#nav-links");
    const nav = select(".site-nav");
    if (!button || !panel || !nav) return;

    const close = () => {
      panel.classList.remove("is-open");
      button.setAttribute("aria-expanded", "false");
    };

    button.addEventListener("click", () => {
      const open = !panel.classList.contains("is-open");
      panel.classList.toggle("is-open", open);
      button.setAttribute("aria-expanded", String(open));
      if (open) {
        const first = focusable(panel)[0];
        if (first) first.focus();
      }
    });

    panel.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        close();
        button.focus();
      } else {
        trapFocus(event, panel);
      }
    });

    document.addEventListener("click", (event) => {
      if (panel.classList.contains("is-open") && !nav.contains(event.target)) close();
    });

    selectAll(".navlink", panel).forEach((link) => link.addEventListener("click", close));
  }

  function initMoreMenu() {
    const button = select("#more-button");
    const menu = select("#more-menu");
    const wrap = select(".more-wrap");
    if (!button || !menu || !wrap) return;

    const close = (restoreFocus) => {
      menu.hidden = true;
      button.setAttribute("aria-expanded", "false");
      if (restoreFocus) button.focus();
    };

    button.addEventListener("click", () => {
      const open = menu.hidden;
      menu.hidden = !open;
      button.setAttribute("aria-expanded", String(open));
      if (open) {
        const first = focusable(menu)[0];
        if (first) first.focus();
      }
    });

    menu.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        close(true);
      } else {
        trapFocus(event, menu);
      }
    });

    document.addEventListener("click", (event) => {
      if (!menu.hidden && !wrap.contains(event.target)) close(false);
    });

    selectAll("a", menu).forEach((link) => link.addEventListener("click", () => close(false)));
  }

  function initScrollSpy() {
    const links = selectAll(".navlink");
    if (!links.length || !("IntersectionObserver" in window)) return;
    const sections = links
      .map((link) => select(link.getAttribute("href")))
      .filter(Boolean);

    const observer = new IntersectionObserver((entries) => {
      const visible = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
      if (!visible) return;
      links.forEach((link) => {
        if (link.getAttribute("href") === `#${visible.target.id}`) {
          link.setAttribute("aria-current", "true");
        } else {
          link.removeAttribute("aria-current");
        }
      });
    }, { rootMargin: "-25% 0px -55% 0px", threshold: [0, 0.1, 0.5] });

    sections.forEach((section) => observer.observe(section));
  }

  function createSvg(tag, attributes) {
    const element = document.createElementNS(SVG_NS, tag);
    Object.entries(attributes).forEach(([key, value]) => element.setAttribute(key, String(value)));
    return element;
  }

  function initDiagram() {
    const canvas = select("#diagram-canvas");
    const svg = select("#flow-connectors");
    const flowNodes = selectAll("#flow-list .flow-node");
    if (!canvas || !svg || !flowNodes.length) return;

    let activeStep = 0;
    let replayTimer = null;
    let typingTimer = null;
    let drawerTrigger = null;

    const terminal = select("#terminal-lines");
    const range = select("#replay-range");
    const playButton = select("#play-button");
    const pauseButton = select("#pause-button");
    const drawer = select("#detail-drawer");
    const drawerTitle = select("#drawer-title");
    const drawerBody = select("#drawer-body");

    const nodeById = (id) => select(`[data-detail="${id}"]`);
    const stopById = (id) => select(`[data-stop-for="${id}"]`);

    function rectFor(element, base) {
      const rect = element.getBoundingClientRect();
      return {
        left: rect.left - base.left,
        right: rect.right - base.left,
        top: rect.top - base.top,
        bottom: rect.bottom - base.top,
        cx: rect.left - base.left + rect.width / 2,
        cy: rect.top - base.top + rect.height / 2
      };
    }

    function flowPath(from, to) {
      return `M ${from.cx} ${from.bottom} L ${to.cx} ${to.top}`;
    }

    function linkPath(from, to) {
      const forward = to.cx >= from.cx;
      const startX = forward ? from.right : from.left;
      const endX = forward ? to.left : to.right;
      const offset = Math.max(12, Math.abs(endX - startX) * 0.35) * (forward ? 1 : -1);
      return `M ${startX} ${from.cy} C ${startX + offset} ${from.cy}, ${endX - offset} ${to.cy}, ${endX} ${to.cy}`;
    }

    function lanePath(from, to) {
      const x = (from.cx + to.cx) / 2;
      return `M ${x} ${from.bottom} C ${x} ${from.bottom + 12}, ${x} ${to.top - 12}, ${x} ${to.top}`;
    }

    function addEdge(fromEl, toEl, mode, fromId, toId) {
      if (!fromEl || !toEl) return;
      const base = canvas.getBoundingClientRect();
      const from = rectFor(fromEl, base);
      const to = rectFor(toEl, base);
      let d = linkPath(from, to);
      if (mode === "flow") d = flowPath(from, to);
      if (mode === "lane") d = lanePath(from, to);
      const path = createSvg("path", {
        d,
        class: `edge--${mode}`,
        "data-from": fromId,
        "data-to": toId
      });
      svg.append(path);
      if (mode === "flow" && !reducedMotion) {
        const circle = createSvg("circle", { r: 3, class: "packet" });
        const motion = createSvg("animateMotion", {
          dur: `${2.6 + Math.random() * 0.6}s`,
          repeatCount: "indefinite",
          path: d
        });
        circle.append(motion);
        svg.append(circle);
      }
    }

    function drawConnectors() {
      svg.replaceChildren();
      svg.setAttribute("viewBox", `0 0 ${canvas.clientWidth} ${canvas.clientHeight}`);

      flowNodes.forEach((node, index) => {
        const next = flowNodes[index + 1];
        if (next) addEdge(node, next, "flow", node.dataset.detail, next.dataset.detail);
      });

      addEdge(nodeById("airflow"), nodeById("main"), "lane", "airflow", "main");
      addEdge(nodeById("main"), nodeById("run-order"), "lane", "main", "run-order");
      addEdge(nodeById("run-order"), nodeById("extract"), "orch", "run-order", "extract");
      addEdge(nodeById("retry"), nodeById("extract"), "orch", "retry", "extract");
      addEdge(nodeById("watchdog"), nodeById("audit"), "lane", "watchdog", "audit");
      addEdge(nodeById("weekly"), nodeById("consumer"), "orch", "weekly", "consumer");

      ["raw", "staging", "analytics", "marts"].forEach((id) => {
        addEdge(nodeById(id), nodeById("audit"), "audit", id, "audit");
      });

      ["dq-raw", "dq-staging", "dq-analytics", "dq-marts"].forEach((id) => {
        addEdge(nodeById(id), stopById(id), "failure", id, `stop-${id}`);
      });
    }

    function highlight(id, stepIndex) {
      selectAll(".flow-node, .lane-node").forEach((node) => {
        node.classList.toggle("is-linked", node.dataset.detail === id);
      });
      svg.querySelectorAll("path").forEach((path) => {
        const linked = path.dataset.from === id || path.dataset.to === id;
        const active = stepIndex !== undefined && (
          path.dataset.from === STEPS[stepIndex][0] || path.dataset.to === STEPS[stepIndex][0]
        );
        path.classList.toggle("is-linked", linked);
        if (stepIndex !== undefined) path.classList.toggle("is-active", active);
      });
      flowNodes.forEach((node, index) => {
        node.classList.toggle("is-current", index === stepIndex);
      });
    }

    function openDrawer(id) {
      if (!drawer || !drawerTitle || !drawerBody) return;
      const node = nodeById(id);
      if (!node) return;
      const heading = select("strong", node) || select("span", node);
      drawerTitle.textContent = heading ? heading.textContent : id;
      drawerBody.textContent = DETAILS[id] || "No detail is recorded for this node.";
      drawer.setAttribute("aria-hidden", "false");
    }

    function closeDrawer() {
      if (!drawer) return;
      const hadFocus = drawer.contains(document.activeElement);
      drawer.setAttribute("aria-hidden", "true");
      if (hadFocus && drawerTrigger) drawerTrigger.focus();
    }

    function renderTerminal(index) {
      if (!terminal) return;
      window.clearInterval(typingTimer);
      terminal.replaceChildren();
      const lines = STEPS.slice(0, index + 1).map((entry) => entry[1]);
      if (reducedMotion) {
        lines.forEach((line) => {
          const span = document.createElement("span");
          span.className = "terminal-line";
          span.textContent = line;
          terminal.append(span);
        });
        return;
      }
      lines.forEach((line, lineIndex) => {
        const span = document.createElement("span");
        span.className = "terminal-line";
        terminal.append(span);
        if (lineIndex < lines.length - 1) {
          span.textContent = line;
          return;
        }
        let cursor = 0;
        typingTimer = window.setInterval(() => {
          cursor += 1;
          span.textContent = line.slice(0, cursor);
          if (cursor >= line.length) window.clearInterval(typingTimer);
        }, 12);
      });
    }

    function setStep(index) {
      activeStep = Math.max(0, Math.min(STEPS.length - 1, index));
      if (range) range.value = String(activeStep);
      renderTerminal(activeStep);
      highlight(STEPS[activeStep][0], activeStep);
    }

    function stopReplay() {
      if (replayTimer) window.clearInterval(replayTimer);
      replayTimer = null;
    }

    function playReplay() {
      stopReplay();
      setStep(activeStep);
      if (reducedMotion) {
        setStep(STEPS.length - 1);
        return;
      }
      replayTimer = window.setInterval(() => {
        if (activeStep >= STEPS.length - 1) {
          stopReplay();
          return;
        }
        setStep(activeStep + 1);
      }, 1200);
    }

    selectAll(".flow-node, .lane-node").forEach((node) => {
      node.addEventListener("click", () => {
        drawerTrigger = node;
        const id = node.dataset.detail;
        const stepIndex = STEPS.findIndex((entry) => entry[0] === id);
        if (stepIndex >= 0) setStep(stepIndex);
        else highlight(id);
        openDrawer(id);
      });
    });

    if (playButton) playButton.addEventListener("click", playReplay);
    if (pauseButton) pauseButton.addEventListener("click", stopReplay);
    if (range) range.addEventListener("input", () => {
      stopReplay();
      setStep(Number(range.value));
    });
    if (select("#drawer-close")) select("#drawer-close").addEventListener("click", closeDrawer);

    document.addEventListener("keydown", (event) => {
      if (event.key === "Escape") closeDrawer();
    });

    window.addEventListener("resize", () => {
      window.clearTimeout(drawConnectors.pending);
      drawConnectors.pending = window.setTimeout(drawConnectors, 120);
    });

    if ("ResizeObserver" in window) {
      new ResizeObserver(drawConnectors).observe(canvas);
    }
    if (document.fonts && document.fonts.ready) {
      document.fonts.ready.then(drawConnectors);
    }

    window.requestAnimationFrame(() => {
      drawConnectors();
      setStep(0);
    });
  }

  function initCopyButtons() {
    selectAll("[data-copy]").forEach((button) => {
      button.addEventListener("click", async () => {
        const value = button.dataset.copy;
        try {
          if (navigator.clipboard && navigator.clipboard.writeText) {
            await navigator.clipboard.writeText(value);
          } else {
            const input = document.createElement("textarea");
            input.value = value;
            input.className = "visually-hidden";
            document.body.append(input);
            input.select();
            document.execCommand("copy");
            input.remove();
          }
          button.dataset.state = "copied";
          button.textContent = "Copied";
          window.setTimeout(() => {
            button.dataset.state = "idle";
            button.textContent = "Copy";
          }, 1400);
        } catch {
          button.textContent = "Copy unavailable";
          window.setTimeout(() => {
            button.textContent = "Copy";
          }, 1400);
        }
      });
    });
  }

  initTheme();
  wireLinks();
  initMobileNav();
  initMoreMenu();
  initScrollSpy();
  initDiagram();
  initCopyButtons();
})();
