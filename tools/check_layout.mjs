import { spawn } from "node:child_process";
import { constants } from "node:fs";
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const ROOT = path.resolve(import.meta.dirname, "..");
const DEFAULT_URL = pathToFileURL(path.join(ROOT, "site", "index.html")).href;
const DEFAULT_OUT = path.join(ROOT, "docs", "site-qa");
const DEFAULT_WIDTHS = [360, 768, 1024, 1440, 1920];

const MEASURE = String.raw`(() => {
  const vw = window.innerWidth;
  const docEl = document.documentElement;
  const body = document.body;
  const round = (n) => Math.round(n * 10) / 10;
  const rect = (el) => el.getBoundingClientRect();
  const intersect = (a, b) => {
    const w = Math.min(a.right, b.right) - Math.max(a.left, b.left);
    const h = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
    return w > 0 && h > 0 ? { w, h, area: w * h } : { w: 0, h: 0, area: 0 };
  };
  const label = (el) => ({
    tag: el.tagName.toLowerCase(),
    id: el.id || "",
    cls: typeof el.className === "string" ? el.className.slice(0, 120) : "",
    text: (el.textContent || "").trim().replace(/\s+/g, " ").slice(0, 100)
  });
  const isVisible = (el) => {
    let node = el;
    while (node && node !== document.body) {
      if (node.matches && node.matches("details:not([open])")) return false;
      const style = getComputedStyle(node);
      if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
      node = node.parentElement;
    }
    return true;
  };

  const overflow = {
    innerWidth: vw,
    documentScrollWidth: docEl.scrollWidth,
    bodyScrollWidth: body.scrollWidth,
    horizontal: Math.max(docEl.scrollWidth, body.scrollWidth) > vw + 1,
    offenders: []
  };
  for (const el of document.querySelectorAll("body *")) {
    const r = rect(el);
    if (r.width < 1 || r.height < 1) continue;
    if (r.right <= vw + 1 && r.left >= -1) continue;
    const style = getComputedStyle(el);
    if (style.position === "fixed" && el.classList.contains("skip-link")) continue;
    if (el.closest(".diagram-scroll") || el.closest(".tablewrap") || el.closest("pre")) continue;
    overflow.offenders.push({ ...label(el), left: round(r.left), right: round(r.right) });
  }
  overflow.offenders.sort((a, b) => b.right - a.right);
  overflow.offenders = overflow.offenders.slice(0, 30);

  const internalScrollers = [...document.querySelectorAll("body *")].filter((el) => {
    const style = getComputedStyle(el);
    return (style.overflowX === "auto" || style.overflowX === "scroll") && el.scrollWidth > el.clientWidth + 1;
  }).map((el) => ({
    ...label(el),
    scrollWidth: el.scrollWidth,
    clientWidth: el.clientWidth
  })).slice(0, 30);

  const textEls = [...document.querySelectorAll("p,span,a,b,strong,small,code,h1,h2,h3,h4,h5,h6,td,th,li,button,label,figcaption,caption")].filter((el) => {
    if (el.closest("svg")) return false;
    if (![...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) return false;
    if (!isVisible(el)) return false;
    const r = rect(el);
    return r.width > 1 && r.height > 1;
  });
  const textOverlaps = [];
  for (let i = 0; i < textEls.length; i += 1) {
    for (let j = i + 1; j < textEls.length; j += 1) {
      const a = textEls[i];
      const b = textEls[j];
      if (a.contains(b) || b.contains(a)) continue;
      const x = intersect(rect(a), rect(b));
      if (x.w > 2 && x.h > 2 && x.area > 12) {
        textOverlaps.push({ a: label(a), b: label(b), width: round(x.w), height: round(x.h) });
      }
    }
  }

  const svgIssues = [];
  const svgs = [...document.querySelectorAll("svg")];
  for (const svg of svgs) {
    const svgId = svg.id || svg.getAttribute("aria-labelledby") || label(svg).cls;
    const svgRect = rect(svg);
    const texts = [...svg.querySelectorAll("text")];
    for (const text of texts) {
      const r = rect(text);
      if (r.width < 1 || r.height < 1) continue;
      const outside = r.left < svgRect.left - 1 || r.right > svgRect.right + 1 || r.top < svgRect.top - 1 || r.bottom > svgRect.bottom + 1;
      if (outside) svgIssues.push({ svg: svgId, kind: "outside-svg", text: (text.textContent || "").trim(), rect: { left: round(r.left), right: round(r.right), top: round(r.top), bottom: round(r.bottom) } });
    }
    for (const group of svg.querySelectorAll("g.node")) {
      const box = group.querySelector("rect.box");
      if (!box) continue;
      const br = rect(box);
      for (const text of group.querySelectorAll("text")) {
        const r = rect(text);
        if (r.width < 1 || r.height < 1) continue;
        if (r.left < br.left - 1 || r.right > br.right + 1 || r.top < br.top - 1 || r.bottom > br.bottom + 1) {
          svgIssues.push({ svg: svgId, kind: "outside-node-box", node: group.getAttribute("data-id") || "", text: (text.textContent || "").trim() });
        }
      }
    }
    for (let i = 0; i < texts.length; i += 1) {
      for (let j = i + 1; j < texts.length; j += 1) {
        const x = intersect(rect(texts[i]), rect(texts[j]));
        if (x.w > 1 && x.h > 1 && x.area > 4) {
          svgIssues.push({ svg: svgId, kind: "text-text", a: (texts[i].textContent || "").trim(), b: (texts[j].textContent || "").trim(), width: round(x.w), height: round(x.h) });
        }
      }
    }
    const boxes = [...svg.querySelectorAll("g.node rect.box")].map((box) => ({ box, group: box.closest("g.node"), r: rect(box) }));
    for (const text of texts) {
      const ownGroup = text.closest("g.node");
      const tr = rect(text);
      for (const item of boxes) {
        if (item.group === ownGroup) continue;
        const x = intersect(tr, item.r);
        if (x.w > 1 && x.h > 1 && x.area > 4) {
          svgIssues.push({ svg: svgId, kind: "text-in-other-node", text: (text.textContent || "").trim(), node: item.group.getAttribute("data-id") || "", width: round(x.w), height: round(x.h) });
        }
      }
    }
  }

  return { overflow, internalScrollers, textOverlaps, svgIssues, cls: window.__cls || 0, shifts: window.__shifts || [] };
})()`;

