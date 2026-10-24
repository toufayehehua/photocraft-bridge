const application = require("application");
const scenegraph = require("scenegraph");
const uxp = require("uxp");
const fs = uxp.storage.localFileSystem;
let bridge;

function validBridge(value) {
    return value && Number.isInteger(value.port) && value.port >= 1024 && value.port <= 65535 &&
        typeof value.token === "string" && /^[0-9a-f]{64}$/.test(value.token);
}

async function savedBridge() {
    if (bridge) return bridge;
    try {
        const folder = await fs.getDataFolder();
        const value = JSON.parse(await (await folder.getEntry("bridge-config.json")).read());
        if (validBridge(value)) bridge = value;
    } catch (_) {}
    return bridge;
}

async function pairBridge() {
    const dialog = document.createElement("dialog");
    const input = document.createElement("input");
    input.setAttribute("type", "password");
    input.setAttribute("placeholder", "PhotoCraft 配对码");
    const cancel = document.createElement("button");
    cancel.textContent = "取消";
    cancel.onclick = () => dialog.close();
    const pair = document.createElement("button");
    pair.textContent = "配对";
    pair.setAttribute("uxp-variant", "cta");
    pair.onclick = () => dialog.close(input.value.trim());
    dialog.appendChild(input);
    dialog.appendChild(cancel);
    dialog.appendChild(pair);
    document.body.appendChild(dialog);
    let code;
    try { code = await dialog.showModal(); }
    catch (_) { return null; }
    finally { dialog.remove(); }
    if (!code) return null;
    const match = String(code).match(/^(\d{4,5}):([0-9a-fA-F]{64})$/);
    const value = match && { port: Number(match[1]), token: match[2].toLowerCase() };
    if (!validBridge(value)) throw new Error("配对码格式不正确。");
    try { await request("/status", {}, value); }
    catch (_) { throw new Error("无法连接 PhotoCraft 桥接组件，请检查配对码。"); }
    const folder = await fs.getDataFolder();
    const file = await folder.createFile("bridge-config.json", { overwrite: true });
    await file.write(JSON.stringify(value));
    bridge = value;
    return bridge;
}

async function alertError(error) {
    console.log(error.stack || error.message || error);
    const dialog = document.createElement("dialog");
    const content = document.createElement("p");
    content.textContent = error.message || String(error);
    const button = document.createElement("button");
    button.textContent = "确定";
    button.setAttribute("uxp-variant", "cta");
    button.onclick = () => dialog.close();
    dialog.appendChild(content);
    dialog.appendChild(button);
    document.body.appendChild(dialog);
    try { await dialog.showModal(); } finally { dialog.remove(); }
}

function selectedImage(selection) {
    if (selection.items.length !== 1 || !(selection.items[0].fill instanceof scenegraph.ImageFill)) {
        throw new Error("请选择一个包含图像填充的对象。");
    }
    return selection.items[0];
}

async function folderFor(node) {
    const data = await fs.getDataFolder();
    const name = "compositor-edit-" + scenegraph.root.guid + "-" + node.guid;
    try { return await data.getEntry(name); }
    catch (_) { return await data.createFolder(name); }
}

