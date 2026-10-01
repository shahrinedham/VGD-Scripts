-- VGD OUTPUT CONSOLE GUI v57
-- V57: Make the error-count glyph pure white; preserve badge size, placement, and surrounding design.
-- V53: Move the smaller new-error badge to the shortcut top-left corner, half inside/outside.
-- V52: Start with the console panel hidden; open it using the existing floating shortcut.
-- V51: Append matching live logs in place during search/filter to preserve viewport.
-- V50: Guard deferred viewport restoration against stale render callbacks.
-- V49: Stable in-place search selection and navigation.
local Players = game:GetService("Players")
local LogService = game:GetService("LogService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer
local GUI_NAME = "VGD_OutputConsole_v2"
local MAX_LINES = 400
local records = {}
local filter = "ALL"
local query = ""
local expandedId = nil
local preserveScrollOnce = false
local rowWidgets = {}
local lastTappedId = nil
local lastTappedAt = 0
local DOUBLE_TAP_WINDOW = 0.45
local selectedMatch = 0
local pendingScrollRecordId = nil
local renderGeneration = 0
local panelOpen = false
local autoScroll = true
local newErrorCount = 0
local clearArmedAt = 0
local CLEAR_CONFIRM_WINDOW = 1.2
local refreshErrorBadge
local playerGui = LocalPlayer:WaitForChild("PlayerGui")
local old = playerGui:FindFirstChild(GUI_NAME)
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local panel = Instance.new("Frame")
panel.Name = "OutputPanel"
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Position = UDim2.new(0.5, 0, 1, -16)
panel.Size = UDim2.new(0.90, 0, 0, 320)
panel.BackgroundColor3 = Color3.fromRGB(17, 21, 29)
panel.BackgroundTransparency = 0.04
panel.BorderSizePixel = 0
panel.Parent = gui
panel.Visible = false
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)
local stroke = Instance.new("UIStroke", panel)
stroke.Color = Color3.fromRGB(48, 139, 218)
stroke.Transparency = 0.48
stroke.Thickness = 1

local function label(parent, name, text, pos, size, font, textSize, color)
 local l=Instance.new("TextLabel"); l.Name=name; l.BackgroundTransparency=1; l.Text=text; l.Position=pos; l.Size=size; l.Font=font; l.TextSize=textSize; l.TextColor3=color; l.TextXAlignment=Enum.TextXAlignment.Left; l.Parent=parent; return l
end
local title=label(panel,"Title","VGD CONSOLE",UDim2.new(0,12,0,2),UDim2.new(0.55,0,0,25),Enum.Font.GothamBold,15,Color3.fromRGB(240,244,250))
local live=label(panel,"LiveStatus","● LIVE",UDim2.new(0,119,0,3),UDim2.new(0,66,0,21),Enum.Font.GothamBold,10,Color3.fromRGB(93,220,145))

local function button(name,text,pos,size,bg)
 local b=Instance.new("TextButton"); b.Name=name; b.Text=text; b.Position=pos; b.Size=size; b.BackgroundColor3=bg; b.TextColor3=Color3.fromRGB(240,244,250); b.Font=Enum.Font.GothamBold; b.TextSize=10; b.AutoButtonColor=true; b.Parent=panel; Instance.new("UICorner",b).CornerRadius=UDim.new(0,6); return b
end
local copy=button("CopyAll","COPY",UDim2.new(1,-126,0,28),UDim2.new(0,54,0,22),Color3.fromRGB(36,111,83))
local clear=button("ClearAll","CLEAR",UDim2.new(1,-66,0,28),UDim2.new(0,54,0,22),Color3.fromRGB(65,74,89))

local total=label(panel,"TotalCount","TOTAL 0",UDim2.new(0,12,0,29),UDim2.new(0.32,0,0,18),Enum.Font.GothamBold,10,Color3.fromRGB(177,194,216))
local warns=label(panel,"WarnCount","WARN 0",UDim2.new(0.36,0,0,29),UDim2.new(0.28,0,0,18),Enum.Font.GothamBold,10,Color3.fromRGB(255,193,76))
local errors=label(panel,"ErrorCount","ERROR 0",UDim2.new(0.66,0,0,29),UDim2.new(0.3,0,0,18),Enum.Font.GothamBold,10,Color3.fromRGB(255,111,125))

