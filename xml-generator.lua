---@diagnostic disable: invisible
-- https://leafo.net/guides/setfenv-in-lua52-and-above.html
local setfenv = setfenv or function(fn, env)
    local i = 1
    while true do
        local name = debug.getupvalue(fn, i)
        if name == "_ENV" then
            debug.upvaluejoin(fn, i, (function() return env end), 1)
            break
        elseif not name then
            break
        end

        i = i + 1
    end

    return fn
end

---@generic T: table
---@param x T
---@param copy_metatable boolean?
---@return T
local function deep_copy(x, copy_metatable)
    local tname = type(x)
    if tname == "table" then
        local new = {}
        for k, v in pairs(x) do
            new[k] = deep_copy(v, copy_metatable)
        end

        if copy_metatable then setmetatable(new, deep_copy(getmetatable(x), true)) end

        return new
    else return x end
end

---@param x table
---@return metatable
local function metatable(x)
    local mt = getmetatable(x) or {}
    setmetatable(x, mt)
    return mt
end

---@generic T
---@param x T[]
---@return T[]
local function stringable_array(x)
    metatable(x).__tostring = function (self)
        local parts = {}

        for i, v in ipairs(self) do
            parts[i] = tostring(v)
        end

        return table.concat(parts)
    end
    (metatable(x) --[[@as table]]).__name = "XML.StringableArray"

    return x
end

---@class xml-generator
local export = {
    ---Attributes that should not be sanitized
    no_sanitize = { ["style"] = true, ["script"] = true },

    ---If true, the `lua` tag will be replaced with `_G`, so doing `xml.lua` will return the global table
    ---
    ---This is so if you use `declare_generator` you can use `lua` to access the global table
    lua_is_global = true
}

---@class XML.Children
---@field [integer] XML.Node | string | fun(): XML.Node

---@class XML.AttributeTable : XML.Children
---@field [string] string | boolean | number

---@class XML.Node
---@operator call(XML.AttributeTable): XML.Node
---@field tag string
---@field children XML.Children
---@field attributes XML.AttributeTable

---quotes are allowed in text, not in attributes
---@param str string
---@return string
function export.sanitize_text(str)
    return (str:gsub("[<>&]", {
        ["<"] = "&lt;",
        [">"] = "&gt;",
        ["&"] = "&amp;"
    }))
end

---@param str string
---@return string
function export.sanitize_attributes(str)
    return (export.sanitize_text(str):gsub("\"", "&quot;"):gsub("'", "&#39;"))
end

---@generic T
---@param x T
---@return type | `T`
function export.typename(x)
    local mt = getmetatable(x)
    if mt and mt.__name then return mt.__name else return type(x) end
end
local typename = export.typename

local insert = table.insert
local concat = table.concat
local tostring = tostring
---@param node XML.Node | XML.Component
---@return string
function export.node_to_string(node)
    if typename(node) == "XML.Component" then return tostring(node) end

    local sanitize = not export.no_sanitize[node.tag:lower()]
    local sanitize_text = sanitize and export.sanitize_text or function (...) return ... end

    local parts = { "<", node.tag }

    for k, v in pairs(node.attributes) do
        if type(v) == "boolean" then
            if v then insert(parts, " "..k) end
        else
            insert(parts, " "..k.."=\""..export.sanitize_attributes(tostring(v)).."\"")
        end
    end

    insert(parts, ">")

    for i, v in ipairs(node.children) do
        local tname = typename(v)
        if tname == "XML.Node" or tname == "XML.Component" or tname == "XML.StringableArray" then
            insert(parts, tostring(v))
        elseif tname == "function" then
            local f = coroutine.wrap(v)
            for elem in f do
                insert(parts, export.node_to_string(elem))
            end
        else
            insert(parts, sanitize_text(tostring(v)))
        end
    end

    insert(parts, "</"..node.tag..">")

    return concat(parts)
end

export.node_metatable = {
    ---@param self XML.Node
    ---@param attribs XML.AttributeTable | string | XML.Node
    ---@return XML.Node
    __call = function (self, attribs)
        local new = export.create_node(self.tag, deep_copy(self.attributes, true), deep_copy(self.children, true)) --[[@as XML.Node]]
        local tname = typename(attribs)
        if tname == "table" or tname == "function" then
            if tname == "table" then
                for i, v in ipairs(attribs --[[@as (string | XML.Node | fun(): XML.Node)[] ]]) do
                    insert(new.children, v)
                    attribs[i] = nil
                end
                for key, value in pairs(attribs --[[@as { [string] : string | boolean | number }]]) do
                    new.attributes[key] = value
                end
            else
                insert(new.children, attribs)
            end
        else
            insert(new.children, attribs)
        end

        return new
    end;

    __tostring = export.node_to_string;

    __name = "XML.Node";
}