function embeddedBitmap(svg) {
    const images = [];
    const pattern = /(?:xlink:)?href\s*=\s*["'](data:image\/(?:png|jpeg|gif);base64,[A-Za-z0-9+/=\s]+)["']/g;
    let match;
    while ((match = pattern.exec(svg))) {
        const uri = match[1].replace(/\s/g, "");
        if (!images.includes(uri)) images.push(uri);
    }
    if (images.length !== 1) throw new Error("无法从此对象提取单一原始图像，请选择图像本身。");
    const parts = images[0].match(/^data:image\/(png|jpeg|gif);base64,(.+)$/);
    const decoded = atob(parts[2]);
    const bytes = new Uint8Array(decoded.length);
    for (let i = 0; i < decoded.length; i++) bytes[i] = decoded.charCodeAt(i);
    return { bytes, extension: parts[1] === "jpeg" ? "jpg" : parts[1] };
}

async function edit(selection) {
    try {
        const node = selectedImage(selection);
        if (!await savedBridge() && !await pairBridge()) return;
        const folder = await folderFor(node);
        const svgFile = await folder.createFile("source.svg", { overwrite: true });
        let bitmap;
        try {
            await application.createRenditions([{ node, outputFile: svgFile,
                type: application.RenditionType.SVG, minify: false, embedImages: true }]);
            bitmap = embeddedBitmap(await svgFile.read());
        } finally { await svgFile.delete(); }
        // 每次发送用新文件名，避免覆盖尚在 PhotoCraft 中编辑的上一份图像。
        const filename = "working-" + Date.now() + "." + bitmap.extension;
        const image = await folder.createFile(filename, { overwrite: false });
        await image.write(bitmap.bytes, { format: uxp.storage.formats.binary });
        const extracted = new scenegraph.ImageFill(image);
        if (extracted.naturalWidth !== node.fill.naturalWidth || extracted.naturalHeight !== node.fill.naturalHeight) {
            await image.delete();
            throw new Error("导出结果不是原始图像尺寸，未发送或修改 XD 对象。");
        }
        const meta = await folder.createFile("session.json", { overwrite: true });
        await meta.write(JSON.stringify({ filename, document: scenegraph.root.guid,
            node: node.guid, asset: node.fill.assetId, scaleBehavior: node.fill.scaleBehavior }));
        try {
            await request("/edit", { file: image.nativePath, title: application.activeDocument.name });
        } catch (_) { throw new Error("无法连接 PhotoCraft 桥接组件，请重新运行插件安装程序。"); }
    } catch (error) { await alertError(error); }
}

async function request(path, body, configuration = bridge) {
    if (!validBridge(configuration)) throw new Error("PhotoCraft 桥接组件尚未配对。");
    const response = await fetch("http://127.0.0.1:" + configuration.port + path, {
        method: "POST", headers: { "Content-Type": "application/json", "Authorization": "Bearer " + configuration.token },
        body: JSON.stringify(body)
    });
    if (!response.ok) throw new Error("PhotoCraft 桥接组件未能处理请求。");
    return await response.json();
}

function nodeById(root, guid) {
    if (root.guid === guid) return root;
    if (!root.children) return null;
    for (let i = 0; i < root.children.length; i++) {
        const found = nodeById(root.children.at(i), guid);
        if (found) return found;
    }
    return null;
}

async function replaceImage(node, file, scaleBehavior) {
    // Read bytes rather than the path: XD otherwise reuses a cached bitmap.
    const bytes = new Uint8Array(await file.read({ format: uxp.storage.formats.binary }));
    let binary = "";
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    const mime = bytes[0] === 0xff && bytes[1] === 0xd8 ? "image/jpeg" :
        bytes[0] === 0x47 && bytes[1] === 0x49 ? "image/gif" : "image/png";
    const fill = new scenegraph.ImageFill("data:" + mime + ";base64," + btoa(binary));
    fill.scaleBehavior = scaleBehavior;
    node.fill = fill;
}

async function update(selection) {
    let automatic = false;
    try {
        // XD gives AX-triggered and user-triggered commands the same entry point.
        // Only edit may pair: an automated update must stay silent before pairing.
        if (!await savedBridge()) return;
        const delivery = await request("/pending", { document: scenegraph.root.guid, title: application.activeDocument.name });
        automatic = delivery.automatic;
        if (delivery.updates.length) {
            const data = await fs.getDataFolder();
            for (const update of delivery.updates) {
                let status = "applied", asset;
                try {
                    const node = nodeById(scenegraph.root, update.node);
                    if (!node || !(node.fill instanceof scenegraph.ImageFill)) {
                        status = "missing-object";
                    } else {
                        const folder = await data.getEntry(update.folder);
                        const record = await folder.getEntry("session.json");
                        const meta = JSON.parse(await record.read());
                        if (meta.document !== scenegraph.root.guid || meta.node !== node.guid || meta.asset !== update.asset || node.fill.assetId !== update.asset) {
                            status = "image-changed";
                        } else {
                            await replaceImage(node, await folder.getEntry(update.filename), meta.scaleBehavior);
                            asset = node.fill.assetId;
                            meta.asset = asset;
                            await record.write(JSON.stringify(meta));
                        }
                    }
                } catch (error) { console.log(error.stack || error.message); status = "update-error"; }
                const ack = { id: update.id, revision: update.revision, status, previous: update.asset };
                if (asset) ack.asset = asset;
                await request("/ack", ack);
            }
            return;
        }
        // An automated command in another document must never open a file chooser.
        if (automatic) return;
        const node = selectedImage(selection);
        const folder = await folderFor(node);
        let meta;
        try { meta = JSON.parse(await (await folder.getEntry("session.json")).read()); }
        catch (_) { throw new Error("请先将此图像发送到 PhotoCraft 编辑。"); }
        if (meta.document !== scenegraph.root.guid || meta.node !== node.guid) throw new Error("编辑记录与当前文档或对象不一致。");
        if (meta.asset !== node.fill.assetId) throw new Error("XD 中的图像已被替换，请重新发送后再更新。");
        const file = await fs.getFileForOpening();
        if (!file) return;
        if (!/\.(png|jpe?g|gif)$/i.test(file.name)) throw new Error("请选择 PNG、JPEG 或 GIF 图像。");
        await replaceImage(node, file, meta.scaleBehavior);
        meta.asset = node.fill.assetId;
        await (await folder.getEntry("session.json")).write(JSON.stringify(meta));
    } catch (error) {
        if (automatic) console.log(error.stack || error.message);
        else await alertError(error);
    }
}

module.exports = { commands: { edit, update } };