-- Keep the visible search field as a frame, with the editable TextBox inset inside it.
-- This gives the text/caret a reliable left margin on mobile while typing, even if
-- the mobile text-entry overlay does not honor UIPadding consistently.
local searchFrame=Instance.new("Frame")
searchFrame.Name="SearchField"
searchFrame.Position=UDim2.new(0,10,0,54)
searchFrame.Size=UDim2.new(1,-108,0,27)
searchFrame.BackgroundColor3=Color3.fromRGB(29,36,48)
searchFrame.BorderSizePixel=0
searchFrame.Parent=panel
Instance.new("UICorner",searchFrame).CornerRadius=UDim.new(0,7)
local searchStroke=Instance.new("UIStroke",searchFrame)
searchStroke.Color=Color3.fromRGB(55,82,112)
searchStroke.Transparency=0.72
searchStroke.Thickness=1

local search=Instance.new("TextBox")
search.Name="SearchLogs"
search.PlaceholderText="Search output..."
search.Text=""
search.ClearTextOnFocus=false
search.Position=UDim2.new(0,10,0,0)
search.Size=UDim2.new(1,-39,1,0)
search.BackgroundTransparency=1
search.TextColor3=Color3.fromRGB(232,238,247)
search.PlaceholderColor3=Color3.fromRGB(135,149,169)
search.Font=Enum.Font.Gotham
search.TextSize=12
search.TextXAlignment=Enum.TextXAlignment.Left
search.TextYAlignment=Enum.TextYAlignment.Center
search.Parent=searchFrame
local clearSearch=Instance.new("TextButton")
clearSearch.Name="ClearSearch"
clearSearch.Text="×"
clearSearch.Font=Enum.Font.GothamBold
clearSearch.TextSize=17
clearSearch.TextColor3=Color3.fromRGB(155,174,197)
clearSearch.BackgroundTransparency=1
clearSearch.AutoButtonColor=false
clearSearch.AnchorPoint=Vector2.new(0.5,0.5)
-- Place the X as a sibling so its position is predictable on narrow/mobile layouts.
-- Keep a comfortable inset from the search field right edge.
clearSearch.Position=UDim2.new(1,-119,0,67.5)
clearSearch.Size=UDim2.new(0,26,0,24)
clearSearch.Visible=false
clearSearch.ZIndex=search.ZIndex+2
clearSearch.Parent=panel
local resultCount=label(panel,"SearchResultCount","0/0",UDim2.new(1,-94,0,54),UDim2.new(0,35,0,27),Enum.Font.GothamBold,9,Color3.fromRGB(165,185,208)); resultCount.TextXAlignment=Enum.TextXAlignment.Center
local previousMatch=button("PreviousMatch","‹",UDim2.new(1,-57,0,54),UDim2.new(0,22,0,27),Color3.fromRGB(38,46,59)); previousMatch.TextSize=17
local nextMatch=button("NextMatch","›",UDim2.new(1,-32,0,54),UDim2.new(0,22,0,27),Color3.fromRGB(38,46,59)); nextMatch.TextSize=17
local function filterButton(name,text,x,w,selected)
 local b=button(name,text,UDim2.new(x,0,0,86),UDim2.new(w,0,0,22),selected and Color3.fromRGB(35,104,166) or Color3.fromRGB(38,46,59))
 b.TextSize=9
 return b
end
-- Responsive filter row: filters stay left, FOLLOW stays aligned to the far right.
local filters={}
filters.ALL=filterButton("FilterAll","ALL",0.03,0.14,true)
filters.Message=filterButton("FilterInfo","INFO",0.18,0.16,false)
filters.Warning=filterButton("FilterWarn","WARN",0.35,0.17,false)
filters.Error=filterButton("FilterError","ERROR",0.53,0.18,false)
local follow=button("AutoScroll","FOLLOW ON",UDim2.new(0.73,0,0,86),UDim2.new(0.24,0,0,22),Color3.fromRGB(36,111,83))
follow.TextSize=9

