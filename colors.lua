local colors = {}

function colors.reset() return "\27[0m" end

function colors.step(s)   return "\27[36m" .. s .. "\27[0m" end
function colors.info(s)   return "\27[37m" .. s .. "\27[0m" end
function colors.tool(s)   return "\27[33m" .. s .. "\27[0m" end
function colors.error(s)  return "\27[31m" .. s .. "\27[0m" end
function colors.prompt(s) return "\27[34m" .. s .. "\27[0m" end

function colors.cyan(s)   return "\27[96m" .. s .. "\27[0m" end
function colors.green(s)  return "\27[92m" .. s .. "\27[0m" end
function colors.red(s)    return "\27[91m" .. s .. "\27[0m" end
function colors.yellow(s) return "\27[33m" .. s .. "\27[0m" end
function colors.dim(s)    return "\27[35m" .. s .. "\27[0m" end
function colors.bold(s)   return "\27[1m" .. s .. "\27[0m" end

return colors
