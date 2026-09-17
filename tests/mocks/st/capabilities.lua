-- Minimal stand-in for st.capabilities, so init.lua/device_handler.lua can
-- be required offline without the real SmartThings Lua runtime. init.lua
-- only needs capabilities.<name>.ID and capabilities.<name>.commands.<cmd>.NAME
-- at module-load time (to build its capability_handlers table);
-- device_handler.lua's use of capabilities.<name>.<attr>(...) only happens
-- inside function bodies that these lifecycle tests never invoke. Rather
-- than hardcode every capability this driver references, auto-vivify any
-- accessed field with a plausible shape so requiring these modules never
-- errors on a missing capability name.
local function make_commands()
  return setmetatable({}, {
    __index = function(t, cmd_name)
      local cmd = { NAME = cmd_name }
      rawset(t, cmd_name, cmd)
      return cmd
    end
  })
end

--- Auto-vivifying node used for capability attributes: supports both direct
--- calls (capabilities.fanSpeed.fanSpeed(value)) and further indexing into
--- named states (capabilities.switch.switch.on()).
local function make_attr_node(cap_name, attr_name)
  local node
  node = setmetatable({}, {
    __call = function(_, value)
      return { capability = cap_name, attribute = attr_name, value = value }
    end,
    __index = function(t, state_name)
      local fn = function(value)
        return { capability = cap_name, attribute = attr_name, state = state_name, value = value }
      end
      rawset(t, state_name, fn)
      return fn
    end
  })
  return node
end

local capabilities = setmetatable({}, {
  __index = function(t, cap_name)
    local cap = setmetatable({ ID = cap_name, commands = make_commands() }, {
      __index = function(ct, attr_name)
        local node = make_attr_node(cap_name, attr_name)
        rawset(ct, attr_name, node)
        return node
      end
    })
    rawset(t, cap_name, cap)
    return cap
  end
})

return capabilities