local output=Instance.new("ScrollingFrame")
output.Name="LogList"; output.Position=UDim2.new(0,9,0,115); output.Size=UDim2.new(1,-18,1,-143); output.BackgroundColor3=Color3.fromRGB(10,14,20); output.BorderSizePixel=0; output.ScrollBarThickness=4; output.ScrollBarImageColor3=Color3.fromRGB(74,115,155); output.CanvasSize=UDim2.new(0,0,0,0); output.AutomaticCanvasSize=Enum.AutomaticSize.Y; output.ScrollingDirection=Enum.ScrollingDirection.Y; output.Parent=panel; Instance.new("UICorner",output).CornerRadius=UDim.new(0,8)
local outputStroke=Instance.new("UIStroke",output); outputStroke.Color=Color3.fromRGB(42,68,94); outputStroke.Transparency=0.68; outputStroke.Thickness=1
local list=Instance.new("UIListLayout",output); list.Padding=UDim.new(0,3); list.SortOrder=Enum.SortOrder.LayoutOrder
local pad=Instance.new("UIPadding",output); pad.PaddingTop=UDim.new(0,6); pad.PaddingBottom=UDim.new(0,6); pad.PaddingLeft=UDim.new(0,6); pad.PaddingRight=UDim.new(0,6)
local footer=label(panel,"Footer","CLIENT OUTPUT  •  newest logs appear below",UDim2.new(0,12,1,-20),UDim2.new(1,-24,0,13),Enum.Font.Gotham,9,Color3.fromRGB(125,143,165))

local function kindName(t)
 local raw=tostring(t):gsub("^Enum%.MessageType%.","")
 if raw=="MessageError" or raw=="Error" then return "Error" end
 if raw=="MessageWarning" or raw=="Warning" then return "Warning" end
 if raw=="MessageInfo" or raw=="Info" then return "Info" end
 if raw=="MessageOutput" or raw=="Output" then return "Info" end
 return "Info"
end
local function colorFor(kind)
 if kind=="Error" then return Color3.fromRGB(255,116,128) end
 if kind=="Warning" then return Color3.fromRGB(255,198,91) end
 return Color3.fromRGB(190,218,245)
end
local function escapeRichText(value)
 value=tostring(value)
 value=value:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;"):gsub("'","&apos;")
 return value
