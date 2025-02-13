local api = vim.api
local luv = vim.loop

local utils = require'nvim-tree.utils'

local M = {
  ignore_list = {},
  exclude_list = {},
  is_windows = vim.fn.has('win32') == 1
}

local function get_dir_git_status(parent_ignored, status, absolute_path)
  if parent_ignored then
    return '!!'
  end
  local dir_status = status.dirs and status.dirs[absolute_path]
  local file_status = status.files and status.files[absolute_path]
  return dir_status or file_status
end

local function dir_new(cwd, name, status, parent_ignored)
  local absolute_path = utils.path_join({cwd, name})
  local handle = luv.fs_scandir(absolute_path)
  local has_children = handle and luv.fs_scandir_next(handle) ~= nil

  return {
    absolute_path = absolute_path,
    git_status = get_dir_git_status(parent_ignored, status, absolute_path),
    group_next = nil, -- If node is grouped, this points to the next child dir/link node
    has_children = has_children,
    name = name,
    nodes = {},
    open = false,
  }
end

local function is_executable(absolute_path, ext)
  if M.is_windows then
    return utils.is_windows_exe(ext)
  end
  return luv.fs_access(absolute_path, 'X')
end

local function file_new(cwd, name, status, parent_ignored)
  local absolute_path = utils.path_join({cwd, name})
  local ext = string.match(name, ".?[^.]+%.(.*)") or ""

  return {
    absolute_path = absolute_path,
    executable = is_executable(absolute_path, ext),
    extension = ext,
    git_status = parent_ignored and '!!' or status.files and status.files[absolute_path],
    name = name,
  }
end

-- TODO-INFO: sometimes fs_realpath returns nil
-- I expect this be a bug in glibc, because it fails to retrieve the path for some
-- links (for instance libr2.so in /usr/lib) and thus even with a C program realpath fails
-- when it has no real reason to. Maybe there is a reason, but errno is definitely wrong.
-- So we need to check for link_to ~= nil when adding new links to the main tree
local function link_new(cwd, name, status, parent_ignored)
  --- I dont know if this is needed, because in my understanding, there isnt hard links in windows, but just to be sure i changed it.
  local absolute_path = utils.path_join({ cwd, name })
  local link_to = luv.fs_realpath(absolute_path)
  local stat = luv.fs_stat(absolute_path)
  local open, nodes
  if (link_to ~= nil) and luv.fs_stat(link_to).type == 'directory' then
    open = false
    nodes = {}
  end

  local last_modified = 0
  if stat ~= nil then
    last_modified = stat.mtime.sec
  end

  return {
    absolute_path = absolute_path,
    git_status = parent_ignored and '!!' or status.files and status.files[absolute_path],
    group_next = nil,   -- If node is grouped, this points to the next child dir/link node
    last_modified = last_modified,
    link_to = link_to,
    name = name,
    nodes = nodes,
    open = open,
  }
end

-- Returns true if there is either exactly 1 dir, or exactly 1 symlink dir. Otherwise, false.
-- @param cwd Absolute path to the parent directory
-- @param dirs List of dir names
-- @param files List of file names
-- @param links List of symlink names
local function should_group(cwd, dirs, files, links)
  if #dirs == 1 and #files == 0 and #links == 0 then
    return true
  end

  if #dirs == 0 and #files == 0 and #links == 1 then
    local absolute_path = utils.path_join({ cwd, links[1] })
    local link_to = luv.fs_realpath(absolute_path)
    return (link_to ~= nil) and luv.fs_stat(link_to).type == 'directory'
  end

  return false
end

local function node_comparator(a, b)
  if not (a and b) then
    return true
  end
  if a.nodes and not b.nodes then
    return true
  elseif not a.nodes and b.nodes then
    return false
  end

  return a.name:lower() <= b.name:lower()
end

---Check if the given path should be ignored.
---@param path string Absolute path
---@return boolean
local function should_ignore(path)
  local basename = utils.path_basename(path)

  for _, node in ipairs(M.exclude_list) do
    if path:match(node) then
      return false
    end
  end

  if M.config.filter_dotfiles then
    if basename:sub(1, 1) == '.' then
      return true
    end
  end

  if not M.config.filter_ignored then
    return false
  end

  local relpath = utils.path_relative(path, vim.loop.cwd())
  if M.ignore_list[relpath] == true or M.ignore_list[basename] == true then
    return true
  end

  local idx = path:match(".+()%.[^.]+$")
  if idx then
    if M.ignore_list['*'..string.sub(path, idx)] == true then
      return true
    end
  end

  return false
end

local function should_ignore_git(path, status)
  return M.config.filter_ignored
    and (M.config.filter_git_ignored and status and status[path] == '!!')
end