---@overload fun(tag_name: "lua", attributes: XML.AttributeTable?, children: XML.Children?): _G
---@param tag_name string
---@param attributes XML.AttributeTable?
---@param children XML.Children?
---@return XML.Node
function export.create_node(tag_name, attributes, children)
    if tag_name == "lua" and export.lua_is_global then return _G end

    return setmetatable({
        tag = tag_name,
        children = children or {},
        attributes = attributes or {},
    }, export.node_metatable)
end

---@class XML.GeneratorTable
---@field lua _G
---@field [string] XML.Node
export.xml = setmetatable({}, {
    ---@param _ XML.GeneratorTable
    ---@param tag_name string
    __index = function(_, tag_name)
        return export.create_node(tag_name)
    end
})

---@generic T
---@param func fun(...: T): XML.Node
---@return fun(...: T): XML.Node
function export.declare_generator(func) return setfenv(func, export.xml) end

---Creates a style tag with the given lua table
---@param css { [string | string[]] : { [string | string[]] : (number | string | string[]) } }
---@return XML.Node
function export.style(css)
    local css_str = ""
    for selector, properties in pairs(css) do
        if type(selector) == "table" then selector = table.concat(selector, ", ") end

        css_str = css_str..selector.." {\n"
        for property, value in pairs(properties) do
            if type(value) == "table" then value = table.concat(value, ", ") end

            css_str = css_str.."    "..property..": "..value..";\n"
        end
        css_str = css_str.."}\n"
    end

    return export.xml.style(css_str)
end

---@class XML.Component : XML.Node
---@field attributes { [string] : any } The attributes can be any type for `component`s, but not for `node`s
---@field context fun(args: { [string] : any }, children: XML.Children?): XML.Node?
export.component_metatable = {
    ---@param self XML.Component
    ---@param args { [string] : any, [integer] : XML.Children }
    __call = function (self, args)
        ---@type XML.Component
        local new = setmetatable({
            attributes = deep_copy(self.attributes, true),
            children = deep_copy(self.children or stringable_array {}, true),
            context = self.context
        }, getmetatable(self))

        if type(args) == "table" and not (getmetatable(args) or {}).__tostring then
            for k, v in pairs(args) do
                if type(k) == "number" then
                    insert(new.children, v)
                else
                    new.attributes[k] = v
                end
            end
        else
            insert(new.children, args)
        end

        return new
    end;

    ---@param self XML.Component
    __tostring = function (self)
        local f = coroutine.create(self.context)

        ---@type XML.Node[]
        local arr = stringable_array {}
        local ok, res = coroutine.resume(f, self.attributes, self.children)
        if not ok then error(res) end
        table.insert(arr, res)

        if coroutine.status(f) ~= "dead" then
            repeat
                ok, res = coroutine.resume(f)
                if not ok then error(res) end
                table.insert(arr, res)
            until coroutine.status(f) == "dead"
        end

        return tostring(arr)
    end;
    __name = "XML.Component";
}

--[[
```lua
local xml_generator = require("xml-generator")
local xml = xml_generator.xml

local my_component = xml_generator.component(function(args, children)
    local number = args.number + 10

    coroutine.yield(xml.div {
        xml.h1 "Hello, World!";
        xml.p("Number: "..number);
        children;
    })
end)

print(my_component {number=1}{
    xml.p "This is a child"
})
```
]]
---@param context fun(args: { [string] : any }, children: XML.Children): XML.Node?
---@return XML.Component
function export.component(context)
    return setmetatable({ attributes = {}, children = stringable_array {}, context = context }, export.component_metatable)
end

---@param ns string
---@param sep string?
---@return XML.GeneratorTable
function export.namespace(ns, sep)
    sep = sep or "-"
    return setmetatable({ namespace = ns, seperator = sep }, {
        __index = function(self, tag_name)
            return export.create_node(string.format("%s%s%s", self.namespace, self.seperator, tag_name))
        end
    })
end

---WILL NOT BE SANITIZED
---@param ... string
---@return string[]
function export.raw(...) return stringable_array { ... } end

return export
