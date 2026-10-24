var Artwork = require("artwork/Artwork"),
    BaseCommand = require("BaseCommand"),
    BitmapFill = require("BitmapFill"),
    BooleanGroup = require("BooleanGroup"),
    CommandIDs = require("commands/CommandIDs"),
    LiveEditProxyBitmapTracker = require("cloud/LiveEditProxyBitmapTracker"),
    PluginModel = require("plugins/PluginModel"),
    SceneNodeUtil = require("artwork/SceneNodeUtil"),
    Strings = require("locale/Strings"),
    util = require("util");

function getPhotoCraftPluginUid() {
    return Object.keys(PluginModel.plugins).find(function (uid) {
        var plugin = PluginModel.plugins[uid];
        return plugin.id === "CmptXd01" && plugin.uxpPlugin.runtime.loaded;
    });
}

function EditInPhotoshop() {
    EditInPhotoshop.super_.call(this, Strings.CMD_EDIT_IN_PHOTOSHOP,
        CommandIDs.CMD_EDIT_IN_PHOTOSHOP, {});
}

util.inherits(EditInPhotoshop, BaseCommand);

EditInPhotoshop.prototype.executeInternal = function () {
    if (this.enabled) {
        return require("plugins/PluginLoader")._invokePluginCommand(
            getPhotoCraftPluginUid(), "edit", Strings.CMD_EDIT_IN_PHOTOSHOP);
    }
};

Object.defineProperty(EditInPhotoshop.prototype, "enabled", {
    get: function () {
        return this.visible && getPhotoCraftPluginUid() !== undefined &&
            !LiveEditProxyBitmapTracker.isBitmapPending(
                Artwork.selectionModel.selection[0].fill.uid);
    }
});

Object.defineProperty(EditInPhotoshop.prototype, "visible", {
    get: function () {
        return (!canvas.enabled || Artwork.selectionModel.selection.length !== 1 ||
            !SceneNodeUtil.isMediaNode(Artwork.selectionModel.selection[0])) &&
            (canvas.enabled && Artwork.selectionModel.selection.length === 1 &&
            !(Artwork.selectionModel.selection[0] instanceof BooleanGroup) &&
            Artwork.selectionModel.selection[0].fill instanceof BitmapFill);
    }
});

exports.init = function (commandManager) {
    commandManager.registerExistingCommand(new EditInPhotoshop());
};

exports.reset = function () {};
