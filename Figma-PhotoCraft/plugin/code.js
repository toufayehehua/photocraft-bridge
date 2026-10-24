// PhotoCraft Bridge 1.1.0 (Build 3).
const BRIDGE_URL = "http://localhost:47836";
const TOKEN_KEY = "photocraft.bridge.token.v1";
const DATA_KEY = "photocraft.sessions.v1";
const documentId = "runtime-" + Date.now() + "-" + Math.random().toString(36).slice(2) + "-" + Math.random().toString(36).slice(2);
let bridgeToken = "";
let sessions = [];
let polling = false;
let closed = false;
let awaitingPairing = false;
let pairing = false;

function bridgeError(message) {
  const error = new Error(message);
  error.bridgeMessage = message;
  return error;
}

async function request(path, body, binary, token = bridgeToken) {
  let response;
  try {
    response = await fetch(BRIDGE_URL + path, {
      method: "POST",
      headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json" },
      body: JSON.stringify(body)
    });
  } catch (_) {
    throw bridgeError("无法连接本机桥接程序");
  }
  if (!response.ok) {
    let message = "PhotoCraft 桥接连接失败（" + response.status + "）";
    try {
      const messages = { "invalid-image": "无法读取图片", "open-failed": "无法打开 PhotoCraft" };
      const error = (await response.json()).error;
      if (Object.prototype.hasOwnProperty.call(messages, error)) message = messages[error];
    } catch (_) {}
    throw bridgeError(message);
  }
  try {
    return binary ? new Uint8Array(await response.arrayBuffer()) : await response.json();
  } catch (_) {
    throw bridgeError("无法连接本机桥接程序");
  }
}

async function verifyToken(token) {
  const status = await request("/status", {}, false, token);
  if (!status || typeof status.version !== "string" || !Array.isArray(status.jobs)) {
    throw bridgeError("无法连接本机桥接程序");
  }
}

async function startEditing() {
  figma.ui.hide();
  try {
    const saved = JSON.parse(figma.root.getPluginData(DATA_KEY) || "[]");
    sessions = Array.isArray(saved) ? saved.filter(item => item.document === documentId) : [];
    await editSelection();
    if (!closed) poll();
  } catch (error) {
    if (!closed) figma.closePlugin(error.message || "无法打开 PhotoCraft");
  }
}

async function pair(token) {
  if (closed || !awaitingPairing || pairing) return;
  pairing = true;
  try {
    if (typeof token !== "string" || !/^[0-9a-fA-F]{64}$/.test(token.trim())) {
      throw bridgeError("配对码无效");
    }
    token = token.trim().toLowerCase();
    await verifyToken(token);
    if (closed) return;
    await figma.clientStorage.setAsync(TOKEN_KEY, token);
    if (closed) return;
    bridgeToken = token;
    awaitingPairing = false;
  } catch (error) {
    if (!closed) figma.ui.postMessage({ type: "pair-error", message: error.bridgeMessage || "无法保存配对码" });
    return;
  } finally {
    pairing = false;
  }
  await startEditing();
}

function persist() {
  figma.root.setPluginData(DATA_KEY, JSON.stringify(sessions));
}

function imagePaint(node, index) {
  if (!node || node.removed || !("fills" in node) || node.fills === figma.mixed) return null;
  const paint = node.fills[index];
  return paint && paint.type === "IMAGE" ? paint : null;
}

function fillLayout(node, index) {
  return JSON.stringify(node.fills.map((paint, slot) => ({
    type: paint.type,
    asset: paint.type === "IMAGE" && slot !== index ? paint.imageHash : null,
    visible: paint.visible !== false
  })));
}

function trackedPaint(node, session) {
  const paint = imagePaint(node, session.fill);
  return paint && (!session.layout || fillLayout(node, session.fill) === session.layout) ? paint : null;
}

async function acknowledge(update, status, asset) {
  await request("/ack", {
    id: update.id, revision: update.revision, previous: update.asset,
    asset: asset || update.asset, status
  });
}

async function flushAcknowledgement(session) {
  if (!session.pendingAck || closed) return;
  await request("/ack", session.pendingAck);
  if (closed) return;
  delete session.pendingAck;
  persist();
}

