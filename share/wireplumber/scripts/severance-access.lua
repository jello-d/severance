-- severance-access: what a client arriving through an ENCLAVE's PipeWire
-- socket may see. Shipped by severance (docs/enclave-user.md), placed into
-- the owner's WirePlumber by an integrator, with the fragment beside it in
-- ../wireplumber.conf.d.
--
-- An enclave's socket carries the property
--   pipewire.client.access = "severance-<enclave>"
-- onto every client that connects through it. Such a client sees ONLY what
-- clients with the SAME tag made, plus what any client needs to exist: the
-- core, itself, and the factories. Nothing of the owner's, and nothing of
-- another enclave's.
--
-- WHY THIS IS ENOUGH FOR VIDEO, measured: with these grants an enclave
-- reads its own video source, sees none of the owner's objects, and cannot
-- read an owner's source even when it names it by serial; a positive control
-- with ordinary access read that same source. Audio is NOT served this way:
-- playing sound needs the owner's sinks visible, and a visible sink exposes
-- its monitor, so an enclave's audio goes through its pulse socket instead.
--
-- FAILS CLOSED: the stock access script has no rule for this tag, so a
-- tagged client with this script absent gets no permissions at all.
--
-- The ObjectManagers are GLOBALS on purpose: a local one is garbage
-- collected once this chunk returns and silently stops reporting objects.
local log = Log.open_topic ("s-severance-access")
local PREFIX = "severance-"

local tag_of = {}      -- tagged client id -> its tag
local client_of = {}   -- tagged client id -> the client proxy
local owned = {}       -- node id -> tag of the client that made it

local function props (o)
  return o.properties or o["global-properties"] or {}
end

-- The tag an object belongs to, or nil for anything not an enclave's.
-- Ports and links resolve through their nodes, so a NODE is recorded (and
-- cleared, since ids are reused) whenever one arrives.
local function tag_of_object (kind, o)
  local p = props (o)
  if kind == "node" then
    local t = tag_of[tonumber (p["client.id"])]
    owned[o["bound-id"]] = t
    return t
  elseif kind == "port" then
    return owned[tonumber (p["node.id"])]
  elseif kind == "link" then
    return owned[tonumber (p["link.output.node"])] or
           owned[tonumber (p["link.input.node"])]
  end
end

local KINDS = { "factory", "node", "port", "link" }
severance_access_om = {}
for _, k in ipairs (KINDS) do
  severance_access_om[k] = ObjectManager { Interest { type = k } }
end

local function grant (cid, id, perm)
  client_of[cid]:update_permissions { [id] = perm }
end

-- Give every tagged client what it may have of ONE object.
local function share_object (kind, o)
  local t = (kind ~= "factory") and tag_of_object (kind, o) or nil
  for cid, ct in pairs (tag_of) do
    if kind == "factory" then grant (cid, o["bound-id"], "rx")
    elseif t == ct then grant (cid, o["bound-id"], "rwx") end
  end
  -- A port or link can arrive before its node, through another manager:
  -- once the node is known, offer them again.
  if kind == "node" and t then
    for _, k in ipairs { "port", "link" } do
      for x in severance_access_om[k]:iterate () do share_object (k, x) end
    end
  end
end

local function admit (client)
  local cid = client["bound-id"]
  local t = props (client)["pipewire.client.access"]
  tag_of[cid], client_of[cid] = t, client
  client:update_permissions { ["any"] = "-" }
  grant (cid, 0, "rx")
  grant (cid, cid, "rwx")
  -- Same-tag clients see each other (a portal's stream and its reader).
  for other, ot in pairs (tag_of) do
    if ot == t then
      grant (cid, other, "rx")
      grant (other, cid, "rx")
    end
  end
  for _, k in ipairs (KINDS) do
    for o in severance_access_om[k]:iterate () do share_object (k, o) end
  end
  log:info (client, "admitted client " .. cid .. " as " .. t)
end

severance_access_clients = ObjectManager {
  Interest { type = "client",
    Constraint { "pipewire.client.access", "#", PREFIX .. "*", type = "pw" } }
}
severance_access_clients:connect ("object-added", function (_, c) admit (c) end)
severance_access_clients:connect ("object-removed", function (_, c)
  local cid = c["bound-id"]
  tag_of[cid], client_of[cid] = nil, nil
end)
for _, k in ipairs (KINDS) do
  severance_access_om[k]:connect ("object-added",
    function (_, o) share_object (k, o) end)
  severance_access_om[k]:connect ("object-removed", function (_, o)
    if k == "node" then owned[o["bound-id"]] = nil end
  end)
  severance_access_om[k]:activate ()
end
severance_access_clients:activate ()
