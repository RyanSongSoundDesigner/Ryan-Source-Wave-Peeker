-- @description Source Wave Peeker
-- @version 1.0.0
-- @author Gemini & Ryan
-- @about
--   A visual waveform inspector for Reaper (Global Sampler Style).
--   Features:
--   - True source waveform viewing (bypassing trims/cuts).
--   - Drag & Drop selections to timeline.
--   - Solid block waveform aesthetic.
--   - Optimized for floating window workflow.
-- @provides [main] .

-- 1. 依赖检查
if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox("Script requires 'ReaImGui'. Please install via ReaPack.", "Error", 0)
    return
end

local ctx = reaper.ImGui_CreateContext('Source Wave Peeker')
local SCRIPT_TITLE = 'Source Wave Peeker'

-- ==========================================
-- [UI] Magma Theme (配色方案)
-- ==========================================
local COL_BG          = 0x151515FF -- 深黑背景
local COL_WAVE_SOLID  = 0xFF7700FF -- 岩浆橙波形
local COL_USED_BG     = 0xFFFFFF15 -- 当前使用区域(微亮)
local COL_USED_EDGE   = 0xFFFFFF88 -- 区域边缘
local COL_SEL_BG      = 0x0099FFFF -- 选中区域(蓝色)
local COL_TEXT        = 0xAAAAAAFF

-- 核心变量
local peak_cache = {}    
local cache_src_hash = "" 
local last_window_w = 0 

local source_len = 0
local source_path = ""
local selection_start = 0
local selection_end = 0
local vis_item_offset = 0 
local vis_item_len = 0    
local is_dragging_insert = false

-- 2. 核心逻辑：硬盘读取波形 (最稳的 v4 逻辑)
function BuildPeaks_FromDisk(filename, n_points)
    -- 简单的缓存防抖
    if filename == cache_src_hash and #peak_cache > 0 and math.abs(n_points - #peak_cache) < 50 then return end
    
    reaper.PreventUIRefresh(1)
    
    -- 创建隐形轨道进行读取
    local track_idx = reaper.CountTracks(0)
    reaper.InsertTrackAtIndex(track_idx, false)
    local temp_track = reaper.GetTrack(0, track_idx)
    reaper.SetMediaTrackInfo_Value(temp_track, "B_SHOWINMIXER", 0)
    reaper.SetMediaTrackInfo_Value(temp_track, "B_SHOWINTCP", 0)
    
    local new_source = reaper.PCM_Source_CreateFromFile(filename)
    if not new_source then
        reaper.DeleteTrack(temp_track); reaper.PreventUIRefresh(-1); return
    end
    
    local full_len, _ = reaper.GetMediaSourceLength(new_source)
    if full_len <= 0 then full_len = 0.1 end 
    local new_item = reaper.AddMediaItemToTrack(temp_track)
    local new_take = reaper.AddTakeToMediaItem(new_item)
    reaper.SetMediaItemTake_Source(new_take, new_source)
    -- 强制重置属性以读取全长
    reaper.SetMediaItemTakeInfo_Value(new_take, "D_STARTOFFS", 0)
    reaper.SetMediaItemTakeInfo_Value(new_take, "D_PLAYRATE", 1.0)
    reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", full_len)
    
    peak_cache = {}
    cache_src_hash = filename
    source_len = full_len
    
    local accessor = reaper.CreateTakeAudioAccessor(new_take)
    if accessor then
        local samples_per_channel = 1
        local sample_rate = 44100
        local chunk_len = full_len / n_points
        local buffer_size = math.ceil(chunk_len * sample_rate)
        if buffer_size > 2048 then buffer_size = 2048 end
        if buffer_size < 1 then buffer_size = 1 end
        local buf = reaper.new_array(buffer_size)
        
        for i = 0, n_points - 1 do
            local time_start = i * chunk_len
            local result = reaper.GetAudioAccessorSamples(accessor, sample_rate, 1, time_start, buffer_size, buf)
            if result > 0 then
                local min_val = 0; local max_val = 0
                local step = math.floor(result / 3) + 1 
                for j = 1, result, step do
                    local val = buf[j]
                    if val < min_val then min_val = val end
                    if val > max_val then max_val = val end
                end
                table.insert(peak_cache, {min_val, max_val})
            else
                table.insert(peak_cache, {0, 0})
            end
        end
        reaper.DestroyAudioAccessor(accessor)
    end
    reaper.DeleteTrack(temp_track)
    reaper.PreventUIRefresh(-1)
end