async function applyUpdate(update) {
  if (closed) return;
  const session = sessions.find(item => item.id === update.id && item.node === update.node);
  if (!session) return;
  const node = await figma.getNodeByIdAsync(session.node);
  if (closed) return;
  const paint = trackedPaint(node, session);
  if (!paint) {
    await acknowledge(update, node && !node.removed ? "stale" : "deleted");
    if (closed) return;
    sessions = sessions.filter(item => item.id !== session.id);
    persist();
    return;
  }
  // Retry an interrupted acknowledgement without applying the same revision twice.
  if (session.revision === update.revision && paint.imageHash === session.asset) {
    await acknowledge(update, "applied", session.asset);
    return;
  }
  // Undo, replacement, or a moved fill ends this association instead of overwriting new work.
  if (paint.imageHash !== session.asset || update.asset !== session.asset) {
    await acknowledge(update, "stale");
    if (closed) return;
    sessions = sessions.filter(item => item.id !== session.id);
    persist();
    return;
  }
  const bytes = await request("/image", { id: update.id, revision: update.revision }, true);
  if (closed) return;
  const current = trackedPaint(node, session);
  if (!current || current.imageHash !== session.asset) return;
  const image = figma.createImage(bytes);
  const fills = node.fills.map(paint => Object.assign({}, paint));
  fills[session.fill].imageHash = image.hash;
  node.fills = fills;
  session.asset = image.hash;
  session.revision = update.revision;
  session.pendingAck = {
    id: update.id, revision: update.revision, previous: update.asset,
    asset: image.hash, status: "applied"
  };
  persist();
  figma.commitUndo();
  await flushAcknowledgement(session);
}

async function poll() {
  if (polling || closed) return;
  polling = true;
  try {
    for (const session of sessions) await flushAcknowledgement(session);
    if (closed) return;
    const data = await request("/pending", { document: documentId });
    if (closed) return;
    for (const update of data.updates || []) await applyUpdate(update);
  } catch (error) {
    // A temporary disconnect leaves the saved revision available for the next poll.
    console.warn("PhotoCraft:", error.message);
  } finally {
    polling = false;
    if (!closed) setTimeout(poll, 1000);
  }
}

async function editSelection() {
  const selected = figma.currentPage.selection;
  if (selected.length !== 1) throw new Error("请选择单个图片图层");
  const node = selected[0];
  if (!("fills" in node) || node.fills === figma.mixed) throw new Error("请选择图片图层本身");
  const indices = node.fills.reduce((result, paint, index) => {
    if (paint.type === "IMAGE" && paint.visible !== false && paint.imageHash) result.push(index);
    return result;
  }, []);
  if (indices.length !== 1) throw new Error("请选择只有一个可见图片填充的图层");
  const fill = indices[0];
  const asset = node.fills[fill].imageHash;
  const layout = fillLayout(node, fill);
  const image = figma.getImageByHash(asset);
  if (!image) throw new Error("无法读取所选图片");
  const bytes = await image.getBytesAsync();
  if (closed) return;
  const beforeLaunch = imagePaint(node, fill);
  if (!beforeLaunch || beforeLaunch.imageHash !== asset || fillLayout(node, fill) !== layout) return;
  if (bytes.length > 64 * 1024 * 1024) throw new Error("图片超过 64 MB");
  const result = await request("/edit", {
    document: documentId, node: node.id, asset, name: node.name,
    image: figma.base64Encode(bytes)
  });
  if (closed) return;
  // The selection may change while PhotoCraft launches; the captured node is the target.
  const current = imagePaint(node, fill);
  if (!current || current.imageHash !== asset || fillLayout(node, fill) !== layout) return;
  sessions = sessions.filter(item => item.node !== node.id);
  sessions.push({ document: documentId, node: node.id, id: result.id, fill, asset, layout, revision: "" });
  node.setRelaunchData({ edit: "" });
  persist();
  figma.commitUndo();
}

(async function () {
  figma.showUI(__html__, { visible: false, width: 340, height: 180, themeColors: true });
  figma.on("close", () => { closed = true; });
  figma.ui.onmessage = message => {
    if (message && message.type === "pair") pair(message.token);
  };
  try {
    const token = await figma.clientStorage.getAsync(TOKEN_KEY);
    if (closed) return;
    if (typeof token === "string" && /^[0-9a-f]{64}$/.test(token)) {
      await verifyToken(token);
      if (closed) return;
      bridgeToken = token;
      await startEditing();
      return;
    }
  } catch (error) {
    if (closed) return;
    figma.ui.postMessage({ type: "pair-error", message: error.bridgeMessage || "无法读取配对码" });
  }
  if (closed) return;
  awaitingPairing = true;
  figma.ui.show();
})();