end
local function highlightedText(value,needle)
 local raw=tostring(value)
 if needle=="" then return escapeRichText(raw) end
 local lower=string.lower(raw); local parts={}; local cursor=1
 while true do
  local a,b=string.find(lower,needle,cursor,true)
  if not a then parts[#parts+1]=escapeRichText(string.sub(raw,cursor)); break end
  if a>cursor then parts[#parts+1]=escapeRichText(string.sub(raw,cursor,a-1)) end
  parts[#parts+1]='<font color="rgb(150,218,255)"><b>'..escapeRichText(string.sub(raw,a,b))..'</b></font>'
  cursor=b+1
 end
 return table.concat(parts)
end
local function matchingRecords()
 local result={}
 for _,rec in ipairs(records) do
  if (filter=="ALL" or rec.kind==filter or (filter=="Message" and rec.kind=="Info")) and (query=="" or string.find(string.lower(rec.text),query,1,true)~=nil) then result[#result+1]=rec end
 end
 return result
end
local navigationGeneration=0
local function scrollToRecord(rec)
 if not rec then return end
 navigationGeneration+=1
 local generation=navigationGeneration
 task.defer(function()
  task.wait()
  if generation~=navigationGeneration then return end
  local target=rowWidgets[rec.id]
  if not target or not target.row or target.row.Parent~=output then return end
  local row=target.row
  local top=row.AbsolutePosition.Y-output.AbsolutePosition.Y+output.CanvasPosition.Y
  local bottom=top+row.AbsoluteSize.Y
  local viewTop=output.CanvasPosition.Y
  local viewBottom=viewTop+output.AbsoluteSize.Y
  local nextY=viewTop
  if top<viewTop then nextY=top-8
  elseif bottom>viewBottom then nextY=bottom-output.AbsoluteSize.Y+8 end
  local maxY=math.max(0,output.AbsoluteCanvasSize.Y-output.AbsoluteSize.Y)
  output.CanvasPosition=Vector2.new(0,math.clamp(nextY,0,maxY))
 end)
end
local function refreshSearchSelection()
 local visible=matchingRecords()
 for i,rec in ipairs(visible) do
  local w=rowWidgets[rec.id]
  if w then
   local row=w.row
   local selected=(query~="" and i==selectedMatch)
   row.BackgroundColor3=selected and (rec.kind=="Error" and Color3.fromRGB(83,34,43) or (rec.kind=="Warning" and Color3.fromRGB(83,62,28) or Color3.fromRGB(28,67,57))) or (rec.kind=="Error" and Color3.fromRGB(48,25,33) or (rec.kind=="Warning" and Color3.fromRGB(47,39,25) or Color3.fromRGB(19,27,38)))
   row.BackgroundTransparency=selected and 0 or 0.12
   local stroke=row:FindFirstChild("SearchSelectionIndicator")
   if selected and not stroke then
    stroke=Instance.new("UIStroke")
    stroke.Name="SearchSelectionIndicator"
    stroke.Color=colorFor(rec.kind)
    stroke.Thickness=2
    stroke.Transparency=0
    stroke.Parent=row
   elseif not selected and stroke then stroke:Destroy() end
  end
 end
 resultCount.Text=(query=="" and "—" or (#visible==0 and "0/0" or (tostring(selectedMatch).."/"..tostring(#visible))))
end
local function createRow(rec,i,expanded)
  local row=Instance.new("TextButton"); row.Name="Log_"..rec.id; row:SetAttribute("RecordId",rec.id); row.AutoButtonColor=false; row.BackgroundColor3=(rec.kind=="Error" and Color3.fromRGB(48,25,33)) or (rec.kind=="Warning" and Color3.fromRGB(47,39,25)) or Color3.fromRGB(19,27,38); row.BackgroundTransparency=0.12; row.Size=UDim2.new(1,-4,0,23); row.AutomaticSize=Enum.AutomaticSize.None; row.Text=""; row.TextTransparency=1
  Instance.new("UICorner",row).CornerRadius=UDim.new(0,5)
  local mark=rec.kind=="Error" and "✖" or (rec.kind=="Warning" and "⚠" or "●")
  local head=string.format("%s  %s  [%s]  ",mark,rec.time,string.upper(rec.kind))
  local availableWidth=math.max(40,output.AbsoluteSize.X-6-14-20)
  local baseText=escapeRichText(head)..highlightedText(rec.text,query)
  local collapsedText=baseText..'  <font color="rgb(120,145,171)">›</font>'
  local measured=TextService:GetTextSize(head..rec.text.."  ›",11,Enum.Font.Code,Vector2.new(availableWidth,120))
  local baseHeight=math.clamp(math.ceil(measured.Y)+6,23,120)
  local main=Instance.new("TextLabel"); main.Name="OriginalLogText"; main.BackgroundTransparency=1; main.BorderSizePixel=0
  main.Position=UDim2.new(0,7,0,0); main.Size=UDim2.new(1,-34,0,baseHeight)
  main.Font=Enum.Font.Code; main.TextSize=11; main.TextWrapped=true; main.TextXAlignment=Enum.TextXAlignment.Left; main.TextYAlignment=Enum.TextYAlignment.Center
  main.TextColor3=colorFor(rec.kind); main.RichText=true; main.Text=expanded and baseText or collapsedText; main.Parent=row
  local detailText="DETAILS  •  Tap to collapse\nStack trace: not supplied by LogService.MessageOut"
  local detail=Instance.new("TextLabel"); detail.Name="ExpandedDetails"; detail.BackgroundTransparency=1; detail.BorderSizePixel=0
  detail.Font=Enum.Font.Code; detail.TextSize=11; detail.TextColor3=colorFor(rec.kind)
  detail.TextXAlignment=Enum.TextXAlignment.Left; detail.TextYAlignment=Enum.TextYAlignment.Top
  detail.TextWrapped=true; detail.Text=detailText; detail.RichText=false
  detail.Position=UDim2.new(0,7,0,baseHeight+4); detail.Size=UDim2.new(1,-34,0,26); detail.ZIndex=row.ZIndex+1; detail.Visible=expanded; detail.Parent=row
  if expanded then
   row.Size=UDim2.new(1,-4,0,math.clamp(baseHeight+4+26+3,23,120))
  else
   row.Size=UDim2.new(1,-4,0,baseHeight)
  end
  if i==selectedMatch and query~="" then
   local categoryColor=colorFor(rec.kind)
   row.BackgroundColor3=rec.kind=="Error" and Color3.fromRGB(83,34,43) or (rec.kind=="Warning" and Color3.fromRGB(83,62,28) or Color3.fromRGB(28,67,57))
   row.BackgroundTransparency=0
   local selectedStroke=Instance.new("UIStroke",row)
   selectedStroke.Name="SearchSelectionIndicator"
   selectedStroke.Color=categoryColor
   selectedStroke.Transparency=0
   selectedStroke.Thickness=2
  end
  row.LayoutOrder=i; row.Parent=output
  rowWidgets[rec.id]={row=row,main=main,detail=detail,baseHeight=baseHeight,baseText=baseText,collapsedText=collapsedText}
  local copyOne=Instance.new("TextButton")
  copyOne.Name="CopyThisLog"
  copyOne.Text=""
  copyOne.Size=UDim2.new(0,13,0,13)
  copyOne.AnchorPoint=Vector2.new(1,0.5)
  copyOne.Position=UDim2.new(1,-7,0.5,0)
  copyOne.BackgroundColor3=row.BackgroundColor3
  copyOne.BackgroundTransparency=0.35
  copyOne.AutoButtonColor=true
  copyOne.ZIndex=row.ZIndex+1
  copyOne.Parent=row
  Instance.new("UICorner",copyOne).CornerRadius=UDim.new(0,4)
  -- Draw a tiny copy symbol from UI shapes instead of a font glyph (which
  -- rendered as an unknown square on the user's device).
  local backSheet=Instance.new("Frame")
  backSheet.Name="CopyBackSheet"
  backSheet.Size=UDim2.new(0,5,0,6)
  backSheet.Position=UDim2.new(0,5,0,3)
  backSheet.BackgroundTransparency=1
  backSheet.BorderSizePixel=0
  backSheet.ZIndex=copyOne.ZIndex+1
  backSheet.Parent=copyOne
  local backStroke=Instance.new("UIStroke",backSheet)
  backStroke.Color=colorFor(rec.kind)
  backStroke.Thickness=1
  local frontSheet=Instance.new("Frame")
  frontSheet.Name="CopyFrontSheet"
  frontSheet.Size=UDim2.new(0,5,0,6)
  frontSheet.Position=UDim2.new(0,3,0,5)
  frontSheet.BackgroundColor3=row.BackgroundColor3
  frontSheet.BorderSizePixel=0
  frontSheet.ZIndex=copyOne.ZIndex+2
  frontSheet.Parent=copyOne
  local frontStroke=Instance.new("UIStroke",frontSheet)
  frontStroke.Color=colorFor(rec.kind)
  frontStroke.Thickness=1
  copyOne.Activated:Connect(function()
   local setter=setclipboard or toclipboard
   local payload=string.format("[%s] [%s] %s",rec.time,rec.kind,rec.text)
   if type(setter)=="function" then pcall(setter,payload); footer.Text="Selected log copied when clipboard is supported." else footer.Text="Clipboard unavailable in this environment." end
  end)
  row.Activated:Connect(function()
   if expandedId==rec.id then
    -- An already-expanded entry collapses on a single tap.
    expandedId=nil
    lastTappedId=nil
    lastTappedAt=0
    local w=rowWidgets[rec.id]; if w then w.main.Text=w.collapsedText; w.detail.Visible=false; w.row.Size=UDim2.new(1,-4,0,w.baseHeight) end
    return
   end
   local now=os.clock()
   if lastTappedId==rec.id and (now-lastTappedAt)<=DOUBLE_TAP_WINDOW then
    -- A collapsed entry expands only after a second tap on the same row.
    if expandedId and expandedId~=rec.id then
     local previous=rowWidgets[expandedId]
     if previous then previous.main.Text=previous.collapsedText; previous.detail.Visible=false; previous.row.Size=UDim2.new(1,-4,0,previous.baseHeight) end
    end
    expandedId=rec.id
    lastTappedId=nil
    lastTappedAt=0
    local w=rowWidgets[rec.id]; if w then w.main.Text=w.baseText; w.detail.Visible=true; w.row.Size=UDim2.new(1,-4,0,math.clamp(w.baseHeight+4+26+3,23,120)) end
   else
    lastTappedId=rec.id
    lastTappedAt=now
   end
  end)
end
local function render()
 renderGeneration+=1
 local thisRender=renderGeneration
 local savedCanvasPosition=output.CanvasPosition
 table.clear(rowWidgets)
 -- While searching/filtering, incoming logs must not force the list to the top or bottom.
 -- Preserve the user's current viewport; explicit match navigation still scrolls via scrollToRecord.
 local keepScroll=preserveScrollOnce or query~="" or filter~="ALL"
 preserveScrollOnce=false
 for _,child in ipairs(output:GetChildren()) do if child:IsA("GuiObject") and child~=list and child~=pad and child~=outputStroke then child:Destroy() end end
 local visibleRecords=matchingRecords()
 if #visibleRecords==0 then selectedMatch=0 else selectedMatch=math.clamp(selectedMatch,1,#visibleRecords) end
 resultCount.Text=(query=="" and "—" or (#visibleRecords==0 and "0/0" or (tostring(selectedMatch).."/"..tostring(#visibleRecords))))
 for i,rec in ipairs(visibleRecords) do
  createRow(rec,i,expandedId==rec.id)
 end
 footer.Text=string.format("CLIENT OUTPUT  •  %d shown / %d captured",#visibleRecords,#records)
 local navigationId=pendingScrollRecordId
 pendingScrollRecordId=nil
 if navigationId then
  task.defer(function()
   task.wait()
   task.wait()
   if thisRender~=renderGeneration then return end
   local target=rowWidgets[navigationId]
   if target and target.row and target.row.Parent==output then
    local y=target.row.AbsolutePosition.Y-output.AbsolutePosition.Y+output.CanvasPosition.Y
    local maxY=math.max(0,output.AbsoluteCanvasSize.Y-output.AbsoluteSize.Y)
    output.CanvasPosition=Vector2.new(0,math.clamp(y-8,0,maxY))
   end
  end)
 elseif keepScroll then
  task.defer(function()
   task.wait()
   if thisRender~=renderGeneration then return end
   local maxY=math.max(0,output.AbsoluteCanvasSize.Y-output.AbsoluteSize.Y)
   output.CanvasPosition=Vector2.new(0,math.clamp(savedCanvasPosition.Y,0,maxY))
  end)
 elseif autoScroll then
  task.defer(function()
   task.wait()
   if thisRender~=renderGeneration then return end
   output.CanvasPosition=Vector2.new(0,math.max(0,output.AbsoluteCanvasSize.Y-output.AbsoluteSize.Y))
  end)
 end
end
local function updateCounts()
 local w,e=0,0
 for _,r in ipairs(records) do if r.kind=="Warning" then w+=1 elseif r.kind=="Error" then e+=1 end end
 total.Text="TOTAL "..#records; warns.Text="WARN "..w; errors.Text="ERROR "..e
end
local nextRecordId=1
local function append(message,messageType)
 local kind=kindName(messageType)
 if kind=="Error" and not panelOpen then newErrorCount+=1; refreshErrorBadge() end
 local rec={id=nextRecordId,time=os.date("%H:%M:%S"),kind=kind,text=tostring(message)}
 nextRecordId+=1
 records[#records+1]=rec
 local evicted=nil
 if #records>MAX_LINES then evicted=table.remove(records,1) end
 if evicted and expandedId==evicted.id then expandedId=nil; lastTappedId=nil; lastTappedAt=0 end
 updateCounts()
 if evicted then
  -- Eviction changes the beginning of the visible list; rebuild only for this
  -- uncommon cap-boundary case. Ordinary live arrivals never tear down rows.
  render()
  return
 end

 if query~="" or filter~="ALL" then
  local visibleRecords=matchingRecords()
  if visibleRecords[#visibleRecords]==rec then
   if selectedMatch==0 then selectedMatch=1 end
   createRow(rec,#visibleRecords,false)
   refreshSearchSelection()
  else
   resultCount.Text=(query=="" and "—" or (#visibleRecords==0 and "0/0" or (tostring(selectedMatch).."/"..tostring(#visibleRecords))))
  end
  footer.Text=string.format("CLIENT OUTPUT  •  %d shown / %d captured",#visibleRecords,#records)
  -- Deliberately do not alter CanvasPosition here: the user may be inspecting
  -- an older search match while new matching logs arrive.
  return
 end

 createRow(rec,#records,false)
 resultCount.Text="—"
 footer.Text=string.format("CLIENT OUTPUT  •  %d shown / %d captured",#records,#records)
 if autoScroll then
  task.defer(function()
   task.wait()
   output.CanvasPosition=Vector2.new(0,math.max(0,output.AbsoluteCanvasSize.Y-output.AbsoluteSize.Y))
  end)
 end
end
search:GetPropertyChangedSignal("Text"):Connect(function()
 query=string.lower(search.Text)
 selectedMatch=1
 clearSearch.Visible=search.Text~=""
 render()
end)
clearSearch.Activated:Connect(function()
 search.Text=""
 search:ReleaseFocus()
end)
previousMatch.Activated:Connect(function()
 local matches=matchingRecords()
 local n=#matches
 if n>0 then
  selectedMatch=((selectedMatch-2)%n)+1
  refreshSearchSelection()
  scrollToRecord(matches[selectedMatch])
 end
end)
nextMatch.Activated:Connect(function()
 local matches=matchingRecords()
 local n=#matches
 if n>0 then
  selectedMatch=(selectedMatch%n)+1
  refreshSearchSelection()
  scrollToRecord(matches[selectedMatch])
 end
end)
local function setFilter(value)
 filter=value
 selectedMatch=1
 for name,b in pairs(filters) do b.BackgroundColor3=(name==value) and Color3.fromRGB(35,104,166) or Color3.fromRGB(38,46,59) end
 render()
end
for name,b in pairs(filters) do b.Activated:Connect(function() setFilter(name) end) end
copy.Activated:Connect(function()
 local out={}
 for _,r in ipairs(records) do if (filter=="ALL" or r.kind==filter or (filter=="Message" and r.kind=="Info")) and (query=="" or string.find(string.lower(r.text),query,1,true)) then out[#out+1]=string.format("[%s] [%s] %s",r.time,r.kind,r.text) end end
 local setter=setclipboard or toclipboard
 if type(setter)=="function" then pcall(setter,table.concat(out,"\n")); footer.Text="Filtered output copied when clipboard is supported." else footer.Text="Clipboard unavailable in this environment." end
end)
clear.Activated:Connect(function()
 local now=os.clock()
 if now-clearArmedAt<=CLEAR_CONFIRM_WINDOW then
  table.clear(records); expandedId=nil; selectedMatch=0; clearArmedAt=0; newErrorCount=0; refreshErrorBadge()
  clear.Text="CLEAR"
  updateCounts(); render()
 else
  clearArmedAt=now
  clear.Text="TAP AGAIN"
  footer.Text="Tap CLEAR again within 1.2 seconds to remove captured logs."
  task.delay(CLEAR_CONFIRM_WINDOW,function()
   if clearArmedAt==now then clearArmedAt=0; clear.Text="CLEAR" end
  end)
 end
end)
follow.Activated:Connect(function()
 autoScroll=not autoScroll
 follow.Text=autoScroll and "FOLLOW ON" or "PAUSED"
 follow.BackgroundColor3=autoScroll and Color3.fromRGB(36,111,83) or Color3.fromRGB(65,74,89)
 if autoScroll then output.CanvasPosition=Vector2.new(0,math.max(0,output.AbsoluteCanvasSize.Y-output.AbsoluteSize.Y)) end
end)

-- Compact C shortcut using the same drag/input pattern as v1.
local shortcut=Instance.new("TextButton")
shortcut.Name="ConsoleShortcut"
shortcut.Size=UDim2.new(0,34,0,34)
shortcut.Position=UDim2.new(1,-20,0.55,-130)
shortcut.AnchorPoint=Vector2.new(0.5,0.5)
shortcut.BackgroundColor3=Color3.fromRGB(18,26,34)
shortcut.Text="" -- glyph is rendered by independent layered labels below
shortcut.Font=Enum.Font.GothamBold
shortcut.TextSize=17
shortcut.AutoButtonColor=false
shortcut.Active=true
shortcut.Parent=gui
Instance.new("UICorner",shortcut).CornerRadius=UDim.new(0,8)
-- Outer rounded-box outline: match the main GUI panel border.
-- Keep the C glyph styling unchanged.
local shortcutStroke=Instance.new("UIStroke")
shortcutStroke.Name="ShortcutOuterOutline"
shortcutStroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
shortcutStroke.Color=Color3.fromRGB(48,139,218)
shortcutStroke.Thickness=1
shortcutStroke.Transparency=0.48
shortcutStroke.Parent=shortcut

-- Layered glyph glow: blue halo behind a crisp white C. This is independent
-- of the rounded-square UIStroke above.
local function makeCGlyph(name, zIndex, textColor, textTransparency, strokeTransparency, textSize)
 local glyph=Instance.new("TextLabel")
 glyph.Name=name
 glyph.BackgroundTransparency=1
 glyph.Size=UDim2.fromScale(1,1)
 glyph.Position=UDim2.fromOffset(0,0)
 glyph.Text="C"
 glyph.Font=Enum.Font.GothamBold
 glyph.TextSize=textSize
 glyph.TextColor3=textColor
 glyph.TextTransparency=textTransparency
 glyph.TextStrokeColor3=Color3.fromRGB(45,170,255)
 glyph.TextStrokeTransparency=strokeTransparency
 glyph.TextXAlignment=Enum.TextXAlignment.Center
 glyph.TextYAlignment=Enum.TextYAlignment.Center
 glyph.ZIndex=zIndex
 glyph.Parent=shortcut
 return glyph
end

-- Broad, low-opacity halo plus a tighter blue edge; crisp white glyph sits on top.
makeCGlyph("C_GlowWide", 2, Color3.fromRGB(45,170,255), 0.58, 0.28, 19)
makeCGlyph("C_GlowCore", 3, Color3.fromRGB(45,170,255), 0.28, 0.16, 18)
makeCGlyph("C_Foreground", 4, Color3.new(1,1,1), 0, 0.12, 17)

local errorBadge=Instance.new("TextLabel")
errorBadge.Name="NewErrorBadge"
errorBadge.Size=UDim2.new(0,15,0,15)
errorBadge.AnchorPoint=Vector2.new(0.5,0.5)
errorBadge.Position=UDim2.new(0,4,0,4)
errorBadge.BackgroundColor3=Color3.fromRGB(244,69,88)
errorBadge.TextColor3=Color3.fromRGB(255,255,255)
errorBadge.Font=Enum.Font.GothamBlack
errorBadge.TextSize=10
errorBadge.TextScaled=true
errorBadge.TextWrapped=false
errorBadge.TextXAlignment=Enum.TextXAlignment.Center
errorBadge.TextYAlignment=Enum.TextYAlignment.Center
errorBadge.Text=""
errorBadge.TextStrokeColor3=Color3.fromRGB(125,24,39)
errorBadge.TextStrokeTransparency=1
errorBadge.Visible=false
errorBadge.ZIndex=8
errorBadge.Parent=shortcut
Instance.new("UICorner",errorBadge).CornerRadius=UDim.new(1,0)
local badgeStroke=Instance.new("UIStroke")
badgeStroke.Name="BadgeContrastRing"
badgeStroke.Color=Color3.fromRGB(12,19,27)
badgeStroke.Thickness=1
badgeStroke.Transparency=0.16
badgeStroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border
badgeStroke.Parent=errorBadge
refreshErrorBadge=function()
 errorBadge.Visible=newErrorCount>0
 errorBadge.Text=newErrorCount>99 and "99+" or tostring(newErrorCount)
end

local dragging,moved,activeInput,dragStart,startPosition=false,false,nil,nil,nil
local function clampPosition(position)
 local parentSize,buttonSize=gui.AbsoluteSize,shortcut.AbsoluteSize
 if parentSize.X<=0 or parentSize.Y<=0 then return position end
 local x=math.clamp(parentSize.X*position.X.Scale+position.X.Offset,buttonSize.X/2,parentSize.X-buttonSize.X/2)
 local y=math.clamp(parentSize.Y*position.Y.Scale+position.Y.Offset,buttonSize.Y/2,parentSize.Y-buttonSize.Y/2)
 return UDim2.new(position.X.Scale,x-parentSize.X*position.X.Scale,position.Y.Scale,y-parentSize.Y*position.Y.Scale)
end
shortcut.InputBegan:Connect(function(input)
 if input.UserInputType==Enum.UserInputType.Touch or input.UserInputType==Enum.UserInputType.MouseButton1 then
  dragging,moved,activeInput=true,false,input
  dragStart,startPosition=input.Position,shortcut.Position
 end
end)
UserInputService.InputChanged:Connect(function(input)
 if not dragging or input~=activeInput then return end
 local delta=input.Position-dragStart
 if math.abs(delta.X)>5 or math.abs(delta.Y)>5 then moved=true end
 shortcut.Position=clampPosition(UDim2.new(startPosition.X.Scale,startPosition.X.Offset+delta.X,startPosition.Y.Scale,startPosition.Y.Offset+delta.Y))
end)
UserInputService.InputEnded:Connect(function(input)
 if not dragging or input~=activeInput then return end
 dragging=false
 if not moved then
  panelOpen=not panelOpen; panel.Visible=panelOpen
  if panelOpen then newErrorCount=0; refreshErrorBadge() end
 end
 activeInput=nil
end)
local connection=LogService.MessageOut:Connect(append)
gui.Destroying:Connect(function() connection:Disconnect() end)
append("VGD Output Console v21 initialized.",Enum.MessageType.MessageInfo)