function GetSelectedMediaInfo()
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then return nil end
    local take = reaper.GetActiveTake(item)
    if not take or reaper.TakeIsMIDI(take) then return nil end
    
    local src = reaper.GetMediaItemTake_Source(take)
    local parent = reaper.GetMediaSourceParent(src)
    while parent do src = parent; parent = reaper.GetMediaSourceParent(src) end
    local filename = reaper.GetMediaSourceFileName(src, "")
    if filename == "" then return nil end
    
    local start_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
    if not playrate or playrate == 0 then playrate = 1.0 end
    return { filename = filename, item_start = start_offs, item_len = len * playrate }
end

function InsertSelectedToTimeline()
    if selection_end - selection_start <= 0.001 then return end
    reaper.PreventUIRefresh(1); reaper.Undo_BeginBlock(); reaper.SelectAllMediaItems(0, false)
    local _, _, _ = reaper.BR_GetMouseCursorContext()
    local track = reaper.BR_GetMouseCursorContext_Track()
    local pos = reaper.BR_GetMouseCursorContext_Position()
    if not track then
        track = reaper.GetTrack(0,0) or reaper.GetSelectedTrack(0,0)
        if not track then reaper.InsertTrackAtIndex(0, true); track = reaper.GetTrack(0,0) end
        pos = reaper.GetCursorPosition()
    end
    if track and source_path ~= "" then
        reaper.SetOnlyTrackSelected(track)
        if pos > -1 then reaper.SetEditCurPos(pos, false, false) end
        reaper.InsertMedia(source_path, 0)
        local new_item = reaper.GetSelectedMediaItem(0, 0)
        if new_item then
            local take = reaper.GetActiveTake(new_item)
            reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", selection_start)
            reaper.SetMediaItemInfo_Value(new_item, "D_LENGTH", selection_end - selection_start)
            reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1.0)
            reaper.UpdateItemInProject(new_item)
        end
    end
    reaper.Undo_EndBlock("Insert Sample", -1); reaper.PreventUIRefresh(-1); reaper.UpdateArrange()
end

-- 3. 绘图：纯净版 (不依赖绝对坐标，依赖相对布局)
function DrawWaveform(draw_list, p_min_x, p_min_y, w, h)
    -- 背景
    reaper.ImGui_DrawList_AddRectFilled(draw_list, p_min_x, p_min_y, p_min_x + w, p_min_y + h, COL_BG)
    
    if source_len <= 0 then 
        local txt = "NO AUDIO SELECTED"
        local txt_w, txt_h = reaper.ImGui_CalcTextSize(ctx, txt)
        reaper.ImGui_DrawList_AddText(draw_list, p_min_x + w/2 - txt_w/2, p_min_y + h/2 - txt_h/2, COL_TEXT, txt)
        return 
    end
    
    local mid_y = p_min_y + h/2
    local px_per_sec = w / source_len
    
    -- 绘制波形 (实心)
    if #peak_cache > 0 then
        local point_w = w / #peak_cache 
        local thickness = point_w + 1.2 -- 消除缝隙
        
        for i, peak in ipairs(peak_cache) do
            local x = p_min_x + (i-1) * point_w
            local h_scale = h / 2 * 0.95
            local y_min = mid_y + (peak[1] * h_scale)
            local y_max = mid_y + (peak[2] * h_scale)
            
            -- 最小显示 1px
            if y_max - y_min < 1 then y_min = mid_y - 0.5; y_max = mid_y + 0.5 end
            reaper.ImGui_DrawList_AddLine(draw_list, x, y_min, x, y_max, COL_WAVE_SOLID, thickness)
        end
    end
    
    -- 绘制 Current Used 区域
    local used_x1 = p_min_x + (vis_item_offset * px_per_sec)
    local used_w = vis_item_len * px_per_sec
    -- 简单限制防止画出界
    local r1 = math.max(used_x1, p_min_x)
    local r2 = math.min(used_x1 + used_w, p_min_x + w)
    
    if r2 > r1 then
        reaper.ImGui_DrawList_AddRectFilled(draw_list, r1, p_min_y, r2, p_min_y + h, COL_USED_BG)
        reaper.ImGui_DrawList_AddRect(draw_list, r1, p_min_y, r2, p_min_y + h, COL_USED_EDGE)
        reaper.ImGui_DrawList_AddText(draw_list, r1+3, p_min_y, COL_USED_EDGE, "USED")
    end
    
    -- 绘制 Selection 区域
    if selection_end > selection_start then
        local sel_x1 = p_min_x + (selection_start * px_per_sec)
        local sel_w = (selection_end - selection_start) * px_per_sec
        local sr1 = math.max(sel_x1, p_min_x)
        local sr2 = math.min(sel_x1 + sel_w, p_min_x + w)

        if sr2 > sr1 then
            -- 蓝色半透明
            reaper.ImGui_DrawList_AddRectFilled(draw_list, sr1, p_min_y, sr2, p_min_y + h, 0x0099FFFF & 0xFFFFFF66)
            reaper.ImGui_DrawList_AddRect(draw_list, sr1, p_min_y, sr2, p_min_y + h, 0x88CCFFFF, 0, 0, 2.0)
            
            local txt = string.format("%.2fs", selection_end - selection_start)
            reaper.ImGui_DrawList_AddText(draw_list, sr1+4, p_min_y+h-20, 0xFFFFFFFF, txt)
        end
    end
    
    -- 隐形按钮层 (处理鼠标交互)
    reaper.ImGui_SetCursorScreenPos(ctx, p_min_x, p_min_y)
    reaper.ImGui_InvisibleButton(ctx, "WaveCanvas", w, h)
    
    if reaper.ImGui_IsItemActive(ctx) then
        local mx, _ = reaper.ImGui_GetMousePos(ctx)
        local mouse_time = (mx - p_min_x) / px_per_sec
        if mouse_time < 0 then mouse_time = 0 end
        if mouse_time > source_len then mouse_time = source_len end
        
        if reaper.ImGui_IsMouseClicked(ctx, 0) then
            selection_start = mouse_time
            selection_end = mouse_time
        else
            selection_end = mouse_time
        end
        
        -- 自动翻转 start/end
        if selection_start > selection_end then
            local temp = selection_start; selection_start = selection_end; selection_end = temp
        end
    end