function M.refresh(nodes, cwd, parent_node, status)
  local handle = luv.fs_scandir(cwd)
  if type(handle) == 'string' then
    api.nvim_err_writeln(handle)
    return
  end

  local named_nodes = {}
  local cached_nodes = {}
  local nodes_idx = {}
  for i, node in ipairs(nodes) do
    node.git_status = (parent_node and parent_node.git_status == '!!' and '!!')
      or (status.files and status.files[node.absolute_path])
      or (status.dirs and status.dirs[node.absolute_path])
    cached_nodes[i] = node.name
    nodes_idx[node.name] = i
    named_nodes[node.name] = node
  end

  local dirs = {}
  local links = {}
  local files = {}
  local new_nodes = {}
  local num_new_nodes = 0

  while true do
    local name, t = luv.fs_scandir_next(handle)
    if not name then break end
    num_new_nodes = num_new_nodes + 1

    local abs = utils.path_join({cwd, name})
    if not should_ignore(abs) and not should_ignore_git(abs, status.files) then
      if not t then
        local stat = luv.fs_stat(abs)
        t = stat and stat.type
      end

      if t == 'directory' then
        table.insert(dirs, name)
        new_nodes[name] = true
      elseif t == 'file' then
        table.insert(files, name)
        new_nodes[name] = true
      elseif t == 'link' then
        table.insert(links, name)
        new_nodes[name] = true
      end
    end
  end

  -- Handle grouped dirs
  local next_node = parent_node.group_next
  if next_node then
    next_node.open = parent_node.open
    if num_new_nodes ~= 1 or not new_nodes[next_node.name] then
      -- dir is no longer only containing a group dir, or group dir has been removed
      -- either way: sever the group link on current dir
      parent_node.group_next = nil
      named_nodes[next_node.name] = next_node
    else
      M.refresh(nodes, next_node.absolute_path, next_node, status)
      return
    end
  end

  local idx = 1
  for _, name in ipairs(cached_nodes) do
    local node = named_nodes[name]
    if node and node.link_to then
      -- If the link has been modified: remove it in case the link target has changed.
      local stat = luv.fs_stat(node.absolute_path)
      if stat and node.last_modified ~= stat.mtime.sec then
        new_nodes[name] = nil
        named_nodes[name] = nil
      end
    end

    if not new_nodes[name] then
      table.remove(nodes, idx)
    else
      idx = idx + 1
    end
  end

  local all = {
    { nodes = dirs, fn = dir_new, check = function(_, abs) return luv.fs_access(abs, 'R') end },
    { nodes = links, fn = link_new, check = function(name) return name ~= nil end },
    { nodes = files, fn = file_new, check = function() return true end }
  }

  local prev = nil
  local change_prev
  local new_nodes_added = false
  for _, e in ipairs(all) do
    for _, name in ipairs(e.nodes) do
      change_prev = true
      if not named_nodes[name] then
        local n = e.fn(cwd, name, status)
        if e.check(n.link_to, n.absolute_path) then
          new_nodes_added = true
          idx = 1
          if prev then
            idx = nodes_idx[prev] + 1
          end
          table.insert(nodes, idx, n)
          nodes_idx[name] = idx
          cached_nodes[idx] = name
        else
          change_prev = false
        end
      end
      if change_prev and not (next_node and next_node.name == name) then
        prev = name
      end
    end
  end

  if next_node then
    table.insert(nodes, 1, next_node)
  end

  if new_nodes_added then
    utils.merge_sort(nodes, node_comparator)
  end
end

function M.explore(nodes, cwd, parent_node, status)
  local handle = luv.fs_scandir(cwd)
  if type(handle) == 'string' then
    api.nvim_err_writeln(handle)
    return
  end

  local dirs = {}
  local links = {}
  local files = {}

  while true do
    local name, t = luv.fs_scandir_next(handle)
    if not name then break end

    local abs = utils.path_join({cwd, name})
    if not should_ignore(abs) and not should_ignore_git(abs, status.files) then
      if not t then
        local stat = luv.fs_stat(abs)
        t = stat and stat.type
      end

      if t == 'directory' then
        table.insert(dirs, name)
      elseif t == 'file' then
        table.insert(files, name)
      elseif t == 'link' then
        table.insert(links, name)
      end
    end
  end

  local parent_node_ignored = parent_node and parent_node.git_status == '!!'
  -- Group empty dirs
  if parent_node and vim.g.nvim_tree_group_empty == 1 then
    if should_group(cwd, dirs, files, links) then
      local child_node
      if dirs[1] then child_node = dir_new(cwd, dirs[1], status, parent_node_ignored) end
      if links[1] then child_node = link_new(cwd, links[1], status, parent_node_ignored) end
      if luv.fs_access(child_node.absolute_path, 'R') then
        parent_node.group_next = child_node
        child_node.git_status = parent_node.git_status
        M.explore(nodes, child_node.absolute_path, child_node, status)
        return
      end
    end
  end

  for _, dirname in ipairs(dirs) do
    local dir = dir_new(cwd, dirname, status, parent_node_ignored)
    if luv.fs_access(dir.absolute_path, 'R') then
      table.insert(nodes, dir)
    end
  end

  for _, linkname in ipairs(links) do
    local link = link_new(cwd, linkname, status, parent_node_ignored)
    if link.link_to ~= nil then
      table.insert(nodes, link)
    end
  end

  for _, filename in ipairs(files) do
    local file = file_new(cwd, filename, status, parent_node_ignored)
    table.insert(nodes, file)
  end

  utils.merge_sort(nodes, node_comparator)
end

function M.setup(opts)
  M.config = {
    filter_ignored = true,
    filter_dotfiles = opts.filters.dotfiles,
    filter_git_ignored = opts.git.ignore,
  }

  M.exclude_list = opts.filters.exclude

  local custom_filter = opts.filters.custom
  if custom_filter and #custom_filter > 0 then
    for _, filter_name in pairs(custom_filter) do
      M.ignore_list[filter_name] = true
    end
  end
end

return M
