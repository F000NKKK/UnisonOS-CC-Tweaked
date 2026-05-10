// Список известных dotted Lua paths для автокомплита в дашборде.
// Не исчерпывающий — модовые периферии и кастомные глобалы доступны
// через peripheral.call / peripheral.getMethods и не перечислены тут.

export const KNOWN_PATHS: { path: string; signature?: string }[] = [
  // turtle
  { path: "turtle.forward" },     { path: "turtle.back" },
  { path: "turtle.up" },          { path: "turtle.down" },
  { path: "turtle.turnLeft" },    { path: "turtle.turnRight" },
  { path: "turtle.dig" },         { path: "turtle.digUp" },         { path: "turtle.digDown" },
  { path: "turtle.place", signature: "[text]" },
  { path: "turtle.placeUp", signature: "[text]" },
  { path: "turtle.placeDown", signature: "[text]" },
  { path: "turtle.drop", signature: "[count]" },
  { path: "turtle.dropUp", signature: "[count]" },
  { path: "turtle.dropDown", signature: "[count]" },
  { path: "turtle.suck", signature: "[count]" },
  { path: "turtle.suckUp", signature: "[count]" },
  { path: "turtle.suckDown", signature: "[count]" },
  { path: "turtle.refuel", signature: "[count]" },
  { path: "turtle.getFuelLevel" }, { path: "turtle.getFuelLimit" },
  { path: "turtle.select", signature: "slot" },
  { path: "turtle.getSelectedSlot" },
  { path: "turtle.getItemCount", signature: "[slot]" },
  { path: "turtle.getItemSpace", signature: "[slot]" },
  { path: "turtle.getItemDetail", signature: "[slot, detailed]" },
  { path: "turtle.transferTo", signature: "to_slot, [count]" },
  { path: "turtle.compare" }, { path: "turtle.compareUp" }, { path: "turtle.compareDown" },
  { path: "turtle.compareTo", signature: "slot" },
  { path: "turtle.detect" },  { path: "turtle.detectUp" },  { path: "turtle.detectDown" },
  { path: "turtle.inspect" }, { path: "turtle.inspectUp" }, { path: "turtle.inspectDown" },
  { path: "turtle.attack" },  { path: "turtle.attackUp" },  { path: "turtle.attackDown" },
  { path: "turtle.equipLeft" }, { path: "turtle.equipRight" },
  { path: "turtle.craft", signature: "[count]" },

  // peripheral
  { path: "peripheral.isPresent", signature: "name" },
  { path: "peripheral.getType",   signature: "name" },
  { path: "peripheral.hasType",   signature: "name, type" },
  { path: "peripheral.getMethods",signature: "name" },
  { path: "peripheral.getNames" },
  { path: "peripheral.call",      signature: "name, method, ...args" },
  { path: "peripheral.find",      signature: "type" },
  { path: "peripheral.wrap",      signature: "name" },

  // fs
  { path: "fs.list",         signature: "path" },
  { path: "fs.exists",       signature: "path" },
  { path: "fs.isDir",        signature: "path" },
  { path: "fs.isReadOnly",   signature: "path" },
  { path: "fs.getSize",      signature: "path" },
  { path: "fs.getFreeSpace", signature: "path" },
  { path: "fs.makeDir",      signature: "path" },
  { path: "fs.move",         signature: "from, to" },
  { path: "fs.copy",         signature: "from, to" },
  { path: "fs.delete",       signature: "path" },
  { path: "fs.find",         signature: "pattern" },
  { path: "fs.attributes",   signature: "path" },
  { path: "fs.combine",      signature: "...paths" },
  { path: "fs.getDir",       signature: "path" },
  { path: "fs.getName",      signature: "path" },

  // redstone
  { path: "redstone.getSides" },
  { path: "redstone.setOutput",        signature: "side, on" },
  { path: "redstone.getOutput",        signature: "side" },
  { path: "redstone.getInput",         signature: "side" },
  { path: "redstone.setAnalogOutput",  signature: "side, value" },
  { path: "redstone.getAnalogOutput",  signature: "side" },
  { path: "redstone.getAnalogInput",   signature: "side" },
  { path: "redstone.setBundledOutput", signature: "side, colors" },
  { path: "redstone.getBundledOutput", signature: "side" },
  { path: "redstone.getBundledInput",  signature: "side" },
  { path: "redstone.testBundledInput", signature: "side, color" },

  // term
  { path: "term.write",            signature: "text" },
  { path: "term.blit",             signature: "text, fg, bg" },
  { path: "term.clear" },
  { path: "term.clearLine" },
  { path: "term.getCursorPos" },
  { path: "term.setCursorPos",     signature: "x, y" },
  { path: "term.setCursorBlink",   signature: "value" },
  { path: "term.isColor" },
  { path: "term.getSize" },
  { path: "term.scroll",           signature: "lines" },
  { path: "term.setTextColor",     signature: "color" },
  { path: "term.setBackgroundColor", signature: "color" },
  { path: "term.setPaletteColor",  signature: "color, r, g, b" },
  { path: "term.getPaletteColor",  signature: "color" },

  // gps
  { path: "gps.locate", signature: "[timeout, debug]" },

  // os
  { path: "os.getComputerID" },
  { path: "os.getComputerLabel" },
  { path: "os.setComputerLabel", signature: "label" },
  { path: "os.time",  signature: "[locale]" },
  { path: "os.day",   signature: "[locale]" },
  { path: "os.epoch", signature: "[locale]" },
  { path: "os.clock" }, { path: "os.reboot" }, { path: "os.shutdown" },
  { path: "os.version" },
  { path: "os.queueEvent", signature: "event, ...args" },

  // rednet
  { path: "rednet.open",      signature: "side" },
  { path: "rednet.close",     signature: "side" },
  { path: "rednet.isOpen",    signature: "side" },
  { path: "rednet.send",      signature: "recipient, message, [protocol]" },
  { path: "rednet.broadcast", signature: "message, [protocol]" },
  { path: "rednet.host",      signature: "protocol, hostname" },
  { path: "rednet.unhost",    signature: "protocol" },
  { path: "rednet.lookup",    signature: "protocol, [hostname]" },

  // commands (Command Computers only)
  { path: "commands.exec",             signature: "command" },
  { path: "commands.list" },
  { path: "commands.getBlockPosition" },

  // gateway-internal display helpers
  { path: "__display.clear", signature: "monitor, bg" },
  { path: "__display.text",  signature: "monitor, x, y, text, fg, bg, scale" },
  { path: "__display.bar",   signature: "monitor, x, y, w, fraction, fill, empty, label" },
  { path: "__display.chart", signature: "monitor, x, y, w, h, values, line, bg, min, max" },
  { path: "__readFile",   signature: "path" },
  { path: "__writeFile",  signature: "path, data" },
  { path: "__appendFile", signature: "path, data" },
];