end

function Loop()
    local info = GetSelectedMediaInfo()
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    
    -- 动态分辨率重算
    if info and (info.filename ~= source_path or #peak_cache == 0 or math.abs(avail_w - last_window_w) > 50) then
        local new_res = math.floor(avail_w)
        if new_res < 100 then new_res = 100 end
        source_path = info.filename
        if info.filename ~= source_path then selection_start = 0; selection_end = 0 end
        BuildPeaks_FromDisk(info.filename, new_res)
        last_window_w = avail_w
    end
    
    if info then vis_item_offset = info.item_start; vis_item_len = info.item_len end

    -- 设置窗口样式：无Padding，纯黑背景
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0) 
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), COL_BG)
    
    local visible, open = reaper.ImGui_Begin(ctx, SCRIPT_TITLE, true)
    
    if visible then
        -- 布局计算
        local w, h = reaper.ImGui_GetContentRegionAvail(ctx)
        local btn_h = 35 -- 底部按钮高度
        local wave_h = h - btn_h
        if wave_h < 50 then wave_h = 50 end 
        
        local cursor_x, cursor_y = reaper.ImGui_GetCursorScreenPos(ctx)

        -- 1. 画波形区域
        DrawWaveform(reaper.ImGui_GetWindowDrawList(ctx), cursor_x, cursor_y, w, wave_h)
        
        -- 文件名浮动显示
        reaper.ImGui_SetCursorScreenPos(ctx, cursor_x + 10, cursor_y + 10)
        if source_path ~= "" then
             local fname = source_path:match("^.+[\\/](.+)$") or source_path
             reaper.ImGui_TextColored(ctx, 0xFFFFFFFF, "FILE: " .. fname)
        end
        
        -- 2. 底部按钮
        reaper.ImGui_SetCursorScreenPos(ctx, cursor_x, cursor_y + wave_h)
        
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x222222FF)
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 0)
        
        local dur = selection_end - selection_start
        local btn_txt = "DRAG TO TIMELINE"
        if dur > 0 then 
            btn_txt = "DRAG SELECTION (".. string.format("%.2f", dur) .."s)" 
            reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x0077AAFF) -- 激活蓝
        end
        
        -- 按钮填满宽度
        reaper.ImGui_Button(ctx, btn_txt, w, btn_h)
        
        if dur > 0 then reaper.ImGui_PopStyleColor(ctx) end
        reaper.ImGui_PopStyleColor(ctx)
        reaper.ImGui_PopStyleVar(ctx)

        -- 拖拽交互
        if reaper.ImGui_IsItemActive(ctx) then is_dragging_insert = true end
        if is_dragging_insert and not reaper.ImGui_IsMouseDown(ctx, 0) then
            is_dragging_insert = false
            InsertSelectedToTimeline()
        end

        reaper.ImGui_End(ctx)
    end
    
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_PopStyleVar(ctx)

    if open then reaper.defer(Loop) end
end

reaper.defer(Loop)