function parseArgs(argv) {
  const parsed = { url: DEFAULT_URL, out: DEFAULT_OUT, widths: DEFAULT_WIDTHS, prefix: "before", noJs: false, reducedMotion: false, keyboard: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--url") parsed.url = argv[++i];
    else if (arg === "--out") parsed.out = path.resolve(argv[++i]);
    else if (arg === "--widths") parsed.widths = argv[++i].split(",").map(Number).filter(Boolean);
    else if (arg === "--prefix") parsed.prefix = argv[++i];
    else if (arg === "--no-js") parsed.noJs = true;
    else if (arg === "--reduced-motion") parsed.reducedMotion = true;
    else if (arg === "--keyboard") parsed.keyboard = true;
    else if (arg === "--help") {
      console.log("Usage: node tools/check_layout.mjs [--url file-or-http-url] [--out dir] [--widths 360,768,1024,1440,1920] [--prefix before|after] [--no-js] [--reduced-motion] [--keyboard]");
      process.exit(0);
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!parsed.widths.length) throw new Error("No widths supplied");
  return parsed;
}

async function findBrowser() {
  const candidates = process.platform === "win32"
    ? [
        "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
        "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
        "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe"
      ]
    : ["/usr/bin/google-chrome", "/usr/bin/chromium", "/usr/bin/chromium-browser"];
  for (const candidate of candidates) {
    try {
      await access(candidate, constants.X_OK);
      return candidate;
    } catch {}
  }
  throw new Error("No Chrome or Edge executable found");
}

async function startBrowser(executable) {
  const profile = await mkdtemp(path.join(os.tmpdir(), "banking-site-qa-"));
  const child = spawn(executable, [
    "--headless=new",
    "--disable-gpu",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "about:blank"
  ], { stdio: ["ignore", "ignore", "pipe"], windowsHide: true });
  let stderr = "";
  child.stderr.on("data", (chunk) => { stderr += String(chunk); });
  const portFile = path.join(profile, "DevToolsActivePort");
  let port = "";
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      const content = await readFile(portFile, "utf8");
      port = content.split(/\r?\n/)[0];
      if (port) break;
    } catch {}
    if (child.exitCode !== null) throw new Error(`Browser exited: ${stderr}`);
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (!port) throw new Error(`Browser debug port not ready: ${stderr}`);
  const version = await fetch(`http://127.0.0.1:${port}/json/version`).then((r) => r.json());
  return { child, profile, websocketUrl: version.webSocketDebuggerUrl };
}

class Cdp {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
    ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id) {
        const entry = this.pending.get(message.id);
        if (!entry) return;
        this.pending.delete(message.id);
        if (message.error) entry.reject(new Error(`${message.error.message}: ${JSON.stringify(message.error.data || {})}`));
        else entry.resolve(message.result);
        return;
      }
      for (const listener of this.listeners.get(message.method) || []) listener(message.params, message.sessionId);
    });
  }

  send(method, params = {}, sessionId) {
    return new Promise((resolve, reject) => {
      const id = this.nextId;
      this.nextId += 1;
      this.pending.set(id, { resolve, reject });
      const message = { id, method, params };
      if (sessionId) message.sessionId = sessionId;
      this.ws.send(JSON.stringify(message));
    });
  }

  on(method, listener) {
    const existing = this.listeners.get(method) || [];
    existing.push(listener);
    this.listeners.set(method, existing);
  }

  once(method, timeoutMs = 15000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${method}`)), timeoutMs);
      const listener = () => {
        clearTimeout(timer);
        resolve();
      };
      this.on(method, listener);
    });
  }

  close() {
    this.ws.close();
  }
}

async function connect(websocketUrl) {
  const ws = new WebSocket(websocketUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", reject, { once: true });
  });
  return new Cdp(ws);
}

async function pressTab(cdp, sessionId) {
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyDown",
    key: "Tab",
    code: "Tab",
    windowsVirtualKeyCode: 9,
    nativeVirtualKeyCode: 9
  }, sessionId);
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyUp",
    key: "Tab",
    code: "Tab",
    windowsVirtualKeyCode: 9,
    nativeVirtualKeyCode: 9
  }, sessionId);
}

async function focusState(cdp, sessionId) {
  const evaluated = await cdp.send("Runtime.evaluate", {
    expression: `(() => {
      const el = document.activeElement;
      const panel = document.querySelector("#nav-links");
      return {
        tag: el ? el.tagName.toLowerCase() : "",
        text: el && el.textContent ? el.textContent.trim().replace(/\\s+/g, " ").slice(0, 60) : "",
        cls: el && typeof el.className === "string" ? el.className : "",
        inNavPanel: Boolean(el && panel && panel.contains(el))
      };
    })()`,
    returnByValue: true
  }, sessionId);
  return evaluated.result.value;
}

async function measureKeyboard(cdp, sessionId) {
  const focusPath = [];
  for (let index = 0; index < 12; index += 1) {
    await pressTab(cdp, sessionId);
    focusPath.push(await focusState(cdp, sessionId));
  }
  const trapPath = [];
  await cdp.send("Runtime.evaluate", { expression: "document.querySelector('#menu-button').click()" }, sessionId);
  for (let index = 0; index < 8; index += 1) {
    await pressTab(cdp, sessionId);
    trapPath.push(await focusState(cdp, sessionId));
  }
  await cdp.send("Runtime.evaluate", { expression: "document.querySelector('#menu-button').click()" }, sessionId);
  return {
    focusPath,
    trapPath,
    passed: focusPath[0]?.cls === "skip-link" && trapPath.every((item) => item.inNavPanel)
  };
}

async function main() {
  const { url, out, widths, prefix, noJs, reducedMotion, keyboard } = parseArgs(process.argv.slice(2));
  await mkdir(out, { recursive: true });
  const browser = await startBrowser(await findBrowser());
  const cdp = await connect(browser.websocketUrl);
  const report = { url, generatedAt: new Date().toISOString(), browser: "headless Chrome/Edge via CDP", prefix, noJs, reducedMotion, keyboard, runs: [] };

  try {
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    for (const method of ["Page.enable", "Runtime.enable", "Network.enable", "Log.enable"]) {
      await cdp.send(method, {}, sessionId);
    }
    await cdp.send("Page.addScriptToEvaluateOnNewDocument", {
      source: "window.__cls=0;window.__shifts=[];new PerformanceObserver((list)=>{for(const entry of list.getEntries()){if(!entry.hadRecentInput){window.__cls+=entry.value;window.__shifts.push({value:entry.value,sources:(entry.sources||[]).map((source)=>({tag:source.node&&source.node.tagName,cls:source.node&&typeof source.node.className==='string'?source.node.className:'',text:source.node&&source.node.textContent?source.node.textContent.trim().replace(/\\s+/g,' ').slice(0,60):'',previousRect:source.previousRect,currentRect:source.currentRect})).slice(0,5)});}}}).observe({type:'layout-shift',buffered:true});"
    }, sessionId);
    if (noJs) await cdp.send("Emulation.setScriptExecutionDisabled", { value: true }, sessionId);
    if (reducedMotion) {
      await cdp.send("Emulation.setEmulatedMedia", {
        features: [{ name: "prefers-reduced-motion", value: "reduce" }]
      }, sessionId);
    }

    let consoleErrors = [];
    let failedRequests = [];
    let transferBytesExcludingFonts = 0;
    const requestUrls = new Map();
    cdp.on("Network.requestWillBeSent", (params) => requestUrls.set(params.requestId, params.request.url));
    cdp.on("Network.loadingFinished", (params) => {
      const requestUrl = requestUrls.get(params.requestId) || "";
      if (/fonts\.(googleapis|gstatic)\.com|\.(woff2?|ttf|otf)(\?|$)/i.test(requestUrl)) return;
      transferBytesExcludingFonts += params.encodedDataLength || 0;
    });
    cdp.on("Network.loadingFailed", (params) => {
      failedRequests.push({ url: requestUrls.get(params.requestId) || "", errorText: params.errorText || "", type: params.type || "" });
    });
    cdp.on("Runtime.consoleAPICalled", (params) => {
      if (params.type !== "error") return;
      consoleErrors.push({
        text: (params.args || []).map((arg) => arg.value || arg.description || "").join(" "),
        source: params.stackTrace?.callFrames?.[0]?.url || ""
      });
    });
    cdp.on("Runtime.exceptionThrown", (params) => {
      consoleErrors.push({
        text: params.exceptionDetails.exception?.description || params.exceptionDetails.text || "",
        source: params.exceptionDetails.url || ""
      });
    });
    cdp.on("Log.entryAdded", (params) => {
      if (params.entry.level !== "error") return;
      consoleErrors.push({ text: params.entry.text || "", source: params.entry.url || "" });
    });

    for (const width of widths) {
      consoleErrors = [];
      failedRequests = [];
      transferBytesExcludingFonts = 0;
      requestUrls.clear();
      await cdp.send("Emulation.setDeviceMetricsOverride", {
        width,
        height: 900,
        deviceScaleFactor: 1,
        mobile: false
      }, sessionId);
      const loaded = cdp.once("Page.loadEventFired", 15000);
      const separator = url.includes("?") ? "&" : "?";
      await cdp.send("Page.navigate", { url: `${url}${separator}qa=${width}` }, sessionId);
      await loaded;
      await new Promise((resolve) => setTimeout(resolve, 900));
      const evaluated = await cdp.send("Runtime.evaluate", {
        expression: MEASURE,
        awaitPromise: true,
        returnByValue: true
      }, sessionId);
      if (evaluated.exceptionDetails) throw new Error(evaluated.exceptionDetails.text || "Measurement failed");
      const capture = await cdp.send("Page.captureScreenshot", {
        format: "png",
        captureBeyondViewport: true,
        fromSurface: true
      }, sessionId);
      const screenshot = path.join(out, `${prefix}-${width}.png`);
      await writeFile(screenshot, Buffer.from(capture.data, "base64"));
      const metrics = evaluated.result.value;
      const keyboardState = keyboard && !noJs ? await measureKeyboard(cdp, sessionId) : null;
      report.runs.push({
        width,
        screenshot: path.relative(ROOT, screenshot).replace(/\\/g, "/"),
        horizontalScroll: metrics.overflow.horizontal,
        scrollWidth: Math.max(metrics.overflow.documentScrollWidth, metrics.overflow.bodyScrollWidth),
        internalHorizontalScrollers: metrics.internalScrollers,
        visibleTextOverlaps: metrics.textOverlaps,
        svgIssues: metrics.svgIssues,
        overflowOffenders: metrics.overflow.offenders,
        cls: metrics.cls,
        shifts: metrics.shifts,
        transferBytesExcludingFonts,
        consoleErrors,
        failedRequests,
        keyboard: keyboardState,
        passed: !metrics.overflow.horizontal && !metrics.internalScrollers.length && !metrics.textOverlaps.length && !metrics.svgIssues.length && !consoleErrors.length && !failedRequests.length && metrics.cls < 0.05 && transferBytesExcludingFonts < 300 * 1024 && (!keyboardState || keyboardState.passed)
      });
    }
    report.passed = report.runs.every((run) => run.passed);
    const reportName = prefix === "before" ? "report.json" : `${prefix}-report.json`;
    await writeFile(path.join(out, reportName), `${JSON.stringify(report, null, 2)}\n`);
    console.log(JSON.stringify({
      passed: report.passed,
      runs: report.runs.map((run) => ({
        width: run.width,
        horizontalScroll: run.horizontalScroll,
        internalHorizontalScrollers: run.internalHorizontalScrollers.length,
        visibleTextOverlaps: run.visibleTextOverlaps.length,
        svgIssues: run.svgIssues.length,
        consoleErrors: run.consoleErrors.length,
        failedRequests: run.failedRequests.length,
        cls: run.cls,
        transferBytesExcludingFonts: run.transferBytesExcludingFonts,
        keyboardPassed: run.keyboard ? run.keyboard.passed : null,
        screenshot: run.screenshot
      }))
    }, null, 2));
  } finally {
    try {
      await cdp.send("Browser.close", {}, undefined);
    } catch {}
    cdp.close();
    browser.child.kill();
    if (process.platform === "win32" && browser.child.pid) {
      await new Promise((resolve) => {
        const killer = spawn("taskkill", ["/PID", String(browser.child.pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
        killer.on("exit", resolve);
        killer.on("error", resolve);
      });
    }
    await rm(browser.profile, { recursive: true, force: true }).catch(() => {});
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
